#!/usr/bin/env bash
# Usage: parse_carrier_lock.sh [parcel_dump_file]   (no arg: query device via adb)

if [ -n "$1" ]; then
    RAW_DUMP=$(cat "$1")
else
    RAW_DUMP=$(adb shell "service call phone 152 s16 com.android.shell")
fi

echo "$RAW_DUMP" | gawk '
# Parcel words: every 8-hex-digit token between "0xADDR:" and the quoted ASCII column
/^0x/ {
    line = $0
    sub(/^0x[0-9a-fA-F]+: */, "", line)
    sub(/ *\x27.*$/, "", line)
    n = split(line, tok, " ")
    for (i = 1; i <= n; i++) W[nw++] = strtonum("0x" tok[i])
}

function sint(v) { return (v >= 2147483648) ? v - 4294967296 : v }
function rd_int() { return sint(W[p++]) }

# String16: int32 length (-1 = null), UTF-16 chars + NUL, padded to 4 bytes
function rd_str16(    len, s, k, w, nwords) {
    len = rd_int()
    if (len < 0) return "<null>"
    nwords = int(((len + 1) * 2 + 3) / 4)
    s = ""
    for (k = 0; k < len; k++) {
        w = W[p + int(k / 2)]
        s = s sprintf("%c", (k % 2 == 0) ? (w % 65536) : int(w / 65536))
    }
    p += nwords
    return s
}

# String8: int32 length (-1 = null), UTF-8 bytes + NUL, padded to 4 bytes
function rd_str8(    len, s, k, w, nwords) {
    len = rd_int()
    if (len < 0) return "<null>"
    nwords = int((len + 1 + 3) / 4)
    s = ""
    for (k = 0; k < len; k++) {
        w = W[p + int(k / 4)]
        s = s sprintf("%c", int(w / (256 ^ (k % 4))) % 256)
    }
    p += nwords
    return s
}

function policy_name(v) {
    return (v == 0) ? "CARRIER_RESTRICTION_DEFAULT_NOT_ALLOWED" : (v == 1) ? "CARRIER_RESTRICTION_DEFAULT_ALLOWED" : "UNKNOWN"
}
function multisim_name(v) {
    if (v == 0) return "MULTISIM_POLICY_NONE"
    if (v == 1) return "MULTISIM_POLICY_ONE_VALID_SIM_MUST_BE_PRESENT"
    if (v == 2) return "MULTISIM_POLICY_APPLY_TO_ALL_SLOTS"
    if (v == 3) return "MULTISIM_POLICY_APPLY_TO_ONLY_SLOT_1"
    if (v == 4) return "MULTISIM_POLICY_VALID_SIM_MUST_PRESENT_ON_SLOT_1"
    if (v == 5) return "MULTISIM_POLICY_ACTIVE_SERVICE_ON_SLOT_1_TO_UNBLOCK_OTHER_SLOTS"
    if (v == 6) return "MULTISIM_POLICY_ACTIVE_SERVICE_ON_ANY_SLOT_TO_UNBLOCK_OTHER_SLOTS"
    if (v == 7) return "MULTISIM_POLICY_ALL_SIMS_MUST_BE_VALID"
    if (v == 8) return "MULTISIM_POLICY_SLOT_POLICY_OTHER"
    return "UNKNOWN"
}
function status_name(v) {
    return (v == 0) ? "NOT_RESTRICTED" : (v == 1) ? "RESTRICTED" : (v == 2) ? "UNKNOWN" : "?"
}

# CarrierIdentifier list: [1][mcc][mnc][spn][imsi][gid1][gid2][carrierId][specificCarrierId]
function rd_identifier_list(label, count,    i, flag, mcc, mnc, spn, imsi, gid1, gid2, cid, scid) {
    printf "%s carriers: %d\n", label, count
    for (i = 1; i <= count; i++) {
        flag = rd_int()
        if (flag == 0) { printf "  #%d <null>\n", i; continue }
        mcc = rd_str16(); mnc = rd_str16(); spn = rd_str16(); imsi = rd_str16()
        gid1 = rd_str16(); gid2 = rd_str16(); cid = rd_int(); scid = rd_int()
        printf "  #%d MCC=%s MNC=%s SPN=%s IMSI=%s GID1=%s GID2=%s carrierId=%d specificCarrierId=%d\n", \
               i, mcc, mnc, spn, imsi, gid1, gid2, cid, scid
    }
}

# android.telephony.CarrierInfo list: [1][mcc][mnc][spn][gid1][gid2][imsiPrefix][iccid][impi](String8) [ehplmn count][String16 x count]
function rd_info_list(label, count,    i, flag, mcc, mnc, spn, gid1, gid2, imsi, iccid, impi, ne, ehplmn, k) {
    printf "%s CarrierInfo list: %d\n", label, count
    for (i = 1; i <= count; i++) {
        flag = rd_int()
        if (flag == 0) { printf "  #%d <null>\n", i; continue }
        mcc = rd_str8(); mnc = rd_str8(); spn = rd_str8(); gid1 = rd_str8(); gid2 = rd_str8()
        imsi = rd_str8(); iccid = rd_str8(); impi = rd_str8()
        ne = rd_int(); ehplmn = ""
        for (k = 0; k < ne; k++) ehplmn = ehplmn (k ? "," : "") rd_str16()
        if (ne <= 0) ehplmn = "<none>"
        printf "  #%d MCC=%s MNC=%s SPN=%s GID1=%s GID2=%s IMSI=%s ICCID=%s IMPI=%s EHPLMN=%s\n", \
               i, mcc, mnc, spn, gid1, gid2, imsi, iccid, impi, ehplmn
    }
}

END {
    if (nw < 3) { print "No parcel data found" > "/dev/stderr"; exit 1 }
    p = 0
    exc = rd_int()      # exception code
    nn  = rd_int()      # non-null parcelable marker

    print "=========================================================="
    print "CARRIER RESTRICTION RULES"
    print "=========================================================="
    if (exc != 0 || nn == 0) { printf "Call failed or returned null (exception=%d, nonnull=%d)\n", exc, nn; exit 1 }

    rd_identifier_list("Allowed", rd_int())
    rd_identifier_list("Excluded", rd_int())

    dflt = rd_int(); msim = rd_int(); stat = rd_int()
    printf "Policy Config Default Type: %d (%s)\n", dflt, policy_name(dflt)
    printf "Multi-SIM Behavior Policy : %d (%s)\n", msim, multisim_name(msim)
    printf "Restriction Status        : %d (%s)\n", stat, status_name(stat)

    rd_info_list("Allowed", rd_int())
    rd_info_list("Excluded", rd_int())

    use_lock = rd_int()
    printf "Use Carrier Lock Info     : %s\n", use_lock ? "true" : "false"

    if (p < nw) printf "Trailing words (unparsed)  : %d, first=0x%08x\n", nw - p, W[p]
    else if (p > nw) print "WARNING: parser read past end of parcel" > "/dev/stderr"
    print "=========================================================="
}
'
