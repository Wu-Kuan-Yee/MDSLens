param(
  [Parameter(Mandatory = $true)]
  [string]$Configuration,

  [Parameter(Mandatory = $true)]
  [ValidateSet("windows-x64", "windows-arm64")]
  [string]$TargetPlatform,

  [Parameter(Mandatory = $true)]
  [string]$OutputDirectory,

  [Parameter(Mandatory = $true)]
  [string]$CargoTargetDirectory
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot

function Add-ToolDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [string]$CommandName,

    [Parameter(Mandatory = $true)]
    [string[]]$Candidates,

    [Parameter(Mandatory = $true)]
    [string]$InstallHint
  )

  if (Get-Command $CommandName -ErrorAction SilentlyContinue) {
    return
  }
  foreach ($candidate in $Candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      $env:Path = "$(Split-Path -Parent $candidate);$env:Path"
      return
    }
  }
  throw "$CommandName is required to compile vendored OpenSSL. $InstallHint"
}

# openssl-src invokes these tools directly. Virtual-environment activation can
# replace PATH entries, so also discover their conventional Windows locations.
Add-ToolDirectory "perl.exe" @(
  "C:\Strawberry\perl\bin\perl.exe",
  "${env:ProgramFiles}\Git\usr\bin\perl.exe"
) "Install Strawberry Perl or Git for Windows with Perl."
Add-ToolDirectory "nasm.exe" @(
  "C:\Strawberry\c\bin\nasm.exe",
  "${env:ProgramFiles}\NASM\nasm.exe",
  "${env:ProgramFiles(x86)}\NASM\nasm.exe"
) "Install NASM or Strawberry Perl."

if ($Configuration -in @("Release", "Profile")) {
  $cargoProfile = "release"
  $profileArgs = @("--release")
} elseif ($Configuration -eq "Debug") {
  $cargoProfile = "debug"
  $profileArgs = @()
} else {
  throw "Unsupported Rust configuration: $Configuration"
}

$rustTarget = switch ($TargetPlatform) {
  "windows-x64" { "x86_64-pc-windows-msvc" }
  "windows-arm64" { "aarch64-pc-windows-msvc" }
}

if (Get-Command rustup -ErrorAction SilentlyContinue) {
  & rustup target add $rustTarget
  if ($LASTEXITCODE -ne 0) {
    throw "Could not install Rust target $rustTarget"
  }
  $cargoExecutable = (& rustup which cargo).Trim()
  $env:RUSTC = (& rustup which rustc).Trim()
} else {
  $cargoExecutable = (Get-Command cargo -ErrorAction SilentlyContinue).Source
  $rustcCommand = Get-Command rustc -ErrorAction SilentlyContinue
  if ($rustcCommand) {
    $env:RUSTC = $rustcCommand.Source
  }
}

if (-not $cargoExecutable -or -not $env:RUSTC) {
  throw "Cargo is required to build the Windows native library."
}

$env:LIBZ_SYS_STATIC = "1"
$env:CARGO_TARGET_DIR = [IO.Path]::GetFullPath($CargoTargetDirectory)
$cargoArgs = @(
  "build",
  "--manifest-path", (Join-Path $projectRoot "rust\Cargo.toml"),
  "-p", "mds-bridge",
  "--target", $rustTarget
) + $profileArgs

& $cargoExecutable @cargoArgs
if ($LASTEXITCODE -ne 0) {
  throw "Rust build failed for $rustTarget"
}

$library = Join-Path $env:CARGO_TARGET_DIR "$rustTarget\$cargoProfile\mds_bridge.dll"
if (-not (Test-Path $library -PathType Leaf)) {
  throw "Rust build did not produce $library"
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
Copy-Item -Force $library (Join-Path $OutputDirectory "mds_bridge.dll")
Write-Host "Built Windows Rust library: $OutputDirectory\mds_bridge.dll"
