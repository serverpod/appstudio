<#
.SYNOPSIS
Uploads the Windows installer build_release.ps1 made, as a preview.

.DESCRIPTION
Puts dist\windows\AppStudio-<version>-x64-setup.exe and its .sha256 sidecar at
releases/windows/<version>/b<build>/, then refreshes downloads/windows.json so
the website can offer it as the preview. Nothing auto-updates to it until
promote_release.ps1 adds it to the appcast.

Objects are immutable: uploaded with --if-generation-match=0, so a build
number can never be published twice with different contents. Bump the build
(build_release.ps1 -BumpBuild) for every new upload.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File tool\windows\publish_release.ps1 -Bucket my-bucket -DryRun
#>
param(
  [Parameter(Mandatory)][string]$Bucket,
  [string]$PublicBaseUrl,
  [string]$ImpersonateServiceAccount,
  [switch]$DryRun
)

. "$PSScriptRoot\release_common.ps1"

$version = Get-AppVersion
$build = [int](Get-ReleaseConfig).build
$name = Get-InstallerName $version
$installer = Join-Path $DistDir $name
$sidecar = "$installer.sha256"
$object = Get-ObjectPath $version $build

if (-not (Test-Path $installer) -or -not (Test-Path $sidecar)) {
  throw "No $name in dist\windows. Run build_release.ps1 first."
}
$sha = Get-Sha256 $installer
if ($sha -ne (Read-Sidecar (Get-Content $sidecar -Raw))) {
  throw "$name does not match its .sha256 sidecar. Rebuild it."
}

Write-Step "Uploading App Studio $version (Windows build $build)"
Write-Host "    gs://$Bucket/$object"
if ($DryRun) {
  Write-Step 'Dry run: not uploaded.'
} else {
  Invoke-Storage -Impersonate $ImpersonateServiceAccount -Arguments @(
    'cp', $installer, "gs://$Bucket/$object",
    '--if-generation-match=0',
    '--cache-control=public, max-age=31536000, immutable',
    '--content-type=application/vnd.microsoft.portable-executable'
  )
  Invoke-Storage -Impersonate $ImpersonateServiceAccount -Arguments @(
    'cp', $sidecar, "gs://$Bucket/$object.sha256",
    '--if-generation-match=0',
    '--cache-control=public, max-age=31536000, immutable',
    '--content-type=text/plain'
  )
}

& "$PSScriptRoot\publish_downloads.ps1" -Bucket $Bucket `
  -PublicBaseUrl $PublicBaseUrl `
  -ImpersonateServiceAccount $ImpersonateServiceAccount -DryRun:$DryRun
