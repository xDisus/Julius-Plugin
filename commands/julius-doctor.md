---
name: julius-doctor
description: Run diagnostics on the Julius Token Economy plugin. Validates installation, hooks, scripts, agents, dependencies, configuration, and environment.
---

# Julius Doctor

Run a full diagnostic check on the Julius Token Economy plugin.

## Instructions

1. **Find and run the doctor script:** Search `~/.claude/plugins/` for the Julius plugin directory, then run:
   ```
   bash /path/to/julius/scripts/julius-doctor.sh
   ```
   Or if the script is adjacent to this command:
   ```
   bash $(dirname "$(find ~/.claude/plugins -name julius-doctor.sh -type f | head -1)")/julius-doctor.sh
   ```

2. **Display results verbatim** — The script returns pre-formatted output with status prefixes:
   - `[OK]` — check passed (green)
   - `[FAIL]` — check failed, needs fixing (red)
   - `[WARN]` — non-critical issue (yellow)
   Do NOT reformat. Display exactly as returned.

3. **If the script fails to run:** Run these manual checks:
   - Is `jq` installed? `which jq`
   - Is the plugin installed? `ls ~/.claude/plugins/julius/plugin.json`
   - Are hooks registered? `cat ~/.claude/plugins/julius/hooks/hooks.json | head -5`
   - Summarize what you find.

## What /julius-doctor checks

```
═══ INSTALLATION ═══
  Plugin found path + version
  /julius command available
═══ FILES & STRUCTURE ═══
  plugin.json, hooks.json, tier-config.json, commands/
  4 agents (tier-router, julius-reader, julius-executor, julius-researcher)
  11 scripts (all present + executable)
═══ HOOKS VALIDATION ═══
  10 lifecycle hooks registered
  Each hook mapped to correct script
═══ CONFIGURATION ═══
  tier-config.json valid JSON
  3 tiers configured (Normal, Pro, Beast)
═══ DEPENDENCIES ═══
  jq, curl, git availability
═══ RUNTIME ENVIRONMENT ═══
  ANTHROPIC_API_KEY detection
  Active tier status
  State directory writable
═══ DISTRIBUTION ═══
  Marketplace manifest
  npm package.json
═══ SUMMARY ═══
  Pass/warn/fail counts + quick start reference
```
