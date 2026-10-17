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

## 4. If the VM blue-screens

Revert nothing yet. After it reboots, run the report — it lists the crash
event and minidump — then copy `C:\Windows\Minidump\*.dmp` out (an
administrator PowerShell can copy it to the Desktop). That dump is what
names the driver.
