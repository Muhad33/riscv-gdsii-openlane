#!/bin/bash
# LibreLane/Yosys break on paths that contain spaces (e.g. ".../github projects/...").
# Symlinks don't help (LibreLane resolves them back to the real path), so this
# bind-mounts the project at a space-free path. Needs root (default user in WSL here).
#   sudo bash scripts/wsl_mount.sh            -> mounts at /root/rgo
#   sudo bash scripts/wsl_mount.sh /work/rgo  -> custom mount point
set -e
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DST="${1:-/root/rgo}"
mkdir -p "$DST"
if mountpoint -q "$DST"; then
  echo "$DST already mounted"
else
  mount --bind "$SRC" "$DST"
  echo "mounted $SRC -> $DST"
fi
