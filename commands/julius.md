---
name: julius
description: Set or show Julius token economy tier (normal | pro | beast). Each tier adjusts hooks and thresholds for token savings vs quality.
---

# Julius Token Economy

Julius controls token-saving aggressiveness. Read the tier argument:

1. **Extract argument**: Whatever the user typed after `/julius` (e.g. `/julius pro` → `pro`). If no argument → show current tier.

2. **No argument**: Read `.claude/julius/active-tier`. If it exists, print current tier and brief help. If not, print "Julius is inactive. Usage: /julius normal | pro | beast"

3. **With argument**:
   - **normal**: Find and run the `tier-setter.sh` script from the Julius plugin directory (search `~/.claude/plugins/` for it). Run: `bash /path/to/scripts/tier-setter.sh normal`. Print "✅ Julius set to **Normal** — zero quality loss."
   - **pro**: Same, with `pro`. Print "⚠️ Julius set to **Pro** — balanced savings."
   - **beast**: Same, with `beast`. Print "🦍 Julius set to **Beast** — maximum economy."
   - **invalid**: Print "Invalid tier. Usage: /julius normal | pro | beast"

4. After setting tier, show a one-liner of what changes:
   - **Normal**: "Coach + cheap-pattern coaching + Task Manifest + Haiku routing (lossless — no output elided)"
   - **Pro**: "Above + deterministic output compression + dedup + read-range prevention + Batch Synthesis + Agent Pipelines"
   - **Beast**: "Above + Large-File Guard + Flash fallback + Context Oracle + Caveman Agents"

The `tier-setter.sh` script writes the tier name to `.claude/julius/active-tier` and creates the state directory if needed.

State files live under `.claude/julius/` in the project root.
