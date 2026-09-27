# SuperCaffeinate menu bar app

A menu bar item for `supercaffeinate`. It shows at a glance whether the
machine is being held awake, and lets you flip it without a terminal.

- Filled cup = on
- Outline cup = off
- Warning triangle = the state file exists but the caffeinate pid is dead, so
  something died badly and `supercaffeinate off` should be run to clean up

The icon is a template SF Symbol, so it follows light and dark menu bars on its
own. Clicking it opens a menu with the status line ("Awake, since HH:MM",
"Awake, 7h 42m left" or "Off"), the lid line when on, Turn On / Turn Off items
that run `~/bin/supercaffeinate on|off`, and Quit.

When off there are two ways to turn on: Turn On (indefinite) and Turn On
For..., which asks for a number of hours (decimals like 0.5 are fine, blank or 0
means indefinite) and runs `supercaffeinate on <minutes>m`, so the script turns
itself off when the time is up.

## How it decides

Same test as the script: `/tmp/supercaffeinate.state` must exist and `kill -0`
on its first line (the `caffeinate -ims` pid) must succeed. The poll is a stat
plus a `kill(pid, 0)` every 2 seconds, no subprocess, so state changes made from
anywhere else (a hotkey, a terminal) show up within a couple of seconds. The lid
is only queried with `ioreg` when the menu is about to open. Turning on and off
runs off the main thread so the menu bar never stalls.

The "since" time comes from the modification time of the state file, which the
script writes the moment it turns on. When a timer is set, line 4 of the state
file holds the auto-off deadline (epoch seconds) and the status line shows the
time left instead, e.g. "Awake, 7h 42m left".

## Build

    menubar/build.sh

`install.sh` at the repo root runs this for you. It compiles `main.swift` with
`swiftc`, assembles the bundle by hand, installs it to
`~/Applications/SuperCaffeinate.app`, and reloads the LaunchAgent
`com.sawyer.supercaffeinate-menubar` if it is installed so the new build is the
one running.

There is no Xcode project. The bundle is just an executable plus an Info.plist
with `LSUIElement` true, which is what keeps it out of the Dock, plus the app
icon.

## App icon

`icon/AppIcon.icns` is the bundle icon shown in Finder, Spotlight and Login
Items (the menu bar glyph is still the SF Symbol cup). It is generated, not
drawn by hand:

    python3 menubar/icon/make_icon.py

draws a cream cup, saucer and steam on a brown to amber squircle with Pillow,
writes `icon/AppIcon-1024.png`, sizes the `icon/AppIcon.iconset` with `sips`
and packs it with `iconutil`. The .icns is checked in, so `build.sh` only copies
it into `Contents/Resources`; rerun the generator only to change the design.

## Debugging without clicking

    "$HOME/Applications/SuperCaffeinate.app/Contents/MacOS/SuperCaffeinate" --dump-menu

builds the menu exactly as a click would and prints it, then exits. The running
copy also logs one line per state change to `/tmp/supercaffeinate-menubar.out`.

## Menu bar managers

If you use a menu bar manager such as Ice or Bartender, a new status item
usually lands in the hidden section. If the cup is nowhere to be seen, check
there first; `pgrep -f MacOS/SuperCaffeinate` tells you whether it is running.

## Uninstall

    launchctl bootout gui/$(id -u)/com.sawyer.supercaffeinate-menubar
    rm ~/Library/LaunchAgents/com.sawyer.supercaffeinate-menubar.plist
    rm -rf "$HOME/Applications/SuperCaffeinate.app"

The `supercaffeinate` script itself is untouched by any of this.
