# Requirements — Input / Tool-Output Token Savings

**Date:** 2026-06-04
**Status:** Draft (brainstorm output, ready for `/ce-plan`)
**Scope tier:** Deep — feature

## Problem

Julius reduces token spend, but its input-side savings are thin and architecturally
inverted. Tool output and file reads are the biggest input-token consumer (often
60–80% of input). Today only `compress-output.sh` touches tool output, it covers
**Bash only**, and it calls the Haiku flash API per invocation — adding cost and
latency on the critical path. `large-file-guard.sh` redirects large Reads but
everything else (Grep, Glob, medium files, build/test/log output) flows into the
main context uncompressed.

The core architectural flaw: **flash-first**. A network LLM call is the default
compression mechanism, so the cheapest, safest wins (stripping noise, truncating
logs) pay an API + latency tax they shouldn't.

## Users / Beneficiary

Julius users running token-heavy coding sessions — especially read/grep/build/test
heavy work where tool output dominates input. The plugin's own identity is token
economy, so this is a direct extension of its core promise, not a new audience.

## Goal & Core Reframe

Capture input-token savings by **inverting the mechanism order**:

> Deterministic local compression is the default first pass at every tier.
> Flash becomes a rare semantic fallback (Beast only).

Then layer prevention (stop big output entering context) and behavioral coaching
on top, mapped to the existing tiers.

## Decisions (settled in brainstorm)

| Decision | Choice |
|----------|--------|
| Target cost | Input — tool output / context |
| Overhead model | Mix per tier (Normal=deterministic, Pro=+delegation, Beast=+flash fallback) |
| Scope | A + B + C (all three directions) |
| Mechanism order | Deterministic-first; flash demoted to semantic fallback |

## Scope — Three Directions

### A. Deterministic compression (no API) — the default pass

Pure bash/awk, zero network, zero latency, works without `ANTHROPIC_API_KEY`,
always net-positive.

- **Middle-out truncator**: keep head N + tail N + every line matching
  `error|warn|fail|traceback|exception` (case-insensitive); collapse the middle to
  `[… X lines elided …]`.
- **Noise stripping**: ANSI escape codes, progress bars, consecutive duplicate lines.
- **Repeated-output dedup**: hash tool outputs within a session; replace an exact
  repeat with `[same as earlier output of <cmd>]`.
- Applies to Bash, Grep, Glob output (and Read where output shape permits).

### B. Prevention over compression — keep big output out of context

- **Read-range defaulting**: `PreToolUse` on Read without offset/limit on a
  medium-size file → nudge/inject pagination so the model reads in pages.
- **Grep/Glob result cap**: >N matches → first N + `(M more in: <files>)`.
- **Explorer subagent**: multi-file investigation (chained grep+read) delegated to
  an agent with its own context; main context receives only the synthesis. Extends
  `julius-reader` → a `julius-explorer` role.

### C. Behavioral coaching (advisory, near-zero cost)

`PreToolUse` / coach nudges steering the model toward cheap patterns: targeted grep
over `cat`, head/tail, batching reads, routing heavy commands through context-mode.

## Tier Mapping

| Tier | A (deterministic) | B (prevention/delegation) | C (coaching) | Flash fallback |
|------|:----------------:|:-------------------------:|:------------:|:--------------:|
| Normal | ✅ | — | ✅ | — |
| Pro | ✅ | ✅ | ✅ | — |
| Beast | ✅ | ✅ | ✅ | ✅ (semantic only, when deterministic insufficient) |

## Success Criteria

- **Net-positive at every tier**: no technique costs more (tokens+latency) than it
  saves. Normal tier adds zero API cost and zero added latency.
- **No data loss**: errors, stack traces, file paths, line numbers always preserved
  verbatim. On any compression failure, original output is kept (existing invariant).
- **Offline-safe**: Normal and the deterministic pass work with no API key.
- **Measurable**: `metrics-stop.sh` reflects real reduction; deterministic vs flash
  contribution distinguishable.

## Non-Goals / Deferred

- **Model output compression** — caveman already owns this (output tokens).
- **Context-window longevity / compaction** — a different target; out of this brainstorm.
- Per-technique config knobs beyond what tier-gating needs (apply YAGNI).

## Dependencies / Assumptions (resolved via spike 2026-06-04)

- **`updatedToolOutput` shape per tool** — RESOLVED from the hooks doc:
  - `tool_response` is "a serialized **string** or content-block array".
  - **Bash** is the only structured shape: `{stdout,stderr,interrupted,isImage}`.
  - **Read / Grep / Glob outputs are strings** (the PostToolBatch example shows Read
    as a line-number-prefixed string; Grep's `output_mode` content/files/count all
    yield strings). So `updatedToolOutput` = a **string** for those three, an
    **object** for Bash.
  - A wrong shape is **silently ignored** (original output used) → it is safe to
    attempt string replacement for Read/Grep/Glob; worst case is a no-op, never data
    loss.
  - **Only remaining verification is live** (does the running CC version accept a
    string `updatedToolOutput` for Read?). Fixtures can't settle this; the
    silent-ignore fallback makes shipping safe regardless.
- Grep behavior varies by `tool_input.output_mode` — truncation logic must branch on
  it (content = line truncation; files_with_matches / count = cap the list).
- Deterministic truncation runs in `PostToolUse` (per-tool); prevention runs in
  `PreToolUse`. Both already wired patterns in the plugin.
- Reuses existing infra: `lib/julius-common.sh` (tier/config/state), tier-config
  thresholds, the fixture harness (`tests/test-hooks.sh`) for happy-path coverage.

## Open Questions for Planning

1. ~~Grep/Glob/Read output shapes~~ — RESOLVED (see Dependencies): string for
   Read/Grep/Glob, object for Bash, safe no-op fallback. Only live-accept check remains.
2. Truncator thresholds per tier (head/tail N, elision trigger) — new tier-config keys.
3. Grep truncation branching on `output_mode` (content vs files vs count).
4. `julius-explorer` agent: net win vs subagent overhead? Define when delegation
   beats inline targeted grep.
5. Dedup scope: per-session state in `julius_state_dir` — eviction/size cap?
