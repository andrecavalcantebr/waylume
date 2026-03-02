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
DEST_DIR="$HOME/Pictures/WayLume"
INTERVAL="1h"
SOURCES="Unsplash"

# ====================================================
# FUNCTIONS
# ====================================================

# Check and install missing runtime dependencies
check_dependencies() {
    local REQUIRED=("zenity" "curl" "notify-send")
    local MISSING=()

    for cmd in "${REQUIRED[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            MISSING+=("$cmd")
        fi
    done

    if [ ${#MISSING[@]} -eq 0 ]; then
        return 0
    fi

    echo "⚠️ O WayLume precisa de alguns pacotes para funcionar: ${MISSING[*]}"
    echo "Solicitando permissão para instalar..."

    # Map command names to package names where they differ
    local PACKAGES=("${MISSING[@]}")
    for i in "${!PACKAGES[@]}"; do
        [ "${PACKAGES[$i]}" == "notify-send" ] && PACKAGES[$i]="libnotify-bin"
    done

    if command -v apt-get &>/dev/null; then
        sudo apt-get update && sudo apt-get install -y "${PACKAGES[@]}" || exit 1
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y zenity curl libnotify || exit 1
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm zenity curl libnotify || exit 1
    else
        echo "❌ Gerenciador de pacotes não reconhecido."
        echo "Por favor, instale manualmente: ${MISSING[*]}"
        exit 1
    fi

    echo "✅ Dependências instaladas com sucesso!"
}

# Persist current config to disk
save_config() {
    {
        echo "DEST_DIR=\"$DEST_DIR\""
        echo "INTERVAL=\"$INTERVAL\""
        echo "SOURCES=\"$SOURCES\""
    } > "$CONF_FILE"
}

# Load config from disk, applying defaults for missing keys
load_config() {
    source "$CONF_FILE" 2>/dev/null
    [ -z "$DEST_DIR" ] && DEST_DIR="$HOME/Pictures/WayLume"
    [ -z "$INTERVAL" ] && INTERVAL="1h"
    [ -z "$SOURCES" ]  && SOURCES="Unsplash"
}

# Write the wallpaper fetcher worker script and activate the systemd timer
deploy_services() {
    mkdir -p "$DEST_DIR"

    # Generate the worker script (waylume-fetch)
    cat << 'EOF' > "$FETCHER_SCRIPT"
#!/bin/bash
# WayLume Fetcher - runs via systemd or manually
source "$HOME/.config/waylume/waylume.conf"
mkdir -p "$DEST_DIR"

# Mode: pick a random local image from the gallery
if [ "$1" == "--random" ]; then
    TARGET_PATH=$(find "$DEST_DIR" -type f \( -iname "*.jpg" -o -iname "*.png" \) | shuf -n 1)
    if [ -z "$TARGET_PATH" ]; then
        notify-send "WayLume" "Nenhuma imagem encontrada na galeria."
        exit 1
    fi
    MESSAGE="Wallpaper alterado da galeria local."

# Mode: download a new image from the configured sources
else
    IFS=',' read -r -a SOURCE_ARRAY <<< "$SOURCES"
    SELECTED_SOURCE="${SOURCE_ARRAY[$RANDOM % ${#SOURCE_ARRAY[@]}]}"
    FILE_NAME="waylume_$(date +%Y%m%d_%H%M%S).jpg"
    TARGET_PATH="$DEST_DIR/$FILE_NAME"

    case "$SELECTED_SOURCE" in
        "Bing")
            curl -sL "https://bing.biturl.top/?resolution=1920&format=image&index=0&mkt=pt-BR" -o "$TARGET_PATH"
            ;;
        "Unsplash")
            curl -sL "https://picsum.photos/1920/1080.jpg" -o "$TARGET_PATH"
            ;;
        "APOD")
            APOD_JSON=$(curl -sL "https://api.nasa.gov/planetary/apod?api_key=DEMO_KEY")
            APOD_URL=$(echo "$APOD_JSON" | grep -oP '"hdurl"\s*:\s*"\K[^"]+' 2>/dev/null)
            [ -z "$APOD_URL" ] && APOD_URL=$(echo "$APOD_JSON" | grep -oP '"url"\s*:\s*"\K[^"]+' 2>/dev/null)
            [ -n "$APOD_URL" ] && curl -sL "$APOD_URL" -o "$TARGET_PATH"
            ;;
    esac
    MESSAGE="Novo wallpaper baixado via $SELECTED_SOURCE"
fi

# Apply wallpaper on GNOME (light and dark modes)
if [ -f "$TARGET_PATH" ]; then
    gsettings set org.gnome.desktop.background picture-uri      "file://$TARGET_PATH"
    gsettings set org.gnome.desktop.background picture-uri-dark "file://$TARGET_PATH"
    notify-send "WayLume" "$MESSAGE"
fi
EOF
    chmod +x "$FETCHER_SCRIPT"

    # Generate systemd service unit
    cat << EOF > "$SYSTEMD_DIR/waylume.service"
[Unit]
Description=WayLume Wallpaper Fetcher
After=network-online.target

[Service]
Type=oneshot
ExecStart=$FETCHER_SCRIPT
EOF

    # Generate systemd timer unit
    cat << EOF > "$SYSTEMD_DIR/waylume.timer"
[Unit]
Description=WayLume Wallpaper Timer

[Timer]
OnUnitActiveSec=$INTERVAL
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now waylume.timer

    zenity --info --title="WayLume" \
        --text="Scripts gerados e Timer ativado!\nO sistema rodará a cada $INTERVAL."
}

# Install or update WayLume into ~/.local
install_or_update() {
    local SOURCE_DIR="$1"
    local IS_UPDATE="$2"

    mkdir -p "$CONFIG_DIR" "$BIN_DIR" "$APP_DIR" "$ICON_DIR" "$SYSTEMD_DIR"

    # Copy the main script
    cp "$0" "$INSTALL_TARGET"
    chmod +x "$INSTALL_TARGET"

    # Copy the icon
    if [ -f "$SOURCE_DIR/waylume.svg" ]; then
        cp "$SOURCE_DIR/waylume.svg" "$ICON_DIR/waylume.svg"
    fi

    # Create default config only on fresh installs
    if [ ! -f "$CONF_FILE" ]; then
        save_config
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
        zenity --info --title="WayLume" \
            --text="Atualizado com sucesso!\nScripts e timer foram atualizados.\nSuas configurações foram preservadas."
    else
        zenity --info --title="WayLume" \
            --text="Instalado com sucesso!\nAbra o WayLume pelo menu de aplicativos do seu sistema."
    fi
}

# Remove all WayLume files from the system (keeps the photo gallery)
uninstall() {
    zenity --question --title="Aviso" \
        --text="Deseja realmente remover o WayLume do sistema?\nSua galeria de fotos NÃO será apagada."
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
        zenity --info --text="WayLume desinstalado completamente."
        exit 0
    fi
}

# GUI: choose the wallpaper gallery directory
set_gallery_dir() {
    local NEW_DIR
    NEW_DIR=$(zenity --file-selection --directory \
        --title="Escolha a pasta da Galeria" --filename="$DEST_DIR/")
    if [ -n "$NEW_DIR" ]; then
        DEST_DIR="$NEW_DIR"
        save_config
        zenity --info --text="Galeria alterada para:\n$DEST_DIR\n\nLembre-se de clicar em 'Instalar/Atualizar Scripts' para aplicar."
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
    UNIT=$(zenity --list --radiolist --title="Tempo de Atualização" \
        --text="Unidade de tempo:" \
        --column="X" --column="Unidade" --column="Valor" \
        $MIN_SEL "Minutos" "min" \
        $H_SEL   "Horas"   "h"  \
        --print-column=3 --hide-column=3 \
        --width=320 --height=280)

    [ -z "$UNIT" ] && return

    # Step 2: choose value with a slider (1–60)
    local LABEL="minutos"
    [ "$UNIT" = "h" ] && LABEL="horas"

    local VALUE
    VALUE=$(zenity --scale --title="Tempo de Atualização" \
        --text="Intervalo em $LABEL:" \
        --min-value=1 --max-value=60 --step=1 \
        --value="$CUR_VALUE")

    [ -z "$VALUE" ] && return

    INTERVAL="${VALUE}${UNIT}"
    save_config
    zenity --info --text="Tempo alterado para $INTERVAL.\nLembre-se de clicar em 'Instalar/Atualizar Scripts' para aplicar."
}

# GUI: choose which image sources to use
set_image_sources() {
    local BING=FALSE UNSPLASH=FALSE APOD=FALSE
    [[ "$SOURCES" == *"Bing"* ]]     && BING=TRUE
    [[ "$SOURCES" == *"Unsplash"* ]] && UNSPLASH=TRUE
    [[ "$SOURCES" == *"APOD"* ]]     && APOD=TRUE

    local NEW_SOURCES
    NEW_SOURCES=$(zenity --list --checklist --title="Fontes de Imagens" \
        --text="Escolha de onde baixar as imagens novas:" \
        --column="Ativo" --column="Fonte" \
        $BING "Bing" $UNSPLASH "Unsplash" $APOD "APOD" \
        --separator=",")

    if [ -n "$NEW_SOURCES" ]; then
        SOURCES="$NEW_SOURCES"
        save_config
        zenity --info --text="Fontes alteradas.\nLembre-se de clicar em 'Instalar/Atualizar Scripts' para aplicar."
    fi
}

# Apply a random wallpaper from the local gallery immediately
fetch_and_apply_wallpaper() {
    if [ ! -f "$FETCHER_SCRIPT" ]; then
        zenity --error \
            --text="Os scripts ainda não foram gerados.\nClique em 'Instalar/Atualizar Scripts' primeiro."
        return
    fi
    # Run without --random: downloads a fresh image from the configured sources
    "$FETCHER_SCRIPT"
}

# ====================================================
# BOOTSTRAP
# ====================================================

check_dependencies

# Auto-install / update when running from outside ~/.local/bin
if [ "$(realpath "$0")" != "$(realpath "$INSTALL_TARGET")" ]; then
    SOURCE_DIR="$(dirname "$(realpath "$0")")"

    if [ -f "$INSTALL_TARGET" ]; then
        zenity --question --title="WayLume Atualização" \
            --text="O WayLume já está instalado.\nDeseja atualizar para a versão desta pasta?\n\nSuas configurações serão preservadas."
        [ $? -eq 0 ] && install_or_update "$SOURCE_DIR" true
    else
        zenity --question --title="WayLume Instalação" \
            --text="O WayLume não está instalado no sistema.\nDeseja instalar agora na sua pasta de usuário (~/.local/bin)?"
        [ $? -eq 0 ] && install_or_update "$SOURCE_DIR" false
    fi

    exit 0
fi

# ====================================================
# MAIN — load config and show the settings menu
# ====================================================

load_config

while true; do
    CHOICE=$(zenity --list --title="WayLume - Configuração" \
        --text="Gerenciador de Wallpapers para GNOME\nGaleria Atual: $DEST_DIR\nAtualização: $INTERVAL" \
        --column="Opção" --column="Ação" --hide-column=1 \
        1 "📂 1. Escolher pasta da galeria" \
        2 "⏱️ 2. Tempo de atualização" \
        3 "🌍 3. Escolher fontes de imagens" \
        4 "🚀 4. Instalar/Atualizar Scripts e Timer" \
        5 "🎲 5. Mudar imagem AGORA (Baixar nova)" \
        6 "🗑️ 6. Remover WayLume" \
        7 "🚪 7. Sair" \
        --width=500 --height=500)

    # Exit when user closes the window, clicks Cancel, or chooses Sair
    [ $? -ne 0 ] && break

    case "$CHOICE" in
        1) set_gallery_dir           ;;
        2) set_update_interval       ;;
        3) set_image_sources         ;;
        4) deploy_services           ;;
        5) fetch_and_apply_wallpaper ;;
        6) uninstall                 ;;
        7) break                     ;;
    esac
done
