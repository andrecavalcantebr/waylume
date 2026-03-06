#!/bin/bash
# WayLume — English strings
# Loaded by main.sh and fetcher.sh via: source "$(dirname "$0")/i18n/${WAYLUME_LANG:-pt}.sh"

# ── Global buttons ────────────────────────────────────────────────────────────
BTN_CLOSE="Close"
BTN_NO="No"
BTN_YES="Yes"
BTN_OK="OK"

# ── check_dependencies ────────────────────────────────────────────────────────
MSG_DEPS_NEEDED="⚠️ WayLume needs some packages to work"
MSG_DEPS_ASKING="Requesting permission to install..."
MSG_DEPS_APT_FAIL="⚠️  apt update failed (network?), trying with local indexes..."
MSG_DEPS_NO_PM="❌ Package manager not recognized."
MSG_DEPS_MANUAL="Please install manually"
MSG_DEPS_OK="✅ Dependencies installed successfully!"

# ── deploy_services ───────────────────────────────────────────────────────────
MSG_DEPLOY_PROGRESS="Applying settings and restarting timer..."
MSG_DEPLOY_DONE="Scripts generated and Timer activated!\nThe system will run every %s."

# ── install_or_update ─────────────────────────────────────────────────────────
MSG_UPDATE_DONE="Updated successfully!\nScripts and timer have been updated.\nYour settings were preserved."
MSG_INSTALL_DONE="Installed successfully!\nOpen WayLume from your system application menu."

# ── uninstall ─────────────────────────────────────────────────────────────────
TITLE_UNINSTALL_CONFIRM="Warning"
MSG_UNINSTALL_CONFIRM="Do you really want to remove WayLume from the system?\nYour photo gallery will NOT be deleted."
MSG_UNINSTALL_DONE="WayLume completely uninstalled."

# ── set_gallery_dir ───────────────────────────────────────────────────────────
TITLE_GALLERY_PICK="Choose Gallery Folder"
MSG_GALLERY_CHANGED="Gallery changed to:\n%s\n\nRemember to click 'Install/Update Scripts' to apply."

# ── set_update_interval ───────────────────────────────────────────────────────
TITLE_INTERVAL="Update Interval"
MSG_INTERVAL_UNIT="Time unit:"
COL_INTERVAL_UNIT="Unit"
COL_INTERVAL_VALUE="Value"
ITEM_INTERVAL_MIN="Minutes"
ITEM_INTERVAL_H="Hours"
LABEL_MINUTES="minutes"
LABEL_HOURS="hours"
MSG_INTERVAL_SCALE="Interval in %s:"   # %s = minutes | hours
MSG_INTERVAL_CHANGED="Interval changed to %s.\nRemember to click 'Install/Update Scripts' to apply."

# ── set_image_sources ─────────────────────────────────────────────────────────
TITLE_SOURCES="Image Sources"
MSG_SOURCES_PICK="Choose where to download new images from:"
COL_SOURCES_NAME="Source"
MSG_SOURCES_CHANGED="Sources changed.\nRemember to click 'Install/Update Scripts' to apply."

# ── set_apod_api_key ──────────────────────────────────────────────────────────
TITLE_APOD_KEY="WayLume - NASA API Key"
MSG_APOD_KEY_DEMO="(using DEMO_KEY — get yours at api.nasa.gov, it's free!)"
MSG_APOD_KEY_SET="(key configured: %s...)"   # %s = first 6 chars
MSG_APOD_KEY_PROMPT="Enter your NASA APOD API Key:\n%s"   # %s = MSG_APOD_KEY_*
MSG_APOD_KEY_SAVED="API Key saved!\nRemember to click 'Install/Update Scripts' to apply."

# ── clean_gallery ─────────────────────────────────────────────────────────────
MSG_GALLERY_CLEAN_OK="No invalid files found in the gallery. ✅"
TITLE_GALLERY_CLEAN="WayLume - Clean Gallery"
MSG_GALLERY_CLEAN_CONFIRM="Found %d corrupted file(s):\n%s\n\nDo you want to remove them?"
MSG_GALLERY_CLEAN_DONE="%d file(s) removed from the gallery."

# ── fetch_and_apply_wallpaper ─────────────────────────────────────────────────
MSG_FETCH_NO_SCRIPTS="Scripts have not been generated yet.\nClick 'Install/Update Scripts' first."
MSG_FETCH_PROGRESS="Downloading and applying new wallpaper..."
MSG_FETCH_DONE="Wallpaper applied successfully! 🎉"

# ── bootstrap (auto-install / update prompt) ──────────────────────────────────
TITLE_UPDATE_PROMPT="WayLume Update"
MSG_UPDATE_PROMPT="WayLume is already installed.\nDo you want to update to the version in this folder?\n\nYour settings will be preserved."
TITLE_INSTALL_PROMPT="WayLume Installation"
MSG_INSTALL_PROMPT="WayLume is not installed on this system.\nDo you want to install it now to your user folder (~/.local/bin)?"

# ── main menu ─────────────────────────────────────────────────────────────────
TITLE_MENU="WayLume - Menu"
MSG_MENU_HEADER="Wallpaper Manager for GNOME\nCurrent Gallery: %s\nUpdate Interval: %s"
COL_MENU_OPTION="Option"
COL_MENU_ACTION="Action"
MENU_ITEM_1="📂 1. Choose gallery folder"
MENU_ITEM_2="⏱️ 2. Update interval"
MENU_ITEM_3="🌍 3. Choose image sources"
MENU_ITEM_4="🔑 4. NASA API Key (APOD)"
MENU_ITEM_5="🚀 5. Install/Update Scripts and Timer"
MENU_ITEM_6="🎲 6. Change image NOW (Download new)"
MENU_ITEM_7="🧹 7. Clean gallery (remove invalid files)"
MENU_ITEM_8="🗑️ 8. Remove WayLume"
MENU_ITEM_9="🚪 9. Exit"

# ── fetcher: notify-send messages ─────────────────────────────────────────────
MSG_FETCH_NO_IMAGES="No images found in the gallery."
MSG_FETCH_APOD_ERROR="APOD API: %s\nUsing local gallery.\nTip: register a free API key at api.nasa.gov"
MSG_FETCH_INVALID_MIME="⚠️ Invalid download ignored (%s). Please try again."
MSG_FETCH_LOCAL="🔄 Local gallery (%s already downloaded today)"
MSG_FETCH_SOURCE_BING="New wallpaper downloaded via Bing"
MSG_FETCH_SOURCE_UNSPLASH="New wallpaper downloaded via Unsplash"
MSG_FETCH_SOURCE_APOD="New wallpaper downloaded via APOD"
