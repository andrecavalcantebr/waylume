# WayLume — Roadmap & Critical Analysis

> Last updated: 2026-05-12 · Based on v1.7.0

---

## 1. Positioning

WayLume fills a genuinely empty niche: a wallpaper manager with multiple curated online sources, **zero idle RAM**, native Wayland support, and frictionless installation. No competing tool has this exact combination.

It was born from a real gap left by Variety, which suffers from persistent instability under Wayland, while native GNOME Shell extensions are limited to a single source (Bing) and break on every major GNOME Shell release.

---

## 2. Competitive Landscape

### Tools evaluated

| Tool | Stars | Language | Status |
| --- | --- | --- | --- |
| [Variety](https://github.com/varietywalls/variety) | 1,600 | Python 3 | ⚠️ Maintenance mode |
| [Bing GNOME Extension](https://github.com/neffo/bing-wallpaper-gnome-extension) | 358 | JavaScript | ✅ Active |
| [Wallutils](https://github.com/xyproto/wallutils) | 516 | Go | ✅ Active |
| [HydraPaper](https://gitlab.com/gabmus/hydrapaper) | 177 | Python + GTK | ⚠️ Sporadic |
| **WayLume** | — | Bash | ✅ Active |

### Feature comparison

| Feature | WayLume | Variety | Bing Ext. | Wallutils |
| --- | --- | --- | --- | --- |
| Idle RAM usage | ✅ Zero | ❌ ~30 MB | ❌ (Shell ext.) | ✅ Zero |
| Native Wayland (wallpaper) | ✅ `gsettings` | ⚠️ Unstable | ✅ Native | ✅ Yes |
| Native Wayland (GUI) | ✅ zenity 4.x GTK4 (v1.7.0) | ⚠️ Unstable | ✅ Native | ❌ CLI only |
| Graphical UI | ✅ yad | ✅ GTK app | ✅ GNOME native | ❌ CLI only |
| Online sources | 4 curated | 10+ (Wallhaven, Reddit…) | 1 (Bing only) | 0 (local only) |
| Local folder as source | ✅ (v1.6.0) | ✅ | ❌ | ✅ |
| Gallery curation (fav/trash) | ❌ | ✅ | ✅ | N/A |
| Multi-monitor support | ❌ (head -1) | ✅ | ✅ | ✅ |
| Title overlay | ✅ (toggleable) | ✅ (quotes/clock) | ❌ | ❌ |
| Timer pause/resume | ✅ (Maintenance menu) | ✅ (tray icon) | ✅ | N/A |
| Distro packages | ❌ | ✅ apt/dnf/pacman | GNOME Extensions | ✅ Arch (pacman) |
| Installation friction | ⭐ Minimal | ⚠️ Python venv | ⭐ Extension manager | ⚠️ Compile Go |
| Active maintenance | ✅ | ⚠️ | ✅ | ✅ |

### Notes on each competitor

**Variety** is the de-facto standard for X11 — a full Python daemon with tray icon, 10+ sources, Ken Burns filters, and multi-DE support. Now in _maintenance mode_ since 2024. Installation complexity (virtualenv + pip) and Wayland instability are its biggest obstacles. WayLume starts from where Variety stumbles.

**Bing GNOME Extension** (neffo) is the most _integrated_ GNOME solution for Bing-only users. It has a visual gallery, favorites, trash, menu preview, 20+ languages, and lockscreen blur — all via native Shell extension. Downsides: breaks on every GNOME major release (it depends on internal GNOME Shell APIs), only one source, and any Shell API change affects it.

**Wallutils** is a CLI toolbox without a GUI or online sources, focused on timed wallpapers (macOS-style) and multi-monitor support. Its strongest point — native multi-monitor on Wayland — is WayLume's largest gap.

**HydraPaper** solves a different problem: setting independent wallpapers per monitor on GNOME. Sporadically maintained; valuable as a reference for multi-monitor implementation.

---

## 3. Strengths

1. **Zero-idle architecture** — the only GUI competitor that consumes no RAM in the background. Systemd as a scheduler is elegant and robust (`Persistent=true` recovers missed runs).
2. **Real Wayland-first** — uses `gsettings` directly, no compositor-specific hacks, no screen pointer.
3. **High-quality curated sources** — APOD, Bing, Wikimedia POTD are editorial selections, not generic stock photos. Unique combination among competitors.
4. **Frictionless distribution** — `curl .../waylume.sh | bash` + LinuxToys. No compiler, no virtualenv, no package manager lock-in.
5. **Active security posture** — `_wl_read_keyval` whitelist parser, hardcoded `case` for source dispatch, ImageMagick input sanitisation. Uncommon in shell script projects.
6. **Real i18n** — PT/EN with automatic locale detection. Extremely rare at this project scale.
7. **Actively maintained and versioned** — unlike Variety.

---

## 4. Weaknesses and Risks

### Architecture

- **yad requires X11/XWayland — a direct contradiction with WayLume's core positioning.** WayLume's wallpaper backend (`gsettings`) is Wayland-native, but the GUI frontend forces `export GDK_BACKEND=x11` and depends entirely on XWayland. On purely-native Wayland sessions without XWayland (e.g. Fedora Silverblue, systems with `--disable-xwayland`), WayLume's UI fails entirely. This is the most critical architectural gap: an app marketed as Wayland-native with an X11-dependent interface. The `xrandr` call in `process_image` shares the same problem. See **Section 8** for the full technical analysis and migration path to `zenity`.
- **Single monitor only (`head -1`).** In multi-monitor setups, the image is processed for the first monitor's resolution. If monitors have different resolutions, the second one displays the image incorrectly cropped.
- **Bash as the sole language** imposes real limits: no real JSON parsing (using `grep -oP`), no complex data structures, no unit testing. With 5+ sources, this fragility starts to hurt.

### User Experience

- **No gallery curation** — no favorites or trash system. A user can't tell WayLume "never show this image again" without manually deleting the file.
- **Blind gallery navigation** — no thumbnail preview, no position indicator ("3 of 47"). The user has no sense of where they are in the gallery.
- ~~**No timer pause/resume**~~ — **Fixed in v1.6.0:** ⏸️/▶️ toggle in the Maintenance submenu runs `systemctl --user stop/start waylume.timer`. Timer state shown in the main menu header.
- **Overlay is baked into the image** — when an image enters the gallery, the overlay is already rendered. If the user disables the overlay later, old images still have it; new ones don't. This creates visual inconsistency when navigating the gallery.
- ~~**No local folder source**~~ — **Fixed in v1.6.0:** "Local" added as a source option in Settings; when selected, the timer rotates the existing gallery offline, with no download.

### Ecosystem and Distribution

- **No distro package** — installing via `curl | bash` is fine for developers, but is a barrier for LinuxToys' target audience (newcomers). A `.deb` or AUR package would greatly expand reach.
- **Unsplash via Picsum** — Picsum is an unofficial Unsplash proxy. It may change its API, impose rate limits, or shut down without notice.
- **APOD at 960px** — a limitation on 4K/HiDPI displays. The `hdurl` (full resolution) was discarded for speed, but an opt-in quality setting would be desirable.
- **No GitHub Releases** — no versioned `.tar.gz` tarball for users who don't want to use git, which makes third-party packaging harder.

---

## 5. Roadmap

### v1.x — Stability and consolidation (current track)

These require no architectural changes and fit the current single-file model.

| Priority | Feature | Rationale |
| --- | --- | --- |
| ✅ Done | Timer pause/resume from menu | **Implemented in v1.6.0.** ⏸️/▶️ toggle in Maintenance submenu; timer state shown in main menu header. |
| ✅ Done | Local folder as wallpaper source | **Implemented in v1.6.0.** "Local" checkbox in Sources; timer rotates gallery offline; no download, no re-processing. |
| 🟠 Medium | Gallery favorite/trash system | Allows curation; mirrors Variety and Bing Ext.; prevents unwanted images from reappearing |
| 🟠 Medium | Position indicator in gallery navigation | "Image 3 of 47" in notify-send costs nothing and greatly improves UX |
| 🟠 Medium | Overlay applied at display time, not baked in | Store the original image; apply overlay only at `apply_wallpaper` time via a temp file; eliminates inconsistency |
| 🟡 Low | Optional APOD hdurl (4K) | Opt-in setting for HiDPI users; download size trade-off clearly communicated |
| 🟡 Low | Wallhaven as a source | Largest community wallpaper repository; public API with content filters |
| 🟡 Low | Thumbnail preview in main menu | `convert -thumbnail` to generate temp file; display mechanism depends on GUI backend chosen (zenity or GTK4 Python) |
| ✅ Done | Multi-DE support: GNOME, MATE, Cinnamon, KDE Plasma, XFCE | **Implemented in v1.5.0.** `_wl_set_wallpaper` / `_wl_get_current_wallpaper` helpers dispatch via `XDG_CURRENT_DESKTOP`; XFCE uses `xfconf-query` with automatic multi-monitor enumeration. |

### v2.x — Distribution and packaging

| Priority | Feature | Rationale |
| --- | --- | --- |
| 🔴 High | AUR package (`waylume`) | Immediate reach on Arch/Manjaro/EndeavourOS; easiest packaging path |
| 🔴 High | GitHub Release with versioned tarball | Enables third-party packaging and reproducible installs |
| 🟠 Medium | Debian/Ubuntu `.deb` package | Covers the largest Linux user base |
| 🟠 Medium | Makefile + `tools/assemble.py` as build tool | Natural evolution when modularising sources; `make` is the canonical tool for multi-source artifact builds |

### v3.x — Architecture evolution

> Trigger: 5+ sources, or first external contributor.

| Priority | Feature | Rationale |
| --- | --- | --- |
| ✅ Done | **Replace yad with zenity 4.x (Wayland-native GUI)** | **Implemented in v1.7.0.** `export GDK_BACKEND=x11` removed. All dialogs migrated to zenity 4.0.1 (GTK4+libadwaita). GUI is now fully Wayland-native — no XWayland dependency. |
| 🟠 Medium | `src/sources/` modularisation | Each source in its own file; clear interface contract; enables external contributions |
| 🟠 Medium | Multi-monitor support | Detect all connected resolutions via `gdbus`/GSettings or Wayland protocol; one image per monitor |
| 🟡 Low | GTK4 Python helper (if WM_CLASS/icon needed) | Only option that preserves `--class=WayLume` taskbar integration; ~200 lines embedded via `##PLACEHOLDER##` mechanism; high effort |
| 🟡 Low | `jq` as a declared dependency | Enables real JSON parsing; eliminates `grep -oP` fragility across all `fetch_*` functions |

---

## 6. Multi-desktop Support — Implementation (v1.5.0)

Multi-DE support was implemented in v1.5.0. All `gsettings` calls are now routed through two helpers in `src/fetcher.sh`, and gallery navigation in `src/main.sh` uses them via the `--set-wallpaper` / `--get-current-wallpaper` CLI flags.

### 6.1 Implemented changes

| File | Function | Change |
| --- | --- | --- |
| `src/fetcher.sh` | `_wl_set_wallpaper()` _(new)_ | `case $XDG_CURRENT_DESKTOP` dispatcher — GNOME, ubuntu:GNOME, MATE, X-Cinnamon, KDE, XFCE, fallback |
| `src/fetcher.sh` | `_wl_get_current_wallpaper()` _(new)_ | Per-DE read-back; returns empty string for KDE (no clean CLI) |
| `src/fetcher.sh` | `apply_wallpaper()` | Replaced 2 `gsettings` lines with `_wl_set_wallpaper "$TARGET"` |
| `src/fetcher.sh` | `prune_gallery()` | Replaced `gsettings get` with `_wl_get_current_wallpaper` |
| `src/fetcher.sh` | MAIN section | Added `--set-wallpaper <path>` and `--get-current-wallpaper` CLI flags |
| `src/main.sh` | `_gallery_navigate()` | Replaced inline `gsettings get/set` with `waylume-fetch --get-current-wallpaper` / `--set-wallpaper` |
| `src/main.sh` | `pin/unpin_from_favorites()` | Guard: `[[ "$XDG_CURRENT_DESKTOP" =~ ^(GNOME\|ubuntu:GNOME)$ ]] \|\| return` |

### 6.2 Supported desktops

| Desktop | Set mechanism | Read-back |
| --- | --- | --- |
| GNOME / ubuntu:GNOME | `gsettings set org.gnome.desktop.background picture-uri` + `picture-uri-dark` | `gsettings get` |
| MATE | `gsettings set org.mate.background picture-filename` (no `file://`) | `gsettings get` |
| X-Cinnamon | `gsettings set org.cinnamon.desktop.background picture-uri` + `picture-uri-dark` | `gsettings get` |
| KDE Plasma ≥ 5.26 | `plasma-apply-wallpaperimage "$TARGET"` | None — gallery starts from first image |
| XFCE | `xfconf-query` — enumerates all existing `last-image` properties (multi-monitor automatic); falls back to `xrandr` monitor name on fresh install | `xfconf-query` first `last-image` property |
| Unknown DEs | Best-effort GNOME schema (`2>/dev/null \|\| true`) | — |

**Resolution detection for KDE:** `xrandr` works on X11 sessions. On Wayland: `kscreen-doctor --outputs | grep -oP 'Modes:.*?\K[0-9]+x[0-9]+'` as fallback, or expose a manual resolution setting in WayLume's config.

#### Tier 3 — Complex or niche DEs (future, v2.x+)

Document as known limitations for now. **XFCE has been promoted from Tier 3 to supported in v1.5.0** — the "monitor name varies per system" blocker was resolved by enumerating existing `xfconf-query` properties instead of guessing names.

| Desktop | Command | Blocker |
| --- | --- | --- |
| **Xfce** | `xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor{N}/workspace0/last-image -s "$TARGET"` | Monitor name varies per system; multi-monitor = multiple INI paths |
| **LXDE** | `pcmanfm --set-wallpaper "$TARGET"` | Requires pcmanfm running; display variable issues |
| **LXQt** | `pcmanfm-qt --set-wallpaper "$TARGET"` | Same as LXDE |
| **Sway** | `swaybg -i "$TARGET" -m fill` | Requires a background process; conflicts with systemd oneshot model |
| **Hyprland** | `hyprctl hyprpaper wallpaper ",${TARGET}"` | Requires hyprpaper daemon; config file dependency |

### 6.3 Recommended implementation structure

### 6.3 Known limitations after v1.5.0

| Desktop | Limitation |
| --- | --- |
| KDE Plasma | No gallery read-back — `_wl_get_current_wallpaper` returns empty; gallery navigation starts from the first image |
| KDE Plasma < 5.26 | `plasma-apply-wallpaperimage` not available; documented as unsupported |
| Sway / Hyprland | Require a background process (`swaybg`, `hyprpaper`) — conflicts with the systemd oneshot model |
| Xfce multi-monitor (fresh install) | First run with no prior wallpaper configured: only the primary monitor (`xrandr head -1`) receives the wallpaper; subsequent runs update all monitors normally |

---

## 7. Positioning Summary

WayLume's competitive advantage is **architectural**: it solves the Wayland stability problem not by patching a daemon, but by eliminating the daemon entirely. This advantage holds as long as:

1. GNOME remains the primary Wayland desktop (strong: GNOME is the default on Fedora, Ubuntu, Debian)
2. Systemd remains the init system on target distros (strong: all major distros)
3. **The GUI backend becomes truly Wayland-native** (currently a gap — see Section 8)

The path to wide adoption runs through **packaging** (`.deb`, AUR), the **local folder source**, and — crucially — **eliminating the XWayland dependency from the GUI**. The last item is the most important for WayLume's credibility as a Wayland-first project.

---

## 8. GUI Backend: yad → Wayland-native (Technical Analysis)

> Analysed: 2026-05-12

### 8.1 The problem

WayLume forces `export GDK_BACKEND=x11` in `src/main.sh` because `yad` has no native Wayland window-class support. This means:

- The **entire GUI requires XWayland** to function
- On Fedora Silverblue, immutable distros, and any session with `--disable-xwayland`, WayLume's UI is completely broken
- WayLume markets itself as Wayland-native while its most visible component (the GUI) is X11-only
- The `xrandr` call in `process_image` (resolution detection) has the same XWayland dependency

### 8.2 Candidates evaluated

| Candidate | Wayland-native | Bash subprocess | All dialog types | Pre-installed GNOME | Dep weight | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| **zenity 4.x** (GTK4+libadwaita) | ✅ | ✅ | ✅ (with workarounds) | ✅ Ubuntu/Fedora | ~2 MB | **✅ Primary** |
| kdialog | ✅ | ✅ | ✅ | ❌ KDE only | ~150 MB | ❌ ruled out |
| qarma | ✅ | ✅ | ✅ | ❌ AUR only | ~80 MB | ❌ ruled out |
| XDG Portal (`gdbus`) | ✅ | ❌ async D-Bus | ❌ no list/scale | ✅ daemon | 0 | ❌ not a dialog API |
| GTK4 Python inline | ✅ | ✅ | ✅ full parity | ❌ needs `python3-gi` | ~15 MB | ✅ Secondary (high effort) |
| gum (TUI) | N/A | ✅ | ✅ | ❌ | ~5 MB | ❌ no GUI context (`Terminal=false`) |

### 8.3 Recommended path: zenity 4.x

`zenity` (GNOME official, GTK4 ≥ 4.x, libadwaita) is Wayland-native by default — GTK4 auto-selects `WAYLAND_DISPLAY` without any `GDK_BACKEND` override. It is pre-installed on Ubuntu 22.04+ and Fedora 37+ GNOME images, and available as `apt install zenity` / `dnf install zenity` elsewhere.

#### Dialog type mapping

| WayLume usage | yad flag | zenity 4.x equivalent |
| --- | --- | --- |
| Info/error messages | `--info`, `--error` | `--info`, `--error` ✅ identical |
| Yes/no questions | `--question` | `--question` ✅ identical |
| Text entry | `--entry --entry-text=VAL` | `--entry --entry-text=VAL` ✅ identical |
| Directory picker | `--file --directory` | `--file-selection --directory` ✅ |
| Interval picker | `--list --radiolist` | `--list --radiolist` ✅ |
| Sources picker | `--list --checklist` | `--list --checklist --separator=,` ✅ |
| Gallery limit | `--scale --min-value --max-value --step` | `--scale --min-value --max-value --step` ✅ |
| Main/settings menus | `--list --hide-column --print-column` | `--list --hide-column --print-column` ✅ |
| Pulsate progress | `--progress --pulsate --no-buttons` | `--progress --pulsate --no-cancel` ⚠️ needs open stdin |
| Column header hide | `--no-headers` | `--hide-header` ⚠️ flag renamed |

#### Migration delta — items requiring code changes

**a) Remove `GDK_BACKEND=x11` override** — drop entirely.

**b) Progress dialog** — zenity requires open stdin to stay alive (unlike yad's PID-kill approach). The implemented solution uses a named FIFO to animate 0 → 98% and trigger `--auto-close` at 100. The background task has fd 3 closed (`3>&-`) to prevent the write-end of the pipe being inherited by child processes (`curl`, `convert`, etc.), which would block zenity from ever receiving EOF:

```bash
run_with_progress() {
    local MSG="$1"; shift
    local FIFO RC
    FIFO=$(mktemp -u /tmp/wl_progress_XXXXXX)
    mkfifo "$FIFO"
    _zenity --progress --no-cancel --auto-close \
        --title="WayLume" --text="$MSG" --width=380 < "$FIFO" &
    local ZPID=$!
    exec 3>"$FIFO"          # open write-end; unblocks zenity's stdin open
    rm -f "$FIFO"           # unlink path; fd 3 keeps the pipe alive
    echo "0" >&3            # 0% -> OK disabled

    "$@" 3>&- &             # run task; close fd 3 so child never holds the pipe
    local TPID=$!

    local pct=0             # animate 0->98% while task runs
    while kill -0 "$TPID" 2>/dev/null; do
        [ "$pct" -lt 98 ] && pct=$(( pct + 2 ))
        echo "$pct" >&3
        sleep 0.25
    done

    wait "$TPID"; RC=$?
    echo "100" >&3          # triggers --auto-close
    exec 3>&-
    wait "$ZPID" 2>/dev/null
    return $RC
}
```

**Note:** `_wl_check_timeout` (curl timeout) and `validate_image` (bad MIME) exit with RC=1, not RC=0, so `run_with_progress` correctly propagates failure to callers.

**c) Button labels** — zenity supports only `--ok-label` / `--cancel-label` (always exactly 2 buttons). Current `YAD_BTN_*` presets map cleanly:
- `YAD_BTN_OK` → `--ok-label="$BTN_OK"`
- `YAD_BTN_YN` → `--ok-label="$BTN_YES" --cancel-label="$BTN_NO"`
- `YAD_BTN_OKC` → `--ok-label="$BTN_OK" --cancel-label="$BTN_CLOSE"`

All current exit-code checks (`[ $? -eq 0 ]` / `[ $? -ne 0 ]`) remain valid — OK=0, Cancel=1.

**d) `--class=WayLume` and `--window-icon`** — zenity has no equivalent. The dialog window appears under the "zenity" app name in the taskbar instead of WayLume. This is a cosmetic regression, acceptable for the Wayland migration. If WM_CLASS integration must be preserved, the GTK4 Python path (see 8.4) is the only alternative.

**e) `--borders=10`** — drop; libadwaita provides its own spacing defaults.

**f) `--no-headers` → `--hide-header`** — flag rename throughout.

**g) `xrandr` in `process_image`** — replace with `gdbus call --session --dest org.gnome.Mutter.DisplayConfig ...` or expose a manual resolution setting in WayLume's config for non-GNOME DEs.

#### Dependency check command (to add to `check_dependencies`)

```bash
command -v zenity &>/dev/null || _wl_install_pkg zenity
```

### 8.4 Secondary path: GTK4 Python helper

If `--class=WayLume` taskbar integration must be preserved, the only Wayland-native option is a small embedded Python GTK4 helper, embedded via the same `##PLACEHOLDER##` mechanism already used for `fetcher.sh` and the i18n bundles.

- **New placeholder:** `##WL_DIALOG_PY##` in `src/main.sh`, replaced by `src/wl_dialog.py`
- **Interface:** `python3 "$CONFIG_DIR/wl_dialog.py" <type> [args...]` — prints result to stdout, exits 0/1
- **Scope:** ~200 lines covering all 10 dialog types used by WayLume
- **Deps:** `python3-gi`, `gir1.2-gtk-4.0`, `gir1.2-adw-1` — in main repos, ~15 MB on GNOME
- **Effort:** High. Recommended only if zenity's cosmetic gaps are unacceptable after migration.

### 8.5 Decision

**Adopt zenity 4.x as the target GUI backend for v3.x.** The migration is incremental — each `yad_*` wrapper function in `src/main.sh` can be updated independently. The cosmetic loss of `--class=WayLume` is acceptable. The gain — a truly Wayland-native interface — is essential to WayLume's credibility.
