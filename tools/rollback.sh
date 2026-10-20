#!/usr/bin/env bash
# rollback from good-known file
set -euo pipefail

ADB=${ADB:-adb}
BASE_DIR="$(cd "$(dirname "$0")"/.. >/dev/null 2>&1 && pwd)"
KSUD="/data/local/tmp/ksud-pixel"
PACKAGE="com.google.android.apps.work.oobconfig"
BACKUP_FILE="/data/system/users/0/package-restrictions.oobconfig-20261020-201433.reservecopy.bak"
LOG=${LOG:-${BASE_DIR}/${0}.log}

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# Redirect the whole script's output to log file
exec > >(tee -a "$LOG") 2>&1

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

# run rollback transaction
log "Starting roll back from file: ${BACKUP_FILE}"
$ADB shell "$KSUD debug su" <<EOF || true
set -eu
echo disabling wifi...
svc wifi disable
echo disabling data...
svc data disable
echo stopping ${PACKAGE}...
am force-stop ${PACKAGE}
echo replacing configs...
rm -rf /data/local/tmp/oobconfig-fix
mkdir /data/local/tmp/oobconfig-fix
cp ${BACKUP_FILE} /data/local/tmp/oobconfig-fix/package-restrictions.xml
cp /data/local/tmp/oobconfig-fix/package-restrictions.xml /data/system/users/0/package-restrictions.oobconfig-reserve-new                                      
cp /data/local/tmp/oobconfig-fix/package-restrictions.xml /data/system/users/0/package-restrictions.oobconfig-new
chown system:system /data/system/users/0/package-restrictions.oobconfig-new /data/system/users/0/package-restrictions.oobconfig-reserve-new
chmod 660 /data/system/users/0/package-restrictions.oobconfig-new /data/system/users/0/package-restrictions.oobconfig-reserve-new
echo calling restorecon command...
restorecon /data/system/users/0/package-restrictions.oobconfig-new /data/system/users/0/package-restrictions.oobconfig-reserve-new
mv -f /data/system/users/0/package-restrictions.oobconfig-new /data/system/users/0/package-restrictions.xml
mv -f /data/system/users/0/package-restrictions.oobconfig-reserve-new /data/system/users/0/package-restrictions.xml.reservecopy                            
echo syncyng...
sync
echo rebooting...
(reboot) >/dev/null 2>&1 &
EOF
log "Rollback done."
exit 0
