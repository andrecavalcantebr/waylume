#!/bin/bash
# WayLume Fetcher - runs via systemd or manually

# ============================================================
# ENVIRONMENT & CONFIG
# ============================================================

# Export environment needed for gsettings/notify-send when running via systemd.
# Use :- to not override values already set in a graphical session.
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DISPLAY="${DISPLAY:-:0}"

# Safe key=value file reader — no arbitrary code execution.
# Usage: _wl_read_keyval <file> KEY1 KEY2 ...
# Only assigns variables whose names are explicitly listed as arguments.
# Strips surrounding quotes; ignores blank lines and comments.
_wl_read_keyval() {
    local _wl_file="$1"; shift
    local _wl_allowed=("$@")
    local _wl_line _wl_key _wl_value _wl_k
    [ -f "$_wl_file" ] || return 0
    while IFS= read -r _wl_line; do
        [[ "$_wl_line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
        [[ "$_wl_line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        _wl_key="${BASH_REMATCH[1]}"
        _wl_value="${BASH_REMATCH[2]}"
        _wl_value="${_wl_value#\"}"; _wl_value="${_wl_value%\"}"
        _wl_value="${_wl_value#\'}"; _wl_value="${_wl_value%\'}"
        for _wl_k in "${_wl_allowed[@]}"; do
            [[ "$_wl_key" == "$_wl_k" ]] || continue
            printf -v "$_wl_key" '%s' "$_wl_value"
            break
        done
    done < "$_wl_file"
}

_wl_read_keyval "$HOME/.config/waylume/waylume.conf" DEST_DIR INTERVAL SOURCES APOD_API_KEY GALLERY_MAX_FILES
mkdir -p "$DEST_DIR"

# ── i18n: detect language and load strings ────────────────────────────────────
# LANG is injected by the systemd service Environment= directive (set at deploy time)
_wl_lang="${LANG:-${LANGUAGE:-en}}"
_wl_lang="${_wl_lang%%.*}"; _wl_lang="${_wl_lang%%_*}"; _wl_lang="${_wl_lang,,}"
source "$HOME/.config/waylume/i18n/${_wl_lang}.sh" 2>/dev/null \
    || source "$HOME/.config/waylume/i18n/en.sh" 2>/dev/null || true
unset _wl_lang

STATE_FILE="$HOME/.config/waylume/waylume.state"
TODAY=$(date +%Y-%m-%d)

# Read persisted last-download dates per source
APOD_LAST_DATE=""
BING_LAST_DATE=""
UNSPLASH_LAST_DATE=""
WIKIMEDIA_LAST_DATE=""
[ -f "$STATE_FILE" ] && _wl_read_keyval "$STATE_FILE" APOD_LAST_DATE BING_LAST_DATE UNSPLASH_LAST_DATE WIKIMEDIA_LAST_DATE

# Shared output variables set by each fetch_* function
IMG_TITLE=""
MESSAGE=""

# ============================================================
# UTILITIES
# ============================================================

# Rotate a random image from the local gallery (no download).
# Sets TARGET_PATH and MESSAGE; exits if gallery is empty.
apply_random_local() {
    local LABEL="$1"
    TARGET_PATH=$(find "$DEST_DIR" -type f \( -iname "*.jpg" -o -iname "*.png" \) | shuf -n 1)
    if [ -z "$TARGET_PATH" ]; then
        notify-send "WayLume" "${MSG_FETCH_NO_IMAGES:-No images found in the gallery.}"
        exit 0   # handled — timer will retry later
    fi
    MESSAGE="$(printf "${MSG_FETCH_LOCAL:-🔄 Local gallery (%s already downloaded today)}" "$LABEL")"
}

# Persist updated download dates to state file.
save_state() {
    {
        echo "APOD_LAST_DATE=\"$APOD_LAST_DATE\""
        echo "BING_LAST_DATE=\"$BING_LAST_DATE\""
        echo "UNSPLASH_LAST_DATE=\"$UNSPLASH_LAST_DATE\""
        echo "WIKIMEDIA_LAST_DATE=\"$WIKIMEDIA_LAST_DATE\""
    } > "$STATE_FILE"
}

# Remove oldest gallery files when count exceeds GALLERY_MAX_FILES.
# GALLERY_MAX_FILES=0 disables pruning. Files are sorted chronologically
# by filename (waylume_YYYYMMDD_HHMMSS.jpg) so the oldest are always removed first.
prune_gallery() {
    local MAX="${GALLERY_MAX_FILES:-60}"
    { [ "$MAX" -gt 0 ] 2>/dev/null; } || return  # 0 or non-numeric = disabled
    local -a FILES
    mapfile -d '' FILES < <(
        find "$DEST_DIR" -type f \( -iname "*.jpg" -o -iname "*.png" \) -print0 | sort -z
    )
    local COUNT="${#FILES[@]}"
    if (( COUNT > MAX )); then
        local TO_DELETE=$(( COUNT - MAX ))
        rm -f -- "${FILES[@]:0:$TO_DELETE}"
    fi
}

# ============================================================
# SOURCE FUNCTIONS
# Each function receives TARGET_PATH as $1 and is responsible
# for populating IMG_TITLE and MESSAGE (global), and writing
# the image file to TARGET_PATH on success.
# ============================================================

fetch_bing() {
    local TARGET="$1"

    # Bing has one image per day — rotate from gallery if already downloaded today.
    if [ "$BING_LAST_DATE" = "$TODAY" ]; then
        apply_random_local "Bing"
        return
    fi

    local JSON URL
    JSON=$(curl -sL "https://bing.biturl.top/?resolution=1920&format=json&index=0&mkt=pt-BR")
    URL=$(echo "$JSON"       | grep -oP '"url"\s*:\s*"\K[^"]+' 2>/dev/null)
    IMG_TITLE=$(echo "$JSON" | grep -oP '"copyright"\s*:\s*"\K[^"]+' 2>/dev/null)

    if [ -n "$URL" ]; then
        curl -sL "$URL" -o "$TARGET"
        BING_LAST_DATE="$TODAY"
    else
        apply_random_local "Bing"
        return
    fi
    MESSAGE="${MSG_FETCH_SOURCE_BING:-New wallpaper downloaded via Bing}"
}

fetch_unsplash() {
    local TARGET="$1"

    # Limit to one new download per day — rotate from gallery if already done today.
    if [ "$UNSPLASH_LAST_DATE" = "$TODAY" ]; then
        apply_random_local "Unsplash"
        return
    fi

    local HDR_TMP="/tmp/wl_hdr_$$"
    local PICSUM_ID AUTHOR INFO_JSON

    # Capture response headers alongside the image to extract Picsum-ID.
    curl -sL "https://picsum.photos/1920/1080.jpg" -D "$HDR_TMP" -o "$TARGET"

    # Extract Picsum-ID from response header (digits only, guards against injection).
    PICSUM_ID=$(grep -i '^picsum-id:' "$HDR_TMP" 2>/dev/null | grep -oP '\d+' | tr -d '[:space:]')
    rm -f "$HDR_TMP"

    # Fetch author metadata if we got a valid ID; fall back to generic title on any failure.
    if [ -n "$PICSUM_ID" ]; then
        INFO_JSON=$(curl -sL "https://picsum.photos/id/${PICSUM_ID}/info")
        AUTHOR=$(echo "$INFO_JSON" | grep -oP '"author"\s*:\s*"\K[^"]+' 2>/dev/null)
        [ -n "$AUTHOR" ] && IMG_TITLE="Photo by ${AUTHOR} (picsum #${PICSUM_ID})"
    fi
    [ -z "$IMG_TITLE" ] && IMG_TITLE="Unsplash / picsum.photos"

    UNSPLASH_LAST_DATE="$TODAY"
    MESSAGE="${MSG_FETCH_SOURCE_UNSPLASH:-New wallpaper downloaded via Unsplash}"
}

fetch_apod() {
    local TARGET="$1"

    # APOD has one image per day — rotate from gallery if already downloaded today.
    if [ "$APOD_LAST_DATE" = "$TODAY" ]; then
        apply_random_local "APOD"
        return
    fi

    local APOD_URL="" JSON MEDIA_TYPE ERR_MSG APOD_DATE

    # Try up to 8 days back in case today's APOD is a video or not yet published.
    for DAYS_AGO in 0 1 2 3 4 5 6 7; do
        APOD_DATE=$(date -d "-${DAYS_AGO} days" +%Y-%m-%d)
        JSON=$(curl -sL "https://api.nasa.gov/planetary/apod?api_key=${APOD_API_KEY}&date=${APOD_DATE}")

        # Detect API errors (rate limit, invalid key) early to avoid burning quota.
        if echo "$JSON" | grep -q '"error"'; then
            ERR_MSG=$(echo "$JSON" | grep -oP '"message"\s*:\s*"\K[^"]+' 2>/dev/null)
            notify-send "WayLume ⚠️" "$(printf "${MSG_FETCH_APOD_ERROR:-APOD API: %s\nUsing local gallery.\nTip: register a free API key at api.nasa.gov}" "$ERR_MSG")"
            apply_random_local "APOD"
            # Mark today so the timer doesn't hammer the API again until tomorrow.
            APOD_LAST_DATE="$TODAY"
            return
        fi

        MEDIA_TYPE=$(echo "$JSON" | grep -oP '"media_type"\s*:\s*"\K[^"]+' 2>/dev/null)
        if [ "$MEDIA_TYPE" = "image" ]; then
            # Use regular url (~960px) — much faster than hdurl (4K).
            APOD_URL=$(echo "$JSON" | grep -oP '"url"\s*:\s*"\K[^"]+' 2>/dev/null)
            if [ -n "$APOD_URL" ]; then
                IMG_TITLE=$(echo "$JSON" | grep -oP '"title"\s*:\s*"\K[^"]+' 2>/dev/null)
                break
            fi
        fi
    done

    if [ -n "$APOD_URL" ]; then
        curl -sL "$APOD_URL" -o "$TARGET"
        APOD_LAST_DATE="$TODAY"
    fi
    MESSAGE="${MSG_FETCH_SOURCE_APOD:-New wallpaper downloaded via APOD}"
}

fetch_wikimedia() {
    local TARGET="$1"

    # Wikimedia POTD changes once a day — rotate from gallery if already downloaded today.
    if [ "$WIKIMEDIA_LAST_DATE" = "$TODAY" ]; then
        apply_random_local "Wikimedia"
        return
    fi

    local FILENAME JSON1 JSON2 IMG_URL RAW_TITLE

    # Step 1: get POTD filename from the daily template
    JSON1=$(curl -sL \
        "https://commons.wikimedia.org/w/api.php?action=query&prop=images&titles=Template:Potd/${TODAY}&format=json")
    FILENAME=$(echo "$JSON1" | grep -oP '"title"\s*:\s*"\KFile:[^"]+' | head -1)

    if [ -z "$FILENAME" ]; then
        apply_random_local "Wikimedia"
        return
    fi

    # Decode JSON Unicode escapes in filename (e.g. \u00ed → í) so curl can URL-encode correctly.
    # python3 is already a project dependency (used by build.sh).
    FILENAME=$(python3 -c "
import sys, re
t = sys.stdin.read().rstrip('\n')
print(re.sub(r'\\\\u([0-9a-fA-F]{4})', lambda m: chr(int(m.group(1), 16)), t))
" <<< "$FILENAME" 2>/dev/null)

    # Step 2: get 1920px thumbnail URL (filename is URL-encoded by curl --data-urlencode)
    JSON2=$(curl -sGLs "https://commons.wikimedia.org/w/api.php" \
        --data-urlencode "titles=$FILENAME" \
        --data "action=query&prop=imageinfo&iiprop=url&iiurlwidth=1920&format=json")
    IMG_URL=$(echo "$JSON2" | grep -oP '"thumburl"\s*:\s*"\K[^"]+' | head -1)

    if [ -z "$IMG_URL" ]; then
        apply_random_local "Wikimedia"
        return
    fi

    curl -sL "$IMG_URL" -o "$TARGET"
    WIKIMEDIA_LAST_DATE="$TODAY"

    # Title: strip "File:" prefix and file extension from the already-decoded filename.
    IMG_TITLE=$(echo "$FILENAME" | sed 's|^File:||; s|\.[^.]*$||')
    [ -z "$IMG_TITLE" ] && IMG_TITLE="Wikimedia Picture of the Day"

    MESSAGE="${MSG_FETCH_SOURCE_WIKIMEDIA:-New wallpaper downloaded via Wikimedia}"
}

# ============================================================
# IMAGE PIPELINE
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
        exit 0   # handled — bad download removed, timer will retry later
    fi
}

# Resize to exact screen resolution (fill + center crop) and optionally
# overlay a semi-transparent title bar at the top-right corner.
# Single ImageMagick pass — avoids double JPEG re-encoding.
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

    local BAR=52

    if [ -n "$IMG_TITLE" ]; then
        local DISPLAY_TITLE="${IMG_TITLE:0:120}"

        # Sanitise before passing to ImageMagick -annotate:
        #
        # 1. Escape '%' → '%%': ImageMagick treats bare % as a format specifier
        #    (e.g. %f expands to the filename, %[exif:...] to EXIF fields).
        #    A crafted API response like {"title": "%[exif:ImageDescription]"}
        #    would cause ImageMagick to render arbitrary image metadata instead
        #    of the intended title text.
        DISPLAY_TITLE="${DISPLAY_TITLE//%/%%}"

        # 2. Strip C0 control characters (0x00-0x1F) and DEL (0x7F):
        #    Control bytes embedded in the title (e.g. \n, \t, \r) could
        #    misalign the overlay text or be mis-interpreted by the shell
        #    when expanded inside the double-quoted -annotate argument.
        DISPLAY_TITLE=$(printf '%s' "$DISPLAY_TITLE" | tr -d '\000-\037\177')

        # Resize → crop → composite bar → título (NE) → brand text (NW): just one pass
        convert "$TARGET" \
            -resize "${SCREEN_W}x${SCREEN_H}^" \
            -gravity Center \
            -extent "${SCREEN_W}x${SCREEN_H}" \
            \( -size "${SCREEN_W}x${BAR}" xc:"rgba(0,0,0,0.65)" \) \
            -gravity North -composite \
            -font DejaVu-Sans-Bold -pointsize 15 \
            -fill white -gravity NorthWest -annotate +14+11 "WayLume" \
            -font DejaVu-Sans -pointsize 13 \
            -fill "#bbbbbb" -gravity NorthWest -annotate +14+29 "is.gd/48OrTP" \
            -font DejaVu-Sans -pointsize 24 \
            -fill white -gravity NorthEast -annotate +20+14 "  ${DISPLAY_TITLE}  " \
            "$TARGET" 2>/dev/null
    else
        # No title: just resize + center crop.
        convert "$TARGET" \
            -resize "${SCREEN_W}x${SCREEN_H}^" \
            -gravity Center \
            -extent "${SCREEN_W}x${SCREEN_H}" \
            "$TARGET" 2>/dev/null
    fi
}

# Set the wallpaper on GNOME (light and dark schemes) and notify the user.
apply_wallpaper() {
    local TARGET="$1"
    [ -f "$TARGET" ] || return
    gsettings set org.gnome.desktop.background picture-uri      "file://$TARGET"
    gsettings set org.gnome.desktop.background picture-uri-dark "file://$TARGET"
    notify-send "WayLume" "$MESSAGE"
}

# ============================================================
# MAIN
# ============================================================

if [ "$1" == "--random" ]; then
    # Mode: rotate a random image already in the local gallery.
    apply_random_local "manual"
else
    # Mode: download a new image from one of the configured sources.
    IFS=',' read -r -a SOURCE_ARRAY <<< "$SOURCES"
    # Trim any stray whitespace/newlines from each source name.
    for i in "${!SOURCE_ARRAY[@]}"; do
        SOURCE_ARRAY[$i]=$(echo "${SOURCE_ARRAY[$i]}" | tr -d '[:space:]')
    done
    SELECTED_SOURCE="${SOURCE_ARRAY[$RANDOM % ${#SOURCE_ARRAY[@]}]}"
    TARGET_PATH="$DEST_DIR/waylume_$(date +%Y%m%d_%H%M%S).jpg"

    # Dispatch — only known source names are allowed; unknown values fall back to local gallery.
    case "${SELECTED_SOURCE,,}" in
        bing)      fetch_bing      "$TARGET_PATH" ;;
        unsplash)  fetch_unsplash  "$TARGET_PATH" ;;
        apod)      fetch_apod      "$TARGET_PATH" ;;
        wikimedia) fetch_wikimedia "$TARGET_PATH" ;;
        *)
            notify-send "WayLume ⚠️" "Unknown source: ${SELECTED_SOURCE}. Using local gallery."
            apply_random_local "$SELECTED_SOURCE"
            ;;
    esac
fi

save_state

validate_image  "$TARGET_PATH"
process_image   "$TARGET_PATH"
apply_wallpaper "$TARGET_PATH"
prune_gallery
