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

_wl_read_keyval "$HOME/.config/waylume/waylume.conf" DEST_DIR INTERVAL SOURCES APOD_API_KEY GALLERY_MAX_FILES SHOW_OVERLAY
# Fallback: if conf is missing or DEST_DIR was not set, use the XDG Pictures default.
# Without this, DEST_DIR="" causes find to scan the service cwd (/), which is dangerous.
DEST_DIR="${DEST_DIR:-$(xdg-user-dir PICTURES 2>/dev/null || echo "$HOME/Pictures")/WayLume}"
SHOW_OVERLAY="${SHOW_OVERLAY:-true}"
mkdir -p "$DEST_DIR"
mkdir -p "$HOME/.cache/waylume"

# ── i18n: detect language and load strings ────────────────────────────────────
# LANG is injected by the systemd service Environment= directive (set at deploy time)
_wl_lang="${LANG:-${LANGUAGE:-en}}"
_wl_lang="${_wl_lang%%.*}"; _wl_lang="${_wl_lang%%_*}"; _wl_lang="${_wl_lang,,}"
source "$HOME/.config/waylume/i18n/${_wl_lang}.sh" 2>/dev/null \
    || source "$HOME/.config/waylume/i18n/en.sh" 2>/dev/null || true
unset _wl_lang

# Derive Bing market code from system locale (e.g. pt_BR.UTF-8 → pt-BR, en_US → en-US).
# Falls back to en-US for bare/exotic locales (C, POSIX, etc.).
WL_MKT=$(printf '%s' "${LANG:-en_US}" | grep -oP '^[a-z]{2}_[A-Z]{2}' | tr '_' '-')
WL_MKT="${WL_MKT:-en-US}"

STATE_FILE="$HOME/.config/waylume/waylume.state"
DB_FILE="$HOME/.config/waylume/waylume.db"
TODAY=$(date +%Y-%m-%d)

# Read persisted last-download dates per source
APOD_LAST_DATE=""
BING_LAST_DATE=""
UNSPLASH_LAST_DATE=""
WIKIMEDIA_LAST_DATE=""
CURRENT_GALLERY=""
[ -f "$STATE_FILE" ] && _wl_read_keyval "$STATE_FILE" APOD_LAST_DATE BING_LAST_DATE UNSPLASH_LAST_DATE WIKIMEDIA_LAST_DATE CURRENT_GALLERY

# Shared output variables set by each fetch_* function
IMG_TITLE=""
MESSAGE=""

# ============================================================
# UTILITIES
# ============================================================

# Rotate a random image from the local gallery (no download).
# Sets TARGET_PATH and MESSAGE; exits if gallery is empty.
# Uses the db when available; falls back to find for pre-db installs.
apply_random_local() {
    local LABEL="$1"
    local COUNT; COUNT=$(_wl_db_count 2>/dev/null || echo 0)
    if (( COUNT > 0 )); then
        local IDX=$(( RANDOM % COUNT ))
        local ROW; ROW=$(_wl_db_get_by_idx "$IDX")
        TARGET_PATH="$DEST_DIR/$(printf '%s' "$ROW" | cut -f2)"
    else
        TARGET_PATH=$(find "$DEST_DIR" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.png" \) | shuf -n 1)
    fi
    if [ -z "$TARGET_PATH" ] || [ ! -f "$TARGET_PATH" ]; then
        notify-send "WayLume" "${MSG_FETCH_NO_IMAGES:-No images found in the gallery.}"
        exit 0   # handled — timer will retry later
    fi
    MESSAGE="$(printf "${MSG_FETCH_LOCAL:-🔄 Local gallery (%s already downloaded today)}" "$LABEL")"
}

# Daily download cap — returns 0 (true) if the source already ran today.
# In that case it rotates a local image; the caller must return immediately.
# Usage: _wl_daily_cap "Bing" BING_LAST_DATE && return
_wl_daily_cap() {
    [ "${!2}" = "$TODAY" ] || return 1
    apply_random_local "$1"
}

# Checks whether the last curl call timed out (exit code 28).
# On timeout: notifies the user and exits cleanly — wallpaper is left unchanged;
# the systemd timer will retry on the next scheduled tick.
# Usage: _wl_check_timeout $?
_wl_check_timeout() {
    (( $1 == 28 )) || return 0
    notify-send "WayLume ⏱️" "${MSG_FETCH_TIMEOUT:-⏱️ Connection timed out. Wallpaper not changed.}"
    exit 1   # signal failure to the caller (run_with_progress / systemd)
}

##LIB_GALLERY##

##LIB_WALLPAPER##

# ============================================================
# SOURCE FUNCTIONS
# Each function receives TARGET_PATH as $1 and is responsible
# for populating IMG_TITLE and MESSAGE (global), and writing
# the image file to TARGET_PATH on success.
# ============================================================

##SOURCES##

# ============================================================
# MAIN
# ============================================================

# Initialise db on every invocation (one-shot migration runs only if db is absent).
_wl_db_init

if [ "$1" == "--random" ]; then
    # Mode: rotate a random image already in the local gallery.
    # Gallery files are clean (no overlay baked in) — skip save_state,
    # validate_image, and process_image; overlay is applied at display
    # time inside apply_wallpaper via _wl_make_display_image.
    apply_random_local "manual"
    apply_wallpaper "$TARGET_PATH"
    save_state
    exit 0
fi

if [ "$1" == "--set-wallpaper" ]; then
    # Mode: set a specific image as the wallpaper (called from the main GUI for
    # gallery navigation — bypasses download and image processing).
    # Overlay is applied at display time via _wl_make_display_image.
    [ -n "$2" ] || exit 1
    _wl_make_display_image "$2"
    _wl_set_wallpaper "$DISPLAY_PATH"
    save_state
    exit 0
fi

if [ "$1" == "--get-current-wallpaper" ]; then
    # Mode: print the currently active wallpaper path for the current DE.
    _wl_get_current_wallpaper
    exit 0
fi

if [ "$1" == "--get-current-gallery" ]; then
    # Mode: print the gallery file currently being displayed.
    # CURRENT_GALLERY is loaded from waylume.state at startup and updated by
    # _wl_make_display_image on every wallpaper change, so it always points to
    # the original gallery file (never the temporary overlay display file).
    if [ -n "$CURRENT_GALLERY" ]; then
        echo "$CURRENT_GALLERY"
    else
        _wl_get_current_wallpaper
    fi
    exit 0
fi

if [ "$1" == "--nav" ]; then
    # Mode: navigate the gallery (next | prev | random) and apply the wallpaper.
    # Prints a human-readable position string ("Image N of M") to stdout for
    # the caller (main.sh) to display via notify-send.
    DIRECTION="${2:-next}"
    COUNT=$(_wl_db_count)
    if (( COUNT == 0 )); then
        notify-send "WayLume" "${MSG_NAV_NO_IMAGES:-No images in the gallery. Download new images first.}"
        exit 0
    fi
    IDX=0
    if [ "$DIRECTION" = "random" ]; then
        IDX=$(( RANDOM % COUNT ))
    else
        CURRENT_BASE=$(basename "${CURRENT_GALLERY:-}")
        CUR_IDX=$(_wl_db_idx_of "$CURRENT_BASE")
        if [ "$CUR_IDX" = "-1" ] || [ -z "$CUR_IDX" ]; then
            [ "$DIRECTION" = "prev" ] && IDX=$(( COUNT - 1 )) || IDX=0
        elif [ "$DIRECTION" = "next" ]; then
            IDX=$(( (CUR_IDX + 1) % COUNT ))
        else
            IDX=$(( (CUR_IDX - 1 + COUNT) % COUNT ))
        fi
    fi
    ROW=$(_wl_db_get_by_idx "$IDX")
    FNAME=$(printf '%s' "$ROW" | cut -f2)
    TARGET_NAV="$DEST_DIR/$FNAME"
    if [ ! -f "$TARGET_NAV" ]; then
        notify-send "WayLume ⚠️" "Gallery file not found: $FNAME"
        exit 1
    fi
    _wl_make_display_image "$TARGET_NAV"
    _wl_set_wallpaper "$DISPLAY_PATH"
    save_state
    DISP_IDX=$(( IDX + 1 ))
    printf "${MSG_NAV_POSITION:-📸 Image %s of %s}" "$DISP_IDX" "$COUNT"
    exit 0
fi

# Mode: download a new image from one of the configured sources.
IFS=',' read -r -a SOURCE_ARRAY <<< "$SOURCES"
# Trim any stray whitespace/newlines from each source name.
for i in "${!SOURCE_ARRAY[@]}"; do
    SOURCE_ARRAY[$i]=$(echo "${SOURCE_ARRAY[$i]}" | tr -d '[:space:]')
done
SELECTED_SOURCE="${SOURCE_ARRAY[$RANDOM % ${#SOURCE_ARRAY[@]}]}"
TARGET_PATH="$DEST_DIR/waylume_$(date +%Y%m%d_%H%M%S).jpg"

# Dispatch — only known source names are allowed; unknown values fall back to local gallery.
# _WL_NEW_DOWNLOAD tracks whether this run produced a new file (for _wl_db_add).
_WL_NEW_DOWNLOAD=false
case "${SELECTED_SOURCE,,}" in
    bing)      fetch_bing      "$TARGET_PATH"; _WL_NEW_DOWNLOAD=true ;;
    unsplash)  fetch_unsplash  "$TARGET_PATH"; _WL_NEW_DOWNLOAD=true ;;
    apod)      fetch_apod      "$TARGET_PATH"; _WL_NEW_DOWNLOAD=true ;;
    wikimedia) fetch_wikimedia "$TARGET_PATH"; _WL_NEW_DOWNLOAD=true ;;
    local)
        apply_random_local "Local"
        MESSAGE="${MSG_FETCH_SOURCE_LOCAL:-🖼️ Wallpaper from local gallery}"
        apply_wallpaper "$TARGET_PATH"
        exit 0
        ;;
    *)
        notify-send "WayLume ⚠️" "Unknown source: ${SELECTED_SOURCE}. Using local gallery."
        apply_random_local "$SELECTED_SOURCE"
        ;;
esac

save_state

validate_image  "$TARGET_PATH"
process_image   "$TARGET_PATH"
# Persist title metadata alongside the gallery file so _wl_make_display_image
# can read it at display time (overlay is no longer baked into the stored image).
[ -n "$IMG_TITLE" ] && printf '%s' "$IMG_TITLE" > "${TARGET_PATH}.title"
# Register new download in the db before displaying and pruning.
$_WL_NEW_DOWNLOAD && _wl_db_add "$(basename "$TARGET_PATH")" "$IMG_TITLE" "${SELECTED_SOURCE^}"
apply_wallpaper "$TARGET_PATH"
save_state   # persists CURRENT_GALLERY set by _wl_make_display_image
prune_gallery
