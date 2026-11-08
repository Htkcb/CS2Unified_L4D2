<#
.SYNOPSIS
    Install (or remove) the git hooks that run the CS2Unified static CI gate.

.DESCRIPTION
    The hook is a POSIX sh script because Git for Windows executes hooks with its
    own shell, and it must use LF endings (CRLF hooks fail with
    "bad interpreter").  It calls tools\ci.ps1 -Stage Static -Quiet, which runs
    sync drift + compile + the 114 static checks in ~20 s.

    Only the static stage belongs in a hook.  The runtime suites start a real
    L4D2 server for several minutes; run those explicitly:
        tools\ci.ps1 -Stage Runtime -Force

.PARAMETER Hook
    Which hooks to install (default: pre-commit).

.PARAMETER Uninstall
    Remove only hooks that this script installed (marker line checked).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\install-hooks.ps1
    powershell -ExecutionPolicy Bypass -File tools\install-hooks.ps1 -Hook pre-commit,pre-push
    powershell -ExecutionPolicy Bypass -File tools\install-hooks.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [ValidateSet('pre-commit', 'pre-push')]
    [string[]]$Hook = @('pre-commit'),
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$gitDir = Join-Path $repo '.git'
if (-not (Test-Path $gitDir)) { throw "not a git repository: $repo" }

$hooksDir = Join-Path $gitDir 'hooks'
New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null

$marker = '# Installed by tools/install-hooks.ps1'

function Get-HookBody([string]$Name) {
    $when = if ($Name -eq 'pre-push') { 'push' } else { 'commit' }
    return @"
#!/bin/sh
$marker
# CS2Unified static gate: sync drift + compile + verification checks.
# Skip a single run with:  CS2U_SKIP_CI=1 git $when ...
if [ "`${CS2U_SKIP_CI:-0}" = "1" ]; then
  echo "${Name}: CS2U_SKIP_CI=1, static gate skipped"
  exit 0
fi
root="`$(git rev-parse --show-toplevel)"
echo "${Name}: running tools/ci.ps1 -Stage Static"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "`$root/tools/ci.ps1" -Stage Static -Quiet
code=`$?
if [ `$code -ne 0 ]; then
  echo "${Name}: static gate FAILED -- see tests/results/ci-* for the report"
  echo "         (fix the failure, or bypass once with CS2U_SKIP_CI=1 git $when ...)"
fi
exit `$code
"@
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

foreach ($name in $Hook) {
    $path = Join-Path $hooksDir $name
    if ($Uninstall) {
        if (Test-Path $path) {
            $current = Get-Content -Raw $path
            if ($current -match [regex]::Escape($marker)) {
                Remove-Item $path -Force
                Write-Host ("REMOVED {0}" -f $path)
            } else {
                Write-Host ("SKIP    {0} (not installed by this script)" -f $path) -ForegroundColor Yellow
            }
        } else {
            Write-Host ("SKIP    {0} (absent)" -f $path)
        }
        continue
    }

    if (Test-Path $path) {
        $current = Get-Content -Raw $path
        if ($current -notmatch [regex]::Escape($marker)) {
            $bak = "$path.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Move-Item -LiteralPath $path -Destination $bak -Force
            Write-Host ("BACKUP  existing hook -> {0}" -f $bak) -ForegroundColor Yellow
        }
    }

    # LF only: Git for Windows runs hooks through sh, and a CRLF shebang fails.
    $body = (Get-HookBody $name) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($path, $body, $utf8NoBom)
    Write-Host ("INSTALLED {0}" -f $path)
}

Write-Host ''
Write-Host 'Runtime suites are not hooked on purpose (they start a real server):'
Write-Host '  powershell -ExecutionPolicy Bypass -File tools\ci.ps1 -Stage Runtime -Force'
