<#
.SYNOPSIS
Builds App Studio for Windows: the release bundle and its installer.

.DESCRIPTION
1. Takes the version from pubspec.yaml and the build number from
   windows/release.json (-BumpBuild increments it first and saves it).
2. flutter build windows --release with that version and build, then puts
   back the generated plugin files the release build rewrites: release builds
   leave out plugins only dev dependencies bring (url_launcher via Widgetbook).
3. Checks the bundle has what a clean PC needs: the Visual C++ runtime,
   WinSparkle and CEF.
4. Signs the executables and DLLs when -SignCommand is given.
5. Compiles windows/installer/app_studio.iss into
   dist\windows\AppStudio-<version>-x64-setup.exe, with a .sha256 sidecar.

.PARAMETER BumpBuild
Increment windows/release.json's build number before building. Every build
that is published needs a new number; WinSparkle compares them.

.PARAMETER SignCommand
An Authenticode command that signs the file named after it, for example
  signtool sign /fd SHA256 /tr http://timestamp.acs.microsoft.com /td SHA256 /a
Unsigned builds work, but SmartScreen warns about every download.

.PARAMETER Iscc
Path to Inno Setup's ISCC.exe. Found in the usual install folders otherwise.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File tool\windows\build_release.ps1 -BumpBuild
#>
param(
  [switch]$BumpBuild,
  [string]$SignCommand,
  [string]$Iscc
)

. "$PSScriptRoot\release_common.ps1"

$version = Get-AppVersion
$config = Get-ReleaseConfig
if ($BumpBuild) {
  $config.build = [int]$config.build + 1
  Save-ReleaseConfig $config
}
$build = [int]$config.build
if (-not $config.appcastUrl -or -not $config.eddsaPublicKey) {
  Write-Warning ('windows/release.json has no appcastUrl or eddsaPublicKey: ' +
    'this build will not check for updates.')
}

Write-Step "Building App Studio $version (Windows build $build)"
Push-Location $RepoRoot
try {
  & flutter build windows --release --build-name $version --build-number $build
  if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed.' }
} finally {
  & git checkout -- windows/flutter/generated_plugin_registrant.cc `
    windows/flutter/generated_plugins.cmake
  Pop-Location
}

$bundle = Join-Path $RepoRoot 'build\windows\x64\runner\Release'
Write-Step 'Checking the bundle'
foreach ($file in 'appstudio.exe', 'flutter_windows.dll', 'libcef.dll',
                  'WinSparkle.dll', 'vcruntime140.dll', 'vcruntime140_1.dll',
                  'msvcp140.dll', 'data\app.so') {
  if (-not (Test-Path (Join-Path $bundle $file))) {
    throw "The release bundle has no $file."
  }
}

if ($SignCommand) {
  Write-Step 'Signing the executables and DLLs'
  Get-ChildItem $bundle -Recurse -Include '*.exe', '*.dll' | ForEach-Object {
    # Already signed by its vendor (some of the Visual C++ runtime): leave it.
    if ((Get-AuthenticodeSignature $_.FullName).Status -eq 'Valid') { return }
    Invoke-Expression "$SignCommand `"$($_.FullName)`""
    if ($LASTEXITCODE -ne 0) { throw "Signing $($_.Name) failed." }
  }
}

if (-not $Iscc) {
  $Iscc = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Iscc) {
  throw 'Inno Setup 6 (ISCC.exe) not found. Install it, or pass -Iscc.'
}

Write-Step 'Compiling the installer'
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
$isccArgs = @(
  "/DAppVersion=$version",
  "/DAppBuild=$build",
  "/DSourceDir=$bundle",
  "/DOutputDir=$DistDir"
)
if ($SignCommand) {
  # Inno signs the setup and its uninstaller with this; $f is the file.
  $isccArgs += "/Ssigntool=$SignCommand `$f"
  $isccArgs += '/DSignTool=signtool'
}
$isccArgs += (Join-Path $RepoRoot 'windows\installer\app_studio.iss')
& $Iscc @isccArgs
if ($LASTEXITCODE -ne 0) { throw 'ISCC failed.' }

$installer = Join-Path $DistDir (Get-InstallerName $version)
$sha = Get-Sha256 $installer
[IO.File]::WriteAllText("$installer.sha256",
  "$sha  $(Get-InstallerName $version)`n")

Write-Step "Built $installer"
Write-Host "    sha256 $sha"
Write-Host "    $((Get-Item $installer).Length) bytes"
