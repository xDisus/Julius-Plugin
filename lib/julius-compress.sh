#!/usr/bin/env bash
# julius-compress.sh — deterministic, offline compression primitives for Julius.
# Pure stdin->stdout filters: no network, no state, no API key required. Sourced by
# the PostToolUse compressor. Kept separate from julius-common.sh so the transforms
# are unit-testable in isolation.
#
# Functions:
#   jc_strip_ansi              strip ANSI/CSI escape sequences
#   jc_collapse_dups           collapse runs of identical consecutive lines -> "line (×N)"
#   jc_middle_out HEAD TAIL    keep first HEAD + last TAIL + every error/warn line;
#                              replace the elided middle with "[… N lines elided …]"
#   jc_compress HEAD TAIL      strip_ansi | collapse_dups | middle_out (no-op if small)

# Remove ANSI escape sequences (colors, cursor moves). Uses a literal ESC so it works
# on both GNU and BSD sed (BSD sed has no \x1b).
jc_strip_ansi() {
  local esc
  esc=$(printf '\033')
  sed "s/${esc}\[[0-9;?]*[a-zA-Z]//g; s/${esc}[()][AB0-2]//g"
}

# Collapse runs of identical consecutive lines into a single "line (×N)" line.
jc_collapse_dups() {
  awk '
    NR==1 { prev=$0; cnt=1; next }
    $0==prev { cnt++; next }
    { if (cnt>1) printf "%s (×%d)\n", prev, cnt; else print prev; prev=$0; cnt=1 }
    END { if (NR>0) { if (cnt>1) printf "%s (×%d)\n", prev, cnt; else print prev } }
  '
}

# Middle-out truncation. Keeps the first HEAD and last TAIL lines verbatim, always
# preserves any line matching error|warn|fail|traceback|exception (case-insensitive),
# and replaces the remaining elided middle with a single marker. Order is preserved.
# No-op when the input already fits within HEAD+TAIL.
jc_middle_out() {
  local head="${1:-20}" tail="${2:-20}"
  awk -v head="$head" -v tail="$tail" '
    { lines[NR]=$0 }
    END {
      n=NR
      if (n <= head+tail) { for (i=1;i<=n;i++) print lines[i]; exit }
      for (i=1;i<=head;i++) print lines[i]
      elided=0
      for (i=head+1;i<=n-tail;i++) {
        if (tolower(lines[i]) ~ /error|warn|fail|traceback|exception/) print lines[i]
        else elided++
      }
      if (elided>0) printf "[… %d lines elided …]\n", elided
      for (i=n-tail+1;i<=n;i++) print lines[i]
    }
  '
}

# Full deterministic pipeline. middle_out's own size guard makes this a passthrough
# for small inputs.
jc_compress() {
  local head="${1:-20}" tail="${2:-20}"
  jc_strip_ansi | jc_collapse_dups | jc_middle_out "$head" "$tail"
}

# Cap a newline-separated list to the first N entries, appending "(… M more …)".
# For file lists (Glob output, Grep files_with_matches) where order-preserving head
# truncation reads better than middle-out. No-op when the list already fits.
jc_cap_list() {
  local n="${1:-40}"
  awk -v n="$n" '
    { a[NR]=$0 }
    END {
      if (NR<=n) { for (i=1;i<=NR;i++) print a[i]; exit }
      for (i=1;i<=n;i++) print a[i]
      printf "(… %d more …)\n", NR-n
    }'
}
