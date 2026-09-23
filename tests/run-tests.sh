#!/usr/bin/env bash
# =============================================================================
#  tests/run-tests.sh -- verification suite for selfadb.sh and amsrom.sh
#
#  Runs everything against tests/mock/adb, a fixture-driven fake adb client
#  whose canned output was captured from an Infinix Hot 8 (X650C, MT6761,
#  Android 9, XOS 5.0). No real phone or PC is touched, nothing is written to
#  any device.
#
#      bash tests/run-tests.sh            # all tests
#      bash tests/run-tests.sh selfadb    # only the selfadb.sh tests
#      bash tests/run-tests.sh amsrom     # only the amsrom.sh tests
#
#  Exit code 0 = every assertion passed.
# =============================================================================

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS="$ROOT/tests"
MOCK="$TESTS/mock"
WORK="${TMPDIR:-/tmp}/ams-selftest.$$"
WHICH="${1:-all}"

PASS=0; FAIL=0; FAILED_NAMES=()

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; N=$'\033[0m'
else
  G=""; R=""; Y=""; B=""; BOLD=""; DIM=""; N=""
fi

t()        { printf '%s== %s%s\n' "$BOLD" "$1" "$N"; }
pass()     { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$G" "$N" "$1"; }
fail()     { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  %sFAIL%s %s\n' "$R" "$N" "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
assert_eq()      { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$3] got [$2]"; fi; }
assert_contains(){ case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "[$2] does not contain [$3]" ;; esac; }
assert_file()    { if [ -f "$2" ]; then pass "$1"; else fail "$1" "missing file: $2"; fi; }

mkdir -p "$WORK"
export PATH="$MOCK:$PATH" HOME="$WORK/home" NO_COLOR=1
mkdir -p "$HOME"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# syntax + shell sanity
# ---------------------------------------------------------------------------
if [ "$WHICH" = "all" ] || [ "$WHICH" = "selfadb" ]; then
  t "selfadb.sh"
  if bash -n "$ROOT/selfadb.sh" 2>/dev/null; then pass "bash -n selfadb.sh"; else fail "bash -n selfadb.sh"; fi

  out="$(bash "$ROOT/selfadb.sh" version 2>&1)";      assert_contains "version prints" "$out" "selfadb"
  out="$(bash "$ROOT/selfadb.sh" help 2>&1)";         assert_contains "help lists connect" "$out" "connect"
  assert_contains "help lists rom-probe" "$out" "rom-probe"
  assert_contains "help lists pair" "$out" "pair"
  assert_contains "help lists wireless" "$out" "wireless"

  # device that is already reachable at 127.0.0.1:5555
  out="$(bash "$ROOT/selfadb.sh" connect 2>&1)";      assert_contains "connect finds the device" "$out" "127.0.0.1:5555"
  bash "$ROOT/selfadb.sh" connect >/dev/null 2>&1;    assert_eq "connect exits 0" "$?" "0"
  out="$(bash "$ROOT/selfadb.sh" status 2>&1)";       assert_contains "status prints device info" "$out" "X650C"
  out="$(bash "$ROOT/selfadb.sh" doctor 2>&1)";       assert_contains "doctor reports TCP mode" "$out" "service.adb.tcp.port = 5555"

  out="$(bash "$ROOT/selfadb.sh" rom-probe 2>&1)";    assert_contains "rom-probe reads properties" "$out" "properties mentioning 'adb'"
  assert_contains "rom-probe scans settings tables" "$out" "settings keys mentioning adb"
  assert_contains "rom-probe gives the honest verdict" "$out" "PC step needed once per reboot"
  assert_contains "rom-probe prints a verdict" "$out" "VERDICT"

  out="$(bash "$ROOT/selfadb.sh" shell echo hi 2>&1)"; assert_contains "shell passes through to the device" "$out" "hi"
  out="$(bash "$ROOT/selfadb.sh" pair 1.2.3.4:37123 481920 2>&1)"; assert_contains "pair uses adb pair" "$out" "Successfully paired"
  out="$(bash "$ROOT/selfadb.sh" pair 2>&1)";         assert_contains "pair without args explains usage" "$out" "Pair device with pairing code"
  out="$(bash "$ROOT/selfadb.sh" wireless 2>&1)";     assert_contains "wireless discovers over mDNS" "$out" "_adb-tls-connect"
  out="$(bash "$ROOT/selfadb.sh" install /tmp/fake.apk 2>&1)"; assert_contains "install reaches adb" "$out" "Success"

  bash "$ROOT/selfadb.sh" bogus >/dev/null 2>&1
  assert_eq "unknown command exits 64" "$?" "64"

  # somewhere with no adb at all -> must explain, not crash
  out="$(env PATH=/usr/bin:/bin HOME="$HOME" bash "$ROOT/selfadb.sh" doctor 2>&1)"
  assert_contains "doctor without adb explains the fix" "$out" "pkg install android-tools"
fi

# ---------------------------------------------------------------------------
# amsrom.sh
# ---------------------------------------------------------------------------
if [ "$WHICH" = "all" ] || [ "$WHICH" = "amsrom" ]; then
  t "amsrom.sh"
  if bash -n "$ROOT/amsrom.sh" 2>/dev/null; then pass "bash -n amsrom.sh"; else fail "bash -n amsrom.sh"; fi

  OUT="$WORK/AMS-ROM"
  bash "$ROOT/amsrom.sh" all --serial 127.0.0.1:5555 --dir "$OUT" >"$WORK/ams.log" 2>&1
  assert_eq "amsrom all exits 0" "$?" "0"

  F="$OUT/hardware/facts.kv"
  assert_file "facts.kv written" "$F"
  assert_file "report.md written"    "$OUT/hardware/report.md"
  assert_file "profile.json written" "$OUT/hardware/profile.json"
  assert_file "device tree BoardConfig.mk written" "$OUT/device/infinix/x650c/BoardConfig.mk"
  assert_file "GSI candidates doc written"         "$OUT/gsi/candidates.md"
  assert_file "flash helper written"               "$OUT/gsi/flash-gsi.sh"
  assert_file "backup checklist written"           "$OUT/backups/README.md"
  assert_file "project README written"             "$OUT/README.md"

  fact() { grep -m1 "^$1=" "$F" 2>/dev/null | cut -d= -f2-; }
  assert_eq "brand detected"        "$(fact device.brand)"     "Infinix"
  assert_eq "codename detected"     "$(fact device.codename)"  "X650C"
  assert_eq "SoC family detected"   "$(fact soc.family)"       "mediatek"
  assert_eq "SoC identified"        "$(fact soc.name)"         "mt6761"
  assert_eq "CPU cores counted"     "$(fact cpu.cores)"        "4"
  assert_eq "RAM read from meminfo" "$(fact mem.total_mb)"     "1832"
  assert_eq "kernel version parsed" "$(fact kernel.version)"   "4.9.117+"
  assert_eq "A-only scheme detected" "$(fact part.scheme)"     "A-only"
  assert_eq "system-as-root detected" "$(fact part.system_as_root)" "yes"
  assert_eq "vbmeta partition seen"  "$(fact part.vbmeta)"     "yes"
  assert_eq "Treble capability read" "$(fact treble.enabled)"  "true"
  assert_eq "VNDK version read"      "$(fact treble.vndk_version)" "28"
  assert_eq "GSI arch class is A64"  "$(fact gsi.arch_class)"  "arm32_binder64"
  assert_eq "GSI partition flavour"  "$(fact gsi.partition)"   "aonly"

  assert_contains "partition list has vbmeta"  "$(fact part.list)" "vbmeta"
  assert_contains "partition list has nvram"   "$(fact part.list)" "nvram"
  assert_contains "verdict recommends a GSI"   "$(fact verdict)"   "GSI route"
  assert_contains "report names the SoC"       "$(cat "$OUT/hardware/report.md")" "Helio A22"
  assert_contains "device tree lists ARM class" "$(cat "$OUT/device/infinix/x650c/BoardConfig.mk")" "TARGET_ARCH           := arm"

  if python3 -c "import json,sys; json.load(open('$OUT/hardware/profile.json'))" 2>/dev/null; then
    pass "profile.json is valid JSON"
  else
    fail "profile.json is valid JSON"
  fi
  raw_count="$(find "$OUT/hardware/raw" -name '*.txt' | wc -l | tr -d ' ')"
  if [ "$raw_count" -ge 30 ]; then pass "raw dumps captured ($raw_count files)"; else fail "raw dumps captured" "only $raw_count files"; fi

  # folder name with a space, and info re-reads it
  OUTF="$WORK/AMS ROM"
  bash "$ROOT/amsrom.sh" all --serial 127.0.0.1:5555 --dir "$OUTF" >/dev/null 2>&1
  assert_file "project works with a space in --dir" "$OUTF/hardware/facts.kv"
  out="$(bash "$ROOT/amsrom.sh" info --dir "$OUTF" 2>&1)"
  assert_contains "info prints the verdict" "$out" "arm32_binder64"

  # local mode (no adb): must degrade gracefully instead of crashing
  OUTF2="$WORK/local"
  env PATH=/usr/bin:/bin HOME="$HOME" bash "$ROOT/amsrom.sh" all --local --dir "$OUTF2" >"$WORK/local.log" 2>&1
  assert_eq "local mode exits 0" "$?" "0"
  assert_file "local mode still writes a project" "$OUTF2/README.md"

  # the flash helper must be dry-run by default
  out="$(cd "$OUT/gsi" && bash flash-gsi.sh 2>&1)";  assert_contains "flash helper needs an image" "$out" "usage:"
  touch "$WORK/system-arm32binder64-aonly-vanilla.img"
  out="$(cd "$OUT/gsi" && bash flash-gsi.sh "$WORK/system-arm32binder64-aonly-vanilla.img" 2>&1)"
  assert_contains "flash helper refuses without the confirmation flag" "$out" "DRY RUN"
  assert_contains "flash helper warns about preloader"                "$out" "preloader"
fi

# ---------------------------------------------------------------------------
echo
printf '%s---------------------------------------------%s\n' "$DIM" "$N"
if [ "$FAIL" -eq 0 ]; then
  printf '%sall %d checks passed%s\n' "$G" "$PASS" "$N"
  exit 0
fi
printf '%s%d passed, %d FAILED%s\n' "$R" "$PASS" "$FAIL" "$N"
for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
exit 1
