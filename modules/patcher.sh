#!/usr/bin/env bash
# patch_ko_bash_only.sh - Patch .ko so SHN_UNDEF imports become SHN_ABS with runtime addrs
# Usage: patch_ko_bash_only.sh [-v] <in.ko> <out.ko> <ksym.tsv> <slide_hex>
set -euo pipefail

verbose=0
if [ "${1:-}" = "-v" ]; then verbose=1; shift; fi
if [ "$#" -ne 4 ]; then
  echo "Usage: $0 [-v] <in.ko> <out.ko> <ksym.tsv> <slide_hex>" >&2
  exit 2
fi

inp="$1"; outp="$2"; ksympath="$3"; slide_hex="${4#0x}"

# Require tools: readelf, awk, xxd, dd
for cmd in readelf awk xxd dd; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found: $cmd" >&2
    exit 2
  fi
done

# Copy input -> output (we will edit output in place)
cp -- "$inp" "$outp"

# parse_num: parse hex or decimal; treat EntSize as hex later
parse_num() {
  local raw="$1"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  if [[ -z "$raw" ]]; then echo 0; return; fi
  if [[ "$raw" == 0x* || "$raw" =~ [A-Fa-f] ]]; then echo $((16#${raw#0x})); else echo $((10#${raw})); fi
}

# Extract .symtab Off (token 5) and EntSize (token 7) robustly from readelf -SW
readelf -SW "$inp" | awk '
  /^\s*Section Headers:/ { started=1; next }
  started && NF>0 && /Name/ && /Offset/ && /EntSize/ { next }
  /^\s*\[.*\]/ && $2==".symtab" {
    print $5, $7
    exit
  }
' > /tmp/.patch_symtab_info.$$ || { echo "failed to parse sections" >&2; exit 1; }
read -r sh_off_raw sh_entsize_raw < /tmp/.patch_symtab_info.$$
rm -f /tmp/.patch_symtab_info.$$

# Interpret Offset as hex token, EntSize token is hex (like "18")
sh_off_dec=$(parse_num "$sh_off_raw")
entsize_dec=$((16#${sh_entsize_raw#0x}))

$([ "$verbose" -eq 1 ] && printf "DEBUG: sh_off_raw=%s sh_entsize_raw=%s -> sh_off_dec=%d entsize_dec=%d\n" "$sh_off_raw" "$sh_entsize_raw" "$sh_off_dec" "$entsize_dec" >&2) || true

slide_hex="${slide_hex#0x}"

patched=0
missing=()

hex_byte(){ printf '%02x' "$1"; }

# lookup with fallbacks (exact, strip leading _, strip @suffix, substring)
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

# write_bytes: write hex string (no spaces) to file at decimal offset using xxd|dd
# args: file, offset_decimal, hexstring
write_bytes() {
  local file="$1"; local offset="$2"; local hex="$3"
  # echo hex -> xxd -r -p produces binary -> dd to file at offset (conv=notrunc)
  printf '%s' "$hex" | xxd -r -p 2>/dev/null | dd of="$file" bs=1 seek="$offset" conv=notrunc 2>/dev/null
  return $?
}

# Iterate symbols from readelf -sW, produce num<TAB>name for UND symbols
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

  # normalize link hex and compute runtime
  link_hex="${link_hex#0x}"
  runtime_dec=$((16#$link_hex + 16#$slide_hex))

  off_dec=$(( sh_off_dec + num * entsize_dec ))
  off_shndx=$(( off_dec + 6 ))
  off_value=$(( off_dec + 8 ))

  # 2-byte LE for SHN_ABS (0xfff1)
  low=$((0xfff1 & 0xff)); high=$(((0xfff1 >> 8) & 0xff))
  hex_shndx="$(hex_byte "$low")$(hex_byte "$high")"

  # 8-byte LE runtime value hex (16 hex chars)
  hex_val=""
  for ((i=0;i<8;i++)); do
    byte=$(( (runtime_dec >> (i*8)) & 0xff ))
    hex_val+=$(hex_byte "$byte")
  done

  $([ "$verbose" -eq 1 ] && printf "WRITE: num=%s name=%s link=%s runtime=0x%s off_shndx=%s off_value=%s\n" \
      "$num" "$name" "$link_hex" "$hex_val" "$off_shndx" "$off_value" >&2) || true

  # Write st_shndx (2 bytes) and st_value (8 bytes)
  if ! write_bytes "$outp" "$off_shndx" "$hex_shndx"; then
    echo "failed to write shndx for $name at $off_shndx" >&2
    exit 2
  fi
  if ! write_bytes "$outp" "$off_value" "$hex_val"; then
    echo "failed to write st_value for $name at $off_value" >&2
    exit 2
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
  for m in "${missing[@]}"; do
    printf "MISSING: %s\n" "$m"
  done
  exit 3
fi

exit 0
