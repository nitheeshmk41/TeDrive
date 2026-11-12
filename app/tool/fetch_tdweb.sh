#!/usr/bin/env bash
# Puts tdweb (Telegram's TDLib compiled to WebAssembly) next to the built
# web app. It is built by .github/workflows/tdweb.yml and published as a
# release asset, so the large binaries are not kept in the repository.
#
#   tool/fetch_tdweb.sh build/web
set -euo pipefail
dest="${1:?usage: fetch_tdweb.sh <built web app folder>}"
url="https://github.com/nitheeshmk41/TeDrive/releases/download/tdweb-1.8.15/tdweb.tar.gz"
curl -fsSL --retry 3 "$url" | tar -xz -C "$dest"
test -f "$dest/tdweb.js" || { echo "tdweb.js missing after download" >&2; exit 1; }
echo "tdweb added to $dest:"
ls -la "$dest" | grep -Ei 'tdweb|worker|\.wasm' || true
