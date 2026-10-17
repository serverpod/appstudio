<#
.SYNOPSIS
Publishes downloads/windows.json, the website's pointer to the Windows
installer.

.DESCRIPTION
The same two entries as downloads/macos.json, each a full download link:

  latest   the newest build in the Windows appcast, which is what auto-update
           serves
  preview  the build windows/release.json names, once it is uploaded and not
           yet promoted

When nothing is waiting for promotion the two are identical. Derived entirely
from published state, so it is safe to re-run. publish_release.ps1 runs it
after an upload and promote_release.ps1 after a promotion.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File tool\windows\publish_downloads.ps1 -Bucket my-bucket -DryRun
#>
param(
  [Parameter(Mandatory)][string]$Bucket,
  [string]$PublicBaseUrl,
  [string]$ImpersonateServiceAccount,
  [switch]$DryRun
)

. "$PSScriptRoot\release_common.ps1"

$origin = Get-OriginBaseUrl $Bucket
$public = Get-PublicBaseUrl $Bucket $PublicBaseUrl
$version = Get-AppVersion
$build = [int](Get-ReleaseConfig).build
$object = Get-ObjectPath $version $build

function Get-ObjectSha([string]$Path) {
  $sidecar = Get-PublishedText "$origin$Path.sha256"
  if (-not $sidecar) { throw "No .sha256 sidecar at $origin$Path.sha256" }
  return Read-Sidecar $sidecar
}

Write-Step 'Reading the live appcast'
$items = @(Get-AppcastItems (Get-PublishedText "$origin$AppcastPath"))
$latest = $null
if ($items.Count -gt 0) {
  $top = $items[0]
  # Strip whichever base the item carries; the object path is the same.
  $path = $top.Url
  foreach ($base in @($public, $origin)) {
    if ($path.StartsWith($base)) { $path = $path.Substring($base.Length) }
  }
  $latest = [pscustomobject]@{ Version = $top.Version; Build = $top.Build; Path = $path }
  Write-Host "    appcast serves $($latest.Version) (build $($latest.Build))"
} else {
  Write-Host '    no appcast published yet'
}

if (-not $latest -or $build -gt $latest.Build) {
  Write-Step "Preview: $version (build $build), not yet in the appcast"
  if (-not (Get-PublishedText "$origin$object.sha256")) {
    throw "windows/release.json names build $build, but nothing is uploaded at $origin$object. Run publish_release.ps1 first."
  }
  $preview = [pscustomobject]@{ Version = $version; Build = $build; Path = $object }
} else {
  Write-Step 'Nothing awaiting promotion: preview is the latest release'
  $preview = $latest
}
# First release ever: nothing promoted yet, so the only honest answer is the
# preview.
if (-not $latest) { $latest = $preview }

function Format-Entry($Entry) {
  return "{`n" +
    "    `"version`": `"$($Entry.Version)`",`n" +
    "    `"build`": $($Entry.Build),`n" +
    "    `"url`": `"$public$($Entry.Path)`",`n" +
    "    `"sha256`": `"$(Get-ObjectSha $Entry.Path)`"`n" +
    "  }"
}

$json = "{`n" +
  "  `"generatedAt`": `"$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))`",`n" +
  "  `"latest`": $(Format-Entry $latest),`n" +
  "  `"preview`": $(Format-Entry $preview)`n" +
  "}`n"

Write-Step $DownloadsPath
Write-Host $json

if ($DryRun) {
  Write-Step 'Dry run: not uploaded.'
  return
}

$file = New-TemporaryFile
try {
  [IO.File]::WriteAllText($file.FullName, $json)
  Write-Step 'Uploading'
  # Mutable by design, with a short max-age: the website reads it live.
  Invoke-Storage -Impersonate $ImpersonateServiceAccount -Arguments @(
    'cp', $file.FullName, "gs://$Bucket/$DownloadsPath",
    '--cache-control=public, max-age=60, must-revalidate',
    '--content-type=application/json'
  )
} finally {
  Remove-Item $file.FullName -Force
}
Write-Step "Published: $public$DownloadsPath"
