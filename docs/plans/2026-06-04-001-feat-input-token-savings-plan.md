---
title: "feat: Input / tool-output token savings (deterministic-first)"
type: feat
status: completed
created: 2026-06-04
origin: docs/brainstorms/input-token-savings-requirements.md
depth: standard
---

# feat: Input / Tool-Output Token Savings (Deterministic-First)

Origin: `docs/brainstorms/input-token-savings-requirements.md`

## Problem Frame

Julius's input-side savings are thin and architecturally inverted. Only
`scripts/compress-output.sh` compresses tool output, it covers **Bash only**, and it
calls the Haiku flash API per invocation — paying network cost + latency on the
critical path for wins that should be free. Grep, Glob, and medium-size Reads flow
into context uncompressed.

Core reframe (see origin): **deterministic local compression becomes the default
first pass at every tier; flash is demoted to a Beast-only semantic fallback.** Layer
prevention (keep big output out of context) and behavioral coaching on top, mapped to
existing tiers.

---

## Scope

**In scope:** A (deterministic truncation/strip/dedup for Bash/Read/Grep/Glob),
B-minus (read-range defaulting + grep/glob cap — prevention without the explorer
agent), C (behavioral coaching), tier-gating, tier-config keys, docs, offline tests.

**Spike resolved, then CORRECTED by live verification (2026-06-04):** the brainstorm
spike (from a stale docs example) said Read/Grep/Glob `tool_response` is a string. A
real Claude Code session proved otherwise:
- **Read** `tool_response` is a structured **object** `{type:"text", file:{content,
  filePath, numLines, startLine, totalLines}}` — live-verified: a 300-line Read was
  replaced with 31 lines via `updatedToolOutput`.
- **Bash** object `{stdout,stderr,interrupted,isImage}` — live-verified working.
- **Grep/Glob** shapes **could not be captured** (project `PostToolUse` hooks don't
  fire for subagent tool calls, and the tools aren't directly drivable in-session).
  Their string assumption is now untrustworthy → **deferred** (see below). Matcher is
  `Bash|Read` only until their shapes are captured live.

### Deferred to Follow-Up Work

- **Grep/Glob compression** — live `tool_response` shapes unverified (see corrected
  spike above). Needs a session that captures the real payloads, then per-shape
  handling + tests, before re-adding to the matcher.
- **`julius-explorer` subagent** (delegation arm of B). ROI uncertain (subagent cost
  vs inline targeted grep); validate with metrics before building. (see origin)
- **Semantic dedup / cross-session dedup** — only exact in-session dedup is in scope.

### Out of Scope (origin non-goals)

- Model-output compression — owned by caveman.
- Context-window longevity / compaction — different target.

---

## Tier Mapping

| Tier | Deterministic (A) | Prevention (B-) | Coaching (C) | Flash fallback |
|------|:----------------:|:---------------:|:------------:|:--------------:|
| Normal | ✅ | — | ✅ | — |
| Pro | ✅ | ✅ | ✅ | — |
| Beast | ✅ | ✅ | ✅ | ✅ (Beast-only, semantic, when deterministic still over budget) |

---

## High-Level Technical Design

Deterministic-first pipeline inside the PostToolUse path (directional guidance for
review, not implementation specification — treat as context, not code to reproduce):

```
PostToolUse(tool_response) ─► deterministic pass (lib/julius-compress.sh)
   strip ANSI ─► collapse consecutive dup lines ─► middle-out truncate
   (always keep lines matching error|warn|fail|traceback|exception)
        │
        ├─ shrank enough?  ──► emit updatedToolOutput (object for Bash, string for Read/Grep/Glob)
        │
        └─ Beast AND still over budget AND tool==Bash AND prose-like
                 └─► flash semantic fallback ──► emit updatedToolOutput
   any failure ──► emit nothing (original output preserved)
```

PreToolUse path (prevention): Read without offset/limit on a medium file → nudge
pagination; Grep/Glob → cap is applied in the PostToolUse deterministic pass.

---

## Output Structure (new/changed files)

```
lib/
  julius-compress.sh        # NEW — deterministic compression primitives
scripts/
  compress-output.sh        # MODIFIED — deterministic-first, flash demoted
  read-grep-guard.sh        # NEW — PreToolUse prevention (read-range, nudges)
  turn-coach.sh             # MODIFIED — add cheap-pattern coaching (C)
hooks/hooks.json            # MODIFIED — matcher Bash → Bash|Read|Grep|Glob; PreToolUse additions
lib/tier-config.json        # MODIFIED — new deterministic/prevention/coaching keys
tests/test-hooks.sh         # MODIFIED — offline deterministic + happy-path cases
README.md                   # MODIFIED — document the new behavior
```

---

## Key Technical Decisions

- **Deterministic-first, flash-fallback.** Inverts current architecture. Flash only
  fires Beast + Bash + still-over-budget. Guarantees net-positive at every tier and
  offline safety. (see origin reframe)
- **Single generalized PostToolUse compressor.** `compress-output.sh` handles all four
  tools, branching on `tool_name` for output shape (object vs string) and on Grep
  `output_mode`. Avoids four near-duplicate scripts.
- **Safe-by-construction replacement.** Emit `updatedToolOutput` only when the
  deterministic result is strictly smaller; on any failure emit nothing → original
  preserved. Wrong shape is silently ignored by Claude Code (documented), so attempts
  never lose data.
- **Primitives in a sourced lib.** `lib/julius-compress.sh` holds pure functions so
  they're unit-testable offline without hook plumbing.

---

## Implementation Units

### U1. Deterministic compression primitives

**Goal:** Pure, offline, unit-testable bash/awk functions for the deterministic pass.
**Requirements:** Direction A; success criteria "net-positive", "no data loss", "offline-safe".
**Dependencies:** none.
**Files:** `lib/julius-compress.sh` (new), `tests/test-hooks.sh` (modify).
**Approach:** Functions reading stdin → stdout:
- `jc_strip_ansi` — remove ANSI/CSI escape sequences.
- `jc_collapse_dups` — collapse runs of identical consecutive lines into `<line> (×N)`.
- `jc_middle_out <head> <tail>` — keep first `head` + last `tail` lines + every line
  matching `-iE 'error|warn|fail|traceback|exception'`; replace the elided middle with
  `[… N lines elided …]`. Must preserve relative order and never drop a preserved line.
- `jc_compress <head> <tail>` — pipeline of the three; no-op (passthrough) if already
  within `head+tail`.
**Patterns to follow:** `lib/julius-common.sh` style (small POSIX-ish bash, `set` safety
in callers). Stateless; no network.
**Test scenarios:**
- Happy: 300-line input, head=20/tail=20 → output keeps first 20 + last 20 + elision marker; line count < input.
- Preserve: input with an `ERROR:` line in the elided middle → that line survives in output.
- Strip: input with ANSI color codes → codes removed, text intact.
- Dups: 50 identical consecutive lines → collapsed to one `(×50)` line.
- No-op: 10-line input with head+tail=40 → output identical to input (no marker).
- Order: interleaved normal + error lines → preserved lines appear in original order.
**Verification:** All primitive tests pass offline (no API key, no network).

### U2. Deterministic-first refactor of compress-output (Bash)

**Goal:** Bash output compressed deterministically first; flash demoted to Beast-only fallback.
**Requirements:** Direction A; reframe decision; "net-positive", "no data loss".
**Dependencies:** U1.
**Files:** `scripts/compress-output.sh` (modify), `tests/test-hooks.sh` (modify).
**Approach:** Source `lib/julius-compress.sh`. For Bash: extract stdout, run
`jc_compress` with tier-configured head/tail. If result strictly smaller → emit
`updatedToolOutput` object `{stdout,stderr,interrupted,isImage}`. Flash fires **only**
when `tier==beast` AND deterministic result still exceeds a `flash_fallback_lines`
threshold (prose-heavy case). On any failure → emit nothing. Keep existing
"only replace if shrank" + ERROR-guard invariants.
**Patterns to follow:** current `scripts/compress-output.sh` structure; `JULIUS_FLASH_BIN`
override for stubbing.
**Test scenarios:**
- Covers origin "no data loss": flash unavailable + big Bash stdout → deterministic
  replacement emitted (not empty, not lossy subset), errors preserved.
- Happy: 300-line Bash stdout, beast → `updatedToolOutput.stdout` is the truncated text, shape valid.
- Threshold: stdout below tier threshold → exit 0, no emission.
- Flash gate: non-beast tier never invokes flash even when over `flash_fallback_lines` (stub flash = `/bin/false`, still emits deterministic result).
- Beast fallback: deterministic result still over `flash_fallback_lines` + stub flash → flash output emitted.
**Verification:** Bash compression works offline; flash only on the beast-fallback path.

### U3. Extend deterministic compression to Read/Grep/Glob

**Goal:** Cover the other three high-volume tools via string `updatedToolOutput`.
**Requirements:** Direction A; spike resolution (string shape).
**Dependencies:** U1, U2.
**Files:** `scripts/compress-output.sh` (modify), `hooks/hooks.json` (modify),
`tests/test-hooks.sh` (modify).
**Approach:** Extend PostToolUse matcher to `Bash|Read|Grep|Glob`. Branch on `tool_name`:
- Read/Glob: `tool_response` is a string → `jc_compress` → emit **string** `updatedToolOutput`.
- Grep: branch on `tool_input.output_mode` — `content` → line truncation; `files_with_matches`
  → cap list to first N + `(M more in …)`; `count` → leave untouched (already tiny).
- Never flash for these tools (string semantic summary is Beast-Bash-only).
Wrong-shape emission is silently ignored by CC → safe; document the live-verify caveat.
**Patterns to follow:** U2 branching; safe no-op fallback.
**Test scenarios:**
- Read happy: large line-numbered string → emits string `updatedToolOutput`, smaller, head/tail kept.
- Grep content: many matches → truncated with elision, match lines preserved.
- Grep files_with_matches: 200 files → first N + `(M more …)`.
- Grep count: short numeric output → exit 0, no emission.
- Glob: 200 paths → capped list.
- Below threshold (each tool) → no emission.
**Verification:** Each tool emits correctly-typed `updatedToolOutput` (string vs object) offline.

### U4. In-session repeated-output dedup

**Goal:** Replace an exact repeat of a previously-seen tool output with a back-reference.
**Requirements:** Direction A (dedup); "net-positive".
**Dependencies:** U1.
**Files:** `scripts/compress-output.sh` (modify), `lib/julius-common.sh` (maybe add a
state helper), `tests/test-hooks.sh` (modify).
**Approach:** Hash (`julius_md5`) the raw output; store `hash → short label` under
`julius_state_dir()/dedup/` with a size cap (e.g., keep last K hashes, evict oldest).
On exact-hash repeat, emit `updatedToolOutput` = `[same as earlier output of <cmd/file>]`.
Skip dedup when output is below a min size (not worth a back-ref).
**Patterns to follow:** `julius_state_dir` / `julius_md5` from `lib/julius-common.sh`;
`reactivation-count` file pattern for simple state.
**Test scenarios:**
- Repeat: same large Bash output twice → second emits back-reference; first does not.
- Distinct: two different outputs → neither deduped.
- Below min size: tiny repeated output → not deduped.
- Eviction: more than K distinct outputs → oldest hash evicted, file bounded.
**Verification:** Dedup state stays bounded; back-reference only on exact repeat.

### U5. Prevention — read-range defaulting + grep/glob cap

**Goal:** Stop oversized reads/searches from entering context in the first place.
**Requirements:** Direction B-minus; "net-positive".
**Dependencies:** none (U3 covers the PostToolUse cap; this adds the PreToolUse nudge).
**Files:** `scripts/read-grep-guard.sh` (new), `hooks/hooks.json` (modify),
`lib/tier-config.json` (modify), `tests/test-hooks.sh` (modify).
**Approach:** PreToolUse on Read: when no `offset`/`limit` and file size is between the
`large-file-guard` block threshold and a smaller `nudge` threshold, emit
`additionalContext` suggesting a paged read (offset/limit) — advisory, never blocks
(distinct from `large-file-guard.sh` which blocks the truly large). Coexist with
`large-file-guard.sh` (different threshold band). Gated Pro+.
**Patterns to follow:** `scripts/large-file-guard.sh` (PreToolUse JSON parse, tier gate,
subagent skip via `agent_id`).
**Test scenarios:**
- Medium file, no offset/limit, Pro → additionalContext nudge, exit 0 (not blocked).
- Read already has offset/limit → no nudge.
- File above large-file-guard threshold → leave to large-file-guard (no double-handling).
- Normal tier → disabled, exit 0.
- Inside subagent (`agent_id` present) → no nudge.
**Verification:** Nudge fires only in the intended size band and tier; never blocks.

### U6. Behavioral coaching (C)

**Goal:** Steer the model toward cheap tool patterns.
**Requirements:** Direction C.
**Dependencies:** none.
**Files:** `scripts/turn-coach.sh` (modify) or `scripts/read-grep-guard.sh` (extend),
`lib/tier-config.json` (modify), `tests/test-hooks.sh` (modify).
**Approach:** PreToolUse advisory nudges (additionalContext) for cheap-pattern
opportunities: `cat <file>`/`cat | grep` Bash commands → suggest the Grep tool or
targeted ranges; repeated single-file Reads → suggest batching. Advisory only, all
tiers, gated by a `coaching.cheap_patterns` flag. Keep noise low: at most one nudge per
tool call, skip when the command is already targeted.
**Patterns to follow:** `scripts/turn-coach.sh` advisory style (plain stdout / additionalContext where supported).
**Test scenarios:**
- `cat bigfile.txt` Bash → nudge suggesting Grep/range.
- Already-targeted `grep -n foo file` → no nudge.
- Coaching flag off → no nudge.
- Non-matching command (`ls`) → no nudge.
**Verification:** Nudges fire only on wasteful patterns; off when flag disabled.

### U7. Config keys, hook wiring, docs, and test consolidation

**Goal:** Wire everything into tiers/hooks, document, and ensure the full suite is green.
**Requirements:** "measurable"; tier mapping; all directions.
**Dependencies:** U1–U6.
**Files:** `lib/tier-config.json` (modify), `hooks/hooks.json` (modify),
`scripts/julius-doctor.sh` (modify), `tests/test-all.sh` (modify),
`tests/test-hooks.sh` (modify), `README.md` (modify),
`commands/julius.md` (modify tier one-liners).
**Approach:** Add per-tier keys: `compress_output.head_lines`, `.tail_lines`,
`.flash_fallback_lines`, `.dedup{enabled,min_lines,max_entries}`; `prevention{enabled,
read_nudge_lines}`; `coaching.cheap_patterns`. Update `hooks.json` matchers
(`Bash|Read|Grep|Glob`, new PreToolUse entry). Update `julius-doctor.sh` script/hook
lists and `test-all.sh` script list. Refresh README behavior section + `/julius`
tier one-liners.
**Test scenarios:** Test expectation: covered by U1–U6 behavioral tests plus existing
smoke suite. Add: doctor lists new scripts; tier-config has the new keys for all tiers;
`test-all.sh` includes new scripts; full `test-hooks.sh` + `test-all.sh` green.
**Verification:** `bash tests/test-all.sh` passes (existing 45 + new cases); doctor clean.

---

## System-Wide Impact

- **Hook surface:** PostToolUse matcher widens to four tools; one new PreToolUse hook.
  More hooks fire per turn — all deterministic/offline except the Beast-Bash flash
  fallback, so latency stays near-zero at Normal/Pro.
- **State:** new `dedup/` dir under `julius_state_dir()`; bounded by `max_entries`.
- **Backward compat:** tier names unchanged; new config keys default-safe (features
  off when key absent via `julius_config` defaults).
- **Metrics:** `metrics-stop.sh` continues recording real usage; deterministic vs flash
  contribution distinguishable by whether flash was invoked (Beast only).

---

## Risks & Mitigations

- **String `updatedToolOutput` rejected by some CC version (Read/Grep/Glob).** → Wrong
  shape is silently ignored (original used); zero data loss. Mitigate further: note as
  the one live-verify item; if rejected, value still comes from U5 prevention + Bash (U2).
- **Over-aggressive truncation hides needed detail.** → Always preserve error/warn
  lines; conservative head/tail defaults; only replace when strictly smaller.
- **Coaching noise.** → One nudge per call, skip already-targeted commands, single flag.
- **Dedup false "same as earlier" on coincidental hash.** → md5 collision negligible;
  min-size gate avoids deduping trivial outputs.

---

## Deferred / Execution-Time Unknowns

- Exact head/tail and `flash_fallback_lines` values per tier — tune during U2/U3 against
  real output; start conservative.
- Whether `read-grep-guard` and `turn-coach` coaching should share one script — decide
  when implementing U6 (avoid premature merge).
- Live confirmation that CC applies string `updatedToolOutput` for Read.

---

## Requirements Traceability

| Origin item | Units |
|-------------|-------|
| A — deterministic truncate/strip/dedup | U1, U2, U3, U4 |
| B — prevention (read-range, grep/glob cap) | U3 (cap), U5 (read-range) |
| B — explorer subagent | Deferred to Follow-Up |
| C — behavioral coaching | U6 |
| Tier mapping | U7 |
| Success: net-positive / no data loss / offline-safe / measurable | U1–U4, U7 |
| Spike: updatedToolOutput shapes | U2 (object), U3 (string) |
