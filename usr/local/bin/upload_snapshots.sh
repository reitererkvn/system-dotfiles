#!/bin/zsh

echo "[+] Phase 1: Lokale Spiegelung von SSD auf HDD..."

#sudo mount -a

# Funktion für massenhaften BTRFS-Transfer ohne Inotify-Stress
sync_to_hdd() {
    local src_dir=$1
    local dst_dir=$2
    local last_snap=""

    # Sortierte Liste der Snapshots auf der SSD durchgehen
    for snap in $(ls -d "$src_dir"/[0-9]* | sort -V); do
        id=$(basename "$snap")
        snap_path="$snap/snapshot"

        if [ ! -d "$dst_dir/$id" ]; then
            echo "--> Spiegelung ID $id auf HDD..."

            if [ -z "$last_snap" ]; then
                # Erster Durchlauf oder kein Parent auf HDD: Full Send
                echo "    (Initialer Snapshot - Full Send)"
                sudo btrfs send "$snap_path" | sudo btrfs receive "$dst_dir/"
            else
                # Inkrementeller Send gegen den zeitlich vorigen Snapshot
                echo "    (Inkrementell gegen ID $last_snap)"
                sudo btrfs send -p "$last_snap" "$snap_path" | sudo btrfs receive "$dst_dir/"
            fi

            sudo mv "$dst_dir/snapshot" "$dst_dir/$id"
        fi
        # Den aktuellen Snapshot als Parent für den NÄCHSTEN Durchlauf merken
        last_snap="$snap_path"
    done
}

sync_to_hdd "/.snapshots" "/mnt/HDD-01/backups/root"
sync_to_hdd "/home/.snapshots" "/mnt/HDD-01/backups/home"

echo "[+] Phase 2: Starte Cloud-Backup (Restic) von HDD..."

# ==============================================================================
# OPTIMIERTE UMGEBUNG (Injektion der High-Performance Parameter)
# ==============================================================================
export RCLONE_CONFIG="/etc/rclone/rclone.conf"
export LD_PRELOAD="/usr/lib/libmimalloc.so"

echo "[+] Starte Restic Backup..."

# Prozess-Bereinigung
sudo pkill -9 -f "restic" 2>/dev/null
sleep 2

# ==============================================================================
# RESTIC KONFIGURATION
# ==============================================================================
CLOUD_DEST="rclone:gdrive:backups/homeserver_restic_repo"
HDD_DEST="/mnt/HDD-01/backups"
RESTIC_PASS="/root/.restic_pass"
RCLONE_CONF="serve restic --stdio --tpslimit 8 --tpslimit-burst 8 --config /etc/rclone/rclone.conf"

upload_daily() {
    local source_system=$1
    local hdd_path="$HDD_DEST/$source_system"

    echo "============================================================"
    echo "Processing: "$source_system""

    # Neuesten Ordner auf HDD finden
    local latest_hdd
    latest_hdd=$(ls -1 "$hdd_path" | grep -E '^[0-9]+$' | sort -n | tail -1)

    if [[ -z "$latest_hdd" ]]; then
        echo "[FEHLER] Keine Snapshots auf HDD gefunden!"
        return
    fi

    local snap_dir="$hdd_path/$latest_hdd"
    echo "[+] Ziel-Ordner: $snap_dir"

    # PRE-CHECK: Sicherheitsmessung gegen korrupte/leere Dumps
    local dir_size_mb
    dir_size_mb=$(sudo du -sm "$snap_dir" | awk '{print $1}')

    if [[ "$dir_size_mb" < 1 ]]; then
        echo "--> [FEHLER] Sicherheitsabbruch! Ziel-Ordner ist physikalisch zu klein (${dir_size_mb} MB)."
        echo "--> Verdacht auf fehlerhaften lokalen Dump. Restic wird blockiert."
        return
    fi

    # DER FIX: --parent latest und --host homeserver erzwingen die Deduplikation
    echo "--> [Restic] Starte Block-Abgleich mit Cloud ..."
    if sudo -E restic -o rclone.args="$RCLONE_CONF" \
        -r "$CLOUD_DEST" \
        --password-file "$RESTIC_PASS" \
        backup "$snap_dir" \
        --group-by host,tags \
        --tag "$source_system"; then
        echo "--> Sync erfolgreich."
    else
        echo "--> [FEHLER] Restic fehlgeschlagen!"
        return
    fi

    # Bereinigung
    sudo -E restic -o rclone.args="$RCLONE_CONF" -r "$CLOUD_DEST" --password-file "$RESTIC_PASS" \
        forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --keep-yearly 1 --prune --tag "$source_system"
}

echo "--> [Restic] Bereinigung abgeschlossen"

upload_daily "root"
upload_daily "home"

#sudo umount -R /mnt/HDD-01
sudo hdparm -y /dev/sda
