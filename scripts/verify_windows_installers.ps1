param(
  [Parameter(Mandatory = $true)]
  [string] $Dist,

  [ValidateSet('x64', 'arm64')]
  [string] $Architecture,

  [switch] $MsixBundle
)

$ErrorActionPreference = 'Stop'

function Assert-Condition([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw $Message }
}

function Find-MakeAppx {
  $command = Get-Command makeappx.exe -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }

  $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
  $candidates = Get-ChildItem -Path $kits -Filter makeappx.exe -Recurse |
    Where-Object { $_.DirectoryName -match '\\(x64|arm64)$' } |
    Sort-Object FullName -Descending
  Assert-Condition ($candidates.Count -gt 0) 'Could not find makeappx.exe.'
  return $candidates[0].FullName
}

function Invoke-Checked([string] $FilePath, [string[]] $Arguments) {
  $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru
  Assert-Condition ($process.ExitCode -eq 0) (
    "$FilePath failed with exit code $($process.ExitCode): $($Arguments -join ' ')"
  )
}

function Wait-PathGone([string] $Path) {
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Start-Sleep -Milliseconds 250
  }
}

function Verify-Msix([string] $Package, [string] $ExpectedArchitecture) {
  Assert-Condition (Test-Path -LiteralPath $Package -PathType Leaf) "Missing MSIX: $Package"
  $root = Join-Path ([System.IO.Path]::GetTempPath()) (
    'mdslens-msix-' + [guid]::NewGuid().ToString('N')
  )
  New-Item -ItemType Directory -Path $root | Out-Null
  try {
    Invoke-Checked (Find-MakeAppx) @('unpack', '/o', '/p', $Package, '/d', $root)
    $manifestPath = Join-Path $root 'AppxManifest.xml'
    Assert-Condition (Test-Path -LiteralPath $manifestPath -PathType Leaf) (
      "$Package has no AppxManifest.xml"
    )
    [xml] $manifest = Get-Content -LiteralPath $manifestPath -Raw
    $identity = $manifest.SelectSingleNode("//*[local-name()='Identity']")
    $application = $manifest.SelectSingleNode("//*[local-name()='Application']")
    Assert-Condition ($identity.Name -eq 'MDSLens') "$Package has the wrong identity."
    Assert-Condition ($identity.ProcessorArchitecture -eq $ExpectedArchitecture) (
      "$Package has architecture '$($identity.ProcessorArchitecture)', expected '$ExpectedArchitecture'."
    )
    Assert-Condition ($application.Executable -eq 'mdslens.exe') (
      "$Package does not launch mdslens.exe."
    )
    Assert-Condition (Test-Path -LiteralPath (Join-Path $root 'mdslens.exe') -PathType Leaf) (
      "$Package is missing mdslens.exe."
    )
  } finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Expand-Portable([string] $Archive, [string] $Destination) {
  if ($Archive.EndsWith('.zip')) {
    Expand-Archive -LiteralPath $Archive -DestinationPath $Destination
    return
  }
  if ($Archive.EndsWith('.7z')) {
    $command = Get-Command 7z.exe -ErrorAction SilentlyContinue
    $sevenZip = if ($command) { $command.Source } else { 'C:\Program Files\7-Zip\7z.exe' }
    Assert-Condition (Test-Path -LiteralPath $sevenZip -PathType Leaf) (
      '7-Zip is required to verify the 7z archive.'
    )
    Invoke-Checked $sevenZip @('x', '-y', $Archive, "-o$Destination")
    return
  }
  Invoke-Checked 'tar.exe' @('-xf', $Archive, '-C', $Destination)
}

function Verify-Portable([string] $Archive, [string] $ExpectedRoot, [string] $Arch) {
  Assert-Condition (Test-Path -LiteralPath $Archive -PathType Leaf) "Missing archive: $Archive"
  $destination = Join-Path ([System.IO.Path]::GetTempPath()) (
    'mdslens-portable-' + [guid]::NewGuid().ToString('N')
  )
  New-Item -ItemType Directory -Path $destination | Out-Null
  try {
    Expand-Portable $Archive $destination
    $entries = @(Get-ChildItem -LiteralPath $destination)
    Assert-Condition ($entries.Count -eq 1 -and $entries[0].PSIsContainer) (
      "$Archive must extract exactly one top-level directory."
    )
    Assert-Condition ($entries[0].Name -eq $ExpectedRoot) (
      "$Archive extracts '$($entries[0].Name)', expected '$ExpectedRoot'."
    )
    $root = $entries[0].FullName
    Assert-Condition (Test-Path -LiteralPath (Join-Path $root 'mdslens.exe') -PathType Leaf) (
      "$Archive is missing mdslens.exe."
    )
    $metadataPath = Join-Path $root '.mdslens-portable.json'
    Assert-Condition (Test-Path -LiteralPath $metadataPath -PathType Leaf) (
      "$Archive has no portable metadata."
    )
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    Assert-Condition (
      $metadata.product -eq 'com.mdslens.app' -and
      $metadata.platform -eq 'windows' -and
      $metadata.architecture -eq $Arch -and
      $metadata.executable -eq 'mdslens.exe'
    ) "$Archive has invalid portable metadata."
  } finally {
    Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$distPath = (Resolve-Path -LiteralPath $Dist).Path

if ($MsixBundle) {
  $bundle = Join-Path $distPath 'mdslens-windows.msixbundle'
  Assert-Condition (Test-Path -LiteralPath $bundle -PathType Leaf) "Missing bundle: $bundle"
  $root = Join-Path ([System.IO.Path]::GetTempPath()) (
    'mdslens-msixbundle-' + [guid]::NewGuid().ToString('N')
  )
  New-Item -ItemType Directory -Path $root | Out-Null
  try {
    Invoke-Checked (Find-MakeAppx) @('unbundle', '/o', '/p', $bundle, '/d', $root)
    $packages = @(Get-ChildItem -LiteralPath $root -Filter '*.msix')
    Assert-Condition ($packages.Count -eq 2) 'MSIX bundle must contain x64 and arm64 packages.'
    foreach ($arch in @('x64', 'arm64')) {
      $package = $packages | Where-Object { $_.Name -match $arch } | Select-Object -First 1
      Assert-Condition ($null -ne $package) "MSIX bundle is missing its $arch package."
      Verify-Msix $package.FullName $arch
    }
  } finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Host 'Verified Windows MSIX bundle architectures and application identity.'
  exit 0
}

Assert-Condition (-not [string]::IsNullOrWhiteSpace($Architecture)) (
  'Architecture is required unless -MsixBundle is used.'
)
$base = "mdslens-windows-$Architecture"
$installRoot = Join-Path $env:ProgramFiles 'MDSLens'
Assert-Condition (-not (Test-Path -LiteralPath $installRoot)) (
  "Refusing to overwrite an existing test-host installation: $installRoot"
)

$setup = Join-Path $distPath "$base-setup.exe"
Assert-Condition (Test-Path -LiteralPath $setup -PathType Leaf) "Missing installer: $setup"
Invoke-Checked $setup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-')
try {
  Assert-Condition (Test-Path -LiteralPath (Join-Path $installRoot 'mdslens.exe') -PathType Leaf) (
    "The EXE installer did not install MDSLens to $installRoot."
  )
  $uninstaller = Join-Path $installRoot 'unins000.exe'
  Assert-Condition (Test-Path -LiteralPath $uninstaller -PathType Leaf) (
    'The EXE installer did not create an uninstaller.'
  )
  Invoke-Checked $uninstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
  Wait-PathGone (Join-Path $installRoot 'mdslens.exe')
} finally {
  Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $installRoot 'mdslens.exe'))) (
    'The EXE test installation could not be removed cleanly.'
  )
}

$msi = Join-Path $distPath "$base.msi"
Assert-Condition (Test-Path -LiteralPath $msi -PathType Leaf) "Missing installer: $msi"
Invoke-Checked 'msiexec.exe' @('/i', $msi, '/qn', '/norestart')
try {
  Assert-Condition (Test-Path -LiteralPath (Join-Path $installRoot 'mdslens.exe') -PathType Leaf) (
    "The MSI installer did not install MDSLens to $installRoot."
  )
} finally {
  Invoke-Checked 'msiexec.exe' @('/x', $msi, '/qn', '/norestart')
  Wait-PathGone (Join-Path $installRoot 'mdslens.exe')
  Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $installRoot 'mdslens.exe'))) (
    'The MSI test installation could not be removed cleanly.'
  )
}

Verify-Msix (Join-Path $distPath "$base.msix") $Architecture
foreach ($extension in @('zip', '7z', 'tar.gz', 'tar.xz', 'tar.bz2')) {
  Verify-Portable (Join-Path $distPath "$base.$extension") $base $Architecture
}

Write-Host 'Verified Windows installer destinations, MSIX identity, and portable layouts.'
