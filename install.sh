#!/bin/bash
# Arch + Hyprland + Caelestia Setup (beaufsichtigt)
# Start: ./install.sh   (NICHT mit sudo)

set -euo pipefail

# --- Einstellungen -----------------------------------------------------------
DOTFILES_REPO="https://github.com/Yildiz-Abdullah/Caelestia-Files.git"
# iCloud-Ordner, die synchronisiert werden (lokal: ~/Archiv/Persönliches/<Name>)
ICLOUD_FOLDERS=(Obsidian KeePass)
# -----------------------------------------------------------------------------

if [ "$EUID" -eq 0 ]; then
    echo "Nicht als root starten. Das Skript ruft sudo selbst auf." >&2
    exit 1
fi

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
    obsidian \
    rclone libnotify util-linux \
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

echo "=== iCloud-Sync (rclone bisync) ==="
mkdir -p ~/.local/bin ~/.config/systemd/user ~/.cache/rclone

# --- Sync-Skript (LF-Zeilenenden, direkt aus dem Installer erzeugt) ----------
cat > ~/.local/bin/icloud-sync.sh <<'SYNC_EOF'
#!/bin/bash
# iCloud bisync fuer KeePass / Obsidian (Aufruf: icloud-sync.sh <Name>)

NAME="$1"
[ -z "$NAME" ] && { echo "Usage: $0 <Name>" >&2; exit 2; }

# Display/DBus-Umgebung aus der systemd-User-Session uebernehmen
if [ -z "$WAYLAND_DISPLAY" ] && [ -z "$DISPLAY" ]; then
    eval "$(systemctl --user show-environment 2>/dev/null \
        | grep -E '^(WAYLAND_DISPLAY|DISPLAY|HYPRLAND_INSTANCE_SIGNATURE|DBUS_SESSION_BUS_ADDRESS|XDG_RUNTIME_DIR)=' \
        | sed 's/^\([^=]*\)=\(.*\)$/export \1="\2"/')"
fi

RCLONE_REMOTE="icloud"
REMOTE="${RCLONE_REMOTE}:${NAME}"
LOCAL="$HOME/Archiv/Persönliches/${NAME}"
LOCAL_KEY="${LOCAL#/}"
LOCAL_KEY="${LOCAL_KEY//\//_}"
RCLONE_LCK="$HOME/.cache/rclone/bisync/icloud_${NAME}..${LOCAL_KEY}.lck"
RUNDIR="${XDG_RUNTIME_DIR:-/tmp}"
AUTH_FLAG="$RUNDIR/icloud-needs-reauth"
REAUTH_LOCK="$RUNDIR/icloud-reauth.lock"

BACKUP_ROOT="$HOME/.local/share/icloud-sync-backup/${NAME}"
BACKUP_DIR="${BACKUP_ROOT}/$(date +%F_%H%M%S)"
LOGFILE="$HOME/.cache/rclone/icloud-sync-${NAME}.log"
mkdir -p "$BACKUP_ROOT" "$(dirname "$LOGFILE")"

# Nur ein Lauf pro Name
exec 9>"$RUNDIR/icloud-sync-${NAME}.lock"
flock -n 9 || exit 0

# Nicht syncen, wenn lokal in den letzten 20 Sekunden etwas geaendert wurde
if [ -n "$(find "$LOCAL" -type f -mmin -0.33 -not -path '*/.trash/*' 2>/dev/null | head -n 1)" ]; then
    exit 0
fi

# Flags pro Name
SYNC_FLAGS=(--resilient --exclude ".trash/**" --max-delete 10 --backup-dir2 "$BACKUP_DIR")
case "$NAME" in
    Obsidian)
        SYNC_FLAGS+=(--conflict-resolve newer)
        ;;
    *)
        : # KeePass u.a.: keine automatische Konfliktloesung, Konflikt soll auffallen
        ;;
esac

session_ok() {
    rclone lsd "${RCLONE_REMOTE}:" --max-depth 0 > /dev/null 2>&1
}

reauth() {
    (
        flock -n 8 || exit 1
        logger -t icloud-sync "iCloud Session abgelaufen, oeffne Reconnect-Terminal"
        notify-send -u critical "iCloud Sync: Session abgelaufen" "Terminal oeffnet sich fuer Reconnect (2FA-Code noetig)."

        INNER="echo 'iCloud Session abgelaufen - Reconnect noetig.'
               echo 'Apple-ID Passwort + 2FA-Code eingeben:'
               rclone config reconnect ${RCLONE_REMOTE}:
               echo
               read -rp 'Fertig. Enter zum Schliessen... '"

        if   command -v kitty     > /dev/null; then kitty     -e bash -c "$INNER"
        elif command -v foot      > /dev/null; then foot      -e bash -c "$INNER"
        elif command -v alacritty > /dev/null; then alacritty -e bash -c "$INNER"
        elif command -v wezterm   > /dev/null; then wezterm start -- bash -c "$INNER"
        elif command -v xterm     > /dev/null; then xterm     -e bash -c "$INNER"
        else
            notify-send -u critical "iCloud Sync: Kein Terminal gefunden" "Bitte manuell: rclone config reconnect ${RCLONE_REMOTE}:"
            exit 1
        fi
    ) 8>"$REAUTH_LOCK"
    session_ok
}

if [ -f "$AUTH_FLAG" ]; then
    if session_ok; then
        rm -f "$AUTH_FLAG"
        logger -t icloud-sync "Session wieder gueltig, Flag entfernt"
    else
        if [ -n "$(find "$AUTH_FLAG" -mmin +30 2>/dev/null)" ]; then
            touch "$AUTH_FLAG"
            notify-send -u critical "iCloud Sync pausiert" "Session abgelaufen. Bitte: rclone config reconnect ${RCLONE_REMOTE}:"
        fi
        exit 1
    fi
fi

# Verwaiste rclone-Lock-Datei entfernen
if [ -f "$RCLONE_LCK" ] && ! pgrep -f "rclone bisync $REMOTE" > /dev/null; then
    logger -t icloud-sync "AUTO-FIX $NAME: verwaiste .lck-Datei gefunden, entferne sie"
    rm -f "$RCLONE_LCK"
fi

run_sync() {
    OUTPUT=$(rclone bisync "$REMOTE" "$LOCAL" "${SYNC_FLAGS[@]}" -v 2>&1)
    EXIT_CODE=$?
    {
        echo "=== $(date '+%F %T') exit=$EXIT_CODE ==="
        echo "$OUTPUT"
    } >> "$LOGFILE"
    if [ "$(wc -l < "$LOGFILE")" -gt 25000 ]; then
        tail -n 20000 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
    fi
}

run_sync
if [ $EXIT_CODE -eq 0 ]; then
    find "$BACKUP_ROOT" -mindepth 1 -type d -empty -delete 2>/dev/null
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +60 -exec rm -rf {} + 2>/dev/null
    exit 0
fi

# Fall 1: Session abgelaufen
if echo "$OUTPUT" | grep -qE "Invalid global session|HTTP error 421|Missing X-APPLE-WEBAUTH-TOKEN cookie|authentication required"; then
    touch "$AUTH_FLAG"
    if reauth; then
        rm -f "$AUTH_FLAG"
        run_sync
        if [ $EXIT_CODE -eq 0 ]; then
            notify-send -u normal "iCloud Sync" "Reconnect erfolgreich, $NAME synchronisiert."
            exit 0
        fi
        logger -t icloud-sync "FEHLER $NAME nach Reconnect: $OUTPUT"
        notify-send -u critical "iCloud Sync Fehler: $NAME" "$(echo "$OUTPUT" | grep ERROR | tail -2)"
        exit 1
    fi
    exit 1
fi

# Fall 2: Kaputte bisync-Referenz -> KEIN automatischer Resync
if echo "$OUTPUT" | grep -qE "cannot find prior|critical error on prior run"; then
    logger -t icloud-sync "RESYNC NOETIG $NAME: bisync-Referenz kaputt, manuelles --resync erforderlich"
    notify-send -u critical "iCloud Sync gestoppt: $NAME" \
        "Bisync-Referenz kaputt. Erst Backup pruefen, dann manuell: rclone bisync $REMOTE $LOCAL --resync --resync-mode newer"
    exit 1
fi

# Fall 2b: Max-Delete-Schutz hat ausgeloest
if echo "$OUTPUT" | grep -qiE "too many deletes|max-delete"; then
    logger -t icloud-sync "ABBRUCH $NAME: max-delete Schutz ausgeloest"
    notify-send -u critical "iCloud Sync gestoppt: $NAME" "Zu viele Loeschungen erkannt. Log: $LOGFILE"
    exit 1
fi

# Fall 3: Alles andere
logger -t icloud-sync "FEHLER $NAME: $OUTPUT"
notify-send -u critical "iCloud Sync Fehler: $NAME" "$(echo "$OUTPUT" | grep ERROR | tail -2)"
exit 1
SYNC_EOF
chmod +x ~/.local/bin/icloud-sync.sh
bash -n ~/.local/bin/icloud-sync.sh

# --- systemd-Units (Templates) -----------------------------------------------
cat > ~/.config/systemd/user/icloud-sync@.service <<'UNIT_EOF'
[Unit]
Description=iCloud sync for %i

[Service]
Type=oneshot
ExecStart=%h/.local/bin/icloud-sync.sh %i
UNIT_EOF

cat > ~/.config/systemd/user/icloud-sync@.timer <<'UNIT_EOF'
[Unit]
Description=Periodic iCloud sync for %i

[Timer]
OnBootSec=1min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
UNIT_EOF

systemctl --user daemon-reload || true

# --- rclone-Remote 'icloud' (Apple-ID, 2FA und ADP-Freigabe sind interaktiv) --
ICLOUD_OK=0
if rclone lsd icloud: >/dev/null 2>&1; then
    ICLOUD_OK=1
else
    read -rp "iCloud jetzt einrichten (Apple-ID, 2FA, ADP-Freigabe am iPhone)? [J/n] " ans
    if [[ ! "$ans" =~ ^[nN]$ ]]; then
        if ! rclone listremotes | grep -q '^icloud:$'; then
            read -rp "Apple-ID: " APPLE_ID
            read -rsp "Apple-Passwort: " APPLE_PW; echo
            rclone config create icloud iclouddrive apple_id "$APPLE_ID" password "$APPLE_PW" || true
            unset APPLE_PW
        fi
        echo "2FA-Code eingeben und ggf. auf dem Apple-Gerät freigeben:"
        rclone config reconnect icloud: || true
        rclone lsd icloud: >/dev/null 2>&1 && ICLOUD_OK=1
    fi
fi

# --- Erster Abgleich + Timer pro Ordner ---------------------------------------
if [ "$ICLOUD_OK" = 1 ]; then
    for NAME in "${ICLOUD_FOLDERS[@]}"; do
        L="$HOME/Archiv/Persönliches/$NAME"
        mkdir -p "$L"

        if [ -z "$(rclone lsf "icloud:$NAME" 2>/dev/null | head -n 1)" ]; then
            echo "WARNUNG: icloud:$NAME ist leer oder nicht erreichbar, uebersprungen."
            continue
        fi

        # Vorhandene lokale Daten vor dem Resync sichern
        if [ -n "$(find "$L" -type f -print -quit)" ]; then
            cp -a "$L" "$L.backup.$STAMP"
            echo "Lokale Daten gesichert: $L.backup.$STAMP"
        fi

        if rclone bisync "icloud:$NAME" "$L" --resync --resync-mode newer \
               --exclude ".trash/**" -v; then
            systemctl --user enable --now "icloud-sync@$NAME.timer" \
                || echo "WARNUNG: Timer fuer $NAME nicht gestartet (nach Login: systemctl --user enable --now icloud-sync@$NAME.timer)"
        else
            echo "WARNUNG: Erster Abgleich fuer $NAME fehlgeschlagen, Timer nicht aktiviert."
        fi
    done
else
    echo "WARNUNG: iCloud nicht eingerichtet. Spaeter nachholen:"
    echo "  rclone config   (Name: icloud, Typ: iclouddrive)"
    echo "  Skript erneut starten oder pro Ordner: rclone bisync ... --resync"
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
echo "  systemctl --user list-timers | grep icloud   (Timer pruefen)"
echo "Dann: sudo reboot"
