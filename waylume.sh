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

source "$HOME/.config/waylume/waylume.conf"
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
[ -f "$STATE_FILE" ] && source "$STATE_FILE" 2>/dev/null

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
        notify-send "WayLume" "${MSG_FETCH_NO_IMAGES:-Nenhuma imagem encontrada na galeria.}"
        exit 0   # handled — timer will retry later
    fi
    MESSAGE="$(printf "${MSG_FETCH_LOCAL:-🔄 Galeria local (%s já baixado hoje)}" "$LABEL")"
}

# Persist updated download dates to state file.
save_state() {
    {
        echo "APOD_LAST_DATE=\"$APOD_LAST_DATE\""
        echo "BING_LAST_DATE=\"$BING_LAST_DATE\""
    } > "$STATE_FILE"
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
    JSON=$(curl -sL "https://bing.biturl.top/?resolution=1920&format=js&index=0&mkt=pt-BR")
    URL=$(echo "$JSON"       | grep -oP '"url"\s*:\s*"\K[^"]+' 2>/dev/null)
    IMG_TITLE=$(echo "$JSON" | grep -oP '"copyright"\s*:\s*"\K[^"]+' 2>/dev/null)

    if [ -n "$URL" ]; then
        curl -sL "$URL" -o "$TARGET"
        BING_LAST_DATE="$TODAY"
    fi
    MESSAGE="${MSG_FETCH_SOURCE_BING:-Novo wallpaper baixado via Bing}"
}

fetch_unsplash() {
    local TARGET="$1"

    # Unsplash (picsum) returns a different random image on every request — always download.
    curl -sL "https://picsum.photos/1920/1080.jpg" -o "$TARGET"
    IMG_TITLE="Unsplash / picsum.photos"
    MESSAGE="${MSG_FETCH_SOURCE_UNSPLASH:-Novo wallpaper baixado via Unsplash}"
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
            notify-send "WayLume ⚠️" "$(printf "${MSG_FETCH_APOD_ERROR:-APOD API: %s\nUsando galeria local.\nDica: registre uma API key gratuita em api.nasa.gov}" "$ERR_MSG")"
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
    MESSAGE="${MSG_FETCH_SOURCE_APOD:-Novo wallpaper baixado via APOD}"
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
        notify-send "WayLume" "$(printf "${MSG_FETCH_INVALID_MIME:-⚠️ Download inválido ignorado (%s). Tente novamente.}" "$MIME")"
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
        # Resize → crop → composite bar → título (NE) → brand text (NW): um pass só.
        convert "$TARGET" \
            -resize "${SCREEN_W}x${SCREEN_H}^" \
            -gravity Center \
            -extent "${SCREEN_W}x${SCREEN_H}" \
            \( -size "${SCREEN_W}x${BAR}" xc:"rgba(0,0,0,0.65)" \) \
            -gravity North -composite \
            -font DejaVu-Sans-Bold -pointsize 16 \
            -fill white -gravity NorthWest -annotate +14+17 "WayLume" \
            -font DejaVu-Sans -pointsize 13 \
            -fill "#bbbbbb" -gravity NorthWest -annotate +14+35 "is.gd/48OrTP" \
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

    # Dispatch to the matching fetch function (Bing→fetch_bing, etc.).
    "fetch_${SELECTED_SOURCE,,}" "$TARGET_PATH"
fi

save_state

validate_image  "$TARGET_PATH"
process_image   "$TARGET_PATH"
apply_wallpaper "$TARGET_PATH"
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
MSG_GALLERY_CHANGED="Galeria alterada para:\n%s\n\nLembre-se de clicar em 'Instalar/Atualizar Scripts' para aplicar."

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
MSG_INTERVAL_CHANGED="Tempo alterado para %s.\nLembre-se de clicar em 'Instalar/Atualizar Scripts' para aplicar."

# ── set_image_sources ─────────────────────────────────────────────────────────
TITLE_SOURCES="Fontes de Imagens"
MSG_SOURCES_PICK="Escolha de onde baixar as imagens novas:"
COL_SOURCES_NAME="Fonte"
MSG_SOURCES_CHANGED="Fontes alteradas.\nLembre-se de clicar em 'Instalar/Atualizar Scripts' para aplicar."

# ── set_apod_api_key ──────────────────────────────────────────────────────────
TITLE_APOD_KEY="WayLume - NASA API Key"
MSG_APOD_KEY_DEMO="(usando DEMO_KEY — gere a sua em api.nasa.gov, é grátis!)"
MSG_APOD_KEY_SET="(chave configurada: %s...)"   # %s = primeiros 6 chars
MSG_APOD_KEY_PROMPT="Informe sua API Key da NASA APOD:\n%s"   # %s = MSG_APOD_KEY_*
MSG_APOD_KEY_SAVED="API Key salva!\nLembre-se de clicar em 'Instalar/Atualizar Scripts' para aplicar."

# ── clean_gallery ─────────────────────────────────────────────────────────────
MSG_GALLERY_CLEAN_OK="Nenhum arquivo inválido encontrado na galeria. ✅"
TITLE_GALLERY_CLEAN="WayLume - Limpar Galeria"
MSG_GALLERY_CLEAN_CONFIRM="Encontrados %d arquivo(s) corrompido(s):\n%s\n\nDeseja removê-los?"
MSG_GALLERY_CLEAN_DONE="%d arquivo(s) removido(s) da galeria."

# ── fetch_and_apply_wallpaper ─────────────────────────────────────────────────
MSG_FETCH_NO_SCRIPTS="Os scripts ainda não foram gerados.\nClique em 'Instalar/Atualizar Scripts' primeiro."
MSG_FETCH_PROGRESS="Baixando e aplicando novo wallpaper..."
MSG_FETCH_DONE="Wallpaper aplicado com sucesso! 🎉"

# ── bootstrap (auto-install / update prompt) ──────────────────────────────────
TITLE_UPDATE_PROMPT="WayLume Atualização"
MSG_UPDATE_PROMPT="O WayLume já está instalado.\nDeseja atualizar para a versão desta pasta?\n\nSuas configurações serão preservadas."
TITLE_INSTALL_PROMPT="WayLume Instalação"
MSG_INSTALL_PROMPT="O WayLume não está instalado no sistema.\nDeseja instalar agora na sua pasta de usuário (~/.local/bin)?"

# ── main menu ─────────────────────────────────────────────────────────────────
TITLE_MENU="WayLume - Menu"
MSG_MENU_HEADER="Gerenciador de Wallpapers para GNOME\nGaleria Atual: %s\nAtualização: %s"
COL_MENU_OPTION="Opção"
COL_MENU_ACTION="Ação"
MENU_ITEM_1="📂 1. Escolher pasta da galeria"
MENU_ITEM_2="⏱️ 2. Tempo de atualização"
MENU_ITEM_3="🌍 3. Escolher fontes de imagens"
MENU_ITEM_4="🔑 4. API Key da NASA (APOD)"
MENU_ITEM_5="🚀 5. Instalar/Atualizar Scripts e Timer"
MENU_ITEM_6="🎲 6. Mudar imagem AGORA (Baixar nova)"
MENU_ITEM_7="🧹 7. Limpar galeria (remover arquivos inválidos)"
MENU_ITEM_8="🗑️ 8. Remover WayLume"
MENU_ITEM_9="🚪 9. Sair"

# ── fetcher: mensagens de notify-send ────────────────────────────────────────
MSG_FETCH_NO_IMAGES="Nenhuma imagem encontrada na galeria."
MSG_FETCH_APOD_ERROR="APOD API: %s\nUsando galeria local.\nDica: registre uma API key gratuita em api.nasa.gov"
MSG_FETCH_INVALID_MIME="⚠️ Download inválido ignorado (%s). Tente novamente."
MSG_FETCH_LOCAL="🔄 Galeria local (%s já baixado hoje)"
MSG_FETCH_SOURCE_BING="Novo wallpaper baixado via Bing"
MSG_FETCH_SOURCE_UNSPLASH="Novo wallpaper baixado via Unsplash"
MSG_FETCH_SOURCE_APOD="Novo wallpaper baixado via APOD"
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
MSG_GALLERY_CHANGED="Gallery changed to:\n%s\n\nRemember to click 'Install/Update Scripts' to apply."

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
MSG_INTERVAL_CHANGED="Interval changed to %s.\nRemember to click 'Install/Update Scripts' to apply."

# ── set_image_sources ─────────────────────────────────────────────────────────
TITLE_SOURCES="Image Sources"
MSG_SOURCES_PICK="Choose where to download new images from:"
COL_SOURCES_NAME="Source"
MSG_SOURCES_CHANGED="Sources changed.\nRemember to click 'Install/Update Scripts' to apply."

# ── set_apod_api_key ──────────────────────────────────────────────────────────
TITLE_APOD_KEY="WayLume - NASA API Key"
MSG_APOD_KEY_DEMO="(using DEMO_KEY — get yours at api.nasa.gov, it's free!)"
MSG_APOD_KEY_SET="(key configured: %s...)"   # %s = first 6 chars
MSG_APOD_KEY_PROMPT="Enter your NASA APOD API Key:\n%s"   # %s = MSG_APOD_KEY_*
MSG_APOD_KEY_SAVED="API Key saved!\nRemember to click 'Install/Update Scripts' to apply."

# ── clean_gallery ─────────────────────────────────────────────────────────────
MSG_GALLERY_CLEAN_OK="No invalid files found in the gallery. ✅"
TITLE_GALLERY_CLEAN="WayLume - Clean Gallery"
MSG_GALLERY_CLEAN_CONFIRM="Found %d corrupted file(s):\n%s\n\nDo you want to remove them?"
MSG_GALLERY_CLEAN_DONE="%d file(s) removed from the gallery."

# ── fetch_and_apply_wallpaper ─────────────────────────────────────────────────
MSG_FETCH_NO_SCRIPTS="Scripts have not been generated yet.\nClick 'Install/Update Scripts' first."
MSG_FETCH_PROGRESS="Downloading and applying new wallpaper..."
MSG_FETCH_DONE="Wallpaper applied successfully! 🎉"

# ── bootstrap (auto-install / update prompt) ──────────────────────────────────
TITLE_UPDATE_PROMPT="WayLume Update"
MSG_UPDATE_PROMPT="WayLume is already installed.\nDo you want to update to the version in this folder?\n\nYour settings will be preserved."
TITLE_INSTALL_PROMPT="WayLume Installation"
MSG_INSTALL_PROMPT="WayLume is not installed on this system.\nDo you want to install it now to your user folder (~/.local/bin)?"

# ── main menu ─────────────────────────────────────────────────────────────────
TITLE_MENU="WayLume - Menu"
MSG_MENU_HEADER="Wallpaper Manager for GNOME\nCurrent Gallery: %s\nUpdate Interval: %s"
COL_MENU_OPTION="Option"
COL_MENU_ACTION="Action"
MENU_ITEM_1="📂 1. Choose gallery folder"
MENU_ITEM_2="⏱️ 2. Update interval"
MENU_ITEM_3="🌍 3. Choose image sources"
MENU_ITEM_4="🔑 4. NASA API Key (APOD)"
MENU_ITEM_5="🚀 5. Install/Update Scripts and Timer"
MENU_ITEM_6="🎲 6. Change image NOW (Download new)"
MENU_ITEM_7="🧹 7. Clean gallery (remove invalid files)"
MENU_ITEM_8="🗑️ 8. Remove WayLume"
MENU_ITEM_9="🚪 9. Exit"

# ── fetcher: notify-send messages ─────────────────────────────────────────────
MSG_FETCH_NO_IMAGES="No images found in the gallery."
MSG_FETCH_APOD_ERROR="APOD API: %s\nUsing local gallery.\nTip: register a free API key at api.nasa.gov"
MSG_FETCH_INVALID_MIME="⚠️ Invalid download ignored (%s). Please try again."
MSG_FETCH_LOCAL="🔄 Local gallery (%s already downloaded today)"
MSG_FETCH_SOURCE_BING="New wallpaper downloaded via Bing"
MSG_FETCH_SOURCE_UNSPLASH="New wallpaper downloaded via Unsplash"
MSG_FETCH_SOURCE_APOD="New wallpaper downloaded via APOD"
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
