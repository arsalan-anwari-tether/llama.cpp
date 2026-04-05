# Batch CPU vs Vulkan benchmarks (`run_qwen3_benchmark.sh`)

The script `[scripts/run_qwen3_benchmark.sh](../scripts/run_qwen3_benchmark.sh)` runs Qwen3 benchmark batches over every `*.gguf` file in a directory. It supports:

- **Inference** via `[llama-bench](../tools/llama-bench/README.md)`
- **Logic** prompt runs via `[llama-cli](../tools/main/README.md)`
- **Mode selection** via `--bench-mode={all|inference|logic}`

For each model, the script compares:

- **CPU-only**: `--device none -ngl 0`
- **GPU offload**: `-ngl 999` (typically Vulkan on builds that use it)

The CPU mode is now a true CPU-only run because it uses `--device none`, not just `-ngl 0`.

## Output layout

Under `**--output-dir`** (default: same as `--input-dir`), the script creates one subdirectory per model:

- `**inference/<model>/cpu.json**`
- `**inference/<model>/vulkan.json**`
- `**logic/<model>/cpu_think.md**`
- `**logic/<model>/cpu_no_think.md**`
- `**logic/<model>/vulkan_think.md**`
- `**logic/<model>/vulkan_no_think.md**`

`<model>` is the GGUF filename without the `.gguf` suffix, for example `Qwen3-1.7B-Q4_K_M`.

## Expected binary location

The script resolves the repository root from its own path and defaults to:

- `build/bin/llama-bench` — override with `**LLAMA_BENCH**`
- `build/bin/llama-cli` — override with `**LLAMA_CLI**`

## Usage

```bash
./scripts/run_qwen3_benchmark.sh --input-dir=/path/to/ggufs [--output-dir=/path/to/results] [--bench-mode=all|inference|logic] -- [extra llama-bench arguments]
```

- `**--input-dir**` — Required. Directory containing `*.gguf` files (non-recursive; only the top level of that directory).
- `**--output-dir**` — Optional. Directory for `**inference/**` and `**logic/**`; defaults to the same path as `**--input-dir**`.
- `**--bench-mode**` — Select which parts to run:
  - `all` — run both inference and logic
  - `inference` — run only `llama-bench`
  - `logic` — run only `llama-cli`
- `**--**` — Everything after `--` is passed through to `llama-bench` only. The script sets `**-m**`, the CPU/GPU device flags, and `**-o json**` itself so those stay consistent. In `--bench-mode=logic`, arguments after `--` are accepted but unused.

## Benchmark defaults

### Inference defaults

The script uses these `llama-bench` defaults unless you override them via environment variables:

- `BENCH_P=256`
- `BENCH_N=64`
- `BENCH_R=2`

`llama-bench` upstream defaults are larger (`-p 512 -n 128 -r 5`), so this script is intentionally faster by default.

### Logic defaults

The logic benchmark uses the same fixed prompt set for both modes, but it now has separate default sampling flags for thinking and non-thinking runs.

- **Thinking**

```bash
--temp 1.0 --top-k 20 --top-p 0.95 --min-p 0 --repeat-penalty 1.0 --presence-penalty 1.5
```

- **Non-thinking**

```bash
--temp 0.7 --top-k 20 --top-p 0.8 --min-p 0 --repeat-penalty 1.0 --presence-penalty 1.5
```

The default generation and memory limits are:

- `LOGIC_N_THINK=512`
- `LOGIC_N_NO_THINK=512`
- `LOGIC_TIMEOUT_SEC=300`
- `LOGIC_CTX_SIZE=4096` — context size (prevents OOM on mobile/resource-constrained devices)
- `LOGIC_UBATCH_SIZE=256` — micro-batch size (reduces memory pressure)

Each logic question is wrapped with the shell `timeout` command. If a run exceeds `LOGIC_TIMEOUT_SEC`, the script terminates that `llama-cli` process, records the partial stdout that was produced so far, and then continues to the next question.

You can override the sampling flags with:

- `LOGIC_CLI_EXTRA_THINK`
- `LOGIC_CLI_EXTRA_NO_THINK`

For backward compatibility, `LOGIC_CLI_EXTRA` is still accepted as a shared fallback for both modes if the per-mode variables are not set.

## Examples

Run everything with defaults:

```bash
./scripts/run_qwen3_benchmark.sh --input-dir="$HOME/models/qwen3-gguf"
```

Run only inference so you can iterate faster on throughput:

```bash
./scripts/run_qwen3_benchmark.sh --input-dir="$HOME/models/qwen3-gguf" -- -p 512 -n 128 -r 3
```

Run inference only with explicit mode selection:

```bash
./scripts/run_qwen3_benchmark.sh --input-dir="$HOME/models/qwen3-gguf" --bench-mode=inference -- -p 512 -n 128 -r 3
```

Run only logic prompts:

```bash
./scripts/run_qwen3_benchmark.sh --input-dir="$HOME/models/qwen3-gguf" --bench-mode=logic
```

Send output to a separate results directory:

```bash
./scripts/run_qwen3_benchmark.sh --input-dir="$HOME/models/qwen3-gguf" --output-dir="$HOME/results/qwen3"
```

Override logic defaults differently for think and no-think:

```bash
LOGIC_CLI_EXTRA_THINK="--temp 0.6 --top-k 40 --top-p 0.95 --repeat-penalty 1.10 --presence-penalty 0.3" \
LOGIC_CLI_EXTRA_NO_THINK="--temp 0.1 --top-k 10 --top-p 0.8 --repeat-penalty 1.02 --presence-penalty 0.0" \
./scripts/run_qwen3_benchmark.sh --input-dir="$HOME/models/qwen3-gguf" --bench-mode=logic
```

Run logic with a shorter timeout:

```bash
LOGIC_TIMEOUT_SEC=120 ./scripts/run_qwen3_benchmark.sh --input-dir="$HOME/models/qwen3-gguf" --bench-mode=logic
```

Run logic with smaller context size (for mobile devices with limited RAM):

```bash
LOGIC_CTX_SIZE=2048 LOGIC_UBATCH_SIZE=128 ./scripts/run_qwen3_benchmark.sh --input-dir="$HOME/models/qwen3-gguf" --bench-mode=logic
```

## Running in the background (Termux and other environments)

Long benchmark runs are often started in a shell session that you close. On Android **Termux**, the process may also be stopped when the device sleeps unless you keep the CPU awake.

### Redirect stdout and stderr to a log file

Run the script and tee to a log so you keep a full transcript while still watching progress:

```bash
./scripts/run_qwen3_benchmark.sh --input-dir=/path/to/gguf --bench-mode=inference -- -p 512 -n 128 2>&1 | tee bench.log
```

Or append-only:

```bash
./scripts/run_qwen3_benchmark.sh --input-dir=/path/to/gguf --bench-mode=all >>bench.log 2>&1 &
```

### Background with `nohup`

`nohup` keeps the process from receiving a hangup signal when the terminal disconnects, and typically sends output to `nohup.out` unless you redirect:

```bash
nohup ./scripts/run_qwen3_benchmark.sh --input-dir=/path/to/gguf --bench-mode=logic >>bench.log 2>&1 &
echo $!   # PID to remember for kill or monitoring
```

You can `**tail -f bench.log**` in another session to watch status. JSON and Markdown results go under `**--output-dir**` (or `**--input-dir**` if you omitted `**--output-dir**`); the log is for messages and any errors from the shell or binary.

### Termux: keep the device awake (`termux-wake-lock`)

While Termux is in the foreground, acquire a wake lock so the CPU does not idle the session mid-run (behavior depends on device and battery settings):

```bash
termux-wake-lock
./scripts/run_qwen3_benchmark.sh --input-dir=/path/to/gguf --bench-mode=all -- ...
termux-wake-unlock
```

For unattended jobs, combine with `nohup` and logging; release the lock when finished so the device can sleep normally.

### Why this matters

- `**nohup` / background `&**` — Survive closing the SSH or Termux terminal session (still subject to OS killing background apps under memory pressure).
- **Wake lock** — Reduces the chance that the device suspends the process during long GPU/CPU runs.
- **Log + `tail -f`** — Confirms which model is running and catches failures without opening each JSON file.

### Memory considerations for mobile devices

Qwen3 / Qwen3.5 models have large default context sizes (32K+ tokens). On mobile devices with limited RAM, allocating a large KV cache can cause out-of-memory crashes that terminate the SSH connection or Termux session entirely.

The script uses sensible defaults (`LOGIC_CTX_SIZE=4096`, `LOGIC_UBATCH_SIZE=256`) that work on most mobile devices. If you still encounter OOM crashes:

```bash
# For very constrained devices (e.g., 4GB RAM phones)
LOGIC_CTX_SIZE=2048 LOGIC_UBATCH_SIZE=128 ./scripts/run_qwen3_benchmark.sh --input-dir=... --bench-mode=logic
```

If the device crashes during "Loading model..." in the logic phase, reduce `LOGIC_CTX_SIZE` further or use a smaller quantized model.

## See also

- `[docs/qwen3-llama-run.md](qwen3-llama-run.md)` — Single-model Qwen3 helper for `llama-cli` / `llama-bench`
- `[tools/llama-bench/README.md](../tools/llama-bench/README.md)` — Full `llama-bench` options and JSON output shape

