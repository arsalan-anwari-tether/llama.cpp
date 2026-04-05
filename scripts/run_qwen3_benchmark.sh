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

# Auto-detect problematic GPUs and apply workarounds
# Mali GPUs (ARM) have issues with cooperative matrix and hybrid models like Qwen3.5
# Adreno GPUs (Qualcomm) have issues with async execution causing VK_ERROR_DEVICE_LOST
detect_gpu_workarounds() {
  local gpu_type=""
  local gpu_name=""

  # Method 1: Check for Mali GPU via /sys filesystem (Android/Linux)
  if [[ -d /sys/class/devfreq ]] && ls /sys/class/devfreq/ 2>/dev/null | grep -qi mali; then
    gpu_type="mali"
    gpu_name="Mali (detected via sysfs)"
  fi

  # Method 2: Check for Adreno via /sys filesystem
  if [[ -z "$gpu_type" ]] && [[ -d /sys/class/kgsl ]]; then
    gpu_type="adreno"
    gpu_name="Adreno (detected via kgsl sysfs)"
  fi

  # Method 3: Check via vulkaninfo if available
  if [[ -z "$gpu_type" ]] && command -v vulkaninfo >/dev/null 2>&1; then
    local vk_info
    vk_info="$(vulkaninfo --summary 2>/dev/null || true)"
    if echo "$vk_info" | grep -qi "mali"; then
      gpu_type="mali"
      gpu_name="Mali (detected via vulkaninfo)"
    elif echo "$vk_info" | grep -qi "adreno"; then
      gpu_type="adreno"
      gpu_name="Adreno (detected via vulkaninfo)"
    fi
  fi

  # Method 4: Check Android device info for Mali
  if [[ -z "$gpu_type" ]] && [[ -f /system/build.prop || -d /data/data/com.termux ]]; then
    if [[ -d /sys/devices ]] && find /sys/devices -maxdepth 4 -name "mali*" 2>/dev/null | grep -q .; then
      gpu_type="mali"
      gpu_name="Mali (detected via /sys/devices)"
    elif [[ -d /sys/devices ]] && find /sys/devices -maxdepth 4 -name "kgsl*" 2>/dev/null | grep -q .; then
      gpu_type="adreno"
      gpu_name="Adreno (detected via /sys/devices)"
    fi
  fi

  # Apply GPU-specific workarounds
  case "$gpu_type" in
    mali)
      echo "note: Detected $gpu_name - applying Vulkan workarounds for hybrid models" >&2
      # Mali: Disable cooperative matrix (descriptor set issues with hybrid models)
      if [[ -z "${GGML_VK_DISABLE_COOPMAT+x}" ]]; then
        export GGML_VK_DISABLE_COOPMAT=1
        echo "  -> Set GGML_VK_DISABLE_COOPMAT=1 (override with GGML_VK_DISABLE_COOPMAT=0)" >&2
      fi
      # Mali: Disable graph optimization
      if [[ -z "${GGML_VK_DISABLE_GRAPH_OPTIMIZE+x}" ]]; then
        export GGML_VK_DISABLE_GRAPH_OPTIMIZE=1
        echo "  -> Set GGML_VK_DISABLE_GRAPH_OPTIMIZE=1 (override with GGML_VK_DISABLE_GRAPH_OPTIMIZE=0)" >&2
      fi
      ;;
    adreno)
      echo "note: Detected $gpu_name - Vulkan not supported for hybrid models (Qwen3.5, etc.)" >&2
      echo "  -> Vulkan benchmarks will be skipped for hybrid models (use SKIP_VULKAN_HYBRID=0 to override)" >&2
      # Mark that we should skip Vulkan for hybrid models on Adreno
      # The Adreno driver crashes with VK_ERROR_DEVICE_LOST when running Gated Delta Net shaders
      if [[ -z "${SKIP_VULKAN_HYBRID+x}" ]]; then
        export SKIP_VULKAN_HYBRID=1
      fi
      ;;
  esac

  # Export GPU type for use in other functions
  export DETECTED_GPU_TYPE="$gpu_type"
}

# Run GPU detection
detect_gpu_workarounds

# Check if a model filename indicates a hybrid architecture (Qwen3.5, Kimi-Linear, etc.)
# These models use Gated Delta Net which causes Vulkan driver crashes on some mobile GPUs
is_hybrid_model() {
  local model_name="$1"
  # Match Qwen3.5 (not Qwen3), Kimi-Linear, and other known hybrid architectures
  if echo "$model_name" | grep -qiE "qwen3\.5|qwen35|kimi.?linear"; then
    return 0
  fi
  return 1
}

# Check if we should skip Vulkan for this model
should_skip_vulkan() {
  local model_path="$1"
  local model_name
  model_name="$(basename "$model_path")"

  if [[ "${SKIP_VULKAN_HYBRID:-0}" == "1" ]] && is_hybrid_model "$model_name"; then
    return 0
  fi
  return 1
}

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
  local tmp_stderr
  tmp_stderr="$(mktemp)"
  if ! "${cmd[@]}" >"$out_json" 2>"$tmp_stderr"; then
    local err_output
    err_output="$(cat "$tmp_stderr" 2>/dev/null || true)"
    rm -f "$tmp_stderr"

    local error_log="error.log"
    local is_vulkan_error=false

    # Check for specific Vulkan/GPU errors
    if [[ "$label" == "vulkan" ]] && echo "$err_output" | grep -qiE "GGML_ASSERT|vulkan|descriptor_set|Vulkan"; then
      is_vulkan_error=true
      echo "error: llama-bench failed for $model_path ($label) - Vulkan backend error (model may not be fully supported on this GPU)" >&2
      echo "  Hint: Hybrid models (Qwen3.5, Mamba, etc.) may require GPU features not available on all devices." >&2
      echo "  Try running with CPU only: --bench-mode=inference -- --device none -ngl 0" >&2
      echo "  Full error logged to: $error_log" >&2
    else
      echo "error: llama-bench failed for $model_path ($label)" >&2
    fi

    if [[ -n "$err_output" ]]; then
      echo "  stderr: ${err_output:0:500}" >&2
    fi

    # Write detailed error to error.log for analysis
    {
      echo "========================================================================"
      echo "ERROR REPORT - $(date -Iseconds 2>/dev/null || date)"
      echo "========================================================================"
      echo "Model: $model_path"
      echo "Backend: $label"
      echo "Output file: $out_json"
      echo "Vulkan error detected: $is_vulkan_error"
      echo ""
      echo "Command:"
      printf '  %q ' "${cmd[@]}"
      echo ""
      echo ""
      echo "Environment:"
      echo "  LLAMA_BENCH=$LLAMA_BENCH"
      echo "  BENCH_P=$BENCH_P BENCH_N=$BENCH_N BENCH_R=$BENCH_R"
      if command -v uname >/dev/null 2>&1; then
        echo "  System: $(uname -a)"
      fi
      echo ""
      echo "Full stderr output:"
      echo "------------------------------------------------------------------------"
      echo "$err_output"
      echo "------------------------------------------------------------------------"
      echo ""
    } >> "$error_log"

    FAILURES=$((FAILURES + 1))
    return 1
  fi
  rm -f "$tmp_stderr"
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
  local cmd=("$LLAMA_CLI" -m "$model_path" --jinja -c "$LOGIC_CTX_SIZE" -ub "$LOGIC_UBATCH_SIZE" --quiet)
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
| **Output mode** | \`--quiet\` (suppress all UI output, only model response to stdout) |

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

  # Check if we should skip Vulkan for this model (hybrid models on Adreno)
  skip_vulkan=false
  if should_skip_vulkan "$f"; then
    skip_vulkan=true
    echo "note: Skipping Vulkan benchmarks for $base (hybrid model on ${DETECTED_GPU_TYPE:-unknown} GPU)" >&2
  fi

  if is_inference_enabled; then
    mkdir -p "${OUTPUT_DIR}/inference/${base}"
    run_one "$f" "${OUTPUT_DIR}/inference/${base}/cpu.json" cpu || true
    if [[ "$skip_vulkan" == "false" ]]; then
      run_one "$f" "${OUTPUT_DIR}/inference/${base}/vulkan.json" vulkan || true
    else
      echo "==> vulkan: $base SKIPPED (not supported on this GPU)" >&2
    fi
  fi

  if is_logic_enabled; then
    mkdir -p "${OUTPUT_DIR}/logic/${base}"
    run_logic_one "$f" "${OUTPUT_DIR}/logic/${base}/cpu_think.md" cpu think "$base"
    run_logic_one "$f" "${OUTPUT_DIR}/logic/${base}/cpu_no_think.md" cpu no_think "$base"
    if [[ "$skip_vulkan" == "false" ]]; then
      run_logic_one "$f" "${OUTPUT_DIR}/logic/${base}/vulkan_think.md" vulkan think "$base"
      run_logic_one "$f" "${OUTPUT_DIR}/logic/${base}/vulkan_no_think.md" vulkan no_think "$base"
    else
      echo "==> vulkan logic: $base SKIPPED (not supported on this GPU)" >&2
    fi
  fi
done

if (( FAILURES > 0 )); then
  echo "done with $FAILURES failing run(s)." >&2
  exit 1
fi
echo "selected benchmarks finished (mode=$BENCH_MODE)." >&2
