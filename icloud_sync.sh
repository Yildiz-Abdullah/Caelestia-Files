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
RCLONE_LCK="$HOME/.cache/rclone/bisync/icloud_${NAME}..home_abdullah_Archiv_Persönliches_${NAME}.lck"
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
# (Obsidian schreibt gerade) -> naechster Timer-Lauf holt es nach
if [ -n "$(find "$LOCAL" -type f -mmin -0.33 -not -path '*/.trash/*' 2>/dev/null | head -n 1)" ]; then
    exit 0
fi

# Flags pro Name
SYNC_FLAGS=(--resilient --exclude ".trash/**" --max-delete 10 --backup-dir2 "$BACKUP_DIR")
case "$NAME" in
    Obsidian)
        SYNC_FLAGS+=(--conflict-resolve newer --exclude ".obsidian/workspace*.json")
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
    # Log auf die letzten 20000 Zeilen begrenzen
    if [ "$(wc -l < "$LOGFILE")" -gt 25000 ]; then
        tail -n 20000 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
    fi
}

run_sync
if [ $EXIT_CODE -eq 0 ]; then
    # Leere Backup-Ordner aufraeumen, alte Backups (>60 Tage) loeschen
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

# Fall 2: Kaputte bisync-Referenz -> KEIN automatischer Resync mehr
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