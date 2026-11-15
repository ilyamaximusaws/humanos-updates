# humanos-updates

Update badge for the Omarchy bar: a capsule that shows how many updates are
waiting, and a dropdown that says where they are.

## What the capsule shows

| state | capsule |
| --- | --- |
| nothing waiting | `0` |
| packages waiting | the count, e.g. `2` |
| a new Omarchy release | its version, e.g. `1.7-2`, or `1.7-2 +3` when other packages wait too |
| the last full upgrade is too old | `14d` — how old, so it is never mistaken for a fresh all-clear |
| no check has run yet | `—` |

The dot carries the colour: green when everything is current, amber while
updates wait, red when the last full upgrade is older than `staleAfterDays`,
dim while the state is unknown.

## Install

```sh
git clone https://github.com/ilyamaximusaws/humanos-updates \
  ~/.config/omarchy/plugins/humanos-updates
```

Add it to the bar in `~/.config/omarchy/shell.json`:

```json
"bar": { "layout": { "left": [ { "id": "humanos-updates" } ] } }
```

and reload the shell (`omarchy-restart-shell`).

## Hotkey and IPC

```sh
omarchy-shell humanos.updates toggle
omarchy-shell humanos.updates refresh
```

`open`, `close` and `toggle` drive the dropdown, `refresh` starts a background
check; both are what a Hyprland keybinding should call.

## How it works

- `scripts/humanos-update-check` gathers everything and prints one JSON line:
  `checkupdates` for repository packages and the new Omarchy release (it runs
  under a temporary database, so it never takes the pacman lock), `yay -Qua`
  for the AUR, `flatpak remote-ls --updates`, and `omacontrol plugin updates`
  for git-managed plugins. Every source also reports its package list, so the
  dropdown can show what is waiting, not just how much.
- Nothing is invented when a source cannot be reached: that run is marked
  `degraded`, the cache keeps the previous answer, and the widget holds the
  badge it already had instead of turning `updates` into `0`.
- Results are cached in `~/.cache/omarchy/humanos-update-cache.json`; the
  widget reads it synchronously on startup, so a fresh session or a bar reload
  shows the last answer at once instead of a placeholder.
- The check runs every 6 hours, when the dropdown is opened, and on demand
  (`refresh`). After a boot without network the widget retries after 20 s, 60 s
  and 180 s.

## Tests

```sh
node tests/test-humanos-updates-labels.js   # capsule label logic
bash tests/test-humanos-update-check.sh     # the check script (needs pacman, network)
```

## Requirements

Omarchy with Quickshell; `pacman-contrib` for `checkupdates`; optionally `yay`
(AUR), `flatpak`, and the omacontrol plugin for plugin updates. Sources that are
not installed are reported as `skip`, not as failures.

## Licence

MIT — see `LICENSE`.
