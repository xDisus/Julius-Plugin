# 🧠 Julius — Token Economy Plugin for Claude Code

> *"Julius Rock. Every token counts."*

Julius is a Claude Code plugin that cuts token consumption by **10-60%** without you noticing. Named after Chris's frugal father from *Everybody Hates Chris*.

## Quick Install

```bash
npx julius-plugin
```

Or via marketplace:

```bash
/plugin marketplace add github:xDisus/Julius-Plugin
/plugin install julius@julius-plugin
```

## Usage

```
/julius normal    # Zero quality loss — coach, manifest, safe routing
/julius pro       # Balanced — compression, summarization, batch synthesis
/julius beast     # Maximum savings — caveman agents, context oracle, full send
```

## What It Does

| Tier | Token Savings | Risk |
|------|:---:|:---:|
| **Normal** | ~10% | None |
| **Pro** | ~30% | Low (historical nuance may compress) |
| **Beast** | ~60% | Medium (subagents use haiku, docs compressed) |

### 11 Features

- 🤖 **Caveman agents** — subagents with ultra-compressed prompts (Beast)
- 📄 **Internal docs compressor** — CLAUDE.md → shorthand (Beast)
- 🎯 **Model-tier routing** — haiku for trivial tasks (All tiers)
- ✂️ **Output compression** — PostToolUse summarizes tool results (Pro+)
- 🗜️ **Smart compaction** — PreCompact preserves decisions, drops chatter (Pro+)
- 📖 **Subagent reader** — large files → haiku reader (Beast)
- 🔗 **Batch synthesis** — cross-reference parallel outputs (Pro+)
- 🔮 **Context oracle** — flash pre-processes prompts (Beast)
- 🔄 **Agent pipelines** — teammates stay alive between turns (Pro+)
- 🏋️ **Turn coach** — feedback on token efficiency (All tiers)
- ✅ **Task manifest** — compressed task lists (All tiers)

## Requirements

- Claude Code installed (`npm i -g @anthropic-ai/claude-code`)
- `ANTHROPIC_API_KEY` set in environment (for flash LLM calls in Pro/Beast)

## Docs

- [Requirements](docs/requirements.md)
- [Implementation Plan](docs/plan.md)

## License

MIT
