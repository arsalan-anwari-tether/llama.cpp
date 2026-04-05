# Qwen3 / Qwen3.5 helper script (`qwen3-llama-run.sh`)

The script [`scripts/qwen3-llama-run.sh`](../scripts/qwen3-llama-run.sh) runs [`llama-cli`](../tools/main/README.md) or [`llama-bench`](../tools/llama-bench/README.md) with sensible defaults for **Qwen3** and **Qwen3.5** models that support a **thinking** (reasoning) channel in the Jinja chat template.

It does not replace reading the full `llama-cli` / `llama-bench` documentation; it only saves you from repeating the same flags for this family of models.

## Prerequisites

Build the project so the binaries exist. The script expects:

- `build/bin/llama-cli` when using `--tool=cli` (default)
- `build/bin/llama-bench` when using `--tool=bench`

Override locations with environment variables `LLAMA_CLI` and `LLAMA_BENCH` if needed.

## What the script sets for `llama-cli`

For **`--tool=cli`**, the script always passes:

| Flag | Purpose |
|------|--------|
| `-m <path>` | From `--input=` |
| `-c <size>` | Context size (default: 4096 or `$CTX_SIZE`). Prevents OOM on mobile devices. |
| `-ub <size>` | Micro-batch size (default: 256 or `$UBATCH_SIZE`). Reduces memory pressure. |
| `--jinja` | Required so chat-template thinking / `reasoning-budget` apply (see note below) |
| `--reasoning-budget -1` | If `--mode=think` (default): do not disable thinking in the template |
| `--reasoning-budget 0` | If `--mode=no_think`: disable thinking in the template |
| `--temp <float>` | Only if you set `--temp=` |

Then it appends any arguments you pass **after** `--` (see below).

Thinking behavior matches the same Jinja / `enable_thinking` idea used by `llama-server` in this tree; see [`tools/server/README.md`](../tools/server/README.md) for `--reasoning-budget`, `--chat-template-kwargs`, and related options.

## What the script does for `llama-bench`

For **`--tool=bench`**, the script runs:

`llama-bench -m <path> <args after -->`

It does **not** pass `--jinja`, `--reasoning-budget`, or `--temp`. `llama-bench` measures prompt-processing and token-generation throughput only; it does not apply chat templates, so **thinking mode does not apply**. The script prints a short note when you use bench.

## Script options (before `--`)

Only these may appear **before** the separator `--`:

| Option | Required | Description |
|--------|----------|-------------|
| `--input=PATH` | Yes | Path to the GGUF file. |
| `--mode=think` or `no_think` | No | Default: `think`. Affects **`llama-cli` only** (`--reasoning-budget`). |
| `--temp=FLOAT` | No | Forwarded as `--temp FLOAT` to **`llama-cli` only**. |
| `--ctx-size=N` | No | Context size (default: `$CTX_SIZE` or 4096). Affects **`llama-cli` only**. |
| `--ubatch-size=N` | No | Micro-batch size (default: `$UBATCH_SIZE` or 256). Affects **`llama-cli` only**. |
| `--tool=cli` or `bench` | No | Default: `cli`. |
| `-h` / `--help` | No | Print script usage (header + short option list). |

Any other token before `--` is an error; the script suggests using `--` for `llama-cli` / `llama-bench` flags.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LLAMA_CLI` | `build/bin/llama-cli` | Path to `llama-cli` binary |
| `LLAMA_BENCH` | `build/bin/llama-bench` | Path to `llama-bench` binary |
| `CTX_SIZE` | `4096` | Default context size for `llama-cli` |
| `UBATCH_SIZE` | `256` | Default micro-batch size for `llama-cli` |

## Passing flags to `llama-cli` or `llama-bench` (Rust-style `--`)

Use a **double dash** to separate script options from everything that should go to the underlying binary (same idea as `cargo run --`):

```text
./scripts/qwen3-llama-run.sh [script options] -- [llama-cli or llama-bench args]
```

- If you **do not** need any extra flags for the binary, you can **omit** `--` entirely.
- If you **do** need extra flags (`-p`, `-n`, `-ngl`, `-c`, etc.), put them **after** `--`.

Examples:

```bash
# Script options only (no extra llama-cli flags)
./scripts/qwen3-llama-run.sh --input=model.gguf --mode=no_think --temp=0.6

# With llama-cli flags after --
./scripts/qwen3-llama-run.sh --input=model.gguf --mode=think --temp=0.6 -- -p "Hello" -n 128 -ngl 99

# Smaller context for memory-constrained devices (mobile, etc.)
./scripts/qwen3-llama-run.sh --input=model.gguf --ctx-size=2048 --ubatch-size=128 -- -p "Hello"

# Benchmark (mode/temp/ctx-size/ubatch-size ignored; forward bench flags after --)
./scripts/qwen3-llama-run.sh --input=model.gguf --tool=bench -- -ngl 99
```

## Final command shape

For **`llama-cli`**, the executed command is equivalent to:

```bash
llama-cli -m <input> -c <ctx-size> -ub <ubatch-size> --jinja --reasoning-budget <-1|0> [--temp …] <extra args after -->
```

For **`llama-bench`**:

```bash
llama-bench -m <input> <extra args after -->
```

The script uses `set -x` before `exec`, so the shell prints the full command line before running it.

## Memory considerations

Qwen3 / Qwen3.5 models have large default context sizes (32K+ tokens). On mobile devices or systems with limited RAM, the default context size would cause out-of-memory crashes. The script uses conservative defaults (`-c 4096 -ub 256`) that work on most devices.

For very constrained devices (e.g., 4GB RAM phones), reduce further:

```bash
./scripts/qwen3-llama-run.sh --input=model.gguf --ctx-size=2048 --ubatch-size=128 -- -p "Hello"
# Or via environment:
CTX_SIZE=2048 UBATCH_SIZE=128 ./scripts/qwen3-llama-run.sh --input=model.gguf -- -p "Hello"
```

## See also

- [README: Quick start / running a model](../README.md#quick-start)
- [docs/build.md](build.md) — build options
- [tools/main/README.md](../tools/main/README.md) — `llama-cli` options
- [tools/llama-bench/README.md](../tools/llama-bench/README.md) — `llama-bench` options
