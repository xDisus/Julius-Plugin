# 🧠 Julius — Token Economy Plugin for Claude Code

> *"Every token counts." — Julius Rock, 1987*

Julius is a Claude Code plugin that reduces token consumption by orchestrating
compression at the right points in the session lifecycle. It pairs well with two
external tools:

| Tool | What it compresses |
|------|-------------------|
| **[context-mode](https://github.com/cc-shared/context-mode)** | Tool output (often 60-80% of input) |
| **[caveman](https://github.com/JuliusBrussee/caveman)** | Model output |
| **Julius hooks** | Preprocessing, routing, large-file redirection, Bash-output compression |

> **On the savings numbers:** the percentages below are **rough estimates / targets**,
> not measured benchmarks. Actual savings depend heavily on workload. The metrics hook
> (`metrics-stop.sh`) records **real** per-turn token usage and cost; its "savings" figure
> is a heuristic tier multiplier, clearly labelled as an estimate.

## Quick Install

```bash
# One-liner (npm)
npx julius-plugin

# Or via Claude Code marketplace
/plugin marketplace add github:xDisus/Julius-Plugin
/plugin install julius@julius-plugin
```

## Usage

```
/julius            # Show current tier
/julius normal     # Zero quality loss
/julius pro        # Balanced compression
/julius beast      # Maximum savings
/julius-doctor     # Run diagnostic checks
/julius-stats      # Measured numbers: real token usage + bytes elided by compression
```

## Measuring real efficacy

Julius reports each lever it can measure **separately** — there is no single "total saved"
number, because some hooks add tokens (oracle, coaching) and some prevent reads
counterfactually (guards), neither of which a compression delta can see.

- **`/julius-stats`** — live, passive. `compress-output.sh` records the true orig-vs-compressed
  bytes of every call it touches; `metrics-stop.sh` records real API-counted usage from the
  transcript. Just work normally on `pro`/`beast`; the numbers accumulate in `~/.julius/metrics/`.
- **`bash tests/replay.sh <transcript.jsonl>`** — deterministic test. Replays the *real* tool
  outputs from a captured session through `compress-output.sh` at each tier and reports
  visible-bytes per tier vs control. Capture the transcript on `normal` (lossless) so the
  recorded outputs are raw. Isolates the compression lever — no model-nondeterminism confound.
- **`bash tests/benchmark.sh`** — same harness on synthetic heavy scenarios (no session needed).

## Tiers

| Tier | Est. savings | What's active | Risk |
|------|:-----------:|---------------|------|
| **Normal** ✅ | ~10% | Coach, task manifest, haiku routing | None |
| **Pro** ⚠️ | ~50-80%* | + Bash output compression, batch synthesis, agent pipelines | Low |
| **Beast** 🦍 | ~80-95%* | + large-file guard, context oracle, caveman agents | Medium |

\* Estimates. The biggest real savings come from pairing with **context-mode** (tool
output) and **caveman** (model output); Julius hooks alone contribute the smaller share.

---

## Features

### Normal (always on — lossless: nothing the model sees is elided)

| Feature | Mechanism | What it does |
|---------|-----------|-------------|
| **Turn Coach** 🏋️ | `Stop` hook | Reads the last assistant turn from the transcript; flags wasteful planning prose alongside tool calls. Advisory only (never blocks). |
| **Cheap-Pattern Coaching** 🧭 | `PreToolUse` (Bash) | Advisory nudges: `cat <file>` → Read, `cat \| grep` → Grep tool. Skips heredocs/targeted commands. Adds a hint; removes nothing. |
| **Task Manifest** ✅ | `TaskCreated` + `TaskCompleted` | Maintains a compact `[TASKS] 2/6 done. Active: …` digest. |
| **Haiku Routing** 🎯 | Agent `tier-router.md` | Trivial tasks delegated to haiku workers, freeing the main model. |

### Pro+ (deterministic compression — the default first pass; may elide output middles)

| Feature | Mechanism | What it does |
|---------|-----------|-------------|
| **Tool-Output Compression** ✂️ | `PostToolUse` (Bash, Read, Grep, Glob) | Deterministic, offline truncation (middle-out keeping head+tail+all error/warn lines), ANSI strip, consecutive-dup collapse, and list capping. Replaces output via `updatedToolOutput` (object for Bash, string for the rest). **Always preserves errors/paths; on any failure the original output is kept (no data loss); works without an API key.** Elides large-output middles — that's why it starts at Pro, not Normal. |
| **Repeated-Output Dedup** 🪞 | `PostToolUse` | Exact in-session repeats become `[same as earlier output of …]`. Bounded store, oldest evicted. |
| **Read-Range Prevention** 📐 | `PreToolUse` (Read) | Medium-size reads with no offset/limit get a pagination nudge — keep the whole file out of context. Advisory; yields the large band to Large-File Guard. |
| **Batch Synthesis** 🔗 | `PostToolBatch` | Cross-references parallel tool outputs into one dense synthesis. |
| **Agent Pipelines** 🔄 | `TeammateIdle` | When a teammate idles with pending work, redirects it. Capped by `max_reactivations`. |

### Beast only

| Feature | Mechanism | What it does |
|---------|-----------|-------------|
| **Large-File Guard** 📖 | `PreToolUse` on Read + `julius-reader` | >50-line reads are blocked and redirected to the haiku reader (JSON summary). Skipped inside subagents. |
| **Flash Semantic Fallback** 🔮 | `PostToolUse` (Bash) | Only when deterministic output is still over `flash_fallback_lines`, a Haiku pass semantically compresses it. Beast + Bash only. |
| **Context Oracle** 🔮 | `UserPromptSubmit` | Flash pre-processes non-trivial prompts into `TARGETS / APPROACH / WATCH`. Length-gated, cached by content hash. |
| **Compressed Workers** 🤖 | `julius-reader`, `julius-executor`, `julius-researcher` | Ultra-compressed agent prompts. Pairs with the external [caveman](https://github.com/JuliusBrussee/caveman) tool. |

> **Mechanism order:** deterministic compression runs first at every tier — it's free,
> offline, and never loses data. Flash (Haiku) is a **Beast-only fallback** for Bash,
> fired only when the deterministic result is still over budget. The oracle/synthesis
> hooks also call Haiku but are gated (length, batch size, caching). Without
> `ANTHROPIC_API_KEY`, every flash-backed path no-ops and the deterministic/original
> output is preserved.

---

## Architecture

### Hooks (8 lifecycle events)

```
UserPromptSubmit       → oracle-preprocess.sh   (Beast: flash pre-processes prompt)
PreToolUse Read        → large-file-guard.sh    (Beast: redirect large reads)
                       → read-grep-guard.sh     (Pro+: read-range nudge)
PreToolUse Bash        → coach-patterns.sh      (All: cheap-pattern coaching)
PostToolUse B/R/G/G    → compress-output.sh     (Pro+: deterministic; Beast: +flash)
PostToolBatch          → batch-synthesizer.sh   (Pro+: cross-reference batch)
Stop                   → turn-coach.sh          (All: efficiency coaching)
                       → metrics-stop.sh        (All: real token/cost metrics)
TeammateIdle           → keep-busy.sh           (Pro+: keep agents working)
TaskCreated/Completed  → task-manifest.sh       (All: compressed task list)
```
(PostToolUse matcher: `Bash|Read|Grep|Glob`.)

All hooks read the documented JSON event on **stdin** and respond via the correct
mechanism for their event (exit code, `additionalContext`, or `updatedToolOutput`).

### Agents (4 haiku agents)

| Agent | Purpose | Tools |
|-------|---------|-------|
| `tier-router` | Generic trivial tasks | Read, Bash, Glob, Grep |
| `julius-reader` | Read files, return JSON summary | Read, Grep, Glob |
| `julius-executor` | Run tests, lint, format, git ops | Bash, Read, Grep |
| `julius-researcher` | Web search & summarize | WebSearch, WebFetch |

### Scripts

| Script | Role | Dependencies |
|--------|------|-------------|
| `lib/julius-common.sh` | Shared helpers (state dir, tier, config, md5, dedup) — sourced by all hooks | `jq` |
| `lib/julius-compress.sh` | Deterministic compression primitives (strip/collapse/middle-out/cap) | `awk`, `sed` |
| `flash-client.sh` | Anthropic Haiku client | `curl`, `jq`, `ANTHROPIC_API_KEY` |
| `tier-setter.sh` | Writes active tier | `jq` |
| `turn-coach.sh` | Stop hook | `jq` |
| `metrics-stop.sh` | Stop hook (metrics) | `jq`, `bc` |
| `task-manifest.sh` | Task hooks | `jq` |
| `compress-output.sh` | PostToolUse compressor (Bash/Read/Grep/Glob) | `julius-compress.sh` |
| `large-file-guard.sh` | PreToolUse Read block | `jq` |
| `read-grep-guard.sh` | PreToolUse Read range nudge | `jq` |
| `coach-patterns.sh` | PreToolUse Bash coaching | `jq` |
| `batch-synthesizer.sh` | PostToolBatch hook | `flash-client.sh` |
| `oracle-preprocess.sh` | UserPromptSubmit hook | `flash-client.sh` |
| `keep-busy.sh` | TeammateIdle hook | `jq`, `git` |
| `julius-doctor.sh` | Diagnostics | `jq` |
| `julius-stats.sh` | Measured stats report (read-only) | `jq` |

---

## Project Structure

```
Julius-Plugin/
├── plugin.json                   # Plugin manifest
├── package.json                  # npm: npx julius-plugin
├── .claude-plugin/
│   └── marketplace.json          # Self-hosted marketplace
├── bin/
│   └── install.sh                # npx entrypoint
├── commands/
│   ├── julius.md                 # /julius normal|pro|beast
│   ├── julius-doctor.md          # /julius-doctor
│   └── julius-stats.md           # /julius-stats
├── agents/
│   ├── tier-router.md            # generic haiku worker
│   ├── julius-reader.md          # file analyst
│   ├── julius-executor.md        # test/lint/git worker
│   └── julius-researcher.md      # web researcher
├── hooks/
│   └── hooks.json                # 8 lifecycle hooks
├── scripts/                      # hook implementations (see table above)
├── lib/
│   ├── julius-common.sh          # shared helpers, sourced by hooks
│   ├── julius-compress.sh        # deterministic compression primitives
│   └── tier-config.json          # thresholds per tier
├── tests/
│   ├── test-all.sh               # smoke tests (existence/parse + behavior)
│   └── test-hooks.sh             # behavioral hook I/O tests with fixtures
└── docs/
    ├── requirements.md
    └── plan.md
```

---

## Requirements

- **Claude Code:** `npm install -g @anthropic-ai/claude-code`
- **Dependencies:** `jq`, `curl`, and `bc` (for metrics). Portable md5 falls back across
  `md5sum` (Linux) / `md5` (macOS).
- **API key:** `ANTHROPIC_API_KEY` (for the flash LLM in Pro/Beast). Auto-detected from
  `~/.claude/.env`. Without it, flash-backed hooks no-op safely.

## Development

```bash
git clone https://github.com/xDisus/Julius-Plugin.git
cd Julius-Plugin
bash tests/test-all.sh     # full suite (includes behavioral hook tests)
bash tests/test-hooks.sh   # hook I/O contract tests only
bash tests/benchmark.sh    # tool-output token savings per tier vs control
npm publish                # requires npm login
```

### Efficiency benchmark

`tests/benchmark.sh` measures model-visible tool-output size per tier vs control over
10 synthetic-but-realistic outputs (real `tool_response` shapes, no network). Estimated
token savings (chars/4 proxy, tool-output compression only):

| Tier | Saved vs control |
|------|:----------------:|
| Normal | 0% (lossless by design — compression off) |
| Pro | ~77% |
| Beast | ~85% (deterministic only; flash fallback would add more) |

Dedup turns an exact repeated output into an ~8-token back-reference (~99% on repeats).
Caveats: estimate not a real tokenizer; excludes oracle/coaching/hook overhead; real
workloads with small outputs save less (the threshold gate prevents churn).
```

## License

MIT — use freely, save tokens wisely.
