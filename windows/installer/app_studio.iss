; App Studio's Windows installer (Inno Setup 6).
;
; A per-user install into %LOCALAPPDATA%\Programs\App Studio: no
; administrator, nothing outside the user's profile, the same place VS Code,
; Cursor and Git for Windows put their user installs. Built by
; tool/windows/build_release.ps1, which passes:
;
;   /DAppVersion=0.2.3   the marketing version (pubspec's, before the "+")
;   /DAppBuild=22        the Windows build number (windows/release.json)
;   /DSourceDir=...      the release bundle (build\windows\x64\runner\Release)
;   /DOutputDir=...      where the setup .exe goes
;
; and, when a signing credential is set up, /DSignTool=<name> with a matching
; /S<name>=... sign tool definition.
;
; The installer never removes the user's data: like dragging the app to the
; Trash on macOS, uninstalling here leaves settings and tools alone. App
; Studio's own Help > Uninstall App Studio... removes those first.

#ifndef AppVersion
  #error Pass /DAppVersion=<version>
#endif
#ifndef AppBuild
  #error Pass /DAppBuild=<build number>
#endif
#ifndef SourceDir
  #error Pass /DSourceDir=<release bundle directory>
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist\windows"
#endif

[Setup]
; Never change: Windows tells installs of the same app apart by it.
AppId={{376E8EA4-818C-49AA-961E-6C270357EA66}
AppName=App Studio
AppVersion={#AppVersion}
AppVerName=App Studio {#AppVersion}
AppPublisher=Serverpod AB
AppPublisherURL=https://serverpod.dev
AppSupportURL=https://serverpod.dev
VersionInfoVersion={#AppVersion}.{#AppBuild}
VersionInfoProductName=App Studio
DefaultDirName={localappdata}\Programs\App Studio
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Windows 10 1809: AF_UNIX sockets (the runner's), tar.exe and Developer
; Mode's symbolic links are all there from it on.
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename=AppStudio-{#AppVersion}-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\appstudio.exe
UninstallDisplayName=App Studio
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; The mutex the running app holds (windows/runner/main.cpp): setup and
; uninstall wait for App Studio to be closed rather than replace it in use.
AppMutex=Serverpod.AppStudio.Running
CloseApplications=yes
RestartApplications=no
#ifdef SignTool
SignTool={#SignTool}
SignedUninstaller=yes
#endif

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; An update replaces the bundle whole, so a file a newer build no longer ships
; cannot linger and be loaded.
Type: filesandordirs; Name: "{app}\data"

[Icons]
; The AppUserModelID matches the one the app sets for itself, so the pinned
; taskbar icon is the running app, and toast notifications are allowed.
Name: "{autoprograms}\App Studio"; Filename: "{app}\appstudio.exe"; AppUserModelID: "Serverpod.AppStudio"

[Run]
Filename: "{app}\appstudio.exe"; Description: "Open App Studio"; Flags: nowait postinstall skipifsilent
; An update WinSparkle started runs silently and closed the app first: open
; it again, as Sparkle relaunches on macOS.
Filename: "{app}\appstudio.exe"; Flags: nowait skipifnotsilent

[UninstallDelete]
; What the app writes next to itself (CEF's log). Never the user's data.
Type: filesandordirs; Name: "{app}"
