# Linux AppImage: adding App Studio to the app menu

Status: **A, B and C built, 2026-11-28.** Follows PR 4 (`make appimage`,
`tool/linux/build_appimage.sh`) on the step branch `linux/4b-appimage`, which
merges into `linux/port` like the other steps.

## The plan in short

The AppImage works well **once a tool has added it to the app menu**:
[Gear Lever](https://github.com/mijorus/gearlever) (an app for managing
AppImages), [AppImageLauncher](https://github.com/TheAssassin/AppImageLauncher)
(which steps in when an AppImage it has not integrated yet starts, and asks
"Integrate and run" or "Run once") or
[appimaged](https://github.com/probonopd/go-appimage) (a daemon that adds
every AppImage it finds in the folders it watches). Without one of them, App
Studio never appears in the app menu and the dock shows a generic icon,
because no desktop entry names it. Part A closes that gap from inside App
Studio.

| Part | What | Where | State |
|---|---|---|---|
| A | **Add to Applications**: on start, until it is in the app menu, App Studio offers to add itself; **Remove from Applications** undoes it | App Studio (Dart), Linux only | done |
| B | **Updates from inside the app**: Help → Check for Updates, and a daily check, replace the AppImage in place | App Studio (Dart), `tool/linux/`; feed and key are Serverpod's | done |
| C | **A clear message on a system that cannot load App Studio**, instead of nothing happening | `AppRun` in the AppImage | done |
| D | **Download page text** for Serverpod's website | text in this spec | written; needs A |
| E | Uninstall removes what A added | App Studio (Dart) | with PR 5 |

**B is built and tested against a local feed.** Where builds are hosted,
the feed's URL and the signing key are Serverpod's to decide: until
`linux/release.json` names a feed and a key, a release build reports updates
as unavailable, as a build without them does on Windows. The AppImage still
carries no `.zsync` update information for Gear Lever; that is a separate
choice for the same people (`specs/linux_port.md` 4.5).

This spec covers the AppImage. Whether the `.deb` and `.rpm` of
`specs/linux_port.md` (4.5) still follow is open with Serverpod.

### Decisions

| # | Decision |
|---|---|
| A1 | **App Studio asks before it writes anything outside its own folders**, at most once per start. It does not offer to add itself when it is in the app menu already, whoever put it there; which tools are installed does not matter. The one question it asks then is about a second copy of its own (see Another copy). |
| A2 | **An added AppImage lives at one fixed path, `~/AppImages/AppStudio-x86_64.AppImage`.** No version in the name, so replacing the file keeps the menu entry valid. `~/AppImages` is Gear Lever's default folder, and by default neither AppImageLauncher nor appimaged watches it; both add whatever appears in `~/Applications`, so a file moved there would show up in the menu twice. (Either can be told to watch more folders; appimaged also watches every folder on `PATH`.) |
| A3 | **The desktop entry App Studio writes carries a marker**, `X-AppStudio-AddedBy=appstudio`, so Remove from Applications (and PR 5's uninstall) removes only that entry. An entry another tool wrote stays. |
| C1 | **No older build base.** The AppImage needs glibc 2.38 (Ubuntu 24.04 and later); part C makes that readable rather than lower. |

---

## A. Add to Applications

### Four states

Everything in part A follows from one of four states, read from the disk
whenever a question or the Help menu needs it:

| State | Meaning |
|---|---|
| `unavailable` | Not running as an AppImage (condition 1 below). Nothing to offer. |
| `managedByOther` | In the app menu through another tool, or a package. Theirs. |
| `addedByAppStudio` | App Studio's own entry (A3), and the file its `TryExec` names exists. |
| `notAdded` | None of the above: App Studio offers to add itself. |

1. **Running as an AppImage** means: the AppImage runtime set `$APPIMAGE`
   (the file's path) and `$APPDIR` (where the image is mounted), **and** App
   Studio's executable is inside `$APPDIR`. The variables are inherited by
   child processes, so a development build started from a terminal inside
   another AppImage (an editor, say) sees that one's; only the executable
   tells them apart. A *portable* AppImage, one with a `<file>.AppImage.home`
   folder beside it, counts as `unavailable` too: the runtime points `HOME`
   there, so an entry written under it never reaches the desktop.
2. **In the app menu** means a desktop entry, in `$XDG_DATA_HOME/applications`
   (default `~/.local/share/applications`) or an `applications` folder under
   `$XDG_DATA_DIRS`, sub-folders included (one that cannot be read is
   skipped), that is called
   `dev.serverpod.appstudio.desktop` or names
   `StartupWMClass=dev.serverpod.appstudio`. Gear Lever, AppImageLauncher and
   appimaged name their entries after the app or a hash, but keep the
   AppImage's own `StartupWMClass`, so one check finds all of them, and a
   copy they added is found even when started from a terminal.
   - An entry whose `TryExec` names a file that no longer exists does not
     count: it is left over from an AppImage the user deleted. This covers
     App Studio's own entry too, which the next Add then writes over.
     (appimaged's `TryExec` names appimaged itself, so its entries always
     count.)
   - An installed tool that did not add App Studio does not count. With
     AppImageLauncher, a user who chose "Run once" in its question is then
     asked by App Studio as well.

### When App Studio asks

Over the start page: on a normal start once it shows, and on a first run as
soon as setup ends, in the same run, so the question never lands among
setup's own dialogs. The checks read the disk; if a project opens before they
are done, no question comes that run. A project opened while the question is
up closes it (the routes over the start page are cleared, as for every
project open).

In state `notAdded` it asks to add itself, unless the user said "Don't ask
again" (preference `linux.add_to_applications_declined`). In state
`addedByAppStudio` it may ask about another copy (below). In the other two
states it asks nothing.

### The question

```text
Add App Studio to your applications?

App Studio will appear in your app menu, and the file moves from
~/Downloads to ~/AppImages.

[ ] Don't ask again                      [Not now]  [Add]
```

The sentence about the file names the folder it is in now. It is left out
when the file is in `~/AppImages` already (where Add at most renames it to the
fixed name), and when an earlier Add in the same run already moved it. When
another file is at `~/AppImages/AppStudio-x86_64.AppImage` already (a copy
left there by Remove, or whose entry was deleted by hand), the question adds
"It replaces the App Studio already at ~/AppImages/AppStudio-x86_64.AppImage.",
since that copy may be newer.

When App Studio may not take the file out of its folder (a root-owned
`/opt`, a read-only file system, or a shared sticky folder such as `/tmp`
holding someone else's file), Add copies it and the original stays, so the
sentence reads "App Studio will appear in your app menu, with a copy of the
file in ~/AppImages. The one in /opt/as stays, since App Studio cannot move
it from there." This is read from the folder's permissions (`test -w`, `-x`,
and for a sticky folder `-O`, or root), without writing anything there
before the user answers. An immutable file (`chattr +i`) is not detected: Add still
copies it, and only the wording is off.

**Not now** asks again on the next start; with the box ticked it never asks
again on start.

### The Help menu

Exactly one of two items shows in Help on Linux, or neither:

- **Add to Applications...** in state `notAdded`, so "Don't ask again" is
  never a dead end. It opens the same dialog with **Cancel** instead of
  Not now, and no checkbox.
- **Remove from Applications...** in state `addedByAppStudio`. It confirms
  first:

  ```text
  Remove App Studio from your applications?

  App Studio leaves your app menu. The file stays at
  ~/AppImages/AppStudio-x86_64.AppImage, and App Studio will not ask to
  add itself again.

  [Cancel]  [Remove]
  ```

Neither shows in states `unavailable` and `managedByOther`.

### What Add does

The dialog stays open while it runs and shows any error in it.

1. **Moves the AppImage to `~/AppImages/AppStudio-x86_64.AppImage`** (A2),
   creating the folder if needed. A rename where it can be. Where the rename
   fails (another file system, or a folder the file cannot be taken out of,
   such as a root-owned `/opt`), a copy to a temporary name in `~/AppImages`,
   made executable, then renamed onto the target, and the original deleted.
   A file already at the target is replaced only by a rename, so it is never
   half-written. If the original cannot be deleted, the copy is added anyway
   and the original stays.

   Moving a running AppImage is safe. The runtime's squashfuse opens the file
   once, when it mounts the image, and reads every block through that
   descriptor. Checked with the 0.4.1 AppImage: after the file was copied to
   another file system and the original deleted, all of `libcef.so` read back
   from the mount and the loader still resolved the executable's libraries.
2. **Copies the icons** from `$APPDIR/usr/share/icons/hicolor/` into
   `$XDG_DATA_HOME/icons/hicolor/`, under the same names.
3. **Writes `$XDG_DATA_HOME/applications/dev.serverpod.appstudio.desktop`**
   from the AppImage's own entry: `Exec` set to the new path, quoted as the
   Desktop Entry spec requires for an argument; `TryExec` set to the same
   path as a plain, unquoted string; the marker (A3); and the running version
   as `X-AppStudio-Version` and `X-AppStudio-Build`. Every other key and group
   is kept. It is written to a temporary name and renamed, so a launcher never
   reads half an entry. The file name is the application id, so on Wayland
   the dock can match the window to it by its app id as well as by
   `StartupWMClass`.
4. **Tells the desktop the icons changed**, as `xdg-icon-resource` does.
   GTK rescans the theme, and judges an icon cache stale, only when the
   `hicolor` folder's own modification time moves, not its size folders'.
   Copied into folders an earlier Add left behind (Remove keeps them), the
   icon stayed generic until the next login. So Add first moves the
   folder's time, by adding a file and taking it away again (xdg's
   `.xdg-icon-resource-dummy`), then runs `gtk-update-icon-cache -f -t` on
   the folder when `$XDG_DATA_HOME/icons/hicolor/icon-theme.cache` exists
   (best effort; should it fail, the old cache is already stale and icons
   are looked up on disk). Remove does the same, and creates no folder
   where there was none.
5. **Shows a toast**: "Added to your applications".

`update-desktop-database` is not run: it only writes `mimeinfo.cache` from
`MimeType=` keys, and the entry has none. GNOME (through GLib's file monitor
on each `applications` folder) and KDE (through kded's directory watch) pick a
new entry up on their own, going by their source; to confirm in the VM.

**If a step fails**, the icons and entry that this Add created are removed;
ones that were there before (a Replace, below) are kept, so the entry already
in the menu still shows its icon. The dialog shows the step and the reason. A
moved file is not moved back, since App Studio runs on from its new place, so
the error then also says that the AppImage is now at
`~/AppImages/AppStudio-x86_64.AppImage`. Pressing Add again (or Help → Add
later) finds the file there, though `$APPIMAGE` still names its old place,
and carries on from step 2; if the original could not be deleted, it is
copied again.

### What Remove does

Deletes the entry App Studio wrote and the `dev.serverpod.appstudio.png`
icons under `$XDG_DATA_HOME/icons/hicolor/`, only when the entry carries the
marker, and rebuilds the icon cache as Add does. The AppImage stays where it
is. Removing sets "Don't ask again" first (the user just said no), so a
removal that fails halfway does not bring the question back either. A toast
says "Removed from your applications", or, on failure, "Could not remove App
Studio from your applications" with the reason. Finding no entry of App
Studio's to remove is a failure too: another tool may have rewritten it since
the Help menu last looked.

### Another copy than the one in the app menu

Someone who downloads App Studio again and starts the new file is in state
`addedByAppStudio`, so the question above never comes. When the running file
is not the one App Studio's entry names, App Studio compares the two by build
number, which orders releases:

- **This copy is newer:**

  ```text
  Replace App Studio 0.4.1 with this version?

  This copy is App Studio 0.4.2, newer than the 0.4.1 in your app menu.
  Replace moves it from ~/Downloads to ~/AppImages, in place of the older
  one.

  [Not now]  [Replace]
  ```

  When the copy is in `~/AppImages` already, the second sentence reads
  "Replace puts it in place of the older one." Where the file can only be
  copied out of its folder (as for the question above), it reads "Replace
  puts a copy of it from /opt/as into ~/AppImages, in place of the older
  one." Replace runs Add, so
  everything above applies: the file is renamed over the old one, and the
  entry is rewritten with the new version. Once the move has happened the
  older copy is gone; if a later step fails, the existing entry and icons
  stay and point at the new file. The entry then no longer records a
  version: the one it named is gone, and compared with the next download it
  could offer to replace a newer copy with an older one. Until an Add writes
  the entry again, no copy is compared with it. A toast says "App Studio
  0.4.2 is in your applications".
- **This copy is older:**

  ```text
  A newer App Studio is in your app menu

  This copy is App Studio 0.4.0. Your app menu has 0.4.1.

  [Keep using this one]  [Open 0.4.1]
  ```

  Open quits this copy, through the same teardown as File → Quit, and starts
  the newer one once this process has ended: the two share the preview's
  browser profile, which only one can hold at a time. (A small detached `sh`
  waits for the process, for at most 30 s.) If the added file is gone, Open
  says so in a toast and nothing quits. Replacing the newer copy with the
  older one is not offered: a downgrade is too easy to click by accident. It
  stays possible in two deliberate steps, Remove and then Add.
- **The same build:** nothing is said. It is a second download.

The versions shown are the marketing versions, with the build added when
both copies share one. The running copy's comes from the `version.json`
Flutter writes into the bundle. The added copy's is not mounted, so Add
records it in the entry as `X-AppStudio-Version` and `X-AppStudio-Build`.
Without them nothing is said. A copy Gear Lever or another tool added is
theirs: Gear Lever has its own update. There is no "Don't ask again" here;
the question is about one file, and comes up only when someone starts a
second copy by hand.

Nothing stops two copies running at once (the GTK application is
`G_APPLICATION_NON_UNIQUE`, as before this spec). Replace while the added copy
also runs swaps its file underneath it, which the running copy does not
notice (its image stays mounted); Open while it runs starts a second
instance of it. Both are left as they are.

### Living alongside the other tools

- **AppImageLauncher** asks when an AppImage it has not integrated yet
  starts, before App Studio runs. After "Integrate and run" App Studio finds
  its entry and stays quiet; after "Run once" App Studio asks too. By default
  its daemon does not watch `~/AppImages`, so App Studio's Add gets no second
  entry from it.
- **appimaged** adds every AppImage in the Downloads folder, the desktop,
  `~/Applications`, the folders on `PATH` and more, but not `~/AppImages`. A
  downloaded App Studio is already in the menu by the time it starts, and the
  entry check finds it.
- **Gear Lever** lists an entry in `~/.local/share/applications` as one of
  its own when its `TryExec` names a file in Gear Lever's folder (default
  `~/AppImages`), or anywhere while its "manage files outside the default
  folder" setting is on (the default). So the entry App Studio writes
  usually shows up there too. Removing it in Gear Lever moves the AppImage to
  the trash and deletes the entry; the icons App Studio copied stay behind.
  Updating it through Gear Lever rewrites the entry from the AppImage's own,
  which drops App Studio's marker: App Studio then reads it as
  `managedByOther`, which is what it has become.

### Where it lives

- `lib/platform/linux/desktop_integration.dart`: the states, Add, Remove and
  the comparison of copies, with the environment and the executable injected
  so the tests point `HOME` at a temporary folder and run on every host; and
  `DesktopIntegrationController`, the state the menu strip listens to.
- `lib/platform/linux/app_version.dart`: a version and build, and how two
  copies compare; free of `dart:io`.
- `lib/platform/linux/desktop_integration_status.dart`: the four states,
  free of `dart:io` so the menu strip can read them.
- `lib/ui/add_to_applications_dialog.dart`: the dialogs, free of `dart:io`
  so Widgetbook shows them.
- `lib/ui/desktop_integration_commands.dart`: what the question and the Help
  items run, including the preference, which the caller writes as the
  project notices do.

---

## B. Updates from inside the app

macOS updates through Sparkle and Windows through WinSparkle; Linux has no
such library, so App Studio does the same job in Dart, with the same feed
format and the same rules.

| # | Decision |
|---|---|
| B1 | **The feed is a Sparkle appcast**, like the macOS and Windows ones: one `<item>` per release, its `<enclosure>` carrying `url`, `length`, `sparkle:version` (the build number, which orders releases), `sparkle:shortVersionString`, `sparkle:os="linux-x86_64"` and `sparkle:edSignature`. |
| B2 | **Every download is checked against an Ed25519 signature** over the whole file, as Sparkle and WinSparkle check theirs. The public key is compiled in; the private one never leaves Serverpod. A key pair from `openssl genpkey -algorithm ed25519` works, and so does signing with `openssl pkeyutl -sign -rawin`. |
| B3 | **The feed URL and public key live in `linux/release.json`** (`appcastUrl`, `eddsaPublicKey`), as Windows keeps them in `windows/release.json`. `build_appimage.sh` passes them to `flutter build` as `--dart-define`s; `APPSTUDIO_APPCAST_URL` and `APPSTUDIO_EDDSA_PUBLIC_KEY` in the environment override them, for a local feed. Empty, updates are unavailable. |
| B4 | **The build number is pubspec's**, the same `+N` the macOS build uses, so `make set_version` covers Linux too. |
| B5 | **The AppImage is replaced in place**, at whatever path it runs from, and started again from there. A menu entry, App Studio's or another tool's, keeps working because the path stays the same. When App Studio's entry names `~/AppImages/AppStudio-x86_64.AppImage` and records the running build, that file is the one replaced, even though `$APPIMAGE` still names the folder the file came from: after an Add in the same run, and also when Add had to copy rather than move and the original is still in a folder App Studio cannot write to (`/opt`, say). Another copy left there, of another build, is never replaced. So a second copy of the same build, run from `~/Downloads` say, updates the menu's copy and restarts that one; started again, the copy that ran offers to open the newer one. A leftover download is cleared beside both. |
| B6 | **https only**, for the feed and every download: the signature covers the file, not the feed, so over plain http anyone in between could serve an older signed build as a newer one. Plain http is accepted only to this machine (`localhost`, `127/8`, `::1`) or a private IPv4 network (`10/8`, `172.16/12`, `192.168/16`), written in dotted decimal, which only a local test feed uses. The app, `build_appimage.sh` and `appcast.sh` check the same rule; the scripts also refuse a few odd spellings (percent-escaped hosts) the app lets through to the very host it checked. |
| B7 | **The feed is not signed, so nothing in it is trusted beyond the file's signature.** `sparkle:shortVersionString` is written into App Studio's menu entry, so an item whose version is not letters, digits, `.`, `+` and `-` (64 at most) is left out, and every value written to the entry has its line breaks escaped. `build_appimage.sh` refuses a build with only one of the feed and the key. |

### When it checks

- **Help → Check for Updates...**, any time. It says when App Studio is up
  to date, and why when the check fails.
- **Automatically, once a day** (Help → Check for Updates Automatically,
  on by default, as on macOS): on start after the Add question, and every
  hour after that whenever the last check is a day old. Only over the start
  page, with nothing pushed over it: a project open means a running server,
  and an update dialog there would interrupt work, as Sparkle's busy veto
  avoids on macOS and Windows. New Project and Settings count as work too,
  since Install quits the app in the middle of `serverpod create` or a tool
  install.
  An automatic check that finds nothing, or fails, says nothing.
- Only when running as an AppImage (part A's condition 1). A development
  build, or one without a feed, shows "Check for Updates (unavailable in this
  build)".

### The dialog

```text
App Studio 0.4.2 is available

You have 0.4.1. Installing restarts App Studio, which stops the server if
it is running.

[Skip This Version]                    [Later]  [Install and Restart]
```

**Skip This Version** stops the automatic check offering that build; Help →
Check for Updates still offers it, as Sparkle does. **Install and Restart**
downloads with a progress bar and Cancel, then checks and installs. Cancel
stops the download at once, even while the server has stopped sending; a
server that stays silent for 60 s fails the download.

1. **Downloads** to a hidden file beside the AppImage
   (`.AppStudio-update.part`), so the final rename stays on one file system
   and is atomic. The file is created anew, never opened through whatever
   is in its place, and one an interrupted run left behind is deleted by the
   next check. One download runs at a time: the Help menu stays usable under
   the dialog, so a second one is refused, and a check leaves a running
   download's file alone. A folder App Studio cannot write to fails here, before
   anything is downloaded, and says to move the AppImage to a folder of the
   user's own, such as `~/AppImages` (Help → Add to Applications).
2. **Checks** the length and the signature (B2). A mismatch deletes the
   file and says so; nothing is replaced.
3. **Replaces** the AppImage: made executable, then renamed over the running
   file. The running copy is unaffected, as part A's move showed: its image
   stays mounted.
4. **Updates App Studio's menu entry**, when it names this file: its
   recorded version becomes the new one (part A, Another copy).
5. **Restarts**: the same quit as File → Quit, teardown included, and the
   new file starts once this process has ended (part A's Open).

A failure in steps 1 to 3 leaves the running AppImage as it was and shows
the reason with **Try Again**. A failed restart (step 5) comes after the
replacement, so the dialog says the new version is installed, and to quit
and start it again, with nothing to try again.

### Gear Lever and other tools

Replacing the file in place keeps their menu entries working. Gear Lever
shows the version it read when it added the file until it looks again; its
own update (through `.zsync`) stays a separate route, and it stays off until
the AppImage carries update information.

### Where it lives

- `lib/update/linux/appcast.dart`: reads the feed and picks the newest
  item for Linux; free of `dart:io`.
- `lib/update/linux/linux_updater.dart`: the configuration, the check, the
  download, the signature, the replacement and the preferences (automatic
  checks, last check, skipped build), with the environment, the HTTP client
  and the paths injected so the tests run on every host.
- `lib/update/linux/linux_update_dialog.dart`: the dialog, and
  `update_signals.dart`, what it and the updater tell each other (a
  cancellation, an update installed but not started); both free of
  `dart:io`.
- `lib/update/linux/linux_update_commands.dart`: what Help and the daily
  check run.
- `UpdateController` reads its state from `LinuxUpdater` on Linux, so the
  menu, About and analytics see the version as on the other two systems.
- `tool/linux/appcast.sh`: signs an AppImage and adds it to a feed, newest
  first, refusing a build number the feed already has or has passed, and
  checking the signature against the key in `linux/release.json`.

---

## C. A system that cannot load App Studio (done)

On a system with an older glibc (Ubuntu 22.04, Debian 12, Linux Mint 21), or
without a library such as GTK, `appstudio` fails before any of App Studio
runs: a double-click does **nothing visible**, and only a terminal shows the
loader's error. Dart never runs, so the check sits in `AppRun`.

- **`AppRun` asks the loader first.** `LD_TRACE_LOADED_OBJECTS=1` lists what
  the executable needs without running it, with "not found" for each library
  or symbol version the system lacks. With nothing missing it starts App
  Studio. Otherwise it says why, in one of three ways:
  - **a symbol version missing** (any, such as `GLIBC_2.38` or
    `GLIBCXX_3.4.29`): "App Studio needs a newer Linux", naming the glibc
    version needed, distributions that have it, the system's glibc and the
    versions it lacks. Missing libraries are left out of this message: a
    newer Linux is the fix either way, and on an old system the list runs to
    dozens;
  - **no glibc at all** (`getconf` knows none, as on Alpine): "App Studio
    needs a Linux with glibc";
  - **only libraries missing**: "App Studio is missing system libraries",
    listing them, with a hint to install them with the distribution's
    package manager.
- The message goes to stderr always and, when there is a display, to a
  window through the first of `zenity`, `kdialog` or `notify-send` that
  manages to show it. Then `AppRun` exits with 1.
- **The glibc version is read from the build**: the highest `GLIBC_x.y` any
  ELF file in the bundle references, `data/` excluded (today 2.38). The
  distributions the message names are tied to that version, so a build that
  needs another one stops until they are updated.
- Tested by hand with the packed AppImage in containers: Debian 11 (glibc
  2.31) shows "needs a newer Linux", Alpine shows "needs a Linux with glibc",
  and on Ubuntu 24.04 the check passes and App Studio's executable is
  started. There is no automated test.

---

## D. Download page text

For Serverpod's website, next to the macOS and Windows downloads, once part A
ships. The requirement line follows part C's glibc version; the
distributions named have that glibc, which is not the same as tested (App
Studio is tested on Ubuntu 26.04 and Arch).

```text
App Studio for Linux (x86_64)

Needs a 64-bit Linux with glibc 2.38 or later, such as Ubuntu 24.04,
Fedora 39 or Debian 13, or newer. Tested on Ubuntu and Arch.

Allow the downloaded file to run, then double-click it:
  - GNOME (Ubuntu, Fedora): right-click → Properties → "Executable as Program"
  - KDE: right-click → Properties → Permissions → "Allow executing file as
    program" ("Is executable" on older versions)
  - Terminal: chmod +x AppStudio-*-x86_64.AppImage
Once its setup is done, App Studio offers to add itself to your app menu.

If you use Gear Lever, open the file with it and choose
"Move to the app menu" instead.
```

---

## E. Uninstall (PR 5)

App Studio's uninstall on Linux, in PR 5, runs the same removal as Remove
from Applications, and counts "not in your app menu" as done: Remove reports
it as a failure, which is right for the Help item but not for an uninstall
on a machine where nothing was ever added. Whether it also deletes the AppImage itself is decided
there.

## Testing

- **Unit tests on every host** through `HostPlatform.linux`
  (`test/platform/linux/desktop_integration_test.dart`): each condition of
  the four states (inherited variables, a portable AppImage, entries in
  sub-folders, an unreadable sub-folder, a deleted `TryExec`), the entry it
  writes (including an `Exec` path that needs quoting), a move within and
  across file systems and out of a folder the file cannot leave, a Replace
  across file systems, a failed step undoing only what it created, a retry
  after the move, a failed Replace dropping the recorded version, Remove
  leaving an entry without the marker alone and saying so, how another copy
  compares (newer, older, the same, no recorded version), and Open starting
  the added copy only once the given process has ended. The dialogs and the
  Help items have widget tests, and
  `test/ui/desktop_integration_commands_test.dart` pins the preference both
  ways ("Don't ask again" and Remove set it, Not now, Add and a cancelled
  Remove do not), the question asked once per run and only on Linux, and
  Open quitting this copy only when the newer one could be started.
- **Widgetbook:** the question (from Downloads, already in `~/AppImages`,
  replacing a copy left there, from the Help menu), another copy (newer, older) and the Remove
  confirmation.
- **Ubuntu VM from `clean-install`:**
  - without Gear Lever: download in Firefox, allow it to run, start; after
    setup the question appears; Add; App Studio is in the app menu with its
    icon, starts from there, and the question does not come back;
  - Remove from Applications: the menu entry goes, the file stays;
  - after Gear Lever added it: no question, and no Help item;
  - with Gear Lever installed but not used: the question appears;
  - another copy: start a newer build from `~/Downloads` and Replace; start
    an older one and Open, and the newer copy comes up once the older one
    has quit.
- **Omarchy:** the same Add and Remove, through Walker.
- **Part B, unit tests on every host:** the feed (newest Linux item, other
  systems and incomplete items left out, the namespace rather than the
  prefix, https only); the updater against a fake HTTP server with real
  Ed25519 signatures (a wrong signature, another key, another length, a
  cancel, one download at a time, a folder it cannot write, a link in the
  download's place, another copy in `~/AppImages` never taken, an
  http feed or download, a leftover download cleared, the replacement and
  restart, the new version recorded in App Studio's entry, the file in
  `~/AppImages` after an Add in the same run, and a signature made by
  `openssl` accepted); the dialog's phases; the daily check (due or not,
  only over the start page, a skipped build and a newer one).
- **Part B, Ubuntu VM** with two builds made against a local feed
  (`APPSTUDIO_APPCAST_URL` and `APPSTUDIO_EDDSA_PUBLIC_KEY`, never
  committed) and a feed from `appcast.sh` naming the newer one:
  - start the older from `~/Downloads`, Add, and the update is offered
    right after; Install and Restart; the newer build comes up from
    `~/AppImages`, its entry records the new version, and no
    `.AppStudio-update.part` is left;
  - Help → Check for Updates in the newer build says it is up to date;
  - in an older copy: Cancel during the download goes back to the offer
    and leaves no file; Skip This Version; a feed whose signature does not
    match is refused and nothing is replaced;
  - with a project open and the server running, Install and Restart stops
    the server and the newer build starts.
