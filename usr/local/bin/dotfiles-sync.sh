#!/usr/bin/env bash

# Hardcodierte Root-Allokation
SRC="/opt/system-dotfiles"
DEST="/"

if [ "$EUID" -ne 0 ]; then
  echo "Fatal: System-Sync erfordert Kernel-Root-Privilegien."
  exit 1
fi

# ==========================================
# PHASE 1: Topologische Replikation (Ignoriert .git und sich selbst)
# ==========================================
find "$SRC" -mindepth 1 \( -name ".git" -o -name "sync.sh" \) -prune -o -type d -printf '%P\n' | while read -r relative_dir; do
    mkdir -p "$DEST$relative_dir"
done

# ==========================================
# PHASE 2: I/O-Mapping (Symlinks für /etc und /usr)
# ==========================================
find "$SRC" -mindepth 1 \( -name ".git" -o -name "sync.sh" \) -prune -o -type f -printf '%P\n' | while read -r relative_file; do
    source_file="$SRC/$relative_file"
    target_link="$DEST$relative_file"
    
    if [ -e "$target_link" ] && [ ! -L "$target_link" ]; then
        echo "Konflikt: Reale Datenstruktur blockiert Symlink bei $target_link"
        continue
    fi
    
    ln -sfn "$source_file" "$target_link"
done
