#!/usr/bin/env bash
# Run llama-cli or llama-bench with Qwen3 / Qwen3.5-friendly thinking toggles.
#
# Thinking is implemented in this tree via the Jinja chat template (enable_thinking /
# reasoning-budget), same idea as llama-server. llama-bench does not use chat templates;
# it only benchmarks raw token throughput, so --mode is ignored for bench (see message).
#
# Usage (Rust/cargo-style): script options, then -- , then everything for llama-cli or llama-bench:
#   qwen3-llama-run.sh [--input=...] [--mode=...] [--temp=...] [--ctx-size=...] [--ubatch-size=...] [--tool=...] -- <args for llama-cli|llama-bench>
# Only flags listed above may appear before -- ; all custom flags go after -- .
#
# Environment defaults (override with env):
#   CTX_SIZE      Context size for llama-cli (default: 4096, prevents OOM on mobile devices)
#   UBATCH_SIZE   Micro-batch size for llama-cli (default: 256)
#
# Examples:
#   ./scripts/qwen3-llama-run.sh --input=model.gguf --mode=think --temp=0.6 -- -p "Hello"
#   ./scripts/qwen3-llama-run.sh --input=model.gguf --mode=no_think --temp=0.6
#   ./scripts/qwen3-llama-run.sh --input=model.gguf --tool=bench -- -ngl 99
#   ./scripts/qwen3-llama-run.sh --input=model.gguf --ctx-size=2048 -- -p "Hello"

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLAMA_CLI="${LLAMA_CLI:-$ROOT/build/bin/llama-cli}"
LLAMA_BENCH="${LLAMA_BENCH:-$ROOT/build/bin/llama-bench}"

: "${CTX_SIZE:=4096}"
: "${UBATCH_SIZE:=256}"

INPUT=""
MODE="think"
TEMP=""
CTX=""
UBATCH=""
TOOL="cli"
EXTRA=()

usage() {
  sed -n '1,80p' "$0" | sed -n '/^# /s/^# //p'
  echo ""
  echo "Options:"
  echo "  --input=PATH          Path to GGUF (required)"
  echo "  --mode=think|no_think Chat template thinking channel (cli only; default: think)"
  echo "  --temp=FLOAT          Pass-through as: --temp FLOAT"
  echo "  --ctx-size=N          Context size (cli only; default: \$CTX_SIZE or 4096)"
  echo "  --ubatch-size=N       Micro-batch size (cli only; default: \$UBATCH_SIZE or 256)"
  echo "  --tool=cli|bench      Which binary to run (default: cli)"
  echo "  --                    Separator (Rust-style): llama-cli / llama-bench args go after this; omit if you pass none"
}

while (( "$#" )); do
  case "$1" in
    --input=*)
      INPUT="${1#*=}"
      shift
      ;;
    --mode=*)
      MODE="${1#*=}"
      shift
      ;;
    --temp=*)
      TEMP="${1#*=}"
      shift
      ;;
    --ctx-size=*)
      CTX="${1#*=}"
      shift
      ;;
    --ubatch-size=*)
      UBATCH="${1#*=}"
      shift
      ;;
    --tool=*)
      TOOL="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      EXTRA+=("$@")
      break
      ;;
    *)
      echo "error: unknown script argument: $1" >&2
      echo "hint: this script only accepts --input=, --mode=, --temp=, --ctx-size=, --ubatch-size=, --tool=, -h/--help, then -- before llama-cli or llama-bench flags." >&2
      echo "example: $0 --input=model.gguf --mode=think -- -p \"Hello\"" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$INPUT" ]]; then
  echo "error: --input=PATH is required" >&2
  usage >&2
  exit 1
fi

if [[ "$MODE" != "think" && "$MODE" != "no_think" ]]; then
  echo "error: --mode must be think or no_think" >&2
  exit 1
fi

if [[ "$TOOL" != "cli" && "$TOOL" != "bench" ]]; then
  echo "error: --tool must be cli or bench" >&2
  exit 1
fi

THINK_ARGS=()
if [[ "$TOOL" == "cli" ]]; then
  # Qwen3 / Qwen3.5: Jinja must be on for enable_thinking / reasoning-budget to apply.
  THINK_ARGS+=(--jinja)
  if [[ "$MODE" == "think" ]]; then
    THINK_ARGS+=(--reasoning-budget -1)
  else
    THINK_ARGS+=(--reasoning-budget 0)
  fi
fi

TEMP_ARGS=()
if [[ -n "$TEMP" ]]; then
  TEMP_ARGS+=(--temp "$TEMP")
fi

# Context size: use explicit --ctx-size= if given, else env default
CTX_ARGS=()
if [[ -n "$CTX" ]]; then
  CTX_ARGS+=(-c "$CTX")
else
  CTX_ARGS+=(-c "$CTX_SIZE")
fi

# Micro-batch size: use explicit --ubatch-size= if given, else env default
UBATCH_ARGS=()
if [[ -n "$UBATCH" ]]; then
  UBATCH_ARGS+=(-ub "$UBATCH")
else
  UBATCH_ARGS+=(-ub "$UBATCH_SIZE")
fi

if [[ "$TOOL" == "cli" ]]; then
  if [[ ! -x "$LLAMA_CLI" ]]; then
    echo "error: llama-cli not found or not executable: $LLAMA_CLI" >&2
    exit 1
  fi
  set -x
  exec "$LLAMA_CLI" -m "$INPUT" "${CTX_ARGS[@]}" "${UBATCH_ARGS[@]}" "${THINK_ARGS[@]}" "${TEMP_ARGS[@]}" "${EXTRA[@]}"
else
  if [[ ! -x "$LLAMA_BENCH" ]]; then
    echo "error: llama-bench not found or not executable: $LLAMA_BENCH" >&2
    exit 1
  fi
  echo "note: llama-bench measures prompt/decode throughput only; chat 'thinking' mode does not apply." >&2
  set -x
  exec "$LLAMA_BENCH" -m "$INPUT" "${EXTRA[@]}"
fi
