param(
  [Parameter(Mandatory = $true)]
  [string]$Configuration,

  [Parameter(Mandatory = $true)]
  [ValidateSet("windows-x64", "windows-arm64")]
  [string]$TargetPlatform,

  [Parameter(Mandatory = $true)]
  [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot

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
}

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
  throw "Cargo is required to build the Windows native library."
}

$env:LIBZ_SYS_STATIC = "1"
$cargoArgs = @(
  "build",
  "--manifest-path", (Join-Path $projectRoot "rust\Cargo.toml"),
  "-p", "mds-bridge",
  "--target", $rustTarget
) + $profileArgs

& cargo @cargoArgs
if ($LASTEXITCODE -ne 0) {
  throw "Rust build failed for $rustTarget"
}

$library = Join-Path $projectRoot "rust\target\$rustTarget\$cargoProfile\mds_bridge.dll"
if (-not (Test-Path $library -PathType Leaf)) {
  throw "Rust build did not produce $library"
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
Copy-Item -Force $library (Join-Path $OutputDirectory "mds_bridge.dll")
Write-Host "Built Windows Rust library: $OutputDirectory\mds_bridge.dll"
