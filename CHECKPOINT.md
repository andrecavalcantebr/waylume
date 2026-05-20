# CHECKPOINT — Session 2026-05-20

> Read this file at the start of each session to recover development context.

---

## Repository state

- **Repo:** github.com/andrecavalcantebr/waylume
- **Branch:** main
- **Version:** `1.8.0` — ⛔ SÉRIE 1.x ENCERRADA — não commitada
- **Git log:**

  ```text
  (pendente)   fix: fresh install + atomic writes + BTNS rename + set_gallery_dir (v1.8.0)
  70ee310  feat(zenity-migration): migrate GUI from yad to zenity 4.x (v1.7.0)
  7b2962c  feat: timer pause/resume and local gallery source (v1.6.0)
  6061b85  feat: multi-DE support — GNOME, MATE, Cinnamon, KDE, XFCE (v1.5.0)
  653b2d4  feat: overlay toggle, multi-DE roadmap, and docs update (v1.4.0)
  ```

---

## File structure

```text
waylume/
  src/
    main.sh         (~796 lines) — installer and GUI; placeholders ##FETCHER_CONTENT## ##ICON_CONTENT## ##I18N_PT## ##I18N_EN##
    fetcher.sh      (~570 lines) — systemd worker (waylume-fetch); multi-DE helpers; standalone-testable with: bash src/fetcher.sh
    waylume.svg     (  22 lines) — application SVG icon
    i18n/
      pt.sh         (~142 lines) — all strings in Brazilian Portuguese
      en.sh         (~144 lines) — all strings in English
  build.sh          (  50 lines) — combines the above files → waylume.sh; supports --install flag
  waylume.sh        (~1674 lines) — GENERATED ARTIFACT; do not edit directly
  test_multi_de.sh  — mock-based smoke tests for multi-DE dispatch (29 assertions; no DE installation required)
  linuxtoys-pr/     — material for the LinuxToys PR (see below)
  DEVELOPER.md      — technical reference for contributors
  ROADMAP.md        — version history, competitive analysis, and future plans
  README.md         — language hub (links → README.pt.md and README.en.md)
  README.pt.md      — user documentation in Portuguese
  README.en.md      — user documentation in English
  LICENSE.md        — GPLv3 (authoritative English text)
  CHECKPOINT.md     — this file
```

### Golden rule

**Always edit in `src/`, never in `waylume.sh` directly.**

```bash
./build.sh --install   # build + install
./build.sh && bash -n waylume.sh   # validate only
bash test_multi_de.sh  # run tests (expected: 29/29)
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

The i18n placeholders live inside heredocs in `install_or_update`. Python substitutes them before runtime; `waylume.sh` is self-contained (~1658 lines, single file for distribution).

---

## Internationalisation (i18n)

- Bundles in `src/i18n/{lang}.sh` — variables `BTN_*`, `TITLE_*`, `MSG_*`, `COL_*`, `ITEM_*`, `LABEL_*`, `MENU_ITEM_*`
- Extracted to `~/.config/waylume/i18n/` during `--install`; loaded at runtime in `main.sh` and `fetcher.sh`
- Language detection: `$LANG` → strip `.UTF-8` → strip `_BR`/`_US` → lowercase → source `{lang}.sh`; fallback to `en.sh`
- `LANG` injected into systemd via `Environment="LANG=${LANG}"` in the `.service` file (set at deploy time)
- Inline fallbacks via `${VAR:=value}` for first-run before `--install`
- To add a language: `cp src/i18n/en.sh src/i18n/XX.sh` → translate → add placeholder in `install_or_update` → update `build.sh`

---

## Implemented features

### Menu (src/main.sh)

#### Main menu

| # | Option | Handler |
| --- | --- | --- |
| 1 | ⬇️ Download new image now | `fetch_and_apply_wallpaper` |
| 2 | 🎲 Random image from gallery | `go_random_image` |
| 3 | ➡️ Next image in gallery | `go_next_image` |
| 4 | ⬅️ Previous image in gallery | `go_prev_image` |
| 5 | ⚙️ Settings | `menu_settings` (submenu) |
| 6 | 🔧 Maintenance | `menu_maintenance` (submenu) |
| 7 | 🚪 Exit | `break` |

Header shows: gallery folder, interval, overlay state (ON/OFF), timer state (active/paused).

#### Settings submenu — deferred save pattern

`_WL_CONFIG_DIRTY=false` reset on entry. Each `set_*` updates the in-memory variable and sets the flag but does **not** call `save_config`. On exit: if dirty → ask user → `save_config + deploy_services`.

| # | Option | Handler | Variable |
| --- | --- | --- | --- |
| 1 | 📂 Gallery folder | `set_gallery_dir` | `DEST_DIR` |
| 2 | ⏱️ Update interval | `set_update_interval` | `INTERVAL` |
| 3 | 🌍 Image sources | `set_image_sources` | `SOURCES` |
| 4 | 🔑 NASA API Key | `set_apod_api_key` | `APOD_API_KEY` |
| 5 | 🖼️ Gallery limit | `set_gallery_max` | `GALLERY_MAX_FILES` |
| 6 | 🎨 Title overlay (ON/OFF) | `set_overlay_toggle` | `SHOW_OVERLAY` |
| 7 | 🚪 Exit | — | triggers apply prompt if dirty |

#### Maintenance submenu

| # | Option | Handler |
| --- | --- | --- |
| 1 | ⏸️/▶️ Pause / Resume timer | `toggle_timer` — dynamic label |
| 2 | 🧹 Clean gallery | `clean_gallery` |
| 3 | 🗑️ Remove WayLume | `uninstall` |

#### Gallery navigation

`_gallery_navigate(next|prev|random)` in `main.sh`:

- Filenames `waylume_YYYYMMDD_HHMMSS.jpg` → alphabetical sort = chronological order
- Current gallery file read via `waylume-fetch --get-current-gallery` — returns original gallery path even when DE wallpaper points to the temp overlay display file (`waylume_display.jpg`)
- Circular index with modulo arithmetic; `go_next_image()`, `go_prev_image()`, `go_random_image()` are thin one-line wrappers
- Navigation applies via `waylume-fetch --set-wallpaper "$TARGET"` — composites overlay at display time

### Fetcher (src/fetcher.sh)

- **Sources:** `Bing`, `Unsplash`, `APOD`, `Wikimedia`, `Local` — comma-separated in `SOURCES`; `Local` rotates gallery offline
- **Daily cap:** Bing, APOD, Wikimedia download once/day; `_wl_daily_cap()` helper; Unsplash capped since 2026-04-04
- **Persisted state (`waylume.state`):** `APOD_LAST_DATE`, `BING_LAST_DATE`, `UNSPLASH_LAST_DATE`, `WIKIMEDIA_LAST_DATE`, `CURRENT_GALLERY`
- **Overlay architecture:** gallery files stored clean; each image has a `${file}.title` sidecar (written after `process_image`); `_wl_make_display_image()` composites overlay onto `~/.cache/waylume/waylume_display.jpg` at display time only; `SHOW_OVERLAY` controls it
- **`CURRENT_GALLERY`:** active gallery file path tracked in state; set by `_wl_make_display_image()`; persisted by `save_state()`; read back via `--get-current-gallery`; needed because with overlay on, DE stores the temp display path, not the gallery file
- **`prune_gallery`:** uses `CURRENT_GALLERY` (not `_wl_get_current_wallpaper`) to protect the active file; also deletes `.title` sidecar alongside the image
- **Unsplash:** `curl -D` captures `Picsum-ID` header → `/id/{id}/info` → real author name in title
- **Wikimedia POTD:** 2-step API; Python3 decodes `\uXXXX` Unicode escapes in filename before `--data-urlencode`
- **API errors:** rate limit / invalid key → notify + local gallery + mark date (avoids hammering API)
- **APOD:** uses `url` (960px); `hdurl` (4K) is opt-in (future roadmap item)

### CLI modes of waylume-fetch

| Flag | Purpose |
| --- | --- |
| `--random` | Pick random gallery image and apply (overlay at display time) |
| `--set-wallpaper PATH` | Apply PATH; composite overlay; save state |
| `--get-current-wallpaper` | Print DE's wallpaper path (may be temp display file) |
| `--get-current-gallery` | Print original gallery file from `CURRENT_GALLERY` in state |
| *(no flag)* | Download from a configured source and apply |

### Fixed bugs

| Session | Bug | Fix |
| --- | --- | --- |
| 2026-05-13 | `run_with_progress` — fd 3 herdado por subprocess do fetcher → zenity nunca recebia EOF → app travado | `"$@" 3>&- &`: fd 3 fechado no subprocess antes do fork |
| 2026-05-13 | `_wl_check_timeout` — `exit 0` em timeout mascarava falha | Alterado para `exit 1`; RC correto propagado |
| 2026-05-13 | `validate_image` — `exit 0` em MIME inválido mascarava falha | Alterado para `exit 1` |
| 2026-05-13 | `fetch_and_apply_wallpaper` — diálogo de sucesso exibido incondicionalmente | `if run_with_progress ...; then yad_info ...` |
| 2026-05-17 | `_gallery_navigate` — usava `--get-current-wallpaper`; com overlay ativo DE guarda temp file → never found in array → navegação sempre recomeçava do índice 0 | Novo CLI mode `--get-current-gallery`; `_wl_make_display_image()` seta `CURRENT_GALLERY`; `save_state()` persiste |
| 2026-05-17 | `prune_gallery` — proteção do wallpaper ativo usava `_wl_get_current_wallpaper`; retornava temp file → proteção nunca disparava → gallery file ativo podia ser deletado | Substituído por `CURRENT_GALLERY:-$(_wl_get_current_wallpaper)` |
| 2026-05-17 | Overlay baked in no arquivo da galeria — `process_image` compunha overlay no arquivo armazenado; impossível ligar/desligar sem re-download; JPEG re-encodado na navegação | `process_image` só faz resize/crop; sidecar `.title` por imagem; overlay composited ao display time por `_wl_make_display_image()` |
| 2026-05-18 | `set_overlay_toggle` — alternar `SHOW_OVERLAY` não re-aplicava o wallpaper atual; mudança só visível na **próxima** troca | `save_config` chamado imediatamente; `waylume-fetch --set-wallpaper "$(--get-current-gallery)"` re-aplica a imagem ativa; `yad_info` bloqueante substituído por `notify-send`; `_WL_CONFIG_DIRTY` não setado (sem restart de serviço necessário) |
| 2026-05-20 | `set_gallery_dir` — diálogo de seleção de pasta nunca abria; `zenity --file-selection --directory` não suporta `--ok-label`/`--cancel-label` → exit 255 silencioso | Removido `"${YAD_BTN_OKC[@]}"` da chamada; file chooser usa botões nativos |
  | 2026-05-20 | `install_or_update` (fresh install) — `deploy_services` nunca chamado no branch `IS_UPDATE=false` → fetcher script e timer nunca gerados na 1ª instalação | Adicionado `load_config; deploy_services` ao branch `else` |
  | 2026-05-20 | `save_config` / `save_state` — escrita não-atômica: arquivo truncado antes de completar → crash entre truncate e write → config/state zerado; usuário perde `DEST_DIR` e datas | Escrita via `.tmp` + `mv` atômico em ambas as funções |
---

## Default configuration

```bash
# ~/.config/waylume/waylume.conf
DEST_DIR="$(xdg-user-dir PICTURES)/WayLume"  # fallback: $HOME/Pictures/WayLume
INTERVAL="1h"
SOURCES="Unsplash"
APOD_API_KEY="DEMO_KEY"
GALLERY_MAX_FILES=60
SHOW_OVERLAY="true"
```

> ⚠️ For publishing/testing on another machine, use `DEMO_KEY` (limit: 30 req/hour).

---

## LinuxToys integration

- **PR:** <https://github.com/psygreg/linuxtoys/pull/399> (open, awaiting review)
- **Fork:** <https://github.com/andrecavalcantebr/linuxtoys> → branch `feat/add-waylume`
- **Files added:** `p3/scripts/utils/waylume.sh` (nocontainer), `waylume.svg`, `p3/libs/lang/{en,pt}.json` (`waylume_desc` key)
- **Auto-update:** LinuxToys script points to `raw.githubusercontent.com/andrecavalcantebr/waylume/main/waylume.sh` — every `build.sh + git push` updates what LinuxToys installs

---

## Open issues

### Functionality

- **No thumbnail in menu** — user doesn't see the current wallpaper; only filename via `notify-send`
- **APOD low resolution** — `url` (~960px) used for speed; `hdurl` (4K) never offered (roadmap v1.x)
- **Multiple monitors** — `process_image` uses only `head -1` monitor from `xrandr`
- **xrandr dependency** — `process_image` exits silently if `xrandr` fails (pure Wayland without XWayland)
- **`SHOW_OVERLAY` toggle re-aplica imagem nova em vez da atual** — ~~ao salvar Settings com `SHOW_OVERLAY` alterado, a lógica atual não sabe qual era a imagem ativa; o próximo wallpaper vem do ciclo normal (download / gallery), não é a mesma imagem com/sem overlay. Para corrigir: armazenar o **ID da imagem atual** (ex.: nome do arquivo sem extensão) além do `.title` sidecar; ao confirmar mudança de `SHOW_OVERLAY`, chamar `_wl_make_display_image()` sobre a imagem cujo ID está salvo → usuário vê o mesmo papel de parede, apenas com ou sem título (ver próxima sessão)~~ **RESOLVIDO** — `set_overlay_toggle()` chama `save_config` imediatamente (sem esperar confirm de saída do Settings) e então `waylume-fetch --set-wallpaper $(--get-current-gallery)`. Toggle não seta `_WL_CONFIG_DIRTY`: config já salva, sem restart de serviço necessário. `yad_info` substituído por `notify-send`.

### Security

- **`grep -oP` JSON parsing** — not real parsing; malicious API response could inject unexpected output. Risk is low after `IMG_TITLE` sanitisation (`%%` escaping + C0 stripping), since injected value no longer reaches ImageMagick unfiltered. Proper fix (`jq` or `python3 json.loads`) not justified at this scale; revisit if `jq` becomes a declared dependency.

---

## ⛔ Série 1.x encerrada — conhecidos bugs remanescentes (não serão corrigidos)

> A série 1.x está congelada em v1.8.0. Não serão adicionadas features nem corrigidos os itens abaixo. Eles serão resolvidos na arquitetura 2.x.

| ID | Componente | Descrição | Impacto |
|---|---|---|---|
| F2 | `fetcher.sh` | `process_image` roda sobre rotações locais da galeria — re-encoda JPEG in-place a cada hora | Degradação acumulada com uso intenso da source "Local" |
| S1 | `main.sh` | `set_gallery_dir` não valida o caminho: `prune_gallery` pode deletar fotos pessoais se o usuário escolher um dir que já tem imagens `.jpg`/`.png` | **Não use diretório com fotos pessoais como galeria** |
| S2 | `main.sh` | FIFO de progresso criado via `mktemp -u /tmp/...` — TOCTOU race entre geração do nome e `mkfifo` | Improvável em prática; sem exploração conhecida |
| Q1 | `main.sh` | `_gallery_navigate` chama `waylume-fetch` por nome, não por `$FETCHER_SCRIPT` | Falha silenciosa se `~/.local/bin` não está no `$PATH` |

---

## Next session priorities — início da série 2.x

> See also: [ROADMAP.md](ROADMAP.md) — strategic analysis, competitive comparison, and full roadmap.

**Objetivo do v2.0:** mesma paridade de features do v1.8, sobre arquitetura nova. Sem features novas até o 2.0 estar estável.

1. **Arquitetura `.waylume.db`** — fundação da série 2.x
   - Schema TSV: `id \t filename \t title \t source \t date_iso`
   - Funções: `db_add`, `db_list`, `db_remove_by_id`, `db_get_by_index`
   - Escrita atômica: `.waylume.db.tmp` + `mv`
   - Migração one-shot de galerias existentes (lê `*.title` sidecars → popula db)
2. **Modularização** — `src/sources/` (bing.sh, unsplash.sh, apod.sh, wikimedia.sh, local.sh); `src/lib/` (config.sh, gallery.sh, ui.sh)
3. **`prune_gallery` via db** — apaga apenas arquivos registrados; resolve S1 definitivamente
4. **`_gallery_navigate` via db** — índice real; resolve Q1 e habilita posição "Imagem 3 de 47"
5. **Favoritos/lixo** — campo `status` no db (`normal`/`favorite`/`trash`); trivial com fundação certa
6. **Validação de caminho** — `set_gallery_dir` aceita apenas subdirs de `$HOME`; resolve S1 como medida adicional

---

## Consolidated architecture decisions

| Decision | Rationale |
| --- | --- |
| `waylume.sh` is a single distributed artifact | Preserves "Unix Way": `curl .../waylume.sh \| bash` works; required for LinuxToys `# nocontainer` integration |
| `src/` holds development sources | Syntax highlighting, shellcheck, standalone testability |
| `.desktop`, `.service`, `.timer` as heredocs in `src/main.sh` | Depend on variables interpolated at deploy time (`$INTERVAL`, `$FETCHER_SCRIPT`) |
| Multi-DE helpers in `fetcher.sh`, called via CLI flags from `main.sh` | `fetcher.sh` owns all wallpaper set/get logic; `main.sh` never calls `_wl_set_wallpaper` directly |
| Overlay composited at display time, not baked in gallery file | Gallery files stay clean; overlay toggles instantly; avoids JPEG re-encoding on navigation; sidecar `.title` decouples metadata from image |
| `CURRENT_GALLERY` key in `waylume.state` (not a separate file) | Consistent with existing state architecture; no new file proliferation; `_wl_read_keyval` whitelist already in place |
| `_wl_read_keyval()` whitelist parser (no `eval`, no `source`) | Prevents arbitrary code execution if conf/state files are tampered |
| `case` dispatch for sources (not dynamic function name) | `"fetch_${SELECTED_SOURCE,,}"` would resolve to arbitrary function names; `case` limits to 4 known values |
| `src/main.sh` not split yet | Global-state coupling manageable at ~780 lines; split into `src/lib/` warranted at ~900+ lines or first external contributor |
| `src/fetcher.sh` not split into `src/sources/` yet | 4 sources, 1 maintainer; split warranted at 5+ sources or when contributors ask "where is source X?" |
| i18n via `.sh` files (not gettext) | No external dependencies; compatible with single distributed file |
| `SHOW_OVERLAY` default `true` | Overlay agrega contexto (fonte, título); usuários que preferem imagem limpa desativam via Settings |
| APOD uses `url` (960px) | `hdurl` (4K) caused 30s+ downloads with no perceptible visual gain on a wallpaper |
| XFCE uses `xfconf-query` property enumeration | Enumerating existing `last-image` properties solves multi-monitor automatically; no monitor name guessing |
| `build.sh` (bash + inline Python) as build tool | Works; evolve to `Makefile + tools/assemble.py` when modularising |
