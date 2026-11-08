# 30 Hz leg of the environment adaptation suite (CS2Unified 1.0.12+).
#
# Thin entry point: the assertions live in env_runtime.ps1 -Phase B, so there is
# exactly one implementation of them. This wrapper exists because tools\ci.ps1
# maps a suite name to tests\<name>_runtime.ps1.
#
#   powershell -File tests\env30_runtime.ps1 -Force
#   powershell -File tools\ci.ps1 -Stage Runtime -Only env30 -Force
#
# Why it is not part of the default CI list: a 30 Hz boot on this rig
# intermittently stalls inside Host_NewGame for minutes (listener closed, process
# alive; reproduced with the plugin disabled too). That is a property of the
# machine, not of the feature, so it cannot be allowed to redden the gate that
# protects the feature. Run it explicitly when you need the E-5 evidence.
param(
    [string]$Map = 'c5m1_waterfront',
    [string]$OutDir,
    [switch]$Force,
    [int]$StartTimeoutSec = 240
)

$ErrorActionPreference = 'Stop'

$forward = @{
    Phase           = 'B'
    SuiteName       = 'env30'
    Map             = $Map
    StartTimeoutSec = $StartTimeoutSec
}
if ($OutDir) { $forward.OutDir = $OutDir }
if ($Force)  { $forward.Force  = $true }

& (Join-Path $PSScriptRoot 'env_runtime.ps1') @forward
exit $LASTEXITCODE
