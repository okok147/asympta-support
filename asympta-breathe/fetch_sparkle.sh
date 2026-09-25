#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.build/deps"
DEST="$CACHE/Sparkle-2.10.0"
ARCHIVE="$CACHE/Sparkle-2.10.0.tar.xz"
URL="https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz"
SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"

mkdir -p "$CACHE"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Downloading Sparkle 2.10.0…" >&2
  curl --fail --location --retry 3 --retry-delay 2 "$URL" -o "$ARCHIVE"
fi

echo "$SHA256  $ARCHIVE" | shasum -a 256 -c - >&2

if [[ ! -d "$DEST" ]]; then
  mkdir -p "$DEST"
  tar -xJf "$ARCHIVE" -C "$DEST"
fi

FRAMEWORK="$(find "$DEST" -type d -name Sparkle.framework -print -quit)"
if [[ -z "$FRAMEWORK" ]]; then
  echo "Sparkle.framework not found after extraction" >&2
  exit 1
fi

DIST_ROOT="$(dirname "$FRAMEWORK")"
if [[ ! -x "$DIST_ROOT/bin/sign_update" ]]; then
  echo "Sparkle signing tools not found in $DIST_ROOT/bin" >&2
  exit 1
fi

printf '%s\n' "$DIST_ROOT"
