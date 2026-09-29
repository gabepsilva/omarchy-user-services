#!/bin/bash
# Run a command with its output bounded in bytes before it reaches the shell:
#
#   capped.sh <max-bytes> <command> [args...]
#
# The panel collects each command's output whole (StdioCollector with
# waitForEnd), and `timeout` bounds only how long a command runs, not how
# much it prints. Here `head` cuts stdout at max-bytes + 1 (the extra byte
# shows it overflowed) and stderr at max-bytes, so the shell never buffers
# more than that whatever the command does.
#
# Output that fits is passed through byte for byte with the command's own
# exit status. Output that doesn't is dropped rather than passed on cut,
# and the exit status is 90 (Model.OVERFLOW_EXIT), so the panel never parses
# a truncated payload.

cap=$1
shift
case $cap in '' | *[!0-9]*) exit 2 ;; esac
[ $# -gt 0 ] || exit 2

# stdout through one head into $out, stderr (swapped onto the pipe) through
# another straight to our stderr. The trailing x keeps $(...) from eating
# trailing newlines, which would hide a cut that landed after one.
out=$(
  { "$@" 2>&1 >&3 3>&- | head -c "$cap" >&2; exit "${PIPESTATUS[0]}"; } 3>&1 \
    | head -c "$((cap + 1))"
  status=${PIPESTATUS[0]}
  printf x
  exit "$status"
)
status=$?
out=${out%x}

# Measure bytes, not characters.
LC_ALL=C
if [ "${#out}" -gt "$cap" ]; then
  echo "output passed $cap bytes" >&2
  exit 90
fi
printf '%s' "$out"
exit "$status"
