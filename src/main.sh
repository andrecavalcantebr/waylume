#!/bin/bash
# ====================================================
# WayLume - Minimalist Wayland Wallpaper Manager
# Version: 1.5.0
# ====================================================

WL_VERSION="1.7.0"

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
: "${TITLE_MENU:=WayLume - Menu}" "${TITLE_INTERVAL:=Update Interval}"
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
YAD_BTN_OK=(--ok-label="${BTN_CLOSE}")
YAD_BTN_YN=(--ok-label="${BTN_YES}"  --cancel-label="${BTN_NO}")
YAD_BTN_OKC=(--ok-label="${BTN_OK}" --cancel-label="${BTN_CLOSE}")

# Wrappers so button labels are consistent without repeating them everywhere
yad_info()     { _zenity --info     "${YAD_BTN_OK[@]}"  "$@"; }
yad_error()    { _zenity --error    "${YAD_BTN_OK[@]}"  "$@"; }
yad_question() { _zenity --question "${YAD_BTN_YN[@]}"  "$@"; }

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
    } > "$CONF_FILE"
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
##FETCHER_CONTENT##
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
##ICON_CONTENT##
SVGEOF

    # Write i18n string files (plain text, safe to customize)
    mkdir -p "$CONFIG_DIR/i18n"
    cat << 'WL_I18N_PT' > "$CONFIG_DIR/i18n/pt.sh"
##I18N_PT##
WL_I18N_PT
    cat << 'WL_I18N_EN' > "$CONFIG_DIR/i18n/en.sh"
##I18N_EN##
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
        # First install: offer to pin WayLume to the GNOME Dash favorites
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
        --title="${TITLE_GALLERY_PICK}" --filename="$DEST_DIR/" \
        "${YAD_BTN_OKC[@]}")
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
        "${YAD_BTN_OKC[@]}")
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
        "${YAD_BTN_OKC[@]}")

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
        "${YAD_BTN_OKC[@]}")
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
        "${YAD_BTN_OKC[@]}")

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
        "${YAD_BTN_OKC[@]}")
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
            --text="${MSG_OVERLAY_DISABLE_PROMPT:-The title overlay is currently ON.\nDisable it? Images will no longer show the WayLume brand or the image title.}"
        [ $? -ne 0 ] && return
        SHOW_OVERLAY="false"
        yad_info --title="WayLume" \
            --text="${MSG_OVERLAY_OFF:-Title overlay disabled. New downloads will not have the title bar.}"
    else
        yad_question --title="WayLume" \
            --text="${MSG_OVERLAY_ENABLE_PROMPT:-The title overlay is currently OFF.\nEnable it? Images will show the WayLume brand and the image title.}"
        [ $? -ne 0 ] && return
        SHOW_OVERLAY="true"
        yad_info --title="WayLume" \
            --text="${MSG_OVERLAY_ON:-Title overlay enabled. New downloads will show the title bar.}"
    fi
    _WL_CONFIG_DIRTY=true
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

# Navigate the local gallery circularly (direction: next | prev | random)
# Images already have overlays applied — only gsettings + notify-send here.
_gallery_navigate() {
    local DIRECTION="$1"
    local FILES=()
    while IFS= read -r -d '' f; do
        FILES+=("$f")
    done < <(find "$DEST_DIR" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.png" \) -print0 | sort -z)

    local COUNT=${#FILES[@]}
    if [ "$COUNT" -eq 0 ]; then
        notify-send "WayLume" "${MSG_NAV_NO_IMAGES:-No images in the gallery. Download new images first.}"
        return
    fi

    local IDX=0
    if [ "$DIRECTION" = "random" ]; then
        IDX=$(( RANDOM % COUNT ))
    else
        # Find the currently displayed wallpaper in the sorted gallery list
        local CURRENT
        CURRENT=$(waylume-fetch --get-current-wallpaper 2>/dev/null || \
            gsettings get org.gnome.desktop.background picture-uri 2>/dev/null \
            | tr -d "'" | sed 's|file://||')
        local FOUND=false
        for i in "${!FILES[@]}"; do
            if [ "${FILES[$i]}" = "$CURRENT" ]; then
                IDX=$i
                FOUND=true
                break
            fi
        done
        # If current is not from our gallery, start from beginning / end
        if ! $FOUND; then
            [ "$DIRECTION" = "prev" ] && IDX=$(( COUNT - 1 )) || IDX=0
        elif [ "$DIRECTION" = "next" ]; then
            IDX=$(( (IDX + 1) % COUNT ))
        else
            IDX=$(( (IDX - 1 + COUNT) % COUNT ))
        fi
    fi

    local TARGET="${FILES[$IDX]}"
    waylume-fetch --set-wallpaper "$TARGET" 2>/dev/null || {
        gsettings set org.gnome.desktop.background picture-uri      "file://$TARGET"
        gsettings set org.gnome.desktop.background picture-uri-dark "file://$TARGET"
    }
    notify-send "WayLume" "$(printf "${MSG_NAV_APPLIED:-📸 %s}" "$(basename "$TARGET")")"
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
            "${YAD_BTN_OKC[@]}")
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
            "${YAD_BTN_OKC[@]}")
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
        "${YAD_BTN_OKC[@]}")
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
