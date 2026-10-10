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
