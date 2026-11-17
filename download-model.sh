#!/bin/bash
# Downloads the Qwen3.8 Flash Next 125B IQ3_XXS shards, verifies, then fetches
# the RCO tensor-allocation file the qwen4exp runtime expects alongside them.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HOME/.moeshift/models/qwen-3.8-flash-next-rco-gsq-iq3-xxs"
DEST="$LIB/IQ3_XXS"
BASE="https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/resolve/main"
NAME="Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS"
mkdir -p "$DEST"

echo "Free disk before: $(df -h "$HOME" | tail -1 | awk '{print $4}')"

python3 -B "$HERE/dl-robust.py" "$DEST/$NAME-00002-of-00002.gguf" \
  "$BASE/IQ3_XXS/$NAME-00002-of-00002.gguf" 28800138432 24 || exit 1

python3 -B "$HERE/dl-robust.py" "$DEST/$NAME-00001-of-00002.gguf" \
  "$BASE/IQ3_XXS/$NAME-00001-of-00002.gguf" 47039860096 24 || exit 1

# Runtime sidecar: per-tensor RCO allocation map.
ALLOC="$BASE/tensor-allocation/$NAME-00001-of-00002.rco-allocation.txt"
ASZ=$(curl -sIL "$ALLOC" | grep -i "^content-length" | tail -1 | tr -d '\r' | awk '{print $2}')
python3 -B "$HERE/dl-robust.py" "$DEST/$(basename "$ALLOC")" "$ALLOC" "${ASZ:-39445}" 4 || exit 1

echo "=== ALL FILES ==="
ls -lh "$DEST"
echo "Free disk after: $(df -h "$HOME" | tail -1 | awk '{print $4}')"
