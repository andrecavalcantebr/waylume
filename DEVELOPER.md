# WayLume — Developer Reference

> **For users:** see [README.pt.md](README.pt.md) or [README.en.md](README.en.md).

This document is the technical reference for contributors and maintainers. It covers architecture, build system, i18n, coding conventions, and step-by-step guides for extending the project.

---

## File structure

```text
waylume/
  src/
    main.sh       (741 lines) — installer + yad GUI + menu logic
    fetcher.sh    (523 lines) — systemd oneshot worker: download, overlay, apply; multi-DE helpers
    waylume.svg   ( 22 lines) — SVG application icon
    i18n/
      pt.sh       (133 lines) — Brazilian Portuguese string bundle
      en.sh       (135 lines) — English string bundle
  build.sh        ( 50 lines) — build tool: embeds src/* into waylume.sh via Python 3
  waylume.sh      (1554 lines) — GENERATED ARTIFACT — never edit directly
  test_multi_de.sh — smoke tests for multi-DE dispatch (mocks; no DE installation required)
  DEVELOPER.md    — this file
  CHECKPOINT.md   — session notes and current development context
  README.md       — language hub
  README.pt.md    — user documentation (Portuguese)
  README.en.md    — user documentation (English)
  LICENSE.md      — GPLv3 (authoritative)
  LICENSE.pt.md   — GPLv3 informational summary (Portuguese)
```

### Golden rule

**Edit only `src/`. Never edit `waylume.sh` directly.**

After any change:

```bash
./build.sh --install
```

---

## Build system

`build.sh` uses an embedded Python 3 script to perform literal string substitution on four placeholders inside `src/main.sh`:

| Placeholder in `src/main.sh` | File embedded |
| --- | --- |
| `##FETCHER_CONTENT##` | `src/fetcher.sh` |
| `##ICON_CONTENT##` | `src/waylume.svg` |
| `##I18N_PT##` | `src/i18n/pt.sh` |
| `##I18N_EN##` | `src/i18n/en.sh` |

The `##I18N_*##` placeholders live inside heredocs in `install_or_update()`:

```bash
cat << 'WL_I18N_PT' > "$CONFIG_DIR/i18n/pt.sh"
##I18N_PT##
WL_I18N_PT
```

Python substitutes the placeholder before the heredoc reaches the shell, so the correct string bundle is embedded verbatim. Result: `waylume.sh` extracts the i18n files to `~/.config/waylume/i18n/` on every `--install` run.

After substitution, `build.sh` optionally runs `shellcheck -S warning` on the output.

**Requirements:** `bash`, `python3`. `shellcheck` optional but recommended.

---

## Runtime architecture

### main.sh — GUI + installer

Runs interactively, called as `waylume` from the application menu (or CLI).

**Boot sequence:**

1. Detect language from `$LANG`, source i18n bundle
2. Parse CLI flags (`--install`, `--uninstall`, `--help`)
3. Check if running from install path; if not, offer install/update
4. `check_dependencies()` — installs missing packages via apt/dnf/pacman
5. `load_config()` — reads `~/.config/waylume/waylume.conf`
6. Main menu loop

**Key globals:**

| Variable | Purpose |
| --- | --- |
| `CONFIG_DIR`, `BIN_DIR`, `APP_DIR`, `ICON_DIR`, `SYSTEMD_DIR` | XDG-compliant install paths |
| `DEST_DIR`, `INTERVAL`, `SOURCES`, `APOD_API_KEY`, `GALLERY_MAX_FILES`, `SHOW_OVERLAY` | Runtime config (loaded from `.conf`) |
| `YAD_BASE` | Common yad options `--class=WayLume --window-icon=...` applied to every dialog |
| `YAD_BTN_OK`, `YAD_BTN_YN`, `YAD_BTN_OKC` | Button label presets (from i18n) |
| `_WL_CONFIG_DIRTY` | Dirty flag for deferred save pattern (see below) |

### fetcher.sh — systemd worker

Runs as a systemd oneshot service (`waylume.service`) on each timer tick.
Can also be tested standalone: `bash src/fetcher.sh`

**Execution flow:**

1. Set environment (`DBUS_SESSION_BUS_ADDRESS`, `XDG_RUNTIME_DIR`, `DISPLAY`)
2. `_wl_read_keyval()` parses `waylume.conf` (whitelist: `DEST_DIR INTERVAL SOURCES APOD_API_KEY GALLERY_MAX_FILES SHOW_OVERLAY`); source i18n bundle
3. `_wl_read_keyval()` parses `waylume.state` (whitelist: `APOD_LAST_DATE BING_LAST_DATE UNSPLASH_LAST_DATE WIKIMEDIA_LAST_DATE`)
4. If `--random`: call `apply_random_local` and exit
5. If `--set-wallpaper <path>`: call `_wl_set_wallpaper` and exit (used by the main GUI for gallery navigation)
6. If `--get-current-wallpaper`: call `_wl_get_current_wallpaper` and exit (used by main GUI)
7. Otherwise: pick a random source from `$SOURCES`, call `fetch_<source>()`
8. `save_state()` — persist updated dates
9. `prune_gallery()` — remove oldest files if count exceeds `GALLERY_MAX_FILES`
10. `validate_image()` — reject non-image MIME types
11. `process_image()` — resize, crop; if `SHOW_OVERLAY=true`: composite semi-transparent bar + centered **WayLume** name (North, bold 15pt) + image title (NorthEast, 24pt)
12. `apply_wallpaper()` — `_wl_set_wallpaper` + `notify-send`

---

## Menu architecture

### Main menu (7 items)

| # | Label | Handler |
| --- | --- | --- |
| 1 | ⬇️ Download new image now | `fetch_and_apply_wallpaper()` |
| 2 | 🎲 Random image from gallery | `go_random_image()` |
| 3 | ➡️ Next image in gallery | `go_next_image()` |
| 4 | ⬅️ Previous image in gallery | `go_prev_image()` |
| 5 | ⚙️ Settings | `menu_settings()` |
| 6 | 🔧 Maintenance | `menu_maintenance()` |
| 7 | 🚪 Exit | `break` |

### Settings submenu — deferred save pattern

`menu_settings()` resets `_WL_CONFIG_DIRTY=false` on entry. Each `set_*` function:

- Updates the in-memory variable (e.g. `DEST_DIR`)
- Sets `_WL_CONFIG_DIRTY=true`
- Does **not** call `save_config()`

On submenu exit (item **7** or window close): if the flag is set, the user is asked “Apply now?”. On confirmation: `save_config()` then `deploy_services()`.

This means a user can make multiple configuration changes and apply them all in one shot, or discard them by choosing not to apply.

**Rule:** `save_config()` must never be called inside `set_*` functions. All persistence goes through `menu_settings()`.

| # | Option | Handler | Effect |
| --- | --- | --- | --- |
| 1 | 📂 Gallery folder | `set_gallery_dir` | sets `DEST_DIR`, marks dirty |
| 2 | ⏱️ Update interval | `set_update_interval` | sets `INTERVAL`, marks dirty |
| 3 | 🌍 Image sources | `set_image_sources` | sets `SOURCES`, marks dirty |
| 4 | 🔑 NASA API Key | `set_apod_api_key` | sets `APOD_API_KEY`, marks dirty |
| 5 | 🖼️ Gallery limit | `set_gallery_max` | sets `GALLERY_MAX_FILES`, marks dirty |
| 6 | 🎨 Title overlay | `set_overlay_toggle` | toggles `SHOW_OVERLAY` (true/false), marks dirty; label shows current state (ON/OFF) |
| 7 | 🚪 Exit | `break` | triggers apply prompt if dirty |

### Maintenance submenu

`menu_maintenance()` wraps `clean_gallery()` and `uninstall()`. No special state logic.

---

## Gallery navigation

`_gallery_navigate(direction)` — direction is `next`, `prev`, or `random`.

**Algorithm:**

1. `find $DEST_DIR -type f ... | sort -z` → sorted array
   - Filenames are `waylume_YYYYMMDD_HHMMSS.jpg` → alphabetical order = chronological order
2. If `random`: pick a random index
3. Otherwise: read current wallpaper via `waylume-fetch --get-current-wallpaper` (DE-aware)
4. Find its index in the array (linear scan)
5. If not found (wallpaper set outside WayLume): start from 0 (`next`) or `COUNT-1` (`prev`)
6. Compute new index with circular modulo: `(IDX ± 1 + COUNT) % COUNT`
7. Apply via `waylume-fetch --set-wallpaper "$TARGET"` (DE-aware; GNOME inline as fallback)
8. `notify-send` with filename

**No ImageMagick.** Images in the gallery already have overlays applied. Reprocessing would degrade JPEG quality on each navigation.

`go_next_image()`, `go_prev_image()`, `go_random_image()` are thin one-line wrappers over `_gallery_navigate`.

## Multi-desktop dispatch

Two helpers in `src/fetcher.sh` abstract all wallpaper set/get operations:

| Function | Purpose |
| --- | --- |
| `_wl_set_wallpaper(TARGET)` | Dispatches via `case "${XDG_CURRENT_DESKTOP:-}"` to the correct mechanism per DE |
| `_wl_get_current_wallpaper()` | Returns current wallpaper path (plain, no `file://`); empty string when no read-back available |

All code that previously called `gsettings set/get org.gnome.desktop.background` directly now routes through these helpers. `apply_wallpaper()` and `prune_gallery()` use them directly (same process). `_gallery_navigate()` in `main.sh` calls them via the `waylume-fetch --set-wallpaper` / `--get-current-wallpaper` CLI flags to avoid coupling `main.sh` to `fetcher.sh` internals.

**Supported DEs and their mechanisms:**

| `XDG_CURRENT_DESKTOP` | Set | Get |
| --- | --- | --- |
| `GNOME`, `ubuntu:GNOME` | `gsettings org.gnome.desktop.background picture-uri` + `picture-uri-dark` | `gsettings get` |
| `MATE` | `gsettings org.mate.background picture-filename` (plain path, no `file://`) | `gsettings get` |
| `X-Cinnamon` | `gsettings org.cinnamon.desktop.background picture-uri` + `picture-uri-dark` | `gsettings get` |
| `KDE` | `plasma-apply-wallpaperimage "$TARGET"` | *(empty — no CLI read-back)* |
| `XFCE` | `xfconf-query` — enumerate all `last-image` props then update each; fallback to `xrandr` monitor on fresh install | `xfconf-query` first `last-image` prop |
| `*` (unknown) | GNOME schema, `2>/dev/null \|\| true` | *(empty)* |

**Testing without installing DEs:**

```bash
bash test_multi_de.sh
```

Mocks replace `gsettings`, `xfconf-query`, `plasma-apply-wallpaperimage`, `xrandr`, and `notify-send`. `XDG_CURRENT_DESKTOP` is overridden per scenario. 29 assertions.

---

## i18n architecture

### String bundles

Each bundle is a plain Bash file (`src/i18n/<lang>.sh`) sourced at startup. Variable prefixes:

| Prefix | Usage |
| --- | --- |
| `BTN_*` | yad button labels |
| `TITLE_*` | yad window titles |
| `MSG_*` | message body texts (some with `printf` placeholders `%s`) |
| `COL_*` | yad column headers |
| `ITEM_*` | radiolist items |
| `LABEL_*` | scale slider labels |
| `MENU_ITEM_*` | main menu rows |
| `MENU_SETTINGS_*` | settings submenu rows |
| `MENU_MAINTENANCE_*` | maintenance submenu rows |
| `MSG_NAV_*` | gallery navigation notify-send messages |

### Language detection

```bash
WL_LANG="${LANG:-${LANGUAGE:-en}}"
WL_LANG="${WL_LANG%%.*}"   # strip .UTF-8
WL_LANG="${WL_LANG%%_*}"   # strip _BR, _US…
WL_LANG="${WL_LANG,,}"     # lowercase
source ".../i18n/${WL_LANG}.sh" 2>/dev/null \
    || source ".../i18n/en.sh" 2>/dev/null || true
```

| `$LANG` | Bundle loaded |
| --- | --- |
| `pt_BR.UTF-8`, `pt_PT`, `pt` | `pt.sh` |
| `en_US.UTF-8`, `en_AU`, `en_GB`, `en` | `en.sh` |
| `de_DE.UTF-8`, `C`, empty | fallback `en.sh` |

`LANG` is injected into the systemd service `Environment=` directive at deploy time so `fetcher.sh` inherits the correct locale.

### Inline fallbacks (first-run safety)

Before the i18n files are installed, the script uses `:` assignments:

```bash
: "${BTN_CLOSE:=Close}" "${BTN_NO:=No}" "${BTN_YES:=Yes}"
```

### Dynamic strings

```bash
# Simple substitution:
--text="${MSG_DEPLOY_DONE}"

# With runtime value (use printf):
--text="$(printf "${MSG_INTERVAL_CHANGED}" "$INTERVAL")"
notify-send "WayLume" "$(printf "${MSG_FETCH_APOD_ERROR}" "$ERR_MSG")"
```

### Adding a new language

1. `cp src/i18n/en.sh src/i18n/de.sh` → translate all values
2. In `install_or_update()` in `src/main.sh`, add a new heredoc:

   ```bash
   cat << 'WL_I18N_DE' > "$CONFIG_DIR/i18n/de.sh"
   ##I18N_DE##
   WL_I18N_DE
   ```

3. In `build.sh`, add `I18N_DE="$SCRIPT_DIR/src/i18n/de.sh"` and pass it to Python; add `'##I18N_DE##'` to the assert list and substitution chain
4. `./build.sh --install`

---

## Image sources

Each source is a `fetch_<name>()` function in `fetcher.sh`. Naming: lowercase, matching entries in `SOURCES` (e.g. `Bing` → `fetch_bing`).

**Interface contract:**

| | Description |
| --- | --- |
| Input `$1` | Target file path — write the downloaded image here |
| Input globals | `DEST_DIR`, `APOD_API_KEY`, `*_LAST_DATE`, `$TODAY` |
| Output globals | `IMG_TITLE` (overlay text; empty = no overlay), `MESSAGE` (notify-send) |
| Cache-hit | Call `apply_random_local "<Source>"` + `return` — skip download |
| Date state | Update `*_LAST_DATE="$TODAY"` on successful new download; call `save_state` |

**Dispatch** (in `fetcher.sh` main):

```bash
SELECTED_SOURCE="${SOURCE_ARRAY[$RANDOM % ${#SOURCE_ARRAY[@]}]}"
"fetch_${SELECTED_SOURCE,,}" "$TARGET_PATH"
```

### Adding a new source

1. Add `fetch_newname()` to `src/fetcher.sh` following the interface above
2. Add `"Newname"` as a checklist option in `set_image_sources()` in `src/main.sh`
3. Add any new strings to both i18n bundles
4. `./build.sh --install`

> **Modularisation note:** When a 4th source is added, consider splitting each into `src/sources/<name>.sh` and making `fetcher.sh` a thin orchestrator. With 3 sources the overhead is not justified.

---

## Systemd integration

`deploy_services()` writes two unit files and activates them:

```text
~/.config/systemd/user/waylume.service   — oneshot: runs waylume-fetch
~/.config/systemd/user/waylume.timer     — activates service every $INTERVAL
```

Key timer options:

| Option | Effect |
| --- | --- |
| `OnBootSec=1min` | Runs 1 minute after login |
| `OnUnitActiveSec=$INTERVAL` | Repeating interval |
| `Persistent=true` | Catches up missed runs after the PC was off |

---

## Architecture decisions

| Decision | Rationale |
| --- | --- |
| Single distributed file | `curl .../waylume.sh \| bash` works; zero setup friction |
| `src/` for development | Syntax highlighting, shellcheck, standalone testability |
| i18n via `.sh` files | No external dependencies; compatible with single-file distribution |
| `GDK_BACKEND=x11` forced | yad on native Wayland causes GDK X11 assertion errors; XWayland works correctly |
| APOD uses `url` (960px) | `hdurl` (4K) caused 30s+ downloads with no perceptible visual gain |
| Brand strip as plain text | QR codes become illegible compressed in JPEG; URL links are not clickable on a wallpaper |
| `SHOW_OVERLAY` default `true` | Overlay adds context (source, title); users who prefer a clean wallpaper can disable via Settings |
| `.desktop`/`.service`/`.timer` as heredocs | Depend on variables interpolated at deploy time (`$INTERVAL`, `$FETCHER_SCRIPT`) |
| No split of `src/main.sh` by feature | Full global-state coupling; no real isolated testability gains from splitting |
| Deferred save pattern | User can make multiple config changes and apply (or discard) them all in one step |
| Navigation in `main.sh`, not `fetcher.sh` | Navigation is instant GUI-only: no download, no ImageMagick; wrong layer for fetcher |
| Multi-DE helpers in `fetcher.sh` | `fetcher.sh` is the primary consumer of wallpaper set/get; standalone-testable; `main.sh` calls them via CLI flags (`--set-wallpaper`, `--get-current-wallpaper`) to avoid cross-file coupling |
| XFCE via `xfconf-query` property enumeration | Enumerating existing `last-image` properties handles multi-monitor setups automatically without guessing monitor names; `--create -t string` makes it idempotent |
| Mock-based DE tests | Running actual DEs in CI is impractical; injecting `$PATH` mocks + overriding `XDG_CURRENT_DESKTOP` gives deterministic coverage of all dispatch branches |

---

## Bug fix log

| Date | Component | Bug | Fix |
| --- | --- | --- | --- |
| 2026-04-30 | `fetcher.sh` / `main.sh` | All `gsettings` calls hardcoded for GNOME; other DEs received black screen or no-op | Extracted to `_wl_set_wallpaper()` / `_wl_get_current_wallpaper()` helpers with `case $XDG_CURRENT_DESKTOP`; `main.sh` gallery navigation delegates via `waylume-fetch --set-wallpaper` / `--get-current-wallpaper` CLI flags; `pin/unpin_from_favorites()` guarded for GNOME-only |
| 2026-04-06 | `fetcher.sh` / `main.sh` | Overlay was always on with no user control | Added `SHOW_OVERLAY=true/false` config key; `set_overlay_toggle()` in Settings (item 6); main menu header shows current state |
| 2026-04-04 | `fetcher.sh` | `source waylume.conf` / `source waylume.state` — arbitrary code execution if file tampered | Replaced with `_wl_read_keyval()`: safe `key=value` parser with explicit key whitelist, no `eval` |
| 2026-04-04 | `main.sh` | `source "$CONF_FILE"` in `load_config()` — same vector, runs in interactive user shell | `_wl_read_keyval()` defined in `main.sh`; `load_config` updated |
| 2026-04-04 | `fetcher.sh` | `"fetch_${SELECTED_SOURCE,,}"` — dynamic dispatch to arbitrary function name | Replaced with `case`; only 4 known source names allowed; unknown → local gallery + notify |
| 2026-04-04 | `process_image` | Bare `%` in `IMG_TITLE` expanded as ImageMagick format specifier; C0 control chars misaligned overlay | `${...//%/%%}` + `tr -d \000-\037\177` on `DISPLAY_TITLE` before `-annotate` |
| 2026-04-04 | `fetch_unsplash` | Downloaded on every timer tick — gallery grew unboundedly | Added `UNSPLASH_LAST_DATE` state; capped at 1 download/day like other sources |
| 2026-04-04 | `fetcher.sh` | Gallery had no size limit — disk filled over time | Added `prune_gallery()` + `GALLERY_MAX_FILES` config (default 60); exposed in Settings |
| 2026-04-01 | `fetch_wikimedia` | `\uXXXX` in filename → `--data-urlencode` sent literal `%5Cu00ed` → empty `thumburl` | Python3 decode before Step 2 curl call |
| 2026-04-01 | `unpin_from_favorites` | Missing closing `}` → premature EOF syntax error | Fixed targeted replacement |
| 2026-03-11 | `fetch_bing` | `format=js` rejected by API → empty URL → silent failure | Changed to `format=json`; added fallback to `apply_random_local` |
| earlier | `yad_info/error/question` | Recursive calls → segfault | Rewrote as non-recursive wrappers |
| earlier | `fetcher.sh` main | `SOURCES` saved with literal `\n` → `case` never matched | Strip whitespace from each `SOURCE_ARRAY` element |
| earlier | `process_image` | Title overlay invisible in JPEG (alpha channel issue) | Fixed with `-composite` |
| earlier | `fetch_apod` | `hdurl` → 30s+ download delay | Use `url` (~960px) |
