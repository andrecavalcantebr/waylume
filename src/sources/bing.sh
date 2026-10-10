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
