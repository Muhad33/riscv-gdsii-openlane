#!/bin/bash
# Run a command inside the LibreLane nix-shell (WSL2 / Linux).
#   scripts/ll.sh librelane examples/counter/config.json
#   LIBRELANE_DIR=/path/to/librelane scripts/ll.sh <cmd...>
set -e
LIBRELANE_DIR="${LIBRELANE_DIR:-$HOME/librelane}"
if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi
CMD="$(printf '%q ' "$@")"
exec nix-shell "$LIBRELANE_DIR/shell.nix" --run "$CMD" </dev/null
