# Generate the auth section of menu.cfg from a SourceMod admins_simple.ini.
#
# Why a generator instead of reading admins_simple.ini at runtime:
#   the plugin must have ONE authority at runtime. Reading two admin files
#   would let them drift and make AUTH-CONFLICT impossible to explain. Run
#   this once after editing the SteamID list; the plugin then only reads
#   menu.cfg.
param(
    [Parameter(Mandatory)][string]$AdminIni,
    [string]$Template = (Join-Path (Split-Path -Parent $PSScriptRoot) 'configs\cs2unified\menu.cfg'),
    [string]$Out,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
if (-not $Out) {
    $Out = Join-Path (Split-Path -Parent $PSScriptRoot) 'configs\cs2unified\menu.cfg'
}
if (-not (Test-Path $AdminIni)) { throw "admins ini not found: $AdminIni" }
if (-not (Test-Path $Template)) { throw "menu template not found: $Template" }

$steamIds = New-Object System.Collections.Generic.List[string]
foreach ($line in Get-Content -LiteralPath $AdminIni) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('//')) { continue }
    if ($t -notmatch '^\s*"([^"]+)"\s+"([^"]*)"') { continue }
    $identity = $Matches[1]
    $flags = $Matches[2]
    if ($identity -notmatch '^STEAM_[0-9]:[0-9]:[0-9]+$') { continue }

    # admins_simple.ini flag strings may carry "immunity:flags" (e.g. 99:z).
    $tier = if ($flags -match '(^|:)z($|:)') { 'root' } else { 'admin' }
    $steamIds.Add(('            "{0}" "{1} {2}"' -f $steamIds.Count, $identity, $tier)) | Out-Null
}

if ($steamIds.Count -eq 0) { throw "no SteamID entries found in $AdminIni" }

$auth = New-Object System.Text.StringBuilder
[void]$auth.AppendLine('')
[void]$auth.AppendLine('	"auth"')
[void]$auth.AppendLine('	{')
[void]$auth.AppendLine('		"priority" "steamid"')
[void]$auth.AppendLine('		"steamids"')
[void]$auth.AppendLine('		{')
foreach ($line in $steamIds) { [void]$auth.AppendLine($line) }
[void]$auth.AppendLine('		}')
[void]$auth.AppendLine('		"groups"')
[void]$auth.AppendLine('		{')
[void]$auth.AppendLine('			"0" "Full Admins root"')
[void]$auth.AppendLine('		}')
[void]$auth.AppendLine('	}')

$text = Get-Content -LiteralPath $Template -Raw
$idx = $text.LastIndexOf('}')
if ($idx -lt 0) { throw "template has no closing brace: $Template" }
$result = $text.Substring(0, $idx) + $auth.ToString() + "}`r`n"

if ($DryRun) {
    Write-Host ("DRYRUN {0} steamids={1}" -f $Out, $steamIds.Count)
    Write-Output $result
    return
}

$dir = Split-Path -Parent $Out
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
[System.IO.File]::WriteAllText($Out, $result, [System.Text.UTF8Encoding]::new($false))
Write-Host ("WROTE {0} steamids={1}" -f $Out, $steamIds.Count)
