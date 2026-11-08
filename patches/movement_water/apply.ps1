<#
.SYNOPSIS
    Local patch layer for the water-depth slowdown (movement 0.5.3).

.DESCRIPTION
    src/movement/*.sp is generated from ..\CS2Movement_L4D2.public\scripting by
    tools/sync_sources.ps1; editing it by hand is overwritten on the next sync
    and rejected by `verify.ps1` as drift.  This file is the supported way to
    add local behaviour on top of the read-only upstream tree:

      * cs2movement_water.sp is copied verbatim into src/movement/;
      * three upstream files get a small number of deterministic insertions.

    tools/sync_sources.ps1 dot-sources this file and applies the same transform
    in write mode AND in -Check mode, so `verify.ps1` proves the patch is still
    present and still produces exactly what is on disk.

    This file has NO standalone mode on purpose: applying the transform to an
    already-patched tree would insert a second copy of every block.  Regenerate
    with `tools\sync_sources.ps1` (it always starts from the upstream copy),
    then `tools\verify.ps1 -Check` to prove the result.

    Every anchor is an exact literal; a missing or duplicated anchor throws
    instead of silently producing a half-patched tree.  Nothing here depends on
    line numbers, so an upstream bump that keeps the anchor lines still works.
#>

$ErrorActionPreference = 'Stop'

function Get-MovementWaterPatchDir {
    return $PSScriptRoot
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

function Get-PatchNewline([string]$Text) {
    if ($Text.Contains("`r`n")) { return "`r`n" }
    return "`n"
}

# All patch literals below are written with LF.  Normalise them to whatever the
# generated file uses so a future upstream CRLF change is a no-op, not a throw.
function ConvertTo-BodyNewline([string]$Text, [string]$Newline) {
    if ($Newline -eq "`n") { return $Text }
    return $Text.Replace("`n", $Newline)
}

function Assert-Count([string]$Body, [string]$Literal, [int]$Expected, [string]$Label) {
    $count = ([regex]::Matches($Body, [regex]::Escape($Literal))).Count
    if ($count -ne $Expected) {
        $shown = $Literal -replace "`r?`n", '\n'
        throw ("movement_water patch [{0}]: expected {1} occurrence(s) of `"{2}`", found {3}" -f `
               $Label, $Expected, $shown, $count)
    }
}

# Insert $Insert (whole lines, no trailing newline) after EVERY occurrence of
# the literal anchor $Anchor.
function Add-AfterLiteral {
    param(
        [string]$Body,
        [string]$Anchor,
        [string]$Insert,
        [string]$Label,
        [int]$Expected = 1
    )
    $nl = Get-PatchNewline $Body
    $Anchor = ConvertTo-BodyNewline $Anchor $nl
    $Insert = ConvertTo-BodyNewline $Insert $nl

    Assert-Count $Body $Anchor $Expected $Label
    $found = [regex]::Matches($Body, [regex]::Escape($Anchor))
    for ($i = $found.Count - 1; $i -ge 0; $i--) {
        $pos = $found[$i].Index + $found[$i].Length
        $Body = $Body.Insert($pos, $nl + $Insert)
    }
    return $Body
}

function Set-Literal {
    param(
        [string]$Body,
        [string]$Old,
        [string]$New,
        [string]$Label,
        [int]$Expected = 1
    )
    $nl = Get-PatchNewline $Body
    $Old = ConvertTo-BodyNewline $Old $nl
    $New = ConvertTo-BodyNewline $New $nl

    Assert-Count $Body $Old $Expected $Label
    return $Body.Replace($Old, $New)
}

# ---------------------------------------------------------------------------
# per-file transforms
# ---------------------------------------------------------------------------

function Update-MovementWaterCore([string]$Text) {
    # 0.5.3 header note + version string.
    $Text = Set-Literal $Text `
        ' * Version: 0.5.2 (2026-11-01) -- changes the shipped crouch_slide_time default' `
        (" * Version: 0.5.3 (2026-11-07) -- adds the water-depth slowdown layer" + "`n" +
         " *   (cs2movement_water.sp).  It is applied after the injury cap in both" + "`n" +
         " *   target functions, so depth costs speed on top of limp instead of" + "`n" +
         " *   replacing it.  No other physics path changed." + "`n" +
         " * Version: 0.5.2 (2026-11-01) -- changes the shipped crouch_slide_time default") `
        'version header'

    $Text = Set-Literal $Text '#define CS2M_VERSION "0.5.2"' '#define CS2M_VERSION "0.5.3"' 'version define'

    # Include the new module: it is used by cs2movement_move.sp, so it has to be
    # visible before that include.
    $Text = Add-AfterLiteral $Text `
        '#include "cs2movement_injury.sp"' `
        '#include "cs2movement_water.sp"' `
        'include chain'

    # Create the ConVars + the probe command next to the injury layer.
    $Text = Add-AfterLiteral $Text `
        '    CS2M_InjurySetup();' `
        ("    /* 0.5.3: water-depth slowdown.  Registers its own cvars, the probe" + "`n" +
         "     * command and the per-client prop cache; the behaviour itself is" + "`n" +
         "     * gated inside CS2M_WaterApply() by CS2M_IsSurvivor(). */" + "`n" +
         "    CS2M_WaterSetup();") `
        'create cvars'

    # ACTIVE line: one more switch pair so a startup log proves the layer is on.
    $Text = Set-Literal $Text `
        'crouch_slide=%d injury=%d injury_mode=%d",' `
        'crouch_slide=%d injury=%d injury_mode=%d water=%d water_slow=%.2f",' `
        'active format'

    $Text = Set-Literal $Text `
        '                  GetConVarInt(g_cvInjuryMode));' `
        ("                  GetConVarInt(g_cvInjuryMode)," + "`n" +
         "                  GetConVarInt(g_cvWaterEnable)," + "`n" +
         "                  GetConVarFloat(g_cvWaterSlowdown));") `
        'active args'

    # Per-client reset on connect and disconnect (same anchor, two functions).
    $Text = Add-AfterLiteral $Text `
        '    CS2M_InjuryResetClient(client);' `
        '    CS2M_WaterResetClient(client);' `
        'client reset' -Expected 2

    # Status command: report the water layer with the rest of movement.
    $Text = Add-AfterLiteral $Text `
        '    CS2M_InjuryStatus(client);' `
        '    CS2M_WaterStatus(client);' `
        'status line'

    # Selftest must fail loudly if the new ConVars never registered.
    $Text = Set-Literal $Text `
        ("        `"cs2movement_injury_adrenaline`"" + "`n" + "    };") `
        ("        `"cs2movement_injury_adrenaline`"," + "`n" +
         "        `"cs2movement_water_enable`"," + "`n" +
         "        `"cs2movement_water_slowdown`"" + "`n" + "    };") `
        'selftest cvars'

    return $Text
}

function Update-MovementWaterMove([string]$Text) {
    # Both target functions end with the injury cap; water is the final
    # multiplier so it multiplies with limp instead of overwriting it.
    $Text = Add-AfterLiteral $Text `
        '    speed = CS2M_InjuryApply(client, speed);' `
        '    speed = CS2M_WaterApply(client, speed);' `
        'water apply' -Expected 2
    return $Text
}

function Update-MovementWaterConfig([string]$Text) {
    # Anchored on the last injury check, not on the CONFIG-VALIDATE marker: the
    # new checks have to run before that line is printed.
    $Text = Add-AfterLiteral $Text `
        '    CS2M_ConfigValidateInt("cs2movement_injury_adrenaline", 0, 1);' `
        ("    /* 0.5.3 water-depth slowdown.  Registered with the same bounds as the" + "`n" +
         "     * ConVars; a hand-edited cfg would otherwise be silently clamped." + "`n" +
         "     * slowdown 0 is a valid value (= no effect), enable 0 is the off" + "`n" +
         "     * switch. */" + "`n" +
         "    CS2M_ConfigValidateInt(`"cs2movement_water_enable`", 0, 1);" + "`n" +
         "    CS2M_ConfigValidateFloat(`"cs2movement_water_slowdown`", 0.0, 0.8);") `
        'config validate'
    return $Text
}

function Get-MovementWaterFileText {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    switch ($FileName) {
        'cs2movement.sp'        { return (Update-MovementWaterCore   $Text) }
        'cs2movement_move.sp'   { return (Update-MovementWaterMove   $Text) }
        'cs2movement_config.sp' { return (Update-MovementWaterConfig $Text) }
        default                 { return $Text }
    }
}

function Get-MovementWaterExtraFiles {
    param([Parameter(Mandatory)][string]$PatchDir)
    $name = 'cs2movement_water.sp'
    $path = Join-Path $PatchDir $name
    if (-not (Test-Path $path)) {
        throw "movement_water patch: missing $path"
    }
    return @([pscustomobject]@{
        Name = $name
        Path = $path
        Text = (Get-Content -Raw -Encoding UTF8 $path)
    })
}
