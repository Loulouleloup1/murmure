#!/usr/bin/env bash
# Pull the 5 benchmark candidates into Ollama, trying tag fallbacks in order.
# Writes one "name<TAB>resolved_ref" line per success to pulled.tsv, failures to failed.tsv.
set -uo pipefail
cd "$(dirname "$0")"
: > pulled.tsv
: > failed.tsv

try_pull() {
  local name="$1"; shift
  for ref in "$@"; do
    echo "=== $name: trying $ref ==="
    if ollama pull "$ref"; then
      printf '%s\t%s\n' "$name" "$ref" >> pulled.tsv
      return 0
    fi
    echo "--- $name: $ref failed, next candidate ---"
  done
  printf '%s\tALL_FAILED\n' "$name" >> failed.tsv
  return 1
}

try_pull s1-mini \
  "hf.co/superwhisper/s1-mini-GGUF:Q8_0" \
  "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M" \
  "hf.co/superwhisper/s1-mini-GGUF:latest"

try_pull ornith-9b \
  "hf.co/ornith-ai/Ornith-1.5-9B-GGUF:Q4_K_M"

try_pull gemma4-12b-qat \
  "gemma4:12b-it-qat" \
  "gemma4:12b-it-q4" \
  "gemma4:12b"

try_pull qwen3.5-9b \
  "qwen3.5:9b" \
  "qwen3.5:9b-q4" \
  "hf.co/unsloth/Qwen3.5-9B-GGUF:Q4_K_M"

try_pull granite4.2-8b \
  "granite4.2:8b" \
  "granite4.2:8b-q4" \
  "hf.co/ibm-granite/granite-4.2-8b-GGUF:Q4_K_M"

echo "=== DONE ==="
echo "--- pulled ---"; cat pulled.tsv
echo "--- failed ---"; cat failed.tsv
ollama list
