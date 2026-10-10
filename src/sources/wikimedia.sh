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
