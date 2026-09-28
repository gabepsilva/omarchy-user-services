#!/bin/bash
# Print "<unit>=<bytes>" for every user service holding GPU memory.
#
# Two sources, summed per process and then per service:
#   - DRM fdinfo (/proc/<pid>/fdinfo/*, drm-total-vram): the kernel's own
#     per-client accounting, reported by amdgpu, i915/xe, nouveau and others.
#     Each DRM client is counted once even when its fd is duplicated.
#   - nvidia-smi, only if already installed: the proprietary NVIDIA driver
#     keeps CUDA memory outside DRM, so fdinfo cannot see it.

declare -A unit_of   # pid -> unit
declare -A vram      # unit -> bytes

# pid -> unit, from each service's cgroup (including nested cgroups).
while IFS='|' read -r unit cg; do
  [ -n "$cg" ] || continue
  dir="/sys/fs/cgroup$cg"
  [ -d "$dir" ] || continue
  while read -r pid; do
    [ -n "$pid" ] && unit_of[$pid]=$unit
  done < <(find "$dir" -name cgroup.procs -exec cat {} + 2>/dev/null)
done < <(systemctl --user show -p Id,ControlGroup --no-pager -- '*.service' | awk -F= '
  /^Id=/           { id = substr($0, 4) }
  /^ControlGroup=/ { cg = substr($0, 14) }
  /^$/             { if (id != "") print id "|" cg; id = ""; cg = "" }
  END              { if (id != "") print id "|" cg }
')

to_bytes() {  # "<n> <unit>" -> bytes
  case "$2" in
    KiB) echo $(( $1 * 1024 )) ;;
    MiB) echo $(( $1 * 1048576 )) ;;
    GiB) echo $(( $1 * 1073741824 )) ;;
    *)   echo "$1" ;;
  esac
}

# DRM fdinfo. One find over every service process lists just the GPU device
# fds; other fdinfo files can be huge (an inotify fd lists every watch).
declare -A seen      # pid/pdev/client -> 1, so a dup'ed fd counts once
if [ ${#unit_of[@]} -gt 0 ]; then
  dirs=()
  for pid in "${!unit_of[@]}"; do dirs+=("/proc/$pid/fd"); done
  while read -r fdpath; do
    pid=${fdpath#/proc/}; pid=${pid%%/*}
    client="" pdev="" bytes=0
    while IFS=$': \t' read -r key val unit _; do
      case "$key" in
        drm-client-id) client=$val ;;
        drm-pdev) pdev=$val ;;
        drm-total-vram|drm-memory-vram) bytes=$(to_bytes "$val" "$unit") ;;
      esac
    done < <(grep -E '^drm-(client-id|pdev|total-vram|memory-vram):' "/proc/$pid/fdinfo/${fdpath##*/}" 2>/dev/null)
    [ -n "$client" ] && [ "$bytes" -gt 0 ] || continue
    key="$pid/$pdev/$client"
    [ -z "${seen[$key]}" ] || continue
    seen[$key]=1
    u=${unit_of[$pid]}
    vram[$u]=$(( ${vram[$u]:-0} + bytes ))
  done < <(find "${dirs[@]}" -maxdepth 1 -lname '/dev/dri/*' 2>/dev/null)
fi

# NVIDIA proprietary driver.
if command -v nvidia-smi >/dev/null 2>&1; then
  while IFS=', ' read -r pid mib; do
    u=${unit_of[$pid]}
    [ -n "$u" ] && [ -n "$mib" ] || continue
    vram[$u]=$(( ${vram[$u]:-0} + mib * 1048576 ))
  done < <(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null)
fi

for u in "${!vram[@]}"; do
  [ "${vram[$u]}" -ge 1048576 ] && echo "$u=${vram[$u]}"
done
