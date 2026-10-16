#!/usr/bin/env bash
# Remove the confirmed OobConfig carrier-lock enforcer for Android user 0.
set -euo pipefail

PACKAGE="com.google.android.apps.work.oobconfig"
SUPPORTED_DEVICE="akita"
SUPPORTED_BUILD="CP2A.260805.005"
REMOTE_TMP="/data/local/tmp/oobconfig-fix"
KSUD="/data/local/tmp/ksud-pixel"

log() { printf "[%s] %s\n" "$(date +%T)" "$*"; }
err() { printf "ERROR: %s\n" "$*" >&2; }
warn() { printf "WARNING: %s\n" "$*" >&2; }

# Find adb
ADB=${ADB:-/mnt/c/platform-tools/adb.exe}
if [[ "$ADB" == "adb" && ! -x "$(command -v adb 2>/dev/null || true)" ]]; then
  for candidate in \
    "/usr/local/share/android-commandlinetools/platform-tools/adb" \
    "$HOME/Library/Android/sdk/platform-tools/adb"; do
    if [[ -x "$candidate" ]]; then
      ADB="$candidate"
      break
    fi
  done
fi
if ! command -v "$ADB" >/dev/null 2>&1; then
  err "adb not found: $ADB"
  exit 1
fi

# xmlstarlet is required for safe XML edits
if ! command -v xmlstarlet >/dev/null 2>&1; then
  err "xmlstarlet is required but not found. Install xmlstarlet and retry."
  exit 1
fi

BASE_DIR="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd)"
HELPER_JAR="$BASE_DIR/carrier-unlock.jar"
if [[ ! -f "$HELPER_JAR" ]]; then
  err "missing $HELPER_JAR; run tools/carrier-unlock/build.sh first"
  exit 1
fi

log "Applying oobconfig fix..."

# Ensure device is booted
BOOTED="$($ADB shell getprop sys.boot_completed 2>/dev/null || true)"
BOOTED="$(echo "$BOOTED" | tr -d '\r')"
if [[ "$BOOTED" != "1" ]]; then
  err "device is not fully booted"
  exit 1
fi

DEVICE="$($ADB shell getprop ro.product.device 2>/dev/null | tr -d '\r')"
BUILD="$($ADB shell getprop ro.build.display.id 2>/dev/null | tr -d '\r')"
log "device=${DEVICE} build=${BUILD}"
if [[ "$DEVICE" != "$SUPPORTED_DEVICE" || "$BUILD" != "$SUPPORTED_BUILD" ]]; then
  err "supported only on ${SUPPORTED_DEVICE}/${SUPPORTED_BUILD}; aborting"
  exit 1
fi

# Verify KernelSU root via ksud
ROOT_ID="$($ADB shell "$KSUD debug su" <<'EOF'
id
EOF
)"
ROOT_ID="$(echo "$ROOT_ID" | tr -d '\r')"
log "root=${ROOT_ID}"
if ! grep -q "uid=0(root)" <<<"$ROOT_ID"; then
  err "KernelSU root is not active"
  exit 1
fi

USER_ID=0
INSTALLED="$($ADB shell "pm list packages --user ${USER_ID} ${PACKAGE}" 2>/dev/null || true)"
if ! grep -q "package:${PACKAGE}" <<<"$INSTALLED"; then
  log "${PACKAGE} is already absent for user ${USER_ID}"
  exit 0
fi

STATE_DIR="/data/system/users/${USER_ID}"
STATE="${STATE_DIR}/package-restrictions.xml"
RESERVE="${STATE}.reservecopy"
STAMP="$(date +%Y%m%d-%H%M%S)"

TMPDIR="$(mktemp -d -t oobconfig-fix-XXXXXX)"
cleanup_local() { rm -rf "$TMPDIR" || true; }
trap cleanup_local EXIT

PLAIN="$TMPDIR/package-restrictions.xml"
PATCHED="$TMPDIR/package-restrictions.patched.xml"

state_replaced=0

# Run preparation on-device: disable network, backup state, convert ABX->XML into REMOTE_TMP
log "disabling Wi-Fi and staging package state..."
set +e
$ADB shell "$KSUD debug su" <<EOF
set -eu
svc wifi disable
svc data disable
am force-stop ${PACKAGE} || true
rm -rf ${REMOTE_TMP}
mkdir -p ${REMOTE_TMP}
cp ${STATE} ${STATE_DIR}/package-restrictions.oobconfig-${STAMP}.bak
if [ -f ${RESERVE} ]; then
  cp ${RESERVE} ${STATE_DIR}/package-restrictions.oobconfig-${STAMP}.reservecopy.bak
fi
abx2xml ${STATE} ${REMOTE_TMP}/package-restrictions.xml
chmod 644 ${REMOTE_TMP}/package-restrictions.xml
EOF
if [[ $? -ne 0 ]]; then
  err "failed to prepare device state; ensure abx2xml exists on device and ksud is usable"
  exit 1
fi
set -e

log "pulling package-restrictions.xml to $PLAIN"
$ADB pull "${REMOTE_TMP}/package-restrictions.xml" "$PLAIN" >/dev/null

# Patch XML using robust XPath; ensure attributes inst/stopped/nl exist, then set them
log "patching package state locally"
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
  err "expected package entry to be patched, found ${COUNT}"
  echo "--- patched XML preview ---"
  xmlstarlet sel -t -c "//pkg[@name='${PACKAGE}']" "$PATCHED" || true
  exit 1
fi

log "pushing patched xml and helper jar to device"
$ADB push "$PATCHED" "${REMOTE_TMP}/package-restrictions.patched.xml" >/dev/null
$ADB push "$HELPER_JAR" "${REMOTE_TMP}/carrier-unlock.jar" >/dev/null

log "verifying ABX, clearing carrier rules, and replacing package state..."
set +e
TRANSACTION_OUTPUT=$($ADB shell "$KSUD debug su" <<EOF || true
set -eu
xml2abx '${REMOTE_TMP}/package-restrictions.patched.xml' '${REMOTE_TMP}/package-restrictions.patched.abx'
abx2xml '${REMOTE_TMP}/package-restrictions.patched.abx' '${REMOTE_TMP}/verify.xml'
grep -q 'name=\"${PACKAGE}\".*inst=\"false\"' '${REMOTE_TMP}/verify.xml'

pid=
pidof ${PACKAGE} >/dev/null 2>&1 && pid=
pidof ${PACKAGE} || true
[ -z "\$pid" ] || kill -9 \$pid
CLASSPATH='${REMOTE_TMP}/carrier-unlock.jar' app_process / CarrierUnlock clear

new_main='${STATE_DIR}/package-restrictions.oobconfig-new'
new_reserve='${STATE_DIR}/package-restrictions.oobconfig-reserve-new'
cp '${REMOTE_TMP}/package-restrictions.patched.abx' "\$new_main"
cp '${REMOTE_TMP}/package-restrictions.patched.abx' "\$new_reserve"
chown system:system "\$new_main" "\$new_reserve"
chmod 660 "\$new_main" "\$new_reserve"
restorecon "\$new_main" "\$new_reserve"
mv -f "\$new_main" '${STATE}'
mv -f "\$new_reserve" '${RESERVE}'
rm -rf '${REMOTE_TMP}'
sync
echo STATE_REPLACED
(reboot) >/dev/null 2>&1 &
EOF
)
set -e

# Print transaction output and verify
printf "%s\n" "$TRANSACTION_OUTPUT"
if ! grep -q "STATE_REPLACED" <<<"$TRANSACTION_OUTPUT"; then
  if [[ -n "$TRANSACTION_OUTPUT" ]]; then
    warn "$TRANSACTION_OUTPUT"
  fi
  # cleanup/network restore attempt
  warn "root transaction did not confirm state replacement; attempting network restore/cleanup"
  set +e
  $ADB shell "$KSUD debug su" <<EOF || true
svc wifi enable; svc data enable; rm -rf '${REMOTE_TMP}'
EOF
  set -e
  err "root transaction failed or did not confirm state replacement"
  exit 1
fi

state_replaced=1
log "package state replaced; root shell requested immediate reboot"
exit 0
