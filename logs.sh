#!/bin/sh
# Print the newest journal lines of a user unit, bounded in bytes, each
# prefixed with its syslog priority:
#
#   <priority><TAB><line in journalctl's "short" layout>
#
#   logs.sh <unit> [lines] [max-bytes]
#
# The priority (0 emerg … 7 debug) lets the panel colour lines. Messages
# spanning several lines keep their priority on every line and are indented
# like `journalctl -o short` does. `-` marks lines that are not log entries
# (the truncation notice).
#
# `journalctl -n` limits entries, not size, and a single entry can be huge.
# `tail -c` keeps only the newest max-bytes (+1 to detect overflow) before
# anything reaches the shell. When output was cut, the partial first line is
# dropped and a notice is printed first.

unit=$1
lines=${2:-300}
cap=${3:-65536}

[ -n "$unit" ] || exit 2

entries() {
  if command -v jq >/dev/null 2>&1; then
    journalctl --user-unit="$unit" -n "$lines" --no-pager -o json \
      --output-fields=MESSAGE,PRIORITY,SYSLOG_IDENTIFIER,_COMM,_PID,_SOURCE_REALTIME_TIMESTAMP 2>/dev/null \
      | jq -rn '
          # Messages with control characters (e.g. colour escapes) are
          # stored as byte arrays; decode UTF-8 like journalctl prints them.
          def utf8:
            . as $b
            | [foreach range(0; $b | length) as $i ({cp: 0, need: 0, out: null};
                $b[$i] as $x
                | if .need == 0 then
                    if $x < 128 then {cp: 0, need: 0, out: $x}
                    elif $x >= 240 then {cp: ($x % 8), need: 3, out: null}
                    elif $x >= 224 then {cp: ($x % 16), need: 2, out: null}
                    elif $x >= 192 then {cp: ($x % 32), need: 1, out: null}
                    else {cp: 0, need: 0, out: 65533} end
                  else
                    (.cp * 64 + ($x % 64)) as $c
                    | if .need == 1 then {cp: 0, need: 0, out: $c}
                      else {cp: $c, need: (.need - 1), out: null} end
                  end;
                .out) | select(. != null)]
            | implode;
          # Same rule and wording as journalctl: text unless it holds control
          # bytes other than tab, newline and escape (colour codes are kept
          # for the panel to render).
          def size:
            if . < 1024 then "\(.)B" else "\((. / 102.4 | floor) / 10)K" end;
          def message:
            if type == "array" then
              if any(.[]; . < 32 and . != 9 and . != 10 and . != 27)
              then "[\(length | size) blob data]" else utf8 end
            elif . == null then ""
            else . end;
          foreach inputs as $e ({boot: null};
            .sep = (.boot != null and .boot != $e._BOOT_ID) | .boot = $e._BOOT_ID;
            (if .sep then "-\t-- Boot \($e._BOOT_ID) --" else empty end),
            ((($e.PRIORITY // "6") | tostring) as $p
             | ((($e._SOURCE_REALTIME_TIMESTAMP // $e.__REALTIME_TIMESTAMP) | tonumber / 1000000 | floor | strflocaltime("%b %d %H:%M:%S"))
                + " " + ($e.SYSLOG_IDENTIFIER // $e._COMM // "?")
                + (if $e._PID then "[" + $e._PID + "]" else "" end) + ": ") as $head
             | ($e.MESSAGE | message | gsub("\t"; "        ") | split("\n")) as $msg
             | ($p + "\t" + $head + $msg[0]),
               ($msg[1:][] | $p + "\t" + (" " * ($head | length)) + .)))
        ' 2>/dev/null
  else
    # No jq: plain lines, every one treated as informational.
    journalctl --user-unit="$unit" -n "$lines" --no-pager --no-hostname -o short 2>/dev/null \
      | grep -v '^-- No entries --$' \
      | sed 's/^/6\t/'
  fi
}

entries \
  | tail -c "$((cap + 1))" \
  | LC_ALL=C awk -v cap="$cap" '
      { buf[NR] = $0; size += length($0) + 1 }
      END {
        start = 1
        if (size > cap) {
          printf "-\t… older log output not shown (capped at %d KiB)\n", cap / 1024
          start = 2
        }
        for (i = start; i <= NR; i++) print buf[i]
      }
    '
