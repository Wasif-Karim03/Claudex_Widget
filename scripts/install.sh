#!/usr/bin/env bash
# Builds Claudex, installs it to /Applications and launches it. On its first run from
# there the app adds itself to Login Items, so it starts with the Mac from then on.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh
pkill -x Claudex 2>/dev/null || true
sleep 1
rm -rf /Applications/Claudex.app
cp -R build/Claudex.app /Applications/Claudex.app
open /Applications/Claudex.app
echo "Installed /Applications/Claudex.app"
