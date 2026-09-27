#!/bin/bash
#
# Jello-but-BETTER installer
#
# Downloads the app, installs it to /Applications and signs it so macOS will open it.
# Run it with:
#   curl -fsSL https://raw.githubusercontent.com/Miles5746/Jello-but-BETTER/main/install.sh | bash

set -euo pipefail

APP_NAME="Jello-but-Better"
ZIP_URL="https://github.com/Miles5746/Jello-but-BETTER/raw/main/Jello-but-Better.zip"
INSTALL_DIR="/Applications"
APP_PATH="$INSTALL_DIR/$APP_NAME.app"

# Colors, only when writing to a terminal.
if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; PINK=$'\033[35m'
else
    BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; PINK=""
fi

step() { printf '\n%s==>%s %s%s%s\n' "$PINK" "$RESET" "$BOLD" "$1" "$RESET"; }
ok()   { printf '    %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '    %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
fail() { printf '\n%s✗ %s%s\n\n' "$RED" "$1" "$RESET" >&2; exit 1; }

WORK_DIR="$(mktemp -d)"
cleanup() {
    # Put the terminal back to normal in case we quit while reading the password.
    stty echo 2>/dev/null < /dev/tty || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'printf "\n"; fail "Installation cancelled."' INT

# Reads a password from the keyboard, showing * for each character typed.
# Reads from /dev/tty so it still works when the script is piped into bash.
read_password() {
    local password="" char
    # Keep echo off for the whole prompt, not just during each read, so fast typing
    # or pasting never shows the real characters.
    stty -echo < /dev/tty
    while IFS= read -r -s -n 1 char < /dev/tty; do
        if [ -z "$char" ]; then
            break  # Enter
        elif [ "$char" = $'\x7f' ] || [ "$char" = $'\b' ]; then
            if [ -n "$password" ]; then
                password="${password%?}"
                printf '\b \b' > /dev/tty
            fi
        else
            password+="$char"
            printf '*' > /dev/tty
        fi
    done
    stty echo < /dev/tty
    printf '\n' > /dev/tty
    PASSWORD="$password"
}

# Asks for the Mac password (up to 3 tries) and checks it with sudo, so later sudo
# commands in this script run without asking again.
get_admin_access() {
    sudo -k
    local attempt
    for attempt in 1 2 3; do
        printf '    %sMac password%s %s(the one you log in with)%s: ' "$BOLD" "$RESET" "$DIM" "$RESET" > /dev/tty
        read_password
        if printf '%s\n' "$PASSWORD" | sudo -S -p '' -v 2>/dev/null; then
            unset PASSWORD
            ok "Password accepted"
            return
        fi
        unset PASSWORD
        if [ "$attempt" -lt 3 ]; then
            warn "That password didn't work. Try again."
        fi
    done
    fail "Wrong password 3 times. Nothing was changed, so you can just run the installer again."
}

printf '\n%s🍮 Jello-but-BETTER installer%s\n' "$BOLD" "$RESET"
printf '%sWobbly, jelly windows for macOS%s\n' "$DIM" "$RESET"

[ "$(uname -s)" = "Darwin" ] || fail "Jello-but-BETTER only runs on macOS."
if [ "$(uname -m)" != "arm64" ]; then
    fail "Jello-but-BETTER needs a Mac with Apple silicon (M1 or newer)."
fi

step "Downloading $APP_NAME"
curl -fL --progress-bar "$ZIP_URL" -o "$WORK_DIR/$APP_NAME.zip" \
    || fail "Couldn't download the app. Check your internet connection and try again."
ok "Downloaded"

step "Unzipping"
ditto -x -k "$WORK_DIR/$APP_NAME.zip" "$WORK_DIR" \
    || fail "Couldn't unzip the download. It may be damaged, so try running the installer again."
rm -f "$WORK_DIR/$APP_NAME.zip"
[ -d "$WORK_DIR/$APP_NAME.app" ] || fail "The download didn't contain $APP_NAME.app."
ok "Unzipped and removed the .zip"

# Warn early if this Mac's macOS is older than the app needs.
min_version="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
    "$WORK_DIR/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || true)"
this_version="$(sw_vers -productVersion)"
if [ -n "$min_version" ] && \
   [ "$(printf '%s\n%s\n' "$min_version" "$this_version" | sort -V | head -n 1)" != "$min_version" ]; then
    fail "This version needs macOS $min_version or later, and this Mac has macOS $this_version."
fi

step "Getting permission to install"
printf '    macOS needs your password to install the app and sign it so it will open.\n'
printf '    %sNothing is sent anywhere. It only goes to macOS.%s\n\n' "$DIM" "$RESET"
get_admin_access

step "Installing to $INSTALL_DIR"
if pgrep -xq "$APP_NAME"; then
    osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || pkill -x "$APP_NAME" || true
    sleep 1
    ok "Closed the running copy"
fi
if [ -d "$APP_PATH" ]; then
    sudo rm -rf "$APP_PATH"
    ok "Removed the old version"
fi
sudo mv "$WORK_DIR/$APP_NAME.app" "$APP_PATH"
sudo chown -R "$(id -un)":admin "$APP_PATH"
ok "Moved to $APP_PATH"

step "Signing the app"
sudo xattr -cr "$APP_PATH"
sudo codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 \
    || fail "Couldn't sign the app."
sudo -k
ok "Signed"

printf '\n%s🎉 Jello-but-BETTER is installed!%s\n\n' "$GREEN$BOLD" "$RESET"
printf '    Look for the %smagic wand%s in your menu bar.\n' "$BOLD" "$RESET"
printf '    The first time you start the overlay, allow %sScreen Recording%s when macOS asks.\n' "$BOLD" "$RESET"
printf '    Press %s⌃⌥⌘E%s anywhere to turn the jello on or off.\n\n' "$BOLD" "$RESET"

printf '    Open it now? [Y/n] '
read -r answer < /dev/tty || answer="n"
case "$answer" in
    [nN]*) printf '\n    You can open it any time from Applications.\n\n' ;;
    *) open "$APP_PATH" ;;
esac
