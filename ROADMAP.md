# WayLume — Roadmap & Critical Analysis

> Last updated: 2026-04-30 · Based on v1.5.0

---

## 1. Positioning

WayLume fills a genuinely empty niche: a wallpaper manager with multiple curated online sources, **zero idle RAM**, native Wayland support, and frictionless installation. No competing tool has this exact combination.

It was born from a real gap left by Variety, which suffers from persistent instability under Wayland, while native GNOME Shell extensions are limited to a single source (Bing) and break on every major GNOME Shell release.

---

## 2. Competitive Landscape

### Tools evaluated

| Tool | Stars | Language | Status |
|---|---|---|---|
| [Variety](https://github.com/varietywalls/variety) | 1,600 | Python 3 | ⚠️ Maintenance mode |
| [Bing GNOME Extension](https://github.com/neffo/bing-wallpaper-gnome-extension) | 358 | JavaScript | ✅ Active |
| [Wallutils](https://github.com/xyproto/wallutils) | 516 | Go | ✅ Active |
| [HydraPaper](https://gitlab.com/gabmus/hydrapaper) | 177 | Python + GTK | ⚠️ Sporadic |
| **WayLume** | — | Bash | ✅ Active |

### Feature comparison

| Feature | WayLume | Variety | Bing Ext. | Wallutils |
|---|---|---|---|---|
| Idle RAM usage | ✅ Zero | ❌ ~30 MB | ❌ (Shell ext.) | ✅ Zero |
| Native Wayland | ✅ `gsettings` | ⚠️ Unstable | ✅ Native | ✅ Yes |
| Graphical UI | ✅ yad | ✅ GTK app | ✅ GNOME native | ❌ CLI only |
| Online sources | 4 curated | 10+ (Wallhaven, Reddit…) | 1 (Bing only) | 0 (local only) |
| Local folder as source | ❌ | ✅ | ❌ | ✅ |
| Gallery curation (fav/trash) | ❌ | ✅ | ✅ | N/A |
| Multi-monitor support | ❌ (head -1) | ✅ | ✅ | ✅ |
| Title overlay | ✅ (toggleable) | ✅ (quotes/clock) | ❌ | ❌ |
| Timer pause/resume | ❌ | ✅ (tray icon) | ✅ | N/A |
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

- **yad requires X11/XWayland.** On purely-native Wayland systems without XWayland, `yad` fails silently. The `xrandr` call in `process_image` has the same problem. Future path: `zenity` (Wayland-native) or resolution detection via `gdbus`/`gsettings`.
- **Single monitor only (`head -1`).** In multi-monitor setups, the image is processed for the first monitor's resolution. If monitors have different resolutions, the second one displays the image incorrectly cropped.
- **Bash as the sole language** imposes real limits: no real JSON parsing (using `grep -oP`), no complex data structures, no unit testing. With 5+ sources, this fragility starts to hurt.

### User Experience

- **No gallery curation** — no favorites or trash system. A user can't tell WayLume "never show this image again" without manually deleting the file.
- **Blind gallery navigation** — no thumbnail preview, no position indicator ("3 of 47"). The user has no sense of where they are in the gallery.
- **No timer pause/resume** — stopping automatic wallpaper changes requires uninstalling. A menu toggle that runs `systemctl --user stop/start waylume.timer` would solve this.
- **Overlay is baked into the image** — when an image enters the gallery, the overlay is already rendered. If the user disables the overlay later, old images still have it; new ones don't. This creates visual inconsistency when navigating the gallery.
- **No local folder source** — a user with a personal photo collection cannot use it as a wallpaper source.

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
|---|---|---|
| 🔴 High | Timer pause/resume from menu | Today requires uninstalling; `systemctl --user stop/start` in the menu solves it |
| 🔴 High | Local folder as wallpaper source | Removes the dependency on internet access; covers the largest user segment |
| 🟠 Medium | Gallery favorite/trash system | Allows curation; mirrors Variety and Bing Ext.; prevents unwanted images from reappearing |
| 🟠 Medium | Position indicator in gallery navigation | "Image 3 of 47" in notify-send costs nothing and greatly improves UX |
| 🟠 Medium | Overlay applied at display time, not baked in | Store the original image; apply overlay only at `apply_wallpaper` time via a temp file; eliminates inconsistency |
| 🟡 Low | Optional APOD hdurl (4K) | Opt-in setting for HiDPI users; download size trade-off clearly communicated |
| 🟡 Low | Wallhaven as a source | Largest community wallpaper repository; public API with content filters |
| 🟡 Low | Thumbnail preview in main menu | `yad --image` + `convert -thumbnail` with no new dependency |
| ✅ Done | Multi-DE support: GNOME, MATE, Cinnamon, KDE Plasma, XFCE | **Implemented in v1.5.0.** `_wl_set_wallpaper` / `_wl_get_current_wallpaper` helpers dispatch via `XDG_CURRENT_DESKTOP`; XFCE uses `xfconf-query` with automatic multi-monitor enumeration. |

### v2.x — Distribution and packaging

| Priority | Feature | Rationale |
|---|---|---|
| 🔴 High | AUR package (`waylume`) | Immediate reach on Arch/Manjaro/EndeavourOS; easiest packaging path |
| 🔴 High | GitHub Release with versioned tarball | Enables third-party packaging and reproducible installs |
| 🟠 Medium | Debian/Ubuntu `.deb` package | Covers the largest Linux user base |
| 🟠 Medium | Makefile + `tools/assemble.py` as build tool | Natural evolution when modularising sources; `make` is the canonical tool for multi-source artifact builds |

### v3.x — Architecture evolution

> Trigger: 5+ sources, or first external contributor, or GNOME dropping XWayland support.

| Priority | Feature | Rationale |
|---|---|---|
| 🟠 Medium | `src/sources/` modularisation | Each source in its own file; clear interface contract; enables external contributions |
| 🟠 Medium | Multi-monitor support | Detect all connected resolutions via `gdbus`/GSettings or Wayland protocol; one image per monitor |
| 🟡 Low | Replace yad with zenity (or GTK4 native) | Eliminates XWayland dependency; future-proofs against GNOME dropping XWayland |
| 🟡 Low | `jq` as a declared dependency | Enables real JSON parsing; eliminates `grep -oP` fragility across all `fetch_*` functions |

---

## 6. Multi-desktop Support — Implementation (v1.5.0)

Multi-DE support was implemented in v1.5.0. All `gsettings` calls are now routed through two helpers in `src/fetcher.sh`, and gallery navigation in `src/main.sh` uses them via the `--set-wallpaper` / `--get-current-wallpaper` CLI flags.

### 6.1 Implemented changes

| File | Function | Change |
|---|---|---|
| `src/fetcher.sh` | `_wl_set_wallpaper()` *(new)* | `case $XDG_CURRENT_DESKTOP` dispatcher — GNOME, ubuntu:GNOME, MATE, X-Cinnamon, KDE, XFCE, fallback |
| `src/fetcher.sh` | `_wl_get_current_wallpaper()` *(new)* | Per-DE read-back; returns empty string for KDE (no clean CLI) |
| `src/fetcher.sh` | `apply_wallpaper()` | Replaced 2 `gsettings` lines with `_wl_set_wallpaper "$TARGET"` |
| `src/fetcher.sh` | `prune_gallery()` | Replaced `gsettings get` with `_wl_get_current_wallpaper` |
| `src/fetcher.sh` | MAIN section | Added `--set-wallpaper <path>` and `--get-current-wallpaper` CLI flags |
| `src/main.sh` | `_gallery_navigate()` | Replaced inline `gsettings get/set` with `waylume-fetch --get-current-wallpaper` / `--set-wallpaper` |
| `src/main.sh` | `pin/unpin_from_favorites()` | Guard: `[[ "$XDG_CURRENT_DESKTOP" =~ ^(GNOME\|ubuntu:GNOME)$ ]] \|\| return` |

### 6.2 Supported desktops

| Desktop | Set mechanism | Read-back |
|---|---|---|
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
|---|---|---|
| **Xfce** | `xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor{N}/workspace0/last-image -s "$TARGET"` | Monitor name varies per system; multi-monitor = multiple INI paths |
| **LXDE** | `pcmanfm --set-wallpaper "$TARGET"` | Requires pcmanfm running; display variable issues |
| **LXQt** | `pcmanfm-qt --set-wallpaper "$TARGET"` | Same as LXDE |
| **Sway** | `swaybg -i "$TARGET" -m fill` | Requires a background process; conflicts with systemd oneshot model |
| **Hyprland** | `hyprctl hyprpaper wallpaper ",${TARGET}"` | Requires hyprpaper daemon; config file dependency |

### 6.3 Recommended implementation structure

### 6.3 Known limitations after v1.5.0

| Desktop | Limitation |
|---|---|
| KDE Plasma | No gallery read-back — `_wl_get_current_wallpaper` returns empty; gallery navigation starts from the first image |
| KDE Plasma < 5.26 | `plasma-apply-wallpaperimage` not available; documented as unsupported |
| Sway / Hyprland | Require a background process (`swaybg`, `hyprpaper`) — conflicts with the systemd oneshot model |
| Xfce multi-monitor (fresh install) | First run with no prior wallpaper configured: only the primary monitor (`xrandr head -1`) receives the wallpaper; subsequent runs update all monitors normally |

---

## 7. Positioning Summary

WayLume's competitive advantage is **architectural**: it solves the Wayland stability problem not by patching a daemon, but by eliminating the daemon entirely. This advantage holds as long as:

1. GNOME remains the primary Wayland desktop (strong: GNOME is the default on Fedora, Ubuntu, Debian)
2. Systemd remains the init system on target distros (strong: all major distros)
3. XWayland remains available for yad (medium: long-term risk as pure Wayland adoption grows)

The path to wide adoption runs through **packaging** (`.deb`, AUR) and the **local folder source** — the two changes that most expand the addressable user base without requiring architectural changes.

WayLume's competitive advantage is **architectural**: it solves the Wayland stability problem not by patching a daemon, but by eliminating the daemon entirely. This advantage holds as long as:

1. GNOME remains the primary Wayland desktop (strong: GNOME is the default on Fedora, Ubuntu, Debian)
2. Systemd remains the init system on target distros (strong: all major distros)
3. XWayland remains available for yad (medium: long-term risk as pure Wayland adoption grows)

The path to wide adoption runs through **packaging** (`.deb`, AUR) and the **local folder source** — the two changes that most expand the addressable user base without requiring architectural changes.
