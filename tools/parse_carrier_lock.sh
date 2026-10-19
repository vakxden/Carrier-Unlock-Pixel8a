#!/usr/bin/env bash
# Usage: parse_carrier_lock.sh [dump_file]   (default: query device via adb)

if [[ -n $1 ]]; then
    RAW=$(<"$1")
else
    RAW=$(adb shell "service call phone 152 s16 com.android.shell")
fi

echo "$RAW" \
  | sed -nE "s/^0x[0-9a-fA-F]+: *([0-9a-fA-F ]*)'.*/\1/p" \
  | tr -s ' \n' ' ' \
  | gawk '
function u32(i)  { return strtonum("0x" w[i]) }
function rd_int(  v) {
    if (pos > nw) { print "ERROR: parcel truncated at word " pos > "/dev/stderr"; exit 1 }
    v = u32(pos++)
    return v >= 2147483648 ? v - 4294967296 : v
}
# String16: int32 char count (-1 = null), UTF-16LE chars + NUL, padded to 4 bytes
function rd_str(  len, n, i, v, c, out) {
    len = rd_int()
    if (len < 0) return "<null>"
    n = int(((len + 1) * 2 + 3) / 4)
    if (pos + n - 1 > nw) { print "ERROR: string overruns parcel at word " pos > "/dev/stderr"; exit 1 }
    out = ""
    for (i = 0; i < len; i++) {
        v = u32(pos + int(i / 2))
        c = (i % 2 == 0) ? v % 65536 : int(v / 65536)
        out = out (c >= 32 && c < 127 ? sprintf("%c", c) : "?")
    }
    pos += n
    return out
}
function rd_carrier_list(label,  n, i, nn, mcc, mnc, spn, imsi, gid1, gid2, cid, scid) {
    n = rd_int()
    if (n < 0) { printf "%s: <null list>\n", label; return }
    printf "%s: %d\n", label, n
    for (i = 1; i <= n; i++) {
        nn = rd_int()
        if (nn == 0) { printf "  #%d <null>\n", i; continue }
        mcc = rd_str(); mnc = rd_str(); spn = rd_str(); imsi = rd_str(); gid1 = rd_str(); gid2 = rd_str()
        cid = rd_int(); scid = rd_int()
        printf "  #%d MCC=%s MNC=%s SPN=%s IMSI=%s GID1=%s GID2=%s carrierId=%d specificCarrierId=%d\n", \
               i, mcc, mnc, spn, imsi, gid1, gid2, cid, scid
    }
}
function name(v, names) { return (v in names) ? names[v] : "UNKNOWN" }
{ nw = split($0, w, " ") }
END {
    pos = 1
    ex = rd_int()
    if (ex != 0) { printf "ERROR: Binder exception code %d\n", ex > "/dev/stderr"; exit 1 }
    if (rd_int() == 0) { print "Result: null CarrierRestrictionRules"; exit 0 }

    dflt[0] = "CARRIER_RESTRICTION_DEFAULT_NOT_ALLOWED"; dflt[1] = "CARRIER_RESTRICTION_DEFAULT_ALLOWED"
    pol[0] = "MULTISIM_POLICY_NONE"
    pol[1] = "MULTISIM_POLICY_ONE_VALID_SIM_MUST_BE_PRESENT"
    pol[2] = "MULTISIM_POLICY_APPLY_TO_ALL_SLOTS"
    pol[3] = "MULTISIM_POLICY_APPLY_TO_ONLY_SLOT_1"
    pol[4] = "MULTISIM_POLICY_VALID_SIM_MUST_PRESENT_ON_SLOT_1"
    pol[5] = "MULTISIM_POLICY_ACTIVE_SERVICE_ON_SLOT_1_TO_UNBLOCK_OTHER_SLOTS"
    pol[6] = "MULTISIM_POLICY_ACTIVE_SERVICE_ON_ANY_SLOT_TO_UNBLOCK_OTHER_SLOTS"
    pol[7] = "MULTISIM_POLICY_ALL_SIMS_MUST_BE_VALID"
    pol[8] = "MULTISIM_POLICY_SLOT_POLICY_OTHER"
    sts[0] = "STATUS_UNKNOWN (default)"; sts[1] = "NOT_RESTRICTED (all carriers allowed)"

    print "=========================================================="
    print "CARRIER RESTRICTION RULES"
    print "=========================================================="
    rd_carrier_list("Allowed carriers")
    rd_carrier_list("Excluded carriers")
    d = rd_int(); m = rd_int(); s = rd_int()
    printf "Policy Config Default Type: %d (%s)\n", d, name(d, dflt)
    printf "Multi-SIM Behavior Policy : %d (%s)\n", m, name(m, pol)
    printf "Restriction Status        : %d (%s)\n", s, name(s, sts)
    ai = rd_int()
    if (ai != 0) {
        printf "Allowed CarrierInfo list  : %d (element layout not decoded; remaining fields skipped)\n", ai
        exit 0
    }
    ei = rd_int()
    if (ei != 0) {
        printf "Excluded CarrierInfo list : %d (element layout not decoded; remaining fields skipped)\n", ei
        exit 0
    }
    print "Allowed/Excluded CarrierInfo: 0 / 0"
    printf "Use carrier lock info     : %s\n", rd_int() ? "true" : "false"
    if (pos <= nw) printf "WARNING: %d unparsed trailing word(s)\n", nw - pos + 1
    print "=========================================================="
}'

