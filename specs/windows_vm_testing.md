# Windows clean-room testing (VM)

How to test App Studio on a clean Windows without risking the dev laptop:
first-run installs, a project end to end, and quitting. Written for the
Phase 4 end-to-end test (`specs/windows_port.md`), reusable for every
Windows build after it.

Why a VM: the dev laptop already has every tool, so it never takes the
first-run paths, and a process exiting while it holds an AF_UNIX socket has
blue-screened it (afunix.sys). In a VM a crash costs a snapshot revert.

---

## 1. One-time setup (about an hour, mostly downloads)

1. **VMware Workstation Pro** — free for any use. Download from Broadcom's
   support portal (a free Broadcom account is needed), install, reboot if
   asked. It runs alongside WSL2 on Windows 11 Home.
2. **Windows 11 Enterprise, 90-day evaluation** — the ISO from Microsoft's
   Evaluation Center (a short form, then a direct download, ~6 GB).
3. **New virtual machine** → Typical → the ISO → Windows 11 x64.
   - 8 GB RAM, 4 vCPUs, 100 GB disk (split files are fine).
   - Encryption: choose *"Only the files needed to support a TPM are
     encrypted"* — Windows 11 needs the virtual TPM.
   - Display: *Accelerate 3D graphics* on.
4. **Install Windows.** At the account step pick *Sign-in options → Domain
   join instead* to make a **local account**, and name it **`Åsa Öberg`**
   (space and non-ASCII on purpose: it puts both into `%USERPROFILE%`). Make
   it an administrator. Decline the optional extras.
5. **VM → Install VMware Tools**, reboot. Nothing else: no Git, no Flutter,
   no Visual Studio, Developer Mode off, long paths off.
6. **Shared folder:** VM → Settings → Options → Shared Folders → *Always
   enabled*, add `C:\Users\info\Projects\appstudio\dist\windows-vm`
   **read-only**. In the VM it is at `\\vmware-host\Shared Folders\windows-vm`.
7. **Snapshot `pristine`** (VM → Snapshot → Take Snapshot).
8. Optional, for the standard-user pass: create a second, *standard* local
   user `Test User`, sign in as them once, sign out, **snapshot
   `pristine-standard-user`**.

Revert to a snapshot before every pass. Never update the VM's Windows between
passes unless that is what is being tested — note the build in the report.

## 2. What goes into the VM

`dist\windows-vm\` on the laptop (made by Claude; `dist/` is not in git):

- `App Studio\` — the release build: `appstudio.exe`, CEF, Flutter, and the
  Visual C++ runtime DLLs next to the exe (a clean Windows does not have
  them; the Phase 8 installer must take care of this).
- `vm_collect.ps1` — the report script (`tool/windows/vm_collect.ps1`).

Copy the whole `App Studio` folder to the VM's Desktop and run it from there
(not from the share).

## 3. Test passes

After each pass run, in PowerShell in the VM:

```powershell
powershell -ExecutionPolicy Bypass -File "\\vmware-host\Shared Folders\windows-vm\vm_collect.ps1" -Label <pass>
```

and bring the `appstudio-vm-<pass>-….txt` it writes on the Desktop back to
the laptop (drag it out, or a shared folder made writable for the purpose).
Note anything seen on screen that the report cannot show.

### Pass A — first run (snapshot `pristine`)

1. Start `appstudio.exe`. Expect the **setup screen**, then the plan:
   Developer Mode, Git for Windows, Flutter, Serverpod, with versions.
2. **Install.** Expect, in order:
   - a **Windows UAC prompt** for Developer Mode → *Yes*;
   - Git downloading, verifying, installing (no Git windows should appear);
   - Flutter downloading (~1 GB), verifying, unpacking, setting up;
   - Serverpod installing.
3. Expect the **start page**. Record how long the whole install took.
4. Open a *new* PowerShell window: `git --version`, `flutter --version`,
   `serverpod version` should all work.
5. Run the report: `-Label A-first-run`.

### Pass B — a project, end to end (continue from A)

1. **New Project** → name `vmtest`, default folder, pick an editor → Create.
2. Expect the "Starting your project" notice, the log filling, and after a
   few minutes the **preview** showing the Serverpod demo app.
3. In the preview: click into a field and type; check text appears **once**
   and App Studio's own shortcuts do not fire.
4. **Hot Restart** (toolbar). The preview reloads.
5. **Close the window (X).** Note how long it takes.
6. Run the report: `-Label B-project`. It should list **no**
   `serverpod`/`dart`/`postgres`/`appstudio` processes left behind.

### Pass C — reopening (continue from B)

1. Start App Studio again → open `vmtest` from the recents.
2. The runner starts again; the preview comes back.
3. In a PowerShell window in the project's `vmtest_server` folder run
   `serverpod runner status` while App Studio has it open.
4. Close App Studio. Report: `-Label C-reopen`.

### Pass D — standard user (snapshot `pristine-standard-user`, optional)

1. Start App Studio as `Test User` → Install.
2. The UAC prompt asks for an administrator's password. **Cancel it.**
3. Expect a failure that says how to turn Developer Mode on in Settings →
   System → For developers, with *Try again* and *Quit*.
4. Report: `-Label D-standard-user`.

### Pass E — the installer and the Windows polish (snapshot `pristine`)

Uses the installer instead of the copied folder: `AppStudio-<v>-x64-setup.exe`
from `tool\windows\build_release.ps1` (or from CI's `windows installer` job).

1. Run the installer. Expect no administrator prompt. Afterwards, App Studio
   is in the Start menu and under Settings → Apps → Installed apps, and it
   opens.
2. **One instance:** start it again from the Start menu. The open window
   comes to the front; there is no second window.
3. **Version:** Help → About App Studio shows `Version <v> (build <n>)`, the
   Windows build number from `windows/release.json`. Help → Check for
   Updates is greyed out unless the build has a feed.
4. **Notifications:** with a project running, switch to another app and let
   the agent finish a task. A toast from App Studio appears.
5. **Menus:** File, View, Server, Logs and Help work, and so do Ctrl+N,
   Ctrl+O, Ctrl+W, Ctrl+, , Ctrl+R, Ctrl+Shift+R, Ctrl+M and Ctrl+L.
6. **Preview keys:** in a text field of the running Flutter web app, type
   text, then use Ctrl+A, Ctrl+C, Ctrl+V and Ctrl+Z. Typing `r` must not
   restart anything, and Ctrl+R must hot-restart.
7. **Open in:** with VS Code or Cursor installed, the toolbar opens the
   project there. With Claude Desktop installed, its link opens it.
8. **Compact window:** in a phone view, minimize the preview. The window
   becomes phone-shaped, borderless and opaque. Drag it by the frame's edge,
   resize from a corner (the aspect holds), flip the orientation, then
   expand. The window comes back where and as it was.
9. **Uninstall:** Help → Uninstall App Studio…, with Git ticked and Developer
   Mode unticked, then Settings → Apps to remove the app itself. Afterwards,
   none of these remain:
   - `%APPDATA%\App Studio`;
   - `%LOCALAPPDATA%\App Studio`;
   - `%APPDATA%\Serverpod\App Studio`;
   - `%LOCALAPPDATA%\Programs\App Studio`;
   - Git.
10. Report: `-Label E-installer`.

## 4. If the VM blue-screens

Revert nothing yet. After it reboots, run the report — it lists the crash
event and minidump — then copy `C:\Windows\Minidump\*.dmp` out (an
administrator PowerShell can copy it to the Desktop). That dump is what
names the driver.

## 5. On a spare, factory-restored laptop instead

Real hardware is a good second opinion: a real GPU for CEF, a vendor image
with its own antivirus, and the afunix.sys an OEM's Windows ships with. It
has no snapshots, though, so **the order of the passes matters**: nothing can
be reverted, and each pass leaves the machine for the next.

### Getting it ready

1. Finish Windows setup with an **administrator** account.
   - A local account is closest to the VM (name it `Åsa Öberg`, to put a
     space and non-ASCII into `%USERPROFILE%`).
   - A Microsoft account is fine too. Its profile folder gets a truncated
     name instead.
2. Let **Windows Update** finish and restart, then note the build
   (`winver`). Keep whatever antivirus the vendor installed: users will have
   it too.
3. Install nothing else: no Git, no Flutter, no Visual Studio. Leave
   Developer Mode and long paths off.
4. Settings → Accounts → Other users → *Add account*: a **standard** local
   user, `Test User`, for pass D. Sign in as them once, then sign out.
5. Nothing on the laptop should matter to anyone: a test can blue-screen it
   (section 4).

### What to bring

Download these on any computer and copy them over on a USB stick:

- **The installer:** GitHub → `serverpod/appstudio` → Actions → *CI*. Open
  the newest run on `windows/phase1-foundations`, then Artifacts →
  **`windows-installer`**. This needs a signed-in account with access;
  artifacts expire after 14 days, and *Run workflow* on the CI page makes a
  fresh one. Unzip it: `AppStudio-<v>-x64-setup.exe` and its `.sha256`.
- **The report script:**
  `https://raw.githubusercontent.com/serverpod/appstudio/windows/phase1-foundations/tool/windows/vm_collect.ps1`
  (*Save as*).

On the laptop, check the installer against its sidecar before running it:

```powershell
(Get-FileHash .\AppStudio-*-x64-setup.exe -Algorithm SHA256).Hash
```

The installer is unsigned, so SmartScreen stops it: *More info → Run
anyway*. That is expected until there is a code-signing certificate.

Wherever a pass below says to run the report, use:

```powershell
powershell -ExecutionPolicy Bypass -File .\vm_collect.ps1 -Label <pass>
```

### The order

1. **Pass D first, as `Test User`.** It needs Developer Mode still off.
   - Install App Studio. A per-user install needs no administrator.
   - Run it, choose Install, and **cancel** the administrator prompt.
   - Expect the failure that explains Settings → System → For developers.
   - Uninstall App Studio from Settings → Apps, run the report
     (`-Label D-standard-user`), then sign out.
2. **Pass A, as the administrator.**
   - Install, run, and let setup turn on Developer Mode (approve the
     prompt) and install Git, Flutter and the Serverpod CLI.
   - Report: `-Label A-first-run`.
3. **Pass B**, then **pass C**, as in section 3.
4. **Pass E** last. Its final step uninstalls everything (Git ticked,
   Developer Mode unticked).

To go round again, turn Developer Mode off in Settings → System → For
developers after pass E. That leaves the laptop as it was before pass A,
apart from Windows Update.

### Bringing results back

Send the `appstudio-vm-<pass>-….txt` files from the Desktop: USB stick or
email. After a blue screen, add `C:\Windows\Minidump\*.dmp` too (copy it
with an administrator PowerShell). Also note what you saw on screen that a
report cannot show: how the preview looked, how long setup took, any
antivirus warnings.
