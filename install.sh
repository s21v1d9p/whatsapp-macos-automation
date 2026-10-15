#!/usr/bin/env bash
set -euo pipefail

SKILL_NAME="whatsapp-macos-automation"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_DIRS=("$HOME/.agents/skills")

if [ -n "${SKILL_TARGET_DIRS:-}" ]; then
  IFS=':' read -r -a TARGET_DIRS <<< "$SKILL_TARGET_DIRS"
else
  TARGET_DIRS=("${DEFAULT_DIRS[@]}")
fi

for TARGET_ROOT in "${TARGET_DIRS[@]}"; do
  mkdir -p "$TARGET_ROOT"
  DEST="$TARGET_ROOT/$SKILL_NAME"
  if [ "$SRC_DIR" != "$DEST" ]; then
    ln -sfn "$SRC_DIR" "$DEST"
  fi
  echo "Installed: $DEST -> $SRC_DIR"
done
