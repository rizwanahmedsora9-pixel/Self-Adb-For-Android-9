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
| `selfadb.sh unlock` | probes whether your ROM is loose enough to enable TCP mode without a PC (usually: no) |
| `selfadb.sh disconnect` | drops the network connection |
| `selfadb.sh help` | all of the above, on the device |

Options: `--port N` (or `SELFADB_PORT`), `--restart` (kill + restart the Termux-side
server), `-q/--quiet`, `NO_COLOR=1`, `SELFADB_INTERVAL=N` (watch poll seconds).

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
| `selfadb.sh` | the whole tool (bash, ~800 lines, no dependencies beyond `adb`, optional `python3` for the fast LAN scan) |
| `README.md` | this guide |

---

## How it was tested

Every code path was exercised against a **mock `adb` client** (connect succeeds / refuses /
returns `unauthorized` / drops mid-session), with simulated `getprop` values for
*USB-only*, *TCP mode*, and *`persist.adb.tcp.port` set* phones, plus the LAN-scan and
custom-port paths, the watch/reconnect loop, generated boot + widget scripts and the
argument pass-through (`install -r -g`, `shell`, `tcpip`). It has **not** been run on a
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
