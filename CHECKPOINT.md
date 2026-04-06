# CHECKPOINT — Session 2026-04-06

> Read this file at the start of each session to recover development context.

---

## Repository state

- **Repo:** github.com/andrecavalcantebr/waylume
- **Branch:** main
- **Latest commit:** see `git log` below
- **Version:** `1.4.0`
- **Git log:**

  ```text
  653b2d4  feat: overlay toggle, multi-DE roadmap, and docs update (v1.4.0)
  4e5a0c2  docs: fix markdownlint warnings in CHECKPOINT, README.en and README.pt
  3b2e4c1  docs: update architecture decisions with modularisation and build evolution notes
  813701c  docs: update CHECKPOINT.md with final commit hash (v1.3.0)
  ```

---

## File structure

```text
waylume/
  src/
    main.sh       (736 lines) — installer and GUI; placeholders ##FETCHER_CONTENT## ##ICON_CONTENT## ##I18N_PT## ##I18N_EN##
    fetcher.sh    (441 lines) — systemd worker (waylume-fetch); standalone-testable with: bash src/fetcher.sh
    waylume.svg   ( 22 lines) — application SVG icon
    i18n/
      pt.sh       (133 lines) — all strings in Brazilian Portuguese
      en.sh       (135 lines) — all strings in English
  build.sh        ( 50 lines) — combines the above files → waylume.sh; supports --install flag
  waylume.sh      (1467 lines) — GENERATED ARTIFACT; do not edit directly
  linuxtoys-pr/                — material for the LinuxToys PR (see below)
    p3/scripts/utils/
      waylume.sh               — LinuxToys installer script (nocontainer)
      waylume.svg              — symlink → src/waylume.svg
    p3/libs/lang/
      en.json.patch            — waylume_desc to add to LinuxToys en.json
      pt.json.patch            — waylume_desc to add to LinuxToys pt.json
  DEVELOPER.md               — technical reference for contributors
  README.md                  — language hub (links → README.pt.md and README.en.md)
  README.pt.md               — user documentation in Portuguese
  README.en.md               — user documentation in English
  LICENSE.md                 — GPLv3 (authoritative English text)
  LICENSE.pt.md              — informational GPLv3 summary in Portuguese (does not replace EN)
  CHECKPOINT.md              — this file
```

### Golden rule

**Always edit in `src/`, never in `waylume.sh` directly.**
After any change:

```bash
./build.sh --install
```

---

## build.sh architecture

`build.sh` uses Python 3 to substitute four placeholders in `src/main.sh`:

| Placeholder | Replaced by |
| --- | --- |
| `##FETCHER_CONTENT##` | content of `src/fetcher.sh` |
| `##ICON_CONTENT##` | content of `src/waylume.svg` |
| `##I18N_PT##` | content of `src/i18n/pt.sh` |
| `##I18N_EN##` | content of `src/i18n/en.sh` |

The `##I18N_PT##` and `##I18N_EN##` placeholders live **inside heredocs** in `install_or_update`:

```bash
cat << 'WL_I18N_PT' > "$CONFIG_DIR/i18n/pt.sh"
##I18N_PT##
WL_I18N_PT
```

Python substitutes them before runtime, so the resulting heredoc contains the correct string bundle.

Result: `waylume.sh` is self-contained (972 lines, single file for distribution).

---

## Internationalisation (i18n) — COMPLETE

### Architecture

- Bundles in `src/i18n/{lang}.sh` — variables `BTN_*`, `TITLE_*`, `MSG_*`, `COL_*`, `ITEM_*`, `LABEL_*`, `MENU_ITEM_*`
- Embedded into `waylume.sh` via `##I18N_PT##` / `##I18N_EN##` inside heredocs
- Extracted to `~/.config/waylume/i18n/` during `--install`
- Loaded at runtime at the top of `main.sh` and `fetcher.sh`

### Language detection

```bash
_wl_lang="${LANG:-${LANGUAGE:-en}}"
_wl_lang="${_wl_lang%%.*}"   # strip .UTF-8
_wl_lang="${_wl_lang%%_*}"   # strip _BR, _US, _AU…
_wl_lang="${_wl_lang,,}"     # lowercase
source "$CONFIG_DIR/i18n/${_wl_lang}.sh" 2>/dev/null \
    || source "$CONFIG_DIR/i18n/en.sh" 2>/dev/null || true
```

| LANG | Result |
| --- | --- |
| `pt_BR.UTF-8`, `pt_PT.UTF-8`, `pt` | `pt.sh` ✅ |
| `en_US.UTF-8`, `en_AU.UTF-8`, `en_GB.UTF-8`, `en` | `en.sh` ✅ |
| `de_DE.UTF-8`, `C`, empty | fallback `en.sh` |

**LANG injected into systemd:** `Environment="LANG=${LANG}"` is written into the `.service` file at
`deploy_services` time, so that `fetcher.sh` inherits the correct locale from the user session.

### First-run (before --install)

Button and title variables have **inline fallbacks** via `${VAR:=value}` to work without i18n files:

```bash
: "${BTN_CLOSE:=Close}"
: "${BTN_YES:=Yes}"
: "${BTN_NO:=No}"
: "${BTN_OK:=OK}"
# etc.
```

### Dynamic string conventions

```bash
# Simple:
--text="${MSG_CONFIRM_DELETE}"

# With dynamic value (printf):
--text="$(printf "${MSG_CONFIRM_DELETE_N}" "$COUNT")"
notify-send "WayLume" "$(printf "${MSG_FETCH_INVALID_MIME}" "$MIME")"
```

### Adding a new language

1. `cp src/i18n/en.sh src/i18n/XX.sh` → translate all values
2. Add a `##I18N_XX##` placeholder inside a heredoc in `install_or_update` in `src/main.sh`
3. Update `build.sh` with the new `I18N_XX` variable and the extra Python argument
4. `./build.sh && ./waylume.sh --install`

---

## Implemented features

### Menu (src/main.sh)

#### Main menu (7 items)

| # | Option | Handler |
| --- | --- | --- |
| 1 | ⬇️ Download new image now | `fetch_and_apply_wallpaper` |
| 2 | 🎲 Random image from gallery | `go_random_image` |
| 3 | ➡️ Next image in gallery | `go_next_image` |
| 4 | ⬅️ Previous image in gallery | `go_prev_image` |
| 5 | ⚙️ Settings | `menu_settings` (submenu) |
| 6 | 🔧 Maintenance | `menu_maintenance` (submenu) |
| 7 | 🚪 Exit | `break` |

#### Settings submenu — deferred save pattern

`_WL_CONFIG_DIRTY=false` reset on entry. Each `set_*` sets the flag but does **not** call `save_config`. On exit: if dirty → ask user → `save_config + deploy_services`.

| # | Option | Handler |
| --- | --- | --- |
| 1 | 📂 Gallery folder | `set_gallery_dir` |
| 2 | ⏱️ Update interval | `set_update_interval` |
| 3 | 🌍 Image sources | `set_image_sources` |
| 4 | 🔑 NASA API Key | `set_apod_api_key` |
| 5 | 🖼️ Gallery limit | `set_gallery_max` |
| 6 | 🎨 Title overlay | `set_overlay_toggle` — label mostra estado atual (ON/OFF) |
| 7 | 🚪 Exit | `break` → triggers apply prompt |

#### Maintenance submenu

| # | Option | Handler |
| --- | --- | --- |
| 1 | 🧹 Clean gallery | `clean_gallery` |
| 2 | 🗑️ Remove WayLume | `uninstall` |

#### Gallery navigation

`_gallery_navigate(next|prev|random)` in `main.sh`:

- Filenames `waylume_YYYYMMDD_HHMMSS.jpg` → alphabetical sort = chronological order
- Current wallpaper read from `gsettings`; circular index with modulo arithmetic
- No ImageMagick: overlays already applied; only `gsettings set` + `notify-send`
- `go_next_image()`, `go_prev_image()`, `go_random_image()` are thin one-line wrappers

### Fetcher (src/fetcher.sh)

- **4 sources:** Bing (daily), Unsplash (random + real author via Picsum-ID), APOD (NASA), Wikimedia POTD
- **Daily cache:** Bing, APOD, Wikimedia download only once per day; subsequent timer runs rotate from local gallery
- **Persisted state:** `~/.config/waylume/waylume.state` (`APOD_LAST_DATE`, `BING_LAST_DATE`, `WIKIMEDIA_LAST_DATE`)
- **Unsplash metadata:** `curl -D` captures `Picsum-ID` header → `/id/{id}/info` → real author name in title
- **Wikimedia POTD:** 2-step API: Template:Potd/{date} → filename → imageinfo (1920px thumburl). Python3 decodes `\uXXXX` Unicode escapes in filename before `--data-urlencode`
- **API error handling:** rate limit / invalid key → notifies user + uses local gallery + marks date (no loop)
- **Title overlay:** ImageMagick via `-composite` (JPEG has no alpha channel); controlled by `SHOW_OVERLAY` config key (default `true`)
- **Brand strip (North, centered):** `WayLume` name only (DejaVu-Sans-Bold 15pt white, centered `+0+17`); URL removed
- **APOD:** uses `url` (960px) instead of `hdurl` (4K) — ~10x faster
- **Bing fix (2026-03-11):** API changed `format=js` → `format=json`; added fallback to `apply_random_local` when URL is empty

### Fixed bugs

| Session | Bug | Fix |
| --- | --- | --- |
| 2026-04-06 | `process_image` — Brand strip mostrava URL `is.gd/48OrTP` — não clicável no wallpaper, parece fraude | URL removida; nome `WayLume` centralizado (`-gravity North -annotate +0+17`) |
| 2026-04-06 | `fetcher.sh` / `main.sh` — Overlay sempre ativo, sem controle do usuário | Adicionado `SHOW_OVERLAY=true/false` no conf; `set_overlay_toggle()` no submenu Settings (item 6); header do menu principal mostra o estado atual |
| 2026-04-04 | `source waylume.conf` / `source waylume.state` — arbitrary code execution if file tampered | `_wl_read_keyval()`: safe `key=value` parser with explicit key whitelist, no `eval` |
| 2026-04-04 | `source "$CONF_FILE"` in `load_config()` in `main.sh` — same vector, runs in interactive user shell | `_wl_read_keyval()` defined in `main.sh`; `load_config` updated |
| 2026-04-04 | `"fetch_${SELECTED_SOURCE,,}"` — dynamic dispatch to arbitrary function name | Replaced with `case` statement; only 4 known source names allowed; unknown → local gallery + notify |
| 2026-04-04 | `IMG_TITLE` in `convert -annotate` — bare `%` expanded as ImageMagick format specifier; control chars misalign overlay | `${...//%/%%}` + `tr -d \000-\037\177` applied to `DISPLAY_TITLE` in `process_image` |
| 2026-04-04 | Unsplash downloaded on every timer tick — gallery grew unboundedly | Added `UNSPLASH_LAST_DATE` state; now capped at 1 download/day like other sources |
| 2026-04-04 | Gallery grew without bound; no auto-cleanup | Added `prune_gallery()` in fetcher + `GALLERY_MAX_FILES` config (default 60); exposed as Settings item |
| 2026-04-04 | `--random` mode called `validate_image` + `process_image` on already-processed files — JPEG re-encoded (lossy) on every gallery rotation | Early exit: `apply_random_local + apply_wallpaper + exit 0`; pipeline bypassed for `--random` |
| 2026-04-04 | Daily cap check repeated verbatim (3 lines) in all 4 `fetch_*` functions | Extracted to `_wl_daily_cap()` helper (indirect expansion `${!2}`); each source: `_wl_daily_cap "X" X_LAST_DATE && return` |
| 2026-04-01 | Wikimedia: `\uXXXX` in filename → `--data-urlencode` sent literal `%5Cu00ed` → empty `thumburl` | Python3 decode before Step 2 curl call |
| 2026-04-01 | `unpin_from_favorites` missing closing `}` → premature EOF syntax error | Fixed targeted replacement |
| 2026-03-11 | Bing: `format=js` rejected by API → empty URL → silent failure | Changed to `format=json`; added fallback to local gallery |
| earlier | `yad_info/error/question` recursive → segfault | Rewrote as non-recursive wrappers |
| earlier | `SOURCES` saved with literal `\n` → `case` never matched | Strip whitespace from `SOURCE_ARRAY` elements |
| earlier | Title overlay invisible in JPEG (alpha channel) | Fixed with `-composite` |
| earlier | APOD `hdurl` → 30s+ downloads | Use `url` (960px) |

---

## Default configuration

```bash
# ~/.config/waylume/waylume.conf
DEST_DIR="$USER/Images/WayLume"
INTERVAL="3h"
SOURCES="Bing,Unsplash,APOD,Wikimedia"
APOD_API_KEY="DEMO_KEY"
```

> ⚠️ For publishing/testing on another machine, use `DEMO_KEY` (limit: 30 req/hour).

---

## LinuxToys integration

- **PR:** <https://github.com/psygreg/linuxtoys/pull/399> (open, awaiting review)
- **Fork:** <https://github.com/andrecavalcantebr/linuxtoys> → branch `feat/add-waylume`
- **Local clone:** `/home/andre/code/linuxtoys`
- **Files added to linuxtoys:**
  - `p3/scripts/utils/waylume.sh` — `# nocontainer` script; runs `curl .../waylume.sh | bash -s -- --install`
  - `p3/scripts/utils/waylume.svg` — icon copy
  - `p3/libs/lang/en.json` + `pt.json` — `waylume_desc` translation key added
- **Auto-update mechanism:** the LinuxToys script points to `raw.githubusercontent.com/andrecavalcantebr/waylume/main/waylume.sh`. Every `./build.sh && git push` on the waylume repo automatically updates what LinuxToys installs — no changes to the PR needed.
- **PR material backup:** `linuxtoys-pr/` in this repo (`waylume.svg` is a symlink to `src/waylume.svg`)

---

## Critical analysis (session 2026-04-01)

### Usability — issues to address in future versions

- **No thumbnail in menu** — user doesn't see the current wallpaper, only filename via `notify-send`
- ~~**Overlay always on**~~ **FIXED (2026-04-06):** `SHOW_OVERLAY` config key + `set_overlay_toggle()` em Settings
- ~~**Brand URL in banner**~~ **FIXED (2026-04-06):** URL removida; nome `WayLume` centralizado
- **APOD low resolution** — uses `url` (~960px) for speed, but `hdurl` (4K) is never offered
- **No gallery size limit** — disk fills over time; no auto-cleanup of oldest files — **FIXED (2026-04-04):** `prune_gallery()` + `GALLERY_MAX_FILES=60`
- **No timer pause/resume** — must uninstall/reinstall to stop; no toggle
- **Multiple monitors** — `process_image` uses only `head -1` monitor from `xrandr`
- **xrandr fallback** — if `xrandr` fails (pure Wayland without XWayland), `process_image` exits silently with no resize

### Security — issues to address in future versions

- ~~**`source "$CONF_FILE"`** in `fetcher.sh` — arbitrary code execution if the config file is tampered with~~ **FIXED (2026-04-04):** substituído por `_wl_read_keyval()` com whitelist explícita
- ~~**`source "$STATE_FILE"`** — same problem with `waylume.state`~~ **FIXED (2026-04-04)**
- **`grep -oP` JSON parsing** — not real parsing; malicious API responses could inject unexpected output. _Note: the practical risk is low after `IMG_TITLE` sanitisation (% escaping + control-char stripping), since the injected value no longer reaches ImageMagick unfiltered. A proper fix (e.g. `python3 -c json.loads`) would require refactoring all four `fetch_*` functions and is not justified at this scale. Revisit if a new source is added or if `jq` becomes a declared dependency._
- ~~**`IMG_TITLE` in `convert -annotate`** — titles with special chars (`'`, `"`) could break the ImageMagick command; truncation to 120 chars mitigates but doesn't eliminate~~ **FIXED (2026-04-04):** `%` escaped to `%%`; C0 control chars stripped via `tr`
- ~~**`"fetch_${SELECTED_SOURCE,,}"`** — dynamic function dispatch; `SOURCES` now parsed safely but dispatch still resolves to an arbitrary function name; mitigated by the fact that `_wl_read_keyval` no longer allows injection via conf~~ **FIXED (2026-04-04):** substituído por `case` com as 4 fontes hardcoded; valor desconhecido cai em fallback local

### Functionality — gaps for future versions

- ~~Option to disable/configure the title overlay and brand strip~~ **FIXED (2026-04-06)**
- Gallery size limit (keep last N images)
- Multi-monitor support (detect all connected resolutions)
- `hdurl` option for APOD (opt-in for 4K)
- Timer pause/resume without uninstalling
- In-menu thumbnail preview of current wallpaper (yad supports `--image`)

---

## Critical analysis (session 2026-04-04)

| Priority | Issue | Status |
| --- | --- | --- |
| 🔴 1 | `--random` mode re-encoded already-processed JPEGs on every gallery rotation (lossy degradation) | **FIXED** — early exit before `process_image` |
| 🟠 2 | No `--max-time` on any `curl` call — slow server hangs the systemd service indefinitely | **FIXED** — `--connect-timeout 8 --max-time 15` (API), `--connect-timeout 10 --max-time 30` (image); `_wl_check_timeout` notifies + exits clean |
| 🟠 3 | `DEST_DIR` empty if conf missing → `find ""` → `find .` (scans cwd of service, potentially `/`) | **FIXED** — `DEST_DIR="${DEST_DIR:-$(xdg-user-dir PICTURES)/WayLume}"` fallback after `_wl_read_keyval` |
| 🟠 4 | `prune_gallery` may delete the active wallpaper → GNOME shows black on next change | **FIXED** — reads active path via `gsettings get picture-uri`; active file skipped in delete loop |
| 🟡 5 | `HDR_TMP="/tmp/wl_hdr_$$"` — PID-predictable temp file; symlink attack risk | **FIXED** — `mktemp /tmp/wl_hdr_XXXXXX` + `trap 'rm -f "$HDR_TMP"' EXIT`; trap cancelled after manual `rm` |
| 🟡 6 | `WL_VERSION="1.1.0"` — should be bumped to `1.3.0` | **FIXED** — bumped to `1.3.0` in `src/main.sh` |
| 🟡 7 | `mkt=pt-BR` hardcoded in Bing URL — non-PT users see captions in Portuguese | **FIXED** — `WL_MKT` derived from `$LANG` (e.g. `pt_BR` → `pt-BR`); fallback `en-US` |
| 🔵 8 | Daily cap boilerplate (3 lines × 4 sources) → extracted to `_wl_daily_cap()` helper | **FIXED** — `_wl_daily_cap "X" X_LAST_DATE && return` |

---

## Critical analysis (session 2026-04-06)

| Priority | Issue | Status |
| --- | --- | --- |
| 🟢 1 | URL `is.gd/48OrTP` no brand strip — não clicável, parecia fraude | **FIXED** — URL removida; nome centralizado |
| 🟢 2 | Overlay sempre ativo sem controle do usuário | **FIXED** — `SHOW_OVERLAY` + `set_overlay_toggle()` + status no header do menu |

---

## Next session agenda

> See also: [ROADMAP.md](ROADMAP.md) — strategic analysis, competitive comparison, and full roadmap.

### 1. Screenshots

Capturar novos screenshots que reflitam as mudanças da sessão 2026-04-06:

- `screenshot-menu-main.png` — nova linha "Título nas imagens: ativado" no header
- `screenshot-menu-settings.png` — item 6 (Título nas imagens) e item 7 (Sair)

### 2. Source modularisation into `src/sources/` (future)

`fetcher.sh` is at 384 lines with 4 sources. Modularise when reaching 5+ sources or external contributors:

```text
src/
  sources/
    bing.sh
    unsplash.sh
    apod.sh
    wikimedia.sh
  fetcher.sh   ← thin orchestrator (~60 lines)
```

Each source file: input `$TARGET_PATH`, output `$IMG_TITLE` + `$MESSAGE` + image written.

### 3. Multi-DE support implementation (Tier 1 + Tier 2)

See [ROADMAP.md §6](ROADMAP.md) for full analysis and code structure.

Implementation order:

1. Add `_wl_set_wallpaper()` + `_wl_get_current_wallpaper()` to `src/fetcher.sh`
2. Replace direct `gsettings` calls in `apply_wallpaper()` and `_gallery_navigate()`
3. Wrap `pin/unpin_from_favorites()` with GNOME guard
4. Test Tier 1: MATE + Cinnamon (zero new dependencies)
5. Test Tier 2: KDE Plasma ≥5.26 (`plasma-apply-wallpaperimage`)
6. Rebuild + `bash -n waylume.sh`

### 4. Screenshots pendentes

---

## Consolidated architecture decisions

| Decision | Rationale |
| --- | --- |
| `waylume.sh` is a single distributed artifact | Preserves "Unix Way": `curl .../waylume.sh \| bash` works; required for LinuxToys `# nocontainer` integration |
| `src/` holds development sources | Syntax highlighting, shellcheck, standalone testability |
| `.desktop`, `.service`, `.timer` remain as heredocs in `src/main.sh` | Depend on variables interpolated at deploy time (`$INTERVAL`, `$FETCHER_SCRIPT`) |
| `src/main.sh` not split yet | Global-state coupling is manageable at 712 lines; split into `src/lib/` warranted at ~900+ lines or first external contributor |
| `src/fetcher.sh` not split into `src/sources/` yet | 4 sources, 1 maintainer; split warranted at 5+ sources or when contributors ask "where is source X logic?" |
| `fetch_*` functions follow an implicit API contract | Input: `$TARGET` ($1), `$TODAY`,`$WL_MKT`, `$X_LAST_DATE`; Output:`$IMG_TITLE`, `$MESSAGE`, image at`$TARGET`, `X_LAST_DATE="$TODAY"`; helpers:`_wl_daily_cap`,`_wl_check_timeout`,`apply_random_local` |
| `build.sh` (bash + inline Python) as build tool | Works; evolve to `Makefile + tools/assemble.py` when modularising sources/lib — `make` is the canonical tool for "rebuild artifact from multiple sources with explicit dependencies" |
| Future distribution path | v1.x: `build.sh → waylume.sh`; v2.x: `Makefile + waylume.sh + tarball as GitHub release asset`; v3.x+: `Makefile + tarball` as primary if distro packaging needed |
| i18n via `.sh` files (Option B), not gettext | No external dependencies; compatible with single distributed file |
| Plain-text brand strip (no assets) | QR codes become illegible compressed in JPEG; SVG icon looks out of place in the overlay |
| URL removida do brand strip | Um link não clicável numa figura não tem utilidade e parece fraude; o nome `WayLume` centralizado é suficiente como identidade |
| `SHOW_OVERLAY` default `true` | Overlay agrega contexto (fonte, título); usuários que preferem imagem limpa podem desativar via Settings |
| APOD uses `url` (960px) | `hdurl` (4K) caused 30s+ downloads with no perceptible visual gain |
