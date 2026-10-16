# afunix.sys blue screen — reports

Status: drafted 2026-10-16, **not filed yet**. Two reports, ready to paste:
one for Microsoft (Feedback Hub) and one for Serverpod (GitHub). A third,
smaller Serverpod issue from Phase 0 is at the end.

Evidence lives on the dev laptop: `C:\Users\info\crashdumps\101626-12625-01.dmp`
and `101626-15296-01.dmp` (copies of `C:\Windows\Minidump`), and the
`!analyze -v` output in the session scratchpad.

---

## 1. Microsoft — Feedback Hub

**Where:** Feedback Hub → *Report a problem* → category **Devices and
Drivers** → **Network adapters and drivers** (closest fit; afunix.sys is the
AF_UNIX transport under afd.sys). Attach both `.dmp` files. Choosing
*Recreate my problem* is not needed — the dumps carry the evidence.

**Title**

> Bugcheck 0xD1 in afunix.sys (AfUnixTlConnectEndpointDisconnect) when a process exits holding an AF_UNIX socket

**Body**

> On Windows 11 25H2 build 26200.9457 (afunix.sys 10.0.26100.8972, from
> KB5129195) the machine blue-screens with DRIVER_IRQL_NOT_LESS_OR_EQUAL
> (0xD1) while a process that holds a connected AF_UNIX socket is exiting.
> It happened three times in one hour; two minidumps were written and both
> show the same stack.
>
> **Bugcheck:** 0xD1 (0x0000000000000000, 0x0000000000000002,
> 0x0000000000000000, 0x0000000000000000) — a NULL read at DISPATCH_LEVEL.
>
> **Faulting frame:** `afunix!AfUnixTlConnectEndpointDisconnect+0x3e`
> (FAILURE_BUCKET_ID `AV_afunix!AfUnixTlConnectEndpointDisconnect`).
>
> **Stack (both dumps):**
> ```
> nt!KeBugCheckEx
> afunix!AfUnixTlConnectEndpointDisconnect+0x3e
> afd!AfdBeginAbort+0x3e2
> afd!AfdAbortConnection+0x132
> afd!AfdCancelTPackets+0x1f2
> afd!AfdCleanupCore+0x965
> afd!AfdDispatch+0xd9
> nt!IofCallDriver+0x84
> nt!IopCloseFile+0x13d
> nt!ObCloseHandleTableEntry+0x63c
> nt!ExSweepHandleTable+0xcc
> nt!ObKillProcess+0x35
> nt!PspRundownSingleProcess+0xba
> nt!PspExitLastThread+0xe6
> nt!PspExitThread+0x5c4
> ```
> The process being torn down was `flutter_tester.exe` (Flutter 3.47.7 /
> Dart 3.13.5 test runner), at the end of a test file. The handle sweep on
> process exit closes an AF_UNIX socket, afd aborts the connection, and
> afunix dereferences NULL in its disconnect path.
>
> **What the workload does:** Dart's `dart:io` opens AF_UNIX sockets on
> Windows (`InternetAddressType.unix`), both listening and connecting, and
> test processes start and terminate child processes. The crash is
> intermittent: the same workload passed several times before crashing.
>
> **Expected:** closing or abandoning an AF_UNIX socket at process exit
> never bugchecks, whatever state the peer or pending sends are in.
>
> **System:** ASUS Vivobook 18 D1807GA, AMD Ryzen AI 7 445, 32 GB,
> Windows 11 Home 25H2 26200.9457, afunix.sys 10.0.26100.8972 (installed
> 2026-10-12 with KB5129195). KB5127648 (26200.9711) is offered but not yet
> installed. Third-party network-path drivers present: McAfee mfesec.sys,
> Realtek rtwlane613.sys — neither appears on the faulting stack.

---

## 2. Serverpod — GitHub issue (serverpod/serverpod)

**Title**

> Windows: AF_UNIX runner socket can trigger an OS blue screen (afunix.sys bug) on process exit

**Body**

> Heads-up for the 4.1 runner on Windows. While porting App Studio to
> Windows we hit a **Windows kernel bug in `afunix.sys`** (Microsoft's
> AF_UNIX driver, 10.0.26100.8972, Windows 11 25H2 26200.9457): when a
> process exits while holding a connected AF_UNIX socket, the OS can
> bugcheck with `0xD1` in `afunix!AfUnixTlConnectEndpointDisconnect`. Stack
> from two minidumps:
>
> `PspExitThread → ObKillProcess → … → afd!AfdCleanupCore → AfdCancelTPackets
> → AfdAbortConnection → AfdBeginAbort → afunix!AfUnixTlConnectEndpointDisconnect`
>
> Our trigger was `flutter_tester` processes exiting at the end of test
> files (a Dart process with AF_UNIX sockets, plus child processes being
> started and terminated). It is intermittent. We have reported it to
> Microsoft through Feedback Hub.
>
> **Why it matters for Serverpod:** on Windows the runner's `tui.sock` and
> `mcp.sock` are AF_UNIX, so every client (the CLI's attach, App Studio, AI
> agents through `mcp-server`) and the runner itself hold AF_UNIX
> connections. A client or runner that exits — or is killed — mid-connection
> is the pattern that crashed this machine.
>
> **What might reduce exposure until Microsoft fixes it** (untested
> suggestions):
> - Close sockets gracefully — `shutdown` / flush before `close` — rather
>   than leaving them for the process-exit handle sweep, which takes the
>   abort path (`AfdAbortConnection`) seen in the stack.
> - On Windows, consider a loopback TCP port published in `runner.json` as
>   an alternative transport, or a named pipe.
> - Mention the known OS issue in the Windows docs once Microsoft confirms
>   it.
>
> Environment: Serverpod CLI 4.1.0-beta.3, Dart 3.13.5, Flutter 3.47.7,
> Windows 11 Home 25H2 26200.9457, ASUS Vivobook 18 (AMD Ryzen AI 7 445).
> Minidumps available on request.

---

## 3. Serverpod — smaller issue from Phase 0

**Title**

> Windows: `runner stop` leaves the project's Postgres running

**Body**

> On Windows, stopping a runner (`stop` over `tui.sock`, as `serverpod runner
> stop` does) ends the runner, its Flutter web server and its Dart
> processes, but the project's bundled Postgres keeps running, orphaned:
>
> `%LOCALAPPDATA%\serverpod\Cache\pg-binaries\16.13.0-r1\windows-x64\bin\postgres.exe -D <server>\.serverpod\development\pgdata`
>
> `pg_ctl status -D <pgdata>` still reports it running afterwards, and
> `pg_ctl stop -D <pgdata> -m fast` stops it cleanly. Reproduced with a
> fresh `serverpod create` fullstack project at a short and at a long path.
> Serverpod CLI 4.1.0-beta.3, Windows 11 25H2.
