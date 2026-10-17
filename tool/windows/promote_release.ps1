<#
.SYNOPSIS
Promotes the uploaded Windows build into the WinSparkle appcast, so installed
copies update to it.

.DESCRIPTION
1. Reads the live appcast/windows/appcast.xml, or starts a new one.
2. Downloads the installer windows/release.json names from the bucket and
   checks it against its .sha256 sidecar, so what gets signed is exactly what
   users will download.
3. Signs it with WinSparkle's EdDSA tool and the private key in
   -PrivateKeyFile. That key pairs with eddsaPublicKey in windows/release.json
   and is never the macOS Sparkle key.
4. Adds the item at the top, newest first, and uploads the appcast. The
   appcast is mutable: it is rewritten on every release.
5. Refreshes downloads/windows.json.

The installer runs silently when WinSparkle starts it, then opens App Studio
again (windows/installer/app_studio.iss).

.EXAMPLE
powershell -ExecutionPolicy Bypass -File tool\windows\promote_release.ps1 -Bucket my-bucket -PrivateKeyFile C:\keys\winsparkle_priv.pem -DryRun
#>
param(
  [Parameter(Mandatory)][string]$Bucket,
  [Parameter(Mandatory)][string]$PrivateKeyFile,
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
$url = "$public$object"

if (-not (Test-Path $PrivateKeyFile)) { throw "No private key at $PrivateKeyFile." }
$tool = Find-WinSparkleTool

Write-Step "Promoting App Studio $version (Windows build $build)"
$existing = Get-PublishedText "$origin$AppcastPath"
$items = @(Get-AppcastItems $existing)
if ($items | Where-Object { $_.Build -eq $build }) {
  Write-Host "    build $build is already in the appcast: nothing to promote."
  & "$PSScriptRoot\publish_downloads.ps1" -Bucket $Bucket `
    -PublicBaseUrl $PublicBaseUrl `
    -ImpersonateServiceAccount $ImpersonateServiceAccount -DryRun:$DryRun
  return
}
if ($items.Count -gt 0 -and $items[0].Build -gt $build) {
  throw "The appcast already serves build $($items[0].Build), newer than $build."
}

$work = Join-Path ([IO.Path]::GetTempPath()) "appstudio-promote-$build"
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
  Write-Step 'Downloading and verifying the uploaded installer'
  $download = Join-Path $work (Get-InstallerName $version)
  Invoke-WebRequest -Uri "$origin$object" -OutFile $download -UseBasicParsing
  $sidecar = Get-PublishedText "$origin$object.sha256"
  if (-not $sidecar) { throw "No .sha256 sidecar at $origin$object.sha256" }
  if ((Get-Sha256 $download) -ne (Read-Sidecar $sidecar)) {
    throw 'The uploaded installer does not match its .sha256 sidecar.'
  }

  Write-Step 'Signing'
  # Prints: sparkle:edSignature="..." length="..."
  $signed = & $tool sign --verbose --private-key-file $PrivateKeyFile $download
  if ($LASTEXITCODE -ne 0) { throw 'winsparkle-tool sign failed.' }
  $signed = ($signed | Out-String)
  if ($signed -notmatch 'sparkle:edSignature="([^"]+)"') {
    throw "winsparkle-tool printed no signature: $signed"
  }
  $signature = $Matches[1]
  $length = (Get-Item $download).Length

  $pubDate = (Get-Date).ToUniversalTime().ToString('r')
  $item = @"
    <item>
      <title>Version $version</title>
      <pubDate>$pubDate</pubDate>
      <enclosure url="$url"
                 sparkle:version="$build"
                 sparkle:shortVersionString="$version"
                 sparkle:os="windows-x64"
                 sparkle:installerArguments="/SILENT /SP- /SUPPRESSMSGBOXES /NORESTART"
                 sparkle:edSignature="$signature"
                 length="$length"
                 type="application/octet-stream" />
    </item>
"@

  if ($existing) {
    if ($existing -notmatch '<channel>') { throw 'The live appcast has no <channel>.' }
    # Newest first: right after the channel's own elements.
    $feed = if ($existing -match '<item>') {
      $existing.Insert($existing.IndexOf('<item>'), $item.TrimStart() + "`n    ")
    } else {
      $existing.Replace('</channel>', "$item  </channel>")
    }
  } else {
    $feed = @"
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>App Studio for Windows</title>
    <link>https://serverpod.dev</link>
$item  </channel>
</rss>
"@
  }
  # Must still parse, and must now lead with this build.
  $check = @(Get-AppcastItems $feed)
  if ($check[0].Build -ne $build -or $check[0].Url -ne $url) {
    throw 'The new appcast does not lead with this build.'
  }

  $feedFile = Join-Path $work 'appcast.xml'
  [IO.File]::WriteAllText($feedFile, $feed)
  Write-Step $AppcastPath
  Write-Host $feed

  if ($DryRun) {
    Write-Step 'Dry run: not uploaded.'
  } else {
    Write-Step 'Uploading the appcast'
    Invoke-Storage -Impersonate $ImpersonateServiceAccount -Arguments @(
      'cp', $feedFile, "gs://$Bucket/$AppcastPath",
      '--cache-control=public, max-age=300, must-revalidate',
      '--content-type=application/rss+xml'
    )
  }
} finally {
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

& "$PSScriptRoot\publish_downloads.ps1" -Bucket $Bucket `
  -PublicBaseUrl $PublicBaseUrl `
  -ImpersonateServiceAccount $ImpersonateServiceAccount -DryRun:$DryRun
