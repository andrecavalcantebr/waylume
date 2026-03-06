# <img src="src/waylume.svg" width="52" align="center" alt="WayLume icon"> WayLume

🌐 **Language / Idioma:** [🇧🇷 Português](README.pt.md) · 🇺🇸 English (current)

WayLume is a minimalist, self-contained, zero-background-resource wallpaper manager designed specifically for Wayland environments (currently focused on **GNOME**).

It was created to fill the gap left by tools like Variety, which face stability issues under Wayland, opting for a robust architecture based on **Systemd Timers** and native scripts instead of persistent daemons.

## ✨ Highlights

* **Zero Resource Usage:** Doesn't run in the background. The GUI opens only when you want to configure. Systemd handles the scheduling.
* **Daemon-Agnostic:** Once the window is closed, WayLume consumes no RAM.
* **Three Image Sources:** Bing (Photo of the Day), NASA APOD (Astronomy Picture of the Day), or Unsplash — choose one or more.
* **Smart Caching:** Sources with a daily image (APOD, Bing) download only once per day. On subsequent timer runs, WayLume automatically rotates through the local gallery — no bandwidth waste.
* **Overlaid Title:** When available, the image title is rendered directly onto the wallpaper via ImageMagick (optional).
* **Resilience:** The Systemd Timer with `Persistent=true` ensures missed runs (PC off) are caught up on login.
* **Clean Uninstall:** Removes timers, scripts, and config without deleting your photo gallery.
* **Single-File Distribution:** `waylume.sh` is self-contained — installer, configurator (GUI), service generator, and uninstaller, all in one script.

## 🛠️ Prerequisites

The script will attempt to install missing prerequisites on first run (requires `sudo`). Required packages:

* `yad` — graphical interface (dialogs)
* `curl` — image downloading
* `libnotify` / `notify-send` — system notifications
* `file` — MIME type validation of downloaded images
* `imagemagick` *(optional)* — title overlay on the wallpaper

## 🚀 Installation & Usage

WayLume installs everything inside the user's home (`~/.local/...`), no `sudo` needed after dependency installation.

```bash
git clone https://github.com/andrecavalcantebr/waylume.git
cd waylume
chmod +x waylume.sh
./waylume.sh
```

The script will detect it isn't installed and offer to auto-install. From there, close the terminal — WayLume will appear in the system application menu (search "WayLume").

To install directly without the interactive prompt:

```bash
./waylume.sh --install
```

## ⚙️ Configuration Menu

When opening WayLume from the system menu:

| Option | Description |
| --- | --- |
| 📂 Gallery folder | Where photos will be saved |
| ⏱️ Update interval | Systemd Timer interval (minutes or hours) |
| 🌍 Image sources | Bing, Unsplash and/or APOD |
| 🔑 NASA API Key | Key for the APOD API (default: `DEMO_KEY`) |
| 🚀 Install/Update Scripts | Applies settings and restarts the timer |
| 🎲 Change image NOW | Immediately rotates through the local gallery |
| 🧹 Clean gallery | Removes corrupted or invalid files |
| 🗑️ Remove WayLume | Full uninstall (gallery preserved) |

> **NASA APOD API Key:** The `DEMO_KEY` works but has a 30 req/hour limit. For continuous use, register a free key at [api.nasa.gov](https://api.nasa.gov) (limit: 1,000 req/day) and enter it in the **🔑 NASA API Key** menu.

## 📁 Installed Files

Following the XDG standard, everything goes into the user's home:

| File | Location |
| --- | --- |
| Main script | `~/.local/bin/waylume` |
| Systemd worker | `~/.local/bin/waylume-fetch` |
| Icon | `~/.local/share/icons/hicolor/scalable/apps/waylume.svg` |
| Menu entry | `~/.local/share/applications/waylume.desktop` |
| Configuration | `~/.config/waylume/waylume.conf` |
| Download state | `~/.config/waylume/waylume.state` |
| Timer & Service | `~/.config/systemd/user/waylume.*` |
| Image gallery | `~/Pictures/WayLume` *(default, configurable)* |

## 🛠️ For Developers

The `waylume.sh` is a **generated artifact** — do not edit it directly. Sources are in `src/`:

```text
src/
  fetcher.sh    ← Systemd worker (waylume-fetch): download and apply logic
  main.sh       ← installer and GUI: menus, config, service deployment
  waylume.svg   ← application icon (editable with Inkscape or by hand)
  i18n/
    pt.sh       ← Brazilian Portuguese strings
    en.sh       ← English strings
build.sh        ← combines the files and generates waylume.sh
waylume.sh      ← build output (distributed file)
```

### Development Cycle

```bash
# 1. Edit sources in src/
nano src/fetcher.sh

# 2. Test the fetcher in isolation (no install needed)
bash src/fetcher.sh

# 3. Rebuild and reinstall
./build.sh && ./waylume.sh --install
```

``build.sh`` embeds `src/fetcher.sh`, `src/waylume.svg`, `src/i18n/pt.sh` and `src/i18n/en.sh` into their respective placeholders in `src/main.sh`, producing the self-contained `waylume.sh`. Requires Python 3 (present on any modern distro).

| Placeholder in `src/main.sh` | Replaced by |
| --- | --- |
| `##FETCHER_CONTENT##` | `src/fetcher.sh` |
| `##ICON_CONTENT##` | `src/waylume.svg` |
| `##I18N_PT##` | `src/i18n/pt.sh` |
| `##I18N_EN##` | `src/i18n/en.sh` |

The `##I18N_*##` placeholders live inside heredocs in `install_or_update`. When `waylume.sh --install` runs, those heredocs are written to:

```text
~/.config/waylume/i18n/
  pt.sh
  en.sh
```

At runtime, `main.sh` and `fetcher.sh` detect the language from `$LANG` and source the matching bundle. Fallback: `en`.

### Adding a new language

```bash
# 1. Copy an existing bundle and translate
cp src/i18n/en.sh src/i18n/de.sh
nano src/i18n/de.sh

# 2. Add the heredoc in install_or_update (src/main.sh)
# cat << 'WL_I18N_DE' > "$CONFIG_DIR/i18n/de.sh"
# ##I18N_DE##
# WL_I18N_DE

# 3. Update build.sh with the new I18N_DE variable
# 4. Rebuild and reinstall
./build.sh && ./waylume.sh --install
```

## 📄 License

This project is licensed under the GNU General Public License v3.0 (GPLv3) — [see the LICENSE.md file](LICENSE.md) for details.
