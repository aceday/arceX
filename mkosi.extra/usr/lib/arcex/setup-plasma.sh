#!/bin/bash

# Installs a Plasma desktop session via nix - nothing is added to the
# read-only erofs /usr, so the base image never changes and a future arceX
# update can't touch the desktop. Run as the normal user (ace).

set -uo pipefail

if [[ ${EUID:-$UID} -eq 0 ]]; then
    echo "run this as the desktop user, not root:  sudo -iu ace ${0:-setup-plasma.sh}" >&2
    exit 1
fi

command -v nix >/dev/null 2>&1 || { echo "nix is not installed" >&2; exit 1; }
nix --extra-experimental-features 'nix-command flakes' profile --help >/dev/null 2>&1 || {
    echo "arming experimental features (nix-command flakes)…"
    nix --extra-experimental-features 'nix-command flakes' config set experimental-features 'nix-command flakes'
}

echo "installing Plasma Desktop (KDE) from nixpkgs into your user profile…"
nix --extra-experimental-features 'nix-command flakes' profile install \
    nixpkgs#plasma5Packages.plasma-desktop \
    nixpkgs#plasma5Packages.plasma-workspace \
    nixpkgs#plasma5Packages.kwin \
    nixpkgs#plasma5Packages.plasma-integration \
    nixpkgs#plasma5Packages.xdg-desktop-portal-kde \
    nixpkgs#plasma5Packages.plasma-nm \
    nixpkgs#plasma5Packages.konsole \
    nixpkgs#plasma5Packages.dolphin \
    nixpkgs#noto-fonts \
    nixpkgs#sddm

# Guarantee the legacy ~/.nix-profile path the sddm.service unit watches.
for profile in \
    "$HOME/.local/state/nix/profile" \
    "$HOME/.nix-profile"; do
    if [[ -x "$profile/bin/sddm" ]]; then
        if [[ -L "$HOME/.nix-profile" ]] &&
           [[ "$(readlink "$HOME/.nix-profile")" == "$(readlink -f "$profile")" ]]; then
            :
        elif [[ -x "$HOME/.nix-profile/bin/sddm" ]]; then
            :
        else
            ln -sfn "$(readlink -f "$profile")" "$HOME/.nix-profile"
        fi
        break
    fi
done

cat <<'EOF'

Plasma is installed in your nix profile (~/.nix-profile). To start it now:

1. stay on a TTY login (Ctrl+Alt+F2) as this user,
2. run:          exec startkde          # Plasma on X11
           or:   exec startplasma-wayland-session   # Plasma on Wayland (recommended)

To boot straight into the Plasma login screen instead (sddm; safely inert
until sddm is installed - it is now):
    sudo systemctl enable sddm.service
    sudo systemctl set-default graphical.target
    sudo reboot
EOF