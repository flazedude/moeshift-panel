#!/bin/bash
# Run this AFTER the GGUF download completes: prepares expert files, verifies them,
# writes the MoEShift config, and starts the server.
set -euo pipefail
REPO="${MOESHIFT_SRC:?Set MOESHIFT_SRC to your MoEShift source checkout (e.g. export MOESHIFT_SRC=\$HOME/src/moeshift)}"
ALIAS="qwen-3.8-flash-next-rco-gsq-iq3-xxs"
LIB="$HOME/.moeshift/models/$ALIAS"
MODEL="$LIB/IQ3_XXS/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00001-of-00002.gguf"
SHARD2="$LIB/IQ3_XXS/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00002-of-00002.gguf"
CFG="$HOME/.config/moeshift/config.json"

[ -f "$MODEL" ] && [ -f "$SHARD2" ] || { echo "GGUF shards missing — download not finished."; exit 1; }
echo "Shards OK: $(ls -lh "$MODEL" "$SHARD2" | awk '{print $5}' | tr '\n' ' ')"

cd "$REPO"
if [ ! -d "$LIB/experts" ]; then
  echo "Preparing expert files (this writes ~43 GB and takes a while)…"
  .venv/bin/python tools/moe/experts.py extract --model "$MODEL" --out-dir "$LIB/experts"
else
  echo "Expert files already present, skipping extraction."
fi
.venv/bin/python tools/moe/experts.py verify --model "$MODEL" --experts "$LIB/experts"

mkdir -p "$(dirname "$CFG")"
[ -f "$CFG" ] || cp "$REPO/configs/moeshift.json" "$CFG"
.venv/bin/python - "$CFG" "$MODEL" "$LIB/experts" <<'PY'
import json, sys
cfg, model, experts = sys.argv[1:4]
d = json.load(open(cfg))
key = "qwen-3.8-flash-next-rco-gsq-iq3-xxs"
d["models"] = {key: d["models"][key]}
d["models"][key]["args"].update({"model": model, "moe-experts": experts})
json.dump(d, open(cfg, "w"), indent=2)
print("Config written to", cfg)
PY
echo
echo "Starting server on http://127.0.0.1:8080/v1  (Ctrl-C to stop)"
exec ~/.local/bin/moeshift --config "$CFG"
