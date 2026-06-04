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

run compress-output.sh "garbage{not json"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "malformed stdin → clean no-op (no crash)" || bad "malformed stdin should no-op (rc=$RC)"

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
rm -rf "$JULIUS_STATE_DIR/dedup"   # isolate shape tests from the dedup feature (real config has it on)

# compress-output Bash: deterministic-first — shrinks WITHOUT flash (stub would be a tell).
run compress-output.sh "$(jq -n --arg o "$BIGOUT" '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:$o,stderr:"",interrupted:false,isImage:false}}')"
DET_STDOUT=$(echo "$OUT" | jq -r '.hookSpecificOutput.updatedToolOutput.stdout // empty' 2>/dev/null)
DET_LINES=$(printf '%s\n' "$DET_STDOUT" | wc -l | tr -d ' ')
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.hookSpecificOutput.updatedToolOutput.isImage==false' >/dev/null 2>&1 \
   && [ -n "$DET_STDOUT" ] && [ "$DET_LINES" -lt 300 ] && printf '%s' "$DET_STDOUT" | grep -q "elided" \
   && [ "$DET_STDOUT" != "STUBBED_SUMMARY_LINE" ]; then
  ok "compress-output Bash: deterministic shrink, valid shape, no flash needed"
else
  bad "compress-output deterministic path (rc=$RC, lines=$DET_LINES)"
fi

# Error lines survive deterministic Bash compression.
ERROUT=$(printf 'start\n%s\nERROR: kaboom at x.py:9\n%s\nend\n' "$(seq 1 150)" "$(seq 1 150)")
run compress-output.sh "$(jq -n --arg o "$ERROUT" '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:$o,stderr:"",interrupted:false,isImage:false}}')"
echo "$OUT" | jq -r '.hookSpecificOutput.updatedToolOutput.stdout' 2>/dev/null | grep -q "ERROR: kaboom at x.py:9" \
  && ok "compress-output preserves error lines through compression" || bad "compress-output dropped error line"

# Flash fallback fires only on Beast when deterministic is still over budget.
FCFG="$TMP/flash-cfg.json"
jq -n '{beast:{compress_output:{enabled:true,threshold_lines:5,head_lines:50,tail_lines:50,flash_fallback_lines:10}}}' > "$FCFG"
FF_INPUT=$(jq -n --arg o "$BIGOUT" '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:$o,stderr:"",interrupted:false,isImage:false}}')
OUT=$(JULIUS_CONFIG="$FCFG" JULIUS_FLASH_BIN="$STUB" bash -c 'printf "%s" "$1" | "$2/compress-output.sh"' _ "$FF_INPUT" "$SCRIPTS" 2>/dev/null)
echo "$OUT" | jq -e '.hookSpecificOutput.updatedToolOutput.stdout=="STUBBED_SUMMARY_LINE"' >/dev/null 2>&1 \
  && ok "compress-output Beast flash fallback fires when over budget" || bad "flash fallback path (out=$OUT)"

# Non-beast never invokes flash even over budget (flash bin would fail).
PCFG="$TMP/pro-cfg.json"
jq -n '{pro:{compress_output:{enabled:true,threshold_lines:5,head_lines:50,tail_lines:50,flash_fallback_lines:10}}}' > "$PCFG"
printf '%s' "pro" > "$JULIUS_STATE_DIR/active-tier"
OUT=$(JULIUS_CONFIG="$PCFG" JULIUS_FLASH_BIN="/bin/false" bash -c 'printf "%s" "$1" | "$2/compress-output.sh"' _ "$FF_INPUT" "$SCRIPTS" 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.hookSpecificOutput.updatedToolOutput.stdout' >/dev/null 2>&1 \
  && ok "compress-output Pro stays deterministic (no flash)" || bad "pro flash-gate (rc=$RC)"
set_tier beast

# U3: Read deterministic compression — REAL object shape {type,file:{content,...}},
# live-verified 2026-06-04. (Grep/Glob deferred: their live shapes are unverified.)
rm -rf "$JULIUS_STATE_DIR/dedup"
READBIG=$(seq 1 300 | awk '{print "line "$1}')
RDIN=$(jq -n --arg c "$READBIG" '{hook_event_name:"PostToolUse",tool_name:"Read",tool_input:{file_path:"/tmp/big.py"},tool_response:{type:"text",file:{filePath:"/tmp/big.py",content:$c,numLines:300,startLine:1,totalLines:300}}}')
run compress-output.sh "$RDIN"
if [ "$RC" -eq 0 ] \
   && echo "$OUT" | jq -e '.hookSpecificOutput.updatedToolOutput.file.filePath=="/tmp/big.py"' >/dev/null 2>&1 \
   && echo "$OUT" | jq -r '.hookSpecificOutput.updatedToolOutput.file.content' | grep -q "elided" \
   && [ "$(echo "$OUT" | jq -r '.hookSpecificOutput.updatedToolOutput.file.numLines')" -lt 300 ] 2>/dev/null; then
  ok "compress-output Read: object shape, file.content compressed, path + structure preserved"
else
  bad "compress-output Read object (rc=$RC, out=$(echo "$OUT" | head -c 200))"
fi

# Read below threshold → untouched.
RDSMALL=$(jq -n --arg c "$(seq 1 5)" '{hook_event_name:"PostToolUse",tool_name:"Read",tool_input:{file_path:"s.py"},tool_response:{type:"text",file:{filePath:"s.py",content:$c,numLines:5,startLine:1,totalLines:5}}}')
run compress-output.sh "$RDSMALL"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "compress-output Read: small file untouched" || bad "read small (out=$OUT)"

# U4: in-session dedup.
DCFG="$TMP/dedup-cfg.json"
jq -n '{beast:{compress_output:{enabled:true,threshold_lines:5,head_lines:50,tail_lines:50,dedup:{enabled:true,min_lines:10,max_entries:3}}}}' > "$DCFG"
rm -rf "$JULIUS_STATE_DIR/dedup"
run_dcfg() { OUT=$(JULIUS_CONFIG="$DCFG" bash -c 'printf "%s" "$1" | "$2/compress-output.sh"' _ "$1" "$SCRIPTS" 2>/dev/null); }
DTEXT=$(seq 1 50)
DIN=$(jq -n --arg o "$DTEXT" '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"make build"},tool_response:{stdout:$o,stderr:"",interrupted:false,isImage:false}}')
run_dcfg "$DIN"   # first sight — records, no back-ref
FIRST="$OUT"
run_dcfg "$DIN"   # repeat — back-reference
if ! echo "$FIRST" | grep -q "same as earlier" && echo "$OUT" | jq -r '.hookSpecificOutput.updatedToolOutput.stdout' 2>/dev/null | grep -q "same as earlier output of make build"; then
  ok "dedup: exact repeat → back-reference (first sight not deduped)"
else
  bad "dedup repeat (first=$FIRST out=$OUT)"
fi

# Distinct output is not deduped.
DIN2=$(jq -n --arg o "$(seq 100 160)" '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"make test"},tool_response:{stdout:$o,stderr:"",interrupted:false,isImage:false}}')
run_dcfg "$DIN2"
echo "$OUT" | grep -q "same as earlier" && bad "dedup false positive on distinct output" || ok "dedup: distinct output not deduped"

# Below min_lines: not deduped even on repeat.
SMIN=$(jq -n --arg o "$(seq 1 4)" '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"echo hi"},tool_response:{stdout:$o,stderr:"",interrupted:false,isImage:false}}')
run_dcfg "$SMIN"; run_dcfg "$SMIN"
echo "$OUT" | grep -q "same as earlier" && bad "dedup deduped below min_lines" || ok "dedup: below min_lines skipped"

# Eviction keeps the store bounded.
for i in $(seq 1 6); do
  EIN=$(jq -n --arg o "$(seq 1 20 | sed "s/^/v$i-/")" '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"c"},tool_response:{stdout:$o,stderr:"",interrupted:false,isImage:false}}')
  run_dcfg "$EIN"
done
DCOUNT=$(ls -1 "$JULIUS_STATE_DIR/dedup" 2>/dev/null | wc -l | tr -d ' ')
[ "$DCOUNT" -le 3 ] && ok "dedup: store bounded by max_entries ($DCOUNT≤3)" || bad "dedup store unbounded ($DCOUNT)"
rm -rf "$JULIUS_STATE_DIR/dedup"

echo
echo "[read-grep-guard] PreToolUse prevention"
PCFG2="$TMP/prev-cfg.json"
jq -n '{beast:{prevention:{enabled:true,read_nudge_lines:20},subagent_reader:{enabled:true,threshold_lines:50}},normal:{prevention:{enabled:false}}}' > "$PCFG2"
MEDF="$TMP/med.py"; seq 1 30 > "$MEDF"
BIGF2="$TMP/big2.py"; seq 1 100 > "$BIGF2"
rgg() { OUT=$(JULIUS_CONFIG="$PCFG2" bash -c 'printf "%s" "$1" | "$2/read-grep-guard.sh"' _ "$1" "$SCRIPTS" 2>/dev/null); }

rgg "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$MEDF\"}}"
echo "$OUT" | jq -e '.hookSpecificOutput.additionalContext | test("targeted range")' >/dev/null 2>&1 \
  && ok "read-guard: nudge fires for medium file in band" || bad "read-guard band (out=$OUT)"

rgg "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$MEDF\",\"offset\":1,\"limit\":10}}"
[ -z "$OUT" ] && ok "read-guard: no nudge when offset/limit present" || bad "read-guard offset (out=$OUT)"

rgg "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$BIGF2\"}}"
[ -z "$OUT" ] && ok "read-guard: no nudge above block threshold (large-file-guard handles)" || bad "read-guard upper (out=$OUT)"

rgg "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"agent_id\":\"sub_1\",\"tool_input\":{\"file_path\":\"$MEDF\"}}"
[ -z "$OUT" ] && ok "read-guard: no nudge inside subagent" || bad "read-guard subagent (out=$OUT)"

printf '%s' "normal" > "$JULIUS_STATE_DIR/active-tier"
rgg "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$MEDF\"}}"
[ -z "$OUT" ] && ok "read-guard: disabled in normal tier" || bad "read-guard normal (out=$OUT)"
set_tier beast

echo
echo "[coach-patterns] PreToolUse cheap-pattern coaching"
CCFG="$TMP/coach-cfg.json"
jq -n '{beast:{coach:{cheap_patterns:true}},normal:{coach:{cheap_patterns:false}}}' > "$CCFG"
cpn() { OUT=$(JULIUS_CONFIG="$CCFG" bash -c 'printf "%s" "$1" | "$2/coach-patterns.sh"' _ "$1" "$SCRIPTS" 2>/dev/null); }

cpn "$(jq -n '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"cat bigfile.txt"}}')"
echo "$OUT" | jq -e '.hookSpecificOutput.additionalContext | test("Read tool")' >/dev/null 2>&1 \
  && ok "coach: cat <file> → suggests Read" || bad "coach cat (out=$OUT)"

cpn "$(jq -n '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"cat app.log | grep ERROR"}}')"
echo "$OUT" | jq -e '.hookSpecificOutput.additionalContext | test("Grep tool")' >/dev/null 2>&1 \
  && ok "coach: cat|grep → suggests Grep" || bad "coach cat|grep (out=$OUT)"

cpn "$(jq -n '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"grep -n foo file.py"}}')"
[ -z "$OUT" ] && ok "coach: targeted grep → no nudge" || bad "coach grep (out=$OUT)"

cpn "$(jq -n '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"ls -la"}}')"
[ -z "$OUT" ] && ok "coach: unrelated command → no nudge" || bad "coach ls (out=$OUT)"

cpn "$(jq -n '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"cat <<EOF\nhi\nEOF"}}')"
[ -z "$OUT" ] && ok "coach: heredoc → no nudge" || bad "coach heredoc (out=$OUT)"

printf '%s' "normal" > "$JULIUS_STATE_DIR/active-tier"
cpn "$(jq -n '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"cat bigfile.txt"}}')"
[ -z "$OUT" ] && ok "coach: disabled when flag off" || bad "coach flag (out=$OUT)"
set_tier beast

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
echo "[deterministic primitives] lib/julius-compress.sh"
# shellcheck source=../lib/julius-compress.sh
source "$ROOT/lib/julius-compress.sh"

BIG300=$(seq 1 300)
OUT=$(printf '%s\n' "$BIG300" | jc_middle_out 20 20)
NLINES=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')
if [ "$NLINES" -lt 300 ] && echo "$OUT" | grep -q "lines elided" && echo "$OUT" | grep -qx "1" && echo "$OUT" | grep -qx "300"; then
  ok "middle_out keeps head+tail, elides middle, marker present"
else
  bad "middle_out (nlines=$NLINES)"
fi

# Preserve an error line buried in the middle.
PRES=$(printf 'a\nb\nERROR: boom at file.py:42\n%s\ny\nz\n' "$(seq 1 100)" | jc_middle_out 2 2)
echo "$PRES" | grep -q "ERROR: boom at file.py:42" && ok "middle_out preserves error line in elided region" || bad "middle_out dropped error line"

# Strip ANSI.
ESC=$(printf '\033')
STRIPPED=$(printf '%s[31mred%s[0m text\n' "$ESC" "$ESC" | jc_strip_ansi)
[ "$STRIPPED" = "red text" ] && ok "strip_ansi removes color codes" || bad "strip_ansi got: '$STRIPPED'"

# Collapse consecutive duplicates.
COLL=$(printf 'x\nx\nx\nx\nx\ny\n' | jc_collapse_dups)
echo "$COLL" | grep -q "x (×5)" && echo "$COLL" | grep -qx "y" && ok "collapse_dups folds runs into (×N)" || bad "collapse_dups got: $COLL"

# No-op for small input.
SMALLIN=$(printf 'one\ntwo\nthree\n')
NOOP=$(printf '%s\n' "$SMALLIN" | jc_middle_out 20 20)
[ "$NOOP" = "$SMALLIN" ] && ok "middle_out is no-op below head+tail" || bad "middle_out altered small input"

# jc_compress pipeline shrinks a noisy large input.
COMP=$(printf '%s[32m%s\n' "$ESC" "$(seq 1 500)" | jc_compress 10 10)
CN=$(printf '%s\n' "$COMP" | wc -l | tr -d ' ')
[ "$CN" -lt 500 ] && ok "jc_compress pipeline shrinks large input" || bad "jc_compress did not shrink (n=$CN)"

echo
echo "============================================"
printf "Passed: %d  Failed: %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
