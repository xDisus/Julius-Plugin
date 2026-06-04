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
```

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

### Normal (always on)

| Feature | Mechanism | What it does |
|---------|-----------|-------------|
| **Turn Coach** 🏋️ | `Stop` hook | Reads the last assistant turn from the transcript; flags wasteful planning prose alongside tool calls. Advisory only (never blocks). |
| **Task Manifest** ✅ | `TaskCreated` + `TaskCompleted` | Maintains a compact `[TASKS] 2/6 done. Active: …` digest. |
| **Haiku Routing** 🎯 | Agent `tier-router.md` | Trivial tasks delegated to haiku workers, freeing the main model. |

### Pro+

| Feature | Mechanism | Threshold |
|---------|-----------|-----------|
| **Bash Output Compression** ✂️ | `PostToolUse` (Bash only) | Pro: >150 lines, Beast: >80. Replaces stdout via `updatedToolOutput`, preserving errors/paths. On any failure the original output is kept (no data loss). |
| **Batch Synthesis** 🔗 | `PostToolBatch` | Cross-references parallel tool outputs into one dense synthesis. |
| **Agent Pipelines** 🔄 | `TeammateIdle` | When a teammate idles with pending work (active tasks / untested changes), redirects it. Capped by `max_reactivations`. |

### Beast only

| Feature | Mechanism | What it does |
|---------|-----------|-------------|
| **Large-File Guard** 📖 | `PreToolUse` on Read + `julius-reader` | >50-line reads are blocked and redirected to the haiku reader (returns a JSON summary). Skipped inside subagents so the reader itself can read. |
| **Context Oracle** 🔮 | `UserPromptSubmit` | Flash pre-processes non-trivial prompts into `TARGETS / APPROACH / WATCH`. Gated by prompt length and cached by content hash to avoid repeat calls. |
| **Compressed Workers** 🤖 | `julius-reader`, `julius-executor`, `julius-researcher` | Ultra-compressed agent prompts for mechanical tasks. Pairs with the external [caveman](https://github.com/JuliusBrussee/caveman) tool. |

> **Note on cost:** the compression/oracle/synthesis hooks call the Anthropic Haiku API
> on the critical path. They are gated (size thresholds, prompt-length gate, caching) so
> trivial operations don't pay a network round-trip. Without `ANTHROPIC_API_KEY` these
> hooks degrade gracefully — they no-op and the original output/prompt is preserved.

---

## Architecture

### Hooks (8 lifecycle events)

```
UserPromptSubmit → oracle-preprocess.sh    (Beast: flash pre-processes prompt)
PreToolUse Read  → large-file-guard.sh     (Beast: redirect large reads)
PostToolUse Bash → compress-output.sh      (Pro+: replace large Bash stdout)
PostToolBatch    → batch-synthesizer.sh    (Pro+: cross-reference batch)
Stop             → turn-coach.sh           (All: efficiency coaching)
                 → metrics-stop.sh         (All: real token/cost metrics)
TeammateIdle     → keep-busy.sh            (Pro+: keep agents working)
TaskCreated      → task-manifest.sh        (All: compressed task list)
TaskCompleted    → task-manifest.sh        (All: mark done)
```

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
| `lib/julius-common.sh` | Shared helpers (state dir, tier, config, portable md5) — sourced by all hooks | `jq` |
| `flash-client.sh` | Anthropic Haiku client | `curl`, `jq`, `ANTHROPIC_API_KEY` |
| `tier-setter.sh` | Writes active tier | `jq` |
| `turn-coach.sh` | Stop hook | `jq` |
| `metrics-stop.sh` | Stop hook (metrics) | `jq`, `bc` |
| `task-manifest.sh` | Task hooks | `jq` |
| `compress-output.sh` | PostToolUse Bash hook | `flash-client.sh` |
| `large-file-guard.sh` | PreToolUse Read hook | `jq` |
| `batch-synthesizer.sh` | PostToolBatch hook | `flash-client.sh` |
| `oracle-preprocess.sh` | UserPromptSubmit hook | `flash-client.sh` |
| `keep-busy.sh` | TeammateIdle hook | `jq`, `git` |
| `julius-doctor.sh` | Diagnostics | `jq` |

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
│   └── julius-doctor.md          # /julius-doctor
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
npm publish                # requires npm login
```

## License

MIT — use freely, save tokens wisely.
