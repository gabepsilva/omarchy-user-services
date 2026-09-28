#!/bin/bash
# Print "<unit>=<bytes>" for every user service holding GPU memory, or only
# for the unit given as the first argument.
#
# Two sources, summed per process and then per service:
#   - DRM fdinfo (/proc/<pid>/fdinfo/*, drm-total-vram): the kernel's own
#     per-client accounting, reported by amdgpu, i915/xe, nouveau and others.
#     Each DRM client is counted once even when its fd is duplicated.
#   - nvidia-smi, only if already installed: the proprietary NVIDIA driver
#     keeps CUDA memory outside DRM, so fdinfo cannot see it.
#
# Only processes that hold a GPU are looked at: find their DRM fds first,
# then read those few processes' /proc/<pid>/cgroup to learn which user
# service they belong to.

only_unit=$1

# /proc/<pid>/fd/<n> of every GPU device fd we can see (our own processes).
mapfile -t drm_fds < <(find /proc/[0-9]*/fd -maxdepth 1 -lname '/dev/dri/*' 2>/dev/null)

nvidia=""
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null)
fi

# Files for awk: each GPU fd's fdinfo, then the cgroup file of every process
# involved (DRM holders and NVIDIA compute processes).
declare -A pids=()
files=()
for fd in "${drm_fds[@]}"; do
  pid=${fd#/proc/}; pid=${pid%%/*}
  pids[$pid]=1
  files+=("/proc/$pid/fdinfo/${fd##*/}")
done
while IFS=', ' read -r pid _; do
  [ -n "$pid" ] && pids[$pid]=1
done <<< "$nvidia"
for pid in "${!pids[@]}"; do
  files+=("/proc/$pid/cgroup")
done
[ ${#files[@]} -gt 0 ] || exit 0

awk -v nvidia="$nvidia" -v only="$only_unit" '
  function bytes(n, u) {
    if (u == "KiB") return n * 1024
    if (u == "MiB") return n * 1048576
    if (u == "GiB") return n * 1073741824
    return n
  }
  function pid_of(path,   p) { split(path, p, "/"); return p[3] }

  # fdinfo: "drm-key:<tab>value [unit]"
  FILENAME ~ /\/fdinfo\// {
    key = $1; sub(/:$/, "", key)
    if (key == "drm-client-id") client[FILENAME] = $2
    else if (key == "drm-pdev") pdev[FILENAME] = $2
    else if (key == "drm-total-vram" || key == "drm-memory-vram") vram[FILENAME] = bytes($2, $3)
    next
  }

  # cgroup v2: "0::/user.slice/.../user@1000.service/app.slice/foo.service[/...]".
  # The unit is the first *.service component under the user manager.
  FILENAME ~ /\/cgroup$/ {
    if (substr($0, 1, 3) != "0::") next
    n = split(substr($0, 4), part, "/")
    seen_manager = 0
    for (i = 1; i <= n; i++) {
      if (!seen_manager) { if (part[i] ~ /^user@[0-9]+\.service$/) seen_manager = 1; continue }
      if (part[i] ~ /\.service$/) { unit_of[pid_of(FILENAME)] = part[i]; break }
    }
    next
  }

  END {
    for (f in vram) {
      if (!(f in client) || vram[f] <= 0) continue
      pid = pid_of(f)
      if (!(pid in unit_of)) continue
      k = pid "/" pdev[f] "/" client[f]
      if (k in counted) continue
      counted[k] = 1
      total[unit_of[pid]] += vram[f]
    }
    n = split(nvidia, line, "\n")
    for (i = 1; i <= n; i++) {
      if (split(line[i], field, /, */) < 2) continue
      if (field[1] in unit_of) total[unit_of[field[1]]] += field[2] * 1048576
    }
    for (u in total)
      if (total[u] >= 1048576 && (only == "" || u == only)) printf "%s=%.0f\n", u, total[u]
  }
' "${files[@]}" 2>/dev/null
