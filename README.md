# Self-ADB for Android 9 — run ADB on **your own phone** from Termux

**No root. No Magisk. No Xposed. No LSPosed. No custom kernel. Nothing flashed.**

`selfadb.sh` is a single-file tool that makes `adb` work *inside Termux*, talking to the
same phone Termux is running on. Once connected you get a real `adb shell` on your own
device — install APKs, grant permissions, change settings, uninstall bloat, screenshot,
`input tap`, `pm`/`am`/`cmd`, `dumpsys`, pull/push files — all from the Termux prompt.

Built and documented with an **Infinix HOT 8 (X650C, Android 9 / XOS)** in mind, but it
works on any Android 5+ phone.

---

## Read this first: the honest truth about Android 9

You asked for "no root, no PC, just make adb work". Here is exactly what is and is not
possible, so you don't waste hours:

| | Reality on stock Android 9 without root |
|---|---|
| `adb devices` shows nothing after `adb start-server` | **Normal.** `adbd` (the daemon inside Android) is in **USB-only mode**, so there is nothing on the network to connect to. |
| Turn TCP mode on from inside the phone | **Impossible without root.** `service.adb.tcp.port` can only be written by `adbd`/root. There is no on-device switch in Android 9 — "Wireless debugging + pairing code" only exists on **Android 11+**. |
| Doing it without a computer at all | **Not possible on stock Android 9 without root.** This is an Android security design, not a limitation of this tool. |
| What *is* possible | **One 60-second step with any PC + USB cable, then everything runs inside Termux.** After that you never touch a PC again — until you reboot the phone. |

So the flow this tool automates is:

```
[ once per boot, ~60 s with a PC ]   adb tcpip 5555
                │
                ▼
[ every day, 100 % inside Termux ]   selfadb.sh connect
                                     selfadb.sh shell          ← adb on your own phone
                                     selfadb.sh watch          ← auto-reconnect forever
```

Two useful consequences of that one PC step:

* **You don't need the PC to stay connected.** Unplug the cable, leave the PC off.
* **Wi-Fi changes don't matter.** New network, new IP, hotspot, Wi-Fi off/on → the tool
  finds adbd again automatically. Only a **reboot** sends adbd back to USB-only mode.

---

## Quick start (Termux on the phone)

```bash
# 1. get the tool
git clone https://github.com/rizwanahmedsora9-pixel/Self-Adb-For-Android-9
cd Self-Adb-For-Android-9
bash selfadb.sh setup          # installs android-tools + python, adds 'selfadb' to PATH

# 2. find out what state your phone is in (this always works, no cable needed)
bash selfadb.sh doctor

# 3. if doctor says "USB-only"  ->  do the one-time PC step it prints:
bash selfadb.sh one-time

# 4. back in Termux, cable unplugged:
bash selfadb.sh connect
bash selfadb.sh shell
```

`setup` copies the tool to `$PREFIX/bin/selfadb`, so after step 1 you can just type
`selfadb doctor`, `selfadb connect`, … instead of `bash selfadb.sh …`.

---

## The one-time step (60 seconds, any PC, **nothing gets installed on your phone**)

**On the phone**

1. Settings → About phone → tap **Build number** 7 times (on XOS: Settings → System → About phone).
2. Settings → System → **Developer options**:
   * **USB debugging** → ON
   * **Install via USB** → ON (Infinix/XOS shows this; needs you signed in)
   * **USB debugging (Security settings)** → ON
     *This is the XOS-specific one. Without it, `adb` cannot change secure settings,
     grant permissions or simulate taps. Turn it on if you want `selfadb.sh keepawake`,
     `pm grant`, `settings put …` to actually work.*
3. Plug the phone into the PC with a **data** cable, choose *File transfer (MTP)* if asked.

**On the PC** (Windows / macOS / Linux — install platform-tools, no Android Studio needed)

```text
Windows: https://dl.google.com/android/repository/platform-tools-latest-windows.zip
macOS:   https://dl.google.com/android/repository/platform-tools-latest-darwin.zip
Linux:   https://dl.google.com/android/repository/platform-tools-latest-linux.zip
   or:   winget install Google.PlatformTools
         brew install android-platform-tools
         sudo apt install android-tools-adb
```

Then, in the folder where you extracted it:

```bash
adb devices          # phone pops "Allow USB debugging?"  ->  tap Allow, tick "Always allow"
adb tcpip 5555       # prints: restarting in TCP mode port: 5555
```

Unplug the cable. **That's it — the PC is now unnecessary.**

`adb devices` shows nothing on the PC? → try another cable (charge-only cables are
everywhere), toggle USB debugging off/on, choose MTP, or reinstall the OEM USB driver.

---

## Command reference

| Command | What it does |
|---|---|
| `selfadb.sh` (no args) | one-screen summary + the next action you should take |
| `selfadb.sh setup` | installs `android-tools`, `python`, `termux-api`, registers `selfadb` in PATH |
| `selfadb.sh doctor` | full diagnosis: adb version, phone IP, `adbd` state, TCP port, `adb devices`. Exit code 0 = ready |
| `selfadb.sh one-time` | the printed walkthrough for the 60-second PC step |
| `selfadb.sh connect [host:port]` | finds adbd (saved target → `127.0.0.1` → Wi-Fi IP → gateway → LAN scan) and connects |
| `selfadb.sh status` | connection + brand/model/Android version/uid of the phone |
| `selfadb.sh shell [cmd]` | **`adb shell` on your own phone** (interactive if you give no command) |
| `selfadb.sh install app.apk` | `adb install -r -g` (installs *and* grants all runtime permissions) |
| `selfadb.sh keepawake` | stops Wi-Fi from sleeping, whitelists Termux from Doze, keeps screen on while charging |
| `selfadb.sh scan [port]` | sweeps your subnet for something listening on the port |
| `selfadb.sh tcpip [port]` | re-arms/changes the TCP port **using the existing connection** (no PC) |
| `selfadb.sh usb` | closes the network port again (`adb usb`) |
| `selfadb.sh watch` | auto-reconnect loop; survives Wi-Fi drops, sleeps, Doze |
| `selfadb.sh boot-install` | Termux:Boot script + Termux:Widget one-tap shortcut |
| `selfadb.sh shizuku` | launches Shizuku via this adb connection (gives apps ADB powers, still no root) |
| `selfadb.sh pair IP:PORT CODE` | **Android 11+**: pair with the wireless-debugging dialog — no PC at all |
| `selfadb.sh wireless [IP:PORT]` | **Android 11+**: connect to wireless debugging (mDNS auto-discovery) |
| `selfadb.sh rom-probe` | read-only hunt for a hidden on-device network-ADB switch; verdict on whether you ever need the PC again |
| `selfadb.sh unlock` | probes whether your ROM is loose enough to enable TCP mode without a PC (usually: no) |
| `selfadb.sh disconnect` | drops the network connection |
| `selfadb.sh help` | all of the above, on the device |

Options: `--port N` (or `SELFADB_PORT`), `--restart` (kill + restart the Termux-side
server), `-q/--quiet`, `NO_COLOR=1`, `SELFADB_INTERVAL=N` (watch poll seconds).

---

## "Do I need the PC again?" — what survives a reboot

**Yes for a reboot, no for anything else.** This is the single most common question, so
here is the exact matrix:

| What happened | PC needed again? | Why |
|---|---|---|
| **Full reboot** / power off / battery died / OTA update / crash | **YES** — ~60 s with any computer | `service.adb.tcp.port` lives in RAM only; at boot `init` starts `adbd` in USB-only mode. Making it stick needs `persist.adb.tcp.port`, which only root/`init` may write on a user build. |
| Wi-Fi off/on, new router, new IP, hotspot, mobile hotspot | No | `selfadb.sh connect` re-finds adbd on the new address |
| Termux app closed, killed by XOS, phone memory cleaned | No | adbd is still in TCP mode; just `selfadb.sh connect` again |
| `adb kill-server` (Termux side) | No | the phone's daemon was never touched |
| Screen lock, Doze, battery saver, phone idle for hours | No | `selfadb.sh watch` + battery "Unrestricted" keeps it alive |
| Airplane mode toggle | No (usually) | adbd re-binds when Wi-Fi returns; the tool reconnects |
| `selfadb.sh tcpip` while already connected | No | re-arms TCP mode over the live connection |
| Soft reboot / `adb reboot` | **YES** | same as a full reboot for adbd |

### The two ways to never need the PC again

Both are rare on Android 9, both are checkable on *your* phone in 10 seconds:

```bash
selfadb.sh rom-probe      # read-only: hunts for an on-device switch, prints a verdict
selfadb.sh doctor         # shows persist.adb.tcp.port if your ROM happens to set it
```

1. **`persist.adb.tcp.port` is set** (some engineering/vendor/serviced builds) → adbd comes
   up in TCP mode by itself at every boot. `rom-probe` will say *"this ROM keeps TCP mode
   across reboots"*. Nothing left to do, ever.
2. **Your ROM kept an "ADB over network" / "Wireless debugging" toggle** in Developer
   options (MediaTek ROMs sometimes do even on Android 9) → flip it on and you are done for
   good. `rom-probe` lists any wireless-debug settings keys it finds; also just scroll
   Developer options by hand and look for:
   `ADB over network`, `Network ADB`, `Wireless ADB`, `ADB over Wi-Fi`, `Wi-Fi debugging`,
   `Wireless debugging`, `Debug over network`.

If `rom-probe` says *"no on-device switch found"* (most likely on stock XOS 5.0), then it is
**PC once per reboot** — that is the Android 9 design, and nothing below root can change it.

> Practical tip: the one-time step needs *any* computer with a USB data cable and adb — a
> friend's laptop, a cyber-café PC, a cheap Windows stick or a Raspberry Pi all work. Keep
> the cable in your bag and the step takes under a minute. Also avoid unnecessary reboots:
> a phone that stays powered stays connected indefinitely.

---

## Would installing Android 11 fix the "PC every reboot" problem?

**Yes — that is the one real fix, and it is why people put a custom ROM/GSI on this phone.**
Android 11 introduced **Wireless debugging with pairing**: the phone itself starts listening
and shows you a pairing code, so Termux pairs with it directly. No PC, no cable, ever again.

```bash
selfadb.sh pair 192.168.1.42:37123 481920   # ip:port + 6-digit code from the phone dialog
selfadb.sh wireless                          # connects (auto-discovers the port via mDNS)
```

The catch: your X650C ships Android 9 and Infinix never released 11 for it. To get Android 11
you must **flash a custom ROM or a GSI** (Generic System Image) yourself.

### What the X650C community has proven (so you don't learn it the hard way)

| Fact | Detail |
|---|---|
| Bootloader | unlockable: `fastboot flashing unlock` (enable *OEM unlocking* first; **wipes all data**) |
| Chipset | MT6761 Helio A22 (2/32 GB) or MT6762 Helio P22 (4/64 GB), PowerVR GE8320 — MediaTek |
| Method that works | GSI: format `system-<arch>-<scheme>-<flavour>.img` |
| Your arch/scheme | **`arm32_binder64`** (64-bit kernel, 32-bit userspace) + **A-only** — `amsrom.sh` detects this for you |
| Most stable build reported | DOT OS 5.2 (Android 11 era); Android 12 GSIs boot too |
| Broken on Android 12 GSIs | Wi-Fi hotspot, USB tethering, Bluetooth tethering |
| VoLTE / mobile data | needs an IMS APK installed afterwards |
| Mandatory step | `fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img`, or you get a boot loop |
| Keep handy | stock firmware + scatter file + SP Flash Tool (MTK unbrick path), and a dump of `nvram`/IMEI |

**Risks, honestly:** unlocking wipes the phone and shows the "orange state" warning; Play
Integrity/Widevine L1 break; a bad flash can brick an MTK device (that is why the unbrick
files matter); and after flashing you own the bugs — no Infinix support. It is a weekend
project, not a 10-minute tweak.

**Recommendation:** keep Android 9 + `selfadb.sh` for daily use (one PC step per reboot,
everything else is on-device), and only go the GSI route if you specifically want Android 11+
features — wireless debugging without a PC, newer apps, security patches.

---

## AMS ROM — hardware analysis + custom-ROM project generator

`amsrom.sh` answers "what exactly is inside my phone, and what would a ROM for it need?"
It reads your device with read-only commands, analyses the result, and writes a ready-to-fill
project folder:

```bash
# on the phone (no PC needed):
bash amsrom.sh all --dir "AMS ROM"

# or with a live adb connection, which adds the deep dumps a device tree needs:
bash selfadb.sh connect && bash amsrom.sh all --serial 127.0.0.1:5555 --dir "AMS ROM"

bash amsrom.sh info          # quick summary of the last analysis
```

### What it creates

```
AMS ROM/
├── README.md                  analysis summary + roadmap + warnings
├── hardware/
│   ├── report.md              human-readable analysis of YOUR device
│   ├── profile.json           the same data, machine-readable
│   ├── facts.kv               flat key=value facts the scripts use
│   └── raw/*.txt              every raw dump (36 files in deep mode), untouched
├── device/<vendor>/<codename>/  AOSP-style device tree skeleton
│   ├── BoardConfig.mk         arch, platform, kernel cmdline, partitions (TODO-marked)
│   ├── device.mk · AndroidProducts.mk · ams_<codename>.mk · vendorsetup.sh
├── gsi/
│   ├── candidates.md          which GSI images match YOUR arch/scheme + known bugs
│   └── flash-gsi.sh           flashing helper — DRY RUN unless you pass the confirm flag
├── build/build-rom.sh         source-build wrapper (naming skeleton)
└── backups/README.md          what to save BEFORE unlocking/flashing
```

### What it extracts

Identity (brand/model/codename/build/fingerprint), SoC family and marketing name
(MT6761 = Helio A22, MT6762 = Helio P22), CPU cores, ABI list, kernel version and machine
(aarch64 vs armv7), RAM, storage, display size/density, GPU renderer, camera and sensor
counts, the full partition table (including `nvram`, `preloader`, `vbmeta`, `md1img`),
A-only vs A/B, dynamic partitions, system-as-root, verified-boot/verity state, SELinux mode,
Treble + VNDK availability and the HAL inventory — plus every raw dump for proof.

From that it derives the three things a port actually needs: **arch class for GSI**
(`arm64` / `arm32_binder64` / `arm`), **partition scheme** (`aonly` / `ab`), and a
**verdict** — GSI route (fast, mostly works) vs source-port route (weeks of kernel work).

**It never writes to your phone.** The only script that can write is `gsi/flash-gsi.sh`, and
it prints a plan and refuses to act without `--yes-i-know-i-can-brick`; it will not touch
`preloader`, `lk`, `tee`, `md1img` or `modem` under any circumstances.

See `docs/sample-report.md` for a real generated report (from the X650C profile used in the
test suite).

---

## Staying connected (this is the part that matters)

Android aggressively kills background apps, and Infinix/XOS kills them *twice*.

```bash
# terminal 1 — keep the link alive and heal it automatically
selfadb.sh watch            # hold a wake lock, reconnect on loss, back off up to 2 min
```

Do these once in the phone's UI (no root needed):

* Settings → Apps → Termux → **Battery → Unrestricted / No restrictions**
* Settings → Apps → Termux → **Auto-start → ON**
* Settings → Battery → **Power saving mode OFF** (XOS throttles everything otherwise)
* Install the **Termux:Boot** app, open it once, then `selfadb.sh boot-install`
* Optional: **Termux:Widget** gives you a home-screen button that runs `adb-connect.sh`

`selfadb.sh keepawake` handles the device side over adb
(`wifi_sleep_policy=2`, `cmd deviceidle whitelist +com.termux`, `stay_on_while_plugged_in`).

> After a reboot adbd is USB-only again, so the boot script can only *reconnect* if you
> (or a root/vendor setting) kept TCP mode on. On a stock Android 9 phone, plan on the
> 60-second PC step once per reboot. `selfadb.sh tcpip` is the no-PC way to re-arm it
> while a connection already exists.

---

## What you can do once it is connected

```bash
selfadb.sh shell                                    # interactive shell on your phone
selfadb.sh shell pm list packages -3                # every app you installed
selfadb.sh shell pm uninstall -k --user 0 com.xos.bloat   # remove bloat (no root!)
selfadb.sh shell pm grant com.app.pkg android.permission.WRITE_SECURE_SETTINGS
selfadb.sh shell settings put global policy_control immersive.full=*
selfadb.sh shell input keyevent KEYCODE_POWER
selfadb.sh shell screencap -p /sdcard/s.png && selfadb.sh shell ls /sdcard/s.png
selfadb.sh shell cmd wifi set-wifi-enabled disabled
selfadb.sh shell dumpsys battery | head
selfadb.sh install ~/storage/downloads/app.apk     # -r -g: replace + grant everything
```

Everything you can do with `adb` on a PC, you can now do from the Termux prompt —
because Termux *is* the ADB host and the phone is the device.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `adb devices` → empty list, `doctor` says *USB-only* | Normal on Android 9 after a reboot. Run the one-time PC step: `selfadb.sh one-time` |
| `device unauthorized` | Look at the phone: tap **Allow** (+ "Always allow"). Then `adb kill-server && selfadb.sh connect` |
| `device offline` | `selfadb.sh disconnect`, toggle Wi-Fi, retry. If it persists: reboot the phone and redo the one-time step |
| `failed to connect … Connection refused` | adbd is not listening on that port (USB-only, or a different port). `selfadb.sh doctor` shows the real port |
| `Connection timed out` | Wrong IP, client isolation on the router, or a VPN. Try `selfadb.sh connect 127.0.0.1:5555`; turn off VPN |
| Works after `connect` but dies in the background | It's the ROM killing Termux: wake lock (`selfadb.sh watch`), battery "Unrestricted", disable XOS power saving |
| `adb: inaccessible or not found` | `selfadb.sh setup` (or `pkg install android-tools`) |
| `Permission denied` / settings changes do nothing | Turn on **USB debugging (Security settings)** on Infinix/XOS, then reconnect |
| Port 5555 already used | `selfadb.sh tcpip 5038` while connected, then `selfadb.sh connect --port 5038` |
| Adb works but stops the moment you lock the screen | `selfadb.sh keepawake` + battery unrestricted for Termux |
| Everything worked yesterday, nothing today | Did the phone reboot or power off? `selfadb.sh rom-probe`, then redo the one-time step |
| Do I have to redo this after every reboot? | Yes on stock Android 9 — see the reboot matrix above; `rom-probe` finds the two rare exceptions |
| `selfadb.sh` says command not found after `setup` | Open a new Termux session, or run `bash selfadb.sh …` from the repo folder |

### Security note

`adb tcpip 5555` opens port 5555 to the local network, and the shell it grants is powerful.
Keep it on trusted Wi-Fi, and when you are done for a while close it again with
`selfadb.sh usb` (sends `adb usb` over the live connection, so adbd goes back to
USB-only), by toggling USB debugging off in Developer options, or simply by rebooting.
Nothing in this repo is installed on your phone: no APK, no service, no daemon — only
text scripts you can read.

---

## Files in this repo

| File | Purpose |
|---|---|
| `selfadb.sh` | the whole tool (bash, ~890 lines, no dependencies beyond `adb`, optional `python3` for the fast LAN scan) |
| `README.md` | this guide |

---

## How it was tested

Every code path was exercised against a **mock `adb` client** (connect succeeds / refuses /
returns `unauthorized` / drops mid-session), with simulated `getprop` values for
*USB-only*, *TCP mode*, and *`persist.adb.tcp.port` set* phones, plus the LAN-scan and
custom-port paths, the watch/reconnect loop, generated boot + widget scripts, the
argument pass-through (`install -r -g`, `shell`, `tcpip`) and all four `rom-probe`
outcomes (no switch found / wireless-debug keys present / `persist.adb.tcp.port` set /
settings unreadable). It has **not** been run on a
physical X650C — when you run `selfadb.sh doctor` on your phone, that output is the real
status of your device, and `one-time` / `doctor` are written to tell you exactly what to
do from there.

Tested on: Termux 0.118 + `android-tools` 37.0.0 (the build you installed), Android 9
behaviour model. The tool degrades gracefully on Android 11+ (Wireless debugging and
pairing codes are supported there too — `selfadb.sh connect` uses the same paths).

## FAQ

**Does this need root?** No. Everything here uses the `adb` permission level (uid 2000,
`com.android.shell`) — exactly what a PC-side adb gets. Some actions still require root
(mounting `/system`, `su`, factory tools); those are not attempted.

**Can it survive a reboot without a PC?** Only if `persist.adb.tcp.port=5555` is set
(root/vendor/engineering builds). `doctor` tells you which case you are in.

**Why can't Termux just turn TCP mode on itself?** Because `service.adb.tcp.port` is
SELinux-labelled `shell_prop` and only `adbd`/root may write it. `selfadb.sh unlock`
demonstrates the denial on your own device if you want to see it.

**Is it safe to leave the adb server running?** The Termux-side server (port 5037) is
local-only. The risk is the *phone's* port 5555 on untrusted Wi-Fi — use trusted networks.

**Does it interfere with `adb` from a PC later?** No. It's the same protocol; the PC will
just find the phone already in TCP mode (`adb connect <phone-ip>:5555`).
