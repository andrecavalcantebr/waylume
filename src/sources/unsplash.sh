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
