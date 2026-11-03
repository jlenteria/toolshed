# toolshed

<img src="assets/logo.png" alt="toolshed logo" width="96" height="96">

A cross-platform developer console for the machines you are sitting at: macOS,
Linux and Windows, from one Flutter codebase with no third-party dependencies.

Every tool states what it can actually do on the device it is running on. A
disabled button always says why, in the same screen, because a console that
guesses at your platform is worse than one that admits it.

## Tools

### mem_reaper — reclaim memory from hung background processes

Watches the processes you allow it to see and terminates the ones that have gone
unresponsive, with a recorded reason and a log you can read afterwards.

- **macOS** runs as a root-free LaunchAgent, ranks processes by the physical
  footprint `top` reports — the same number Activity Monitor shows, not RSS,
  which understates it badly because macOS compresses idle pages — and can be
  installed, started, stopped and reconfigured from the app. **Memory right
  now** has a force-stop button on every row: after you confirm, the app hands
  the pid to `mem_reaper.py --stop-pid`, which applies the same rules as a scan
  (protected names and paths, other users, toolshed itself), refuses if the pid
  now names a different executable, asks the process to quit, and kills it after
  3 s — or at once, if you ticked that in the dialog. The toast shows the
  script's verdict, not the app's guess.

### port_warden — what is holding a port, and how to let it go

The socket table is read on demand — `lsof -nP -iTCP -sTCP:LISTEN` and
`lsof -nP -iUDP` on macOS, `ss -ltnp` and `ss -lunp` on Linux, `netstat -ano`
plus `tasklist` on Windows — and shown as one row per process and port, with a
search field. A server bound on IPv4 and IPv6 is one row, because "what is on
3000" has one answer; two processes on the same port stay two rows, which is
the conflict worth seeing.

Freeing a port is offered where the **rules exist to do it safely**: on macOS
the row's pid and executable path go to `mem_reaper.py --stop-pid`, so the
protected names, the ancestor walk and the pid-reuse guard are the script's
decision and not a second copy in Dart. Where that stop is offered, the list
only shows rows it can act on: a socket with no visible owner, or one owned by
root, a protected name, or an executable under a protected system path, is
left out with a single line saying how many — offering a button the script
would refuse is worse than saying the socket is not ours to close. That mirror
lives in `stop_policy.dart`; the script still makes the final call. Linux and
Windows list the whole table because they do not offer the stop, so there is no
promise to keep.

### dev_sweeper — move the caches you can rebuild to the Trash

**Reclaim space** measures the directories whose loss costs only a rebuild or a
re-download — Xcode's DerivedData and device support, CoreSimulator's caches,
CocoaPods and Homebrew, the Gradle, npm, Yarn, pnpm and pub stores, the Go build
cache, Cargo's registry cache — and finds every `node_modules` under the
conventional checkout folders. Rows are grouped by the tool that owns them,
largest first, with a search field and a running total.

Every row is a whole directory, because moving one is a single reversible step
and a half-deleted cache is worse than a full one. **Moving is the only action,
and it is a move, not a delete.** macOS asks `NSFileManager` to trash the item,
so Finder's Put Back knows where it came from; Linux writes the freedesktop
Trash `files/` and `info/` pair directly, with the `.trashinfo` that makes a
restore possible; Windows uses the Recycle Bin. The confirmation names the count
and the size before anything moves, and says plainly that the space comes back
when the Trash is emptied.

The refusal rules live below the screen, not in it. A path is moved only if the
scan produced it — a known cache directory or a `node_modules` — and only if it
is still a real directory that resolves strictly inside your home and is not a
symbolic link. A stale or hand-edited target gets a reason instead of a move.
Project sources, Xcode archives, simulator devices and SDKs are not on the
allowlist and are never measured or offered.

### docker — the containers and images you already have

**Containers & images** lists what the `docker` CLI reports on demand — every
container running or stopped, every image, and `docker system df` — and offers
the lifecycle actions the engine will honour: start, stop, restart and remove a
container, and prune **dangling images only**. Every action confirms first;
remove says plainly that the container's writable layer goes with it, and prune
promises nothing about tagged images because `docker image prune` removes none.
This is a remote control, not an agent: the console sends `docker` commands and
shows the CLI's own verdict in the toast, and the engine — never a second copy of
the rules in Dart — decides whether each one succeeds.

**Engine-agnostic on purpose.** It finds the standard `docker` binary on `PATH`
and — because an app launched from the Dock does not inherit a login shell's
`PATH`, and would otherwise miss Homebrew and `/usr/local/bin` — in the usual
install locations too, then lets that CLI resolve the machine's own current
`docker context`. So it is not welded to any one runtime: uninstall OrbStack and
install Docker Desktop, or run a plain `dockerd`, Colima or podman, and the next
scan finds whichever CLI is now there and talks to whatever endpoint is now
active. A dangling symlink an uninstalled engine left behind fails the existence
check and is skipped rather than winning over a working binary, and the child
inherits this process's environment, so a `DOCKER_HOST` or a switched context is
honoured without the app knowing the difference.

**What it says when there is no Docker.** With no `docker` CLI *and* no engine
manager found the tool is still listed, but as *helper not found* with the reason
and no action buttons — a page of controls that could only fail is worse than one
line telling you to install an engine. And if the CLI is present but its daemon
does not answer, the status and any failed read carry docker's own message
("Cannot connect to the Docker daemon…") instead of pretending you have zero
containers, because "nothing to show" and "I could not reach the engine you
pointed me at" are different truths.

**Starting the engine itself.** A switched-off daemon is the one state where a
read can do nothing but say so, so when a manager for the engine is installed —
Colima, OrbStack's `orbctl`, or Docker Desktop — the console shows an **Engine**
card that runs that manager's own command. Start brings the engine up
(`colima start`, or opening Docker Desktop) so you are not forced into a terminal
after stopping or uninstalling one runtime and switching to another; Stop takes it
down, behind a confirm dialog that says plainly that the whole engine and every
running container go with it. The button is named for whichever manager was
actually found, so it never advertises a start path this machine does not have,
and a plain `dockerd` with no manager correctly offers nothing.

**Opening a container's port.** Each container row lists its ports in full and
separates what can be browsed from what cannot. A published mapping
(`0.0.0.0:24400->80/tcp`) is drawn as a clickable link that opens
`http://localhost:24400` in the default browser through the OS's own handler
(`open` / `xdg-open` / `cmd start`) — no URL is ever handed to a shell, and the
address is built only from a digits-only host port. A dual-stack bind prints two
lines for one port, so the link is collapsed to one. A port that is exposed but
never published (`8080/tcp`) is shown greyed and inert, because nothing on the
host can reach it.

### fan_ctl — temperature-triggered fan control (macOS)

Set a temperature; below it the fan stays in Apple's own control, at or above it
the daemon takes over and holds the speed the policy asks for.

```
below target ....... Apple's automatic curve, registers untouched
at target .......... hold at N rpm
each degree over ... + M rpm, clamped to the fan's own floor and ceiling
above guard ........ handed back to Apple, whose curve is steeper than any
                     setting here
```

Hysteresis is not optional: a machine sitting exactly on the threshold would
otherwise flip control twice a second.

**Why there is a daemon.** Reading the System Management Controller needs no
privilege, and `toolshed-fand telemetry` proves it — fans, their ranges, and
every temperature sensor on the machine, as your ordinary user. Writing a fan
register does not: the kernel returns `kIOReturnNotPrivileged` (`0xe00002c1`) for
any uid but 0, which this app measures rather than assumes. So control goes
through a root `LaunchDaemon` behind a Unix socket, installed with one
administrator prompt, and the app keeps working after you close it rather than
holding a password prompt open.

- The socket is world-reachable by design — a GUI user has to be able to reach
  it — and every connection is gated on the peer's uid: root, or the owner of
  `/dev/console`. Nothing else gets an answer.
- A policy has a **lease**. It survives only while the app renews it, so a crash
  or a quit cannot leave a fan forced; a lease of zero means hold until released,
  and is a choice in the UI rather than a default.
- A daemon that starts and finds a fan already forced hands it back to Apple
  before it serves anything, including after a crash respawn.
- `SIGTERM` releases the fan before the process exits, and `Stop` is a
  `bootout` plus a `disable`, so the button survives a reboot.
- The installer refuses to build a LaunchDaemon out of a helper that does not
  pass its own `selfcheck`, and verifies root ownership before `launchd` is
  asked to run the file.

The decision law lives in `macos/fanctl/main.swift` and nowhere in Dart. The UI
shows the rpm the daemon says it applied, never a number it predicted, because
only one of the two is allowed to be wrong.

**Take control** is the only button that writes hardware. `Save only` writes the
policy file and sends nothing, and the renewal timer re-applies the policy the
last `Take control` named rather than one it captured — so a save cannot be
undone seconds later by a superseded hold. Every control action answers with a
toast carrying the daemon's own verdict, each button carries the sentence that
explains what it is for, and a disabled one says why beside itself, because a
silent no-op on a fan console is indistinguishable from a broken one.

### app_lock — close the apps you named, until you type a passphrase (macOS)

Pick the apps, set a passphrase, install the watcher. A locked app that launches
is asked to quit and stays closed until the passphrase is typed correctly, which
opens it again for as long as you are using it: the unlock window is an
**inactivity timer**, so only minutes spent in the background count before the
watcher closes it again and asks for the passphrase. A stopwatch from the
passphrase would close an app somebody is in the middle of using. The list is
**desktop apps only** — a `.app` that does not declare itself background-only,
or one running with the `.regular` activation policy: ClickUp, Safari, Terminal,
System Settings, and not the agents and menu-bar extras that have no window to
close. The guard list is not on the list either: Finder, the Dock, the menu bar
and toolshed are apps the agent will never close, so offering them would be a
checkbox it refuses to honour. A locked app is always listed, even if it falls
into either group, so the lock can still be removed.

**What it is, exactly.** A root-free `LaunchAgent`: its plist lives in
`~/Library/LaunchAgents`, its binary in `~/Library/Application Support/toolshed`,
and it runs as you. It subscribes to the `NSWorkspace` launch and activate
notifications rather than polling — the latency of a lock is the whole quality of
a lock — with a 5 s reconcile so an app that was already open when the lock was
armed, and an idle window that has run out, are both caught. It **reacts to a launch and
asks the app to quit**; it cannot stop the system from starting one. The console
says that in its own words, and names the one thing missing between what is
installed and what is actually enforcing — no passphrase, an empty list, switched
off, or a watcher that is not running — rather than letting a padlock icon be the
whole message. You may see the window for a frame, and an app that ignores the
quit is `forceTerminate`d after a few seconds. The prompt wears the app's own
icon, and a wrong passphrase — or a dismissed dialog — insists on the close, so
"no" cannot look like "yes" because the window was still behind the dialog.

**Where the passphrase lives.** `PBKDF2-HMAC-SHA256`, 120 000 rounds, a random
salt per store, 32 derived bytes, in `app_lock_secret.json` at mode `0600`. The
comparison happens inside the Swift helper, so the plaintext never crosses back
into Dart and is never stored: the console can check a phrase, and can tell you
that a phrase did not match, but cannot read one. The phrase travels to the helper
on **stdin, never argv** — every process on the machine can read another's argv
through `ps`, which is not a place for a secret with a window open on it.

**What it refuses.** It will not close the six things whose death takes the
session with them — Finder, the Dock, Control Center, SystemUIServer,
`loginwindow`, the wallpaper agent — and it will not close toolshed, which hosts
the button that unlocks everything else. That guard list lives in the helper
*and* in the config: the app list does not offer those entries at all, and if one
is put in the config by hand the UI still renders the reason where a checkbox
would have been. There is no admin prompt, no entitlement and no kernel write
anywhere in this tool.

**The bypass, said plainly.** Anyone who can `launchctl bootout` the agent, or
delete the plist it came from, can open a locked app: the guard runs as you, and
so does anyone with your terminal. A passphrase you cannot remember cannot be
recovered, because the only reset that works is one that first reads the file it
protects. `uninstall` unloads the agent and *moves* its plist to a timestamped
backup instead of deleting it, and leaves the store — lock list, secret, state —
alone, so the wrong button costs a reinstall rather than the work of picking the
apps again. Switching the lock *off* edits one boolean.

So what this buys is the cost of an unwanted launch, on a machine you left logged
in: a locked app quits itself and will not stay open for someone who does not know
the phrase. It is not encryption, and it is not a parental control aimed at
someone comfortable with a terminal.

The console is built from the same parts as the fan one and inherits the rules:
every button is gated on a measurement (the helper present on disk, the agent
installed, `launchctl print` saying `running`), every action answers with a toast
carrying the helper's own verdict, each button explains itself behind an info
badge, and a disabled one says why beside itself.

## The console

The front page summarises the fleet — tools, running, stopped, attention — and
draws one card per tool, stretched to the same height within its row, with a
live status pill and the agent's own blurb. Every tool then shares one shell: a
page intro, section cards, and an action bar whose buttons each carry an info
badge explaining what they do and a reason line when they are disabled.

The app bar's overflow menu opens two pages that belong to the app rather than
to a tool:

- **About** — the version, the platform, and the promises this console keeps:
  no third-party packages, no telemetry, no account. Reads are `dart:io` or a
  platform channel, and helpers run as the user who started them.
- **Support** — an optional tip, paid through the user's own bank app by
  scanning a QR. It unlocks nothing, funds no feature, and is never required.

## Building

```sh
make setup        # flutter pub get
make fanctl       # compile the macOS fan helper and run its policy selfcheck
make lockd        # compile the macOS lock helper and run its selfcheck
make run          # flutter run
make run-macos    # flutter run -d macos (also run-windows, run-linux, run-all)
make check        # analyze + format check + tests (builds the lock helper first)
make build        # flutter build macos --release, helpers embedded
make install-macos  build, then replace and relaunch /Applications/toolshed.app
make install-linux  install the Linux release build with a menu entry and icon
make uninstall-linux  remove what install-linux added
make logo         # re-render the app icons from assets/logo.svg
```

**The app carries its helpers.** An `Embed Helpers` build phase
(`macos/Helpers/embed_helpers.sh`) compiles both Swift files into
`Contents/Resources` as universal binaries, per architecture in `$ARCHS`, and runs
each one's `selfcheck` for the slice this machine can execute — so a bundle cannot
ship a helper that fails its own table. It runs before Xcode signs, which is the
only order in which an embedded binary stays inside the seal. The consequence is
the point: an installed `toolshed.app` needs nothing from `~/Project/toolshed`.

Resolution has two orders, and they are deliberately not the same.

- **Reading** (`Paths.fanHelperPath`, `Paths.lockHelperPath`) prefers what is
  installed — `/usr/local/bin/toolshed-fand`, or the agent's copy in Application
  Support — because the console must interpret a reply with the protocol of the
  process that produced it. The bundle copy is next.
- **Installing** (`Paths.fanInstallSourcePath`, `Paths.lockInstallSourcePath`)
  prefers the bundle, because an update has to reach the thing it updates;
  preferring the installed copy would reinstall the binary the last install left
  behind, forever.

The build tree is last in both lists, and only a developer's convenience.

```sh
swiftc -O macos/fanctl/main.swift -o build/fanctl/toolshed-fand \
  -framework Foundation -framework IOKit
swiftc -O macos/lockd/main.swift -o build/lockd/toolshed-lockd \
  -framework AppKit -framework CryptoKit -framework Foundation
```

`make lockd` and `make fanctl` still build those standalone copies for the
protocol tests and for running from a checkout. `make test` depends on `make
lockd`, so the lock protocol suite always runs the binary that matches the source
in the tree; without it, those tests skip.

## Layout

```
lib/
  app.dart                  MaterialApp, wired to the theme and the front page
  app_info.dart             the version the About page shows
  main.dart                 the zone that keeps a slow read off the first frame
  models/                   shared contracts only: status, config, descriptor
  platform/                 paths, process runner, log tailing
  tools/
    registry.dart           one entry per tool: descriptor, backend, status
    tool_backend.dart       the interfaces a tool may implement, per capability
    unsupported_backend.dart  an OS that cannot run a tool, said out loud
    mem_reaper/             everything about that one tool:
      managed_app.dart        a ranked process
      mem_reaper_config.dart  its settings
      macos_backend.dart      the agent, `top`, launchctl, the plist
      launchctl_parse.dart    the two grammars of `launchctl print`
      plist_args.dart         the config sheet's plist round trip
      config_sheet.dart       its settings sheet
      stop_outcome.dart       what `--stop-pid` says it did
      ranking_screen.dart     its UI
    port_warden/              ditto, for the ports:
      port_listener.dart      one row per process and port, and its labels
      listener_parsers.dart   the lsof, ss, netstat and tasklist grammars
      port_backend.dart       the three desktop scanners; macOS stop via mem_reaper
      stop_policy.dart        which owners mem_reaper refuses, mirrored for the list
      port_screen.dart        its console
    dev_sweeper/             ditto, for the caches:
      cache_locations.dart    the allowlist, per platform
      sweep_target.dart       one directory, its size and what a move reports
      sweep_parsers.dart      the du, PowerShell and find grammars
      trash_linux.dart        the freedesktop Trash, written directly
      dev_sweeper_backend.dart  the scan, the platform Trash, the refusal rules
      sweep_screen.dart       its console
    docker/                 ditto, for the containers:
      docker_models.dart      a container, an image, a disk line, the action
      docker_engine.dart      which manager (Colima/OrbStack/Desktop) can start it
      docker_parsers.dart     the `--format json` grammars of ps, images, df
      docker_backend.dart     finds the docker CLI, sends it commands, reports back
      docker_screen.dart      the console
    fan_ctl/                ditto, for the fan:
      fan_policy.dart         the threshold, the ramp, the lease
      fan_telemetry.dart      fans, sensors and the group maxima
      fan_daemon.dart         what the root process says it is doing
      daemon_client.dart      one newline-JSON request per connection
      daemon_install.dart     the privileged install, gated on `selfcheck`
      fan_backend.dart        the tool: reads unprivileged, writes via root
      fan_screen.dart         the console
    app_lock/                 ditto, for the lock:
      app_lock_config.dart    the lock list, the idle window, the guard list
      lock_agent.dart         the helper client, and the agent's life cycle
      app_lock_backend.dart   the tool: a config file and a passphrase handoff
      lock_screen.dart        the console
  ui/                       the shell every tool shares
    theme.dart              colours, type, radii, the mono face, ContentColumn
    screens/                the front page, a tool's detail page, the log view,
                            and the About and Support pages
    widgets/                status pills and badges, the capability notice,
                            and the console parts (action bar, field groups)
macos/fanctl/main.swift     the SMC, the control law, and the root daemon
macos/lockd/main.swift      the hash, the guard list, and the watcher
macos/Helpers/embed_helpers.sh  the build phase that puts both in the bundle
linux/packaging/com.bling.toolshed.desktop  the menu entry install-linux writes
linux/runner/resources/app_icon.png         the 256px icon install-linux copies
docs/banks/bpi.jpg          the support QR, drawn by the Support page
test/
  fan_ctl/                  policy, protocol, installer, backend, live helper
  app_lock/                 config, protocol, agent, backend, live helper, console
  mem_reaper/               launchctl, plist args, plist round trip, live scan,
                            force stop (script and console)
  port_warden/              parsers, three scanners, live lsof, console
  dev_sweeper/              parsers, locations, Trash, scanners, console
  docker/                   parsers, backend, engine-manager discovery, and the
                            console over a fake docker CLI and a fake Colima
  platform/                 where an installed app looks for its helpers
  fixtures/                 canned `launchctl` output
```

A tool's models, backend and screen live in its own folder under `tools/`;
`models/` and `ui/` hold only what two or more tools share. A new tool's icon
goes in `toolIcon` in `ui/widgets/status_style.dart`. Adding a tool means
adding a folder and one line in `registry.dart`.

`ToolBackend` is deliberately small. A tool that can rank memory implements
`MemoryRanking`, one that can stop a single process implements `ProcessStopper`
(`ProcessReaper` adds the whole memory scan), one that can list listening
sockets implements `PortInspector`, one that can find and move cache directories
implements `CacheSweeper`, one that can hold a fan implements `FanControl`, one
that can keep apps shut implements `AppLockGuard`, one that drives a Docker
engine implements `DockerManager`, and the UI asks the interface before it draws
a button. `Capabilities` is the answer it draws from.

## Tests

`flutter test`. The fan tests are worth naming, because they are the ones that
catch the failure modes this design actually has:

- `fan_ctl/protocol_test` reads `macos/fanctl/main.swift` and the Dart models and
  compares their shapes, so renaming a JSON key on either side fails a test
  rather than silently falling back to a default.
- `fan_ctl/daemon_install_test` runs the installer's script through a real
  `osascript` and a real `plutil` in a scratch directory, unprivileged, to prove
  the two escaping layers agree and the LaunchDaemon is a plist launchd accepts.
  Nothing in it touches `/Library` or asks for a password.
- `fan_ctl/helper_test` runs the built helper's `selfcheck` and `telemetry`
  against the machine it is on. It never runs `selftest`, which writes a
  register.
- `fan_ctl/backend_test` replaces the daemon with the list of requests it was
  sent, which is the only honest seam: it pins that `Save only` sends nothing,
  that a second `Take control` renews with the new numbers instead of racing the
  old timer, and that a release stops renewing.
- `fan_ctl/console_test` drives the real widget over that same fake, so the
  buttons are tested against the capabilities they are drawn from: the info
  badges open one note at a time, the bar does not overflow a narrow window, and
  `Save only` still sends nothing when a finger, rather than a test, presses it.

The lock tests are the same shape, because the lock has the same failure modes:

- `app_lock/protocol_test` runs the built `toolshed-lockd` against a scratch
  `--store` and asserts what is on the disk afterwards: the secret is a salt and
  a derived hash and never the phrase, the file is mode `0600`, a correct phrase
  verifies and a wrong one grants nothing, an allowance is granted for exactly the
  minutes asked for and can be ended early, and an app that is not running is
  answered as *not running* rather than as a failure. It skips when the helper has
  not been built, so `make test` builds it first. It also pins what a watcher is:
  the pid a store recorded, checked against the process table and, for stores that
  are not the default one, nothing else — so a scratch store is never reported as
  enforced by the agent running for the user, and a pid that died or was reused is
  not reported as a lock that is holding.
- `app_lock/agent_test` has the machine's own `plutil` lint and decode the plist
  the installer writes — a plist launchd will not read is not a lock — and pins
  the life cycle: install refuses a helper that is missing, unsound or already
  installed, `start` does not claim success until `launchctl print` says
  `state = running`, a `bootout` that reports the service was never loaded is
  read as *already stopped*, and a real failure is said out loud.
- `app_lock/backend_test` replaces the helper with the argv it was handed and
  the stdin it was fed, which is the seam that matters for a secret: one test
  asserts that the phrase appears in neither of the argv logs, and another that a
  phrase too short to be a lock is refused before a process is started at all.
- `app_lock/console_test` drives the real console over that fake and checks that
  an empty state admits it is not enforcing, that ticking an app and saving
  touches the file and closes nothing, that *Close all* names how many it asked,
  that a guarded app is offered a reason rather than a checkbox, and that the
  passphrase is never rendered back.

The sweeper's tests are about what must not happen:

- `dev_sweeper/parsers_test` pins the two grammars the scanners actually print —
  `du` writes `size<TAB>path`, PowerShell writes `path<TAB>bytes`, and they are
  not the same order — plus the formatter that decides which row looks big.
- `dev_sweeper/backend_test` builds a throwaway home and answers `du` and `find`
  from a fake runner: the largest cache comes first, a discovered module is
  labelled by its path under home, and a failed or partial measurement becomes a
  note and an unknown size rather than a zero. Its move tests pin the refusals
  the screen cannot be trusted with — a path the scan did not produce, a
  symlinked `node_modules`, a file where a cache used to be, a path that resolves
  outside home, and home itself. Linux is exercised end to end into a scratch
  freedesktop Trash.
- `dev_sweeper/trash_linux_test` checks the spec's two directories, the
  `.trashinfo` that makes restore possible, collision names, and that a failed
  rename leaves no record claiming a move that did not happen.
- `dev_sweeper/console_test` drives the real screen: nothing is selected until
  ticked, *Select shown* respects a search, the dialog names the count and size,
  a confirmed move sends exactly the ticked targets and rescans, and a failed
  move leaves the rows with the path beside the reason.
- `platform/paths_test` builds a throwaway `.app` in a temp directory and asks the
  resolution questions of it: the bundle's `Resources` is found and a non-bundle
  path is not, a missing helper is `null` rather than a path that cannot run, and
  the read order puts what is enforcing first while the install order puts the
  app's own copy first. That last pair is the whole reason an installed toolshed
  can update its own agent.
