# Collects what a Windows clean-room test run left behind, for review.
#
# Run inside the test VM, in PowerShell, after a test pass:
#   powershell -ExecutionPolicy Bypass -File vm_collect.ps1 -Out <folder>
# It only reads: the Windows build, Developer Mode, the user and machine Path,
# App Studio's install record, any processes App Studio or the runner left,
# crash dumps, and the runner log of every project under the user's profile.
# Nothing is changed or uploaded; the report is one text file in -Out.
param(
  [string]$Out = "$env:USERPROFILE\Desktop",
  [string]$Label = 'run'
)

$report = Join-Path $Out ("appstudio-vm-$Label-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
function Section($title) { "`n===== $title =====" }

& {
  Section 'Windows'
  $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  "$($cv.ProductName) $($cv.DisplayVersion) build $($cv.CurrentBuild).$($cv.UBR)"
  "afunix.sys " + (Get-Item "$env:SystemRoot\System32\drivers\afunix.sys").VersionInfo.FileVersion
  "user: $env:USERNAME  profile: $env:USERPROFILE"
  "admin: " + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

  Section 'Developer Mode and long paths'
  "AllowDevelopmentWithoutDevLicense = " + (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
  "Policy (Appx)                     = " + (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx' -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
  "LongPathsEnabled                  = " + (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem').LongPathsEnabled

  Section 'User Path (as stored)'
  $key = Get-Item 'HKCU:\Environment'
  "type: " + $key.GetValueKind('Path')
  $key.GetValue('Path', $null, 'DoNotExpandEnvironmentNames') -split ';'
  Section 'Machine Path'
  [Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';'

  Section 'Tools a new terminal finds'
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
  foreach ($t in 'git', 'flutter', 'dart', 'serverpod') { "$t -> " + ((Get-Command $t -ErrorAction SilentlyContinue | Select-Object -First 1).Source) }
  try { git --version } catch { 'git: not runnable' }

  Section 'Install record (~\.serverpod\app_studio_installs.json)'
  Get-Content "$env:USERPROFILE\.serverpod\app_studio_installs.json" -ErrorAction SilentlyContinue

  Section 'Processes left running'
  Get-CimInstance Win32_Process |
    Where-Object { $_.Name -match '^(appstudio|dart|dartvm|dartaotruntime|serverpod|postgres|flutter_tester)' } |
    ForEach-Object { "[$($_.ProcessId)] $($_.Name)  parent=$($_.ParentProcessId)  $($_.CommandLine)" }

  Section 'Crash dumps (C:\Windows\Minidump)'
  Get-ChildItem C:\Windows\Minidump -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name)  $($_.LastWriteTime)" }
  Get-WinEvent -FilterHashtable @{LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'} -MaxEvents 5 -ErrorAction SilentlyContinue |
    ForEach-Object { "$($_.TimeCreated)  " + ($_.Message -split "`n")[0] }
  Get-WinEvent -FilterHashtable @{LogName = 'Application'; ProviderName = 'Application Error'} -MaxEvents 20 -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match 'appstudio|dart|serverpod|postgres' } |
    ForEach-Object { "$($_.TimeCreated)  " + (($_.Message -split "`n") | Select-Object -First 3) -join ' | ' }

  Section 'Runner logs (last 60 lines each)'
  Get-ChildItem $env:USERPROFILE -Recurse -Filter runner.log -ErrorAction SilentlyContinue -Depth 6 |
    Where-Object { $_.FullName -match '\\.dart_tool\\serverpod\\' } |
    ForEach-Object { "--- $($_.FullName)"; Get-Content $_.FullName -Tail 60 }
} *> $report

"Wrote $report"
