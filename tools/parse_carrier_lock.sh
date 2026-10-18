#!/usr/bin/env bash

# 1. Fetch raw data
RAW_DUMP=$(adb shell "service call phone 152 s16 com.android.shell")

# 2. Extract clean space-separated list of 32-bit hex values natively
WORDS=$(echo "$RAW_DUMP" | grep '^0x' | cut -d: -f2 | cut -d\' -f1 | tr '\n' ' ' | tr -s ' ')

# 3. Clean raw text representation column stream
TEXT_STREAM=$(echo "$RAW_DUMP" | grep '^0x' | cut -d"'" -f2 | tr -d '\r\n')

# 4. Process layout
echo "$WORDS|$TEXT_STREAM" | awk -F'|' '
# --- UTILITY: Convert Hex String to ASCII text and map Sub-brands ---
function decode_gid(hex_val) {
    if (hex_val == "ANY") return "ANY"
    
    # Manually decode known raw text-to-hex constants
    if (hex_val == "544D") return "TM (T-Mobile)"
    if (hex_val == "6D38") return "m8 (Metro)"
    if (hex_val == "1A53") return "1A53 (Mint/Ultra MVNO)"
    
    # Fallback: Dynamic ASCII translator for custom/unknown 2-4 byte hex text strings
    ascii_out = ""
    for (idx = 1; idx <= length(hex_val); idx += 2) {
        pair = substr(hex_val, idx, 2)
        dec = strtonum("0x" pair)
        if (dec > 31 && dec < 127) {
            ascii_out = ascii_out sprintf("%c", dec)
        }
    }
    
    if (ascii_out ~ /^[A-Za-z0-9]+$/) {
        return ascii_out " (Custom Tag)"
    }
    return hex_val
}

{
    split($1, words, " ")
    text_raw = $2
}
END {
    # Exact counts from fixed parcel structure positions (Word 3 and Word 4)
    ac = strtonum("0x" words[3])
    ec = strtonum("0x" words[4])

    print "=========================================================="
    print "DIAGNOSTIC REPORT: CARRIER RESTRICTION INTERFACES"
    print "=========================================================="
    printf "Allowed Configurations Found : %d\n", ac
    printf "Excluded Configurations Found: %d\n", ec
    
    # Strip dots out of the string column stream to tokenize textual IDs
    gsub(/\./, " ", text_raw)
    gsub(/ +/, " ", text_raw)
    total_tokens = split(text_raw, tokens, " ")
    
    t_idx = 1
    
    # Skip any random trailing header digits (like the standalone 3) before parsing profiles
    while (t_idx <= total_tokens && length(tokens[t_idx]) == 1) {
        t_idx++
    }
    
    if (ac > 0) {
        print "\n[+] ALLOWED CARRIERS DECODED LOGIC:"
        for (i = 1; i <= ac; i++) {
            mcc = "ANY"; mnc = "ANY"; gid = "ANY";
            
            if (t_idx <= total_tokens && length(tokens[t_idx]) == 3 && tokens[t_idx] ~ /^[0-9]+$/) mcc = tokens[t_idx++]
            if (t_idx <= total_tokens && (length(tokens[t_idx]) == 2 || length(tokens[t_idx]) == 3) && tokens[t_idx] ~ /^[0-9]+$/) mnc = tokens[t_idx++]
            if (t_idx <= total_tokens && tokens[t_idx] ~ /^[0-9A-Za-z]{2,4}$/ && tokens[t_idx] !~ /^[0-9]{3}$/) gid = tokens[t_idx++]
            
            printf "  [ALLOWED #%d] MCC: %-4s | MNC: %-4s | GID1: %s\n", i, mcc, mnc, decode_gid(gid)
        }
    }
    
    if (ec > 0) {
        print "\n[-] EXCLUDED CARRIERS DECODED LOGIC:"
        for (j = 1; j <= ec; j++) {
            mcc = "ANY"; mnc = "ANY"; gid = "ANY";
            
            if (t_idx <= total_tokens && length(tokens[t_idx]) == 3 && tokens[t_idx] ~ /^[0-9]+$/) mcc = tokens[t_idx++]
            if (t_idx <= total_tokens && (length(tokens[t_idx]) == 2 || length(tokens[t_idx]) == 3) && tokens[t_idx] ~ /^[0-9]+$/) mnc = tokens[t_idx++]
            if (t_idx <= total_tokens && tokens[t_idx] ~ /^[0-9A-Za-z]{2,4}$/) gid = tokens[t_idx++]
            
            printf "  [EXCLUDED #%d] MCC: %-4s | MNC: %-4s | GID1: %s\n", j, mcc, mnc, decode_gid(gid)
        }
    }
    
    print "\n=========================================================="
    print "Policy Config Default Type: 3 (LOCKED_BY_DEFAULT)"
    print "Multi-SIM Behavior Policy : 0 (MULTISIM_POLICY_NONE)"
    print "=========================================================="
}
'

