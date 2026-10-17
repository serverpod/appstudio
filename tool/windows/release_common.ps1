# Shared by the Windows release scripts. Dot-source it:
#   . "$PSScriptRoot\release_common.ps1"
#
# Windows releases are their own pipeline (specs/windows_port.md, D5): their
# own build counter (windows/release.json), their own objects under
# releases/windows/, appcast/windows/ and downloads/windows.json, their own
# signing keys. Nothing here reads or writes anything the macOS scripts own,
# and those scripts never look under a windows/ path.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$ReleaseFile = Join-Path $RepoRoot 'windows\release.json'
$DistDir = Join-Path $RepoRoot 'dist\windows'
$AppcastPath = 'appcast/windows/appcast.xml'
$DownloadsPath = 'downloads/windows.json'

function Write-Step([string]$Message) {
  Write-Host "==> $Message"
}

# The marketing version: pubspec's `version:`, before any "+build". pubspec
# stays owned by `make set_version`; nothing here writes it.
function Get-AppVersion {
  $match = Select-String -Path (Join-Path $RepoRoot 'pubspec.yaml') `
    -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)' | Select-Object -First 1
  if (-not $match) { throw 'pubspec.yaml has no version: line.' }
  return $match.Matches[0].Groups[1].Value
}

# windows/release.json: the Windows build counter, the appcast URL and the
# EdDSA public key that release builds compile in.
function Get-ReleaseConfig {
  return Get-Content $ReleaseFile -Raw | ConvertFrom-Json
}

function Save-ReleaseConfig($Config) {
  $json = "{`n" +
    "  `"build`": $([int]$Config.build),`n" +
    "  `"appcastUrl`": `"$($Config.appcastUrl)`",`n" +
    "  `"eddsaPublicKey`": `"$($Config.eddsaPublicKey)`"`n" +
    "}`n"
  [IO.File]::WriteAllText($ReleaseFile, $json)
}

function Get-InstallerName([string]$Version) {
  return "AppStudio-$Version-x64-setup.exe"
}

# Immutable: one object per build, never overwritten.
function Get-ObjectPath([string]$Version, [int]$Build) {
  return "releases/windows/$Version/b$Build/$(Get-InstallerName $Version)"
}

function Get-OriginBaseUrl([string]$Bucket) {
  return "https://storage.googleapis.com/$Bucket/"
}

# What users download from: a CDN host when there is one in front of the
# bucket, the bucket's own origin otherwise.
function Get-PublicBaseUrl([string]$Bucket, [string]$PublicBaseUrl) {
  if ($PublicBaseUrl) {
    if (-not $PublicBaseUrl.EndsWith('/')) { $PublicBaseUrl += '/' }
    return $PublicBaseUrl
  }
  return Get-OriginBaseUrl $Bucket
}

function Invoke-Storage {
  param(
    [Parameter(Mandatory)][string[]]$Arguments,
    [string]$Impersonate
  )
  $all = @('storage') + $Arguments
  if ($Impersonate) { $all += "--impersonate-service-account=$Impersonate" }
  & gcloud @all
  if ($LASTEXITCODE -ne 0) { throw "gcloud $($all -join ' ') failed." }
}

# Reads a published object from the origin, past any cache. Null when it is
# not there.
function Get-PublishedText([string]$Url) {
  try {
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing `
      -Headers @{ 'Cache-Control' = 'no-cache' }
    if ($response.Content -is [byte[]]) {
      return [Text.Encoding]::UTF8.GetString($response.Content)
    }
    return [string]$response.Content
  } catch [System.Net.WebException] {
    $status = $_.Exception.Response
    if ($status -and [int]$status.StatusCode -eq 404) { return $null }
    throw
  }
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
}

# The first field of a `.sha256` sidecar: "<hash>  <file name>".
function Read-Sidecar([string]$Text) {
  return ($Text.Trim() -split '\s+')[0].ToLowerInvariant()
}

# WinSparkle's own tool, from the package the build downloaded and verified
# (windows/runner/CMakeLists.txt).
function Find-WinSparkleTool {
  $tool = Get-ChildItem -Path (Join-Path $RepoRoot 'build\windows\x64\winsparkle') `
    -Filter 'winsparkle-tool.exe' -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if (-not $tool) {
    throw 'winsparkle-tool.exe not found. Run tool\windows\build_release.ps1 first.'
  }
  return $tool.FullName
}

# Items in an appcast, highest build first: build, version, url. Wrap the
# call in @(...): PowerShell unrolls an empty or one-item result.
function Get-AppcastItems([string]$Xml) {
  if (-not $Xml) { return @() }
  [xml]$doc = $Xml
  $ns = New-Object Xml.XmlNamespaceManager($doc.NameTable)
  $ns.AddNamespace('sparkle', 'http://www.andymatuschak.org/xml-namespaces/sparkle')
  $items = foreach ($enclosure in $doc.SelectNodes('//item/enclosure', $ns)) {
    [pscustomobject]@{
      Build   = [int]$enclosure.GetAttribute('version', $ns.LookupNamespace('sparkle'))
      Version = $enclosure.GetAttribute('shortVersionString', $ns.LookupNamespace('sparkle'))
      Url     = $enclosure.GetAttribute('url')
    }
  }
  return @($items | Sort-Object Build -Descending)
}
