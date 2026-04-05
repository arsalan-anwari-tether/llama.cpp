#!/usr/bin/env bash
# Run llama-bench on every *.gguf in a directory: once CPU-only (--device none -ngl 0)
# and once with GPU offload (-ngl 999, Vulkan when the build uses it). Writes JSON per run.
#
# Also runs llama-cli logic prompts (thinking + non-thinking) and writes Markdown reports.
#
#   {output-dir}/inference/{model}/{cpu|vulkan}.json
#   {output-dir}/logic/{model}/{cpu|vulkan}_{think|no_think}.md
#
# Usage:
#   run_qwen3_benchmark.sh --input-dir=DIR [--output-dir=DIR] [--bench-mode=MODE] -- [extra llama-bench args]
#
# Default llama-bench workload: -p/-n/-r from BENCH_* env (see below). Extra arguments after
# -- apply to llama-bench only (not llama-cli logic), so bench flags like -p/-n/-r do not
# confuse llama-cli. Logic-only flags are configured via LOGIC_CLI_EXTRA_THINK /
# LOGIC_CLI_EXTRA_NO_THINK (or legacy LOGIC_CLI_EXTRA).
# Logic runs use stdin from /dev/null so llama-cli cannot block on console input when stdout
# is captured (command substitution otherwise inherits the script's TTY stdin).
#
# Environment:
#   LLAMA_BENCH  Path to llama-bench (default: <repo>/build/bin/llama-bench)
#   LLAMA_CLI    Path to llama-cli (default: <repo>/build/bin/llama-cli)
#   LOGIC_CLI_EXTRA  Legacy fallback: if set, used for both logic modes unless the
#                    per-mode variables below are set explicitly.
#   LOGIC_CLI_EXTRA_THINK      Optional extra llama-cli flags for thinking runs
#   LOGIC_CLI_EXTRA_NO_THINK   Optional extra llama-cli flags for non-thinking runs
#   LOGIC_TIMEOUT_SEC          Per-question timeout for llama-cli logic runs
#                              (default: 300, partial stdout is preserved on timeout)
#
# Defaults (override with env):
#   BENCH_P, BENCH_N, BENCH_R     llama-bench: prompt tokens, gen tokens, repetitions (defaults: 256, 64, 2)
#   LOGIC_N_THINK, LOGIC_N_NO_THINK  llama-cli -n for think / no_think logic runs (defaults: 512, 512)
#   LOGIC_CTX_SIZE                llama-cli context size for logic runs (default: 4096)
#   LOGIC_UBATCH_SIZE             llama-cli micro-batch size for logic runs (default: 256)
# llama-bench upstream defaults are -p 512 -n 128 -r 5; this script uses smaller values unless env overrides.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLAMA_BENCH="${LLAMA_BENCH:-$ROOT/build/bin/llama-bench}"
LLAMA_CLI="${LLAMA_CLI:-$ROOT/build/bin/llama-cli}"

: "${BENCH_P:=256}"
: "${BENCH_N:=64}"
: "${BENCH_R:=2}"
: "${LOGIC_N_THINK:=512}"
: "${LOGIC_N_NO_THINK:=512}"
: "${LOGIC_TIMEOUT_SEC:=300}"
: "${LOGIC_CTX_SIZE:=4096}"
: "${LOGIC_UBATCH_SIZE:=256}"

DEFAULT_LOGIC_CLI_EXTRA_THINK="--temp 1.0 --top-k 20 --top-p 0.95 --min-p 0 --repeat-penalty 1.0 --presence-penalty 1.5"
DEFAULT_LOGIC_CLI_EXTRA_NO_THINK="--temp 0.7 --top-k 20 --top-p 0.8 --min-p 0 --repeat-penalty 1.0 --presence-penalty 1.5"

if [[ -n "${LOGIC_CLI_EXTRA_THINK+x}" ]]; then
  LOGIC_CLI_EXTRA_THINK_VALUE="${LOGIC_CLI_EXTRA_THINK}"
elif [[ -n "${LOGIC_CLI_EXTRA:-}" ]]; then
  LOGIC_CLI_EXTRA_THINK_VALUE="${LOGIC_CLI_EXTRA}"
else
  LOGIC_CLI_EXTRA_THINK_VALUE="${DEFAULT_LOGIC_CLI_EXTRA_THINK}"
fi

if [[ -n "${LOGIC_CLI_EXTRA_NO_THINK+x}" ]]; then
  LOGIC_CLI_EXTRA_NO_THINK_VALUE="${LOGIC_CLI_EXTRA_NO_THINK}"
elif [[ -n "${LOGIC_CLI_EXTRA:-}" ]]; then
  LOGIC_CLI_EXTRA_NO_THINK_VALUE="${LOGIC_CLI_EXTRA}"
else
  LOGIC_CLI_EXTRA_NO_THINK_VALUE="${DEFAULT_LOGIC_CLI_EXTRA_NO_THINK}"
fi

LOGIC_CLI_EXTRA_THINK_ARR=()
if [[ -n "${LOGIC_CLI_EXTRA_THINK_VALUE}" ]]; then
  read -r -a LOGIC_CLI_EXTRA_THINK_ARR <<< "${LOGIC_CLI_EXTRA_THINK_VALUE}"
fi

LOGIC_CLI_EXTRA_NO_THINK_ARR=()
if [[ -n "${LOGIC_CLI_EXTRA_NO_THINK_VALUE}" ]]; then
  read -r -a LOGIC_CLI_EXTRA_NO_THINK_ARR <<< "${LOGIC_CLI_EXTRA_NO_THINK_VALUE}"
fi

INPUT_DIR=""
OUTPUT_DIR=""
BENCH_MODE="all"
EXTRA=()
FAILURES=0

usage() {
  sed -n '1,37p' "$0" | sed -n '/^# /s/^# //p'
  echo ""
  echo "Options:"
  echo "  --input-dir=DIR | --input-dir DIR   Directory containing .gguf files (required)"
  echo "  --output-dir=DIR | --output-dir DIR Where to write inference/ and logic/ (default: same as --input-dir)"
  echo "  --bench-mode=MODE                   One of: all, inference, logic (default: all)"
  echo "  -h, --help                           This help"
  echo "  --                                   Separator: all following tokens go to llama-bench"
}

# Fixed logic prompts (Qwen3-style chat: --jinja + --reasoning-budget).
LOGIC_PROMPTS=(
  'What is the derivative of x³ + 2x² - 5x + 3?'
  'Write a Python function to check if a string is a palindrome.'
  'A farmer has 17 sheep. All but 9 run away. How many sheep does the farmer have left?'
)

die() {
  echo "error: $*" >&2
  exit 1
}

is_inference_enabled() {
  [[ "$BENCH_MODE" == "all" || "$BENCH_MODE" == "inference" ]]
}

is_logic_enabled() {
  [[ "$BENCH_MODE" == "all" || "$BENCH_MODE" == "logic" ]]
}

while (( "$#" )); do
  case "$1" in
    --input-dir=*)
      INPUT_DIR="${1#*=}"
      shift
      ;;
    --input-dir)
      [[ $# -ge 2 ]] || die "--input-dir requires a path"
      INPUT_DIR="$2"
      shift 2
      ;;
    --output-dir=*)
      OUTPUT_DIR="${1#*=}"
      shift
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir requires a path"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --bench-mode=*)
      BENCH_MODE="${1#*=}"
      shift
      ;;
    --bench-mode)
      [[ $# -ge 2 ]] || die "--bench-mode requires a value"
      BENCH_MODE="$2"
      shift 2
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
      die "unknown argument: $1 (use -- before llama-bench flags)"
      ;;
  esac
done

[[ -n "$INPUT_DIR" ]] || die "--input-dir is required"
[[ -d "$INPUT_DIR" ]] || die "input directory does not exist: $INPUT_DIR"
[[ "$BENCH_MODE" == "all" || "$BENCH_MODE" == "inference" || "$BENCH_MODE" == "logic" ]] || die "--bench-mode must be one of: all, inference, logic"

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$INPUT_DIR"
fi

if is_inference_enabled; then
  mkdir -p "$OUTPUT_DIR/inference"
  if [[ ! -x "$LLAMA_BENCH" ]]; then
    die "llama-bench not found or not executable: $LLAMA_BENCH (set LLAMA_BENCH if installed elsewhere)"
  fi
fi

if is_logic_enabled; then
  mkdir -p "$OUTPUT_DIR/logic"
  if [[ ! -x "$LLAMA_CLI" ]]; then
    die "llama-cli not found or not executable: $LLAMA_CLI (set LLAMA_CLI if installed elsewhere)"
  fi
  command -v timeout >/dev/null 2>&1 || die "'timeout' command is required for logic runs"
fi

LLAMA_VERSION="not-used"
if is_logic_enabled; then
  LLAMA_VERSION="$("$LLAMA_CLI" --version 2>/dev/null | head -n1 || echo "unknown")"
fi

mapfile -t GGUF_FILES < <(find "$INPUT_DIR" -maxdepth 1 -type f -name '*.gguf' | LC_ALL=C sort)
((${#GGUF_FILES[@]})) || die "no .gguf files in $INPUT_DIR"

run_one() {
  local model_path=$1
  local out_json=$2
  local label=$3
  local cmd=("$LLAMA_BENCH" -m "$model_path" -p "$BENCH_P" -n "$BENCH_N" -r "$BENCH_R" "${EXTRA[@]}")

  if [[ "$label" == "cpu" ]]; then
    cmd+=(--device none -ngl 0)
  elif [[ "$label" == "vulkan" ]]; then
    cmd+=(-ngl 999)
  else
    die "run_one: label must be cpu or vulkan (got: $label)"
  fi
  cmd+=(-o json)

  echo "==> $label: $(basename "$model_path") -> $out_json" >&2
  if ! "${cmd[@]}" >"$out_json"; then
    echo "error: llama-bench failed for $model_path ($label) model arch not supported!" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  return 0
}

run_logic_one() {
  local model_path=$1
  local out_md=$2
  local backend=$3
  local mode=$4
  local base_name=$5

  local n_predict rbudget ngl logic_extra_value device_label timeout_note
  local logic_extra_arr=()
  local cmd=("$LLAMA_CLI" -m "$model_path" --jinja -c "$LOGIC_CTX_SIZE" -ub "$LOGIC_UBATCH_SIZE")
  if [[ "$mode" == "think" ]]; then
    n_predict=$LOGIC_N_THINK
    rbudget=-1
    logic_extra_value="${LOGIC_CLI_EXTRA_THINK_VALUE}"
    logic_extra_arr=("${LOGIC_CLI_EXTRA_THINK_ARR[@]}")
  elif [[ "$mode" == "no_think" ]]; then
    n_predict=$LOGIC_N_NO_THINK
    rbudget=0
    logic_extra_value="${LOGIC_CLI_EXTRA_NO_THINK_VALUE}"
    logic_extra_arr=("${LOGIC_CLI_EXTRA_NO_THINK_ARR[@]}")
  else
    die "run_logic_one: mode must be think or no_think (got: $mode)"
  fi

  if [[ "$backend" == "cpu" ]]; then
    device_label="none"
    ngl=0
    cmd+=(--device none --reasoning-budget "$rbudget" -ngl "$ngl" -st)
  elif [[ "$backend" == "vulkan" ]]; then
    device_label="auto"
    ngl=999
    cmd+=(--reasoning-budget "$rbudget" -ngl "$ngl" -st)
  else
    die "run_logic_one: backend must be cpu or vulkan (got: $backend)"
  fi

  {
    cat <<EOF
# Logic test: ${base_name}

## Run configuration

| Field | Value |
|-------|-------|
| **llama-cli** | \`${LLAMA_CLI}\` |
| **llama-cli version** | ${LLAMA_VERSION} |
| **Model file** | \`$(basename "$model_path")\` |
| **Backend** | ${backend} |
| **Device selection** | \`--device ${device_label}\` |
| **GPU layers** | \`-ngl ${ngl}\` |
| **Thinking mode** | \`${mode}\` (\`--reasoning-budget ${rbudget}\`) |
| **Max new tokens** | \`-n ${n_predict}\` |
| **Context size** | \`-c ${LOGIC_CTX_SIZE}\` |
| **Micro-batch size** | \`-ub ${LOGIC_UBATCH_SIZE}\` |
| **Sampling flags** | \`${logic_extra_value}\` |
| **Per-question timeout** | \`${LOGIC_TIMEOUT_SEC}s\` |
| **Chat** | \`--jinja\`, \`--single-turn\` (each question: \`-p\` …) |

## Command line (same for every question; only \`-p\` changes)

EOF
    printf '````bash\n'
    printf '%q ' "${cmd[@]}" -p '<prompt>' -n "$n_predict" "${logic_extra_arr[@]}"
    printf ' </dev/null\n'
    printf '````\n\n---\n\n'
  } >"$out_md"

  local i=1
  local tmp_err
  tmp_err="$(mktemp)"

  local prompt answer ec err
  for prompt in "${LOGIC_PROMPTS[@]}"; do
    echo "==> logic $backend $mode Question-${i}: $(basename "$model_path")" >&2
    set +e
    answer="$(timeout --signal=TERM --kill-after=10s "${LOGIC_TIMEOUT_SEC}s" "${cmd[@]}" -p "$prompt" -n "$n_predict" "${logic_extra_arr[@]}" </dev/null 2>"$tmp_err")"
    ec=$?
    set -e
    err="$(cat "$tmp_err" || true)"
    timeout_note=""
    if (( ec == 124 )); then
      echo "warning: llama-cli timed out for $model_path ($backend $mode Q${i}) after ${LOGIC_TIMEOUT_SEC}s" >&2
      FAILURES=$((FAILURES + 1))
      timeout_note="**llama-cli timed out after ${LOGIC_TIMEOUT_SEC} seconds; partial output captured below.**"
    elif (( ec != 0 )); then
      echo "error: llama-cli failed for $model_path ($backend $mode Q${i}) exit=$ec" >&2
      FAILURES=$((FAILURES + 1))
    fi

    if (( ec != 0 )); then
      {
        printf '## Question %s\n\n### Prompt\n\n%s\n\n### Answer\n\n' "$i" "$prompt"
        if [[ -n "$timeout_note" ]]; then
          printf '%s\n\n' "$timeout_note"
        else
          printf '**llama-cli exited with code %s**\n\n' "$ec"
        fi
        if [[ -n "$answer" ]]; then
          printf '#### Partial output\n\n'
          printf '````text\n\n'
          printf '%s\n' "$answer"
          printf '\n````\n\n'
        fi
        if [[ -n "$err" ]]; then
          printf '#### stderr\n\n'
          printf '````text\n\n'
          printf '%s\n' "$err"
          printf '\n````\n\n'
        fi
        if [[ -z "$answer" && -z "$err" ]]; then
          printf '````text\n\n(no output captured)\n\n````\n\n'
        fi
      } >>"$out_md"
    else
      if [[ -z "$answer" ]]; then
        answer="(empty output)"
      fi
      {
        printf '## Question %s\n\n### Prompt\n\n%s\n\n### Answer\n\n' "$i" "$prompt"
        printf '````text\n\n'
        printf '%s\n' "$answer"
        printf '\n````\n\n'
      } >>"$out_md"
    fi
    i=$((i + 1))
  done
  rm -f "$tmp_err"
  return 0
}

for f in "${GGUF_FILES[@]}"; do
  base="$(basename "$f" .gguf)"
  if is_inference_enabled; then
    mkdir -p "${OUTPUT_DIR}/inference/${base}"
    run_one "$f" "${OUTPUT_DIR}/inference/${base}/cpu.json" cpu || true
    run_one "$f" "${OUTPUT_DIR}/inference/${base}/vulkan.json" vulkan || true
  fi

  if is_logic_enabled; then
    mkdir -p "${OUTPUT_DIR}/logic/${base}"
    run_logic_one "$f" "${OUTPUT_DIR}/logic/${base}/cpu_think.md" cpu think "$base"
    run_logic_one "$f" "${OUTPUT_DIR}/logic/${base}/cpu_no_think.md" cpu no_think "$base"
    run_logic_one "$f" "${OUTPUT_DIR}/logic/${base}/vulkan_think.md" vulkan think "$base"
    run_logic_one "$f" "${OUTPUT_DIR}/logic/${base}/vulkan_no_think.md" vulkan no_think "$base"
  fi
done

if (( FAILURES > 0 )); then
  echo "done with $FAILURES failing run(s)." >&2
  exit 1
fi
echo "selected benchmarks finished (mode=$BENCH_MODE)." >&2
