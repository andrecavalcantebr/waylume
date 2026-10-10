# WayLume — Developer Reference

> **For users:** see [README.pt.md](README.pt.md) or [README.en.md](README.en.md).

Technical reference for contributors and maintainers. Covers architecture, key functions, and step-by-step guides for adding sources, settings, and i18n strings.

---

## File structure

```text
waylume/
  src/
    main.sh            (759 lines) — installer, GUI menus, gallery navigation
    fetcher.sh         (257 lines) — skeleton with ##LIB_GALLERY## ##LIB_WALLPAPER## ##SOURCES##
    waylume.svg        ( 22 lines) — SVG application icon (embedded at build time)
    lib/
      gallery.sh       (155 lines) — state persistence + gallery database CRUD
      wallpaper.sh     (215 lines) — image pipeline + per-DE wallpaper dispatch
    sources/
      bing.sh          ( 29 lines) — fetch_bing()
      unsplash.sh      ( 41 lines) — fetch_unsplash()
      apod.sh          ( 50 lines) — fetch_apod()
      wikimedia.sh     ( 56 lines) — fetch_wikimedia()
    i18n/
      pt.sh            (144 lines) — Brazilian Portuguese string bundle
      en.sh            (146 lines) — English string bundle
  build.py             ( 88 lines) — ferramenta de build em Python puro; dois passes
  build.sh             (  3 lines) — shim de compatibilidade: `exec build.py "$@"`
  waylume.sh           (1870 lines) — GENERATED ARTIFACT — never edit directly
  test_multi_de.sh     — smoke tests for multi-DE dispatch (mocks; no DE needed)
  DEVELOPER.md         — this file
  ROADMAP.md           — version history and future plans
  README.md / README.pt.md / README.en.md — user documentation
  LICENSE.md           — GPLv3
```

### Golden rule

**Never edit `waylume.sh` directly. Edit only `src/`.**

After any change to `src/`:

```bash
./build.py --install
```

To validate without installing:

```bash
./build.py && bash -n waylume.sh
```

To run tests:

```bash
bash test_multi_de.sh
```

---

## Build system

`build.py` (pure Python 3) performs **two passes**:

**Pass 1 — expand library placeholders inside `src/fetcher.sh`:**

| Placeholder in `src/fetcher.sh` | Content substituted |
| --- | --- |
| `##LIB_GALLERY##` | `src/lib/gallery.sh` |
| `##LIB_WALLPAPER##` | `src/lib/wallpaper.sh` |
| `##SOURCES##` | `src/sources/bing.sh` + `unsplash.sh` + `apod.sh` + `wikimedia.sh` (blank-line-separated) |

**Pass 2 — embed expanded fetcher + assets into `src/main.sh`:**

| Placeholder in `src/main.sh` | Content substituted |
| --- | --- |
| `##FETCHER_CONTENT##` | expanded fetcher (output of pass 1) |
| `##ICON_CONTENT##` | `src/waylume.svg` |
| `##I18N_PT##` | `src/i18n/pt.sh` |
| `##I18N_EN##` | `src/i18n/en.sh` |

The `##FETCHER_CONTENT##` placeholder lives inside a heredoc in `install_or_update()`. When `waylume --install` runs, the fully expanded fetcher is extracted to `~/.local/bin/waylume-fetch`. The i18n files are extracted the same way to `~/.config/waylume/i18n/`.

`build.py` uses `pathlib.Path`, `argparse`, `subprocess`, and `shutil` — no external dependencies beyond the Python standard library. `build.sh` is a 3-line compatibility shim: `exec build.py "$@"`.

**Requirements:** `python3 ≥ 3.9`. `shellcheck` is optional but checked if present.

---

## Two-process architecture

WayLume runs as two separate processes that communicate through files:

```plaintext
waylume (main.sh)               waylume-fetch (fetcher.sh)
─────────────────               ──────────────────────────
Interactive GUI                 systemd oneshot service
Reads:  waylume.conf            Reads:  waylume.conf
        waylume.state                   waylume.state
Writes: waylume.conf            Writes: waylume.state
                                        DEST_DIR/*.jpg
                                        DEST_DIR/*.jpg.title
        calls waylume-fetch             ~/.cache/waylume/waylume_display.jpg
        for downloads and
        gallery navigation
```

**Persistence files:**

| File | Written by | Contains |
| --- | --- | --- |
| `~/.config/waylume/waylume.conf` | `main.sh` via `save_config` | User settings |
| `~/.config/waylume/waylume.state` | `fetcher.sh` via `save_state` | Download dates + active gallery path |
| `~/.config/waylume/waylume.db` | `fetcher.sh` via `_wl_db_*` | Gallery database (TSV; see below) |
| `~/.cache/waylume/waylume_display.jpg` | `fetcher.sh` via `_wl_make_display_image` | Temp wallpaper with overlay composited |
| `$DEST_DIR/waylume_YYYYMMDD_HHMMSS.jpg` | `fetcher.sh` | Gallery image (clean, no overlay baked in) |
| `$DEST_DIR/waylume_YYYYMMDD_HHMMSS.jpg.title` | `fetcher.sh` | Image title text (sidecar) |

All key=value files are read via `_wl_read_keyval()` — a whitelist parser that prevents code injection by only assigning explicitly listed variable names.

### Gallery database (`waylume.db`)

TSV file, one row per image. Never edited by `main.sh` — only by `waylume-fetch`.

```text
id  filename  title  source  date_iso  status
```

| Field | Values |
| --- | --- |
| `id` | auto-incremented integer |
| `filename` | basename only (`DEST_DIR`-independent) |
| `title` | image caption / attribution (may be empty) |
| `source` | `Bing \| Unsplash \| APOD \| Wikimedia \| Local \| Unknown` |
| `date_iso` | `YYYY-MM-DD` download date |
| `status` | `normal \| favorite \| trash` |

All mutations use atomic write (`.tmp` + `mv`). Reads are plain `awk -F'\t'`.

**Config whitelist (`waylume.conf`):**
`DEST_DIR INTERVAL SOURCES APOD_API_KEY GALLERY_MAX_FILES SHOW_OVERLAY`

**State whitelist (`waylume.state`):**
`APOD_LAST_DATE BING_LAST_DATE UNSPLASH_LAST_DATE WIKIMEDIA_LAST_DATE CURRENT_GALLERY`

---

## `src/main.sh` — GUI and installer

Runs interactively as the `waylume` command. Never runs as a service.

### Boot sequence

1. Define path constants (`CONFIG_DIR`, `BIN_DIR`, `APP_DIR`, etc.)
2. Detect language from `$LANG`; source i18n bundle from `~/.config/waylume/i18n/`
3. Parse CLI flags (`--install`, `--uninstall`, `--help`, `--version`)
4. If running from outside `~/.local/bin`: offer install or update, then exit
5. `check_dependencies()` — installs missing packages via apt/dnf/pacman
6. `load_config()` — reads `waylume.conf` into memory
7. Main menu loop

### Key globals

| Variable | Purpose |
| --- | --- |
| `CONFIG_DIR` | `~/.config/waylume` |
| `BIN_DIR` | `~/.local/bin` |
| `FETCHER_SCRIPT` | `~/.local/bin/waylume-fetch` |
| `CONF_FILE` | `~/.config/waylume/waylume.conf` |
| `DEST_DIR` | Gallery folder (from conf) |
| `INTERVAL` | Fetch interval, e.g. `1h`, `30min` (from conf) |
| `SOURCES` | Comma-separated source list, e.g. `Bing,Unsplash` (from conf) |
| `APOD_API_KEY` | NASA API key (from conf) |
| `GALLERY_MAX_FILES` | Max images to keep; 0 = unlimited (from conf) |
| `SHOW_OVERLAY` | `true`/`false` — show title bar on wallpaper (from conf) |
| `_WL_CONFIG_DIRTY` | `true` when any `set_*` function changed a setting in memory |

### Utility functions

**`_wl_read_keyval FILE KEY1 KEY2 ...`**
Safe `key=value` parser. Reads FILE and assigns only whitelisted keys via `printf -v` — never evals content. Defined independently in both main.sh and fetcher.sh.

**`_zenity ARGS...`**
Thin wrapper over `zenity` that suppresses a known cosmetic GTK4/libadwaita warning. All dialogs go through this.

> **Zenity limitation:** `--file-selection --directory` does **not** accept `--ok-label`/`--cancel-label` (exits 255). Never pass `YAD_BTN_OKC` to file-chooser dialogs; they use native buttons.

**`yad_info / yad_error / yad_question`**
Wrappers over `_zenity` with pre-set button labels from the i18n bundle.

**`run_with_progress MSG CMD ARGS...`**
Shows a zenity progress dialog while running CMD in the background. Animates 0→98% and closes at 100% when the command finishes. Used for slow operations (install, deploy, download).

**`save_config`**
Writes all six config variables to `waylume.conf`. Must only be called from `menu_settings()` after user confirms — never from inside `set_*` functions directly (exception: `set_overlay_toggle`, which writes immediately without service restart).

**`load_config`**
Reads `waylume.conf` via `_wl_read_keyval`, applies defaults for any missing key.

**`deploy_services`**
Extracts fetcher to `~/.local/bin/waylume-fetch`, writes systemd `.service` and `.timer` units, then runs `daemon-reload + enable --now waylume.timer`. Called after `save_config` on settings apply.

**`install_or_update IS_UPDATE`**
Copies the main script, extracts icon and i18n files, writes `.desktop` launcher, calls `deploy_services`. On fresh install, also calls `pin_to_favorites`.

### Main menu

```plaintext
1. Download new image now   → fetch_and_apply_wallpaper()
2. Random image             → go_random_image()
3. Next image               → go_next_image()
4. Previous image           → go_prev_image()
5. Settings                 → menu_settings()
6. Maintenance              → menu_maintenance()
7. Exit
```

The header shows current gallery folder, interval, overlay state, and timer state (updated on each menu open).

### Settings submenu — deferred save pattern

`menu_settings()` sets `_WL_CONFIG_DIRTY=false` on entry. Each `set_*` function updates an in-memory variable and sets `_WL_CONFIG_DIRTY=true` — it does **not** call `save_config`.

When the user exits the submenu, if the flag is true: ask to apply. On yes: `save_config` → `deploy_services`.

**Rule:** `save_config` must never be called inside `set_*` functions.

| Item | Handler | Variable changed |
| --- | --- | --- |
| 1. Gallery folder | `set_gallery_dir` | `DEST_DIR` |
| 2. Update interval | `set_update_interval` | `INTERVAL` |
| 3. Image sources | `set_image_sources` | `SOURCES` |
| 4. NASA API Key | `set_apod_api_key` | `APOD_API_KEY` |
| 5. Gallery limit | `set_gallery_max` | `GALLERY_MAX_FILES` |
| 6. Title overlay (ON/OFF) | `set_overlay_toggle` | `SHOW_OVERLAY` |
| 7. Exit | — | triggers apply prompt if dirty |

### Maintenance submenu

| Item | Handler |
| --- | --- |
| 1. Pause / Resume timer | `toggle_timer` |
| 2. Clean gallery | `clean_gallery` |
| 3. Remove WayLume | `uninstall` |

### Gallery navigation

**`_gallery_navigate(direction)`** — direction is `next`, `prev`, or `random`

1. `find $DEST_DIR -maxdepth 1 -type f ... | sort -z` → sorted array (filenames `waylume_YYYYMMDD_HHMMSS.jpg` → alphabetical = chronological)
2. If `random`: pick a random index
3. Otherwise: call `waylume-fetch --get-current-gallery` to get the active gallery file (returns the original file even when the DE's wallpaper points to the temp overlay file)
4. Linear scan to find index; if not found, start from 0 (`next`) or `COUNT-1` (`prev`)
5. Compute new index: `(IDX ± 1 + COUNT) % COUNT`
6. Apply via `waylume-fetch --set-wallpaper "$TARGET"` — composites overlay and saves state
7. `notify-send` with filename

`go_next_image`, `go_prev_image`, `go_random_image` are one-line wrappers.

`main.sh` never calls `_wl_set_wallpaper` directly — all wallpaper operations go through `waylume-fetch` subprocesses to avoid coupling to `fetcher.sh` internals.

---

## `src/fetcher.sh` — systemd worker

Installed to `~/.local/bin/waylume-fetch`. Runs as a systemd oneshot service and is also invoked by `main.sh` for gallery operations.

### Fetcher startup sequence

1. Export environment for gsettings/notify-send under systemd (`DBUS_SESSION_BUS_ADDRESS`, `XDG_RUNTIME_DIR`, `DISPLAY`)
2. `_wl_read_keyval waylume.conf` — load all config keys
3. `_wl_read_keyval waylume.state` — load dates and `CURRENT_GALLERY`
4. `mkdir -p "$DEST_DIR" "$HOME/.cache/waylume"`
5. Source i18n bundle
6. Parse CLI mode from `$1`

### CLI modes

| Flag | Purpose |
| --- | --- |
| `--random` | Pick a random gallery image and apply it (overlay composited) |
| `--set-wallpaper PATH` | Apply PATH as wallpaper; composite overlay; save state |
| `--get-current-wallpaper` | Print DE's current wallpaper path (may be temp display file) |
| `--get-current-gallery` | Print original gallery file path from `CURRENT_GALLERY` in state |
| *(no flag)* | Download from a configured source and apply |

### Image pipeline (default/download mode)

```text
pick source randomly from $SOURCES
        ↓
fetch_<source>()   — download to $TARGET_PATH; set $IMG_TITLE and $MESSAGE
        ↓
save_state()       — persist download dates (before validate, to avoid API hammering on retry)
        ↓
validate_image()   — reject non-image MIME types (e.g. HTML error pages)
        ↓
process_image()    — resize to screen resolution, center crop (ImageMagick + xrandr)
        ↓
write .title sidecar  — ${TARGET_PATH}.title if IMG_TITLE is non-empty
        ↓
apply_wallpaper()
  └─ _wl_make_display_image()  — composite overlay onto temp file if SHOW_OVERLAY=true
  └─ _wl_set_wallpaper()       — set wallpaper on the current DE
  └─ notify-send
        ↓
save_state()       — persist CURRENT_GALLERY (set by _wl_make_display_image)
        ↓
prune_gallery()    — delete oldest files if count > GALLERY_MAX_FILES
```

### Source functions

Each `fetch_<source>(TARGET)` function must follow this contract:

- Call `_wl_daily_cap "Name" VARNAME_LAST_DATE && return` at the top (auto-rotates local image if already ran today)
- Download image to `$TARGET`
- Set `$IMG_TITLE` (may be empty) and `$MESSAGE`
- Update `SOURCENAME_LAST_DATE="$TODAY"` on success
- Call `_wl_check_timeout $?` after every `curl`

| Function | Source | Daily cap var | Title source |
| --- | --- | --- | --- |
| `fetch_bing` | `bing.biturl.top` API | `BING_LAST_DATE` | `copyright` field in JSON |
| `fetch_unsplash` | `picsum.photos` | `UNSPLASH_LAST_DATE` | Author from `/id/{id}/info` |
| `fetch_apod` | NASA APOD API | `APOD_LAST_DATE` | `title` field; retries up to 8 days back (skips videos) |
| `fetch_wikimedia` | Wikimedia Commons POTD | `WIKIMEDIA_LAST_DATE` | Filename with `File:` prefix and extension stripped |

### Key utility functions

**`_wl_daily_cap(label, VAR_NAME)`**
Returns 0 (true) if `${!VAR_NAME} == $TODAY`. Calls `apply_random_local` first. The caller must `return` immediately after.

**`apply_random_local(label)`**
Picks a random file from `$DEST_DIR` via `shuf -n 1`. Sets `TARGET_PATH`.

**`_wl_check_timeout(exit_code)`**
If exit_code is 28 (curl timeout), notifies the user and exits 1. No-op otherwise.

**`validate_image(TARGET)`**
Uses `file --mime-type` to verify the file is an image. Removes it and exits 1 if not.

**`process_image(TARGET)`**
Uses `xrandr` to detect screen resolution, then `convert` (ImageMagick) to resize and center-crop to fill the screen exactly. Overwrites the original file in-place. Does **not** bake the overlay into the stored file.

**`_wl_make_display_image(TARGET)`**
Sets `CURRENT_GALLERY="$TARGET"` (persisted via `save_state`). If `SHOW_OVERLAY=true` and a `.title` sidecar exists:

- Reads title; truncates to 120 chars; escapes `%` → `%%`; strips C0 control chars (security: prevents ImageMagick format-string injection and control-char misalignment)
- Detects image width with `identify` (ImageMagick)
- Composites a 52px semi-transparent black bar at the top
- Adds "WayLume" in DejaVu-Sans-Bold 15pt (left) and the image title in DejaVu-Sans 24pt (right)
- Writes result to `~/.cache/waylume/waylume_display.jpg`
- Sets `DISPLAY_PATH` to the temp file

If overlay is disabled or no sidecar: `DISPLAY_PATH="$TARGET"`.

---

## `src/lib/gallery.sh` — state and database

Loaded into `fetcher.sh` via `##LIB_GALLERY##`. Never used directly by `main.sh`.

**`save_state()`**
Writes all five state keys (`*_LAST_DATE` + `CURRENT_GALLERY`) atomically to `waylume.state`.

**`_wl_db_init()`**
Calls `_wl_db_migrate()` if `waylume.db` does not yet exist. Called on every fetcher invocation (migration is a no-op on subsequent runs).

**`_wl_db_migrate()`**
One-shot: scans `DEST_DIR` for existing images and populates `waylume.db` from `.title` sidecars. Skips filenames already present. Extracts the date from the `waylume_YYYYMMDD_HHMMSS.jpg` filename pattern.

**`_wl_db_add(filename, title, source, [date_iso])`**
Appends a new row to `waylume.db`. Atomic rewrite.

**`_wl_db_count()`**
Counts non-trash entries.

**`_wl_db_get_by_idx(idx)`**
Returns the 0-based Nth non-trash row as a full TSV line.

**`_wl_db_idx_of(filename)`**
Returns the 0-based position of `filename` among non-trash entries, or `-1` if not found.

**`_wl_db_remove_by_id(id)`**
Deletes the row, the gallery file, and its `.title` sidecar. Atomic rewrite.

**`_wl_db_prune()`**
Deletes oldest `normal` entries until active count ≤ `GALLERY_MAX_FILES`. Always protects the current `CURRENT_GALLERY` file.

**`prune_gallery()`**
Backwards-compatible wrapper for `_wl_db_prune`.

---

## `src/lib/wallpaper.sh` — image pipeline and DE dispatch

Loaded into `fetcher.sh` via `##LIB_WALLPAPER##`.

**`validate_image(TARGET)`**
Uses `file --mime-type` to verify the file is an image. Removes it and exits 1 if not.

**`process_image(TARGET)`**
Uses `xrandr` to detect screen resolution, then `convert` (ImageMagick) to resize and center-crop. Overwrites the original file in-place. Does **not** bake the overlay.

**`_wl_make_display_image(TARGET)`**
Sets `CURRENT_GALLERY="$TARGET"` (persisted via `save_state`). If `SHOW_OVERLAY=true` and a `.title` sidecar exists:

- Reads title; truncates to 120 chars; escapes `%` → `%%`; strips C0 control chars (prevents ImageMagick format-string injection)
- Composites a 52px semi-transparent black bar at the top with brand + title text
- Writes result to `~/.cache/waylume/waylume_display.jpg`; sets `DISPLAY_PATH`

If overlay is disabled or no sidecar: `DISPLAY_PATH="$TARGET"`.

### DE dispatcher pattern

The `case` block for DE detection appears **exactly once** in `_wl_de_name()`. All set/get logic lives in named per-DE functions. Adding a new DE requires two functions and one pattern in `_wl_de_name`.

**`_wl_de_name()`**
Maps `XDG_CURRENT_DESKTOP` to a canonical lowercase name: `gnome | mate | cinnamon | kde | xfce | unknown`.

**`_wl_set_<de>(TARGET)` — per-DE set functions:**

| Function | Command |
| --- | --- |
| `_wl_set_gnome` | `gsettings org.gnome.desktop.background picture-uri` (+ dark variant) |
| `_wl_set_mate` | `gsettings org.mate.background picture-filename` (plain path, no `file://`) |
| `_wl_set_cinnamon` | `gsettings org.cinnamon.desktop.background picture-uri` (+ dark variant) |
| `_wl_set_kde` | `plasma-apply-wallpaperimage` |
| `_wl_set_xfce` | `xfconf-query` on all `/last-image` properties; fallback to first `xrandr` monitor |
| `_wl_set_unknown` | GNOME schema best-effort |

**`_wl_get_<de>()` — per-DE get functions:**
Each returns a plain filesystem path (no `file://`, no quotes). `_wl_get_kde` and `_wl_get_unknown` return empty string.

**`_wl_set_wallpaper(TARGET)`**
Public API: `"_wl_set_$(_wl_de_name)" "$1"`

**`_wl_get_current_wallpaper()`**
Public API: `"_wl_get_$(_wl_de_name)"`

> When overlay is on, returns the temp display file path — use `--get-current-gallery` for navigation.

**`apply_wallpaper(TARGET)`**
Full pipeline: `_wl_make_display_image` → `_wl_set_wallpaper` → `notify-send`.

---

## `src/sources/` — download sources

Loaded into `fetcher.sh` via `##SOURCES##` (concatenation of all four files). Each file contains exactly one `fetch_<name>()` function.

### Source function contract

```bash
fetch_<name>() {
    local TARGET="$1"   # path to write the downloaded image
    # Populates globals:
    IMG_TITLE="..."     # image caption for overlay and db
    MESSAGE="..."       # text for notify-send
    # Utilities provided by fetcher.sh preamble:
    _wl_daily_cap "Label" LABEL_LAST_DATE && return   # rotate local if already ran today
    _wl_check_timeout $?                               # exit on curl timeout (code 28)
    apply_random_local "Label"                         # fallback when download fails
}
```

| File | Function | API |
| --- | --- | --- |
| `bing.sh` | `fetch_bing` | `bing.biturl.top` (unofficial proxy) |
| `unsplash.sh` | `fetch_unsplash` | `picsum.photos/1920/1080.jpg` + `/id/<ID>/info` |
| `apod.sh` | `fetch_apod` | `api.nasa.gov/planetary/apod` — retries up to 8 days back for videos |
| `wikimedia.sh` | `fetch_wikimedia` | `commons.wikimedia.org/w/api.php` — 2-step: template → imageinfo |

The dispatch `case` in `fetcher.sh` MAIN sets `_WL_NEW_DOWNLOAD=true` for the four external sources and calls `_wl_db_add` after a successful download.

---

## i18n system

Language is detected at startup from `$LANG`, reduced to a two-letter code (`pt`, `en`):

```bash
source "$CONFIG_DIR/i18n/${WL_LANG}.sh" 2>/dev/null \
    || source "$CONFIG_DIR/i18n/en.sh" 2>/dev/null || true
```

The i18n files are plain `KEY="value"` shell files. Values can contain `\n` for newlines and `%s`/`%d` for `printf` formatting. Always provide a hardcoded fallback in code:

```bash
yad_info --text="$(printf "${MSG_MY_FEATURE:-Fallback text}" "$value")"
```

To add a new language: copy `src/i18n/en.sh` to `src/i18n/XX.sh`, translate all values, add a `##I18N_XX##` placeholder in `src/main.sh`'s `install_or_update()`, and register it in `build.py`.

---

## How-to guides

### Add a new image source

1. Create `src/sources/mysource.sh` with `fetch_mysource()` following the source contract.

2. Register it in `build.py`: add the path to the `SOURCES` list.

3. Add `MYSOURCE_LAST_DATE=""` to the state variables block in `src/fetcher.sh` and to its `_wl_read_keyval` whitelist call.

4. Add `echo "MYSOURCE_LAST_DATE=\"$MYSOURCE_LAST_DATE\""` to `save_state()` in `src/lib/gallery.sh`.

5. Add `mysource) fetch_mysource "$TARGET_PATH" ; _WL_NEW_DOWNLOAD=true ;;` to the dispatch `case` in `src/fetcher.sh` MAIN.

6. Add `"MySource"` as a checkbox option in `set_image_sources()` in `src/main.sh`.

7. Add i18n strings `MSG_FETCH_SOURCE_MYSOURCE` in both `src/i18n/en.sh` and `src/i18n/pt.sh`.

8. Run `./build.py --install` and add a test case to `test_multi_de.sh`.

### Add a new desktop environment

1. Add `_wl_set_<de>(TARGET)` and `_wl_get_<de>()` functions in `src/lib/wallpaper.sh`.

2. Add the `XDG_CURRENT_DESKTOP` pattern to `_wl_de_name()` mapping to the canonical name.

3. Add a test scenario to `test_multi_de.sh`.

### Add a new user setting

1. Add the variable with a default to the globals block in `src/main.sh`.

2. Add it to `load_config()`'s `_wl_read_keyval` whitelist and set a default for the empty case.

3. Add it to `save_config()`.

4. Write `set_my_setting()`: update the variable, set `_WL_CONFIG_DIRTY=true`. Do not call `save_config`.

5. Add to `menu_settings()` loop with a new case number.

6. If `fetcher.sh` needs it: add to its `_wl_read_keyval` whitelist and add a default fallback.

### Add an i18n string

1. Add the key to `src/i18n/en.sh` and `src/i18n/pt.sh`.

2. Use in code with a hardcoded fallback:

```bash
yad_info --text="${MSG_MY_STRING:-Fallback text}"
# or with printf:
yad_info --text="$(printf "${MSG_MY_STRING:-Text with %s}" "$variable")"
```

---

## Testing

`test_multi_de.sh` mocks `gsettings`, `xfconf-query`, and `plasma-apply-wallpaperimage`, then runs the **assembled fetcher** (extracted from `waylume.sh` via `awk`) to verify multi-DE dispatch for each desktop environment.

> The test uses the assembled fetcher — not `src/fetcher.sh` directly — because `src/fetcher.sh` is now a skeleton with bare placeholders. Always run `./build.py` before running tests.

```bash
./build.py && bash test_multi_de.sh   # expected: 29/29 tests passed
```

To validate the build artifact only:

```bash
./build.py && bash -n waylume.sh && echo "OK"
```
