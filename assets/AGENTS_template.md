# Flutter & Serverpod project

This project is a Flutter app (frontend) backed by a Serverpod server (backend). Always build the app's backend with Serverpod.
Build for multiple users, use Serverpod's built-in authentication, which is already set up in `lib/server.dart`. The database is PostgreSQL.

The `serverpod-*` skills cover how to work with Serverpod: start with `serverpod-overview`, which explains the runner, the `serverpod` MCP tools and the checklist below. If you cannot access the `serverpod` and `dart` MCP servers, STOP and tell the user how to enable them.

## Serverpod App Studio

The user works on this project in `Serverpod App Studio`, a desktop app for Mac and Windows (it works the same on both) that runs the Serverpod runner and shows the Flutter app in a live preview next to its server log. Where the skills say the user runs `serverpod start`, the user has `Serverpod App Studio` instead. The user may be new to programming: explain everything in plain, non-technical language, and NEVER ask the user to run command line tools.

In `Serverpod App Studio` the user can:

- Open the project, which starts the server and the Flutter app, or connects to them if they are already running. Closing the project stops them.
- See the app in the preview, as a phone (portrait or landscape) or on a desktop.
- Read the server's log (Logs → Show Logs).
- Hot Restart (⚡ button, ⌘R on Mac, Ctrl+R on Windows), which also reloads the preview, and Full Restart (circular arrow button, ⇧⌘R or Ctrl+Shift+R).
- Create and apply database migrations (Server menu, ⌘M or Ctrl+M).

When nothing is running, start the runner with `serverpod runner start` in `projectname_server` as the skills describe. `Serverpod App Studio` connects to it by itself, and to a runner you restart with `serverpod runner stop` and `serverpod runner start`.

Keep the app inside `Serverpod App Studio`. Unless the user asks for it, NEVER:

- run `flutter run`, `serverpod start`, or anything else that launches the app on its own,
- launch the Flutter app on another device (Chrome, macOS, Windows, iOS, Android), open it in a web browser, or use `spawn_flutter_app`,
- leave the server stopped.

To show the user the app, tell them to look at the preview in `Serverpod App Studio`, or to open the project there if they have not. If the preview still shows the old app after a `hot_restart`, ask the user to press Hot Restart.

## Keep Serverpod up to date

At the start of a session, compare `serverpod version` with the `serverpod` dependency in `projectname_server/pubspec.yaml`. If the CLI is newer, upgrade the project to the CLI's version with the `serverpod-upgrading` skill, then tell the user in a sentence or two. NEVER downgrade the project without asking first.

## Checklist

After doing changes, in this order:

- `dart analyze` (CLI)
- `dart format` (CLI)
- `create_migration` and `apply_migrations` (MCP - only if necessary)
- Do `serverpod` MCP `hot_restart` if required (hot reload is done automatically). Will also hot restart Flutter app
- Run tests, if applicable (`dart test` in the server package)
- Check `serverpod` MCP `tail_server_logs` and `tail_flutter_logs` for any issues.

## Testing the app

If the user asks you to test the app:

1. Use `get_flutter_app_dtd` (`serverpod` MCP) to get the Flutter app's DTD
2. Pass the DTD to `connect_dart_tooling_daemon` (`dart` MCP) to connect to the app
3. Use `flutter_driver` (`dart` MCP) to navigate through the app

The app is launched from `projectname_flutter/lib/driver.dart`, which starts the Flutter driver extension with text entry emulation turned off so the app stays usable by hand. To let the driver type, set `enableTextEntryEmulation: true` there and `hot_restart` the app.

IMPORTANT: After building the first version of the app, update this AGENTS.md file with information about the app we're building. KEEP the info about `Serverpod App Studio`, keeping Serverpod up to date and the checklist. Remove this paragraph.
