#!/usr/bin/env bash
# patch_ko_bash_final.sh - robust pure-Bash patcher that handles readelf format differences
# Usage: patch_ko_bash_final.sh [-v] <in.ko> <out.ko> <ksym.tsv> <slide_hex>
set -euo pipefail

verbose=0
if [ "${1:-}" = "-v" ]; then verbose=1; shift; fi
if [ "$#" -ne 4 ]; then
  echo "Usage: $0 [-v] <in.ko> <out.ko> <ksym.tsv> <slide_hex>" >&2
  exit 2
fi

inp="$1"; outp="$2"; ksympath="$3"; slide_hex="${4#0x}"

for cmd in readelf awk xxd dd; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found: $cmd" >&2
    exit 2
  fi
done

cp -- "$inp" "$outp"

# parse_num: detect hex (0x or letters) else decimal
parse_num() {
  local raw="$1"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  if [[ -z "$raw" ]]; then echo 0; return; fi
  if [[ "$raw" == 0x* || "$raw" =~ [A-Fa-f] ]]; then
    echo $((16#${raw#0x}))
  else
    echo $((10#${raw}))
  fi
}

# Extract raw tokens: Off (token 5), Size (token 6), EntSize (token 7)
readelf -SW "$inp" | awk '
  /^\s*Section Headers:/ { started=1; next }
  started && NF>0 && /Name/ && /Offset/ && /EntSize/ { next }
  /^\s*\[.*\]/ && $2==".symtab" {
    print $5, $6, $7
    exit
  }
' > /tmp/.patch_symtab_info.$$ || { echo "failed to parse readelf sections" >&2; exit 1; }

read -r sh_off_raw sh_size_raw sh_entsize_raw < /tmp/.patch_symtab_info.$$
rm -f /tmp/.patch_symtab_info.$$

# Convert sh_off (likely hex) using parse_num
sh_off_dec=$(parse_num "$sh_off_raw")

# Convert sh_size (may be hex or decimal)
sh_size_dec=$(parse_num "$sh_size_raw")

# Determine entsize robustly:
# - If contains letters or starts with 0x => treat as hex
# - Else try: candidate_dec = decimal, candidate_hex = hex; pick the candidate that divides sh_size_dec evenly (if any)
if [[ "$sh_entsize_raw" == 0x* || "$sh_entsize_raw" =~ [A-Fa-f] ]]; then
  entsize_dec=$((16#${sh_entsize_raw#0x}))
else
  # candidate interpretations
  candidate_dec=$((10#${sh_entsize_raw}))
  # handle large numbers safely: use 16# prefix only if valid digits [0-9a-fA-F]
  candidate_hex=0
  if [[ "$sh_entsize_raw" =~ ^[0-9A-Fa-f]+$ ]]; then
    candidate_hex=$((16#${sh_entsize_raw}))
  fi
  # prefer the candidate that divides sh_size_dec evenly (size / entsize is integer)
  entsize_dec="$candidate_dec"
  if [ "$candidate_hex" -gt 0 ] && [ $(( sh_size_dec % candidate_hex )) -eq 0 ]; then
    entsize_dec="$candidate_hex"
  elif [ $(( sh_size_dec % candidate_dec )) -ne 0 ] && [ "$candidate_hex" -gt 0 ]; then
    # if decimal doesn't divide size but hex does, choose hex
    entsize_dec="$candidate_hex"
  fi
fi

$([ "$verbose" -eq 1 ] && printf "DEBUG: sh_off_raw=%s sh_size_raw=%s sh_entsize_raw=%s -> sh_off_dec=%d sh_size_dec=%d entsize_dec=%d\n" \
  "$sh_off_raw" "$sh_size_raw" "$sh_entsize_raw" "$sh_off_dec" "$sh_size_dec" "$entsize_dec" >&2) || true

slide_hex="${slide_hex#0x}"

patched=0
missing=()

hex_byte(){ printf '%02x' "$1"; }

lookup_link() {
  local nm="$1" k="$2" res
  res=$(awk -F$'\t' -v nm="$nm" '{ gsub(/\r$/,"",$2); if($2==nm){print $1; exit}}' "$k" || true)
  [ -n "$res" ] && { printf "%s" "$res"; return 0; }
  if [[ "$nm" == _* ]]; then
    nm2="${nm#_}"
    res=$(awk -F$'\t' -v nm="$nm2" '{ gsub(/\r$/,"",$2); if($2==nm){print $1; exit}}' "$k" || true)
    [ -n "$res" ] && { printf "%s" "$res"; return 0; }
  fi
  if [[ "$nm" == *@* ]]; then
    nm3="${nm%@*}"
    res=$(awk -F$'\t' -v nm="$nm3" '{ gsub(/\r$/,"",$2); if($2==nm){print $1; exit}}' "$k" || true)
    [ -n "$res" ] && { printf "%s" "$res"; return 0; }
  fi
  res=$(awk -F$'\t' -v nm="$nm" '{ gsub(/\r$/,"",$2); if(index($2,nm)){print $1; exit}}' "$k" || true)
  [ -n "$res" ] && { printf "%s" "$res"; return 0; }
  return 1
}

write_bytes() {
  local file="$1" offset="$2" hex="$3"
  printf '%s' "$hex" | xxd -r -p 2>/dev/null | dd of="$file" bs=1 seek="$offset" conv=notrunc 2>/dev/null
  return $?
}

while IFS=$'\t' read -r num name; do
  [ -z "${num:-}" ] && continue
  [ -z "${name// }" ] && continue

  $([ "$verbose" -eq 1 ] && printf "SYM: %s -> [%s]\n" "$num" "$name" >&2) || true

  link_hex="$(lookup_link "$name" "$ksympath" || true)"
  if [ -z "${link_hex:-}" ]; then
    missing+=("$name")
    $([ "$verbose" -eq 1 ] && printf "MISS: %s\n" "$name" >&2) || true
    continue
  fi

  link_hex="${link_hex#0x}"
  runtime_dec=$((16#$link_hex + 16#$slide_hex))

  off_dec=$(( sh_off_dec + num * entsize_dec ))
  off_shndx=$(( off_dec + 6 ))
  off_value=$(( off_dec + 8 ))

  low=$((0xfff1 & 0xff)); high=$(((0xfff1 >> 8) & 0xff))
  hex_shndx="$(hex_byte "$low")$(hex_byte "$high")"

  hex_val=""
  for ((i=0;i<8;i++)); do
    byte=$(( (runtime_dec >> (i*8)) & 0xff ))
    hex_val+=$(hex_byte "$byte")
  done

  $([ "$verbose" -eq 1 ] && printf "WRITE: num=%s name=%s link=%s runtime=0x%s off_shndx=%s off_value=%s\n" \
      "$num" "$name" "$link_hex" "$hex_val" "$off_shndx" "$off_value" >&2) || true

  if ! write_bytes "$outp" "$off_shndx" "$hex_shndx"; then
    echo "write failed for shndx $name" >&2; exit 2
  fi
  if ! write_bytes "$outp" "$off_value" "$hex_val"; then
    echo "write failed for st_value $name" >&2; exit 2
  fi

  patched=$((patched + 1))
done < <( readelf -sW "$inp" | awk '
  /^Symbol table/ {started=1; next}
  started && /^[[:space:]]*[0-9]+:/ {
    num=$1; sub(/:$/,"",num)
    ndx=$7
    if (ndx != "UND") next
    name=""; for(i=8;i<=NF;i++) name = (name=="" ? $i : name " " $i)
    print num "\t" name
  }
' )

echo "patched=${patched} missing=${#missing[@]}"
if [ "${#missing[@]}" -ne 0 ]; then
  for m in "${missing[@]}"; do printf "MISSING: %s\n" "$m"; done
  exit 3
fi

exit 0
