# Carrier-Unlock-Pixel8a

This repo contains a practical solution to unlock a carrier-locked Google Pixel 8a device.

The solution described in this repository is implemented entirely as shell scripts.
There are no Python or Java sources in this project; only shell-based automation and device manipulation steps are used.

The solution was inspired by:
- https://github.com/alex193a/Root-My-Pixel
- https://github.com/DurkaEbanaya/Root-My-Pixel-Pixel6a

This is the only known working solution for Google Pixel 8a (akita, build id: CP2A.260805.005).
The phone was locked to the T-Mobile US / Sprint network ecosystem, but configured to allow specific virtual operators (MVNOs) and sub-brands via GID1 (Group Identifier 1) codes.

What it does:
1. `./scripts/get_root.sh` gets root on the locked device in two stages:
   - stage 1: obtains root using the CVE-2026-43499 exploit (`context=u:r:kernel:s0`)
   - stage 2: uses the KASLR slide method and inserts the KernelSU-Next module (`context=u:r:ksu:s0`)

2. `./scripts/unlock_sim.sh` unlocks the carrier-locked device in two stages:
   - stage 1: disables the oobconfig application
   - stage 2: clears modem carrier restriction rules

Third-party files:
- `./third_party/kernelsu-next/bin/ksud-pixel` - extracted from assets in Root-My-Pixel: `assets/ksud/ksud`
- `./third_party/exploit/akita-CP2A.260805.005.so` - extracted from assets in Root-My-Pixel: `assets/exploits/akita-CP2A.260805.005.so`
- `./third_party/exploit/exploit-helper` - taken from Root-My-Pixel-Pixel6a: `binaries/cve-2026-43499-root`
- `./third_party/kernel-symbols/akita-CP2A.260805.005.ksym.tsv` - extracted from the Pixel 8a kernel image
- `./third_party/kernelsu-next/modules/android14-6.1_kernelsu_v3.3.0.ko` - taken from Root-My-Pixel-Pixel6a: `ksun/android14-6.1_kernelsu_v3.3.0.ko`

Example successful root log (`./scripts/get_root.sh`):

```bash
$ ./get_root.sh
[20:11:12] Rebooting smartphone...
[20:11:18] Device is down, waiting for boot...
[20:11:32] Reboot completed.
[20:11:32] Waiting 5s for the UI to settle...
[20:11:37] Done.
[20:11:37] Pushing exploit and helper to the device...
[push akita-CP2A.260805.005.so] rc=0 ./third_party/exploit/akita-CP2A.260805.005.so: 1 file pushed, 0 skipped.
[push exploit-helper] rc=0 ./third_party/exploit/exploit-helper: 1 file pushed, 0 skipped.
[20:11:37] Waiting for the 'constructor returned' pattern in exploit log...
adb shell ended rc=0 out= err=
[20:13:36] App constructor returned.
[20:13:36] Waiting for the exploit to finish...
[20:13:36] Exploit finished. Post-run steps...
/data/local/tmp/exploit.log: 1 file pulled, 0 skipped.
[20:13:36] Verified root: uid=0(root) gid=0(root) groups=0(root),1004(input),1007(log),1011(adb),1015(sdcard_rw),1028(sdcard_r),1078(ext_data_rw),1079(ext_obb_rw),3001(net_bt_admin),3002(net_bt),3003(inet),3006(net_bw_stats),3009(readproc),3011(uhid),3012(readtracefs) context=u:r:kernel:s0
Permissive
[20:13:36] The slide from exploit log: 0000001109200000
[20:13:36] Patching the kernel module...
patched=209 missing=0
[20:13:45] The kernel module has been patched.
[20:13:45] Pushing patched module...
[20:13:45] Pushing ksud-pixel...
[20:13:46] Executing <insmod allow_shell=1> command...
[20:13:46] The <insmod allow_shell=1> command output: rc=0
[20:13:48] Verifying the <kernelsu> module on the device: kernelsu 319488 0 - Live 0x0000000000000000 (O)
[20:13:48] Executing <ksud-pixel su> command...
[20:13:48] The <ksud-pixel su> output: uid=0(root) gid=0(root) groups=0(root) context=u:r:ksu:s0
Enforcing
KSU_ROOT_OK
[20:13:48] === ROOT PIPELINE SUCCESS ===
```

Example successful unlock log (`./scripts/unlock_sim.sh`):

```bash
$ ./unlock_sim.sh
[20:14:33.250231339] Device: akita; Build: CP2A.260805.005
[20:14:33.387637895] root=uid=0(root) gid=0(root) groups=0(root) context=u:r:ksu:s0
[20:14:33.576421943] Disabling com.google.android.apps.work.oobconfig package...
[20:14:33.579398228] Disabling Wi-Fi and staging package state...
Disabling WiFi...
Done.
Disabling data...
Done.
Stoping com.google.android.apps.work.oobconfig...
Done.
Making backups...
- Creating /data/local/tmp/oobconfig-fix...
- Done.
- Copying /data/system/users/0/package-restrictions.xml to /data/system/users/0/package-restrictions.oobconfig-20261020-201433.bak...
- Done.
- Copying /data/system/users/0/package-restrictions.xml.reservecopy to /data/system/users/0/package-restrictions.oobconfig-20261020-201433.reservecopy.bak...
- Done.
Backups created.
Converting ABX to XML...
Done.
[20:14:34.558747327] Pulling package-restrictions.xml to /tmp/oobconfig-fix/package-restrictions.xml...
[20:14:34.583999983] Patching package state locally...
[20:14:34.599925821] Pushing patched XML to the device...
[20:14:34.615543355] Converting XML to ABX, and verifying ABX...
ABX_VERIFIED
[20:14:35.512180718] Converted and verified.
[20:14:35.513140933] Terminating com.google.android.apps.work.oobconfig package (if it is currently running)...
Found PID: <>.
[20:14:35.761220160] Clearing modem rules...
[20:14:35.931364767] Modem rules before:
===========================================================
CARRIER RESTRICTION RULES
===========================================================
Allowed carriers: 9
...
Restriction Status        : 2 (RESTRICTED)
...
===========================================================
Calling <service call phone 151> with some params...
Result: Parcel( 00000000 00000000   '........')
Done.
[20:14:36.145379511] Modem rules cleared.
[20:14:39.147401109] Replacing the package state...
Replacing configs...
Done.
Calling restorecon command...
Done.
Moving files...
Done.
Deleting /data/local/tmp/oobconfig-fix...
Done.
Syncing...
Done.
STATE_REPLACED
[20:14:39.571628628] The package state was replaced.
[20:14:39.669086160] Modem rules after:
===========================================================
CARRIER RESTRICTION RULES
===========================================================
Allowed carriers: 0
Excluded carriers: 0
Policy Config Default Type: 1 (CARRIER_RESTRICTION_DEFAULT_ALLOWED)
Multi-SIM Behavior Policy : 0 (MULTISIM_POLICY_NONE)
Restriction Status        : 1 (NOT_RESTRICTED)
Allowed CarrierInfo list: 0
Excluded CarrierInfo list: 0
Use Carrier Lock Info     : true
===========================================================
[20:14:39.671051617] Rebooting smartphone...
[20:14:46.588958916] Device is down, waiting for boot...
[20:15:00.770918539] Reboot completed.
[20:15:00.772055406] Waiting 5s for the UI to settle...
[20:15:05.774274946] Done.
[20:15:05.939711081] Modem rules after reboot:
===========================================================
CARRIER RESTRICTION RULES
===========================================================
Allowed carriers: 0
Excluded carriers: 0
Policy Config Default Type: 1 (CARRIER_RESTRICTION_DEFAULT_ALLOWED)
Multi-SIM Behavior Policy : 0 (MULTISIM_POLICY_NONE)
Restriction Status        : 1 (NOT_RESTRICTED)
Allowed CarrierInfo list: 0
Excluded CarrierInfo list: 0
Use Carrier Lock Info     : true
===========================================================
[20:15:05.941732765] Script finished its work.
```

Test environment:
- OS: Debian GNU/Linux 12 (bookworm)
- Tested on: a Debian 12 host machine used for validation and device interaction

Credits:
- Root-My-Pixel: https://github.com/alex193a/Root-My-Pixel
- Root-My-Pixel-Pixel6a: https://github.com/DurkaEbanaya/Root-My-Pixel-Pixel6a

