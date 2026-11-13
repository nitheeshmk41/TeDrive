#!/usr/bin/env bash
# Copies the Android APKs of the latest release into the built web app, so
# phones can download them straight from tedrive.vercel.app/download/.
# GitHub's own download links redirect to short-lived signed URLs, which
# some Android browsers (Brave, Firefox) leave stuck at 100%.
#
#   tool/fetch_apks.sh build/web
# Never fails the web build: without APKs the download page links to GitHub.
set -uo pipefail
dest="${1:?usage: fetch_apks.sh <built web app folder>}/download"
mkdir -p "$dest"
api="https://api.github.com/repos/nitheeshmk41/TeDrive/releases/latest"
json="$(curl -fsSL --retry 3 "$api")" || { echo "No release info; skipping APKs"; exit 0; }
tag="$(printf '%s' "$json" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
for abi in arm64 arm32; do
  url="$(printf '%s' "$json" | grep -o "\"browser_download_url\": *\"[^\"]*android-$abi\.apk\"" | head -1 | sed 's/.*"\(https[^"]*\)"$/\1/')"
  [ -n "$url" ] || continue
  if curl -fsSL --retry 3 -o "$dest/TeDrive-android-$abi.apk" "$url"; then
    echo "Added $tag android-$abi"
  else
    rm -f "$dest/TeDrive-android-$abi.apk"
  fi
done
printf '%s\n' "$tag" > "$dest/version.txt"
exit 0
