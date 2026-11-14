# Playtest scripts

Short scripts for trying a build in the headset (or on the desktop) and reporting back in a way we can act on.
Each script lives here as `<area>-<nn>.md`. The VR lead keeps the VR ones up to date as features land.

## How a script is written

- At most 15 numbered steps. Each step is one concrete action, the result we expect, and a blank for what happened:
  `3. Grip an item on a table and lift it. Expect: it follows the hand. Happened: ____`
- First, how to start the build, open the VR menu and quit safely. Last, a comfort check and what to send.
- Steps go from the most basic (does it start) to the newest feature, so a broken basic stops the run early.
- Nothing personal in a script or a report: no names, accounts or chat handles.

## While playing

- **Report a bug** (VR menu, the left menu button, last row): saves what you were doing and a picture of your view in
  `bug_reports/` in Godot's user folder. Press it right when something goes wrong, then carry on.
- **Comfort comes first.** Stop at once if you feel warm, sweaty, dizzy or sick; don't push through, and wait at
  least an hour before trying again. A run stopped for comfort is the most serious kind of bug: say which step and
  what was moving (turning, walking, a fall, the panel).

## What to send back

- The script with the blanks filled in (a line each is plenty; "as expected" is fine).
- `vr_perf.log` and the `bug_reports/` folder from Godot's user folder: Windows `%APPDATA%\Godot\app_userdata\CDDA-3D\`,
  Linux `~/.local/share/godot/app_userdata/CDDA-3D/`. The log starts with the headset runtime, the controllers and
  any VR settings you changed (your height setting included, which helps with size bugs), so you don't have to type
  them. A bug report's picture shows your view as it was, wrist HUD and game messages included.
- The console output, when the game was started from a terminal.

## Severity (how we sort what comes back)

1. A crash, a hang, a lost save, or anything that made you feel unwell.
2. A feature that doesn't work at all.
3. It works, but badly or with a workaround.
4. Looks, polish, frame rate.
