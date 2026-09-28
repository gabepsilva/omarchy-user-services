#!/bin/sh
# Print "<unit>=<bytes>" for every user service, where bytes is the RAM the
# service itself holds: anonymous memory + shmem + kernel memory from its
# cgroup's memory.stat. Page cache (e.g. model weights read from disk) is
# left out; the kernel drops it whenever something else needs the memory.

systemctl --user show -p Id,ControlGroup --no-pager -- '*.service' | awk -F= '
  function flush() {
    if (id != "" && cg != "") {
      f = "/sys/fs/cgroup" cg "/memory.stat"
      used = 0
      while ((getline line < f) > 0) {
        split(line, p, " ")
        if (p[1] == "anon" || p[1] == "shmem" || p[1] == "kernel") used += p[2]
      }
      close(f)
      if (used > 0) print id "=" used
    }
    id = ""; cg = ""
  }
  /^Id=/           { id = substr($0, 4) }
  /^ControlGroup=/ { cg = substr($0, 14) }
  /^$/             { flush() }
  END              { flush() }
'
