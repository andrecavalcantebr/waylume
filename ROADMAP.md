# WayLume — Roadmap & Analysis

> Last updated: 2026-06-03 · Current version: v2.0.0

---

## 1. Positioning

WayLume fills a genuinely empty niche: a wallpaper manager with multiple curated online sources, **zero idle RAM**, native Wayland support, and frictionless installation. No competing tool has this exact combination.

Born from the gap left by Variety — persistent Wayland instability and maintenance-mode status — and from GNOME Shell extensions limited to a single source that break on every major release.

---

## 2. Competitive Landscape

| Tool | Stars | Language | Status |
| --- | --- | --- | --- |
| [Variety](https://github.com/varietywalls/variety) | 1,600 | Python 3 | ⚠️ Maintenance mode |
| [Bing GNOME Extension](https://github.com/neffo/bing-wallpaper-gnome-extension) | 358 | JavaScript | ✅ Active |
| [Wallutils](https://github.com/xyproto/wallutils) | 516 | Go | ✅ Active |
| [HydraPaper](https://gitlab.com/gabmus/hydrapaper) | 177 | Python + GTK | ⚠️ Sporadic |
| **WayLume** | — | Bash | ✅ Active |

| Feature | WayLume | Variety | Bing Ext. | Wallutils |
| --- | --- | --- | --- | --- |
| Idle RAM | ✅ Zero | ❌ ~30 MB | ❌ (Shell ext.) | ✅ Zero |
| Wayland wallpaper | ✅ gsettings | ⚠️ Unstable | ✅ Native | ✅ |
| Wayland GUI | ✅ zenity 4.x GTK4 | ⚠️ Unstable | ✅ Native | ❌ CLI only |
| Online sources | 4 curated | 10+ | 1 (Bing) | 0 |
| Local folder | ✅ | ✅ | ❌ | ✅ |
| Gallery curation | ❌ | ✅ | ✅ | N/A |
| Multi-monitor | ❌ | ✅ | ✅ | ✅ |
| Title overlay | ✅ toggleable | ✅ | ❌ | ❌ |
| Timer control | ✅ | ✅ | ✅ | N/A |
| Distro packages | ❌ | ✅ | GNOME Ext. | ✅ Arch |
| Install friction | ⭐ Minimal | ⚠️ venv+pip | ⭐ Ext. manager | ⚠️ Go compile |

**Variety** — de-facto X11 standard. Maintenance mode since 2024; Wayland unstable.  
**Bing Extension** — best GNOME integration (favorites, trash, preview, lockscreen blur) but single source and breaks on every Shell API change.  
**Wallutils** — CLI only, no GUI, no online sources; strongest point is native multi-monitor.  
**HydraPaper** — solves independent wallpapers per monitor; useful as multi-monitor reference.

---

## 3. Strengths

1. **Zero-idle architecture** — systemd oneshot scheduler; no daemon, no background RAM. `Persistent=true` recovers missed runs.
2. **Wayland-first** — `gsettings` for wallpaper; zenity 4.x (GTK4+libadwaita) for GUI since v1.7.0.
3. **Curated sources** — APOD, Bing, Wikimedia POTD are editorial picks, not generic stock. Unique combination.
4. **Frictionless install** — `curl .../waylume.sh | bash` + LinuxToys. No compiler, no venv, no lock-in.
5. **Security posture** — `_wl_read_keyval` whitelist parser, hardcoded `case` dispatch, ImageMagick input sanitisation.
6. **Real i18n** — PT/EN with automatic locale detection.

---

## 4. Weaknesses

### Architecture

- **Single monitor** — `process_image` resizes for the first monitor only. Wrong crop on different-resolution setups.
- **`xrandr` in `process_image`** — X11 dependency for resolution detection; fails on pure Wayland without XWayland.
- **Bash limits** — no real JSON parsing (`grep -oP`), no typed structures. Fragility grows with source count.

### UX

- **No gallery curation UI** — `status` field (`normal|favorite|trash`) exists in `waylume.db` but there is no GUI to mark favorites or send to trash yet.
- **Blind navigation** — no thumbnail preview. Position indicator ("Image N of M") is now shown via notify-send on `--nav`.
- **APOD at 960px** — `hdurl` (4K) unused; opt-in quality setting desirable for HiDPI.

### Distribution

- **No distro package** — no AUR, no `.deb`, no versioned GitHub Release tarball.
- **Unsplash via Picsum** — unofficial proxy; rate limits or shutdown risk.

---

## 5. Roadmap

### Changelog

| Version | Deliverables |
| --- | --- |
| v1.5.0 | Multi-DE: GNOME, MATE, Cinnamon, KDE, XFCE. |
| v1.6.0 | Local folder source. Timer pause/resume in Maintenance menu. |
| v1.7.0 | `yad` → `zenity 4.x` (GTK4+libadwaita). Fully Wayland-native GUI. |
| v1.8.0 | Overlay at display time (clean gallery files + `.title` sidecar). `CURRENT_GALLERY` in state. Fresh-install fix. Atomic config writes. |
| v2.0.0 | Gallery database (`waylume.db` TSV). Schema: `id·filename·title·source·date_iso·status`. `--nav next\|prev\|random` + position indicator. Source modularisation (`src/lib/`, `src/sources/`). `src/fetcher.sh` as skeleton. Two-pass build. Per-DE dispatcher pattern (`_wl_de_name` + `_wl_set_<de>`/`_wl_get_<de>`). `build.py` (pure Python build tool). |

### série 2.x — Foundation

| Priority | Feature |
| --- | --- |
| 🟠 Medium | Gallery favorites/trash UI — `status` field already in db, needs GUI |
| 🟡 Low | Optional APOD hdurl (4K opt-in for HiDPI) |
| 🟡 Low | Wallhaven as a source |

### série 3.x — Distribution

| Priority | Feature |
| --- | --- |
| 🔴 High | AUR package |
| 🔴 High | GitHub Release with versioned tarball |
| 🟠 Medium | Debian/Ubuntu `.deb` package |

### série 4.x — Architecture

| Priority | Feature |
| --- | --- |
| 🟠 Medium | Multi-monitor support — one image per resolution via `gdbus`/GSettings |
| 🟠 Medium | Resolution detection without `xrandr` (pure Wayland path) |
| 🟡 Low | `jq` as declared dependency — replaces `grep -oP` fragility across all `fetch_*` |
| 🟡 Low | Thumbnail preview in main menu |

---

## 6. Multi-DE Support

Implemented in v1.5.0. All wallpaper operations route through `_wl_set_wallpaper()` and `_wl_get_current_wallpaper()` in `src/lib/wallpaper.sh`. A single `_wl_de_name()` dispatcher maps `XDG_CURRENT_DESKTOP` to a canonical name; per-DE logic lives in `_wl_set_<de>` / `_wl_get_<de>` functions — the `case` block appears only once. Gallery navigation uses `waylume-fetch --nav next|prev|random` (returns "Image N of M" to stdout), `--set-wallpaper`, and `--get-current-gallery`.

| Desktop | Set | Read-back |
| --- | --- | --- |
| GNOME / ubuntu:GNOME | `gsettings org.gnome.desktop.background picture-uri` + `picture-uri-dark` | `gsettings get` |
| MATE | `gsettings org.mate.background picture-filename` (no `file://`) | `gsettings get` |
| X-Cinnamon | `gsettings org.cinnamon.desktop.background picture-uri` + `picture-uri-dark` | `gsettings get` |
| KDE Plasma ≥ 5.26 | `plasma-apply-wallpaperimage` | None — navigation starts from first image |
| XFCE | `xfconf-query` — enumerates all `last-image` properties automatically | `xfconf-query` first property |
| Unknown | Best-effort GNOME schema | — |

**Known limitations:**

- KDE < 5.26: unsupported (`plasma-apply-wallpaperimage` unavailable).
- Sway / Hyprland: require a persistent process (`swaybg`, `hyprpaper`) — incompatible with the systemd oneshot model.
- XFCE fresh install: primary monitor only on first run; subsequent runs update all monitors.
- LXDE, LXQt: unsupported, documented as known limitation.
