#!/bin/bash
# ====================================================
# WayLume - Minimalist Wayland Wallpaper Manager
# Version: 1.1.0
# ====================================================

WL_VERSION="1.1.0"

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

# Force yad through XWayland so WM_CLASS and window icons work correctly.
# Without this, yad running under a native Wayland session triggers
# GDK X11 assertion errors and --class has no effect on the taskbar icon.
export GDK_BACKEND=x11

# yad base options: consistent class and icon across all dialogs
# --class sets WM_CLASS so GNOME Shell matches the window to waylume.desktop
YAD_BASE=(--class=WayLume --window-icon="$ICON_DIR/waylume.svg" --borders=10)

# Button label presets (populated from i18n file loaded above)
YAD_BTN_OK=(--button="${BTN_CLOSE}:0")
YAD_BTN_YN=(--button="${BTN_NO}:1" --button="${BTN_YES}:0")
YAD_BTN_OKC=(--button="${BTN_CLOSE}:1" --button="${BTN_OK}:0")

# Wrappers so button labels are consistent without repeating them everywhere
yad_info()     { yad "${YAD_BASE[@]}" --info     "${YAD_BTN_OK[@]}"  "$@"; }
yad_error()    { yad "${YAD_BASE[@]}" --error    "${YAD_BTN_OK[@]}"  "$@"; }
yad_question() { yad "${YAD_BASE[@]}" --question "${YAD_BTN_YN[@]}"  "$@"; }

# Show a pulsate progress dialog, run a command in background, wait, then close
# Unlike zenity, yad --progress --pulsate does not depend on stdin to stay open,
# so we never send < /dev/null (which caused an immediate EOF → auto-close).
run_with_progress() {
    local MSG="$1"; shift
    yad "${YAD_BASE[@]}" \
        --progress --pulsate \
        --title="WayLume" --text="$MSG" \
        --width=380 --no-buttons &
    local YPID=$!
    "$@"
    local RC=$?
    kill $YPID 2>/dev/null; wait $YPID 2>/dev/null
    return $RC
}

# Check and install missing runtime dependencies
check_dependencies() {
    # Runtime commands required by this script
    local REQUIRED=("yad" "curl" "notify-send" "file")
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
    } > "$CONF_FILE"
}

# Load config from disk, applying defaults for missing keys
load_config() {
    _wl_read_keyval "$CONF_FILE" DEST_DIR INTERVAL SOURCES APOD_API_KEY GALLERY_MAX_FILES
    [ -z "$DEST_DIR" ]          && DEST_DIR="$(xdg-user-dir PICTURES 2>/dev/null || echo "$HOME/Pictures")/WayLume"
    [ -z "$INTERVAL" ]          && INTERVAL="1h"
    [ -z "$SOURCES" ]           && SOURCES="Unsplash"
    [ -z "$APOD_API_KEY" ]      && APOD_API_KEY="DEMO_KEY"
    [ -z "$GALLERY_MAX_FILES" ] && GALLERY_MAX_FILES=60
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
    NEW_DIR=$(yad "${YAD_BASE[@]}" --file --directory \
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
    UNIT=$(yad "${YAD_BASE[@]}" --list --radiolist --title="${TITLE_INTERVAL}" \
        --text="${MSG_INTERVAL_UNIT:-Time unit:}" \
        --column="" --column="${COL_INTERVAL_UNIT:-Unit}" --column="${COL_INTERVAL_VALUE:-Value}" \
        $MIN_SEL "${ITEM_INTERVAL_MIN:-Minutes}" "min" \
        $H_SEL   "${ITEM_INTERVAL_H:-Hours}"    "h"  \
        --print-column=3 --hide-column=3 \
        --width=320 --height=280 \
        "${YAD_BTN_OKC[@]}")
    UNIT="${UNIT%%|*}"   # yad may append a trailing pipe separator

    [ -z "$UNIT" ] && return

    # Step 2: choose value with a slider (1–60)
    local LABEL="${LABEL_MINUTES:-minutes}"
    [ "$UNIT" = "h" ] && LABEL="${LABEL_HOURS:-hours}"

    local VALUE
    VALUE=$(yad "${YAD_BASE[@]}" --scale --title="${TITLE_INTERVAL}" \
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
    local BING=FALSE UNSPLASH=FALSE APOD=FALSE WIKIMEDIA=FALSE
    [[ "$SOURCES" == *"Bing"* ]]       && BING=TRUE
    [[ "$SOURCES" == *"Unsplash"* ]]   && UNSPLASH=TRUE
    [[ "$SOURCES" == *"APOD"* ]]       && APOD=TRUE
    [[ "$SOURCES" == *"Wikimedia"* ]]  && WIKIMEDIA=TRUE

    local NEW_SOURCES
    NEW_SOURCES=$(yad "${YAD_BASE[@]}" --list --checklist --title="${TITLE_SOURCES}" \
        --text="${MSG_SOURCES_PICK:-Choose where to download new images from:}" \
        --column="" --column="${COL_SOURCES_NAME:-Source}" \
        $BING "Bing" $UNSPLASH "Unsplash" $APOD "APOD" $WIKIMEDIA "Wikimedia" \
        --print-column=2 --separator="," \
        --width=280 --height=255 --no-headers \
        "${YAD_BTN_OKC[@]}")
    # Strip trailing comma and any whitespace/newlines yad may inject between items
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
    NEW_KEY=$(yad "${YAD_BASE[@]}" --entry \
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
    NEW_MAX=$(yad "${YAD_BASE[@]}" --scale \
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
    run_with_progress "${MSG_FETCH_PROGRESS:-Downloading and applying new wallpaper...}" "$FETCHER_SCRIPT"
    yad_info --title="WayLume" --text="${MSG_FETCH_DONE:-Wallpaper applied successfully! 🎉}"
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
        CURRENT=$(gsettings get org.gnome.desktop.background picture-uri 2>/dev/null \
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
    gsettings set org.gnome.desktop.background picture-uri      "file://$TARGET"
    gsettings set org.gnome.desktop.background picture-uri-dark "file://$TARGET"
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
        CHOICE=$(yad "${YAD_BASE[@]}" --list --title="${TITLE_SETTINGS:-WayLume \u2014 Settings}" \
            --text="${MSG_SETTINGS_HEADER:-Change the desired options. On exit, you can apply the changes.}" \
            --column="${COL_MENU_OPTION:-Option}" --column="${COL_MENU_ACTION:-Action}" --hide-column=1 --print-column=1 \
            1 "${MENU_SETTINGS_1:-📂 1. Gallery folder}" \
            2 "${MENU_SETTINGS_2:-⏱️  2. Update interval}" \
            3 "${MENU_SETTINGS_3:-🌍 3. Image sources}" \
            4 "${MENU_SETTINGS_4:-🔑 4. NASA API Key}" \
            5 "${MENU_SETTINGS_5:-�️  5. Gallery limit}" \
            6 "${MENU_SETTINGS_6:-🚪 6. Exit}" \
            --width=420 --height=360 --no-headers \
            "${YAD_BTN_OKC[@]}")
        CHOICE="${CHOICE%%|*}"
        [ $? -ne 0 ] || [ -z "$CHOICE" ] && break
        case "$CHOICE" in
            1) set_gallery_dir      ;;
            2) set_update_interval  ;;
            3) set_image_sources    ;;
            4) set_apod_api_key     ;;
            5) set_gallery_max      ;;
            6) break                ;;
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

# Submenu: maintenance options (clean gallery, uninstall)
menu_maintenance() {
    while true; do
        CHOICE=$(yad "${YAD_BASE[@]}" --list --title="${TITLE_MAINTENANCE:-WayLume \u2014 Maintenance}" \
            --column="${COL_MENU_OPTION:-Option}" --column="${COL_MENU_ACTION:-Action}" --hide-column=1 --print-column=1 \
            1 "${MENU_MAINTENANCE_1:-🧹 1. Clean gallery}" \
            2 "${MENU_MAINTENANCE_2:-🗑️  2. Remove WayLume}" \
            --width=380 --height=220 --no-headers \
            "${YAD_BTN_OKC[@]}")
        CHOICE="${CHOICE%%|*}"
        [ $? -ne 0 ] || [ -z "$CHOICE" ] && break
        case "$CHOICE" in
            1) clean_gallery ;;
            2) uninstall     ;;
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
    CHOICE=$(yad "${YAD_BASE[@]}" --list --title="${TITLE_MENU}" \
        --text="$(printf "${MSG_MENU_HEADER:-Wallpaper Manager for GNOME\nCurrent Gallery: %s\nUpdate Interval: %s}" "$DEST_DIR" "$INTERVAL")" \
        --column="${COL_MENU_OPTION:-Option}" --column="${COL_MENU_ACTION:-Action}" --hide-column=1 --print-column=1 \
        1 "${MENU_ITEM_1:-⬇️  1. Download new image now}" \
        2 "${MENU_ITEM_2:-🎲 2. Random image from gallery}" \
        3 "${MENU_ITEM_3:-➡️  3. Next image in gallery}" \
        4 "${MENU_ITEM_4:-⬅️  4. Previous image in gallery}" \
        5 "${MENU_ITEM_5:-⚙️  5. Settings}" \
        6 "${MENU_ITEM_6:-🔧 6. Maintenance}" \
        7 "${MENU_ITEM_7:-🚪 7. Exit}" \
        --width=460 --height=340 --no-headers \
        "${YAD_BTN_OKC[@]}")
    CHOICE="${CHOICE%%|*}"   # strip trailing pipe yad may append

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
