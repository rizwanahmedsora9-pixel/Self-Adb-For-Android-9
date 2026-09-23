#!/usr/bin/env bash
# =============================================================================
#  selfadb.sh  --  Use ADB on your OWN phone, from inside Termux.
#
#  No root. No Magisk. No Xposed. No custom kernel.
#
#  What it does:
#    * checks your phone / Termux for everything needed
#    * finds adbd (the ADB daemon) running on YOUR OWN device
#    * connects Termux's adb client to it  -> "adb shell" on your own phone
#    * keeps the connection alive and reconnects automatically if Wi-Fi drops
#    * auto-connects at boot (Termux:Boot) and can re-arm TCP mode without a PC
#
#  Why the "one-time step" exists on Android 9:
#    adbd only listens on the network (TCP port 5555) after someone sends it
#    the "tcpip" command. For security, Android 9 has *no* on-device toggle for
#    that (Wireless Debugging / pairing codes arrived in Android 11). So the
#    very first time (and again after every reboot) you need ~60 seconds with
#    ANY computer + USB cable:  "adb tcpip 5555".
#    After that, everything - including using adb - happens inside Termux.
#    See:  selfadb.sh one-time
#
#  Author: built for Infinix Hot 8 (X650C, Android 9) + Termux
# =============================================================================

set -uo pipefail

VERSION="1.0.0"
DEFAULT_PORT="${SELFADB_PORT:-5555}"
STATE_DIR="${HOME}/.selfadb"
STATE_FILE="${STATE_DIR}/target"
BOOT_DIR="${HOME}/.termux/boot"
SHORTCUT_DIR="${HOME}/.shortcuts"

# ---------- pretty output ----------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'
  BOLD=$'\033[1m'; DIM=$'\033[2m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; BOLD=""; DIM=""; N=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[!]%s %s\n' "$Y" "$N" "$*"; }
err()  { printf '%s[x]%s %s\n' "$R" "$N" "$*" >&2; }
die()  { err "$*"; exit 1; }

hr() { printf '%s\n' "${DIM}-----------------------------------------------------------${N}"; }

have() { command -v "$1" >/dev/null 2>&1; }

sys_bin() { # sys_bin NAME -> absolute path of an Android system binary, "" if absent
  local p
  p="$(command -v "$1" 2>/dev/null)"
  if [ -n "$p" ]; then printf '%s' "$p"; return 0; fi
  for p in "/system/bin/$1" "/system/xbin/$1" "/vendor/bin/$1"; do
    [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}
is_termux() { [ -d /data/data/com.termux/files/usr ] || [ -n "${TERMUX_VERSION:-}" ]; }
prefix_dir() { printf '%s' "${PREFIX:-/usr}"; }

run_timeout() { # run_timeout SECONDS cmd [args...]
  local secs="$1"; shift
  if have timeout; then timeout "$secs" "$@"; else "$@"; fi
}

# ---------- prerequisites ----------------------------------------------------
need_adb() {
  if ! have adb; then
    err "The 'adb' program is not installed."
    if is_termux; then
      say "    Fix:  pkg install android-tools"
      say "    (this is the android-tools package you already unpacked)"
    else
      say "    Fix:  sudo apt install android-tools-adb   (or install platform-tools)"
    fi
    exit 2
  fi
}

# ---------- device facts (no root needed, plain getprop) ---------------------
prop() { # prop NAME
  have getprop || return 0
  getprop "$1" 2>/dev/null | tr -d '\r'
}

adbd_tcp_port() { # port adbd is listening on right now, "" when USB-only
  local p
  p="$(prop service.adb.tcp.port)"
  printf '%s' "${p//[[:space:]]/}"
}

adbd_persist_port() { # survives reboots if the ROM set it (root/vendor only)
  local p
  p="$(prop persist.adb.tcp.port)"
  printf '%s' "${p//[[:space:]]/}"
}

self_wifi_ip() {
  local ip="" p
  if have getprop; then
    for p in dhcp.wlan0.ipaddress dhcp.wlan1.ipaddress dhcp.eth0.ipaddress; do
      ip="$(prop "$p")"
      case "$ip" in ""|"0.0.0.0") ip="" ;; *) printf '%s' "$ip"; return 0 ;; esac
    done
  fi
  local ipcmd=""
  have ip && ipcmd="ip"
  [ -z "$ipcmd" ] && [ -x /system/bin/ip ] && ipcmd="/system/bin/ip"
  if [ -n "$ipcmd" ]; then
    ip="$("$ipcmd" -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    if [ -z "$ip" ]; then
      ip="$("$ipcmd" -4 -o addr show 2>/dev/null | awk '$2 !~ /^lo/{print $4}' | cut -d/ -f1 | head -n1)"
    fi
    case "$ip" in ""|"0.0.0.0") ip="" ;; *) printf '%s' "$ip"; return 0 ;; esac
  fi
  if have ifconfig; then
    ip="$(ifconfig 2>/dev/null | awk '/inet[ ]/{print $2}' | grep -v '^127\.' | head -n1)"
    case "$ip" in ""|"0.0.0.0") ip="" ;; *) printf '%s' "$ip"; return 0 ;; esac
  fi
  if have hostname; then
    ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^127\.' | head -n1)"
    case "$ip" in ""|"0.0.0.0") ip="" ;; *) printf '%s' "$ip"; return 0 ;; esac
  fi
  if have termux-wifi-connectioninfo && have python3; then
    ip="$(termux-wifi-connectioninfo 2>/dev/null \
          | python3 -c 'import sys,json;print(json.load(sys.stdin).get("ip",""))' 2>/dev/null)"
    case "$ip" in ""|"0.0.0.0") ip="" ;; *) printf '%s' "$ip"; return 0 ;; esac
  fi
  return 1
}

port_open() { # port_open HOST PORT -> 0 when something accepts TCP there
  local h="$1" p="$2"
  if have timeout; then
    timeout 2 bash -c "exec 3<>/dev/tcp/$h/$p" >/dev/null 2>&1
  else
    (exec 3<>/dev/tcp/"$h"/"$p") >/dev/null 2>&1
  fi
}

# ---------- adb helpers ------------------------------------------------------
adb_state() { run_timeout 6 adb -s "$1" get-state 2>/dev/null | tr -d '\r' | head -n1; }

adb_online() { [ "$(adb_state "$1")" = "device" ]; }

saved_target() { [ -f "$STATE_FILE" ] && head -n1 "$STATE_FILE" 2>/dev/null; }

save_target() { mkdir -p "$STATE_DIR" 2>/dev/null; printf '%s\n' "$1" >"$STATE_FILE" 2>/dev/null; }

online_from_list() { # first device already in "device" state
  adb devices 2>/dev/null | tr -d '\r' | awk 'NR>1 && $2=="device"{print $1; exit}'
}

best_target() { # a target that is currently usable, "" if none
  local t
  t="$(saved_target)"
  if [ -n "$t" ] && adb_online "$t"; then printf '%s' "$t"; return 0; fi
  t="$(online_from_list)"
  if [ -n "$t" ]; then printf '%s' "$t"; return 0; fi
  return 1
}

start_server() { run_timeout 15 adb start-server >/dev/null 2>&1; }

lan_scan() { # lan_scan PORT [HOST...] -> prints hosts accepting TCP on PORT
  local port="$1"; shift
  local hosts=("$@")
  if have python3; then
    python3 - "$port" ${hosts[@]+"${hosts[@]}"} <<'PY'
import socket, sys, concurrent.futures
port = int(sys.argv[1]); hosts = sys.argv[2:]
def probe(h):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(0.8)
    try:
        s.connect((h, port)); return h
    except Exception:
        return None
    finally:
        try: s.close()
        except Exception: pass
with concurrent.futures.ThreadPoolExecutor(max_workers=64) as ex:
    for r in ex.map(probe, hosts):
        if r: print(r)
PY
    return 0
  fi
  # bash fallback (slower)
  local h
  for h in ${hosts[@]+"${hosts[@]}"}; do
    port_open "$h" "$port" && printf '%s\n' "$h"
  done
}

subnet_hosts() { # subnet_hosts 192.168.1.23 -> 192.168.1.1 .. .254
  local ip="$1" i
  local base="${ip%.*}"
  for i in $(seq 1 254); do printf '%s.%s\n' "$base" "$i"; done
}

# ---------- connect ----------------------------------------------------------
try_one() { # try_one TARGET [quiet] -> 0 ok, 1 no, 2 unauthorized/offline
  local t="$1" quiet="${2:-}" out st
  if adb_online "$t"; then
    [ -n "$quiet" ] || ok "already connected to $t"
    return 0
  fi
  out="$(run_timeout 15 adb connect "$t" 2>&1 | tr -d '\r')"
  [ -n "$quiet" ] || printf '%s    %s\n' "$DIM" "$out"
  st="$(adb_state "$t")"
  case "$st" in
    device)      ok "connected: $t"; save_target "$t"; return 0 ;;
    unauthorized) warn "$t -> UNAUTHORIZED"; return 2 ;;
    offline)      warn "$t -> offline";     return 2 ;;
    *)            return 1 ;;
  esac
}

candidates() {
  local port="${1:-$DEFAULT_PORT}" ip gw
  local t
  t="$(saved_target)"; [ -n "$t" ] && printf '%s\n' "$t"
  printf '%s\n' "127.0.0.1:${port}" "localhost:${port}"
  ip="$(self_wifi_ip || true)"
  if [ -n "$ip" ]; then
    printf '%s\n' "${ip}:${port}"
    gw="$(printf '%s' "$ip" | awk -F. '{print $1"."$2"."$3".1"}')"
    [ -n "$gw" ] && printf '%s\n' "${gw}:${port}"
  fi
}

connect_auto() { # 0 connected, 3 needs one-time step, 1 failed otherwise
  local port="${DEFAULT_PORT}" quiet="" restart="" t rc explicit=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --quiet)   quiet=1 ;;
      --restart) restart=1 ;;
      --port)    port="$2"; shift ;;
      -*)        ;;
      *:*)       explicit="$1" ;;                      # host:port given by hand
      *[0-9].[0-9]*) explicit="$1:${DEFAULT_PORT}" ;;  # bare IP -> default port
      *)         port="$1" ;;
    esac
    shift
  done

  need_adb
  if [ -n "$restart" ]; then
    info "restarting adb server (Termux side)"
    adb kill-server >/dev/null 2>&1
  fi
  start_server

  if [ -n "$explicit" ]; then
    try_one "$explicit" "$quiet" && return 0
    warn "could not connect to the target you gave: $explicit"
    return 1
  fi

  local pending=()
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    case " ${pending[*]-} " in *" $t "*) continue ;; esac
    pending+=("$t")
  done < <(candidates "$port")

  local hint_shown=""
  for t in "${pending[@]}"; do
    saw_target="$t"
    try_one "$t" "$quiet"
    rc=$?
    if [ "$rc" -eq 0 ]; then return 0; fi
    if [ "$rc" -eq 2 ]; then
      [ -n "$quiet" ] || unlock_hint
      return 3
    fi
  done

  # Nothing on the usual suspects. Is adbd even in TCP mode?
  local tp pp
  tp="$(adbd_tcp_port)"; pp="$(adbd_persist_port)"
  if [ -z "$tp" ] && [ -z "$pp" ]; then
    [ -n "$quiet" ] || {
      warn "adbd on this phone is in USB-only mode -- nothing is listening on port ${port}."
      say  ""
      say  "    ${BOLD}One-time step needed (60 seconds, needs a PC + USB cable once):${N}"
      say  "      1. PC has adb?      then just plug the phone in and run:  adb tcpip 5555"
      say  "      2. Unplug, then run in Termux:                          selfadb.sh connect"
      say  "    Full walkthrough:   selfadb.sh one-time"
    }
    return 3
  fi

  # TCP mode says it should be up; is it maybe on a different port? (some ROMs)
  if [ -n "$tp" ] && [ "$tp" != "$port" ]; then
    [ -n "$quiet" ] || info "adbd reports TCP port ${tp}, trying it"
    try_one "127.0.0.1:${tp}" "$quiet" && return 0
  fi

  # Last resort: sweep the LAN for something answering on this port.
  if have python3; then
    local ip hosts found
    ip="$(self_wifi_ip || true)"
    if [ -n "$ip" ]; then
      [ -n "$quiet" ] || info "scanning ${ip%.*}.0/24 for port ${port} (a few seconds) ..."
      hosts="$(subnet_hosts "$ip")"
      found="$(lan_scan "$port" $hosts)"
      for t in $found; do
        try_one "${t}:${port}" "$quiet" && return 0
      done
    fi
  fi

  [ -n "$quiet" ] || warn "could not connect. Run: selfadb.sh doctor"
  return 1
}

unlock_hint() {
  say ""
  warn "The phone is asking for permission -- look at your screen!"
  say  "    Tap ${BOLD}Allow${N} (tick 'Always allow from this computer') and retry:"
  say  "      selfadb.sh connect"
  say  "    If the dialog never appears: unlock the phone, then run"
  say  "      adb kill-server && selfadb.sh connect"
}

# ---------- commands ---------------------------------------------------------
cmd_setup() {
  info "installing / updating the pieces this tool needs"
  if is_termux; then
    pkg update -y >/dev/null 2>&1 || true
    pkg install -y android-tools || die "pkg install android-tools failed"
    pkg install -y python || warn "python not installed (only needed for fast LAN scan)"
    pkg install -y termux-api 2>/dev/null && info "termux-api installed (optional extras)"
    mkdir -p "$(prefix_dir)/bin"
    local own; own="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
    if [ -w "$(prefix_dir)/bin" ] && [ -f "$own" ]; then
      cp -f "$own" "$(prefix_dir)/bin/selfadb" && chmod +x "$(prefix_dir)/bin/selfadb" \
        && ok "installed: you can now type just 'selfadb' instead of 'bash selfadb.sh'"
    fi
  else
    if have apt-get; then sudo apt-get update -qq && sudo apt-get install -y android-tools-adb python3
    elif have brew; then brew install android-platform-tools python3
    else warn "install platform-tools (adb) + python3 with your package manager"
    fi
  fi
  have adb   && ok "adb:    $(adb version 2>/dev/null | head -n1)"
  have python3 && ok "python: $(python3 -V 2>&1)"
  if is_termux; then
    say ""
    info "For auto-connect at boot, also install the ${BOLD}Termux:Boot${N} app"
    say  "    then run:  selfadb.sh boot-install"
  fi
}

cmd_doctor() {
  say "${BOLD}selfadb doctor${N} -- version ${VERSION}"
  hr
  if have adb; then
    ok   "adb found:  $(adb version 2>/dev/null | head -n1)"
  else
    err  "adb NOT found  ->  pkg install android-tools"
  fi
  if have python3; then ok "python3:    $(python3 -V 2>&1)"; else warn "python3 not found (optional: faster LAN scan)"; fi

  local ip tp pp secure adbd
  ip="$(self_wifi_ip || true)"
  [ -n "$ip" ] && ok "this phone's Wi-Fi IP: $ip" || warn "could not read this phone's Wi-Fi IP (Wi-Fi off?)"
  adbd="$(prop init.svc.adbd)";   [ -n "$adbd" ] && info "init.svc.adbd = $adbd"
  secure="$(prop ro.adb.secure)"; [ -n "$secure" ] && info "ro.adb.secure = $secure  (1 = you must tap Allow on screen)"
  tp="$(adbd_tcp_port)"
  pp="$(adbd_persist_port)"
  if [ -n "$tp" ]; then ok "service.adb.tcp.port = $tp  -> adbd IS in TCP mode"
  else warn "service.adb.tcp.port = (empty)  -> adbd is USB-only right now"; fi
  if [ -n "$pp" ]; then ok "persist.adb.tcp.port = $pp  -> survives reboots, you may never need a PC!"
  else info "persist.adb.tcp.port = (empty)  -> after each reboot the one-time step is needed again"; fi

  if have adb; then
    start_server
    say ""
    info "adb devices:"
    adb devices -l 2>&1 | sed 's/^/    /'
    if port_open 127.0.0.1 "${tp:-$DEFAULT_PORT}"; then
      ok "port 127.0.0.1:${tp:-$DEFAULT_PORT} is OPEN (something is listening)"
    else
      warn "port 127.0.0.1:${tp:-$DEFAULT_PORT} is closed"
    fi
  fi

  say ""
  hr
  local ready=1
  if ! have adb; then
    err "NEXT STEP: install the adb client:   selfadb.sh setup"
  elif [ -n "$(best_target || true)" ]; then
    ready=0
    ok "READY -- adb is talking to this phone: $(best_target)"
    say "    try:  selfadb.sh shell"
  elif [ -n "$tp" ] || [ -n "$pp" ]; then
    ok "TCP mode looks enabled -- just connect:"
    say "    selfadb.sh connect"
  else
    warn "NEXT STEP: enable TCP mode once with a PC (60 seconds):"
    say "    selfadb.sh one-time"
  fi
  return "$ready"
}

cmd_connect() { connect_auto "$@"; }

cmd_one_time() {
  local ip; ip="$(self_wifi_ip || true)"
  say "${BOLD}=== ONE-TIME ENABLE: make adbd listen on TCP (Android 9) ===${N}"
  say ""
  say "Why: on Android 9 the daemon (adbd) only opens network port ${DEFAULT_PORT}"
  say "after it is told 'tcpip'. Android 9 has no on-device switch for that"
  say "(Wireless Debugging + pairing codes are Android 11+ only), and without"
  say "root no app is allowed to flip it. So: any computer + USB cable, ONCE."
  say "After that, adb runs 100% inside Termux -- until you reboot the phone."
  hr
  say "${BOLD}ON THE PHONE${N}"
  say "  1) Settings > About phone > tap 'Build number' 7 times"
  say "  2) Settings > System > Developer options:"
  say "       - USB debugging ................ ON"
  say "       - Install via USB / USB debugging (Security settings) ... ON (if present)"
  say "  3) Plug the phone into the PC, choose 'File transfer (MTP)' if asked"
  say ""
  say "${BOLD}ON THE PC${N}  (Windows / macOS / Linux -- pick one)"
  say "  Download platform-tools:"
  say "    Windows: https://dl.google.com/android/repository/platform-tools-latest-windows.zip"
  say "    macOS:   https://dl.google.com/android/repository/platform-tools-latest-darwin.zip"
  say "    Linux:   https://dl.google.com/android/repository/platform-tools-latest-linux.zip"
  say "    (or: winget install Google.PlatformTools / brew install android-platform-tools"
  say "         / sudo apt install android-tools-adb)"
  say ""
  say "  Then in the platform-tools folder:"
  say "      ${BOLD}adb devices${N}                # phone shows 'Allow USB debugging?' -> tap Allow"
  say "      ${BOLD}adb tcpip 5555${N}             # prints: restarting in TCP mode port: 5555"
  say ""
  say "  Tip: if 'adb devices' is empty -> check the cable is a DATA cable,"
  say "  toggle USB debugging off/on, or reinstall the OEM USB driver."
  hr
  say "${BOLD}BACK IN TERMUX${N} (USB unplugged)"
  say "      ${BOLD}selfadb.sh connect${N}"
  say "      ${BOLD}selfadb.sh shell${N}           # adb shell ON YOUR OWN PHONE"
  if [ -n "$ip" ]; then
    say ""
    say "  Expected:  connected: 127.0.0.1:${DEFAULT_PORT}   (phone IP: ${ip})"
  fi
  say ""
  say "${BOLD}STAY CONNECTED${N}"
  say "      selfadb.sh watch               # auto-reconnect loop (keep it running)"
  say "      selfadb.sh boot-install        # auto-connect after boot (Termux:Boot)"
  say "      selfadb.sh keepawake           # stop Wi-Fi from sleeping"
  say ""
  say "${BOLD}NO COMPUTER AT ALL?${N}"
  say "  Then it cannot be done on stock Android 9 without root -- that is an"
  say "  Android 9 security design, not a limitation of this tool. Options:"
  say "    * borrow any PC/laptop for 1 minute (phone stays yours; nothing is installed)"
  say "    * use a friend's phone + OTG?  No: adb needs USB host rights, which"
  say "      Android only gives to a real computer, not to another phone app."
  say "    * root/Universal ADB driver style hacks: out of scope (you said no root)."
  say "  Good news: from then on you can re-arm TCP mode from Termux itself:"
  say "      selfadb.sh tcpip               # re-sends 'tcpip 5555' over the network"
  say "      (only fails after the phone has rebooted)"
}

cmd_tcpip() { # re-arm TCP mode over the existing network connection
  local port="${1:-$DEFAULT_PORT}" t
  t="$(best_target || true)"
  if [ -z "$t" ]; then
    err "not connected yet -- run: selfadb.sh connect"
    say "    (re-arming only works while a connection already exists)"
    return 1
  fi
  info "asking adbd on $t to listen on TCP port ${port}"
  say "    (this survives Wi-Fi changes and unplugging, but not a reboot)"
  adb -s "$t" tcpip "$port" 2>&1 | sed 's/^/    /'
  sleep 2
  adb disconnect "$t" >/dev/null 2>&1
  try_one "127.0.0.1:${port}" || try_one "${t}" || warn "re-connect manually: selfadb.sh connect"
}

cmd_usb() { # put adbd back into USB-only mode (closes the TCP port)
  need_adb
  local t; t="$(best_target || true)"
  [ -z "$t" ] && { err "connect first: selfadb.sh connect"; return 1; }
  info "switching adbd back to USB-only mode (network port closes)"
  adb -s "$t" usb 2>&1 | sed 's/^/    /'
  rm -f "$STATE_FILE" 2>/dev/null
  ok "done -- adbd is USB-only again until you send 'tcpip' once more"
  say "    (you will need the one-time PC step to get TCP mode back)"
}

cmd_status() {
  need_adb
  start_server
  local t; t="$(best_target || true)"
  if [ -n "$t" ]; then ok "connected target: $t"
  else warn "no device connected (run: selfadb.sh connect)"; fi
  say ""
  info "adb devices:"
  adb devices -l 2>&1 | sed 's/^/    /'
  if [ -n "$t" ]; then
    say ""
    info "device info:"
    local remote='getprop ro.product.brand; getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.version.sdk; id'
    adb -s "$t" shell "$remote" 2>&1 | tr -d '\r' | sed 's/^/    /'
  fi
}

cmd_shell() {
  need_adb
  local t; t="$(best_target || true)"
  if [ -z "$t" ]; then
    err "not connected -- run: selfadb.sh connect"
    return 1
  fi
  info "adb shell on $t  (type 'exit' to come back)"
  exec adb -s "$t" shell "$@"
}

cmd_scan() {
  local port="${1:-$DEFAULT_PORT}" ip hosts
  ip="$(self_wifi_ip || true)"
  if [ -z "$ip" ]; then
    err "cannot detect this phone's Wi-Fi IP"
    say "    pass hosts manually:  selfadb.sh scan ${port} 192.168.1.5"
    return 1
  fi
  info "scanning ${ip%.*}.0/24 for TCP port ${port} ..."
  hosts="$(subnet_hosts "$ip")"
  local found; found="$(lan_scan "$port" $hosts)"
  if [ -z "$found" ]; then
    warn "nothing found. adbd is probably in USB-only mode -> selfadb.sh one-time"
    return 1
  else
    ok "hosts with port ${port} open:"
    printf '%s\n' "$found" | sed 's/^/    /'
    say "    connect with:  adb connect <ip>:${port}"
  fi
}

cmd_watch() {
  local interval="${SELFADB_INTERVAL:-20}" quiet="" backoff=5
  while [ $# -gt 0 ]; do
    case "$1" in
      --quiet|-q) quiet=1 ;;
      --interval)   interval="$2"; shift ;;
    esac
    shift
  done
  need_adb
  if is_termux && have termux-wake-lock; then
    termux-wake-lock 2>/dev/null
    [ -n "$quiet" ] || info "wake lock held (Termux will not be frozen)"
  fi
  [ -n "$quiet" ] || info "watching adb connection (Ctrl-C to stop) ..."
  local t
  while :; do
    t="$(best_target || true)"
    if [ -n "$t" ]; then
      if run_timeout 8 adb -s "$t" shell echo ok >/dev/null 2>&1; then
        [ -n "$quiet" ] || printf '%s[%s] alive: %s%s\n' "$DIM" "$(date +%H:%M:%S)" "$t" "$N"
        backoff=5
      else
        [ -n "$quiet" ] || warn "$(date +%H:%M:%S) connection lost, reconnecting ..."
      fi
    fi
    if [ -z "$(best_target || true)" ]; then
      if connect_auto --quiet; then
        backoff=5
        [ -n "$quiet" ] || ok "$(date +%H:%M:%S) reconnected: $(saved_target)"
        if is_termux && have termux-notification && [ -n "${SELFADB_NOTIFY:-}" ]; then
          termux-notification -t "selfadb" -c "reconnected: $(saved_target)" >/dev/null 2>&1
        fi
      else
        [ -n "$quiet" ] || warn "$(date +%H:%M:%S) no adbd on the network -- retrying in ${backoff}s (PC step needed after a reboot)"
        sleep "$backoff"
        backoff=$(( backoff * 2 )); [ "$backoff" -gt 120 ] && backoff=120
        continue
      fi
    fi
    sleep "$interval"
  done
}

cmd_keepawake() { # keep Wi-Fi alive + screen wake-ups so adbd stays reachable
  need_adb
  local t; t="$(best_target || true)"
  if [ -z "$t" ]; then err "connect first: selfadb.sh connect"; return 1; fi
  info "keeping Wi-Fi awake and disabling battery trampling (safe, reversible)"
  adb -s "$t" shell settings put global wifi_sleep_policy 2 2>/dev/null \
    && ok "wifi_sleep_policy = 2 (never sleep)" || warn "could not set wifi_sleep_policy"
  adb -s "$t" shell svc wifi enable >/dev/null 2>&1 && ok "wifi enabled"
  adb -s "$t" shell settings put global stay_on_while_plugged_in 7 2>/dev/null \
    && ok "screen stays on while charging"
  adb -s "$t" shell cmd deviceidle whitelist +com.termux 2>/dev/null \
    && ok "Termux whitelisted from Doze (needs no root)" || true
  say ""
  info "also do this by hand on Infinix/XOS (it kills background apps):"
  say "    Settings > Apps > Termux > Battery > Unrestricted / No restrictions"
  say "    Settings > Apps > Termux > enable 'Auto-start'"
  say "    Settings > Battery > Power saving mode: OFF while using adb"
}

cmd_install_apk() {
  need_adb
  local t; t="$(best_target || true)"
  [ -z "$t" ] && { err "connect first: selfadb.sh connect"; return 1; }
  [ $# -eq 0 ] && { err "usage: selfadb.sh install /path/to/file.apk  [-d] [-t] ..."; return 1; }
  local filtered=() a
  for a in "$@"; do
    case "$a" in -r|-g) continue ;; esac      # provided below already
    filtered+=("$a")
  done
  adb -s "$t" install -r -g ${filtered[@]+"${filtered[@]}"}
}

cmd_shizuku() { # start Shizuku (Android 7+) using the adb connection
  need_adb
  local t; t="$(best_target || true)"
  [ -z "$t" ] && { err "connect first: selfadb.sh connect"; return 1; }
  info "starting Shizuku (gives apps ADB-level powers, still no root)"
  adb -s "$t" shell sh /storage/emulated/0/Android/data/moe.shizuku.privileged.api/start.sh 2>&1 \
    | tr -d '\r' | sed 's/^/    /'
}

cmd_boot_install() {
  local self_path; self_path="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
  have selfadb && self_path="$(command -v selfadb)"
  mkdir -p "$BOOT_DIR" || die "cannot create $BOOT_DIR"
  cat >"${BOOT_DIR}/selfadb.sh" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
# auto-generated by selfadb.sh -- connects adb on every boot
termux-wake-lock 2>/dev/null
i=0
while [ \$i -lt 40 ]; do
  ip=\$(getprop dhcp.wlan0.ipaddress 2>/dev/null)
  [ -n "\$ip" ] && break
  sleep 3
  i=\$((i+1))
done
sleep 5
NO_COLOR=1 exec "${self_path}" watch --quiet
EOF
  chmod +x "${BOOT_DIR}/selfadb.sh"
  ok "boot script installed: ${BOOT_DIR}/selfadb.sh"
  say "    Requires the ${BOLD}Termux:Boot${N} app (F-Droid/GitHub) -- open it once,"
  say "    and allow Termux to auto-start in XOS settings."
  warn "Reminder: after a reboot adbd is USB-only again on Android 9, so the"
  say  "    boot script can only reconnect if adbd is still in TCP mode."

  mkdir -p "$SHORTCUT_DIR" 2>/dev/null
  cat >"${SHORTCUT_DIR}/adb-connect.sh" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
NO_COLOR=1 "${self_path}" connect
sleep 3
NO_COLOR=1 "${self_path}" status
EOF
  chmod +x "${SHORTCUT_DIR}/adb-connect.sh" 2>/dev/null
  ok "Termux:Widget shortcut: ~/.shortcuts/adb-connect.sh (one tap to connect)"
}

cmd_boot_remove() {
  rm -f "${BOOT_DIR}/selfadb.sh" "${SHORTCUT_DIR}/adb-connect.sh" 2>/dev/null
  ok "removed boot script and widget shortcut"
}

cmd_rom_probe() { # look for an on-device ADB-over-network switch (no root needed)
  say "${BOLD}ROM probe${N} -- is there any way to enable adb-over-network without a PC?"
  say "Read-only: this only queries properties and settings, it changes nothing."
  hr

  # 1) adb-related system properties
  say "${BOLD}1) properties mentioning 'adb'${N}"
  if have getprop; then
    local adbprops
    adbprops="$(getprop 2>/dev/null | grep -i 'adb' | tr -d '\r')"
    if [ -n "$adbprops" ]; then printf '%s\n' "$adbprops" | sed 's/^/    /'
    else say "    (none)"; fi
  else
    warn "    getprop not available -- run this inside Termux on the phone"
  fi

  # 2) settings tables: hunt for network/wireless adb keys
  say ""
  say "${BOLD}2) settings keys mentioning adb / wireless debugging / tcp${N}"
  local settings_bin tbl out hits key val
  settings_bin="$(sys_bin settings || true)"
  local candidates=""
  for tbl in global secure system; do
    if [ -z "$settings_bin" ]; then
      warn "    'settings' command not found"
      break
    fi
    out="$("$settings_bin" list "$tbl" 2>&1 | tr -d '\r')"
    if printf '%s' "$out" | grep -qi 'SecurityException\|Permission Denial\|Unknown command'; then
      warn "    cannot read '${tbl}' settings ($(printf '%s' "$out" | head -n1))"
      continue
    fi
    hits="$(printf '%s\n' "$out" | grep -iE '(^|[^a-z])(adb|wireless_debug|wifi_debug|network_adb|adb_tcp|adbd)' | sed 's/^/    /')"
    if [ -n "$hits" ]; then
      say "    ${DIM}${tbl}:${N}"
      printf '%s\n' "$hits"
      candidates="${candidates}$(printf '%s\n' "$hits" | sed 's/^    //') 
"
    else
      say "    ${DIM}${tbl}: nothing adb-related${N}"
    fi
  done

  # 3) verdict
  say ""
  hr
  local tp pp
  tp="$(adbd_tcp_port)"
  pp="$(adbd_persist_port)"
  local verdict="pc"
  if [ -n "$pp" ]; then
    verdict="free"
    ok "VERDICT: this ROM keeps TCP mode across reboots."
    say "    persist.adb.tcp.port = ${pp}  ->  after a reboot just: selfadb.sh connect"
  elif printf '%s' "$candidates" | grep -qiE 'wireless_debug|wifi_debug|network_adb|adb_wifi'; then
    verdict="maybe"
    ok "VERDICT: this ROM has an Android-11-style wireless-debugging setting!"
    say "    Found:"
    printf '%s\n' "$candidates" | grep -iE 'wireless_debug|wifi_debug|network_adb|adb_wifi' | sed 's/^/      /'
    say "    Look in Settings > Developer options for 'Wireless debugging' / 'ADB over network'."
    say "    If it is there and toggleable, you never need a PC again."
  else
    warn "VERDICT: no on-device switch found -- PC step needed once per reboot."
  fi
  [ -n "$tp" ] && info "currently: service.adb.tcp.port = ${tp} (TCP mode live right now)"
  [ -z "$tp" ] && warn "currently: adbd is USB-only (service.adb.tcp.port empty)"

  # 4) what to look for by hand
  say ""
  say "${BOLD}Also check by hand (10 seconds, XOS hides things)${N}"
  say "    Settings > System > Developer options, scroll and look for any of:"
  say "      'ADB over network'  'Network ADB'  'Wireless ADB'  'ADB over Wi-Fi'"
  say "      'Wi-Fi debugging'   'Wireless debugging'  'Debug over network'"
  say "    If you find one: switch it ON, then in Termux run  selfadb.sh connect"
  say "    If it works across a reboot -> tell me, we can drop the PC step entirely."
  say ""
  say "    ${DIM}(XOS/Infinix builds usually strip this on Android 9, but some MediaTek ROMs keep it.)${N}"
  case "$verdict" in
    free|maybe) return 0 ;;
    *) return 1 ;;
  esac
}

cmd_unlock_probe() { # honesty probe: can this (non-root) device flip TCP mode itself?
  say "trying to set service.adb.tcp.port from Termux (expected: denied on retail Android 9)"
  if ! have setprop && [ ! -x /system/bin/setprop ]; then
    warn "no 'setprop' in PATH -- are you running this inside Termux?"
    return 1
  fi
  local out rc
  out="$(setprop service.adb.tcp.port "$DEFAULT_PORT" 2>&1)"; rc=$?
  if [ $rc -eq 0 ] && [ -z "$out" ]; then
    ok "setprop was ACCEPTED! (rare/loose ROM)"
    info "value now: service.adb.tcp.port=$(adbd_tcp_port)"
    info "try re-arming without a PC:  selfadb.sh tcpip   (or restart adbd if you can)"
  else
    warn "denied: ${out:-permission error}"
    say "    Normal on stock Android 9: only root or a PC-side 'adb tcpip' may do this."
    say "    -> selfadb.sh one-time"
  fi
}

cmd_help() {
  cat <<EOF
${BOLD}selfadb${N} v${VERSION} -- ADB on your own Android phone, from Termux. No root.

${BOLD}USAGE${N}
  bash selfadb.sh <command> [options]

${BOLD}GETTING STARTED${N}
  setup                 install android-tools/python, add 'selfadb' to PATH
  doctor                full diagnosis: what is missing, what to do next
  one-time              the 60-second PC step that enables adbd over TCP
  connect [host:port]   find adbd and connect (default port ${DEFAULT_PORT});
                        or connect straight to a host you name yourself
  status                show connection + phone info

${BOLD}DAILY USE${N}
  shell [cmd...]        adb shell on your own phone
  install FILE.apk      install an APK (with -g: all permissions granted)
  keepawake             stop Wi-Fi sleeping so the link survives
  scan [port]           sweep your LAN for something listening
  tcpip [port]          re-arm TCP mode using the existing connection
  usb                   close the network port again (back to USB-only)
  disconnect            drop the network connection
  shizuku               start Shizuku via this adb connection (no root)

${BOLD}KEEP IT ALIVE / AUTOMATION${N}
  watch [--interval N]  loop: keep alive + auto-reconnect (use with wake lock)
  boot-install          auto-connect at boot via Termux:Boot + widget shortcut
  boot-remove           undo the above
  rom-probe             hunt for an on-device adb-over-network switch (may save the PC step)
  unlock                probe whether this ROM allows a no-PC enable (usually no)

${BOLD}OPTIONS${N}
  --port N              use another port (also: SELFADB_PORT=5555)
  --restart             kill and restart the Termux-side adb server
  -q, --quiet           quiet watch/boot mode
  NO_COLOR=1            plain text output

${BOLD}EXAMPLES${N}
  bash selfadb.sh doctor
  bash selfadb.sh connect && bash selfadb.sh shell
  SELFADB_INTERVAL=15 bash selfadb.sh watch
  bash selfadb.sh install ~/storage/downloads/app.apk
EOF
}

cmd_disconnect() {
  need_adb
  local t; t="$(best_target || true)"
  if [ -n "$t" ]; then
    adb disconnect "$t" >/dev/null 2>&1
    ok "disconnected $t"
  else
    adb disconnect >/dev/null 2>&1
    info "disconnected all network targets"
  fi
  rm -f "$STATE_FILE" 2>/dev/null
}

cmd_quick() { # no arguments: friendly summary + next best action
  say "${BOLD}selfadb${N} v${VERSION} ${DIM}(run: bash selfadb.sh help)${N}"
  hr
  if ! have adb; then
    err "adb missing -> run:  selfadb.sh setup"
    return 2
  fi
  local t ip tp
  t="$(best_target || true)"
  ip="$(self_wifi_ip || true)"
  tp="$(adbd_tcp_port)"
  if [ -n "$t" ]; then
    ok "CONNECTED to $t"
    say "    shell:   selfadb.sh shell"
    say "    install: selfadb.sh install file.apk"
    say "    keep-up: selfadb.sh watch"
    return 0
  fi
  say "  connected : ${R}no${N}"
  say "  phone IP  : ${ip:-unknown}"
  say "  adbd TCP  : ${tp:-not listening (USB-only)}"
  hr
  if [ -n "$tp" ]; then
    info "next:  ${BOLD}bash selfadb.sh connect${N}"
  else
    warn "adbd is USB-only, so there is nothing to connect to yet."
    info "next:  ${BOLD}bash selfadb.sh one-time${N}  (60 s with any PC) then ${BOLD}connect${N}"
    say  "       ${DIM}check first: bash selfadb.sh doctor${N}"
    say  "       ${DIM}or look for a hidden on-device switch: bash selfadb.sh rom-probe${N}"
  fi
}

# ---------- dispatch ---------------------------------------------------------
main() {
  local cmd="${1:-}"; [ $# -gt 0 ] && shift
  case "$cmd" in
    ""|quick|menu|start)  cmd_quick ;;
    setup)                cmd_setup ;;
    deps|install-deps)    cmd_setup ;;
    doctor|diag|check)    cmd_doctor ;;
    connect|up)           cmd_connect "$@" ;;
    status|st|devices)    cmd_status ;;
    shell|sh)             cmd_shell "$@" ;;
    one-time|onetime|pc)  cmd_one_time ;;
    tcpip)                cmd_tcpip "$@" ;;
    usb|tousb)            cmd_usb ;;
    scan|find)            cmd_scan "$@" ;;
    watch|keepalive-loop) cmd_watch "$@" ;;
    keepawake|wake)       cmd_keepawake ;;
    install|install-apk)  cmd_install_apk "$@" ;;
    shizuku)              cmd_shizuku ;;
    boot-install|boot)    cmd_boot_install ;;
    boot-remove)          cmd_boot_remove ;;
    rom-probe|romprobe|hidden) cmd_rom_probe ;;
    unlock|probe)         cmd_unlock_probe ;;
    disconnect|down)      cmd_disconnect ;;
    version|-v|--version) say "selfadb ${VERSION}" ;;
    help|-h|--help)       cmd_help ;;
    *) err "unknown command: $cmd"; say ""; cmd_help; exit 64 ;;
  esac
}

main "$@"
