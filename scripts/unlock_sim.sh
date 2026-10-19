#!/bin/bash

set -o pipefail

# The adb command is required
if ! command -v adb >/dev/null 2>&1; then
  echo "Error: 'adb' not found in PATH. Install Android platform-tools and set ADB env variable." >&2
  exit 1
fi

# The xmlstarlet command is required for safe XML edits
if ! command -v xmlstarlet >/dev/null 2>&1; then
  err "xmlstarlet is required but not found. Install xmlstarlet and retry."
  exit 1
fi

ADB=${ADB:-adb}
BASE_DIR="$(cd "$(dirname "$0")"/.. >/dev/null 2>&1 && pwd)"
LOG=${LOG:-${BASE_DIR}/${0}.log}
KSUD="/data/local/tmp/ksud-pixel"
PACKAGE="com.google.android.apps.work.oobconfig"
REMOTE_TMP="/data/local/tmp/oobconfig-fix"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
err() { printf "ERROR: %s\n" "$*" >&2; }
warn() { printf "WARNING: %s\n" "$*" >&2; }

# Redirect the whole script's output to log file
exec > >(tee -a "$LOG") 2>&1

# Log the device details
DEVICE="$($ADB shell getprop ro.product.device 2>/dev/null | tr -d '\r')"
BUILD="$($ADB shell getprop ro.build.display.id 2>/dev/null | tr -d '\r')"
log "Device: ${DEVICE}; Build: ${BUILD}"

# Verify KernelSU root via ksud
ROOT_ID="$($ADB shell "$KSUD debug su" <<'EOF'
id
EOF
)"
ROOT_ID="$(echo "$ROOT_ID" | tr -d '\r')"
log "root=${ROOT_ID}"
if ! grep -q "uid=0(root)" <<<"$ROOT_ID"; then
  err "KernelSU root is not active."
  exit 1
fi

# Verivy package installed
USER_ID=0
INSTALLED="$($ADB shell "pm list packages --user ${USER_ID} ${PACKAGE}" 2>/dev/null || true)"
if ! grep -q "package:${PACKAGE}" <<<"$INSTALLED"; then
  log "The ${PACKAGE} package is already absent for user ${USER_ID}"
  exit 0
fi

# Disable PACKAGE on the device
log "Disabling ${PACKAGE} package..."
STATE_DIR="/data/system/users/${USER_ID}"
STATE="${STATE_DIR}/package-restrictions.xml"
RESERVE="${STATE}.reservecopy"
STAMP="$(date +%Y%m%d-%H%M%S)"

TMPDIR="$(mktemp -d -t oobconfig-fix-XXXXXX)"
cleanup_local() { rm -rf "$TMPDIR" || true; }
trap cleanup_local EXIT

PLAIN="$TMPDIR/package-restrictions.xml"
PATCHED="$TMPDIR/package-restrictions.patched.xml"

# Run preparation on-device: disable network, backup state, convert ABX->XML into REMOTE_TMP
log "Disabling Wi-Fi and staging package state..."
set +e
$ADB shell "$KSUD debug su" <<EOF
set -eu
echo Disabling WiFi...
svc wifi disable
echo Done.
echo Disabling data...
svc data disable
echo Done.
echo Stoping ${PACKAGE}...
am force-stop ${PACKAGE} || true
echo Done.
echo Making backups...
echo  - Deleting ${REMOTE_TMP}...
rm -rf ${REMOTE_TMP}
echo  - Done.
echo  - Creating ${REMOTE_TMP}...
mkdir -p ${REMOTE_TMP}
echo  - Done.
echo  - Copying ${STATE} to ${STATE_DIR}/package-restrictions.oobconfig-${STAMP}.bak...
cp ${STATE} ${STATE_DIR}/package-restrictions.oobconfig-${STAMP}.bak
echo  - Done.
if [ -f ${RESERVE} ]; then
  echo  - Copying ${RESERVE} to ${STATE_DIR}/package-restrictions.oobconfig-${STAMP}.reservecopy.bak...
  cp ${RESERVE} ${STATE_DIR}/package-restrictions.oobconfig-${STAMP}.reservecopy.bak
  echo  - Done.
fi
echo Backups created.
echo Converting ABX to XML...
abx2xml ${STATE} ${REMOTE_TMP}/package-restrictions.xml
echo Done.
chmod 644 ${REMOTE_TMP}/package-restrictions.xml
EOF
if [[ $? -ne 0 ]]; then
  err "Failed to prepare the device state; ensure abx2xml exists on device and ksud is usable."
  exit 1
fi
set -e

log "Pulling package-restrictions.xml to ${PLAIN}..."
$ADB pull "${REMOTE_TMP}/package-restrictions.xml" "$PLAIN" >/dev/null

# Patch XML using robust XPath; ensure attributes inst/stopped/nl exist, then set them
log "Patching package state locally..."
xmlstarlet ed \
  -i "//pkg[@name='${PACKAGE}'][not(@inst)]" -t attr -n inst -v "false" \
  -i "//pkg[@name='${PACKAGE}'][not(@stopped)]" -t attr -n stopped -v "true" \
  -i "//pkg[@name='${PACKAGE}'][not(@nl)]" -t attr -n nl -v "true" \
  -u "//pkg[@name='${PACKAGE}']/@inst" -v "false" \
  -u "//pkg[@name='${PACKAGE}']/@stopped" -v "true" \
  -u "//pkg[@name='${PACKAGE}']/@nl" -v "true" \
  "$PLAIN" > "$PATCHED"

# Quick local sanity check
COUNT=$(xmlstarlet sel -t -v "count(//pkg[@name='${PACKAGE}'][@inst='false' and @stopped='true' and @nl='true'])" "$PATCHED")
if [[ "$COUNT" != "1" ]]; then
  err "Expected package entry to be patched: 1; found: ${COUNT}."
  echo "--- patched XML preview ---"
  xmlstarlet sel -t -c "//pkg[@name='${PACKAGE}']" "$PATCHED" || true
  exit 1
fi

log "Pushing patched XML to the device..."
$ADB push "$PATCHED" "${REMOTE_TMP}/package-restrictions.patched.xml" >/dev/null

log "Converting XML to ABX, and verifying ABX..."
set +e
TRANSACTION_OUTPUT=$($ADB shell "$KSUD debug su" <<EOF || true
set -eu
xml2abx '${REMOTE_TMP}/package-restrictions.patched.xml' '${REMOTE_TMP}/package-restrictions.patched.abx'
abx2xml '${REMOTE_TMP}/package-restrictions.patched.abx' '${REMOTE_TMP}/verify.xml'
grep -q 'name=\"${PACKAGE}\".*inst=\"false\"' '${REMOTE_TMP}/verify.xml'
echo ABX_VERIFIED
EOF
)
set -e

# Print transaction output and verify
printf "%s\n" "$TRANSACTION_OUTPUT"
if ! grep -q "ABX_VERIFIED" <<<"$TRANSACTION_OUTPUT"; then
  if [[ -n "$TRANSACTION_OUTPUT" ]]; then
    warn "$TRANSACTION_OUTPUT"
  fi
  err "Something went wrong."
  exit 1
else
  log "Converted and verified."
fi

log "Terminating ${PACKAGE} package (if it is currently running)..."
$ADB shell "$KSUD debug su" <<EOF || true
set -eu
pid=
pidof ${PACKAGE} >/dev/null 2>&1 && pid=
pidof ${PACKAGE} || true
echo Found PID: \<\$pid\>.
[ -z "\$pid" ] || kill -9 \$pid
EOF

log "Replacing the package state..."
set +e
TRANSACTION_OUTPUT=$($ADB shell "$KSUD debug su" <<EOF || true
set -eu
echo Replacing configs...
new_main='${STATE_DIR}/package-restrictions.oobconfig-new'
new_reserve='${STATE_DIR}/package-restrictions.oobconfig-reserve-new'
cp '${REMOTE_TMP}/package-restrictions.patched.abx' "\$new_main"
cp '${REMOTE_TMP}/package-restrictions.patched.abx' "\$new_reserve"
chown system:system "\$new_main" "\$new_reserve"
chmod 660 "\$new_main" "\$new_reserve"
echo Done.
echo Calling restorecon command...
restorecon "\$new_main" "\$new_reserve"
echo Done.
echo Movinf files...
mv -f "\$new_main" '${STATE}'
mv -f "\$new_reserve" '${RESERVE}'
echo Done.
echo Deleting ${REMOTE_TMP}...
rm -rf '${REMOTE_TMP}'
echo Done.
echo Syncing...
sync
echo Done.
echo STATE_REPLACED
EOF
)
set -e

# Print transaction output and verify
printf "%s\n" "$TRANSACTION_OUTPUT"
if ! grep -q "STATE_REPLACED" <<<"$TRANSACTION_OUTPUT"; then
  if [[ -n "$TRANSACTION_OUTPUT" ]]; then
    warn "$TRANSACTION_OUTPUT"
  fi
  err "Something went wrong."
  exit 1
else
  log "The package state was replaced."
fi

log "Clearing modem rules..."
RULES_BEFORE=$(${BASE_DIR}/tools/parse_carrier_lock.sh)
log "Modem rules before:"
log "${RULES_BEFORE}"

$ADB shell "$KSUD debug su" <<EOF || true
set -eu
echo Calling \<service call phone 151\> with some params...
service call phone 151 i32 1 i32 0 i32 0 i32 1 i32 0 i32 0 i32 0 i32 0 i32 0
echo Done.
EOF
log "Modem rules cleared."

# DEBUG
$ADB shell "$KSUD debug su" <<EOF || true
set -eu
echo dmesg:
dmesg | tail -50
echo logcat:
logcat -t 50
EOF

# Reboot the device because PackageManager still has the old insalled state in memory
log "Rebooting smartphone..."
"$ADB" reboot

# Wait for the device to go down
down=0
for i in {1..30}; do
  if ! "$ADB" get-state >/dev/null 2>&1; then down=1; break; fi
  sleep 1
done
[ "$down" = 1 ] || { log "Device did not go down after reboot. Exit script."; exit 1; }
log "Device is down, waiting for boot..."

# Wait for the device to come back and finish booting
ok=0
for i in {1..120}; do
  sleep 2
  b=$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
  a=$("$ADB" shell getprop init.svc.bootanim 2>/dev/null | tr -d '\r' || true)
  if [ "$b" = "1" ] && [ "$a" = "stopped" ]; then ok=1; log "Reboot completed."; break; fi
done
[ "$ok" = 1 ] || { log "BOOT TIMEOUT. Exit script."; exit 1; }

log "Waiting 5s for the UI to settle..."
sleep 5
log "Done."

RULES_AFTER=$(${BASE_DIR}/tools/parse_carrier_lock.sh)
log "Modem rules after:"
log "${RULES_AFTER}"

log "Script finished its work."
exit 0
