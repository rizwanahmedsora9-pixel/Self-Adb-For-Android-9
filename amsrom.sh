#!/usr/bin/env bash
# =============================================================================
#  amsrom.sh -- hardware profiler + "AMS ROM" custom-ROM project generator
#
#  Reads everything it can about THIS device (read-only, it never changes
#  anything), analyses it, and creates a ready-to-fill custom-ROM project:
#
#      AMS-ROM/
#        README.md                  analysis summary + roadmap + warnings
#        hardware/profile.json      machine-readable hardware profile
#        hardware/report.md         human-readable analysis
#        hardware/facts.kv          flat key=value facts used by the scripts
#        hardware/raw/*.txt         every raw dump, exactly as read
#        device/<vendor>/<codename>/  device-tree skeleton (AOSP/Lineage style)
#        gsi/candidates.md          which GSI images match this device
#        gsi/flash-gsi.sh           dry-run-first flashing helper
#        build/build-rom.sh         ROM build wrapper (template)
#        backups/README.md          what to save BEFORE touching the phone
#
#  Runs two ways:
#    * in Termux on the phone                     (local mode, no adb needed)
#    * on a PC / in Termux with a device connected via adb  (--serial, deep mode)
#      deep mode adds partition table, HAL list, camera/sensor/GPU dumps,
#      fstab, boot-chain state -- everything a device tree needs.
#
#  Usage:  bash amsrom.sh [all|collect|analyze|init|info] [options]
#          --serial SERIAL   use this adb device (default: the only one online)
#          --local           force local mode (ignore adb)
#          --dir PATH        output folder (default ./AMS-ROM)
#
#  Nothing here flashes, roots or modifies the phone. The only script that can
#  write to a device is gsi/flash-gsi.sh, and it refuses to run without an
#  explicit confirmation flag and never touches bootloader/modem partitions.
# =============================================================================

set -uo pipefail

VERSION="1.0.0"
OUT_DIR="${AMSRON_DIR:-}"
MODE_SERIAL=""
FORCE_LOCAL=0

# ---------- output helpers ---------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; BOLD=""; DIM=""; N=""
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[!]%s %s\n' "$Y" "$N" "$*"; }
err()  { printf '%s[x]%s %s\n' "$R" "$N" "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }
run_timeout() { local s="$1"; shift; if have timeout; then timeout "$s" "$@"; else "$@"; fi; }

# ---------- device I/O -------------------------------------------------------
serial_detect() {
  [ -n "$MODE_SERIAL" ] && return 0
  [ "$FORCE_LOCAL" = "1" ] && return 1
  have adb || return 1
  local s n
  s="$(run_timeout 6 adb devices 2>/dev/null | tr -d '\r' | awk 'NR>1 && $2=="device"{print $1}')"
  n="$(printf '%s\n' "$s" | grep -c . || true)"
  if [ "$n" -eq 1 ]; then MODE_SERIAL="$s"; return 0; fi
  if [ "$n" -gt 1 ]; then
    warn "several adb devices online -- pick one with --serial"; printf '%s\n' "$s" | sed 's/^/    /'
    return 1
  fi
  return 1
}

run_dev() { # run_dev "shell command"
  local cmd="$1"
  if [ -n "$MODE_SERIAL" ]; then
    run_timeout 25 adb -s "$MODE_SERIAL" shell "$cmd" 2>&1
  else
    run_timeout 25 bash -c "$cmd" 2>&1
  fi
}

# ---------- collection -------------------------------------------------------
DUMPED=(); SKIPPED=()
dump() { # dump NAME "command" [local|adb]
  local name="$1" cmd="$2" cap="${3:-local}" src
  if [ "$cap" = "adb" ] && [ -z "$MODE_SERIAL" ]; then SKIPPED+=("$name"); printf '  %s(skip)%s %s\n' "$DIM" "$N" "$name"; return 0; fi
  src=$([ -n "$MODE_SERIAL" ] && printf 'adb' || printf 'local')
  {
    printf '# dump:    %s\n# source:  %s\n# serial:  %s\n# command: %s\n# date:    %s\n# ---------------- output ----------------\n' \
      "$name" "$src" "${MODE_SERIAL:-local}" "$cmd" "$(date -Is 2>/dev/null || date)"
    run_dev "$cmd"
  } > "$RAW/$name.txt" 2>&1
  DUMPED+=("$name")
  printf '  %sok%s   %-22s %s lines\n' "$G" "$N" "$name" "$(wc -l <"$RAW/$name.txt" | tr -d ' ')"
}

collect() {
  mkdir -p "$RAW" || { err "cannot create $RAW"; exit 1; }
  info "collecting hardware data (source: ${MODE_SERIAL:+adb device $MODE_SERIAL}${MODE_SERIAL:-local Termux})"
  say "${DIM}  -- read-only: no command in this list writes anything --${N}"

  # ---- always available (local or adb) ----
  dump props_all      "getprop"                                                    local
  dump cpuinfo        "cat /proc/cpuinfo"                                          local
  dump meminfo        "cat /proc/meminfo"                                          local
  dump version        "cat /proc/version; uname -a; uname -m"                      local
  dump cmdline        "cat /proc/cmdline"                                          local
  dump partitions     "cat /proc/partitions"                                       local
  dump mounts         "cat /proc/mounts"                                           local
  dump df             "df -h 2>/dev/null || df"                                    local
  dump byname         "ls -l /dev/block/by-name 2>/dev/null || ls /dev/block"      local
  dump block_platform "ls -l /dev/block/platform/*/by-name 2>/dev/null"            local
  dump input_devices  "cat /proc/bus/input/devices"                                local
  dump thermal        "for f in /sys/class/thermal/thermal_zone*/type; do printf '%s=' \"\$f\"; cat \"\$f\"; done 2>/dev/null" local
  dump cpu_freq       "for c in /sys/devices/system/cpu/cpu[0-9]*; do printf '%s ' \"\$c\"; cat \"\$c/cpufreq/cpuinfo_max_freq\" 2>/dev/null || echo n/a; done" local
  dump ged_hal        "ls /sys/kernel/ged/hal 2>/dev/null; cat /sys/kernel/ged/hal/custom_boost_gpu_freq 2>/dev/null" local
  dump soc0           "for f in machine family soc_id revision; do printf '%s=' \"\$f\"; cat /sys/devices/soc0/\$f 2>/dev/null; done" local
  dump mem_blocks     "ls /sys/block 2>/dev/null; cat /proc/devices"               local

  # ---- deep dumps (need adb: Termux as a normal app cannot read these) ----
  dump mtk_dumchar    "cat /proc/dumchar_info"                                     adb
  dump mtk_emmc       "cat /proc/emmc"                                             adb
  dump fstab          "cat /vendor/etc/fstab* /fstab* 2>/dev/null; ls /vendor/etc | grep -i fstab" adb
  dump vendor_prop    "cat /vendor/build.prop 2>/dev/null; cat /vendor/odm/etc/build.prop 2>/dev/null" adb
  dump system_prop    "cat /system/build.prop 2>/dev/null"                         adb
  dump treble_props   "getprop | grep -iE 'treble|vndk|board|platform|hardware|boot_|slot'" adb
  dump display        "wm size; wm density; dumpsys display 2>/dev/null | head -60" adb
  dump gpu            "dumpsys SurfaceFlinger 2>/dev/null | grep -iE 'gles|renderer|vendor|version' | head -20" adb
  dump camera         "dumpsys media.camera 2>/dev/null | grep -iE 'camera module|device [0-9]|number of' | head -40" adb
  dump sensors        "dumpsys sensorservice 2>/dev/null | grep -iE 'handle=|sensor list|[0-9]+ sensors' | head -40" adb
  dump hal_files      "ls /vendor/lib64/hw 2>/dev/null; ls /vendor/lib/hw 2>/dev/null; ls /system/lib64/hw 2>/dev/null; ls /system/lib/hw 2>/dev/null" adb
  dump treble_perm    "ls /system/etc/permissions 2>/dev/null | grep -i 'treble\\|compatibility'; ls /vendor/etc/permissions 2>/dev/null" adb
  dump battery        "dumpsys battery"                                            adb
  dump bootchain      "getprop ro.boot.verifiedbootstate; getprop ro.boot.flash.locked; getprop ro.boot.veritymode; getprop ro.secure; getprop ro.debuggable; getprop ro.build.type; getprop ro.boot.slot_suffix" adb
  dump selinux        "getenforce 2>/dev/null; cat /sys/fs/selinux/enforce 2>/dev/null" adb
  dump kernel_cfg     "zcat /proc/config.gz 2>/dev/null | head -300"               adb
  dump pkg_count      "pm list packages 2>/dev/null | wc -l; pm list packages -3 2>/dev/null | wc -l" adb
  dump abi_list       "getprop ro.product.cpu.abilist; getprop ro.product.cpu.abilist32; getprop ro.product.cpu.abilist64; getprop ro.product.cpu.abi" adb
  dump lib_dirs       "ls /system/lib64 2>/dev/null | head -3; ls /system/lib 2>/dev/null | head -3; ls /vendor/lib64 2>/dev/null | head -3; ls /vendor/lib 2>/dev/null | head -3" adb
  dump recovery_misc  "ls -l /dev/block/by-name 2>/dev/null | grep -iE 'recovery|misc|vbmeta|super|metadata'" adb

  say ""
  if [ "${#SKIPPED[@]}" -gt 0 ]; then
    warn "${#SKIPPED[@]} deep dumps skipped (no adb connection): ${SKIPPED[*]}"
    say  "    For a complete profile: connect first, e.g."
    say  "      bash selfadb.sh connect        # from the Self-Adb-For-Android-9 repo"
    say  "      bash amsrom.sh all --serial 127.0.0.1:5555"
  fi
  ok "raw dumps: ${#DUMPED[@]} files in $RAW"
}

# ---------- fact extraction --------------------------------------------------
gprop() { # gprop NAME  -> value from any props dump (getprop or build.prop style)
  local key="$1" v
  v="$(grep -h -m1 "^\[$key\]: \[" "$RAW"/*.txt 2>/dev/null | sed -E 's/^\[[^]]*\]: \[(.*)\]$/\1/')"
  if [ -z "$v" ]; then
    v="$(grep -h -m1 "^${key}=" "$RAW"/*.txt 2>/dev/null | head -n1 | cut -d= -f2-)"
  fi
  printf '%s' "$(printf '%s' "$v" | tr -d '\r' | head -n1)"
}

first_field() { # first_field FILE AWK_EXPR   (skips the '# ' header of our dumps)
  local out
  out="$(grep -v '^#' "$1" 2>/dev/null | tr -d '\r')"
  printf '%s' "$(printf '%s\n' "$out" | awk "$2" 2>/dev/null | head -n1)"
}

FACTS_FILE=""
kv() { printf '%s=%s\n' "$1" "$2" >> "$FACTS_FILE"; }
FACTS=();  # for the report table
kvset() { kv "$1" "$2"; FACTS+=("$1|$2"); }

analyze() {
  FACTS_FILE="$HW/facts.kv"; : > "$FACTS_FILE"
  info "analysing collected data"

  # ----- identity -----
  local brand model device board hw platform android sdk buildid fp patch btype
  brand="$(gprop ro.product.brand)";      [ -z "$brand" ] && brand="$(gprop ro.product.vendor.brand)"
  model="$(gprop ro.product.model)";      [ -z "$model" ] && model="$(gprop ro.product.vendor.model)"
  device="$(gprop ro.product.device)"    # codename
  board="$(gprop ro.product.board)";      [ -z "$board" ] && board="$(gprop ro.board.board)"
  hw="$(gprop ro.hardware)"
  platform="$(gprop ro.board.platform)"; [ -z "$platform" ] && platform="$(gprop ro.mediatek.platform)"
  android="$(gprop ro.build.version.release)"; sdk="$(gprop ro.build.version.sdk)"
  buildid="$(gprop ro.build.id)"; fp="$(gprop ro.build.fingerprint)"
  patch="$(gprop ro.build.version.security_patch)"; btype="$(gprop ro.build.type)"

  # codename fallback: ro.product.device is authoritative; else clean the model
  local codename="$device"
  if [ -z "$codename" ]; then
    codename="$(printf '%s' "$model" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_')"
    [ -z "$codename" ] && codename="unknown"
  fi

  kvset "device.brand" "$brand"; kvset "device.model" "$model"
  kvset "device.codename" "$codename"; kvset "device.board" "$board"
  kvset "build.android" "$android"; kvset "build.sdk" "$sdk"
  kvset "build.id" "$buildid"; kvset "build.type" "$btype"
  kvset "build.security_patch" "$patch"; kvset "build.fingerprint" "$fp"

  # ----- SoC family -----
  local soc_family="unknown" soc_reason=""
  if [ -n "$(gprop ro.mediatek.platform)" ] \
     || grep -qE 'md1img|preloader|lk' "$RAW/byname.txt" "$RAW/block_platform.txt" 2>/dev/null \
     || grep -q 'Part_Name' "$RAW/mtk_dumchar.txt" 2>/dev/null; then
    soc_family="mediatek"; soc_reason="MTK partitions (preloader/md1img/lk) and/or /proc/dumchar_info present"
  fi
  local soc_name="$platform"
  [ -z "$soc_name" ] && soc_name="$(first_field "$RAW/cpuinfo.txt" '/[Hh]ardware/{sub(/^[^:]*: */,""); print; exit}')"
  if [ "$soc_family" = "mediatek" ] && printf '%s' "$soc_name" | grep -qi '^MT'; then
    soc_reason="$soc_reason; SoC id reported as $soc_name"
  fi
  local soc_mkt="unknown"
  case "$soc_name" in
    *[Mm][Tt]6761*) soc_mkt="MediaTek MT6761 Helio A22 (4x Cortex-A53 @2.0GHz, PowerVR GE8320)"; soc_reason="$soc_reason; MT6761 = Helio A22" ;;
    *[Mm][Tt]6762*) soc_mkt="MediaTek MT6762 Helio P22 (8x Cortex-A53 @2.0GHz, PowerVR GE8320)"; soc_reason="$soc_reason; MT6762 = Helio P22" ;;
    *[Mm][Tt]6765*) soc_mkt="MediaTek MT6765 Helio P35 (8x Cortex-A53, PowerVR GE8320)" ;;
  esac
  kvset "soc.family" "$soc_family"; kvset "soc.name" "$soc_name"; kvset "soc.marketing" "$soc_mkt"

  # ----- CPU / ABI -----
  local cores unicorn
  cores="$(grep -c '^processor' "$RAW/cpuinfo.txt" 2>/dev/null)"
  [ -z "$cores" ] || [ "$cores" = "0" ] && cores="$(first_field "$RAW/cpuinfo.txt" '/cpu cores/{print $NF; exit}')"
  local abilist abi64 abi32
  abilist="$(gprop ro.product.cpu.abilist)"; abi64="$(gprop ro.product.cpu.abilist64)"; abi32="$(gprop ro.product.cpu.abilist32)"
  if [ -z "$abilist" ]; then
    abilist="$(grep -h -m1 'abilist' "$RAW"/*.txt 2>/dev/null | head -n1)"
  fi
  local kmachine
  kmachine="$(first_field "$RAW/version.txt" '/^(aarch64|armv7l|armv8l|arm|x86_64|i686)/{print; exit}')"
  local userspace_bits="unknown"
  case "$abilist" in
    *arm64*) userspace_bits="64" ;;
    *armeabi*) [ -n "$abilist" ] && userspace_bits="32" ;;
  esac
  local img_arch="unknown"
  if [ "$userspace_bits" = "64" ]; then img_arch="arm64"
  elif printf '%s' "$kmachine" | grep -q 'aarch64'; then img_arch="arm32_binder64"   # A64: 64-bit kernel, 32-bit userspace
  elif [ "$userspace_bits" = "32" ]; then img_arch="arm"
  fi
  kvset "cpu.cores" "$cores"; kvset "cpu.abilist" "$abilist"
  kvset "cpu.abilist64" "$abi64"; kvset "cpu.abilist32" "$abi32"
  kvset "cpu.kernel_machine" "$kmachine"; kvset "cpu.userspace_bits" "$userspace_bits"
  kvset "gsi.arch_class" "$img_arch"

  # ----- memory / storage / display / gpu -----
  local memkb memmb
  memkb="$(first_field "$RAW/meminfo.txt" '/^MemTotal:/{print $2; exit}')"
  if [ -n "$memkb" ]; then memmb=$(( memkb / 1024 )); else memmb="unknown"; fi
  local data_avail
  data_avail="$(first_field "$RAW/df.txt" '$NF=="/data" || $NF=="/" {print $(NF-2); exit}')"
  local disp_size disp_dens
  disp_size="$(grep -h -m1 'Physical size' "$RAW/display.txt" 2>/dev/null | awk '{print $NF}')"
  [ -z "$disp_size" ] && disp_size="$(grep -h -m1 'msm_drm\|cmdline' "$RAW/cmdline.txt" 2>/dev/null | tr ' ' '\n' | grep -m1 -E '^[0-9]{3,4}x[0-9]{3,4}$')"
  disp_dens="$(grep -h -m1 'Physical density' "$RAW/display.txt" 2>/dev/null | awk '{print $NF}')"
  local gpu_renderer
  gpu_renderer="$(grep -h -m1 -iE 'GLES:' "$RAW/gpu.txt" 2>/dev/null | sed -E 's/.*GLES:[[:space:]]*//' | cut -d, -f1-2)"
  if [ -z "$gpu_renderer" ] && [ -s "$RAW/ged_hal.txt" ]; then gpu_renderer="(MTK GED present -> PowerVR GPU)"; fi
  kvset "mem.total_mb" "$memmb"; kvset "storage.data_avail" "$data_avail"
  kvset "display.size" "$disp_size"; kvset "display.density" "$disp_dens"
  kvset "gpu.renderer" "$gpu_renderer"

  # ----- cameras / sensors -----
  local cams sensors
  cams="$(grep -c -iE 'camera module|Device [0-9]+ \(' "$RAW/camera.txt" 2>/dev/null)"
  sensors="$(grep -c -iE 'handle=' "$RAW/sensors.txt" 2>/dev/null)"
  kvset "camera.entries" "$cams"; kvset "sensor.entries" "$sensors"

  # ----- partitions / boot chain -----
  local parts scheme dynamic sar vbmeta recovery
  parts="$(sed -n 's/.*[[:space:]]\([A-Za-z0-9_][A-Za-z0-9_]*\)[[:space:]]*->.*/\1/p' "$RAW/byname.txt" "$RAW/block_platform.txt" 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//')"
  if [ -z "$parts" ]; then
    parts="$(awk '/^[a-z0-9_]+[[:space:]]+0x/{print $1}' "$RAW/mtk_dumchar.txt" 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//')"
  fi
  if grep -qE 'boot_a|system_a|_a$' "$RAW/byname.txt" 2>/dev/null || [ -n "$(gprop ro.boot.slot_suffix)" ]; then scheme="A/B"; else scheme="A-only"; fi
  grep -q 'super' "$RAW/byname.txt" 2>/dev/null && dynamic="yes" || dynamic="no"
  grep -q 'vbmeta' "$RAW/byname.txt" 2>/dev/null && vbmeta="yes" || vbmeta="no"
  grep -q 'recovery' "$RAW/byname.txt" 2>/dev/null && recovery="separate" || recovery="boot-as-recovery"
  if [ "$(gprop ro.build.system_root_image)" = "1" ] || grep -qE ' / ext4| / (erofs|f2fs)' "$RAW/mounts.txt" 2>/dev/null; then sar="yes"; else sar="no"; fi
  kvset "part.scheme" "$scheme"; kvset "part.dynamic_partitions" "$dynamic"
  kvset "part.vbmeta" "$vbmeta"; kvset "part.recovery" "$recovery"; kvset "part.system_as_root" "$sar"
  kvset "part.list" "$parts"
  kvset "gsi.partition" "$([ "$scheme" = "A/B" ] && printf 'ab' || printf 'aonly')"

  # ----- bootloader / security state -----
  local vbs locked veritymode secure debuggable selinux
  vbs="$(gprop ro.boot.verifiedbootstate)"; locked="$(gprop ro.boot.flash.locked)"
  veritymode="$(gprop ro.boot.veritymode)"; secure="$(gprop ro.secure)"; debuggable="$(gprop ro.debuggable)"
  selinux="$(first_field "$RAW/selinux.txt" 'NR==1{print; exit}')"
  kvset "boot.verified_boot_state" "$vbs"; kvset "boot.flash_locked" "$locked"
  kvset "boot.verity_mode" "$veritymode"; kvset "boot.secure" "$secure"
  kvset "boot.debuggable" "$debuggable"; kvset "selinux" "$selinux"

  # ----- kernel -----
  local kver
  kver="$(first_field "$RAW/version.txt" '/Linux version/{print $3; exit}')"
  kvset "kernel.version" "$kver"

  # ----- treble / GSI readiness -----
  local treble vndk
  treble="$(gprop ro.treble.enabled)"
  vndk="$(gprop ro.vndk.version)"
  if [ -z "$treble" ]; then
    if grep -q 'vendor' "$RAW/byname.txt" 2>/dev/null && [ -n "$(grep -h -m1 'vendor' "$RAW/fstab.txt" 2>/dev/null)" ]; then
      treble="unset (but vendor partition + vndk=$vndk found -> likely Treble-capable)"
    else
      treble="unset"
    fi
  fi
  kvset "treble.enabled" "$treble"; kvset "treble.vndk_version" "$vndk"
  local treble_ok="no"
  case "$treble" in 1|true|"unset (but"*) treble_ok="yes" ;; esac
  kvset "treble.likely_capable" "$treble_ok"

  # ----- verdict -----
  local verdict
  if [ "$treble_ok" = "yes" ] && [ "$img_arch" != "unknown" ]; then
    verdict="GSI route: flash an Android 11-13 GSI built for ${img_arch} + $([ "$scheme" = "A/B" ] && printf 'A/B' || printf 'A-only')"
  else
    verdict="Source-port route: no Treble/arch signal -> a full device tree + kernel source port is required (much bigger job)"
  fi
  kvset "verdict" "$verdict"
  ok "facts written: $FACTS_FILE (${#FACTS[@]} keys)"
}

# ---------- report writers ---------------------------------------------------
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr -d '\r' | tr '\n' ' '; }

write_profile_json() {
  local f="$HW/profile.json"
  {
    printf '{\n'
    printf '  "generator": "amsrom.sh %s",\n' "$VERSION"
    printf '  "generated_at": "%s",\n' "$(date -Is 2>/dev/null || date)"
    if [ -n "$MODE_SERIAL" ]; then printf '  "collected_via": "adb_device",\n  "adb_serial": "%s",\n' "$(json_escape "$MODE_SERIAL")"
    else printf '  "collected_via": "local_termux",\n'; fi
    printf '  "source_dumps": {\n'
    local i n
    for i in "${!DUMPED[@]}"; do
      n="${DUMPED[$i]}"
      printf '    "%s": "hardware/raw/%s.txt"%s\n' "$(json_escape "$n")" "$(json_escape "$n")" \
        "$([ "$i" -lt $(( ${#DUMPED[@]} - 1 )) ] && printf ',' || printf '')"
    done
    printf '  },\n'
    printf '  "hardware": {\n'
    local first=1 key val
    while IFS='=' read -r key val; do
      [ -z "$key" ] && continue
      [ "$first" = "1" ] || printf ',\n'
      first=0
      printf '    "%s": "%s"' "$(json_escape "$key")" "$(json_escape "$val")"
    done < "$FACTS_FILE"
    printf '\n  }\n}\n'
  } > "$f"
  ok "machine-readable profile: $f"
}

report_table() {
  local key val
  while IFS='=' read -r key val; do
    [ -z "$key" ] && continue
    printf '| `%s` | %s |\n' "$key" "${val:-_(empty)_}"
  done < "$FACTS_FILE"
}

write_report() {
  local f="$HW/report.md"
  local brand model codename android soc scheme imgarch mem disp gpu kernel treble vndk
  brand="$(gprop ro.product.brand)"; model="$(gprop ro.product.model)"; codename="$(gprop ro.product.device)"
  android="$(gprop ro.build.version.release)"; soc="$(gprop ro.board.platform)"
  {
    printf '# AMS ROM — hardware analysis report\n\n'
    local srcdesc="Termux on the device (local mode)"
    [ -n "$MODE_SERIAL" ] && srcdesc="adb device $MODE_SERIAL"
    printf 'Generated by `amsrom.sh %s` on %s (data source: %s).\n\n' \
      "$VERSION" "$(date -Is 2>/dev/null || date)" "$srcdesc"
    printf '> Everything below was read with read-only commands. Nothing was modified,\n> flashed, rooted or even mounted rw. Raw proof is in `hardware/raw/`.\n\n'

    printf '## 1. Identity\n\n'
    printf -- '- **Brand / model:** %s %s\n' "${brand:-?}" "${model:-?}"
    printf -- '- **Codename (`ro.product.device`):** %s\n' "${codename:-?}"
    printf -- '- **Android:** %s (SDK %s), build %s, type %s\n' \
      "${android:-?}" "$(gprop ro.build.version.sdk)" "$(gprop ro.build.id)" "$(gprop ro.build.type)"
    printf -- '- **Security patch:** %s\n' "$(gprop ro.build.version.security_patch)"
    printf -- '- **Fingerprint:** `%s`\n\n' "$(gprop ro.build.fingerprint)"

    printf '## 2. SoC, CPU, memory\n\n'
    printf -- '- **SoC:** %s  (family: %s, id: %s)\n' \
      "$(grep -m1 '^soc.marketing=' "$FACTS_FILE" | cut -d= -f2)" \
      "$(grep -m1 '^soc.family=' "$FACTS_FILE" | cut -d= -f2)" \
      "$(grep -m1 '^soc.name=' "$FACTS_FILE" | cut -d= -f2)"
    printf -- '- **Platform id:** %s (%s)\n' "$(gprop ro.board.platform)" "$(gprop ro.mediatek.platform)"
    printf -- '- **Hardware id:** %s / board %s\n' "$(gprop ro.hardware)" "$(gprop ro.product.board)"
    printf -- '- **ARM class for GSI choice:** `%s` (kernel machine `%s`, userspace %s-bit)\n' \
      "$(grep -m1 '^gsi.arch_class=' "$FACTS_FILE" | cut -d= -f2)" \
      "$(grep -m1 '^cpu.kernel_machine=' "$FACTS_FILE" | cut -d= -f2)" \
      "$(grep -m1 '^cpu.userspace_bits=' "$FACTS_FILE" | cut -d= -f2)"
    printf -- '- **CPU cores:** %s · **ABI list:** `%s`\n' \
      "$(grep -m1 '^cpu.cores=' "$FACTS_FILE" | cut -d= -f2)" "$(grep -m1 '^cpu.abilist=' "$FACTS_FILE" | cut -d= -f2)"
    printf -- '- **RAM:** %s MB · **free on /data:** %s\n\n' \
      "$(grep -m1 '^mem.total_mb=' "$FACTS_FILE" | cut -d= -f2)" "$(grep -m1 '^storage.data_avail=' "$FACTS_FILE" | cut -d= -f2)"

    printf '## 3. Display, GPU, cameras, sensors\n\n'
    printf -- '- **Display:** %s @ %s dpi\n' "$(grep -m1 '^display.size=' "$FACTS_FILE" | cut -d= -f2)" "$(grep -m1 '^display.density=' "$FACTS_FILE" | cut -d= -f2)"
    printf -- '- **GPU:** %s\n' "$(grep -m1 '^gpu.renderer=' "$FACTS_FILE" | cut -d= -f2)"
    printf -- '- **Camera entries seen:** %s · **sensor entries seen:** %s\n' \
      "$(grep -m1 '^camera.entries=' "$FACTS_FILE" | cut -d= -f2)" "$(grep -m1 '^sensor.entries=' "$FACTS_FILE" | cut -d= -f2)"
    printf -- '- **HAL inventory:** see `hardware/raw/hal_files.txt` (this is what a port must re-implement or reuse)\n\n'

    printf '## 4. Partitions & boot chain\n\n'
    printf -- '- **Partition scheme:** %s\n' "$(grep -m1 '^part.scheme=' "$FACTS_FILE" | cut -d= -f2)"
    printf -- '- **Dynamic partitions (super):** %s · **vbmeta:** %s · **recovery:** %s\n' \
      "$(grep -m1 '^part.dynamic_partitions=' "$FACTS_FILE" | cut -d= -f2)" \
      "$(grep -m1 '^part.vbmeta=' "$FACTS_FILE" | cut -d= -f2)" \
      "$(grep -m1 '^part.recovery=' "$FACTS_FILE" | cut -d= -f2)"
    printf -- '- **system-as-root:** %s\n' "$(grep -m1 '^part.system_as_root=' "$FACTS_FILE" | cut -d= -f2)"
    printf -- '- **Bootloader state:** verified-boot=%s, flash-locked=%s, verity=%s, SELinux=%s\n' \
      "$(grep -m1 '^boot.verified_boot_state=' "$FACTS_FILE" | cut -d= -f2)" \
      "$(grep -m1 '^boot.flash_locked=' "$FACTS_FILE" | cut -d= -f2)" \
      "$(grep -m1 '^boot.verity_mode=' "$FACTS_FILE" | cut -d= -f2)" \
      "$(grep -m1 '^selinux=' "$FACTS_FILE" | cut -d= -f2)"
    printf -- '- **Kernel:** %s\n' "$(grep -m1 '^kernel.version=' "$FACTS_FILE" | cut -d= -f2)"
    printf -- '- **Partition names seen:** `%s`\n\n' "$(grep -m1 '^part.list=' "$FACTS_FILE" | cut -d= -f2)"

    printf '## 5. Treble / GSI readiness\n\n'
    printf -- '- **ro.treble.enabled:** `%s`\n' "$(grep -m1 '^treble.enabled=' "$FACTS_FILE" | cut -d= -f2)"
    printf -- '- **VNDK version:** `%s`\n' "$(grep -m1 '^treble.vndk_version=' "$FACTS_FILE" | cut -d= -f2)"
    printf -- '- **Verdict:** **%s**\n\n' "$(grep -m1 '^verdict=' "$FACTS_FILE" | cut -d= -f2)"

    printf '## 6. Every collected fact\n\n| key | value |\n|---|---|\n'
    report_table
    printf '\n'
  } > "$f"
  ok "human-readable report: $f"
}

# ---------- project scaffold -------------------------------------------------
write_device_tree() {
  local vnd dev arch platform cmdline kernel kver pagesize
  vnd="$(gprop ro.product.brand | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"; [ -z "$vnd" ] && vnd="vendor"
  dev="$(gprop ro.product.device | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_')"; [ -z "$dev" ] && dev="$(grep -m1 '^device.codename=' "$FACTS_FILE" | cut -d= -f2)"
  arch="$(grep -m1 '^gsi.arch_class=' "$FACTS_FILE" | cut -d= -f2)"
  platform="$(gprop ro.board.platform)"; [ -z "$platform" ] && platform="unknown"
  cmdline="$(first_field "$RAW/cmdline.txt" 'NR==1{print; exit}')"
  kernel="$(first_field "$RAW/version.txt" 'NR==1{print; exit}')"
  kver="$(grep -m1 '^kernel.version=' "$FACTS_FILE" | cut -d= -f2)"
  local d="$OUT/device/$vnd/$dev"
  mkdir -p "$d"

  local tarch t2nd
  case "$arch" in
    arm64)            tarch="arm64"; t2nd="arm" ;;
    arm32_binder64)   tarch="arm";   t2nd="" ;;
    arm)              tarch="arm";   t2nd="" ;;
    *)                tarch="arm64"; t2nd="arm" ;;
  esac

  cat > "$d/BoardConfig.mk" <<EOF
# AMS ROM - generated device tree skeleton (BoardConfig)
# Values below were READ FROM YOUR DEVICE. Lines marked TODO must be verified
# against the stock firmware / MTK scatter file before you trust a build.

TARGET_ARCH           := $tarch
$([ -n "$t2nd" ] && printf 'TARGET_2ND_ARCH      := %s\n' "$t2nd")
TARGET_BOARD_PLATFORM := $platform
TARGET_BOOTLOADER_BOARD_NAME := $platform
TARGET_KERNEL_ARCH    := $([ "$tarch" = "arm64" ] && printf 'arm64' || printf 'arm')

# Detected kernel: $kver
# Full string: $kernel
BOARD_KERNEL_CMDLINE  := $cmdline          # TODO: verify against stock boot.img
BOARD_KERNEL_BASE     := 0x40000000        # TODO: MTK default, verify in boot.img
BOARD_KERNEL_PAGESIZE := 2048              # TODO: verify (2048 = MTK common)
BOARD_KERNEL_IMAGE_NAME := Image$([ "$tarch" = "arm" ] && printf '.gz' || true)

# --- partitions (sizes read from /proc/partitions when available) ---
# TODO: fill the *_SIZE values from hardware/raw/partitions.txt (blocks are 1KiB)
#       BOARD_SYSTEMIMAGE_PARTITION_SIZE :=
#       BOARD_VENDORIMAGE_PARTITION_SIZE :=
#       BOARD_BOOTIMAGE_PARTITION_SIZE   :=
BOARD_USES_METADATA_PARTITION := true
BOARD_AVB_ENABLE := true                   # device ships vbmeta (detected)

# --- MTK specifics ---
# BOARD_USES_MTK_HARDWARE := true          # TODO if you port a full tree
# TARGET_USES_MTK_ION := true
EOF

  cat > "$d/device.mk" <<EOF
# AMS ROM - generated device tree skeleton (device.mk)
# This is where vendor blobs and HALs from the STOCK firmware get wired up.
# Nothing here is functional yet: it is a checklist with a real structure.

LOCAL_PATH := \$(call my-dir)

# 1) vendor blobs - extract from YOUR stock ROM (see AMS-ROM/backups/README.md)
# \$(call inherit-product-if-exists, vendor/$vnd/$dev/$dev-vendor.mk)

PRODUCT_PACKAGES += \\
    # TODO: HALs seen on your device are listed in hardware/raw/hal_files.txt
EOF

  cat > "$d/AndroidProducts.mk" <<EOF
# AMS ROM - generated
PRODUCT_MAKEFILES := \$(LOCAL_DIR)/ams_$dev.mk

COMMON_LUNCH_CHOICES := \\
    ams_$dev-user \\
    ams_$dev-userdebug \\
    ams_$dev-eng
EOF

  cat > "$d/ams_$dev.mk" <<EOF
# AMS ROM - product definition (generated skeleton)
\$(call inherit-product, \$(SRC_TARGET_DIR)/product/aosp_base_telephony.mk)
\$(call inherit-product, device/$vnd/$dev/device.mk)

PRODUCT_NAME   := ams_$dev
PRODUCT_DEVICE := $dev
PRODUCT_BRAND  := $vnd
PRODUCT_MODEL  := $dev
PRODUCT_MANUFACTURER := $vnd
PRODUCT_CHARACTERISTICS := nosdcard
EOF

  cat > "$d/vendorsetup.sh" <<EOF
# AMS ROM - generated: source this before lunch
add_lunch_combo ams_$dev-userdebug
EOF

  cat > "$d/README.md" <<EOF
# Device tree skeleton: $vnd/$dev

Generated by \`amsrom.sh\` from real device data. It is a **skeleton**, not a
working tree — a real port still needs the items in
\`AMS-ROM/README.md -> Roadmap\`.

Detected: arch \`$arch\`, platform \`$platform\`, kernel \`$kver\`,
partition scheme \`$(grep -m1 '^part.scheme=' "$FACTS_FILE" | cut -d= -f2)\`.
EOF

  ok "device tree skeleton: $d"
}

write_gsi_docs() {
  local arch scheme dev
  arch="$(grep -m1 '^gsi.arch_class=' "$FACTS_FILE" | cut -d= -f2)"
  scheme="$(grep -m1 '^gsi.partition=' "$FACTS_FILE" | cut -d= -f2)"
  dev="$(grep -m1 '^device.codename=' "$FACTS_FILE" | cut -d= -f2)"
  mkdir -p "$OUT/gsi"
  cat > "$OUT/gsi/candidates.md" <<EOF
# GSI candidates for this device

Detected profile: **arch class \`$arch\`**, **partition scheme \`$scheme\`**,
codename \`$dev\`. GSI images are named \`system-<arch>-<scheme>-<flavour>.img\`,
so the files that match this profile are:

- \`system-$arch-$scheme-*.img\`  ← your match
- flavours: \`vanilla\` (no Google apps) or \`gapps\`; \`-su\` variants ship su/root

Where to get GSIs (pick ONE flavour, always the newest build):

| Source | What it is | Notes |
|---|---|---|
| phhusson/treble_experimentations (Releases) | AOSP-based GSI, the reference | best HAL compatibility on MTK |
| AndyYan's LineageOS GSI (SourceForge) | LineageOS 18.1 / 19.1 / 20 GSI | most popular, Android 11-13 |
| other GSIs (DOT OS, crDroid, PixelExperience GSI) | themed builds | check "treble" in the release notes |

## Reality check from other X650C owners

Community field reports for **Infinix Hot 8 (X650C)** say a DOT OS 5.2 GSI was
"the most stable, bug-free and recent GSI tested", Android 12 GSIs boot with:

- Wi-Fi hotspot, USB tethering and Bluetooth tethering **not working**
- VoLTE / mobile data needs an **IMS APK** installed
- verified boot must be disabled with
  \`fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img\`

Source: https://github.com/TadiT7/treble_experimentations_wiki/blob/master/Infinix-Hot-8.md
(that page also notes the \`-ab\` image was the one that booted there — if your
device reports A-only and the A/B image fails to boot, retry with the \`-aonly\` one.)

## Before you flash anything

1. Read \`../backups/README.md\` and DO the backups. IMEI/NVRAM loss is a real risk on MTK.
2. Unlock the bootloader (\`fastboot flashing unlock\`), accept the data wipe.
3. Keep the **exact stock firmware** for your build (SP Flash Tool loadable) offline.
4. Only then: \`bash flash-gsi.sh system-<arch>-<scheme>-*.img\` (dry run by default).
EOF

  cat > "$OUT/gsi/flash-gsi.sh" <<'EOF'
#!/usr/bin/env bash
# AMS ROM - GSI flasher. DRY RUN by default: it only prints what it would do.
# Add --yes-i-know-i-can-brick to actually write anything.
#
#   bash flash-gsi.sh /path/to/system-XXXX.img            # dry run
#   bash flash-gsi.sh /path/to/system-XXXX.img --yes-i-know-i-can-brick
#
# It NEVER flashes preloader / lk / tee / md1img / modem. Flashing those with a
# mismatched image is the classic hard-brick on MediaTek devices.
set -uo pipefail
IMG="${1:-}"; GO="${2:-}"
[ -z "$IMG" ] && { echo "usage: bash flash-gsi.sh <system.img> [--yes-i-know-i-can-brick]"; exit 64; }
[ -f "$IMG" ] || { echo "no such file: $IMG"; exit 66; }

VB="vbmeta.img"
cat <<EOM
=== AMS ROM GSI flash plan (device: Infinix X650C class MTK, A-only SAR) ===
  fastboot --disable-verity --disable-verification flash vbmeta $VB
  fastboot flash system $IMG
  fastboot -w
  fastboot reboot

NEVER touched by this script: preloader, lk, tee1/tee2, md1img, modem, nvram.
(Flashing those with a mismatched image is the classic hard-brick on MediaTek.)

Requirements before this works:
  * bootloader unlocked (fastboot flashing unlock)
  * a $VB from YOUR stock firmware present in this folder (or a known-good one)
  * stock firmware ZIP kept aside for SP Flash Tool in case of brick
EOM
if [ "$GO" != "--yes-i-know-i-can-brick" ]; then
  echo "DRY RUN - nothing written. Re-run with --yes-i-know-i-can-brick to flash."
  exit 0
fi
command -v fastboot >/dev/null || { echo "fastboot not found (pkg install android-tools / platform-tools)"; exit 69; }
fastboot devices | grep -q . || { echo "device not in fastboot mode"; exit 69; }
[ -f "$VB" ] || { echo "refusing: $VB missing - flash the stock vbmeta first"; exit 70; }
set -x
fastboot --disable-verity --disable-verification flash vbmeta "$VB" || exit 1
fastboot flash system "$IMG" || exit 1
fastboot -w || exit 1
fastboot reboot
EOF
  chmod +x "$OUT/gsi/flash-gsi.sh"

  cat > "$OUT/build/build-rom.sh" <<'EOF'
#!/usr/bin/env bash
# AMS ROM - source-build wrapper (template).
# Only useful once device/<vendor>/<device>/ holds a REAL device tree:
# kernel source (MediaTek archive / your own dump), vendor blobs, HALs.
set -euo pipefail
ROM_SRC="${ROM_SRC:-$HOME/android/lineage}"
DEVICE="${1:-}"
[ -z "$DEVICE" ] && { echo "usage: ROM_SRC=~/android/lineage bash build-rom.sh <device>"; exit 64; }
[ -d "$ROM_SRC" ] || { echo "no ROM source at $ROM_SRC (repo sync LineageOS/AOSP first)"; exit 66; }
cp -r "$(dirname "$0")/../device"/* "$ROM_SRC/device/" 2>/dev/null || true
cd "$ROM_SRC"
. build/envsetup.sh
lunch "ams_${DEVICE}-userdebug"
mka bacon -j"$(nproc)"
EOF
  chmod +x "$OUT/build/build-rom.sh"
  ok "GSI + build guidance written"
}

write_backups_doc() {
  mkdir -p "$OUT/backups"
  cat > "$OUT/backups/README.md" <<'EOF'
# DO THIS BEFORE YOU UNLOCK OR FLASH ANYTHING

Unlocking the bootloader wipes all data and, on MediaTek phones, a bad flash can
destroy the IMEI/NVRAM — a phone that boots but can never make a call again.
These steps are 20 minutes and save the device.

## 1. Save the stock firmware (non-negotiable)
Download the **exact** firmware for your build (`X650C-H626xx-...`), the
`MT67xx_Android_scatter.txt` and **SP Flash Tool** from a trusted mirror
(Hovatek firmware section is the usual source). Keep them on a PC *and* a USB
stick. This is the only reliable unbrick path for preloader-level failures.

## 2. Dump your own partitions first (through TWRP, or adb with root)
Critical ones on MTK: `nvram`, `nvdata`, `nvcfg`, `protect1`, `protect2`,
`persist`, `proinfo`, `boot`, `recovery`, `vbmeta`, `preloader` (read-only!).
With root shell:
```
dd if=/dev/block/by-name/nvram  of=/sdcard/nvram.img
dd if=/dev/block/by-name/nvdata of=/sdcard/nvdata.img
dd if=/dev/block/by-name/protect1 of=/sdcard/protect1.img
dd if=/dev/block/by-name/boot    of=/sdcard/boot.img
```
Without root: use SP Flash Tool *Readback* with the scatter file, or a TWRP
backup of at least Boot + Nvram + Nvdata + Persist + Protect.

## 3. Record your identity
Write down the IMEI(s) (`*#06#`), MAC addresses, and your current build number.
Screenshot the Developer-options toggles you changed.

## 4. Know the consequences of unlocking
- full data wipe
- "orange state" warning on every boot (removable with an MTK orange-state disabler zip)
- Widevine L1 and some banking/DRM apps stop working or complain
- SafetyNet/Play Integrity fails until you re-lock or use a fix
- OTA updates stop installing

## 5. Have a rescue plan ready
Preloader (VCOM) USB driver installed, SP Flash Tool tested, cable you trust,
battery above 80%, and the stock firmware in hand *before* the first flash.
EOF
  ok "backup checklist written"
}

write_project_readme() {
  local brand model codename android soc arch scheme
  brand="$(gprop ro.product.brand)"; model="$(gprop ro.product.model)"
  codename="$(grep -m1 '^device.codename=' "$FACTS_FILE" | cut -d= -f2)"
  android="$(gprop ro.build.version.release)"; soc="$(gprop ro.board.platform)"
  arch="$(grep -m1 '^gsi.arch_class=' "$FACTS_FILE" | cut -d= -f2)"
  scheme="$(grep -m1 '^part.scheme=' "$FACTS_FILE" | cut -d= -f2)"
  cat > "$OUT/README.md" <<EOF
# AMS ROM — project folder

Custom-ROM project for **${brand:-?} ${model:-?}** (codename \`${codename:-?}\`,
${soc:-unknown SoC}, Android ${android:-?} stock), generated by \`amsrom.sh\`.

    Status: hardware analysed ✅ | device tree skeleton ✅ | buildable tree ❌ (needs the roadmap items)

## What the analysis says

- ARM class for image choice: **$arch**
- Partition scheme: **$scheme**
- Recommended route: **$(grep -m1 '^verdict=' "$FACTS_FILE" | cut -d= -f2)**
- Full report: \`hardware/report.md\` · raw proof: \`hardware/raw/\` · facts: \`hardware/facts.kv\`

## Layout

| Path | What it is |
|---|---|
| \`hardware/report.md\` | human-readable analysis of your device |
| \`hardware/profile.json\` | the same data, machine-readable |
| \`hardware/raw/*.txt\` | every raw dump, exactly as read from the device |
| \`device/<vendor>/<codename>/\` | AOSP-style device tree skeleton (BoardConfig, device.mk, product makefiles) |
| \`gsi/candidates.md\` | which GSI images fit this exact profile + known X650C field reports |
| \`gsi/flash-gsi.sh\` | flashing helper — **dry run by default** |
| \`build/build-rom.sh\` | wrapper for a source build once a real tree exists |
| \`backups/README.md\` | **read this first** — what to save before unlocking/flashing |

## Two roads to AMS ROM

### Road A — GSI (hours, low risk, works today)
1. Back up (\`backups/README.md\`) — firmware, NVRAM/IMEI, stock boot image.
2. Unlock bootloader: enable *OEM unlocking* + *USB debugging*, then
   \`fastboot flashing unlock\` (wipes everything).
3. \`fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img\`
4. \`fastboot flash system system-$arch-$scheme-<flavour>.img\` (see \`gsi/candidates.md\`)
5. \`fastboot -w && fastboot reboot\`
6. Bonus: on Android 11+ GSIs you get **Wireless debugging with pairing** — after
   one pairing you can use adb inside Termux with **no PC ever again**
   (\`selfadb.sh pair\` / \`selfadb.sh wireless\`).

### Road B — real source port (weeks-months, high effort)
Needs, in order:
1. **Kernel source** for \`$soc\` (MediaTek archive or a dumped/ported tree that boots)
2. **Vendor blobs** extracted from your stock ROM (\`system/vendor\`) + the HAL list
   from \`hardware/raw/hal_files.txt\`
3. **A real device tree** — the skeleton in \`device/\` is the starting point; you must fill
   partition sizes, kernel cmdline, AVB config and HAL wiring
4. A working **recovery** (TWRP for X650C exists in the XDA/Hovatek guides)
5. A build host: ~150 GB disk, 16 GB RAM, Ubuntu; \`repo sync\` LineageOS/AOSP, then
   \`build/build-rom.sh <codename>\`
The skeleton files carry \`TODO\` markers on every line that needs real data.

## Warnings (read once, remember forever)

- Never flash \`preloader\`, \`lk\`, \`tee\`, \`md1img\` or \`modem\` from an unverified source —
  that is how MTK phones become bricks.
- After unlocking, the phone prints an "orange state" warning and Play Integrity fails.
- Keep the stock firmware + scatter file offline. Always.
- Nothing in this folder has been flashed by the generator. \`flash-gsi.sh\` is dry-run
  until you add \`--yes-i-know-i-can-brick\`.
EOF
  ok "project README: $OUT/README.md"
}

do_init() {
  info "creating AMS ROM project structure in $OUT"
  mkdir -p "$OUT/hardware/raw" "$OUT/gsi" "$OUT/build" "$OUT/backups"
  [ -f "$FACTS_FILE" ] || { err "no facts yet -- run: bash amsrom.sh analyze"; exit 1; }
  write_device_tree
  write_gsi_docs
  write_backups_doc
  write_project_readme
}

# ---------- info -------------------------------------------------------------
cmd_info() {
  [ -f "$FACTS_FILE" ] || { err "nothing collected yet -- run: bash amsrom.sh all"; exit 1; }
  say "${BOLD}AMS ROM — quick info${N} (from $FACTS_FILE)"
  printf '%s\n' "${DIM}-----------------------------------------------------------${N}"
  local key val
  for key in device.brand device.model device.codename soc.family soc.name build.android \
             cpu.cores cpu.abilist mem.total_mb display.size gpu.renderer \
             treble.enabled treble.vndk_version part.scheme part.system_as_root \
             gsi.arch_class kernel.version verdict; do
    val="$(grep -m1 "^${key}=" "$FACTS_FILE" 2>/dev/null | cut -d= -f2-)"
    printf '  %-22s %s\n' "$key" "${val:-?}"
  done
  say ""
  info "full report: $HW/report.md"
}

cmd_help() {
  cat <<EOF
${BOLD}amsrom.sh${N} v${VERSION} — hardware profiler + AMS ROM project generator

${BOLD}USAGE${N}
  bash amsrom.sh [all|collect|analyze|init|info] [options]

${BOLD}COMMANDS${N}
  all        collect + analyze + build the AMS-ROM project folder (default)
  collect    read the device (read-only) into AMS-ROM/hardware/raw/
  analyze    turn the raw dumps into facts.kv + report.md + profile.json
  init       generate the project skeleton (device tree, GSI docs, flash helper)
  info       print the key facts from the last analysis

${BOLD}OPTIONS${N}
  --serial S   use this adb device (deep mode). Default: the only one online
  --local      force local mode (Termux reads /proc, /sys, getprop itself)
  --dir PATH   output folder (default ./AMS-ROM; use --dir "AMS ROM" for a space)

${BOLD}EXAMPLES${N}
  bash amsrom.sh all                          # on the phone, no PC needed
  bash selfadb.sh connect && bash amsrom.sh all --serial 127.0.0.1:5555
  bash amsrom.sh all --dir "AMS ROM"          # literal folder name with a space
  bash amsrom.sh info

${BOLD}NOTES${N}
  * local (Termux) mode: reads /proc, /sys, getprop, /dev/block -> good profile
  * adb mode adds: partition table, fstab, HAL list, camera/sensor/GPU dumps,
    boot-chain state — the things a device tree actually needs
  * it is read-only. The only writer is gsi/flash-gsi.sh, dry-run by default.
EOF
}

# ---------- dispatch ---------------------------------------------------------
main() {
  local cmd=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --serial) MODE_SERIAL="${2:-}"; shift ;;
      --local)  FORCE_LOCAL=1 ;;
      --dir)    OUT_DIR="${2:-}"; shift ;;
      -h|--help) cmd="help" ;;
      -*)       : ;;
      *)        [ -z "$cmd" ] && cmd="$1" ;;
    esac
    shift
  done
  [ -z "$cmd" ] && cmd="all"

  case "$cmd" in
    help|-h|--help) cmd_help; return 0 ;;
    version) say "amsrom.sh $VERSION"; return 0 ;;
    info)    OUT_DIR="${OUT_DIR:-AMS-ROM}"; OUT="$OUT_DIR"; HW="$OUT/hardware"; FACTS_FILE="$HW/facts.kv"; cmd_info; return $? ;;
    help2)   : ;;
  esac

  OUT_DIR="${OUT_DIR:-AMS-ROM}"
  OUT="$OUT_DIR"; HW="$OUT/hardware"; RAW="$HW/raw"; FACTS_FILE="$HW/facts.kv"
  mkdir -p "$RAW" || exit 1

  serial_detect
  if [ -n "$MODE_SERIAL" ]; then
    ok "deep mode through adb: $MODE_SERIAL"
  else
    if [ "$FORCE_LOCAL" = "1" ]; then info "local mode (forced)"
    else warn "no adb device online -> local mode (25 deep dumps will be skipped)"
         say "    connect first for the complete profile:  bash selfadb.sh connect"
    fi
  fi

  case "$cmd" in
    collect) collect ;;
    analyze) analyze; write_profile_json; write_report ;;
    init)    do_init ;;
    all)     collect; analyze; write_profile_json; write_report; do_init
             say ""; printf '%s\n' "${DIM}-----------------------------------------------------------${N}"
             ok "AMS ROM project ready in: $OUT"
             say "    start here:  $OUT/README.md"
             say "    raw proof:   $OUT/hardware/report.md" ;;
    *) err "unknown command: $cmd"; cmd_help; exit 64 ;;
  esac
}

main "$@"
