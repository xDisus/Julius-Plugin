---
name: julius-stats
description: Show MEASURED Julius token numbers — real API-counted usage plus ground-truth tool-output bytes elided by compression/dedup. No estimated net-savings figure.
---

# Julius Stats

Show what Julius actually measured this and prior sessions. Read-only.

## Instructions

1. **Find and run the stats script.** Search `~/.claude/plugins/` for the Julius plugin, then run:
   ```
   bash /path/to/julius/scripts/julius-stats.sh
   ```
   Or, when the script is adjacent to this command:
   ```
   bash "$(dirname "$(find ~/.claude/plugins -name julius-stats.sh -type f | head -1)")/julius-stats.sh"
   ```
   To scope to the current session, pass `--session <session_id>`.

2. **Display the output verbatim.** Do not re-summarize or invent a "total saved"
   number — the script deliberately reports each lever separately because no honest
   single net figure exists (some hooks add tokens, some prevent reads counterfactually).

## What it shows

- **Compression lever (measured):** real bytes elided by `compress-output.sh` (deterministic
  compression + dedup), with per-tool and per-method breakdown. Ground truth — recorded at
  compress time. Token figure is a bytes/4 proxy (labeled est).
- **Real usage:** API-counted input/output/cache tokens and cost from transcript `usage`
  fields, accumulated across turns. No baseline guess.

Compression only fires on tiers `pro` and `beast`, above the line threshold. On `normal`
the compression section will be empty by design (Normal is lossless).
