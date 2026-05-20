# WayLume — Developer Reference

> **For users:** see [README.pt.md](README.pt.md) or [README.en.md](README.en.md).

Technical reference for contributors and maintainers. Covers architecture, key functions, and step-by-step guides for adding sources, settings, and i18n strings.

---

## File structure

```plaitext
waylume/
  src/
    main.sh          (~793 lines) — installer, GUI menus, gallery navigation
    fetcher.sh       (~570 lines) — systemd oneshot worker: download, process, apply
    waylume.svg      (  22 lines) — SVG application icon (embedded at build time)
    i18n/
      pt.sh          (~142 lines) — Brazilian Portuguese string bundle
      en.sh          (~144 lines) — English string bundle
  build.sh           (  50 lines) — build tool: embeds src/* into waylume.sh via Python 3
  waylume.sh         (~1671 lines) — GENERATED ARTIFACT — never edit directly
  test_multi_de.sh   — smoke tests for multi-DE dispatch (mocks; no DE needed)
  DEVELOPER.md       — this file
  ROADMAP.md         — version history and future plans
  README.md / README.pt.md / README.en.md — user documentation
  LICENSE.md         — GPLv3
```

### Golden rule

**Never edit `waylume.sh` directly. Edit only `src/`.**

After any change to `src/`:

```bash
./build.sh --install
```

To validate without installing:

```bash
./build.sh && bash -n waylume.sh
```

To run tests:

```bash
bash test_multi_de.sh
```

---

## Build system

`build.sh` embeds four source files into `waylume.sh` by replacing placeholder strings inside `src/main.sh`. The substitution is done by an embedded Python 3 script.

| Placeholder in `src/main.sh` | File embedded |
| --- | --- |
| `##FETCHER_CONTENT##` | `src/fetcher.sh` |
| `##ICON_CONTENT##` | `src/waylume.svg` |
| `##I18N_PT##` | `src/i18n/pt.sh` |
| `##I18N_EN##` | `src/i18n/en.sh` |

The `##FETCHER_CONTENT##` placeholder lives inside a heredoc in `install_or_update()`. When `waylume --install` runs, fetcher.sh is extracted to `~/.local/bin/waylume-fetch`. The i18n files are extracted the same way to `~/.config/waylume/i18n/`.

**Requirements:** `bash`, `python3`. `shellcheck` is optional but checked if present.

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
| `~/.cache/waylume/waylume_display.jpg` | `fetcher.sh` via `_wl_make_display_image` | Temp wallpaper with overlay composited |
| `$DEST_DIR/waylume_YYYYMMDD_HHMMSS.jpg` | `fetcher.sh` | Gallery image (clean, no overlay baked in) |
| `$DEST_DIR/waylume_YYYYMMDD_HHMMSS.jpg.title` | `fetcher.sh` | Image title text (sidecar) |

Both config files are read via `_wl_read_keyval()` — a whitelist parser that prevents code injection by only assigning explicitly listed variable names.

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
Writes all six config variables to `waylume.conf`. Must only be called from `menu_settings()` after user confirms — never from inside `set_*` functions directly.

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

**`_wl_set_wallpaper(TARGET)`**
Dispatches to the correct wallpaper command for the current DE:

| `XDG_CURRENT_DESKTOP` | Command |
| --- | --- |
| `GNOME`, `ubuntu:GNOME` | `gsettings set org.gnome.desktop.background picture-uri` (+ dark variant) |
| `MATE` | `gsettings set org.mate.background picture-filename` (plain path, no `file://`) |
| `X-Cinnamon` | `gsettings set org.cinnamon.desktop.background picture-uri` (+ dark variant) |
| `KDE` | `plasma-apply-wallpaperimage` |
| `XFCE` | `xfconf-query` on all `/last-image` properties (auto-detects all monitors) |
| *(unknown)* | GNOME schema best-effort |

**`_wl_get_current_wallpaper`**
Returns the active wallpaper path from the DE. Returns empty string for KDE (no CLI read-back). When overlay is on, this returns the temp display file path — use `--get-current-gallery` instead for navigation.

**`apply_wallpaper(TARGET)`**
Calls `_wl_make_display_image` → `_wl_set_wallpaper` → `notify-send`.

**`save_state`**
Writes all five state keys (`*_LAST_DATE` + `CURRENT_GALLERY`) to `waylume.state`.

**`prune_gallery`**
Deletes oldest gallery files until count ≤ `GALLERY_MAX_FILES`. Uses `CURRENT_GALLERY` (from state) to protect the active image. Also deletes the `.title` sidecar alongside the image.

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

To add a new language: copy `src/i18n/en.sh` to `src/i18n/XX.sh`, translate all values, add a `##I18N_XX##` placeholder in `src/main.sh`'s `install_or_update()`, and register it in `build.sh`.

---

## How-to guides

### Add a new image source

1. Add `fetch_mysource()` in `src/fetcher.sh` following the source contract above.

2. Add `MYSOURCE_LAST_DATE=""` to the state variables block and to the `_wl_read_keyval` whitelist call.

3. Add `echo "MYSOURCE_LAST_DATE=\"$MYSOURCE_LAST_DATE\""` to `save_state()`.

4. Add `mysource) fetch_mysource "$TARGET_PATH" ;;` to the dispatch `case` in the main flow.

5. Add `"MySource"` as a checkbox option in `set_image_sources()` in `src/main.sh`.

6. Add i18n strings `MSG_FETCH_SOURCE_MYSOURCE` in both `src/i18n/en.sh` and `src/i18n/pt.sh`.

7. Run `./build.sh --install` and add a test case to `test_multi_de.sh`.

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

`test_multi_de.sh` mocks `gsettings`, `xfconf-query`, and `plasma-apply-wallpaperimage`, then sources `fetcher.sh` to verify multi-DE dispatch for each desktop environment.

```bash
bash test_multi_de.sh    # expected: 29/29 tests passed
```

To validate the build artifact only:

```bash
./build.sh && bash -n waylume.sh && echo "OK"
```
