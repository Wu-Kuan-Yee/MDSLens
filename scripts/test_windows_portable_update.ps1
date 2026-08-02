[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $Archive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$archivePath = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $Archive))
$logRoot = Join-Path $repositoryRoot 'build\update-test-logs\windows-portable'
$unicodePathSegment = [string] [char] 0x03BB
$sandboxRoot = Join-Path $env:RUNNER_TEMP "MDSLens Updater Test - spaces - $unicodePathSegment"
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Write-TestEvent {
  param([Parameter(Mandatory = $true)][string] $Message)
  $line = '[{0:O}] {1}' -f [DateTime]::UtcNow, $Message
  Add-Content -LiteralPath (Join-Path $logRoot 'events.log') -Value $line -Encoding UTF8
  Write-Host $line
}

function Quote-ProcessArgument {
  param([Parameter(Mandatory = $true)][string] $Value)
  # None of the generated test paths end in a backslash. Doubling embedded
  # quotes is sufficient for the PowerShell command line used by Start-Process.
  return '"' + $Value.Replace('"', '\"') + '"'
}

function Save-Diagnostics {
  param([string] $Reason = '')
  if ($Reason) {
    Set-Content -LiteralPath (Join-Path $logRoot 'failure.txt') -Value $Reason -Encoding UTF8
  }
  if (Test-Path -LiteralPath $sandboxRoot) {
    Get-ChildItem -LiteralPath $sandboxRoot -Force -Recurse -ErrorAction SilentlyContinue |
      Select-Object FullName, Length, LastWriteTimeUtc |
      Format-Table -AutoSize |
      Out-String -Width 4096 |
      Set-Content -LiteralPath (Join-Path $logRoot 'directory-tree.txt') -Encoding UTF8
  }
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Name -in @('mdslens.exe', 'powershell.exe', 'cmd.exe')
    } |
    Select-Object ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine |
    Format-List |
    Out-String -Width 4096 |
    Set-Content -LiteralPath (Join-Path $logRoot 'processes.txt') -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
  throw "Windows portable archive was not found: $archivePath"
}
if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) {
  throw "Windows PowerShell was not found: $powershell"
}

Remove-Item -LiteralPath $logRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
Remove-Item -LiteralPath $sandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $sandboxRoot -Force | Out-Null

$archiveCopy = Join-Path $sandboxRoot 'mdslens-windows-x64.zip'
$extractionRoot = Join-Path $sandboxRoot 'archive contents'
$currentRoot = Join-Path $sandboxRoot 'installed application\mdslens-windows-x64'
$stagedRoot = "$currentRoot.mdslens-update-ci"
$backupRoot = "$currentRoot.mdslens-backup-ci"
$previousRoot = "$currentRoot.mdslens-previous"
$unrelatedRollbackMarker = Join-Path $previousRoot 'unrelated-directory.txt'
$commitMarker = "$currentRoot.mdslens-update-committed"
$workRoot = Join-Path $sandboxRoot 'transaction work'
$helperWorkingDirectory = Join-Path $sandboxRoot 'helper working directory'
$healthFile = Join-Path $workRoot 'healthy'
$readyFile = Join-Path $workRoot 'helper-ready'
$token = 'windows-portable-e2e-token'
$helperPath = Join-Path $workRoot 'apply-update.ps1'
$helperStdout = Join-Path $logRoot 'helper.stdout.log'
$helperStderr = Join-Path $logRoot 'helper.stderr.log'
$helperLogFile = Join-Path $logRoot 'portable-update.log'
$probeSource = Join-Path $workRoot 'UpdateProbe.cs'
$probeCompiler = Join-Path $workRoot 'compile-probe.ps1'
$replacementMarker = Join-Path $currentRoot 'replacement-launched.txt'

$context = [ordered]@{
  archive = $archivePath
  sandbox = $sandboxRoot
  current_root = $currentRoot
  staged_root = $stagedRoot
  backup_root = $backupRoot
  helper = $helperPath
  helper_working_directory = $helperWorkingDirectory
  parent_working_directory = $currentRoot
}
$context | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $logRoot 'context.json') -Encoding UTF8

$helperProcess = $null
$parentProcess = $null
try {
  Write-TestEvent 'Preparing the real Windows portable archive layout.'
  Copy-Item -LiteralPath $archivePath -Destination $archiveCopy
  Expand-Archive -LiteralPath $archiveCopy -DestinationPath $extractionRoot -Force
  $candidateRoot = Join-Path $extractionRoot 'mdslens-windows-x64'
  $candidateMarker = Join-Path $candidateRoot '.mdslens-portable.json'
  if (-not (Test-Path -LiteralPath (Join-Path $candidateRoot 'mdslens.exe') -PathType Leaf)) {
    throw 'The release archive does not contain mdslens-windows-x64/mdslens.exe.'
  }
  if (-not (Test-Path -LiteralPath $candidateMarker -PathType Leaf)) {
    throw 'The release archive does not contain its portable metadata marker.'
  }
  $metadata = Get-Content -LiteralPath $candidateMarker -Raw | ConvertFrom-Json
  if ($metadata.product -ne 'com.mdslens.app' -or
      $metadata.platform -ne 'windows' -or
      $metadata.architecture -ne 'x64' -or
      $metadata.executable -ne 'mdslens.exe') {
    throw 'The release archive contains invalid Windows portable metadata.'
  }
  $newVersion = [string] $metadata.version

  New-Item -ItemType Directory -Path (Split-Path -Parent $currentRoot) -Force | Out-Null
  Copy-Item -LiteralPath $candidateRoot -Destination $currentRoot -Recurse
  Copy-Item -LiteralPath $candidateRoot -Destination $stagedRoot -Recurse
  Set-Content -LiteralPath (Join-Path $currentRoot 'old-version-only.txt') -Value 'old' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $stagedRoot 'new-version-only.txt') -Value 'new' -Encoding Ascii
  # Exercise the collision guard: a directory with the conventional rollback
  # name may belong to an unrelated application and must never be removed.
  New-Item -ItemType Directory -Path $previousRoot -Force | Out-Null
  Set-Content -LiteralPath $unrelatedRollbackMarker -Value 'must-survive' -Encoding Ascii
  $oldMetadata = Get-Content -LiteralPath (Join-Path $currentRoot '.mdslens-portable.json') -Raw | ConvertFrom-Json
  $oldMetadata.version = '0.0.0-ci-old'
  $oldMetadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $currentRoot '.mdslens-portable.json') -Encoding UTF8

  New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $helperWorkingDirectory -Force | Out-Null
  $source = Get-Content -LiteralPath (Join-Path $repositoryRoot 'lib\services\update_installer_native.dart') -Raw
  $helperMatch = [regex]::Match(
    $source,
    "const _windowsPortableApplyUpdateScript = r'''(?<script>.*?)''';",
    [Text.RegularExpressions.RegexOptions]::Singleline
  )
  if (-not $helperMatch.Success) {
    throw 'Could not extract the production Windows portable helper script.'
  }
  [IO.File]::WriteAllText(
    $helperPath,
    $helperMatch.Groups['script'].Value,
    [Text.UTF8Encoding]::new($false)
  )
  Copy-Item -LiteralPath $helperPath -Destination (Join-Path $logRoot 'apply-update.ps1')

  @'
using System;
using System.IO;
using System.Threading;

internal static class UpdateProbe {
    [STAThread]
    private static int Main(string[] args) {
        string health = null;
        string token = null;
        string commit = null;
        foreach (var argument in args) {
            if (argument.StartsWith("--mdslens-update-health=", StringComparison.Ordinal))
                health = argument.Substring("--mdslens-update-health=".Length);
            else if (argument.StartsWith("--mdslens-update-token=", StringComparison.Ordinal))
                token = argument.Substring("--mdslens-update-token=".Length);
            else if (argument.StartsWith("--mdslens-update-commit=", StringComparison.Ordinal))
                commit = argument.Substring("--mdslens-update-commit=".Length);
        }
        if (String.IsNullOrEmpty(health) || String.IsNullOrEmpty(token) || String.IsNullOrEmpty(commit))
            return 2;
        File.WriteAllText(health, token + Environment.NewLine);
        File.WriteAllText(commit, token + Environment.NewLine);
        File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "replacement-launched.txt"), token);
        Thread.Sleep(3000);
        return 0;
    }
}
'@ | Set-Content -LiteralPath $probeSource -Encoding UTF8
Remove-Item -LiteralPath (Join-Path $stagedRoot 'mdslens.exe') -Force
@'
param(
    [Parameter(Mandatory = $true)][string] $Source,
    [Parameter(Mandatory = $true)][string] $Output
)
$ErrorActionPreference = 'Stop'
Add-Type -Path $Source -OutputAssembly $Output -OutputType WindowsApplication
if (-not (Test-Path -LiteralPath $Output -PathType Leaf)) { exit 1 }
'@ | Set-Content -LiteralPath $probeCompiler -Encoding UTF8
& $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probeCompiler `
  $probeSource (Join-Path $stagedRoot 'mdslens.exe')
if ($LASTEXITCODE -ne 0) {
  throw "Windows PowerShell could not compile the update probe (exit code $LASTEXITCODE)."
}

  Write-TestEvent 'Starting a disposable parent process with its CWD inside the old portable root.'
  $parentProcess = Start-Process -FilePath $powershell `
    -ArgumentList '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 3"' `
    -WorkingDirectory $currentRoot -WindowStyle Hidden -PassThru

  $arguments = @(
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    (Quote-ProcessArgument $helperPath),
    [string] $parentProcess.Id,
    (Quote-ProcessArgument $currentRoot),
    (Quote-ProcessArgument $stagedRoot),
    (Quote-ProcessArgument $backupRoot),
    (Quote-ProcessArgument $archiveCopy),
    (Quote-ProcessArgument $workRoot),
    (Quote-ProcessArgument $healthFile),
    $token,
    (Quote-ProcessArgument $commitMarker),
    (Quote-ProcessArgument $readyFile),
    (Quote-ProcessArgument $helperLogFile)
  ) -join ' '

  Write-TestEvent 'Launching the extracted production PowerShell helper.'
  $helperProcess = Start-Process -FilePath $powershell -ArgumentList $arguments `
    -WorkingDirectory $helperWorkingDirectory -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $helperStdout -RedirectStandardError $helperStderr

  $readyDeadline = [DateTime]::UtcNow.AddSeconds(15)
  while (-not (Test-Path -LiteralPath $readyFile) -and [DateTime]::UtcNow -lt $readyDeadline) {
    if ($helperProcess.HasExited) { break }
    Start-Sleep -Milliseconds 100
    $helperProcess.Refresh()
  }
  if (-not (Test-Path -LiteralPath $readyFile)) {
    throw 'The production helper did not acknowledge ownership of the transaction.'
  }
  Write-TestEvent 'The helper acknowledged ownership; waiting for the parent to exit and for the transaction to commit.'

  if (-not $helperProcess.WaitForExit(300000)) {
    Stop-Process -Id $helperProcess.Id -Force -ErrorAction SilentlyContinue
    throw 'The production helper did not finish within five minutes.'
  }
  if ($helperProcess.ExitCode -ne 0) {
    throw "The production helper exited with code $($helperProcess.ExitCode)."
  }

  if (-not (Test-Path -LiteralPath $replacementMarker -PathType Leaf)) {
    throw 'The replacement executable was not launched with the update handshake.'
  }
  if ((Get-Content -LiteralPath $replacementMarker -Raw).Trim() -ne $token) {
    throw 'The replacement executable received an invalid update token.'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $currentRoot 'new-version-only.txt') -PathType Leaf) -or
      (Test-Path -LiteralPath (Join-Path $currentRoot 'old-version-only.txt'))) {
    throw 'The current portable directory was not replaced atomically.'
  }
  $installedMetadata = Get-Content -LiteralPath (Join-Path $currentRoot '.mdslens-portable.json') -Raw | ConvertFrom-Json
  if ([string] $installedMetadata.version -ne $newVersion) {
    throw "The replacement metadata version is '$($installedMetadata.version)', expected '$newVersion'."
  }
  if (-not (Test-Path -LiteralPath $unrelatedRollbackMarker -PathType Leaf) -or
      (Get-Content -LiteralPath $unrelatedRollbackMarker -Raw).Trim() -ne 'must-survive') {
    throw 'The updater removed or changed an unrelated rollback-name directory.'
  }
  foreach ($path in @($stagedRoot, $backupRoot, $commitMarker, $archiveCopy, $workRoot)) {
    if (Test-Path -LiteralPath $path) {
      throw "The successful update left transaction state behind: $path"
    }
  }

  Write-TestEvent "Windows portable updater transaction completed successfully for version $newVersion."
  Save-Diagnostics
} catch {
  Write-TestEvent "FAILED: $($_.Exception.Message)"
  Save-Diagnostics -Reason ($_ | Out-String)
  throw
} finally {
  if ($parentProcess -and -not $parentProcess.HasExited) {
    Stop-Process -Id $parentProcess.Id -Force -ErrorAction SilentlyContinue
  }
  if ($helperProcess -and -not $helperProcess.HasExited) {
    Stop-Process -Id $helperProcess.Id -Force -ErrorAction SilentlyContinue
  }
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Name -eq 'mdslens.exe' -and
      $_.ExecutablePath -and
      $_.ExecutablePath.StartsWith($sandboxRoot, [StringComparison]::OrdinalIgnoreCase)
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
