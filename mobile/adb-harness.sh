#!/bin/sh
# adb harness: install (optional), launch the phone app cold, and watch it for
# a while — memory, the D log (tag photowagon), ANRs, crashes, dropped frames —
# then take a screenshot. Pass/fail on the console; everything under $OUT.
#
#   mobile/adb-harness.sh [--install] [--seconds N] [--clear-data]
#
# Needs one device over adb. Never touches the phone while another app is in
# front unless --force: check the focused window first.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PKG=org.photowagon.mobile
ACT=$PKG/.MainActivity
APK=${APK:-$HERE/build-android/photo-wagon-mobile-debug.apk}   # APK=… for the x86_64 build
OUT=${OUT:-$HERE/build-android/harness}
SECONDS_TO_WATCH=90
INSTALL=0
CLEAR=0
FORCE=0
EXERCISE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL=1 ;;
    --seconds) shift; SECONDS_TO_WATCH=$1 ;;
    --clear-data) CLEAR=1 ;;
    --force) FORCE=1 ;;
    --exercise) EXERCISE=1 ;;   # swipe the grid every few seconds: frames rendered tell if the UI thread is free
    *) echo "unknown option $1"; exit 2 ;;
  esac
  shift
done
mkdir -p "$OUT"
fail=0
say() { printf '%s\n' "$*"; }
bad() { say "FAIL $*"; fail=1; }
ok()  { say "ok   $*"; }

adb get-state >/dev/null 2>&1 || { say "no device"; exit 2; }

# Percentage of near-black pixels in the app area of a screenshot (below the
# status bar, above the navigation bar). A black window is what the user sees
# as "trava": the theme background is dark grey, not black.
darkness() {
  python3 - "$1" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
w, h = im.size
box = im.crop((0, int(h * 0.06), w, int(h * 0.92))).resize((90, 160))
px = list(box.getdata())
# #171717 (a dead window) sums to 69; the theme background #16181d to 83
print(round(100 * sum(1 for r, g, b in px if r + g + b < 75) / len(px)))
PY
}
black=0

# Only take the phone when nothing else is in front of the user.
front=$(adb shell dumpsys window 2>/dev/null | grep -E 'mCurrentFocus' | head -1 | sed 's/.*u0 //; s/}.*//')
case "$front" in
  *$PKG*|*launcher*|*Launcher*|*NexusLauncher*|"") ;;
  *) if [ $FORCE = 0 ]; then say "phone in use by $front; pass --force to take it anyway"; exit 3; fi ;;
esac

if [ $INSTALL = 1 ]; then
  adb install -r "$APK" >"$OUT/install.log" 2>&1 && ok "installed $(basename "$APK")" || { bad "install: $(tail -1 "$OUT/install.log")"; exit 1; }
fi
adb shell am force-stop $PKG
[ $CLEAR = 1 ] && adb shell pm clear $PKG >/dev/null && ok "app data cleared"
adb logcat -c
adb shell dumpsys gfxinfo $PKG reset >/dev/null 2>&1
t0=$(date +%s)
adb shell am start -W -n $ACT >"$OUT/start.log" 2>&1
grep -E 'TotalTime' "$OUT/start.log" | sed 's/^/     /'

pid=""
peak=0
anr=0
crashed=0
last_line=""
i=0
: >"$OUT/memory.tsv"
while [ $i -lt "$SECONDS_TO_WATCH" ]; do
  sleep 3; i=$((i + 3))
  if [ $EXERCISE = 1 ]; then
    # a flick up then down over the grid; a live UI renders dozens of frames for each
    adb shell input swipe 540 1600 540 700 200
    adb shell input swipe 540 700 540 1600 200
    # every fourth round: open a photo, look at it, go back
    if [ $((i % 12)) = 0 ]; then adb shell input tap 300 900; sleep 2; adb shell input keyevent 4; fi
  fi
  # the system permission dialog: press Allow, as the user would
  if adb shell dumpsys window 2>/dev/null | grep -qE 'mCurrentFocus=.*permissioncontroller'; then
    adb shell uiautomator dump /sdcard/pw-ui.xml >/dev/null 2>&1
    allow=$(adb shell cat /sdcard/pw-ui.xml 2>/dev/null | python3 -c '
import re, sys
x = sys.stdin.read()
best = None
for m in re.finditer(r"<node[^>]*text=\"([^\"]*)\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", x):
    t = m.group(1).lower()
    # "Allow all" (Android 14+) before a plain "Allow"; never "Don t allow" / "Select photos"
    rank = 2 if t.startswith(("allow all", "permitir tod")) else 1 if t.startswith(("allow", "permitir")) else 0
    if rank and (best is None or rank > best[0]):
        best = (rank, (int(m.group(2)) + int(m.group(4))) // 2, (int(m.group(3)) + int(m.group(5))) // 2)
if best: print(best[1], best[2])')
    if [ -n "$allow" ]; then adb shell input tap $allow; ok "permission dialog: tapped Allow at $allow"; fi
  fi
  pid=$(adb shell pidof $PKG | tr -d '\r')
  if [ -z "$pid" ]; then
    crashed=1
    break
  fi
  pss=$(adb shell dumpsys meminfo $pid 2>/dev/null | grep -E 'TOTAL PSS:' | awk '{print $3}')
  [ -n "$pss" ] && printf '%s\t%s\n' "$i" "$pss" >>"$OUT/memory.tsv"
  [ -n "$pss" ] && [ "$pss" -gt "$peak" ] && peak=$pss
  line=$(adb logcat -d -s photowagon:I 2>/dev/null | grep -E 'phone:' | tail -1 | sed 's/.*photowagon: //')
  if [ "$line" != "$last_line" ]; then say "     ${i}s  pss=${pss}K  $line"; last_line=$line; fi
  if adb logcat -d 2>/dev/null | grep -qE "ANR in $PKG|Input dispatching timed out.*$PKG"; then anr=1; break; fi
  if [ $((i % 15)) = 0 ]; then
    adb exec-out screencap -p >"$OUT/screen-${i}s.png" 2>/dev/null
    d=$(darkness "$OUT/screen-${i}s.png")
    say "     ${i}s  dark ${d}%"
    [ -n "$d" ] && [ "$d" -gt 95 ] && black=$((black + 1))
  fi
done

adb logcat -d -b all >"$OUT/logcat.txt" 2>/dev/null   # -b all: the crash buffer holds the native backtraces
adb logcat -d -s photowagon:I >"$OUT/app.log" 2>/dev/null
adb exec-out screencap -p >"$OUT/screen.png" 2>/dev/null && ok "screenshot $OUT/screen.png"
# a black window is the failure the user sees as "trava": the app area (below the status
# bar, above the navigation bar) almost entirely darker than the theme background
dark=$(darkness "$OUT/screen.png")
say "     dark pixels in the app area at the end: ${dark}%"
[ -n "$dark" ] && [ "$dark" -gt 95 ] && black=$((black + 1))
[ $black -gt 0 ] && bad "black screen in $black of the screenshots"

# The QML watchdog: "ui alive" every 10 s, "ui stalled N ms" when a 250 ms timer
# came late. (dumpsys gfxinfo does not count frames of Qt's own GL surface.)
beats=$(grep -c 'ui alive' "$OUT/logcat.txt")
stalls=$(grep -E 'ui stalled' "$OUT/logcat.txt" | sed 's/.*ui stalled //' | sort -n | tail -3 | tr '\n' ' ')
say "     ui heartbeats: $beats in ${i}s; worst stalls: ${stalls:-none}"
[ $crashed = 0 ] && [ "$beats" -lt $((i / 10 - 1)) ] && bad "UI thread blocked: $beats heartbeats in ${i}s"

if [ $crashed = 1 ]; then
  reason=$(grep -E "Killing [0-9]+:$PKG|FATAL|SIGSEGV|SIGABRT|Abort message" "$OUT/logcat.txt" | tail -1 | cut -c1-200)
  bad "process gone after ${i}s: ${reason:-no reason logged}"
  grep -A20 -E 'backtrace:' "$OUT/logcat.txt" | head -25 >"$OUT/backtrace.txt"
elif [ $anr = 1 ]; then
  bad "ANR after ${i}s"
else
  ok "alive after ${i}s"
fi
say "     peak pss ${peak}K  ($(wc -l <"$OUT/memory.tsv") samples in $OUT/memory.tsv)"
[ "$peak" -gt 1200000 ] && bad "memory above 1.2 GB"
grep -E 'phone:.*: ' "$OUT/app.log" | grep -vE 'phone: (roots|[0-9]+ files)' | head -3 | sed 's/^/     decode error: /'
exit $fail
