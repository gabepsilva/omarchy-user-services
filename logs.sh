#!/bin/sh
# Print the newest journal lines of a user unit, bounded in bytes.
#
#   logs.sh <unit> [lines] [max-bytes]
#
# `journalctl -n` limits entries, not size, and a single entry can be huge.
# `tail -c` keeps only the newest max-bytes (+1 to detect overflow) before
# anything reaches the shell. When output was cut, the partial first line is
# dropped and a notice is printed first.

unit=$1
lines=${2:-300}
cap=${3:-65536}

[ -n "$unit" ] || exit 2

journalctl --user-unit="$unit" -n "$lines" --no-pager --no-hostname -o short 2>/dev/null \
  | tail -c "$((cap + 1))" \
  | LC_ALL=C awk -v cap="$cap" '
      { buf[NR] = $0; size += length($0) + 1 }
      END {
        start = 1
        if (size > cap) {
          printf "… older log output not shown (capped at %d KiB)\n", cap / 1024
          start = 2
        }
        for (i = start; i <= NR; i++) print buf[i]
      }
    '
