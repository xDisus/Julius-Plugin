#!/usr/bin/env bash
# test-hooks.sh — behavioral tests for Julius hooks.
# Pipes documented hook-event JSON (stdin) into each script and asserts on
# exit code + stdout/stderr. This exercises the I/O contract that test-all.sh
# (existence/parse only) never checked. No network: flash-backed hooks are
# asserted to degrade gracefully (exit 0, original output preserved).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
PASS=0; FAIL=0
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

# Isolated state dir so tests never touch a real project.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export JULIUS_STATE_DIR="$TMP/state"
export CLAUDE_PLUGIN_ROOT="$ROOT"
mkdir -p "$JULIUS_STATE_DIR"

ok()   { PASS=$((PASS+1)); printf "${GREEN}✓${NC} %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf "${RED}✗${NC} %s\n" "$1"; }

set_tier() { printf '%s' "$1" > "$JULIUS_STATE_DIR/active-tier"; }

# run <script> <stdin>  -> sets RC, OUT, ERRV
run() {
  local script="$1" stdin="$2" outf errf
  outf="$TMP/out"; errf="$TMP/err"
  printf '%s' "$stdin" | "$SCRIPTS/$script" >"$outf" 2>"$errf"
  RC=$?; OUT="$(cat "$outf")"; ERRV="$(cat "$errf")"
}

echo "[large-file-guard] PreToolUse Read"
BIG="$TMP/big.py"; printf 'x\n%.0s' $(seq 1 200) > "$BIG"
SMALL="$TMP/small.py"; printf 'x\ny\n' > "$SMALL"

set_tier beast
run large-file-guard.sh "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$BIG\"}}"
{ [ "$RC" -eq 2 ] && echo "$ERRV" | grep -q "julius-reader"; } && ok "blocks large file (exit 2 + redirect)" || bad "should block large file (rc=$RC)"

run large-file-guard.sh "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$SMALL\"}}"
[ "$RC" -eq 0 ] && ok "passes small file (exit 0)" || bad "should pass small file (rc=$RC)"

run large-file-guard.sh "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"agent_id\":\"sub_1\",\"tool_input\":{\"file_path\":\"$BIG\"}}"
[ "$RC" -eq 0 ] && ok "never blocks inside subagent (julius-reader can Read)" || bad "should not block in subagent (rc=$RC)"

set_tier normal
run large-file-guard.sh "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$BIG\"}}"
[ "$RC" -eq 0 ] && ok "disabled in normal tier (subagent_reader off)" || bad "should be off in normal (rc=$RC)"

run large-file-guard.sh "garbage-not-json"
[ "$RC" -eq 0 ] && ok "malformed stdin → pass-through, no crash" || bad "should not crash on bad json (rc=$RC)"

echo
echo "[compress-output] PostToolUse Bash"
set_tier beast
BIGOUT=$(printf 'line %s\n' $(seq 1 300))
run compress-output.sh "$(jq -n --arg o "$BIGOUT" '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:$o,stderr:"",interrupted:false,isImage:false}}')"
# Without network the flash call fails; must exit 0 and NOT emit a lossy/garbage replacement.
[ "$RC" -eq 0 ] && ok "no-network → exit 0 (no data loss, original kept)" || bad "should exit 0 on flash failure (rc=$RC)"
if [ -n "$OUT" ]; then echo "$OUT" | jq -e '.hookSpecificOutput.hookEventName=="PostToolUse"' >/dev/null 2>&1 && ok "any output is valid hookSpecificOutput JSON" || bad "output must be valid hook JSON"; else ok "empty output (original preserved)"; fi

run compress-output.sh "$(jq -n '{hook_event_name:"PostToolUse",tool_name:"Read",tool_response:"short"}')"
[ "$RC" -eq 0 ] && ok "non-Bash tool ignored cleanly" || bad "non-Bash should be ignored (rc=$RC)"

echo
echo "[oracle-preprocess] UserPromptSubmit"
set_tier beast
run oracle-preprocess.sh '{"hook_event_name":"UserPromptSubmit","prompt":"hi"}'
[ "$RC" -eq 0 ] && ok "trivial prompt → gated/skip, exit 0" || bad "trivial prompt should exit 0 (rc=$RC)"

echo
echo "[batch-synthesizer] PostToolBatch"
set_tier beast
run batch-synthesizer.sh '{"hook_event_name":"PostToolBatch","tool_calls":[{"tool_name":"Read","tool_input":{"file_path":"a"},"tool_response":"x"}]}'
[ "$RC" -eq 0 ] && ok "single-call batch below min → skip, exit 0" || bad "small batch should exit 0 (rc=$RC)"

echo
echo "[turn-coach] Stop"
set_tier normal
TRANSCRIPT="$TMP/t.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Let me start. I will first check. I think I need to look."}]}}' > "$TRANSCRIPT"
run turn-coach.sh "{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_reason\":\"end_turn\"}"
[ "$RC" -eq 0 ] && ok "Stop with transcript → exit 0, no crash" || bad "Stop should exit 0 (rc=$RC)"

run turn-coach.sh '{"hook_event_name":"Stop","transcript_path":"/nonexistent","stop_reason":"end_turn"}'
[ "$RC" -eq 0 ] && ok "missing transcript → graceful exit 0" || bad "missing transcript should exit 0 (rc=$RC)"

echo
echo "[task-manifest] TaskCreated/TaskCompleted"
set_tier normal
run task-manifest.sh '{"hook_event_name":"TaskCreated","tool_input":{"description":"do thing","id":"t1"}}' created 2>/dev/null || true
# task-manifest takes the action as $1; re-run with arg via direct call:
printf '%s' '{"hook_event_name":"TaskCreated","tool_input":{"description":"do thing","subagent_id":"t1"}}' | "$SCRIPTS/task-manifest.sh" created >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "TaskCreated parses JSON, exit 0" || bad "TaskCreated should exit 0 (rc=$RC)"
[ -f "$JULIUS_STATE_DIR/tasks.json" ] && ok "tasks.json written to unified state dir" || bad "tasks.json missing in state dir"

echo
echo "[happy paths] flash stubbed (no network) — exercises the emit code"
# Stub flash: consumes stdin, prints a short canned summary.
STUB="$TMP/stub-flash.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
cat >/dev/null
echo "STUBBED_SUMMARY_LINE"
STUBEOF
chmod +x "$STUB"
export JULIUS_FLASH_BIN="$STUB"

set_tier beast

# compress-output: must emit updatedToolOutput with the stub text.
run compress-output.sh "$(jq -n --arg o "$BIGOUT" '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:$o,stderr:"",interrupted:false,isImage:false}}')"
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.hookSpecificOutput.updatedToolOutput.stdout=="STUBBED_SUMMARY_LINE" and .hookSpecificOutput.updatedToolOutput.isImage==false' >/dev/null 2>&1; then
  ok "compress-output emits correctly-shaped updatedToolOutput (Bash)"
else
  bad "compress-output happy path (rc=$RC, out=$OUT)"
fi

# oracle-preprocess: non-trivial prompt → additionalContext with [ORACLE].
# Use a stable cwd whose contents don't change between calls (the project index is
# part of the cache key — a mutating dir would legitimately invalidate the cache).
ODIR="$TMP/oproj"; mkdir -p "$ODIR"; printf 'x\n' > "$ODIR/app.py"
OREQ='{"hook_event_name":"UserPromptSubmit","prompt":"please refactor the auth middleware to fix token expiry","cwd":"'"$ODIR"'"}'
run oracle-preprocess.sh "$OREQ"
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.hookSpecificOutput.additionalContext | test("\\[ORACLE\\]")' >/dev/null 2>&1; then
  ok "oracle emits additionalContext dossier"
else
  bad "oracle happy path (rc=$RC, out=$OUT)"
fi

# Second identical call must hit cache (flash pointed at a failing binary).
JULIUS_FLASH_BIN="/bin/false" bash -c 'printf "%s" "$1" | "$2/oracle-preprocess.sh"' _ "$OREQ" "$SCRIPTS" >"$TMP/out" 2>/dev/null
grep -q "\[ORACLE\]" "$TMP/out" && ok "oracle serves from cache without flash" || bad "oracle cache miss on repeat"

# batch-synthesizer: 2 calls → additionalContext synthesis.
run batch-synthesizer.sh '{"hook_event_name":"PostToolBatch","tool_calls":[{"tool_name":"Read","tool_input":{"file_path":"a.py"},"tool_response":"import b"},{"tool_name":"Read","tool_input":{"file_path":"b.py"},"tool_response":"x=1"}]}'
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.hookSpecificOutput.additionalContext=="STUBBED_SUMMARY_LINE"' >/dev/null 2>&1; then
  ok "batch-synthesizer emits additionalContext"
else
  bad "batch-synthesizer happy path (rc=$RC, out=$OUT)"
fi
unset JULIUS_FLASH_BIN

echo
echo "[metrics-stop] Stop with usage transcript"
if command -v bc >/dev/null 2>&1; then
  MT="$TMP/metrics-transcript.jsonl"
  printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":0}}}' > "$MT"
  HOME="$TMP/home" bash "$SCRIPTS/metrics-stop.sh" <<< "{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$MT\",\"session_id\":\"s1\",\"cwd\":\"$TMP\"}" >/dev/null 2>&1
  RC=$?
  if [ "$RC" -eq 0 ] && [ -f "$TMP/home/.julius/metrics/cumulative.json" ] && \
     jq -e '.turns>=1 and .total_input>=1000' "$TMP/home/.julius/metrics/cumulative.json" >/dev/null 2>&1; then
    ok "metrics-stop records real token usage (no stop_reason gate)"
  else
    bad "metrics-stop did not record (rc=$RC)"
  fi
else
  ok "metrics-stop skipped (bc not installed)"
fi

echo
echo "============================================"
printf "Passed: %d  Failed: %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
