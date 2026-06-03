# ============================================================
# IMAGE PIPELINE
# Depends on: SHOW_OVERLAY, DEST_DIR (set in fetcher.sh preamble)
# ============================================================

# Reject files that are not valid images (e.g. HTML error pages from failed downloads).
validate_image() {
    local TARGET="$1"
    [ -f "$TARGET" ] || return
    local MIME
    MIME=$(file --mime-type -b "$TARGET")
    if [[ "$MIME" != image/* ]]; then
        notify-send "WayLume" "$(printf "${MSG_FETCH_INVALID_MIME:-⚠️ Invalid download ignored (%s). Please try again.}" "$MIME")"
        rm -f "$TARGET"
        exit 1   # failure — bad download; caller shows no "success" dialog
    fi
}

# Resize to exact screen resolution (fill + center crop).
# The title sidecar (TARGET.title) is written by the caller after this function.
# Overlay is applied at display time by _wl_make_display_image(), not here.
process_image() {
    local TARGET="$1"
    [ -f "$TARGET" ] && command -v convert &>/dev/null || return

    local SCREEN_RES SCREEN_W SCREEN_H
    SCREEN_RES=$(xrandr --current 2>/dev/null \
        | grep ' connected' \
        | grep -oP '\d+x\d+\+\d+\+\d+' \
        | head -1 \
        | cut -d'+' -f1)
    SCREEN_W=${SCREEN_RES%x*}
    SCREEN_H=${SCREEN_RES#*x}
    [ -n "$SCREEN_W" ] && [ -n "$SCREEN_H" ] || return

    convert "$TARGET" \
        -resize "${SCREEN_W}x${SCREEN_H}^" \
        -gravity Center \
        -extent "${SCREEN_W}x${SCREEN_H}" \
        "$TARGET" 2>/dev/null
}

# ============================================================
# WALLPAPER DISPLAY
# ============================================================

# Build the image that will be set as wallpaper.
# If SHOW_OVERLAY=true and a .title sidecar exists alongside TARGET, the overlay
# is composited onto a temporary display file; otherwise TARGET is used directly.
# Sets the global DISPLAY_PATH to the path to pass to _wl_set_wallpaper.
# Sets CURRENT_GALLERY to TARGET so gallery navigation can find the active file
# even when the DE wallpaper points to the temporary overlay display file.
_wl_make_display_image() {
    local TARGET="$1"
    DISPLAY_PATH="$TARGET"

    # Track the gallery file in memory (persisted to waylume.state via save_state).
    CURRENT_GALLERY="$TARGET"

    [ -f "$TARGET" ] && command -v convert &>/dev/null || return
    [ "$SHOW_OVERLAY" = "true" ] || return

    local TITLE_FILE="${TARGET}.title"
    [ -f "$TITLE_FILE" ] || return
    local TITLE
    TITLE=$(< "$TITLE_FILE")
    [ -z "$TITLE" ] && return

    # Sanitise before passing to ImageMagick -annotate:
    # 1. Truncate to 120 chars.
    # 2. Escape '%' → '%%': ImageMagick treats bare % as a format specifier
    #    (e.g. %f expands to the filename, %[exif:...] to EXIF fields).
    #    A crafted API response like {"title": "%[exif:ImageDescription]"}
    #    would cause ImageMagick to render arbitrary image metadata instead
    #    of the intended title text.
    # 3. Strip C0 control characters (0x00-0x1F) and DEL (0x7F):
    #    Control bytes embedded in the title (e.g. \n, \t, \r) could
    #    misalign the overlay text or be mis-interpreted by the shell
    #    when expanded inside the double-quoted -annotate argument.
    TITLE="${TITLE:0:120}"
    TITLE="${TITLE//%/%%}"
    TITLE=$(printf '%s' "$TITLE" | tr -d '\000-\037\177')

    local IMG_W
    IMG_W=$(identify -format '%w' "$TARGET" 2>/dev/null)
    [ -z "$IMG_W" ] && IMG_W=1920

    local BAR=52
    local DISPLAY_FILE="$HOME/.cache/waylume/waylume_display.jpg"

    if convert "$TARGET" \
        \( -size "${IMG_W}x${BAR}" xc:"rgba(0,0,0,0.65)" \) \
        -gravity North -composite \
        -font DejaVu-Sans-Bold -pointsize 15 \
        -fill white -gravity NorthWest -annotate +20+17 " WayLume " \
        -font DejaVu-Sans -pointsize 24 \
        -fill white -gravity NorthEast -annotate +20+14 " ${TITLE} " \
        "$DISPLAY_FILE" 2>/dev/null; then
        DISPLAY_PATH="$DISPLAY_FILE"
    fi
}

# ── DE dispatcher ────────────────────────────────────────────────────────────
# Resolves XDG_CURRENT_DESKTOP to a canonical lowercase DE name used as the
# suffix in _wl_set_<de> / _wl_get_<de> function names.
# Adding support for a new DE = add two functions + one pattern here.
_wl_de_name() {
    case "${XDG_CURRENT_DESKTOP:-}" in
        GNOME|ubuntu:GNOME) echo "gnome"    ;;
        MATE)               echo "mate"     ;;
        X-Cinnamon)         echo "cinnamon" ;;
        KDE)                echo "kde"      ;;
        XFCE)               echo "xfce"     ;;
        *)                  echo "unknown"  ;;
    esac
}

# ── Per-DE set functions ──────────────────────────────────────────────────────

_wl_set_gnome() {
    gsettings set org.gnome.desktop.background picture-uri      "file://$1"
    gsettings set org.gnome.desktop.background picture-uri-dark "file://$1"
}

_wl_set_mate() {
    # MATE uses a plain path — no file:// prefix.
    gsettings set org.mate.background picture-filename "$1"
}

_wl_set_cinnamon() {
    gsettings set org.cinnamon.desktop.background picture-uri      "file://$1"
    gsettings set org.cinnamon.desktop.background picture-uri-dark "file://$1"
}

_wl_set_kde() {
    plasma-apply-wallpaperimage "$1"
}

_wl_set_xfce() {
    # Enumerate all existing last-image properties (one per monitor/workspace)
    # and update each one. This handles multi-monitor setups automatically
    # without having to guess monitor names (which vary per system).
    local -a _PROPS
    mapfile -t _PROPS < <(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep '/last-image$')
    if [ "${#_PROPS[@]}" -gt 0 ]; then
        local _PROP
        for _PROP in "${_PROPS[@]}"; do
            xfconf-query -c xfce4-desktop -p "$_PROP" \
                --create -t string -s "$1" 2>/dev/null || true
        done
    else
        # Fresh XFCE with no wallpaper set yet — build path from first connected monitor.
        local _MON
        _MON=$(xrandr --current 2>/dev/null | awk '/ connected/{print $1; exit}')
        [ -n "$_MON" ] && xfconf-query -c xfce4-desktop \
            -p "/backdrop/screen0/monitor${_MON}/workspace0/last-image" \
            --create -t string -s "$1" 2>/dev/null || true
    fi
}

_wl_set_unknown() {
    # Unknown DE — attempt GNOME schema as last resort.
    gsettings set org.gnome.desktop.background picture-uri "file://$1" 2>/dev/null || true
}

# ── Per-DE get functions ──────────────────────────────────────────────────────
# Each function prints a plain filesystem path (no file:// prefix, no quotes).
# Returns empty string when no reliable read-back is available.

_wl_get_gnome() {
    gsettings get org.gnome.desktop.background picture-uri 2>/dev/null \
        | tr -d "'" | sed 's|file://||'
}

_wl_get_mate() {
    # MATE stores a plain path — no file:// stripping needed.
    gsettings get org.mate.background picture-filename 2>/dev/null | tr -d "'"
}

_wl_get_cinnamon() {
    gsettings get org.cinnamon.desktop.background picture-uri 2>/dev/null \
        | tr -d "'" | sed 's|file://||'
}

_wl_get_kde()     { echo ""; }  # no reliable CLI read-back
_wl_get_unknown() { echo ""; }

_wl_get_xfce() {
    # Read the first last-image property found (primary monitor / workspace 0).
    local _PROP
    _PROP=$(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep '/last-image$' | head -1)
    [ -n "$_PROP" ] && xfconf-query -c xfce4-desktop -p "$_PROP" 2>/dev/null || echo ""
}

# ── Public API ────────────────────────────────────────────────────────────────

# Set the wallpaper for the current desktop environment.
_wl_set_wallpaper() {
    "_wl_set_$(_wl_de_name)" "$1"
}

# Read the currently active wallpaper path for the current desktop environment.
_wl_get_current_wallpaper() {
    "_wl_get_$(_wl_de_name)"
}

# Apply the wallpaper and notify the user.
# Calls _wl_make_display_image to overlay the title bar if SHOW_OVERLAY=true.
apply_wallpaper() {
    local TARGET="$1"
    [ -f "$TARGET" ] || return
    _wl_make_display_image "$TARGET"
    _wl_set_wallpaper "$DISPLAY_PATH"
    notify-send "WayLume" "$MESSAGE"
}
