# Troubleshooting

## The Workspaces item is not in the menu bar

On a MacBook with a notch, macOS hides the menu-bar items that do not fit beside it,
and Brow's may be one of them. Workspaces still opens from the stacked-squares button
in the notch panel's footer, from **Show Workspaces** in Brow's menu (the menu bar
shows it while Brow's Settings window is in front), and when you open Brow again from
Finder, Spotlight or `open -a Brow`. Settings › General › **Show Workspaces in the menu bar** turns the
item off altogether. While Workspaces is off there is no item at all.

## Workspaces says Grove is still running

Workspaces stays paused while `Grove.app` (`dev.artemefimov.grove3`, or the older
`dev.artemefimov.grove`) runs: the two would write the same `config.json` and run the
transcript safety net twice. Press **Quit Grove**, or quit it from its own panel; Brow
starts Workspaces as soon as Grove has quit. If Grove starts at login, remove it from
System Settings › General › Login Items.

## "cmux unavailable" although cmux is running

cmux's control socket only accepts clients whose process ancestry traces into
the cmux app (`automation.socketControlMode`, default `"cmuxOnly"`). Commands
work from any cmux-hosted terminal, but Brow launched from Finder/Dock/`open`
descends from launchd, so the server rejects every call ("ERROR: Access denied
— only processes started inside cmux can connect"; the cmux CLI surfaces this
only as "Failed to write to socket (Broken pipe)"). One-time fix in cmux:
Settings > Automation > Socket control mode -> "Automation" (allows external
clients from your user account; equivalently set
`"automation": {"socketControlMode": "automation"}` in `~/.config/cmux/cmux.json`
and `cmux reload-config`). cmux applies the mode when its CLI listener starts,
so afterwards run cmux's "Restart CLI Listener" palette command or restart
cmux once. Alternatively set a socket password in the same settings pane —
Brow reads `automation.socketPassword` from `~/.config/cmux/cmux.json` and
forwards it as `CMUX_SOCKET_PASSWORD` automatically.

Since the AppleScript fallback (`CmuxAppleScript`), a socket denial is also
self-healing: Brow switches to driving cmux through its AppleScript
dictionary (one-time macOS consent dialog: System Settings > Privacy &
Security > Automation > Brow > cmux) and silently returns to the socket once
it accepts Brow again. Workspaces created via the fallback keep cmux's
cwd-derived tab title (the dictionary has no rename). `Scripts/build-brow.sh`
signs with `BROW_SIGN_IDENTITY` when you set one, so the automation grant
survives rebuilds.

## cmux diagnostic probe

`Brow.app` ships a hidden diagnostic flag that runs the exact production cmux
call path (ping, ensure-running, list, create + close a probe workspace —
exercising BOTH the socket backend and the AppleScript fallback) WITHOUT the
error-swallowing the UI does, and writes a step-by-step report (environment,
executable resolution, per-step stdout/stderr/error, raw-socket denial check,
active backend):

    open -nW /Applications/Brow.app --args --cmux-probe /tmp/cmux-probe.txt
    cat /tmp/cmux-probe.txt

Launching through `open` (LaunchServices) is the point: it reproduces the real
GUI context (no TTY, launchd ancestry). `-n` forces a new instance when Brow
is already running; the probe exits without starting the notch or Workspaces.
Running the binary directly
(`/Applications/Brow.app/Contents/MacOS/Brow --cmux-probe /tmp/p.txt`) probes the
terminal context instead — comparing the two reports isolates
context-dependent failures like the socket access mode above. A build of your
own is at `dist/Brow.app` after `Scripts/build-brow.sh`.

## Brow's settings were reset

Brow reads `~/Library/Application Support/Brow/config.json` field by field: a value
it cannot read falls back to its default and costs nothing else. When that happens,
the file as it was is kept as `config.json.bak` next to it, before the next settings
change saves over it, so you can copy a hand-edited value back.
