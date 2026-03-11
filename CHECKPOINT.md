# CHECKPOINT — Session 2026-03-11

> Read this file at the start of each session to recover development context.

---

## Repository state

- **Repo:** github.com/andrecavalcantebr/waylume
- **Branch:** main
- **Latest commit:** `5238bed` — (session work not yet committed — see "Next session agenda")
- **Git log:**

  ```text
  5238bed  (HEAD -> main, origin/main) docs: translate CHECKPOINT.md fully to English
  fbbd706  chore: update CHECKPOINT to session 06/03/2026
  e7afc24  chore: fix all markdown lint issues across project files
  c9d7a7a  docs: document i18n build embedding and runtime extraction in developer sections
  b41647e  feat: i18n, brand overlay, bilingual docs, and locale fixes
  31a284e  chore: adicionar CHECKPOINT da sessão 04/03/2026
  ```

---

## File structure

```text
waylume/
  src/
    main.sh       (626 lines) — installer and GUI; placeholders ##FETCHER_CONTENT## ##ICON_CONTENT## ##I18N_PT## ##I18N_EN##
    fetcher.sh    (240 lines) — systemd worker (waylume-fetch); standalone-testable with: bash src/fetcher.sh
    waylume.svg   ( 22 lines) — application SVG icon
    i18n/
      pt.sh       (116 lines) — all strings in Brazilian Portuguese
      en.sh       (116 lines) — all strings in English
  build.sh        ( 46 lines) — combines the above files → waylume.sh
  waylume.sh      (1120 lines) — GENERATED ARTIFACT; do not edit directly
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
./build.sh && ./waylume.sh --install
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
| 1 | ⬇️ Baixar nova imagem agora | `fetch_and_apply_wallpaper` |
| 2 | 🎲 Imagem aleatória da galeria | `go_random_image` |
| 3 | ➡️ Próxima imagem da galeria | `go_next_image` |
| 4 | ⬅️ Imagem anterior da galeria | `go_prev_image` |
| 5 | ⚙️ Configurações | `menu_settings` (submenu) |
| 6 | 🔧 Manutenção | `menu_maintenance` (submenu) |
| 7 | 🚪 Sair | `break` |

#### Settings submenu — deferred save pattern

`_WL_CONFIG_DIRTY=false` reset on entry. Each `set_*` sets the flag but does **not** call `save_config`. On exit: if dirty → ask user → `save_config + deploy_services`.

| # | Option | Handler |
| --- | --- | --- |
| 1 | 📂 Pasta da galeria | `set_gallery_dir` |
| 2 | ⏱️ Tempo de atualização | `set_update_interval` |
| 3 | 🌍 Fontes de imagens | `set_image_sources` |
| 4 | 🔑 API Key da NASA | `set_apod_api_key` |
| 5 | 🚪 Sair | `break` → triggers apply prompt |

#### Maintenance submenu

| # | Option | Handler |
| --- | --- | --- |
| 1 | 🧹 Limpar galeria | `clean_gallery` |
| 2 | 🗑️ Remover WayLume | `uninstall` |

#### Gallery navigation

`_gallery_navigate(next|prev|random)` in `main.sh`:
- Filenames `waylume_YYYYMMDD_HHMMSS.jpg` → alphabetical sort = chronological order
- Current wallpaper read from `gsettings`; circular index with modulo arithmetic
- No ImageMagick: overlays already applied; only `gsettings set` + `notify-send`
- `go_next_image()`, `go_prev_image()`, `go_random_image()` are thin one-line wrappers

### Fetcher (src/fetcher.sh)

- **3 sources:** Bing (daily photo), Unsplash (random), APOD (NASA)
- **Daily cache:** APOD and Bing download only once per day; subsequent timer runs rotate from the local gallery (~0.06s, no network)
- **Persisted state:** `~/.config/waylume/waylume.state` (`APOD_LAST_DATE`, `BING_LAST_DATE`)
- **API error handling:** rate limit / invalid key → notifies user + uses local gallery + marks date (no loop)
- **Title overlay:** ImageMagick via `-composite` (JPEG has no alpha channel)
- **Brand strip (NorthWest):** plain text overlay: `WayLume` (DejaVu-Sans-Bold 16pt white +14+17) + `is.gd/48OrTP` (DejaVu-Sans 13pt #bbbbbb +14+35). No external assets.
- **APOD:** uses `url` (960px) instead of `hdurl` (4K) — ~10x faster
- **Bing fix (2026-03-11):** API changed `format=js` → `format=json`; added fallback to `apply_random_local` when URL is empty

### Fixed bugs

| Session | Bug | Fix |
| --- | --- | --- |
| 2026-03-11 | Bing: `format=js` rejected by API → empty URL → silent failure | Changed to `format=json`; added fallback to local gallery |
| earlier | `yad_info/error/question` recursive → segfault | Rewrote as non-recursive wrappers |
| earlier | `SOURCES` saved with literal `\n` → `case` never matched | Strip whitespace from `SOURCE_ARRAY` elements |
| earlier | Title overlay invisible in JPEG (alpha channel) | Fixed with `-composite` |
| earlier | APOD `hdurl` → 30s+ downloads | Use `url` (960px) |

---

## Current development configuration

```bash
# ~/.config/waylume/waylume.conf
DEST_DIR="/home/andre/Imagens/WayLume"
INTERVAL="3min"
SOURCES="Bing,Unsplash,APOD"
APOD_API_KEY="DEMO_KEY
```

> ⚠️ For publishing/testing on another machine, use `DEMO_KEY` (limit: 30 req/hour).

---

## Next session agenda

### 1. Commit and push this session's work

Suggested commit message:

```
fix: bing source format=js → format=json + fallback on empty URL
feat: menu refactor — submenus, gallery nav (next/prev/random), dirty-flag config flow
docs: CHECKPOINT, DEVELOPER.md, README user rewrite
```

### 2. Add screenshots to repository

Add actual screenshots to `docs/screens/` for the README mini-manual:

- `docs/screens/menu-principal.png`
- `docs/screens/submenu-configuracoes.png`
- `docs/screens/submenu-manutencao.png`
- `docs/screens/wallpaper-exemplo.png`

### 3. Source modularisation — when a 4th source is added

**Approach:** each source becomes an independent file under `src/sources/`.

```text
src/
  sources/
    apod.sh       ← testable with: bash src/sources/apod.sh
    bing.sh
    unsplash.sh
  fetcher.sh      ← thin orchestrator (~50 lines): pick → source → validate → overlay → apply
```

**Interface convention (TBD):**

- Input: `$TARGET_PATH` (where to save), variables from `waylume.conf`
- Output: image file written + `$IMG_TITLE` + `$MESSAGE`
- Date cache: each source manages its own entry in `waylume.state`

**Implementation trigger:** when a 4th source is added.
With only 3 sources, the setup overhead is not yet justified.

---

## Consolidated architecture decisions

| Decision | Rationale |
| --- | --- |
| `waylume.sh` is a single distributed artifact | Preserves "Unix Way": `curl .../waylume.sh \| bash` works |
| `src/` holds development sources | Syntax highlighting, shellcheck, standalone testability |
| `.desktop`, `.service`, `.timer` remain as heredocs in `src/main.sh` | Depend on variables interpolated at deploy time (`$INTERVAL`, `$FETCHER_SCRIPT`) |
| Do not split `src/main.sh` by menu/feature | Full global-state coupling; no real isolated testability |
| i18n via `.sh` files (Option B), not gettext | No external dependencies; compatible with single distributed file |
| Plain-text brand strip (no assets) | QR codes become illegible compressed in JPEG; SVG icon looks out of place in the overlay |
| APOD uses `url` (960px) | `hdurl` (4K) caused 30s+ downloads with no perceptible visual gain |
