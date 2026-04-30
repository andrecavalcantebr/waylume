#!/bin/bash
# test_multi_de.sh — smoke tests for multi-DE wallpaper dispatch
#
# Tests _wl_set_wallpaper / _wl_get_current_wallpaper without installing
# any desktop environment. DE-specific commands are replaced by mock scripts
# in a temporary directory prepended to PATH.
#
# Run from the repository root:
#   bash test_multi_de.sh

set -uo pipefail

PASS=0; FAIL=0
MOCK_BIN=$(mktemp -d)
export LOG="$MOCK_BIN/calls.log"
FAKE_IMG=$(mktemp /tmp/wl_test_XXXXXX.jpg)
touch "$FAKE_IMG"   # existence is enough; --set-wallpaper does not validate MIME

cleanup() { rm -rf "$MOCK_BIN" "$FAKE_IMG"; }
trap cleanup EXIT

# ── Test helpers ──────────────────────────────────────────────────────────────
pass() { echo "  ✅ $1"; (( PASS++ )); }
fail() { echo "  ❌ $1"; (( FAIL++ )); }

assert_contains() {
    local desc="$1" pattern="$2"
    # Use -e to prevent patterns starting with '-' being parsed as grep options.
    if grep -qF -e "$pattern" "$LOG" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc  (expected in log: $pattern)"
        echo "     --- log dump ---"; cat "$LOG" 2>/dev/null; echo "     ----------------"
    fi
}

assert_not_contains() {
    local desc="$1" pattern="$2"
    if ! grep -qF -e "$pattern" "$LOG" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc  (should NOT be in log: $pattern)"
    fi
}

# ── Mock commands ─────────────────────────────────────────────────────────────
# Each mock logs its invocation to $LOG so assertions can inspect it.

cat > "$MOCK_BIN/gsettings" << 'MOCK'
#!/bin/bash
echo "gsettings $*" >> "$LOG"
# Simulate a 'get' response so _wl_get_current_wallpaper returns something.
if [ "$1" = "get" ]; then
    echo "'file:///home/user/Pictures/WayLume/test.jpg'"
fi
MOCK

cat > "$MOCK_BIN/xfconf-query" << 'MOCK'
#!/bin/bash
echo "xfconf-query $*" >> "$LOG"
# Handle -l (list properties): return two fake last-image paths.
if [[ " $* " == *" -l "* ]] || [[ "$*" == *"-l" ]]; then
    echo "/backdrop/screen0/monitorHDMI-0/workspace0/last-image"
    echo "/backdrop/screen0/monitoreDP-1/workspace0/last-image"
fi
# Handle read (-p without -s): return a fake path.
if [[ "$*" == *"-p"* ]] && [[ "$*" != *"-s"* ]] && [[ "$*" != *"-l"* ]]; then
    echo "/home/user/Pictures/WayLume/test.jpg"
fi
MOCK

cat > "$MOCK_BIN/plasma-apply-wallpaperimage" << 'MOCK'
#!/bin/bash
echo "plasma-apply-wallpaperimage $*" >> "$LOG"
MOCK

# xrandr mock: used by the XFCE fresh-install path (no existing xfconf properties).
cat > "$MOCK_BIN/xrandr" << 'MOCK'
#!/bin/bash
echo "HDMI-0 connected 1920x1080+0+0 (normal left inverted right x axis y axis) 527mm x 296mm"
echo "  1920x1080     60.00*+"
MOCK

cat > "$MOCK_BIN/notify-send" << 'MOCK'
#!/bin/bash
: # no-op
MOCK

chmod +x "$MOCK_BIN"/*

# ── Run one scenario ──────────────────────────────────────────────────────────
run() {
    local DE="$1"; shift
    > "$LOG"
    XDG_CURRENT_DESKTOP="$DE" PATH="$MOCK_BIN:$PATH" \
        bash src/fetcher.sh "$@" 2>/dev/null
}

# ── Test suite ────────────────────────────────────────────────────────────────

echo ""
echo "━━ --set-wallpaper ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "── GNOME ──────────────────────────────────────────────────────"
run "GNOME" --set-wallpaper "$FAKE_IMG"
assert_contains     "sets picture-uri"          "gsettings set org.gnome.desktop.background picture-uri "
assert_contains     "sets picture-uri-dark"     "gsettings set org.gnome.desktop.background picture-uri-dark"
assert_not_contains "no xfconf on GNOME"        "xfconf-query"
assert_not_contains "no plasma on GNOME"        "plasma-apply-wallpaperimage"

echo ""
echo "── ubuntu:GNOME ───────────────────────────────────────────────"
run "ubuntu:GNOME" --set-wallpaper "$FAKE_IMG"
assert_contains     "sets picture-uri"          "gsettings set org.gnome.desktop.background picture-uri "
assert_not_contains "no xfconf"                 "xfconf-query"

echo ""
echo "── MATE ───────────────────────────────────────────────────────"
run "MATE" --set-wallpaper "$FAKE_IMG"
assert_contains     "uses MATE schema"          "gsettings set org.mate.background picture-filename"
assert_not_contains "no file:// in MATE value"  "picture-filename file://"
assert_not_contains "no GNOME schema"           "org.gnome.desktop.background"

echo ""
echo "── X-Cinnamon ─────────────────────────────────────────────────"
run "X-Cinnamon" --set-wallpaper "$FAKE_IMG"
assert_contains     "uses Cinnamon schema"      "gsettings set org.cinnamon.desktop.background picture-uri "
assert_contains     "sets Cinnamon dark"        "gsettings set org.cinnamon.desktop.background picture-uri-dark"
assert_not_contains "no GNOME schema"           "org.gnome.desktop.background"

echo ""
echo "── KDE ────────────────────────────────────────────────────────"
run "KDE" --set-wallpaper "$FAKE_IMG"
assert_contains     "calls plasma-apply-wallpaperimage" "plasma-apply-wallpaperimage $FAKE_IMG"
assert_not_contains "no gsettings on KDE"       "gsettings set"

echo ""
echo "── XFCE (existing xfconf properties) ─────────────────────────"
run "XFCE" --set-wallpaper "$FAKE_IMG"
assert_contains     "lists xfce4-desktop props" "xfconf-query -c xfce4-desktop -l"
assert_contains     "sets HDMI-0 property"      "-p /backdrop/screen0/monitorHDMI-0/workspace0/last-image"
assert_contains     "sets eDP-1 property"       "-p /backdrop/screen0/monitoreDP-1/workspace0/last-image"
assert_contains     "writes target path"        "-s $FAKE_IMG"
assert_not_contains "no gsettings on XFCE"      "gsettings set"
assert_not_contains "no plasma on XFCE"         "plasma-apply-wallpaperimage"

echo ""
echo "── XFCE (fresh install — no existing xfconf properties) ───────"
# Override xfconf-query to return nothing for -l (simulates first run).
cat > "$MOCK_BIN/xfconf-query" << 'MOCK'
#!/bin/bash
echo "xfconf-query $*" >> "$LOG"
# -l returns empty (fresh install, no wallpaper configured yet)
if [[ "$*" == *"-p"* ]] && [[ "$*" != *"-s"* ]] && [[ "$*" != *"-l"* ]]; then
    echo "/home/user/Pictures/WayLume/test.jpg"
fi
MOCK
chmod +x "$MOCK_BIN/xfconf-query"

run "XFCE" --set-wallpaper "$FAKE_IMG"
assert_contains     "falls back to xrandr path" "xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitorHDMI-0/workspace0/last-image"
assert_contains     "writes target path"        "-s $FAKE_IMG"

# Restore the two-monitor mock for subsequent tests.
cat > "$MOCK_BIN/xfconf-query" << 'MOCK'
#!/bin/bash
echo "xfconf-query $*" >> "$LOG"
if [[ " $* " == *" -l "* ]] || [[ "$*" == *"-l" ]]; then
    echo "/backdrop/screen0/monitorHDMI-0/workspace0/last-image"
    echo "/backdrop/screen0/monitoreDP-1/workspace0/last-image"
fi
if [[ "$*" == *"-p"* ]] && [[ "$*" != *"-s"* ]] && [[ "$*" != *"-l"* ]]; then
    echo "/home/user/Pictures/WayLume/test.jpg"
fi
MOCK
chmod +x "$MOCK_BIN/xfconf-query"

echo ""
echo "── Unknown DE (fallback to GNOME schema) ──────────────────────"
run "LXDE" --set-wallpaper "$FAKE_IMG"
assert_contains     "fallback uses gnome schema" "gsettings set org.gnome.desktop.background picture-uri"

echo ""
echo "━━ --get-current-wallpaper ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "── GNOME ──────────────────────────────────────────────────────"
RESULT=$(run "GNOME" --get-current-wallpaper)
if [ -n "$RESULT" ]; then pass "returns a non-empty path"; else fail "returned empty string"; fi
if [[ "$RESULT" != *"file://"* ]]; then pass "no file:// prefix in output"; else fail "output should not contain file://"; fi

echo ""
echo "── MATE ───────────────────────────────────────────────────────"
# MATE mock gsettings get returns a plain path (no file:// prefix stored)
cat > "$MOCK_BIN/gsettings" << 'MOCK'
#!/bin/bash
echo "gsettings $*" >> "$LOG"
if [ "$1" = "get" ]; then
    echo "'/home/user/Pictures/WayLume/test.jpg'"
fi
MOCK
chmod +x "$MOCK_BIN/gsettings"
RESULT=$(run "MATE" --get-current-wallpaper)
if [ -n "$RESULT" ]; then pass "MATE returns a non-empty path"; else fail "MATE returned empty string"; fi
if [[ "$RESULT" != *"file://"* ]]; then pass "MATE: no file:// in output"; else fail "MATE: should not contain file://"; fi

echo ""
echo "── XFCE ───────────────────────────────────────────────────────"
RESULT=$(run "XFCE" --get-current-wallpaper)
if [ -n "$RESULT" ]; then pass "XFCE returns a non-empty path"; else fail "XFCE returned empty string"; fi

echo ""
echo "── KDE (no read-back available) ───────────────────────────────"
RESULT=$(run "KDE" --get-current-wallpaper)
if [ -z "$RESULT" ]; then pass "KDE returns empty string (expected)"; else fail "KDE should return empty but got: $RESULT"; fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo ""
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
