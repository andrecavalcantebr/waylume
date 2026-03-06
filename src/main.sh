#!/bin/bash
# ====================================================
# WayLume - Minimalist Wayland Wallpaper Manager
# ====================================================

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

# ====================================================
# FUNCTIONS
# ====================================================

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

    echo "${MSG_DEPS_NEEDED:-⚠️ O WayLume precisa de alguns pacotes para funcionar}: ${MISSING[*]}"
    echo "${MSG_DEPS_ASKING:-Solicitando permissão para instalar...}"

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
        sudo apt-get update 2>/dev/null || echo "${MSG_DEPS_APT_FAIL:-⚠️  apt update falhou (rede?), tentando com índices locais...}"
        sudo apt-get install -y "${PACKAGES[@]}" || exit 1
    elif command -v dnf &>/dev/null; then
        for cmd in "${MISSING[@]}"; do PACKAGES+=("$(pkg_name "$cmd" dnf)"); done
        sudo dnf install -y "${PACKAGES[@]}" || exit 1
    elif command -v pacman &>/dev/null; then
        for cmd in "${MISSING[@]}"; do PACKAGES+=("$(pkg_name "$cmd" pacman)"); done
        sudo pacman -S --noconfirm "${PACKAGES[@]}" || exit 1
    else
        echo "${MSG_DEPS_NO_PM:-❌ Gerenciador de pacotes não reconhecido.}"
        echo "${MSG_DEPS_MANUAL:-Por favor, instale manualmente}: ${MISSING[*]}"
        exit 1
    fi

    echo "${MSG_DEPS_OK:-✅ Dependências instaladas com sucesso!}"
}

# Persist current config to disk
save_config() {
    {
        echo "DEST_DIR=\"$DEST_DIR\""
        echo "INTERVAL=\"$INTERVAL\""
        echo "SOURCES=\"$SOURCES\""
        echo "APOD_API_KEY=\"$APOD_API_KEY\""
    } > "$CONF_FILE"
}

# Load config from disk, applying defaults for missing keys
load_config() {
    source "$CONF_FILE" 2>/dev/null
    [ -z "$DEST_DIR" ]     && DEST_DIR="$(xdg-user-dir PICTURES 2>/dev/null || echo "$HOME/Pictures")/WayLume"
    [ -z "$INTERVAL" ]     && INTERVAL="1h"
    [ -z "$SOURCES" ]      && SOURCES="Unsplash"
    [ -z "$APOD_API_KEY" ] && APOD_API_KEY="DEMO_KEY"
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
    run_with_progress "${MSG_DEPLOY_PROGRESS:-Aplicando configurações e reiniciando timer...}" \
        bash -c '
            systemctl --user daemon-reload
            systemctl --user disable waylume.timer 2>/dev/null
            systemctl --user enable --now waylume.timer
            systemctl --user start waylume.service || true
        '

    yad_info --title="WayLume" \
        --text="$(printf "${MSG_DEPLOY_DONE:-Scripts gerados e Timer ativado!\nO sistema rodará a cada %s.}" "$INTERVAL")"
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
            --text="${MSG_UPDATE_DONE:-Atualizado com sucesso!\nScripts e timer foram atualizados.\nSuas configurações foram preservadas.}"
    else
        yad_info --title="WayLume" \
            --text="${MSG_INSTALL_DONE:-Instalado com sucesso!\nAbra o WayLume pelo menu de aplicativos do seu sistema.}"
    fi
}

# Remove all WayLume files from the system (keeps the photo gallery)
uninstall() {
    yad_question --title="${TITLE_UNINSTALL_CONFIRM}" \
        --text="${MSG_UNINSTALL_CONFIRM:-Deseja realmente remover o WayLume do sistema?\nSua galeria de fotos NÃO será apagada.}"
    if [ $? -eq 0 ]; then
        systemctl --user disable --now waylume.timer 2>/dev/null
        rm -f "$SYSTEMD_DIR"/waylume.*
        rm -f "$INSTALL_TARGET" "$FETCHER_SCRIPT"
        rm -f "$APP_DIR/waylume.desktop"
        rm -f "$ICON_DIR/waylume.svg"
        rm -rf "$CONFIG_DIR"
        systemctl --user daemon-reload
        gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" &>/dev/null
        update-desktop-database "$HOME/.local/share/applications" &>/dev/null
        yad_info --text="${MSG_UNINSTALL_DONE:-WayLume desinstalado completamente.}"
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
        save_config
        yad_info --text="$(printf "${MSG_GALLERY_CHANGED:-Galeria alterada para:\n%s\n\nLembre-se de clicar em 'Instalar/Atualizar Scripts' para aplicar.}" "$DEST_DIR")"
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
        --text="${MSG_INTERVAL_UNIT:-Unidade de tempo:}" \
        --column="" --column="${COL_INTERVAL_UNIT:-Unidade}" --column="${COL_INTERVAL_VALUE:-Valor}" \
        $MIN_SEL "${ITEM_INTERVAL_MIN:-Minutos}" "min" \
        $H_SEL   "${ITEM_INTERVAL_H:-Horas}"    "h"  \
        --print-column=3 --hide-column=3 \
        --width=320 --height=280 \
        "${YAD_BTN_OKC[@]}")
    UNIT="${UNIT%%|*}"   # yad may append a trailing pipe separator

    [ -z "$UNIT" ] && return

    # Step 2: choose value with a slider (1–60)
    local LABEL="${LABEL_MINUTES:-minutos}"
    [ "$UNIT" = "h" ] && LABEL="${LABEL_HOURS:-horas}"

    local VALUE
    VALUE=$(yad "${YAD_BASE[@]}" --scale --title="${TITLE_INTERVAL}" \
        --text="$(printf "${MSG_INTERVAL_SCALE:-Intervalo em %s:}" "$LABEL")" \
        --min-value=1 --max-value=60 --step=1 \
        --value="$CUR_VALUE" \
        "${YAD_BTN_OKC[@]}")

    [ -z "$VALUE" ] && return

    INTERVAL="${VALUE}${UNIT}"
    save_config
    yad_info --text="$(printf "${MSG_INTERVAL_CHANGED:-Tempo alterado para %s.\nLembre-se de clicar em 'Instalar/Atualizar Scripts' para aplicar.}" "$INTERVAL")"
}

# GUI: choose which image sources to use
set_image_sources() {
    local BING=FALSE UNSPLASH=FALSE APOD=FALSE
    [[ "$SOURCES" == *"Bing"* ]]     && BING=TRUE
    [[ "$SOURCES" == *"Unsplash"* ]] && UNSPLASH=TRUE
    [[ "$SOURCES" == *"APOD"* ]]     && APOD=TRUE

    local NEW_SOURCES
    NEW_SOURCES=$(yad "${YAD_BASE[@]}" --list --checklist --title="${TITLE_SOURCES}" \
        --text="${MSG_SOURCES_PICK:-Escolha de onde baixar as imagens novas:}" \
        --column="" --column="${COL_SOURCES_NAME:-Fonte}" \
        $BING "Bing" $UNSPLASH "Unsplash" $APOD "APOD" \
        --print-column=2 --separator="," \
        --width=280 --height=220 --no-headers \
        "${YAD_BTN_OKC[@]}")
    # Strip trailing comma and any whitespace/newlines yad may inject between items
    NEW_SOURCES=$(echo "$NEW_SOURCES" | tr -d '[:space:]' | sed 's/,$//')

    if [ -n "$NEW_SOURCES" ]; then
        SOURCES="$NEW_SOURCES"
        save_config
        yad_info --text="${MSG_SOURCES_CHANGED:-Fontes alteradas.\nLembre-se de clicar em 'Instalar/Atualizar Scripts' para aplicar.}"
    fi
}

# GUI: set the NASA APOD API key
set_apod_api_key() {
    local KEY_HINT
    if [ "$APOD_API_KEY" = "DEMO_KEY" ]; then
        KEY_HINT="${MSG_APOD_KEY_DEMO:-(usando DEMO_KEY — gere a sua em api.nasa.gov, é grátis!)}"
    else
        KEY_HINT="$(printf "${MSG_APOD_KEY_SET:-(chave configurada: %s...)}" "${APOD_API_KEY:0:6}")"
    fi

    local NEW_KEY
    NEW_KEY=$(yad "${YAD_BASE[@]}" --entry \
        --title="${TITLE_APOD_KEY}" \
        --text="$(printf "${MSG_APOD_KEY_PROMPT:-Informe sua API Key da NASA APOD:\n%s}" "$KEY_HINT")" \
        --entry-text="$APOD_API_KEY" \
        --width=480 \
        "${YAD_BTN_OKC[@]}")

    [ $? -ne 0 ] || [ -z "$NEW_KEY" ] && return

    APOD_API_KEY="$NEW_KEY"
    save_config
    yad_info --title="WayLume" \
        --text="${MSG_APOD_KEY_SAVED:-API Key salva!\nLembre-se de clicar em 'Instalar/Atualizar Scripts' para aplicar.}"
}

# Remove non-image files from the gallery
clean_gallery() {
    local INVALID=()
    while IFS= read -r -d '' f; do
        MIME=$(file --mime-type -b "$f")
        [[ "$MIME" != image/* ]] && INVALID+=("$f")
    done < <(find "$DEST_DIR" -type f \( -iname "*.jpg" -o -iname "*.png" -o -iname "*.webp" \) -print0)

    if [ ${#INVALID[@]} -eq 0 ]; then
        yad_info --title="WayLume" --text="${MSG_GALLERY_CLEAN_OK:-Nenhum arquivo inválido encontrado na galeria. ✅}"
        return
    fi

    yad_question --title="${TITLE_GALLERY_CLEAN}" \
        --text="$(printf "${MSG_GALLERY_CLEAN_CONFIRM:-Encontrados %d arquivo(s) corrompido(s):\n%s\n\nDeseja removê-los?}" "${#INVALID[@]}" "$(printf '%s\n' "${INVALID[@]}")")"
    if [ $? -eq 0 ]; then
        rm -f "${INVALID[@]}"
        yad_info --title="WayLume" --text="$(printf "${MSG_GALLERY_CLEAN_DONE:-%d arquivo(s) removido(s) da galeria.}" "${#INVALID[@]}")"
    fi
}

# Apply a random wallpaper from the local gallery immediately
fetch_and_apply_wallpaper() {
    if [ ! -f "$FETCHER_SCRIPT" ]; then
        yad_error \
            --text="${MSG_FETCH_NO_SCRIPTS:-Os scripts ainda não foram gerados.\nClique em 'Instalar/Atualizar Scripts' primeiro.}"
        return
    fi

    # Show progress while downloading/applying
    run_with_progress "${MSG_FETCH_PROGRESS:-Baixando e aplicando novo wallpaper...}" "$FETCHER_SCRIPT"
    yad_info --title="WayLume" --text="${MSG_FETCH_DONE:-Wallpaper aplicado com sucesso! 🎉}"
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
    --help|-h)
        echo "Uso: waylume [opção]"
        echo "  (sem opção)   Abre o menu de configuração (ou instala se necessário)"
        echo "  --install     Instala ou atualiza o WayLume"
        echo "  --uninstall   Remove o WayLume do sistema"
        echo "  --help        Exibe esta ajuda"
        exit 0
        ;;
    "")
        : # Sem argumento — continua com o fluxo normal
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
            --text="${MSG_UPDATE_PROMPT:-O WayLume já está instalado.\nDeseja atualizar para a versão desta pasta?\n\nSuas configurações serão preservadas.}"
        [ $? -eq 0 ] && install_or_update true
    else
        yad_question --title="${TITLE_INSTALL_PROMPT}" \
            --text="${MSG_INSTALL_PROMPT:-O WayLume não está instalado no sistema.\nDeseja instalar agora na sua pasta de usuário (~/.local/bin)?}"
        [ $? -eq 0 ] && install_or_update false
    fi

    exit 0
fi

# ====================================================
# MAIN — load config and show the settings menu
# ====================================================

load_config

while true; do
    CHOICE=$(yad "${YAD_BASE[@]}" --list --title="${TITLE_MENU}" \
        --text="$(printf "${MSG_MENU_HEADER:-Gerenciador de Wallpapers para GNOME\nGaleria Atual: %s\nAtualização: %s}" "$DEST_DIR" "$INTERVAL")" \
        --column="${COL_MENU_OPTION:-Opção}" --column="${COL_MENU_ACTION:-Ação}" --hide-column=1 --print-column=1 \
        1 "${MENU_ITEM_1:-📂 1. Escolher pasta da galeria}" \
        2 "${MENU_ITEM_2:-⏱️ 2. Tempo de atualização}" \
        3 "${MENU_ITEM_3:-🌍 3. Escolher fontes de imagens}" \
        4 "${MENU_ITEM_4:-🔑 4. API Key da NASA (APOD)}" \
        5 "${MENU_ITEM_5:-🚀 5. Instalar/Atualizar Scripts e Timer}" \
        6 "${MENU_ITEM_6:-🎲 6. Mudar imagem AGORA (Baixar nova)}" \
        7 "${MENU_ITEM_7:-🧹 7. Limpar galeria (remover arquivos inválidos)}" \
        8 "${MENU_ITEM_8:-🗑️ 8. Remover WayLume}" \
        9 "${MENU_ITEM_9:-🚪 9. Sair}" \
        --width=460 --height=380 --no-headers --no-cancel)
    CHOICE="${CHOICE%%|*}"   # strip trailing pipe yad may append

    # Exit on window close (X button / Alt+F4) or empty selection
    [ $? -ne 0 ] || [ -z "$CHOICE" ] && break

    case "$CHOICE" in
        1) set_gallery_dir           ;;
        2) set_update_interval       ;;
        3) set_image_sources         ;;
        4) set_apod_api_key          ;;
        5) deploy_services           ;;
        6) fetch_and_apply_wallpaper ;;
        7) clean_gallery             ;;
        8) uninstall                 ;;
        9) break                     ;;
    esac
done

exit 0
