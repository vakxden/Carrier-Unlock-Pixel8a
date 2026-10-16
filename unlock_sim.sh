#!/bin/bash

set -o pipefail

if ! command -v adb >/dev/null 2>&1; then
  echo "Error: 'adb' not found in PATH. Install Android platform-tools and set ADB env variable." >&2
  exit 1
fi
# As the sript is running on Ubuntu WSL I use the adb.exe,
# because the phone is atatched to Windows PC.
# Note: Ubuntu WSL means running the Ubuntu Linux operating system 
#       directly inside Windows using the Windows Subsystem for Linux (WSL).
ADB=${ADB:-/mnt/c/platform-tools/adb.exe}
BASE=$(dirname "${0}")
LOG=${LOG:-$BASE/${0}.log}
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# redirect the whole script's output
exec > >(tee -a "$LOG") 2>&1

# 1. reboot for a cold-boot run
log "Rebooting smartphone..."
"$ADB" reboot

# wait for the device to go down, so a stale boot_completed=1 isn't read
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


###
###
###

HELPER_SRC=${BASE}/binaries/helper
APP_SRC=${BASE}/binaries/app.so
REMOTE_DIR="/data/local/tmp"
HELPER_DST=${REMOTE_DIR}/helper
APP_DST=${REMOTE_DIR}/app.so
PROGRAM_LOG=${REMOTE_DIR}/app.log

# 2. push fresh binaries (remove first so a running/busy file can't block the overwrite)
push() {
    local src=$1 dst=$2 out rc
    "$ADB" shell "rm -f $dst"
    out=$(timeout 120 "$ADB" push "$src" "$dst" 2>&1)
    rc=$?
    echo "[push $(basename "$src")] rc=$rc $out"
    return $rc
}

log "push <$HELPER_SRC> to <$HELPER_DST>"
push "$HELPER_SRC" "$HELPER_DST" || exit 1

log "push <$APP_SRC> to <$APP_DST>"
push "$APP_SRC"    "$APP_DST"    || exit 1

# make sure the helper is executable on the device
"$ADB" shell "chmod 755 $HELPER_DST"

# remove the old log
timeout 15 "$ADB" shell "rm -f $PROGRAM_LOG"


# 3. launch the app on the smartphone
launch() {
    local out err rc
    err=$(mktemp)
    out=$(timeout 420 "$ADB" shell "PSELECT_ACCEPT_NONREADY_CFI=1 exec ${HELPER_DST} --run-payload ${APP_DST} ${HELPER_DST} $PROGRAM_LOG" 2>"$err")
    rc=$?
    [ $rc -eq 124 ] && { rc=-1; echo TIMEOUT >"$err"; }   # GNU timeout returns 124
    echo "adb shell ended rc=$rc out=${out:0:200} err=$(head -c 200 "$err")"
    rm -f "$err"
    return $rc
}

launch &
launch_pid=$!

# 4. wait until the app finishes its work
# wait_for_log PATTERN [TIMEOUT_SEC]
# returns 0 = found, 1 = timeout, 2 = launcher exited without the pattern
wait_for_log() {
  local pattern=$1 timeout=${2:-120} i alive
  for ((i=0; i<timeout; i++)); do
    alive=1; kill -0 "$launch_pid" 2>/dev/null || alive=0
    if "$ADB" shell "grep -q '$pattern' $PROGRAM_LOG" 2>/dev/null; then
      return 0
    fi
    [ "$alive" = 1 ] || return 2
    sleep 1
  done
  return 1
}

log "Waiting for 'constructor returned' in $PROGRAM_LOG..."
wait_for_log "constructor returned" 120
case $? in
  0) log "App constructor returned." ;;
  1) log "TIMEOUT waiting for 'constructor returned'. Exit script."; exit 1 ;;
  2) log "App exited before printing 'constructor returned'. Exit script."; exit 1 ;;
esac

log "Waiting for the app to finish..."
wait "$launch_pid"; app_rc=$?
[ "$app_rc" -eq 0 ] || log "App ended with rc=$app_rc"

log "App finished. Post-run steps..."
"$ADB" pull "$PROGRAM_LOG" "$BASE/app.log"

# 5. verify root + read the KASLR slide printed by the payload
out=$("$ADB" shell '/apex/com.android.virt/bin/su "id; getenforce"')
log "root check: $out"
echo "$out" | grep -q "uid=0(root)" || { log "NO ROOT"; exit 2; }

slidehex=$(grep -o 'slide=0*[0-9a-f]*' $BASE/app.log 2>/dev/null | tail -1 | cut -d= -f2)
log "slide from exploit log: $slidehex"
[ -n "$slidehex" ] || { log "NO SLIDE"; exit 3; }

# 6. patch the KSUN LKM: undefined imports -> SHN_ABS with runtime addresses
#./modules/patch_ko.py ./modules/android14-6.1_kernelsu_v3.3.0.ko ./modules/kernelsu-patched.ko ./modules/akita-CP2A.260805.005.ksym.tsv ${slidehex}
log "Patching the kernel module..."
./modules/patcher.sh ./modules/android14-6.1_kernelsu_v3.3.0.ko ./modules/kernelsu-patched.ko ./modules/akita-CP2A.260805.005.ksym.tsv ${slidehex}

# 7. push + insmod with allow_shell=1 (shell gets root via KSU)
log "push <$BASE/modules/kernelsu-patched.ko> to <${REMOTE_DIR}/ksu-patched.ko>"
"$ADB" push "$BASE/modules/kernelsu-patched.ko" "${REMOTE_DIR}/ksu-patched.ko" >/dev/null

log "push <$BASE/modules/ksud-pixel> to <${REMOTE_DIR}/ksud-pixel>"
"$ADB" push "$BASE/modules/ksud-pixel" "${REMOTE_DIR}/ksud-pixel" >/dev/null
"$ADB" shell "chmod 755 ${REMOTE_DIR}/ksud-pixel"

log "insmod allow_shell=1..."
ins=$("$ADB" shell "$REMOTE_DIR/su insmod $REMOTE_DIR/ksu-patched.ko allow_shell=1 2>&1; echo rc=\$?")

log "insmod: $ins"
echo "$ins" | grep -q "rc=0" || exit 5

# 8. verify: module live + root via ksud su works even with SELinux enforcing
sleep 2
mod=$("$ADB" shell "grep kernelsu /proc/modules")
log "module: $mod"
echo "$mod" | grep -q kernelsu || exit 6
su_output=$("$ADB" -s "$S" shell "echo 'id; getenforce; echo KSU_ROOT_OK' | ${REMOTE_DIR}/ksud-pixel debug su 2>&1")
log "ksud su output: $su_output"
echo "$su_output" | grep -q KSU_ROOT_OK && log "=== FULL PIPELINE SUCCESS ===" || log "=== KSU SU FAILED ==="

# 9. "unlock" SIM
./tools/carrier-unlock/oobconfig_fix.sh
