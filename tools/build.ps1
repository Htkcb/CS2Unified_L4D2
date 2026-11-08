<#
.SYNOPSIS
    Build the merged CS2Unified plugin with the SourceMod 1.12 compiler.

.DESCRIPTION
    Input : src/cs2unified.sp (and its includes)
    Output: build/cs2unified.smx

    The compiler is looked up in this order:
      1. -CompilerPath
      2. ..\Left 4 Dead 2\...\scripting\spcomp.exe     (sibling Steam library layout)
      3. spcomp on PATH

    -Sync re-runs tools/sync_sources.ps1 first. Use it after bumping either
    upstream project; the transform is the only supported way to update src/feel
    and src/movement.
#>
[CmdletBinding()]
param(
    [string]$CompilerPath,
    [string]$IncludePath,
    [switch]$Sync,
    [switch]$StrictWarnings
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Source      = Join-Path $ProjectRoot 'src\cs2unified.sp'
$BuildDir    = Join-Path $ProjectRoot 'build'
$Output      = Join-Path $BuildDir 'cs2unified.smx'

$compilerCandidates = @(
    $CompilerPath,
    (Join-Path (Split-Path -Parent $ProjectRoot) 'Left 4 Dead 2\left4dead2\addons\sourcemod\scripting\spcomp.exe')
) | Where-Object { $_ -and (Test-Path $_) }

if ($compilerCandidates.Count -eq 0) {
    $cmd = Get-Command spcomp.exe -ErrorAction SilentlyContinue
    if ($cmd) { $compilerCandidates = @($cmd.Source) }
}
if ($compilerCandidates.Count -eq 0) {
    throw "spcomp.exe not found. Pass -CompilerPath <path to spcomp.exe> (from any SourceMod install: addons/sourcemod/scripting/spcomp.exe) or install SourceMod."
}
$spcomp = $compilerCandidates[0]

if (-not $IncludePath) {
    $IncludePath = Join-Path (Split-Path -Parent $spcomp) 'include'
}
if (-not (Test-Path (Join-Path $IncludePath 'sourcemod.inc'))) {
    throw "SourceMod include directory not found: $IncludePath"
}

if ($Sync) {
    & (Join-Path $PSScriptRoot 'sync_sources.ps1')
    if ($LASTEXITCODE -ne 0) { throw "sync_sources.ps1 failed" }
}

if (-not (Test-Path $Source)) { throw "missing source: $Source" }
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
if (Test-Path $Output) { Remove-Item $Output -Force }

Write-Host ("BUILD spcomp={0}" -f $spcomp)
Write-Host ("BUILD source={0}" -f $Source)

$raw = & $spcomp -i $IncludePath -i (Join-Path $ProjectRoot 'src') $Source -o $Output 2>&1
$text = ($raw | Out-String)
$text.Trim() | Write-Host

$hasError   = $text -match 'error \d+:'
$hasWarning = $text -match 'warning \d+:'
if ($LASTEXITCODE -ne 0 -or $hasError) {
    throw "compile failed (exit=$LASTEXITCODE)"
}
if ($StrictWarnings -and $hasWarning) {
    throw "compile produced warnings and -StrictWarnings is set"
}

$file = Get-Item $Output
$hash = (Get-FileHash $Output -Algorithm SHA256).Hash
Write-Host ("BUILD OK {0} bytes sha256={1}" -f $file.Length, $hash)
