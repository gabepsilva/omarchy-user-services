# User Services

An Omarchy bar widget that lists your `systemctl --user` services. Each row has
a switch to start/stop the service and shows the RAM and VRAM it holds; a
details dialog adds restart, start-at-login, resource figures and live logs.
The bar icon turns urgent when any user service has failed.

## Install

```sh
omarchy plugin add https://github.com/gabepsilva/omarchy-user-services.git --enable
```

## Usage

- **Left click** the icon to open the list, **middle click** to refresh.
- **Favorites** tab: your starred services, in your order. Drag the `󰇛`
  handle to reorder (or `Shift+J`/`Shift+K`).
- **All** tab: every loaded service with a filter; failed first, then running,
  then stopped. Click the star (or press `s`) to add/remove a favorite.
- Running services show the RAM they actually hold (page cache excluded) and,
  underneath, their GPU memory when they use any. Hover for labels.
- **Details** (`󰋽` or `d`): name and description with a **restart** button;
  status, PID, uptime, RAM, VRAM, CPU time and tasks, refreshed every 2s; a
  **Start at login** switch (`systemctl --user enable/disable`); and the
  unit's live journal. `f` (or the terminal button) follows the logs in a
  floating terminal, `e` flips start at login, `r` restarts, `Esc` goes back.
- Keyboard: `j`/`k` or arrows move, `h`/`l` switch tabs, `Enter`/`Space`
  start/stop, `r` restart, `d` details, `s` favorite, `/` filter, `R` refresh,
  `Esc` close.

### How memory is measured

- **RAM**: `anon + shmem + kernel` from each service's cgroup `memory.stat`
  (`memory.sh`). Disk cache such as model weights is left out; the kernel
  drops it whenever something else needs the memory.
- **VRAM** (`vram.sh`): the kernel's DRM fdinfo (`drm-total-vram`) for amdgpu,
  i915/xe, nouveau and other DRM drivers, plus `nvidia-smi` when it is
  installed, since the proprietary NVIDIA driver keeps CUDA memory outside DRM.
  Nothing extra needs installing.

IPC:

```sh
omarchy-shell io.github.gabepsilva.user-services restart foo.service
omarchy-shell io.github.gabepsilva.user-services start|stop foo.service
omarchy-shell io.github.gabepsilva.user-services refresh|toggle
omarchy-shell io.github.gabepsilva.user-services favorite foo.service   # toggle
omarchy-shell io.github.gabepsilva.user-services details foo.service
```

## Settings

| Key                  | Default | Meaning                                      |
|----------------------|---------|----------------------------------------------|
| `showInactive`       | `true`  | List stopped services too                    |
| `hideAutostart`      | `true`  | Hide generated `app-*@autostart.service`     |
| `refreshIntervalSec` | `5`     | Poll interval while the popup is open        |
| `favorites`          | `[]`    | Ordered unit names (managed by the popup)    |

## Caution

Commands run as your user with no confirmation. Stopping session plumbing such
as `dbus-broker` or `pipewire` will break your desktop session until it's
restarted.
