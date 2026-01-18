#!/bin/bash
# One-time environment setup for WSL2 Ubuntu 24.04 (run inside WSL).
# Follows the official LibreLane (successor to OpenLane 2) Nix install guide:
#   https://librelane.readthedocs.io/en/latest/installation/nix_installation/installation_win.html
# LibreLane is pinned to tag 3.0.17 (latest stable as of 2026-11).
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
$SUDO apt-get update
$SUDO apt-get install -y curl git make

# 1) Nix (official installer + FOSSi binary cache). Do NOT install Nix via apt.
if [ ! -e /nix/var/nix/profiles/default/bin/nix ]; then
  curl --proto '=https' --tlsv1.2 -fsSL https://artifacts.nixos.org/nix-installer | sh -s -- install --no-confirm --extra-conf "
    extra-substituters = https://nix-cache.fossi-foundation.org
    extra-trusted-public-keys = nix-cache.fossi-foundation.org:3+K59iFwXqKsL7BNu6Guy0v+uTlwsxYQxjspXzqLYQs=
    extra-experimental-features = nix-command flakes
"
fi
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
nix --version

# 2) LibreLane source (provides shell.nix with yosys, OpenROAD, magic, klayout, netgen, iverilog...)
cd ~
[ -d librelane ] || git clone https://github.com/librelane/librelane
cd librelane
git fetch --tags -q
git checkout -q 3.0.17
git log -1 --oneline

# 3) sky130 PDK (~2.2 GiB into ~/.ciel). Same Ciel download LibreLane does on
#    first run, but with a long timeout + retries (the default 5 s timeout fails on slow links).
nix-shell --run "python3 '$HERE/fetch_pdk.py'"

# 4) Smoke test (builds a small design end to end)
nix-shell --run "librelane --log-level ERROR --condensed --smoke-test"
echo "SETUP OK"
