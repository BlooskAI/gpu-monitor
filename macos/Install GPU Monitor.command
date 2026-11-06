#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
zsh "$ROOT/scripts/install.sh"
echo
echo "Installation complete. You may close this window."
read -k 1 '?Press any key to close...'
