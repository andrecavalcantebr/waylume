#!/bin/bash
# ====================================================
# WayLume - Minimalist Wayland Wallpaper Manager
# Version: 2.0.0
# ====================================================

WL_VERSION="2.0.0"

# --- Paths and global variables ---
CONFIG_DIR="$HOME/.config/waylume"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"
SYSTEMD_DIR="$HOME/.config/systemd/user"

CONF_FILE="$CONFIG_DIR/waylume.conf"
FETCHER_SCRIPT="$BIN_DIR/waylume-fetch"
INSTALL_TARGET="$BIN_DIR/waylume"

# --- Default config values ---
DEST_DIR="$(xdg-user-dir PICTURES 2>/dev/null || echo "$HOME/Pictures")/WayLume"
INTERVAL="1h"
SOURCES="Unsplash"
APOD_API_KEY="DEMO_KEY"

# ── i18n: detect language and load strings ────────────────────────────────────
# Handles: pt_BR.UTF-8, pt_PT, pt, en_US.UTF-8, en_AU, en_GB, en → base code
WL_LANG="${LANG:-${LANGUAGE:-en}}"
WL_LANG="${WL_LANG%%.*}"   # strip .UTF-8
WL_LANG="${WL_LANG%%_*}"   # strip _BR, _US, _AU …
WL_LANG="${WL_LANG,,}"     # lowercase
source "$CONFIG_DIR/i18n/${WL_LANG}.sh" 2>/dev/null \
    || source "$CONFIG_DIR/i18n/en.sh" 2>/dev/null || true
# Normalize bare LANG codes so GTK/glibc don't warn:
#   en       → en_US.UTF-8   (bare lang code, expand to canonical locale)
#   en_US    → en_US.UTF-8   (has region, just add encoding)
#   pt       → pt_BR.UTF-8
#   pt_BR    → pt_BR.UTF-8
#   xx_YY.UTF-8 → unchanged
if [[ "${LANG:-}" != *.* ]]; then
    case "${LANG}" in
        en) export LANG="en_US.UTF-8" ;;
        pt) export LANG="pt_BR.UTF-8" ;;
        *)  export LANG="${LANG}.UTF-8" ;;
    esac
fi
# Fallback defaults when i18n files not yet installed (first --install run)
: "${BTN_CLOSE:=Close}" "${BTN_NO:=No}" "${BTN_YES:=Yes}" "${BTN_OK:=OK}"
: "${TITLE_MENU:=WayLume v${WL_VERSION} - Menu}" "${TITLE_INTERVAL:=Update Interval}"
: "${TITLE_SOURCES:=Image Sources}" "${TITLE_APOD_KEY:=WayLume - NASA API Key}"
: "${TITLE_GALLERY_PICK:=Choose Gallery Folder}"
: "${TITLE_UNINSTALL_CONFIRM:=Warning}" "${TITLE_GALLERY_CLEAN:=WayLume - Clean Gallery}"
: "${TITLE_UPDATE_PROMPT:=WayLume Update}" "${TITLE_INSTALL_PROMPT:=WayLume Install}"

# Tracks in-session config changes (set by each set_* function; checked on submenu exit)
_WL_CONFIG_DIRTY=false

# ====================================================
# FUNCTIONS
# ====================================================

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

# zenity 4.x (GTK4 + libadwaita) — Wayland-native; no GDK_BACKEND override needed.

# Thin wrapper that filters a known GTK4/libadwaita layout bug in zenity 4.x:
# "GtkBox reports a minimum height of N, but minimum height for width of 1048576 is M"
# This is a cosmetic inconsistency in GTK's height-for-width measurement at MAX_INT
# width; it has no effect on dialog behaviour. All other stderr output is preserved.
_zenity() { zenity "$@" 2> >(grep -Ev "Gtk-CRITICAL.*minimum height" >&2); }

# Button label presets (populated from i18n file loaded above)
# zenity uses --ok-label / --cancel-label; OK exits 0, Cancel exits 1.
BTNS_OK=(--ok-label="${BTN_CLOSE}")
BTNS_YN=(--ok-label="${BTN_YES}"  --cancel-label="${BTN_NO}")
BTNS_OKC=(--ok-label="${BTN_OK}" --cancel-label="${BTN_CLOSE}")

# Wrappers so button labels are consistent without repeating them everywhere
yad_info()     { _zenity --info     "${BTNS_OK[@]}"  "$@"; }
yad_error()    { _zenity --error    "${BTNS_OK[@]}"  "$@"; }
yad_question() { _zenity --question "${BTNS_YN[@]}"  "$@"; }

# Show a progress dialog, run a command, then close automatically.
# - Task runs in background; foreground loop animates the bar (0→98%)
# - OK button is disabled at any % < 100; Cancel hidden (--no-cancel)
# - When task finishes, sends "100" → --auto-close dismisses dialog
# - No user interaction possible during execution
run_with_progress() {
    local MSG="$1"; shift
    local FIFO RC
    FIFO=$(mktemp -u /tmp/wl_progress_XXXXXX)
    mkfifo "$FIFO"
    _zenity --progress --no-cancel --auto-close \
        --title="WayLume" --text="$MSG" \
        --width=380 < "$FIFO" &
    local ZPID=$!
    exec 3>"$FIFO"   # open write end; unblocks zenity's stdin open
    rm -f "$FIFO"    # unlink path; fd 3 keeps the pipe alive
    echo "0" >&3     # 0% → OK disabled

    "$@" 3>&- &      # run task in background; close fd 3 so child never holds the pipe open
    local TPID=$!

    # Animate 0→98% while task runs; cap at 98 so auto-close never triggers early
    local pct=0
    while kill -0 "$TPID" 2>/dev/null; do
        [ "$pct" -lt 98 ] && pct=$(( pct + 2 ))
        echo "$pct" >&3
        sleep 0.25
    done

    wait "$TPID"
    RC=$?

    echo "100" >&3   # triggers --auto-close
    exec 3>&-
    wait "$ZPID" 2>/dev/null
    return $RC
}

# Check and install missing runtime dependencies
check_dependencies() {
    # Runtime commands required by this script
    local REQUIRED=("zenity" "curl" "notify-send" "file")
    local MISSING=()

    for cmd in "${REQUIRED[@]}"; do
        command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
    done

    [ ${#MISSING[@]} -eq 0 ] && return 0

    echo "${MSG_DEPS_NEEDED:-⚠️ WayLume needs some packages to work}: ${MISSING[*]}"
    echo "${MSG_DEPS_ASKING:-Requesting permission to install...}"

    # Translate command names to the correct package name per package manager
    pkg_name() {
        local CMD="$1" PM="$2"
        case "$CMD" in
            notify-send)
                [ "$PM" = "apt" ] && echo "libnotify-bin" || echo "libnotify" ;;
            file)
                echo "file" ;;
            *)
                echo "$CMD" ;;
        esac
    }

    local PACKAGES=()
    if command -v apt-get &>/dev/null; then
        for cmd in "${MISSING[@]}"; do PACKAGES+=("$(pkg_name "$cmd" apt)"); done
        sudo apt-get update 2>/dev/null || echo "${MSG_DEPS_APT_FAIL:-⚠️  apt update failed (network?), trying with local indexes...}"
        sudo apt-get install -y "${PACKAGES[@]}" || exit 1
    elif command -v dnf &>/dev/null; then
        for cmd in "${MISSING[@]}"; do PACKAGES+=("$(pkg_name "$cmd" dnf)"); done
        sudo dnf install -y "${PACKAGES[@]}" || exit 1
    elif command -v pacman &>/dev/null; then
        for cmd in "${MISSING[@]}"; do PACKAGES+=("$(pkg_name "$cmd" pacman)"); done
        sudo pacman -S --noconfirm "${PACKAGES[@]}" || exit 1
    else
        echo "${MSG_DEPS_NO_PM:-❌ Package manager not recognized.}"
        echo "${MSG_DEPS_MANUAL:-Please install manually}: ${MISSING[*]}"
        exit 1
    fi

    echo "${MSG_DEPS_OK:-✅ Dependencies installed successfully!}"
}

# Persist current config to disk
save_config() {
    {
        echo "DEST_DIR=\"$DEST_DIR\""
        echo "INTERVAL=\"$INTERVAL\""
        echo "SOURCES=\"$SOURCES\""
        echo "APOD_API_KEY=\"$APOD_API_KEY\""
        echo "GALLERY_MAX_FILES=\"$GALLERY_MAX_FILES\""
        echo "SHOW_OVERLAY=\"$SHOW_OVERLAY\""
    } > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "$CONF_FILE"
}

# Load config from disk, applying defaults for missing keys
load_config() {
    _wl_read_keyval "$CONF_FILE" DEST_DIR INTERVAL SOURCES APOD_API_KEY GALLERY_MAX_FILES SHOW_OVERLAY
    [ -z "$DEST_DIR" ]          && DEST_DIR="$(xdg-user-dir PICTURES 2>/dev/null || echo "$HOME/Pictures")/WayLume"
    [ -z "$INTERVAL" ]          && INTERVAL="1h"
    [ -z "$SOURCES" ]           && SOURCES="Unsplash"
    [ -z "$APOD_API_KEY" ]      && APOD_API_KEY="DEMO_KEY"
    [ -z "$GALLERY_MAX_FILES" ] && GALLERY_MAX_FILES=60
    [ -z "$SHOW_OVERLAY" ]      && SHOW_OVERLAY="true"
}

# Write the wallpaper fetcher worker script and activate the systemd timer
deploy_services() {
    mkdir -p "$DEST_DIR"

    # Generate the worker script (waylume-fetch)
    cat << 'EOF' > "$FETCHER_SCRIPT"
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

# ============================================================
# STATE
# Depends on: STATE_FILE (set in fetcher.sh preamble)
# ============================================================

# Persist updated download dates and current gallery file to waylume.state.
save_state() {
    {
        echo "APOD_LAST_DATE=\"$APOD_LAST_DATE\""
        echo "BING_LAST_DATE=\"$BING_LAST_DATE\""
        echo "UNSPLASH_LAST_DATE=\"$UNSPLASH_LAST_DATE\""
        echo "WIKIMEDIA_LAST_DATE=\"$WIKIMEDIA_LAST_DATE\""
        echo "CURRENT_GALLERY=\"$CURRENT_GALLERY\""
    } > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# ============================================================
# GALLERY DATABASE (waylume.db — TSV)
# ============================================================
# Schema: id TAB filename TAB title TAB source TAB date_iso TAB status
# - id       : auto-incremented integer
# - filename : basename only (DEST_DIR may change)
# - title    : image caption / attribution
# - source   : Bing | Unsplash | APOD | Wikimedia | Local | Unknown
# - date_iso : YYYY-MM-DD (download date)
# - status   : normal | favorite | trash
# All mutations use atomic write (.tmp + mv). Reads are plain awk.
# Depends on: DB_FILE, DEST_DIR, TODAY (set in fetcher.sh preamble)

# One-shot migration: scan DEST_DIR for existing images and populate the db
# from .title sidecars. Safe to call on an already-populated db — skips
# filenames already present. Creates DB_FILE if it doesn't exist.
_wl_db_migrate() {
    local f fname title date_iso max_id=0 next_id added=0
    local fname_date

    # Find the current max id and build a lookup of filenames already in db.
    declare -A _existing=()
    if [ -f "$DB_FILE" ]; then
        while IFS=$'\t' read -r _id _fname _rest; do
            (( _id > max_id )) && max_id=$_id
            _existing["$_fname"]=1
        done < "$DB_FILE"
    fi
    next_id=$(( max_id + 1 ))

    while IFS= read -r -d '' f; do
        fname=$(basename "$f")
        [ "${_existing[$fname]+x}" ] && continue   # already in db

        title=""
        [ -f "${f}.title" ] && title=$(< "${f}.title")

        # Extract date from waylume_YYYYMMDD_HHMMSS.jpg; fall back to today.
        fname_date=$(printf '%s' "$fname" | grep -oP '(?<=waylume_)\d{8}' | head -1)
        if [ -n "$fname_date" ]; then
            date_iso="${fname_date:0:4}-${fname_date:4:2}-${fname_date:6:2}"
        else
            date_iso="$TODAY"
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$next_id" "$fname" "$title" "Unknown" "$date_iso" "normal" \
            >> "$DB_FILE"
        (( next_id++ ))
        (( added++ ))
    done < <(find "$DEST_DIR" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.png" \) -print0 | sort -z)

    [ "$added" -gt 0 ] && printf 'WayLume: migrated %s image(s) to waylume.db\n' "$added" >&2
    return 0
}

# Initialise db: run one-shot migration if the db file doesn't exist yet.
_wl_db_init() {
    [ -f "$DB_FILE" ] && return 0
    _wl_db_migrate
}

# Add a new image entry to the db (atomic rewrite).
# Usage: _wl_db_add filename title source [date_iso]
_wl_db_add() {
    local filename="$1" title="$2" source="$3"
    local date_iso="${4:-$TODAY}"
    local max_id=0
    if [ -f "$DB_FILE" ]; then
        max_id=$(awk -F'\t' '{if($1+0>max) max=$1+0} END{print max+0}' "$DB_FILE")
    fi
    local id=$(( max_id + 1 ))
    {
        cat "$DB_FILE" 2>/dev/null
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$id" "$filename" "$title" "$source" "$date_iso" "normal"
    } > "${DB_FILE}.tmp" && mv "${DB_FILE}.tmp" "$DB_FILE"
}

# Count active (non-trash) entries.
_wl_db_count() {
    [ -f "$DB_FILE" ] || { echo 0; return; }
    awk -F'\t' '$6 != "trash" {n++} END{print n+0}' "$DB_FILE"
}

# Return the 0-based Nth active (non-trash) row (full TSV line).
_wl_db_get_by_idx() {
    local idx="$1"
    [ -f "$DB_FILE" ] || return 1
    awk -F'\t' -v idx="$idx" '$6 != "trash" {if (n==idx){print; exit} n++}' "$DB_FILE"
}

# Return the 0-based index of filename among active entries (-1 if not found).
_wl_db_idx_of() {
    local filename="$1"
    [ -f "$DB_FILE" ] || { echo -1; return; }
    awk -F'\t' -v f="$filename" 'BEGIN{idx=-1} $6 != "trash" {
        if ($2 == f) {idx=n; exit} n++
    } END{print idx}' "$DB_FILE"
}

# Remove a row by id; also deletes the image file and its .title sidecar.
_wl_db_remove_by_id() {
    local id="$1"
    [ -f "$DB_FILE" ] || return
    local fname
    fname=$(awk -F'\t' -v id="$id" '$1 == id {print $2; exit}' "$DB_FILE")
    [ -n "$fname" ] && rm -f -- "$DEST_DIR/$fname" "$DEST_DIR/${fname}.title"
    awk -F'\t' -v id="$id" 'BEGIN{OFS="\t"} $1 != id' "$DB_FILE" \
        > "${DB_FILE}.tmp" && mv "${DB_FILE}.tmp" "$DB_FILE"
}

# Remove oldest normal entries when active count exceeds MAX.
# The currently active gallery file is never deleted.
_wl_db_prune() {
    local MAX="${1:-${GALLERY_MAX_FILES:-60}}"
    { [ "$MAX" -gt 0 ] 2>/dev/null; } || return
    [ -f "$DB_FILE" ] || return

    local COUNT; COUNT=$(_wl_db_count)
    (( COUNT > MAX )) || return 0

    local TO_DELETE=$(( COUNT - MAX ))
    local ACTIVE_BASE; ACTIVE_BASE=$(basename "${CURRENT_GALLERY:-}")
    local deleted=0
    local _id _fname _rest _status

    while IFS=$'\t' read -r _id _fname _rest; do
        _status=$(printf '%s' "$_rest" | awk -F'\t' '{print $NF}')
        [ "$_status" = "trash" ] && continue
        (( deleted >= TO_DELETE )) && break
        [ "$_fname" = "$ACTIVE_BASE" ] && continue
        _wl_db_remove_by_id "$_id"
        (( deleted++ ))
    done < "$DB_FILE"
}

# Backwards-compatible wrapper.
prune_gallery() { _wl_db_prune; }

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

# ============================================================
# SOURCE FUNCTIONS
# Each function receives TARGET_PATH as $1 and is responsible
# for populating IMG_TITLE and MESSAGE (global), and writing
# the image file to TARGET_PATH on success.
# ============================================================

# ============================================================
# SOURCE: Bing Daily Image
# Depends on: WL_MKT, BING_LAST_DATE, TODAY (fetcher.sh preamble)
#             apply_random_local, _wl_daily_cap, _wl_check_timeout
# ============================================================

fetch_bing() {
    local TARGET="$1"

    # Bing has one image per day — rotate from gallery if already downloaded today.
    _wl_daily_cap "Bing" BING_LAST_DATE && return

    local JSON URL
    JSON=$(curl --connect-timeout 8 --max-time 15 -sL \
        "https://bing.biturl.top/?resolution=1920&format=json&index=0&mkt=${WL_MKT}")
    _wl_check_timeout $?
    URL=$(echo "$JSON"       | grep -oP '"url"\s*:\s*"\K[^"]+' 2>/dev/null)
    IMG_TITLE=$(echo "$JSON" | grep -oP '"copyright"\s*:\s*"\K[^"]+' 2>/dev/null)

    if [ -n "$URL" ]; then
        curl --connect-timeout 10 --max-time 30 -sL "$URL" -o "$TARGET"
        _wl_check_timeout $?
        BING_LAST_DATE="$TODAY"
    else
        apply_random_local "Bing"
        return
    fi
    MESSAGE="${MSG_FETCH_SOURCE_BING:-New wallpaper downloaded via Bing}"
}

# ============================================================
# SOURCE: Unsplash / picsum.photos
# Depends on: UNSPLASH_LAST_DATE, TODAY (fetcher.sh preamble)
#             apply_random_local, _wl_daily_cap, _wl_check_timeout
# ============================================================

fetch_unsplash() {
    local TARGET="$1"

    # Limit to one new download per day — rotate from gallery if already done today.
    _wl_daily_cap "Unsplash" UNSPLASH_LAST_DATE && return

    local HDR_TMP
    HDR_TMP=$(mktemp /tmp/wl_hdr_XXXXXX)
    # Ensure the temp file is removed even if _wl_check_timeout triggers exit 0.
    trap 'rm -f "$HDR_TMP"' EXIT
    local PICSUM_ID AUTHOR INFO_JSON

    # Capture response headers alongside the image to extract Picsum-ID.
    curl --connect-timeout 10 --max-time 30 -sL \
        "https://picsum.photos/1920/1080.jpg" -D "$HDR_TMP" -o "$TARGET"
    _wl_check_timeout $?

    # Extract Picsum-ID from response header (digits only, guards against injection).
    PICSUM_ID=$(grep -i '^picsum-id:' "$HDR_TMP" 2>/dev/null | grep -oP '\d+' | tr -d '[:space:]')
    rm -f "$HDR_TMP"
    trap - EXIT    # manual cleanup done; cancel the trap

    # Fetch author metadata if we got a valid ID; fall back to generic title on any failure.
    # Timeout here is intentionally not fatal: the image was already downloaded successfully.
    if [ -n "$PICSUM_ID" ]; then
        INFO_JSON=$(curl --connect-timeout 5 --max-time 8 -sL \
            "https://picsum.photos/id/${PICSUM_ID}/info")
        AUTHOR=$(echo "$INFO_JSON" | grep -oP '"author"\s*:\s*"\K[^"]+' 2>/dev/null)
        [ -n "$AUTHOR" ] && IMG_TITLE="Photo by ${AUTHOR} (picsum #${PICSUM_ID})"
    fi
    [ -z "$IMG_TITLE" ] && IMG_TITLE="Unsplash / picsum.photos"

    UNSPLASH_LAST_DATE="$TODAY"
    MESSAGE="${MSG_FETCH_SOURCE_UNSPLASH:-New wallpaper downloaded via Unsplash}"
}

# ============================================================
# SOURCE: NASA Astronomy Picture of the Day (APOD)
# Depends on: APOD_API_KEY, APOD_LAST_DATE, TODAY (fetcher.sh preamble)
#             apply_random_local, _wl_daily_cap, _wl_check_timeout
# ============================================================

fetch_apod() {
    local TARGET="$1"

    # APOD has one image per day — rotate from gallery if already downloaded today.
    _wl_daily_cap "APOD" APOD_LAST_DATE && return

    local APOD_URL="" JSON MEDIA_TYPE ERR_MSG APOD_DATE

    # Try up to 8 days back in case today's APOD is a video or not yet published.
    for DAYS_AGO in 0 1 2 3 4 5 6 7; do
        APOD_DATE=$(date -d "-${DAYS_AGO} days" +%Y-%m-%d)
        JSON=$(curl --connect-timeout 8 --max-time 15 -sL \
            "https://api.nasa.gov/planetary/apod?api_key=${APOD_API_KEY}&date=${APOD_DATE}")
        _wl_check_timeout $?

        # Detect API errors (rate limit, invalid key) early to avoid burning quota.
        if echo "$JSON" | grep -q '"error"'; then
            ERR_MSG=$(echo "$JSON" | grep -oP '"message"\s*:\s*"\K[^"]+' 2>/dev/null)
            notify-send "WayLume ⚠️" "$(printf "${MSG_FETCH_APOD_ERROR:-APOD API: %s\nUsing local gallery.\nTip: register a free API key at api.nasa.gov
}" "$ERR_MSG")"
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

                # NASA sometimes serves its generic brand logo as a fallback payload
                # instead of the actual APOD picture. Treat that as an upstream API issue.
                if [[ "$IMG_TITLE" == *"NASA Science"* ]] || [[ "$APOD_URL" == *"nasa-logo"* ]]; then
                    ERR_MSG="${MSG_FETCH_APOD_UPSTREAM:-NASA APOD upstream issue: the API returned the generic NASA logo instead of the daily image.}"
                    notify-send "WayLume ⚠️" "$(printf "${MSG_FETCH_APOD_ERROR:-APOD API: %s\nUsing local gallery.\nTip: register a free API key at api.nasa.gov}" "$ERR_MSG")"
                    apply_random_local "APOD"
                    APOD_LAST_DATE="$TODAY"
                    return
                fi

                break
            fi
        fi
    done

    if [ -n "$APOD_URL" ]; then
        curl --connect-timeout 10 --max-time 30 -sL "$APOD_URL" -o "$TARGET"
        _wl_check_timeout $?
        APOD_LAST_DATE="$TODAY"
    fi
    MESSAGE="${MSG_FETCH_SOURCE_APOD:-New wallpaper downloaded via APOD}"
}

# ============================================================
# SOURCE: Wikimedia Picture of the Day (POTD)
# Depends on: WIKIMEDIA_LAST_DATE, TODAY (fetcher.sh preamble)
#             apply_random_local, _wl_daily_cap, _wl_check_timeout
# ============================================================

fetch_wikimedia() {
    local TARGET="$1"

    # Wikimedia POTD changes once a day — rotate from gallery if already downloaded today.
    _wl_daily_cap "Wikimedia" WIKIMEDIA_LAST_DATE && return

    local FILENAME JSON1 JSON2 IMG_URL

    # Step 1: get POTD filename from the daily template
    JSON1=$(curl --connect-timeout 8 --max-time 15 -sL \
        "https://commons.wikimedia.org/w/api.php?action=query&prop=images&titles=Template:Potd/${TODAY}&format=json")
    _wl_check_timeout $?
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
    JSON2=$(curl --connect-timeout 8 --max-time 15 -sGLs \
        "https://commons.wikimedia.org/w/api.php" \
        --data-urlencode "titles=$FILENAME" \
        --data "action=query&prop=imageinfo&iiprop=url&iiurlwidth=1920&format=json")
    _wl_check_timeout $?
    IMG_URL=$(echo "$JSON2" | grep -oP '"thumburl"\s*:\s*"\K[^"]+' | head -1)

    if [ -z "$IMG_URL" ]; then
        apply_random_local "Wikimedia"
        return
    fi

    curl --connect-timeout 10 --max-time 30 -sL "$IMG_URL" -o "$TARGET"
    _wl_check_timeout $?
    WIKIMEDIA_LAST_DATE="$TODAY"

    # Title: strip "File:" prefix and file extension from the already-decoded filename.
    IMG_TITLE=$(echo "$FILENAME" | sed 's|^File:||; s|\.[^.]*$||')
    [ -z "$IMG_TITLE" ] && IMG_TITLE="Wikimedia Picture of the Day"

    MESSAGE="${MSG_FETCH_SOURCE_WIKIMEDIA:-New wallpaper downloaded via Wikimedia}"
}

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
EOF
    chmod +x "$FETCHER_SCRIPT"

    # Generate systemd service unit
    cat << EOF > "$SYSTEMD_DIR/waylume.service"
[Unit]
Description=WayLume Wallpaper Fetcher
After=network-online.target

[Service]
Type=oneshot
Environment="LANG=${LANG}"
ExecStart=$FETCHER_SCRIPT
EOF

    # Generate systemd timer unit
    cat << EOF > "$SYSTEMD_DIR/waylume.timer"
[Unit]
Description=WayLume Wallpaper Timer

[Timer]
OnBootSec=1min
OnUnitActiveSec=$INTERVAL
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Show progress while running systemd commands
    run_with_progress "${MSG_DEPLOY_PROGRESS:-Applying settings and restarting timer...}" \
        bash -c '
            systemctl --user daemon-reload
            systemctl --user disable waylume.timer 2>/dev/null
            systemctl --user enable --now waylume.timer
            systemctl --user start waylume.service || true
        '

    yad_info --title="WayLume" \
        --text="$(printf "${MSG_DEPLOY_DONE:-Scripts generated and Timer activated!\nThe system will run every %s.}" "$INTERVAL")"
}

# Install or update WayLume into ~/.local
install_or_update() {
    local IS_UPDATE="$1"

    mkdir -p "$CONFIG_DIR" "$BIN_DIR" "$APP_DIR" "$ICON_DIR" "$SYSTEMD_DIR"

    # Copy the main script
    cp "$0" "$INSTALL_TARGET"
    chmod +x "$INSTALL_TARGET"

    # Write the icon inline (no external .svg file needed)
    cat << 'SVGEOF' > "$ICON_DIR/waylume.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect x="5" y="5" width="90" height="90" rx="15" ry="15" fill="none" stroke="#ff0000" stroke-width="6"/>
  <text 
    x="10" y="60" 
    font-family="Arial, Helvetica, sans-serif" 
    font-size="60" 
    font-weight="bold" 
    fill="#007bff"
    stroke="#fc0404"
    stroke-width="1.5"
    paint-order="stroke fill"
    stroke-linejoin="round">W</text>
  <text 
    x="47" y="85"
    font-family="Arial, Helvetica, sans-serif" 
    font-size="70" 
    font-weight="bold" 
    fill="#007bff"
    stroke="#fc0404"
    stroke-width="1.5"
    paint-order="stroke fill"
    stroke-linejoin="round">L</text>
</svg>
SVGEOF

    # Write i18n string files (plain text, safe to customize)
    mkdir -p "$CONFIG_DIR/i18n"
    cat << 'WL_I18N_PT' > "$CONFIG_DIR/i18n/pt.sh"
#!/bin/bash
# WayLume — strings em Português (Brasil)
# Carregado por main.sh e fetcher.sh via: source "$(dirname "$0")/i18n/${WAYLUME_LANG:-pt}.sh"

# ── Botões globais ────────────────────────────────────────────────────────────
BTN_CLOSE="Fechar"
BTN_NO="Não"
BTN_YES="Sim"
BTN_OK="OK"

# ── check_dependencies ────────────────────────────────────────────────────────
MSG_DEPS_NEEDED="⚠️ O WayLume precisa de alguns pacotes para funcionar"
MSG_DEPS_ASKING="Solicitando permissão para instalar..."
MSG_DEPS_APT_FAIL="⚠️  apt update falhou (rede?), tentando com índices locais..."
MSG_DEPS_NO_PM="❌ Gerenciador de pacotes não reconhecido."
MSG_DEPS_MANUAL="Por favor, instale manualmente"
MSG_DEPS_OK="✅ Dependências instaladas com sucesso!"

# ── deploy_services ───────────────────────────────────────────────────────────
MSG_DEPLOY_PROGRESS="Aplicando configurações e reiniciando timer..."
MSG_DEPLOY_DONE="Scripts gerados e Timer ativado!\nO sistema rodará a cada %s."

# ── install_or_update ─────────────────────────────────────────────────────────
MSG_UPDATE_DONE="Atualizado com sucesso!\nScripts e timer foram atualizados.\nSuas configurações foram preservadas."
MSG_INSTALL_DONE="Instalado com sucesso!\nAbra o WayLume pelo menu de aplicativos do seu sistema."

# ── uninstall ─────────────────────────────────────────────────────────────────
TITLE_UNINSTALL_CONFIRM="Aviso"
MSG_UNINSTALL_CONFIRM="Deseja realmente remover o WayLume do sistema?\nSua galeria de fotos NÃO será apagada."
MSG_UNINSTALL_DONE="WayLume desinstalado completamente."

# ── set_gallery_dir ───────────────────────────────────────────────────────────
TITLE_GALLERY_PICK="Escolha a pasta da Galeria"
MSG_GALLERY_CHANGED="Galeria alterada para:\n%s"

# ── set_update_interval ───────────────────────────────────────────────────────
TITLE_INTERVAL="Tempo de Atualização"
MSG_INTERVAL_UNIT="Unidade de tempo:"
COL_INTERVAL_UNIT="Unidade"
COL_INTERVAL_VALUE="Valor"
ITEM_INTERVAL_MIN="Minutos"
ITEM_INTERVAL_H="Horas"
LABEL_MINUTES="minutos"
LABEL_HOURS="horas"
MSG_INTERVAL_SCALE="Intervalo em %s:"   # %s = minutos | horas
MSG_INTERVAL_CHANGED="Intervalo alterado para %s."

# ── set_image_sources ─────────────────────────────────────────────────────────
TITLE_SOURCES="Fontes de Imagens"
MSG_SOURCES_PICK="Escolha de onde baixar as imagens novas:"
COL_SOURCES_NAME="Fonte"
MSG_SOURCES_CHANGED="Fontes de imagens alteradas."

# ── set_apod_api_key ──────────────────────────────────────────────────────────
TITLE_APOD_KEY="WayLume - NASA API Key"
MSG_APOD_KEY_DEMO="(usando DEMO_KEY — gere a sua em api.nasa.gov, é grátis!)"
MSG_APOD_KEY_SET="(chave configurada: %s...)"   # %s = primeiros 6 chars
MSG_APOD_KEY_PROMPT="Informe sua API Key da NASA APOD:\n%s"   # %s = MSG_APOD_KEY_*
MSG_APOD_KEY_SAVED="API Key salva!"

# ── clean_gallery ─────────────────────────────────────────────────────────────
MSG_GALLERY_CLEAN_OK="Nenhum arquivo inválido encontrado na galeria. ✅"
TITLE_GALLERY_CLEAN="WayLume - Limpar Galeria"
MSG_GALLERY_CLEAN_CONFIRM="Encontrados %d arquivo(s) corrompido(s):\n%s\n\nDeseja removê-los?"
MSG_GALLERY_CLEAN_DONE="%d arquivo(s) removido(s) da galeria."
# ── set_gallery_max ─────────────────────────────────────────────────────────────────
TITLE_GALLERY_MAX="WayLume — Limite da Galeria"
MSG_GALLERY_MAX_PROMPT="Número máximo de imagens a manter na galeria.\n0 = sem limite."
MSG_GALLERY_MAX_SAVED="Limite da galeria definido para %s imagens."   # %s = número
MSG_GALLERY_MAX_DISABLED="Limite da galeria desativado. Os arquivos vão acumular indefinidamente."
# ── fetch_and_apply_wallpaper ─────────────────────────────────────────────────
MSG_FETCH_NO_SCRIPTS="Os scripts não foram gerados. Execute: waylume --install"
MSG_FETCH_PROGRESS="Baixando e aplicando novo wallpaper..."
MSG_FETCH_DONE="Wallpaper aplicado com sucesso! 🎉"

# ── bootstrap (auto-install / update prompt) ──────────────────────────────────
TITLE_UPDATE_PROMPT="WayLume Atualização"
MSG_UPDATE_PROMPT="O WayLume já está instalado.\nDeseja atualizar para a versão desta pasta?\n\nSuas configurações serão preservadas."
TITLE_INSTALL_PROMPT="WayLume Instalação"
MSG_INSTALL_PROMPT="O WayLume não está instalado no sistema.\nDeseja instalar agora na sua pasta de usuário (~/.local/bin)?"
MSG_PIN_FAVORITES="Fixar WayLume na barra de favoritos (Dash) para acesso rápido?"

# ── main menu ─────────────────────────────────────────────────────────────────
TITLE_MENU="WayLume v${WL_VERSION} - Menu"
MSG_MENU_HEADER="WayLume v${WL_VERSION}\nGerenciador de Wallpapers\nGaleria Atual: %s\nAtualização: %s\nTítulo nas imagens: %s\nTimer: %s"
LABEL_OVERLAY_ON="ativado"
LABEL_OVERLAY_OFF="desativado"
LABEL_TIMER_ON="ativo"
LABEL_TIMER_OFF="pausado"
COL_MENU_OPTION="Opção"
COL_MENU_ACTION="Ação"
MENU_ITEM_1="⬇️  1. Baixar nova imagem agora"
MENU_ITEM_2="🎲 2. Imagem aleatória da galeria"
MENU_ITEM_3="➡️  3. Próxima imagem da galeria"
MENU_ITEM_4="⬅️  4. Imagem anterior da galeria"
MENU_ITEM_5="⚙️  5. Configurações"
MENU_ITEM_6="🔧 6. Manutenção"
MENU_ITEM_7="🚪 7. Sair"

# ── submenu configurações ───────────────────────────────────────────────────────────────────
TITLE_SETTINGS="WayLume — Configurações"
MSG_SETTINGS_HEADER="Altere as opções desejadas. Ao sair, você poderá aplicar as mudanças."
MENU_SETTINGS_1="📂 1. Pasta da galeria"
MENU_SETTINGS_2="⏱️  2. Tempo de atualização"
MENU_SETTINGS_3="🌍 3. Fontes de imagens"
MENU_SETTINGS_4="🔑 4. API Key da NASA"
MENU_SETTINGS_5="�️  5. Limite da galeria"
MENU_SETTINGS_6_ON="🎨 6. Título nas imagens: ATIVADO"
MENU_SETTINGS_6_OFF="🎨 6. Título nas imagens: DESATIVADO"
MENU_SETTINGS_7="🚪 7. Sair"
# ── set_overlay_toggle ─────────────────────────────────────────────────────────
MSG_OVERLAY_DISABLE_PROMPT="O título nas imagens está ATIVADO.\nDesativar? O wallpaper atual será atualizado imediatamente."
MSG_OVERLAY_ENABLE_PROMPT="O título nas imagens está DESATIVADO.\nAtivar? O wallpaper atual será atualizado imediatamente."
MSG_OVERLAY_ON="🎨 Título nas imagens ativado."
MSG_OVERLAY_OFF="🎨 Título nas imagens desativado."
MSG_SETTINGS_APPLY_PROMPT="Configurações foram alteradas. Deseja aplicar agora?\nIsso também reinicia o timer com o novo intervalo."

# ── submenu manutenção ────────────────────────────────────────────────────────────────────────────
TITLE_MAINTENANCE="WayLume — Manutenção"
MENU_MAINTENANCE_1_ON="⏸️ 1. Pausar timer"
MENU_MAINTENANCE_1_OFF="▶️ 1. Retomar timer"
MENU_MAINTENANCE_2="🧹 2. Limpar galeria"
MENU_MAINTENANCE_3="🗑️  3. Remover WayLume"

# ── toggle_timer ──────────────────────────────────────────────────────────────
MSG_TIMER_PAUSED="⏸️ Timer pausado. Atualizações automáticas suspensas."
MSG_TIMER_RESUMED="▶️ Timer retomado. Atualizações automáticas reiniciadas."

# ── navegação na galeria ────────────────────────────────────────────────────────────────────────
MSG_NAV_APPLIED="📸 %s"
MSG_NAV_NO_IMAGES="Nenhuma imagem na galeria. Baixe novas imagens primeiro."
MSG_NAV_POSITION="📸 Imagem %s de %s"

# ── fetcher: mensagens de notify-send ────────────────────────────────────────
MSG_FETCH_NO_IMAGES="Nenhuma imagem encontrada na galeria."
MSG_FETCH_APOD_ERROR="APOD API: %s\nUsando galeria local.\nDica: registre uma API key gratuita em api.nasa.gov"
MSG_FETCH_APOD_UPSTREAM="Problema upstream da NASA APOD: a API retornou a logo genérica da NASA em vez da imagem do dia."
MSG_FETCH_INVALID_MIME="⚠️ Download inválido ignorado (%s). Tente novamente."
MSG_FETCH_LOCAL="🔄 Galeria local (%s já baixado hoje)"
MSG_FETCH_SOURCE_BING="Novo wallpaper baixado via Bing"
MSG_FETCH_SOURCE_UNSPLASH="Novo wallpaper baixado via Unsplash"
MSG_FETCH_SOURCE_APOD="Novo wallpaper baixado via APOD"
MSG_FETCH_SOURCE_WIKIMEDIA="Novo wallpaper baixado via Wikimedia POTD"
MSG_FETCH_SOURCE_LOCAL="🖼️ Wallpaper da galeria local"
MSG_FETCH_TIMEOUT="⏱️ Tempo de conexão esgotado. Wallpaper não alterado. Será tentado no próximo ciclo."
WL_I18N_PT
    cat << 'WL_I18N_EN' > "$CONFIG_DIR/i18n/en.sh"
#!/bin/bash
# WayLume — English strings
# Loaded by main.sh and fetcher.sh via: source "$(dirname "$0")/i18n/${WAYLUME_LANG:-pt}.sh"

# ── Global buttons ────────────────────────────────────────────────────────────
BTN_CLOSE="Close"
BTN_NO="No"
BTN_YES="Yes"
BTN_OK="OK"

# ── check_dependencies ────────────────────────────────────────────────────────
MSG_DEPS_NEEDED="⚠️ WayLume needs some packages to work"
MSG_DEPS_ASKING="Requesting permission to install..."
MSG_DEPS_APT_FAIL="⚠️  apt update failed (network?), trying with local indexes..."
MSG_DEPS_NO_PM="❌ Package manager not recognized."
MSG_DEPS_MANUAL="Please install manually"
MSG_DEPS_OK="✅ Dependencies installed successfully!"

# ── deploy_services ───────────────────────────────────────────────────────────
MSG_DEPLOY_PROGRESS="Applying settings and restarting timer..."
MSG_DEPLOY_DONE="Scripts generated and Timer activated!\nThe system will run every %s."

# ── install_or_update ─────────────────────────────────────────────────────────
MSG_UPDATE_DONE="Updated successfully!\nScripts and timer have been updated.\nYour settings were preserved."
MSG_INSTALL_DONE="Installed successfully!\nOpen WayLume from your system application menu."

# ── uninstall ─────────────────────────────────────────────────────────────────
TITLE_UNINSTALL_CONFIRM="Warning"
MSG_UNINSTALL_CONFIRM="Do you really want to remove WayLume from the system?\nYour photo gallery will NOT be deleted."
MSG_UNINSTALL_DONE="WayLume completely uninstalled."

# ── set_gallery_dir ───────────────────────────────────────────────────────────
TITLE_GALLERY_PICK="Choose Gallery Folder"
MSG_GALLERY_CHANGED="Gallery changed to:\n%s"

# ── set_update_interval ───────────────────────────────────────────────────────
TITLE_INTERVAL="Update Interval"
MSG_INTERVAL_UNIT="Time unit:"
COL_INTERVAL_UNIT="Unit"
COL_INTERVAL_VALUE="Value"
ITEM_INTERVAL_MIN="Minutes"
ITEM_INTERVAL_H="Hours"
LABEL_MINUTES="minutes"
LABEL_HOURS="hours"
MSG_INTERVAL_SCALE="Interval in %s:"   # %s = minutes | hours
MSG_INTERVAL_CHANGED="Interval changed to %s."

# ── set_image_sources ─────────────────────────────────────────────────────────
TITLE_SOURCES="Image Sources"
MSG_SOURCES_PICK="Choose where to download new images from:"
COL_SOURCES_NAME="Source"
MSG_SOURCES_CHANGED="Image sources changed."

# ── set_apod_api_key ──────────────────────────────────────────────────────────
TITLE_APOD_KEY="WayLume - NASA API Key"
MSG_APOD_KEY_DEMO="(using DEMO_KEY — get yours at api.nasa.gov, it's free!)"
MSG_APOD_KEY_SET="(key configured: %s...)"   # %s = first 6 chars
MSG_APOD_KEY_PROMPT="Enter your NASA APOD API Key:\n%s"   # %s = MSG_APOD_KEY_*
MSG_APOD_KEY_SAVED="API Key saved!"

# ── clean_gallery ────────────────────────────────────────────────────────────────
MSG_GALLERY_CLEAN_OK="No invalid files found in the gallery. ✅"
TITLE_GALLERY_CLEAN="WayLume - Clean Gallery"
MSG_GALLERY_CLEAN_CONFIRM="Found %d corrupted file(s):\n%s\n\nDo you want to remove them?"
MSG_GALLERY_CLEAN_DONE="%d file(s) removed from the gallery."

# ── set_gallery_max ────────────────────────────────────────────────────────────────
TITLE_GALLERY_MAX="WayLume — Gallery Limit"
MSG_GALLERY_MAX_PROMPT="Maximum number of images to keep in the gallery.\n0 = unlimited."
MSG_GALLERY_MAX_SAVED="Gallery limit set to %s images."   # %s = number
MSG_GALLERY_MAX_DISABLED="Gallery limit disabled. Files will accumulate indefinitely."

# ── fetch_and_apply_wallpaper ─────────────────────────────────────────────────
MSG_FETCH_NO_SCRIPTS="Scripts not generated. Run: waylume --install"
MSG_FETCH_PROGRESS="Downloading and applying new wallpaper..."
MSG_FETCH_DONE="Wallpaper applied successfully! 🎉"

# ── bootstrap (auto-install / update prompt) ──────────────────────────────────
TITLE_UPDATE_PROMPT="WayLume Update"
MSG_UPDATE_PROMPT="WayLume is already installed.\nDo you want to update to the version in this folder?\n\nYour settings will be preserved."
TITLE_INSTALL_PROMPT="WayLume Installation"
MSG_INSTALL_PROMPT="WayLume is not installed on this system.\nDo you want to install it now to your user folder (~/.local/bin)?"
MSG_PIN_FAVORITES="Pin WayLume to the Dash/taskbar for quick access?"

# ── main menu ─────────────────────────────────────────────────────────────────
TITLE_MENU="WayLume v${WL_VERSION} - Menu"
MSG_MENU_HEADER="WayLume v${WL_VERSION}\nWallpaper Manager\nCurrent Gallery: %s\nUpdate Interval: %s\nTitle overlay: %s\nTimer: %s"
LABEL_OVERLAY_ON="on"
LABEL_OVERLAY_OFF="off"
LABEL_TIMER_ON="active"
LABEL_TIMER_OFF="paused"
COL_MENU_OPTION="Option"
COL_MENU_ACTION="Action"
MENU_ITEM_1="⬇️  1. Download new image now"
MENU_ITEM_2="🎲 2. Random image from gallery"
MENU_ITEM_3="➡️  3. Next image in gallery"
MENU_ITEM_4="⬅️  4. Previous image in gallery"
MENU_ITEM_5="⚙️  5. Settings"
MENU_ITEM_6="🔧 6. Maintenance"
MENU_ITEM_7="🚪 7. Exit"

# ── settings submenu ──────────────────────────────────────────────────────────────────────────────
TITLE_SETTINGS="WayLume — Settings"
MSG_SETTINGS_HEADER="Change the desired options. On exit, you can apply the changes."
MENU_SETTINGS_1="📂 1. Gallery folder"
MENU_SETTINGS_2="⏱️  2. Update interval"
MENU_SETTINGS_3="🌍 3. Image sources"
MENU_SETTINGS_4="🔑 4. NASA API Key"
MENU_SETTINGS_5="�️  5. Gallery limit"
MENU_SETTINGS_6_ON="🎨 6. Title overlay: ON"
MENU_SETTINGS_6_OFF="🎨 6. Title overlay: OFF"
MENU_SETTINGS_7="🚪 7. Exit"
# ── set_overlay_toggle ─────────────────────────────────────────────────────────
MSG_OVERLAY_DISABLE_PROMPT="The title overlay is currently ON.\nDisable it? The current wallpaper will be updated immediately."
MSG_OVERLAY_ENABLE_PROMPT="The title overlay is currently OFF.\nEnable it? The current wallpaper will be updated immediately."
MSG_OVERLAY_ON="🎨 Title overlay enabled."
MSG_OVERLAY_OFF="🎨 Title overlay disabled."
MSG_SETTINGS_APPLY_PROMPT="Settings were changed. Do you want to apply now?\nThis will also restart the timer with the new interval."

# ── maintenance submenu ────────────────────────────────────────────────────────────────────────────
TITLE_MAINTENANCE="WayLume — Maintenance"
MENU_MAINTENANCE_1_ON="⏸️ 1. Pause timer"
MENU_MAINTENANCE_1_OFF="▶️ 1. Resume timer"
MENU_MAINTENANCE_2="🧹 2. Clean gallery"
MENU_MAINTENANCE_3="🗑️  3. Remove WayLume"

# ── toggle_timer ──────────────────────────────────────────────────────────────
MSG_TIMER_PAUSED="⏸️ Timer paused. Automatic wallpaper updates suspended."
MSG_TIMER_RESUMED="▶️ Timer resumed. Automatic wallpaper updates restarted."

# ── gallery navigation ───────────────────────────────────────────────────────────────────────
MSG_NAV_APPLIED="📸 %s"
MSG_NAV_NO_IMAGES="No images in the gallery. Download new images first."
MSG_NAV_POSITION="📸 Image %s of %s"

# ── fetcher: notify-send messages ─────────────────────────────────────────────
MSG_FETCH_NO_IMAGES="No images found in the gallery."
MSG_FETCH_APOD_ERROR="APOD API: %s\nUsing local gallery.\nTip: register a free API key at api.nasa.gov"
MSG_FETCH_APOD_UPSTREAM="NASA APOD upstream issue: the API returned the generic NASA logo instead of the daily image."
MSG_FETCH_INVALID_MIME="⚠️ Invalid download ignored (%s). Please try again."
MSG_FETCH_LOCAL="🔄 Local gallery (%s already downloaded today)"
MSG_FETCH_SOURCE_BING="New wallpaper downloaded via Bing"
MSG_FETCH_SOURCE_UNSPLASH="New wallpaper downloaded via Unsplash"
MSG_FETCH_SOURCE_APOD="New wallpaper downloaded via APOD"
MSG_FETCH_SOURCE_WIKIMEDIA="New wallpaper downloaded via Wikimedia POTD"
MSG_FETCH_SOURCE_LOCAL="🖼️ Wallpaper from local gallery"
MSG_FETCH_TIMEOUT="⏱️ Connection timed out. Wallpaper not changed. Will retry on next cycle."
WL_I18N_EN

    # Ensure config exists and contains all current fields (idempotent)
    if [ ! -f "$CONF_FILE" ]; then
        save_config
    else
        load_config   # read existing values (preserve DEST_DIR, INTERVAL, etc.)
        save_config   # re-write so new fields (e.g. WAYLUME_LANG) are added
    fi

    # Write the .desktop launcher
    cat << EOF > "$APP_DIR/waylume.desktop"
[Desktop Entry]
Name=WayLume
Comment=Gerenciador de Wallpapers
Exec=waylume
Icon=waylume
Terminal=false
Type=Application
Categories=Utility;Settings;DesktopSettings;
EOF

    # Refresh icon and application caches
    gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" &>/dev/null
    update-desktop-database "$HOME/.local/share/applications" &>/dev/null

    if [ "$IS_UPDATE" = true ]; then
        # Load saved config so deploy_services uses the correct values
        load_config
        deploy_services
        yad_info --title="WayLume" \
            --text="${MSG_UPDATE_DONE:-Updated successfully!\nScripts and timer have been updated.\nYour settings were preserved.}"
    else
        # First install: generate fetcher script and activate the timer
        load_config
        deploy_services
        # Offer to pin WayLume to the GNOME Dash favorites
        pin_to_favorites
        yad_info --title="WayLume" \
            --text="${MSG_INSTALL_DONE:-Installed successfully!\nOpen WayLume from your system application menu.}"
    fi
}

# Add waylume.desktop to GNOME Dash favorites (asks user; silent if not GNOME)
pin_to_favorites() {
    [[ "${XDG_CURRENT_DESKTOP:-}" =~ ^(GNOME|ubuntu:GNOME)$ ]] || return
    local CURRENT NEW
    CURRENT=$(gsettings get org.gnome.shell favorite-apps 2>/dev/null) || return
    # Already pinned — nothing to do
    [[ "$CURRENT" == *"waylume.desktop"* ]] && return
    yad_question --title="WayLume" \
        --text="${MSG_PIN_FAVORITES:-Pin WayLume to the Dash/taskbar for quick access?}" || return
    # Insert waylume.desktop before the closing bracket
    NEW=$(echo "$CURRENT" | sed "s/]$/, 'waylume.desktop']/")
    gsettings set org.gnome.shell favorite-apps "$NEW" 2>/dev/null || true
}

# Remove waylume.desktop from GNOME Dash favorites (silent)
unpin_from_favorites() {
    [[ "${XDG_CURRENT_DESKTOP:-}" =~ ^(GNOME|ubuntu:GNOME)$ ]] || return
    local CURRENT NEW
    CURRENT=$(gsettings get org.gnome.shell favorite-apps 2>/dev/null) || return
    [[ "$CURRENT" != *"waylume.desktop"* ]] && return
    # Remove the entry, handling both middle and last position
    NEW=$(echo "$CURRENT" | sed "s/, 'waylume.desktop'//; s/'waylume.desktop', //; s/'waylume.desktop'//")
    gsettings set org.gnome.shell favorite-apps "$NEW" 2>/dev/null || true
}

# Remove all WayLume files from the system (keeps the photo gallery)
uninstall() {
    yad_question --title="${TITLE_UNINSTALL_CONFIRM}" \
        --text="${MSG_UNINSTALL_CONFIRM:-Do you really want to remove WayLume from the system?\nYour photo gallery will NOT be deleted.}"
    if [ $? -eq 0 ]; then
        systemctl --user disable --now waylume.timer 2>/dev/null
        rm -f "$SYSTEMD_DIR"/waylume.*
        rm -f "$INSTALL_TARGET" "$FETCHER_SCRIPT"
        unpin_from_favorites
        rm -f "$APP_DIR/waylume.desktop"
        rm -f "$ICON_DIR/waylume.svg"
        rm -rf "$CONFIG_DIR"
        systemctl --user daemon-reload
        gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" &>/dev/null
        update-desktop-database "$HOME/.local/share/applications" &>/dev/null
        yad_info --text="${MSG_UNINSTALL_DONE:-WayLume completely uninstalled.}"
        exit 0
    fi
}

# GUI: choose the wallpaper gallery directory
set_gallery_dir() {
    local NEW_DIR
    NEW_DIR=$(_zenity --file-selection --directory \
        --title="${TITLE_GALLERY_PICK}" --filename="$DEST_DIR/")
    if [ -n "$NEW_DIR" ]; then
        DEST_DIR="$NEW_DIR"
        _WL_CONFIG_DIRTY=true
        yad_info --text="$(printf "${MSG_GALLERY_CHANGED:-Gallery changed to:\n%s}" "$DEST_DIR")"
    fi
}

# GUI: choose how often to fetch a new wallpaper
set_update_interval() {
    # Parse current interval into value + unit for the UI
    local CUR_VALUE=1 CUR_UNIT="h"
    if [[ "$INTERVAL" =~ ^([0-9]+)(min|h)$ ]]; then
        CUR_VALUE="${BASH_REMATCH[1]}"
        CUR_UNIT="${BASH_REMATCH[2]}"
    fi

    # Step 1: choose unit
    local MIN_SEL=FALSE H_SEL=FALSE
    [ "$CUR_UNIT" = "min" ] && MIN_SEL=TRUE || H_SEL=TRUE

    local UNIT
    UNIT=$(_zenity --list --radiolist --title="${TITLE_INTERVAL}" \
        --text="${MSG_INTERVAL_UNIT:-Time unit:}" \
        --column="" --column="${COL_INTERVAL_UNIT:-Unit}" --column="${COL_INTERVAL_VALUE:-Value}" \
        $MIN_SEL "${ITEM_INTERVAL_MIN:-Minutes}" "min" \
        $H_SEL   "${ITEM_INTERVAL_H:-Hours}"    "h"  \
        --print-column=3 --hide-column=3 \
        --width=320 --height=320 \
        "${BTNS_OKC[@]}")
    UNIT="${UNIT%%|*}"   # strip trailing pipe (defensive)

    [ -z "$UNIT" ] && return

    # Step 2: choose value with a slider (1–60)
    local LABEL="${LABEL_MINUTES:-minutes}"
    [ "$UNIT" = "h" ] && LABEL="${LABEL_HOURS:-hours}"

    local VALUE
    VALUE=$(_zenity --scale --title="${TITLE_INTERVAL}" \
        --text="$(printf "${MSG_INTERVAL_SCALE:-Interval in %s:}" "$LABEL")" \
        --min-value=1 --max-value=60 --step=1 \
        --value="$CUR_VALUE" \
        "${BTNS_OKC[@]}")

    [ -z "$VALUE" ] && return

    INTERVAL="${VALUE}${UNIT}"
    _WL_CONFIG_DIRTY=true
    yad_info --text="$(printf "${MSG_INTERVAL_CHANGED:-Interval changed to %s.}" "$INTERVAL")"
}

# GUI: choose which image sources to use
set_image_sources() {
    local BING=FALSE UNSPLASH=FALSE APOD=FALSE WIKIMEDIA=FALSE LOCAL=FALSE
    [[ "$SOURCES" == *"Bing"* ]]       && BING=TRUE
    [[ "$SOURCES" == *"Unsplash"* ]]   && UNSPLASH=TRUE
    [[ "$SOURCES" == *"APOD"* ]]       && APOD=TRUE
    [[ "$SOURCES" == *"Wikimedia"* ]]  && WIKIMEDIA=TRUE
    [[ "$SOURCES" == *"Local"* ]]      && LOCAL=TRUE

    local NEW_SOURCES
    NEW_SOURCES=$(_zenity --list --checklist --title="${TITLE_SOURCES}" \
        --text="${MSG_SOURCES_PICK:-Choose where to download new images from:}" \
        --column="" --column="${COL_SOURCES_NAME:-Source}" \
        $BING "Bing" $UNSPLASH "Unsplash" $APOD "APOD" $WIKIMEDIA "Wikimedia" $LOCAL "Local" \
        --print-column=2 --separator="," \
        --width=320 --height=360 --hide-header \
        "${BTNS_OKC[@]}")
    # Strip trailing comma and any whitespace/newlines zenity may inject between items
    NEW_SOURCES=$(echo "$NEW_SOURCES" | tr -d '[:space:]' | sed 's/,$//')

    if [ -n "$NEW_SOURCES" ]; then
        SOURCES="$NEW_SOURCES"
        _WL_CONFIG_DIRTY=true
        yad_info --text="${MSG_SOURCES_CHANGED:-Image sources changed.}"
    fi
}

# GUI: set the NASA APOD API key
set_apod_api_key() {
    local KEY_HINT
    if [ "$APOD_API_KEY" = "DEMO_KEY" ]; then
        KEY_HINT="${MSG_APOD_KEY_DEMO:-(using DEMO_KEY \u2014 get yours at api.nasa.gov, free at api.nasa.gov)}"
    else
        KEY_HINT="$(printf "${MSG_APOD_KEY_SET:-(key configured: %s...)}" "${APOD_API_KEY:0:6}")"
    fi

    local NEW_KEY
    NEW_KEY=$(_zenity --entry \
        --title="${TITLE_APOD_KEY}" \
        --text="$(printf "${MSG_APOD_KEY_PROMPT:-Enter your NASA APOD API Key:\n%s}" "$KEY_HINT")" \
        --entry-text="$APOD_API_KEY" \
        --width=480 \
        "${BTNS_OKC[@]}")

    [ $? -ne 0 ] || [ -z "$NEW_KEY" ] && return

    APOD_API_KEY="$NEW_KEY"
    _WL_CONFIG_DIRTY=true
    yad_info --title="WayLume" \
        --text="${MSG_APOD_KEY_SAVED:-API Key saved!}"
}

# GUI: set the maximum number of images kept in the gallery
set_gallery_max() {
    local NEW_MAX
    NEW_MAX=$(_zenity --scale \
        --title="${TITLE_GALLERY_MAX:-WayLume — Gallery Limit}" \
        --text="${MSG_GALLERY_MAX_PROMPT:-Maximum number of images to keep in the gallery.\n0 = unlimited.}" \
        --value="${GALLERY_MAX_FILES:-60}" \
        --min-value=0 --max-value=500 --step=10 \
        --width=480 \
        "${BTNS_OKC[@]}")
    [ $? -ne 0 ] && return
    GALLERY_MAX_FILES="$NEW_MAX"
    _WL_CONFIG_DIRTY=true
    if [ "$NEW_MAX" = "0" ]; then
        yad_info --title="WayLume" \
            --text="${MSG_GALLERY_MAX_DISABLED:-Gallery limit disabled. Files will accumulate indefinitely.}"
    else
        yad_info --title="WayLume" \
            --text="$(printf "${MSG_GALLERY_MAX_SAVED:-Gallery limit set to %s images.}" "$NEW_MAX")"
    fi
}

# GUI: toggle the title overlay (WayLume brand + image title on wallpaper)
set_overlay_toggle() {
    if [ "$SHOW_OVERLAY" = "true" ]; then
        yad_question --title="WayLume" \
            --text="${MSG_OVERLAY_DISABLE_PROMPT:-The title overlay is currently ON.\nDisable it? The current wallpaper will be updated immediately.}"
        [ $? -ne 0 ] && return
        SHOW_OVERLAY="false"
    else
        yad_question --title="WayLume" \
            --text="${MSG_OVERLAY_ENABLE_PROMPT:-The title overlay is currently OFF.\nEnable it? The current wallpaper will be updated immediately.}"
        [ $? -ne 0 ] && return
        SHOW_OVERLAY="true"
    fi

    # Save config immediately so waylume-fetch reads the new SHOW_OVERLAY value.
    save_config

    # Re-apply the current wallpaper with the updated overlay state.
    local _CURRENT
    _CURRENT=$("$FETCHER_SCRIPT" --get-current-gallery 2>/dev/null)
    if [ -n "$_CURRENT" ] && [ -f "$_CURRENT" ]; then
        "$FETCHER_SCRIPT" --set-wallpaper "$_CURRENT" 2>/dev/null
    fi

    if [ "$SHOW_OVERLAY" = "true" ]; then
        notify-send "WayLume" "${MSG_OVERLAY_ON:-🎨 Title overlay enabled.}"
    else
        notify-send "WayLume" "${MSG_OVERLAY_OFF:-🎨 Title overlay disabled.}"
    fi

    # _WL_CONFIG_DIRTY is intentionally NOT set here: config is already written
    # to disk and overlay toggle does not require a service restart.
}

# Toggle the systemd timer on/off (pause/resume automatic wallpaper updates)
toggle_timer() {
    if systemctl --user is-active --quiet waylume.timer 2>/dev/null; then
        systemctl --user stop waylume.timer
        notify-send "WayLume" "${MSG_TIMER_PAUSED:-⏸️ Timer pausado. Atualizações automáticas suspensas.}"
    else
        systemctl --user start waylume.timer
        notify-send "WayLume" "${MSG_TIMER_RESUMED:-▶️ Timer retomado. Atualizações automáticas reiniciadas.}"
    fi
}

# Remove non-image files from the gallery
clean_gallery() {
    local INVALID=()
    while IFS= read -r -d '' f; do
        MIME=$(file --mime-type -b "$f")
        [[ "$MIME" != image/* ]] && INVALID+=("$f")
    done < <(find "$DEST_DIR" -type f \( -iname "*.jpg" -o -iname "*.png" -o -iname "*.webp" \) -print0)

    if [ ${#INVALID[@]} -eq 0 ]; then
        yad_info --title="WayLume" --text="${MSG_GALLERY_CLEAN_OK:-No invalid files found in the gallery. ✅}"
        return
    fi

    yad_question --title="${TITLE_GALLERY_CLEAN}" \
        --text="$(printf "${MSG_GALLERY_CLEAN_CONFIRM:-Found %d corrupted file(s):\n%s\n\nDo you want to remove them?}" "${#INVALID[@]}" "$(printf '%s\n' "${INVALID[@]}")")"
    if [ $? -eq 0 ]; then
        rm -f "${INVALID[@]}"
        yad_info --title="WayLume" --text="$(printf "${MSG_GALLERY_CLEAN_DONE:-%d file(s) removed from the gallery.}" "${#INVALID[@]}")"
    fi
}

# Download a new image from a configured source and apply it immediately
fetch_and_apply_wallpaper() {
    if [ ! -f "$FETCHER_SCRIPT" ]; then
        yad_error \
            --text="${MSG_FETCH_NO_SCRIPTS:-Scripts not generated. Run: waylume --install}"
        return
    fi

    # Show progress while downloading/applying
    if run_with_progress "${MSG_FETCH_PROGRESS:-Downloading and applying new wallpaper...}" "$FETCHER_SCRIPT"; then
        yad_info --title="WayLume" --text="${MSG_FETCH_DONE:-Wallpaper applied successfully! 🎉}"
    fi
}

# Navigate the local gallery circularly (direction: next | prev | random).
# Delegates entirely to waylume-fetch --nav, which owns the db and overlay logic.
# Prints the position indicator ("Image N of M") received from the fetcher.
_gallery_navigate() {
    local DIRECTION="$1"
    local RESULT
    RESULT=$("$FETCHER_SCRIPT" --nav "$DIRECTION" 2>/dev/null)
    local RC=$?
    if [ "$RC" -ne 0 ]; then
        # Fetcher printed its own notify-send error; nothing more to do.
        return 1
    fi
    [ -n "$RESULT" ] && notify-send "WayLume" "$RESULT"
}

go_next_image()   { _gallery_navigate next;   }
go_prev_image()   { _gallery_navigate prev;    }
go_random_image() { _gallery_navigate random;  }

# Submenu: configuration options — accumulates changes in memory;
# saves and deploys only when user confirms on exit.
menu_settings() {
    _WL_CONFIG_DIRTY=false
    while true; do
        CHOICE=$(_zenity --list --title="${TITLE_SETTINGS:-WayLume — Settings}" \
            --text="${MSG_SETTINGS_HEADER:-Change the desired options. On exit, you can apply the changes.}" \
            --column="${COL_MENU_OPTION:-Option}" --column="${COL_MENU_ACTION:-Action}" --hide-column=1 --print-column=1 \
            1 "${MENU_SETTINGS_1:-📂 1. Gallery folder}" \
            2 "${MENU_SETTINGS_2:-⏱️  2. Update interval}" \
            3 "${MENU_SETTINGS_3:-🌍 3. Image sources}" \
            4 "${MENU_SETTINGS_4:-🔑 4. NASA API Key}" \
            5 "${MENU_SETTINGS_5:-🖼️  5. Gallery limit}" \
            6 "$([ "$SHOW_OVERLAY" = "true" ] && echo "${MENU_SETTINGS_6_ON:-🎨 6. Title overlay: ON}" || echo "${MENU_SETTINGS_6_OFF:-🎨 6. Title overlay: OFF}")" \
            7 "${MENU_SETTINGS_7:-🚪 7. Exit}" \
            --width=440 --height=520 --hide-header \
            "${BTNS_OKC[@]}")
        CHOICE="${CHOICE%%|*}"
        [ $? -ne 0 ] || [ -z "$CHOICE" ] && break
        case "$CHOICE" in
            1) set_gallery_dir      ;;
            2) set_update_interval  ;;
            3) set_image_sources    ;;
            4) set_apod_api_key     ;;
            5) set_gallery_max      ;;
            6) set_overlay_toggle   ;;
            7) break                ;;
        esac
    done

    if $_WL_CONFIG_DIRTY; then
        yad_question --title="WayLume" \
            --text="${MSG_SETTINGS_APPLY_PROMPT:-Settings were changed. Do you want to apply now?\nThis will also restart the timer with the new interval.}"
        if [ $? -eq 0 ]; then
            save_config
            deploy_services
        fi
    fi
}

# Submenu: maintenance options (timer toggle, clean gallery, uninstall)
menu_maintenance() {
    while true; do
        CHOICE=$(_zenity --list --title="${TITLE_MAINTENANCE:-WayLume — Maintenance}" \
            --column="${COL_MENU_OPTION:-Option}" --column="${COL_MENU_ACTION:-Action}" --hide-column=1 --print-column=1 \
            1 "$(systemctl --user is-active --quiet waylume.timer 2>/dev/null && echo "${MENU_MAINTENANCE_1_ON:-⏸️ 1. Pausar timer}" || echo "${MENU_MAINTENANCE_1_OFF:-▶️ 1. Retomar timer}")" \
            2 "${MENU_MAINTENANCE_2:-🧹 2. Limpar galeria}" \
            3 "${MENU_MAINTENANCE_3:-🗑️  3. Remover WayLume}" \
            --width=400 --height=320 --hide-header \
            "${BTNS_OKC[@]}")
        CHOICE="${CHOICE%%|*}"
        [ $? -ne 0 ] || [ -z "$CHOICE" ] && break
        case "$CHOICE" in
            1) toggle_timer  ;;
            2) clean_gallery ;;
            3) uninstall     ;;
        esac
    done
}

# ====================================================
# BOOTSTRAP
# ====================================================

# Parse command-line options
case "${1:-}" in
    --uninstall)
        check_dependencies
        load_config
        uninstall
        exit 0
        ;;
    --install)
        check_dependencies
        if [ -f "$INSTALL_TARGET" ]; then
            install_or_update true
        else
            install_or_update false
        fi
        exit 0
        ;;
    --version|-V)
        echo "WayLume ${WL_VERSION}"
        exit 0
        ;;
    --help|-h)
        echo "WayLume ${WL_VERSION}"
        echo "Usage: waylume [option]"
        echo "  (no option)   Opens the settings menu (or installs if needed)"
        echo "  --install     Install or update WayLume"
        echo "  --uninstall   Remove WayLume from the system"
        echo "  --version     Show version"
        echo "  --help        Show this help"
        exit 0
        ;;
    "")
        : # No argument — continue with normal flow
        ;;
    *)
        echo "Opção desconhecida: $1" >&2
        echo "Use --help para ver as opções disponíveis." >&2
        exit 1
        ;;
esac

check_dependencies

# Auto-install / update when running from outside ~/.local/bin
if [ "$(realpath "$0")" != "$(realpath "$INSTALL_TARGET")" ]; then
    if [ -f "$INSTALL_TARGET" ]; then
        yad_question --title="${TITLE_UPDATE_PROMPT}" \
            --text="${MSG_UPDATE_PROMPT:-WayLume is already installed.\nDo you want to update to the version in this folder?\n\nYour settings will be preserved.}"
        [ $? -eq 0 ] && install_or_update true
    else
        yad_question --title="${TITLE_INSTALL_PROMPT}" \
            --text="${MSG_INSTALL_PROMPT:-WayLume is not installed on this system.\nDo you want to install it now to your user folder (~/.local/bin)?}"
        [ $? -eq 0 ] && install_or_update false
    fi

    exit 0
fi

# ====================================================
# MAIN — load config and show the main menu
# ====================================================

load_config

while true; do
    CHOICE=$(_zenity --list --title="${TITLE_MENU}" \
        --text="$(printf "${MSG_MENU_HEADER:-Wallpaper Manager\nCurrent Gallery: %s\nUpdate Interval: %s\nTitle overlay: %s\nTimer: %s}" "$DEST_DIR" "$INTERVAL" "$([ "$SHOW_OVERLAY" = "true" ] && echo "${LABEL_OVERLAY_ON:-ON}" || echo "${LABEL_OVERLAY_OFF:-OFF}")" "$(systemctl --user is-active --quiet waylume.timer 2>/dev/null && echo "${LABEL_TIMER_ON:-on}" || echo "${LABEL_TIMER_OFF:-paused}")")" \
        --column="${COL_MENU_OPTION:-Option}" --column="${COL_MENU_ACTION:-Action}" --hide-column=1 --print-column=1 \
        1 "${MENU_ITEM_1:-⬇️  1. Download new image now}" \
        2 "${MENU_ITEM_2:-🎲 2. Random image from gallery}" \
        3 "${MENU_ITEM_3:-➡️  3. Next image in gallery}" \
        4 "${MENU_ITEM_4:-⬅️  4. Previous image in gallery}" \
        5 "${MENU_ITEM_5:-⚙️  5. Settings}" \
        6 "${MENU_ITEM_6:-🔧 6. Maintenance}" \
        7 "${MENU_ITEM_7:-🚪 7. Exit}" \
        --width=480 --height=560 --hide-header \
        "${BTNS_OKC[@]}")
    CHOICE="${CHOICE%%|*}"   # strip trailing pipe (defensive)

    # Exit on window close (X button / Alt+F4) or empty selection
    [ $? -ne 0 ] || [ -z "$CHOICE" ] && break

    case "$CHOICE" in
        1) fetch_and_apply_wallpaper ;;
        2) go_random_image           ;;
        3) go_next_image             ;;
        4) go_prev_image             ;;
        5) menu_settings             ;;
        6) menu_maintenance          ;;
        7) break                     ;;
    esac
done

exit 0