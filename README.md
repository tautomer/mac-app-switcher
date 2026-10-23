<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/icon-dark.png">
    <img src="docs/icon.png" width="128" height="128" alt="ContextSwitch icon">
  </picture>
</p>

<h1 align="center">ContextSwitch</h1>

<p align="center">
  A macOS menu bar app that launches and quits apps based on where you are<br>
  and what's plugged in.
</p>

> [!WARNING]
> **ContextSwitch is completely vibe coded.** None of it was written by hand:
> the author described what they wanted, and an AI coding agent wrote all of
> the code, the tests, the build scripts and the docs, this README included.
> It works on the author's Mac, but nobody has audited it, and it launches
> and quits apps on yours. Use it at your own risk, and try a new profile
> with [`--dry-run`](#command-line) before trusting it.

## What it does

You describe your situations as **profiles**. Each one has conditions that
say when it applies, and a list of apps to launch or quit when it does. When
your network or connected devices change, ContextSwitch picks the profile
that matches and sets your apps up for it.

For example:

- **Office**: on the office Wi-Fi, or the company VPN's DNS domain is set.
  Launch Slack and Outlook, quit Steam.
- **Desk**: your dock's Ethernet adapter is connected. Launch your
  monitoring tools and OpenRGB in server mode.
- **Mobile**: no conditions, so it's the fallback when nothing else matches.
  Quit everything that drains the battery.

## Features

### Conditions

| Condition | Matches when |
| --- | --- |
| Wi-Fi Network | You're on a Wi-Fi network with this name. |
| Ethernet Network | A wired connection's router has this MAC address, i.e. you're plugged into that particular network. |
| Ethernet Adapter | This Ethernet adapter, such as your dock's, is connected. |
| DNS Domain | This DNS domain or search domain is set, as many VPNs do. |
| Router IP, Router MAC | Your router has this address. |
| Subnet | Your IPv4 address is in this range, e.g. `192.168.1.0/24`. |
| Place | You're within a radius of a spot on the map: your current location, or coordinates you enter. |
| USB Device | A USB device of this model is connected, or only this unit (by serial number). |
| Display | A display of this model is connected, or only this unit (by serial number). |

Conditions combine with **and**, **or** and **not**, and any of them can be
timed, so a quick unplug doesn't switch profiles, in one of two ways:

- **For a while:** "dock *not* connected **for 5 min**" only counts once it
  has held for five minutes.
- **With grace:** "dock connected **with 5 min grace**" counts at once, and
  keeps counting for five minutes after the dock goes, so restarting it
  doesn't switch away. This one suits a profile whose way out is the
  fallback, which has no conditions to put a timer on.

When several profiles match, the one with the highest priority wins. A
profile with no conditions is the fallback. ContextSwitch waits for the
network to settle for a few seconds before switching, so joining a network
doesn't launch and quit apps at every step. When you go offline it keeps
the current profile for a minute, so a Wi-Fi reconnect doesn't quit and
relaunch everything, and then switches to whatever matches offline.

### Apps

- Each app in a profile is set to **Launch**, **Quit** or **Ignore**.
- Besides apps, a profile can run scripts and command-line tools.
- Launch arguments (e.g. `--server --port 6742`) can be pasted the way you'd
  type them in Terminal.
- **Start the program directly** runs the executable inside an app, as
  Terminal does. Use it for server or daemon modes that never finish
  launching as an app, which would otherwise leave the Dock icon bouncing.
- **Relaunch it if it crashes** opens an app again a moment after it
  crashes, while its profile keeps it running. Quitting it doesn't count,
  even with Force Quit: ContextSwitch tells a crash by how the app ended,
  with an error status (a Rust panic exits with 101) or a crash signal
  such as `SIGSEGV`. It gives up after 3 crashes in 5 minutes. Like the
  two options above, it's in the app's launch options (the terminal icon).
- Apps are quit the normal way, like ⌘Q, so they can ask you to save your
  work. Programs started directly, scripts and tools get `SIGTERM` instead,
  which can't ask.
- "Add App…" lists `/Applications` by default. Add more folders, such as
  `~/Applications` or `/opt/bin`, in Settings.

### Menu bar

- See the active profile, the current network, and a countdown when a
  timed switch is coming up.
- Turn **Auto-switch** on or off. Picking a profile by hand turns it off, so
  your choice sticks.
- Flip an app on or off for the moment. The override lasts until the
  profile is activated again.
- Launch ContextSwitch at login (Settings ▸ General).

### Notifications and the activity log

- A notification tells you when the profile switches on its own and what
  it's launching and quitting, and another when something goes wrong: an
  app that won't launch or crashes, a script that exits with an error,
  profiles that can't be read. Turn either kind off in Settings ▸ General.
- The activity log records every switch and why, with the network at the
  time and what happened to each app, so "why did Slack just quit?" has an
  answer. Open it from Settings ▸ General, or by clicking a notification.
  It's kept in `~/Library/Logs/ContextSwitch/ContextSwitch.log`, and also
  goes to the system log:
  `log stream --level debug --predicate 'subsystem == "com.contextswitch.app"'`.

### Import and export

- The ⋯ menu under the profile list in **Edit Profiles…** exports the
  selected profile, or all of them, to a JSON file, and imports profiles
  from one: to move them to another Mac, share one, or keep a backup.
- An export uses the same format as `profiles.json`, so you can import a
  `profiles.json` too, or one of the copies ContextSwitch keeps.
- An imported profile that matches one of yours, because it has the same
  name or was exported from it, can **Replace** yours or be added as well
  with **Keep Both**, under a new name if its name is taken.
- Profiles this version can't read are left out, and you're told why.
  Every import goes in the activity log.
- The [command line](#command-line) does both too, with `--export` and
  `--import`.

## Install

1. Download the zip from the [latest release](https://github.com/tautomer/mac-app-switcher/releases/latest).
2. Unzip it and move **ContextSwitch.app** to `/Applications`.
3. Open it. The first time, macOS refuses because the app isn't notarized.
   Go to **System Settings ▸ Privacy & Security**, scroll down to
   **Security**, click **Open Anyway** and confirm.
4. Click the ContextSwitch icon in the menu bar and choose **Edit Profiles…**.

Requires macOS 14 Sonoma or later.

## Permissions and privacy

- **Location** is needed only for **Wi-Fi Network** and **Place**
  conditions, because macOS hides Wi-Fi network names from apps without it.
  ContextSwitch asks for it when you add one of those. Places use region
  monitoring (geofencing), not continuous tracking. Every other condition
  works without any permission.
- **Notifications** are asked for the first time ContextSwitch starts.
  Without them it works the same, and the activity log still records
  everything.
- Nothing leaves your Mac. ContextSwitch makes no network requests, and
  your profiles are saved locally in
  `~/Library/Application Support/ContextSwitch/profiles.json`.
- ContextSwitch never overwrites profiles it can't read. A profile saved
  by a newer version, or mistyped by hand, is left out but kept in the file.
  If the whole file can't be read, it's left alone. Either way, the first
  time you change your profiles afterwards, a copy of the file is saved as
  `profiles-unreadable-<date>.json` first.

## Command line

The app's executable also works as a command-line tool, for scripts and
automations:

```sh
alias contextswitch=/Applications/ContextSwitch.app/Contents/MacOS/ContextSwitch

contextswitch --list                      # profiles, and which match right now
contextswitch --switch                    # switch once to the matching profile
contextswitch --profile Office            # switch once to a profile by name
contextswitch --profile Office --dry-run  # show what would launch or quit

contextswitch --export backup.json                  # all profiles (or - for standard output)
contextswitch --export office.json --profile Office # just one
contextswitch --import backup.json --dry-run        # show what would be imported
contextswitch --import backup.json --replace        # replace yours that match
contextswitch --import backup.json --keep-both      # or add them as well
```

```
$ contextswitch --list
Network: Wi-Fi “Home-WiFi” · router 192.168.1.1
  ✓ Home    priority 2   ← current match
  ✗ Office  priority 1
  · Mobile  fallback
```

If the menu bar app is running, `--switch` and `--profile` are carried out
by it, so the menu stays in sync. Unlike picking a profile from the menu,
they leave auto-switch as it is.

`--import` is carried out by the menu bar app too, which would otherwise
save over the imported profiles. If it doesn't answer, perhaps because it's
an older version, nothing is imported. When profiles in the file match
yours, nothing is imported either, unless you add `--replace` or
`--keep-both`.

Exit codes: `0` success, `1` no profile matches, `2` no profile with that
name, `3` profiles to import match yours, `64` usage error, `65` not a file
of profiles, `66` the file can't be read, `74` the file or your profiles
can't be written, `75` the menu bar app didn't answer.

## Building from source

You need Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
scripts/build.sh           # Release build -> build/ContextSwitch.app
scripts/build.sh --test    # run the unit tests first
```
