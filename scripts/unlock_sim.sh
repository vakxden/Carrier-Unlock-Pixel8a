#!/bin/bash

set -o pipefail

if ! command -v adb >/dev/null 2>&1; then
  echo "Error: 'adb' not found in PATH. Install Android platform-tools and set ADB env variable." >&2
  exit 1
fi

ADB=${ADB:-adb}
BASE_DIR="$(cd "$(dirname "$0")"/.. >/dev/null 2>&1 && pwd)"
LOG=${LOG:-${BASE_DIR}/${0}.log}
KSUD="/data/local/tmp/ksud-pixel"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# redirect the whole script's output
exec > >(tee -a "$LOG") 2>&1

# 1. disable oobconfig package
RULES_BEFORE=$(${BASE_DIR}/tools/parse_carrier_lock.sh)
log "Modem rules before:"
log "${RULES_BEFORE}"

log "Disabling oobconfig package and clear modem rules..."
${BASE_DIR}/tools/oobconfig_fix.sh
log "Done."


# 2. reboot device because PackageManager still has the old insalled state in memory
log "Rebooting smartphone..."
"$ADB" reboot

# wait for the device to go down
down=0
for i in {1..30}; do
  if ! "$ADB" get-state >/dev/null 2>&1; then down=1; break; fi
  sleep 1
done
[ "$down" = 1 ] || { log "Device did not go down after reboot. Exit script."; exit 1; }
log "Device is down, waiting for boot..."

# wait for the device to come back and finish booting
ok=0
for i in {1..120}; do
  sleep 2
  b=$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
  a=$("$ADB" shell getprop init.svc.bootanim 2>/dev/null | tr -d '\r')
  if [ "$b" = "1" ] && [ "$a" = "stopped" ]; then ok=1; log "Reboot completed."; break; fi
done
[ "$ok" = 1 ] || { log "BOOT TIMEOUT. Exit script."; exit 1; }

log "Waiting 5s for the UI to settle..."
sleep 5
log "Done."

RULES_AFTER=$(${BASE_DIR}/tools/parse_carrier_lock.sh)
log "Modem rules after:"
log "${RULES_AFTER}"
