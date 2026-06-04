# 🧠 Julius — Token Economy Plugin for Claude Code

> *"Every token counts." — Julius Rock, 1987*

Julius cuts Claude Code token consumption by **10-60%** using lifecycle hooks as transparent middleware. The model never knows it's there — it just receives fewer tokens and responds the same.

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

| Tier | Token Savings | Risk | Active Features |
|------|:---:|:---:|-----------------|
| **Normal** ✅ | ~10% | None | Coach + Manifest + Haiku routing |
| **Pro** ⚠️ | ~30% | Low (historical nuance) | Above + Output compression + Batch synthesis + Summarization + Pipelines |
| **Beast** 🦍 | ~60% | Medium (haiku subagents) | Above + Caveman agents + Oracle + Docs compression + Subagent reader |

---

## All 11 Features

### Phase 1 — Normal (always on)

| # | Feature | Mechanism | What it does |
|---|---------|-----------|-------------|
| 1 | **Turn Coach** 🏋️ | `Stop` hook | Analyzes each turn for preamble waste (>20%). Injects `[JULIUS COACH]` if model uses too many "I'll" / "Let me" / "First" etc. |
| 2 | **Task Manifest** ✅ | `TaskCreated` + `TaskCompleted` | Maintains compressed `[TASKS] 2/6 done. Active: auth middleware` — no verbose task lists |
| 3 | **Haiku Routing** 🎯 | Agent `tier-router.md` | Trivial tasks (list, search, format, test) delegated to haiku agents. Frees main model for real work |

### Phase 2 — Compression Engine (Pro+)

| # | Feature | Mechanism | Threshold |
|---|---------|-----------|-----------|
| 4 | **Output Compression** ✂️ | `PostToolUse` on Bash/Read/Grep/Glob | Pro: >100 lines → flash summary. Beast: >20. Preserves errors/stacktraces |
| 5 | **Smart Compaction** 🗜️ | `PreCompact` | Blocks native compaction. Injects decision-focused summary. Pro: preserves last 15 turns. Beast: 8 |
| 6 | **Batch Synthesis** 🔗 | `PostToolBatch` | Cross-references parallel outputs. Detects imports, shared entities, relationships |
| 7 | **Subagent Reader** 📖 | `PreToolUse` on Read + Agent `caveman-reader.md` | Beast: >50 lines → blocks Read, delegates to haiku reader. Returns JSON `{summary, structure, edit_targets}` |

### Phase 3 — Beast Mode (Beast only)

| # | Feature | Mechanism | What it does |
|---|---------|-----------|-------------|
| 8 | **Caveman Agents** 🤖 | Agents: executor + researcher | Ultra-compressed prompts. No "I'll", no preamble. Just action verbs and results |
| 9 | **Docs Compression** 📄 | `SessionStart` hook | Compresses CLAUDE.md/AGENTS.md into caveman shorthand. Cached with hash |
| 10 | **Context Oracle** 🔮 | `UserPromptSubmit` hook | Flash pre-processes user prompt + project index. Returns `TARGETS: auth.py:145. APPROACH: check JWT. WATCH: Redis timeout` |
| 11 | **Agent Pipelines** 🔄 | `TeammateIdle` hook | Keeps subagents alive. Detects untested changes, pending tasks, reactivates with directed work |

---

## Architecture

### Hooks (10 lifecycle events)

```
SessionStart     → docs-compressor.sh      (Beast: compress project docs)
UserPromptSubmit → oracle-preprocess.sh    (Beast: flash pre-processes prompt)
  ↓
PreToolUse Read  → large-file-guard.sh      (Beast: redirect large reads)
PostToolUse      → compress-output.sh       (Pro+: summarize tool outputs)
PostToolBatch    → batch-synthesizer.sh     (Pro+: cross-reference batch)
  ↓
PreCompact       → smart-compact.sh         (Pro+: custom compaction)
Stop             → turn-coach.sh            (All: efficiency analysis)
TeammateIdle     → keep-busy.sh             (Pro+: keep agents working)
TaskCreated      → task-manifest.sh         (All: compressed task list)
TaskCompleted    → task-manifest.sh         (All: mark done)
```

### Agents (4 haiku agents)

| Agent | Purpose | Tools | Size |
|-------|---------|-------|------|
| `tier-router` | Generic trivial tasks | Read, Bash, Glob, Grep | ~250 tokens |
| `caveman-reader` | Read files, return JSON summary | Read, Grep, Glob | ~200 tokens |
| `caveman-executor` | Run tests, lint, format, git ops | Bash, Read, Grep | ~180 tokens |
| `caveman-researcher` | Web search & summarize | WebSearch, WebFetch | ~160 tokens |

### Scripts (11 bash scripts)

| Script | Lines | Dependencies |
|--------|:----:|-------------|
| `flash-client.sh` | 82 | `curl`, `jq`, `ANTHROPIC_API_KEY` |
| `tier-setter.sh` | 42 | `jq` |
| `turn-coach.sh` | 104 | `jq` |
| `task-manifest.sh` | 121 | `jq` |
| `compress-output.sh` | 78 | `flash-client.sh` |
| `smart-compact.sh` | 87 | `flash-client.sh` |
| `large-file-guard.sh` | 75 | — |
| `batch-synthesizer.sh` | 78 | `flash-client.sh` |
| `docs-compressor.sh` | 82 | `flash-client.sh` |
| `oracle-preprocess.sh` | 80 | `flash-client.sh` |
| `keep-busy.sh` | 109 | `jq`, `git` |

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
│   └── julius.md                 # /julius normal|pro|beast
├── agents/
│   ├── tier-router.md            # F3: generic haiku worker
│   ├── caveman-reader.md         # F1: file analyst
│   ├── caveman-executor.md       # F1: test/lint/git worker
│   └── caveman-researcher.md     # F1: web researcher
├── hooks/
│   └── hooks.json                # 10 lifecycle hooks
├── scripts/
│   ├── flash-client.sh           # Shared: Anthropic Haiku API
│   ├── tier-setter.sh            # Writes active tier
│   ├── turn-coach.sh             # Stop hook
│   ├── task-manifest.sh          # Task hooks
│   ├── compress-output.sh        # PostToolUse hook
│   ├── smart-compact.sh          # PreCompact hook
│   ├── large-file-guard.sh       # PreToolUse Read hook
│   ├── batch-synthesizer.sh      # PostToolBatch hook
│   ├── docs-compressor.sh        # SessionStart hook
│   ├── oracle-preprocess.sh      # UserPromptSubmit hook
│   └── keep-busy.sh              # TeammateIdle hook
├── lib/
│   └── tier-config.json          # Thresholds per tier
├── tests/
│   └── test-all.sh               # Smoke tests
└── docs/
    ├── requirements.md
    └── plan.md
```

---

## Requirements

- **Claude Code:** `npm install -g @anthropic-ai/claude-code`
- **Dependencies:** `jq`, `curl` (standard on macOS/Linux)
- **API key:** `ANTHROPIC_API_KEY` (for flash LLM in Pro/Beast). Auto-detected from `~/.claude/.env`

## Development

```bash
git clone https://github.com/xDisus/Julius-Plugin.git
cd Julius-Plugin
# Test locally
bash tests/test-all.sh
# Publish to npm (requires npm login)
npm publish
```

## License

MIT — use freely, save tokens wisely.
