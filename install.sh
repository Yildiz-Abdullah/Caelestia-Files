#!/bin/bash
# Arch + Hyprland + Caelestia Setup (beaufsichtigt)
# Start: ./install.sh   (NICHT mit sudo)

set -euo pipefail

# --- Einstellungen -----------------------------------------------------------
# Dein GitHub-Repo mit den Dotfiles (hypr/, fish/, micro/, caelestia/shell.json).
# Leer lassen = Fallback auf ~/.local/state/caelestia/dots (falls vorhanden).
DOTFILES_REPO="https://github.com/Yildiz-Abdullah/Caelestia-Files.git"
# -----------------------------------------------------------------------------

if [ "$EUID" -eq 0 ]; then
    echo "Nicht als root starten. Das Skript ruft sudo selbst auf." >&2
    exit 1
fiOTFILES_REPO=""https://github.com/Yildiz-Abdullah/Caelestia-Files

STAMP=$(date +%Y%m%d-%H%M%S)

echo "=== multilib aktivieren ==="
if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
    sudo sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
fi

echo "=== System Update ==="
sudo pacman -Syu --noconfirm

echo "=== Basis ==="
sudo pacman -S --needed --noconfirm \
    git base-devel curl wget \
    fish kitty micro nemo \
    firefox chromium thunderbird \
    hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk \
    sddm \
    grim slurp satty hyprpicker \
    wl-clipboard cliphist \
    pipewire pipewire-pulse wireplumber \
    polkit-gnome \
    keepassxc \
    obisidan \
    code \
    bluez bluez-utils \
    wine \
    ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji \
    qt6-svg qt6-declarative qt6-5compat qt6-shadertools \
    qt6-multimedia qt6-virtualkeyboard

echo "=== Grafiktreiber (automatisch erkannt) ==="
GPU=$(lspci | grep -iE 'vga|3d' || true)
if echo "$GPU" | grep -qi 'nvidia'; then
    sudo pacman -S --needed --noconfirm nvidia-open nvidia-utils lib32-nvidia-utils
elif echo "$GPU" | grep -qiE 'amd|ati|radeon'; then
    sudo pacman -S --needed --noconfirm mesa vulkan-radeon lib32-mesa lib32-vulkan-radeon
elif echo "$GPU" | grep -qi 'intel'; then
    sudo pacman -S --needed --noconfirm mesa vulkan-intel lib32-mesa lib32-vulkan-intel
else
    echo "Keine GPU erkannt, Treiber bitte manuell installieren."
fi

echo "=== Steam ==="
sudo pacman -S --needed --noconfirm steam

echo "=== Zeitzone Deutschland ==="
sudo timedatectl set-timezone Europe/Berlin
sudo timedatectl set-ntp true

echo "=== yay ==="
if ! command -v yay >/dev/null; then
    rm -rf /tmp/yay-bin
    git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
    (cd /tmp/yay-bin && makepkg -si --noconfirm)
fi

yay --save \
    --answerclean All \
    --answerdiff None \
    --answeredit None \
    --removemake

echo "=== Caelestia & AUR-Programme ==="
yay -S --needed --noconfirm \
    caelestia-shell \
    notepad++ \
    visual-studio-code-bin \
    mullvad-vpn-bin \
    mullvad-browser-bin

echo "=== Dienste ==="
sudo systemctl enable --now mullvad-daemon
sudo systemctl enable --now bluetooth

echo "=== SDDM Astronaut Theme ==="
curl -fsSL https://raw.githubusercontent.com/keyitdev/sddm-astronaut-theme/master/setup.sh \
    -o /tmp/astronaut-setup.sh
read -rp "Setup-Skript vorher ansehen? [j/N] " ans
if [[ "$ans" =~ ^[jJyY]$ ]]; then
    less /tmp/astronaut-setup.sh
fi
bash /tmp/astronaut-setup.sh
sudo systemctl enable sddm

echo "=== Dotfiles ==="
SRC=""
if [ -n "$DOTFILES_REPO" ]; then
    rm -rf ~/dotfiles
    git clone "$DOTFILES_REPO" ~/dotfiles
    SRC=~/dotfiles
elif [ -d ~/.local/state/caelestia/dots/hypr ]; then
    SRC=~/.local/state/caelestia/dots
else
    echo "WARNUNG: Keine Dotfiles-Quelle gefunden. Config-Schritt übersprungen."
    echo "Trage DOTFILES_REPO oben ein oder starte die Shell einmal und führe das Skript erneut aus."
fi

if [ -n "$SRC" ]; then
    mkdir -p ~/.config/caelestia
    for d in hypr fish micro; do
        if [ -d ~/.config/$d ]; then
            mv ~/.config/$d ~/.config/$d.backup.$STAMP
        fi
        cp -a "$SRC/$d" ~/.config/
    done
    if [ -f "$SRC/caelestia/shell.json" ]; then
        cp "$SRC/caelestia/shell.json" ~/.config/caelestia/
    fi

    # Wichtig: ohne dieses require lädt Hyprland die Caelestia-Binds nie.
    HL=~/.config/hypr/hyprland.lua
    if ! grep -q 'hyprland.keybinds' "$HL"; then
        cp "$HL" "$HL.orig"
        # Standard-Beispiel-Binds auskommentieren (sonst öffnen Apps doppelt)
        sed -i -E 's/^(\s*)hl\.bind\(/\1-- hl.bind(/' "$HL"
        echo 'require("hyprland.keybinds")' >> "$HL"
    fi
    
    if ! grep -q 'hyprland.execs' "$HL"; then
        echo 'require("hyprland.execs")' >> "$HL"
    fi
fi

echo "=== Nemo Listenansicht ==="
gsettings set org.nemo.preferences default-folder-viewer 'list-view' || true

echo "=== Firefox Einstellungen ==="
shopt -s nullglob
profiles=(~/.mozilla/firefox/*.default-release)
if [ ${#profiles[@]} -eq 0 ]; then
    timeout 15 firefox --headless >/dev/null 2>&1 || true
    profiles=(~/.mozilla/firefox/*.default-release)
fi
for profile in "${profiles[@]}"; do
    echo 'user_pref("general.autoScroll", true);' > "$profile/user.js"
done
shopt -u nullglob

echo "=== Standardbrowser & Shell ==="
xdg-settings set default-web-browser firefox.desktop || true
chsh -s /usr/bin/fish

echo "=== systemd-boot optimieren ==="
sudo tee /boot/loader/loader.conf >/dev/null <<EOF
default arch-linux.efi
timeout 0
editor no
console-mode max
EOF

echo "=== Fertig ==="
echo "Noch von Hand:"
echo "  mullvad account login DEINE_KONTONUMMER"
echo "  git config --global user.name  \"NAME\""
echo "  git config --global user.email \"MAIL\""
echo "  cp ~/Pictures/BILD.png ~/.face"
echo "Dann: sudo reboot"
