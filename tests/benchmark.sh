#!/usr/bin/env bash
# benchmark.sh — measure model-visible tool-output size per Julius tier vs control.
# Runs the real scripts/compress-output.sh against the real lib/tier-config.json over
# 10 synthetic-but-realistic tool outputs (Bash + Read, true tool_response shapes).
# No network: flash is stubbed to /bin/false, so Beast falls back to deterministic.
#
# Token figures are an estimate (chars/4), not a real tokenizer, and cover ONLY
# tool-output compression — the dominant measurable lever. They do not capture the
# oracle (which adds prompt tokens), advisory coaching/prevention, or per-call hook
# overhead. Totals are the sum over these 10 deliberately-heavy scenarios; real
# workloads with smaller outputs save less (the threshold gate protects against churn).
#
# Usage: bash tests/benchmark.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SD=$(mktemp -d)/state; mkdir -p "$SD"
export JULIUS_FLASH_BIN=/bin/false
TIERS="control normal pro beast"

# token proxy: characters / 4
toktok() { awk 'BEGIN{c=0} {c+=length($0)+1} END{printf "%d", int(c/4)}'; }

bash_json() { jq -Rs --arg cmd "$1" '{tool_name:"Bash",tool_input:{command:$cmd},tool_response:{stdout:.,stderr:"",interrupted:false,isImage:false}}'; }
read_json() { local c n; c=$(cat); n=$(printf '%s\n' "$c"|wc -l|tr -d ' ');
  jq -n --arg fp "$1" --arg ct "$c" --argjson n "$n" '{tool_name:"Read",tool_input:{file_path:$fp},tool_response:{type:"text",file:{filePath:$fp,content:$ct,numLines:$n,startLine:1,totalLines:$n}}}'; }

visible_content() { # $1 json  $2 tier  $3 tool(Bash|Read)
  local json="$1" tier="$2" tool="$3" out
  if [ "$tier" = control ]; then
    if [ "$tool" = Bash ]; then printf '%s' "$json"|jq -r '.tool_response.stdout'
    else printf '%s' "$json"|jq -r '.tool_response.file.content'; fi
    return
  fi
  rm -rf "$SD/dedup"; printf '%s' "$tier" > "$SD/active-tier"
  out=$(JULIUS_STATE_DIR="$SD" bash "$ROOT/scripts/compress-output.sh" 2>/dev/null <<<"$json")
  if [ -z "$out" ]; then
    if [ "$tool" = Bash ]; then printf '%s' "$json"|jq -r '.tool_response.stdout'
    else printf '%s' "$json"|jq -r '.tool_response.file.content'; fi
  else
    if [ "$tool" = Bash ]; then printf '%s' "$out"|jq -r '.hookSpecificOutput.updatedToolOutput.stdout'
    else printf '%s' "$out"|jq -r '.hookSpecificOutput.updatedToolOutput.file.content'; fi
  fi
}

gen() {
case "$1" in
 1) seq 1 300|awk '{print "[build] compiling module_"$1".o"} NR==150{print "warning: unused var x in module_150"}';;
 2) { seq 1 197|awk '{print "tests/test_"$1".py::test_case PASSED"}'; echo "tests/test_x.py::test_auth FAILED"; echo "E   AssertionError: token expiry off-by-one"; echo "Traceback (most recent call last): File auth.py line 42"; };;
 3) seq 1 150|awk '{print "npm http fetch GET 200 https://registry/pkg_"$1" 1234ms"}';;
 4) seq 1 120|awk '{print "commit "$1"abc def  fix: change number "$1}';;
 5) seq 1 260|awk '{print "./src/dir_"int($1/10)"/file_"$1".py"}';;
 6) seq 1 400|awk '{print "    line "$1": code statement here; do_thing("$1")"}';;
 7) seq 1 150|awk '{print "  \"key_"$1"\": \"value_"$1"\","}';;
 8) seq 1 500|awk '{if($1%7==0) print "ERROR: failure at record "$1; else print "info: processed record "$1}';;
 9) seq 1 180|awk '{printf "\033[32m[ci]\033[0m step %d running\n",$1} END{for(i=0;i<20;i++)print "Progress: ##########"}';;
 10) seq 1 200|awk '{print "duplicate-run output line "$1}';;
esac
}
TOOL_OF() { case "$1" in 6|7|8) echo Read;; *) echo Bash;; esac; }
NAME_OF() { case "$1" in
 1) echo "Bash build log (300L)";; 2) echo "Bash pytest +fail (200L)";; 3) echo "Bash npm install (150L)";;
 4) echo "Bash git log (120L)";; 5) echo "Bash find paths (260L)";; 6) echo "Read source file (400L)";;
 7) echo "Read json config (150L)";; 8) echo "Read error log (500L)";; 9) echo "Bash CI+ANSI (200L)";;
 10) echo "Bash dup output (200L)";; esac; }

declare -A SUM; for t in $TIERS; do SUM[$t]=0; done
printf "%-26s | %8s | %8s | %8s | %8s\n" "scenario" control normal pro beast
printf -- "---------------------------|----------|----------|----------|----------\n"
for s in $(seq 1 10); do
  tool=$(TOOL_OF "$s"); content=$(gen "$s")
  if [ "$tool" = Bash ]; then json=$(printf '%s' "$content"|bash_json "cmd$s"); else json=$(printf '%s' "$content"|read_json "/src/file$s"); fi
  row=""
  for t in $TIERS; do
    tk=$(visible_content "$json" "$t" "$tool" | toktok)
    SUM[$t]=$(( ${SUM[$t]} + tk ))
    row="$row | $(printf '%8d' "$tk")"
  done
  printf "%-26s%s\n" "$(NAME_OF "$s")" "$row"
done
printf -- "---------------------------|----------|----------|----------|----------\n"
printf "%-26s | %8d | %8d | %8d | %8d\n" "TOTAL est tokens" "${SUM[control]}" "${SUM[normal]}" "${SUM[pro]}" "${SUM[beast]}"
c=${SUM[control]}
printf "%-26s | %8s | %7d%% | %7d%% | %7d%%\n" "saved vs control" "-" \
  $(( (c-${SUM[normal]})*100/c )) $(( (c-${SUM[pro]})*100/c )) $(( (c-${SUM[beast]})*100/c ))

echo
echo "Dedup (2nd identical occurrence of the 200L output):"
json=$(gen 10|bash_json "cmd10")
for t in pro beast; do
  rm -rf "$SD/dedup"; printf '%s' "$t" > "$SD/active-tier"
  first=$(visible_content "$json" "$t" Bash|toktok)
  JULIUS_STATE_DIR="$SD" bash "$ROOT/scripts/compress-output.sh" >/dev/null 2>&1 <<<"$json"
  out=$(JULIUS_STATE_DIR="$SD" bash "$ROOT/scripts/compress-output.sh" 2>/dev/null <<<"$json")
  vis=$(printf '%s' "$out"|jq -r '.hookSpecificOutput.updatedToolOutput.stdout' 2>/dev/null)
  full=$(printf '%s' "$json"|jq -r '.tool_response.stdout')
  printf "  %-6s 1st=%d tok  2nd=%d tok  (control 2nd=%d tok)\n" "$t" "$first" "$(printf '%s' "$vis"|toktok)" "$(printf '%s' "$full"|toktok)"
done
rm -rf "$(dirname "$SD")"
