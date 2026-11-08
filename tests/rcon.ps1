# Minimal Source RCON client used by the CS2Unified smoke tests.
# Protocol note: the DS-side _rcon.ps1 sends EXECCOMMAND as type 3 (AUTH), so the
# server answers id=-1 and never runs the command. This client uses the correct
# values: AUTH=3, EXECCOMMAND=2, AUTH_RESPONSE=2, RESPONSE_VALUE=0.
param(
    [string]$Server = '127.0.0.1',
    [int]$Port = 27016,
    [string]$Password,
    [string[]]$Command = @('sm version'),
    [int]$ReadTimeoutMs = 1500
)

$ErrorActionPreference = 'Stop'
if (-not $Password) {
    if ($env:CS2U_RCON_PASSWORD) {
        $Password = $env:CS2U_RCON_PASSWORD
    } else {
        Write-Error 'RCON password not provided: pass -Password <secret> or set the CS2U_RCON_PASSWORD environment variable (you set it on the server via rcon_password).'
        exit 1
    }
}

function Send-Packet([int]$id, [int]$type, [string]$body) {
    $b = [Text.Encoding]::UTF8.GetBytes($body)
    $payload = New-Object 'System.Collections.Generic.List[byte]'
    $payload.AddRange([BitConverter]::GetBytes([int]$id))
    $payload.AddRange([BitConverter]::GetBytes([int]$type))
    $payload.AddRange($b)
    $payload.Add(0); $payload.Add(0)
    $size = [BitConverter]::GetBytes([int]$payload.Count)
    $out = New-Object byte[] (4 + $payload.Count)
    [Array]::Copy($size, 0, $out, 0, 4)
    $payload.CopyTo($out, 4)
    $script:stream.Write($out, 0, $out.Length)
    $script:stream.Flush()
}

function Read-Packet {
    $hdr = New-Object byte[] 4
    $n = 0
    try { $n = $script:stream.Read($hdr, 0, 4) } catch { return $null }
    if ($n -lt 4) { return $null }
    $size = [BitConverter]::ToInt32($hdr, 0)
    if ($size -lt 10 -or $size -gt 4MB) { return $null }
    $buf = New-Object byte[] $size
    $read = 0
    while ($read -lt $size) {
        $r = $script:stream.Read($buf, $read, $size - $read)
        if ($r -le 0) { break }
        $read += $r
    }
    $bodyLen = $size - 10
    $body = ''
    if ($bodyLen -gt 0) { $body = [Text.Encoding]::UTF8.GetString($buf, 8, $bodyLen) }
    [pscustomobject]@{
        id   = [BitConverter]::ToInt32($buf, 0)
        type = [BitConverter]::ToInt32($buf, 4)
        body = $body
    }
}

$client = New-Object System.Net.Sockets.TcpClient
$client.Connect($Server, $Port)
$stream = $client.GetStream()
$stream.ReadTimeout = $ReadTimeoutMs

Send-Packet 1 3 $Password
$auth = $null
for ($i = 0; $i -lt 8; $i++) {
    $p = Read-Packet
    if ($null -eq $p) { break }
    # L4D2 replies to AUTH with id=1; the response type is 2 (AUTH_RESPONSE)
    # on some builds but 0 (RESPONSE_VALUE) on this one (measured 2026-11-07,
    # SourceMod 1.12 / L4D2 DS). Key on the id, not the type: a wrong password
    # comes back as id -1, which is what the check below rejects.
    if ($p.id -eq 1) { $auth = $p; break }
}
if ($null -eq $auth -or $auth.id -ne 1) {
    Write-Output 'RCON AUTH FAILED'
    $client.Close()
    exit 1
}

$rid = 10
foreach ($cmd in $Command) {
    Send-Packet $rid 2 $cmd
    $sb = New-Object System.Text.StringBuilder
    $deadline = [DateTime]::UtcNow.AddMilliseconds(1200)
    while ([DateTime]::UtcNow -lt $deadline) {
        $p = Read-Packet
        if ($null -eq $p) { break }
        if ($p.id -eq $rid -and $p.type -eq 0) { [void]$sb.Append($p.body) }
    }
    Write-Output ("### " + $cmd)
    Write-Output ($sb.ToString().Trim([char]0).TrimEnd())
    $rid++
}

$client.Close()
