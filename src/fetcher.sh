#!/bin/bash
# WayLume Fetcher - runs via systemd or manually

# Export environment needed for gsettings/notify-send when running via systemd
# Use :- to not override values already set in a graphical session
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DISPLAY="${DISPLAY:-:0}"

source "$HOME/.config/waylume/waylume.conf"
mkdir -p "$DEST_DIR"

STATE_FILE="$HOME/.config/waylume/waylume.state"
TODAY=$(date +%Y-%m-%d)

# Read persisted last-download dates per source
APOD_LAST_DATE=""
BING_LAST_DATE=""
[ -f "$STATE_FILE" ] && source "$STATE_FILE" 2>/dev/null

# Apply a local random wallpaper from the gallery (no download)
apply_random_local() {
    local SOURCE_LABEL="$1"
    TARGET_PATH=$(find "$DEST_DIR" -type f \( -iname "*.jpg" -o -iname "*.png" \) | shuf -n 1)
    if [ -z "$TARGET_PATH" ]; then
        notify-send "WayLume" "Nenhuma imagem encontrada na galeria."
        exit 1
    fi
    MESSAGE="🔄 Galeria local ($SOURCE_LABEL já baixado hoje)"
}

# Mode: pick a random local image from the gallery
if [ "$1" == "--random" ]; then
    apply_random_local "manual"

# Mode: download a new image from the configured sources
else
    IFS=',' read -r -a SOURCE_ARRAY <<< "$SOURCES"
    # Trim any stray whitespace/newlines from each source name
    for i in "${!SOURCE_ARRAY[@]}"; do
        SOURCE_ARRAY[$i]=$(echo "${SOURCE_ARRAY[$i]}" | tr -d '[:space:]')
    done
    SELECTED_SOURCE="${SOURCE_ARRAY[$RANDOM % ${#SOURCE_ARRAY[@]}]}"
    FILE_NAME="waylume_$(date +%Y%m%d_%H%M%S).jpg"
    TARGET_PATH="$DEST_DIR/$FILE_NAME"

    IMG_TITLE=""

    case "$SELECTED_SOURCE" in
        "Bing")
            # Bing has one image per day — rotate locally if already downloaded today
            if [ "$BING_LAST_DATE" = "$TODAY" ]; then
                apply_random_local "Bing"
            else
                BING_JSON=$(curl -sL "https://bing.biturl.top/?resolution=1920&format=js&index=0&mkt=pt-BR")
                BING_URL=$(echo "$BING_JSON" | grep -oP '"url"\s*:\s*"\K[^"]+' 2>/dev/null)
                IMG_TITLE=$(echo "$BING_JSON" | grep -oP '"copyright"\s*:\s*"\K[^"]+' 2>/dev/null)
                if [ -n "$BING_URL" ]; then
                    curl -sL "$BING_URL" -o "$TARGET_PATH"
                    BING_LAST_DATE="$TODAY"
                fi
                MESSAGE="Novo wallpaper baixado via Bing"
            fi
            ;;
        "Unsplash")
            # Unsplash (picsum) returns a random image on every request — always download
            curl -sL "https://picsum.photos/1920/1080.jpg" -o "$TARGET_PATH"
            IMG_TITLE="Unsplash / picsum.photos"
            MESSAGE="Novo wallpaper baixado via Unsplash"
            ;;
        "APOD")
            # APOD has one image per day — rotate locally if already downloaded today
            if [ "$APOD_LAST_DATE" = "$TODAY" ]; then
                apply_random_local "APOD"
            else
                APOD_URL=""
                for DAYS_AGO in 0 1 2 3 4 5 6 7; do
                    APOD_DATE=$(date -d "-${DAYS_AGO} days" +%Y-%m-%d)
                    APOD_JSON=$(curl -sL "https://api.nasa.gov/planetary/apod?api_key=${APOD_API_KEY}&date=${APOD_DATE}")
                    # Detect API errors (rate limit, invalid key, etc.) early to avoid
                    # burning remaining quota on the 8-day retry loop.
                    if echo "$APOD_JSON" | grep -q '"error"'; then
                        ERR_MSG=$(echo "$APOD_JSON" | grep -oP '"message"\s*:\s*"\K[^"]+' 2>/dev/null)
                        notify-send "WayLume ⚠️" "APOD API: $ERR_MSG\nUsando galeria local.\nDica: registre uma API key gratuita em api.nasa.gov"
                        apply_random_local "APOD"
                        # Mark today as handled so we don't hammer the API on every timer tick.
                        # It will retry tomorrow when the date changes.
                        APOD_LAST_DATE="$TODAY"
                        break
                    fi
                    MEDIA_TYPE=$(echo "$APOD_JSON" | grep -oP '"media_type"\s*:\s*"\K[^"]+' 2>/dev/null)
                    if [ "$MEDIA_TYPE" = "image" ]; then
                        # Use regular url (960px) — much faster than hdurl (4K)
                        APOD_URL=$(echo "$APOD_JSON" | grep -oP '"url"\s*:\s*"\K[^"]+' 2>/dev/null)
                        if [ -n "$APOD_URL" ]; then
                            IMG_TITLE=$(echo "$APOD_JSON" | grep -oP '"title"\s*:\s*"\K[^"]+' 2>/dev/null)
                            break
                        fi
                    fi
                done
                if [ -n "$APOD_URL" ]; then
                    curl -sL "$APOD_URL" -o "$TARGET_PATH"
                    APOD_LAST_DATE="$TODAY"
                fi
                MESSAGE="Novo wallpaper baixado via APOD"
            fi
            ;;
    esac

    # Persist updated download dates
    {
        echo "APOD_LAST_DATE=\"$APOD_LAST_DATE\""
        echo "BING_LAST_DATE=\"$BING_LAST_DATE\""
    } > "$STATE_FILE"
fi

# Validate the file is actually an image before applying
if [ -f "$TARGET_PATH" ]; then
    MIME=$(file --mime-type -b "$TARGET_PATH")
    if [[ "$MIME" != image/* ]]; then
        notify-send "WayLume" "⚠️ Download inválido ignorado ($MIME). Tente novamente."
        rm -f "$TARGET_PATH"
        exit 1
    fi
fi

# Overlay title bar on the image using ImageMagick (optional — skipped if not installed)
if [ -n "$IMG_TITLE" ] && [ -f "$TARGET_PATH" ] && command -v convert &>/dev/null; then
    DISPLAY_TITLE="${IMG_TITLE:0:120}"
    W=$(identify -format "%w" "$TARGET_PATH" 2>/dev/null)
    H=$(identify -format "%h" "$TARGET_PATH" 2>/dev/null)
    if [ -n "$W" ] && [ -n "$H" ]; then
        BAR=52
        # Portrait images get cropped at the bottom by GNOME zoom mode.
        # Place the title bar at the TOP for portrait images so it stays visible.
        if [ "$H" -gt "$W" ]; then
            GRAVITY_BAR="North"
            GRAVITY_TXT="NorthWest"
        else
            GRAVITY_BAR="South"
            GRAVITY_TXT="SouthWest"
        fi
        # Create a semi-transparent bar as a separate image and composite it.
        # This is the reliable method for JPEGs that have no native alpha channel.
        convert "$TARGET_PATH" \
            \( -size "${W}x${BAR}" xc:"rgba(0,0,0,0.65)" \) \
            -gravity "$GRAVITY_BAR" -composite \
            -gravity "$GRAVITY_TXT" \
            -fill white \
            -font DejaVu-Sans \
            -pointsize 24 \
            -annotate +20+14 "  ${DISPLAY_TITLE}  " \
            "$TARGET_PATH" 2>/dev/null
    fi
fi

# Apply wallpaper on GNOME (light and dark modes)
if [ -f "$TARGET_PATH" ]; then
    gsettings set org.gnome.desktop.background picture-uri      "file://$TARGET_PATH"
    gsettings set org.gnome.desktop.background picture-uri-dark "file://$TARGET_PATH"
    notify-send "WayLume" "$MESSAGE"
fi
