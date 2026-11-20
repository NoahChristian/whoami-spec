<#
    Run the shared corpus against ref/powershell/Whoami.psm1.

    SPDX-License-Identifier: MIT

    Same job and same output shape as every other runner here, so results can
    be compared line for line. The corpus is the authority; a runner that
    disagrees with it is reporting a defect in its implementation.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo   = Split-Path -Parent $here
$corpus = Join-Path $here 'corpus'
Import-Module (Join-Path $repo 'ref/powershell/Whoami.psm1') -Force

# Map this implementation's wording to the corpus's canonical token. Each
# language keeps its own phrasing; only the token has to agree.
$tokens = @(
    @{ Needle = 'empty';    Token = 'empty' },
    @{ Needle = 'preamble'; Token = 'preamble' },
    @{ Needle = 'schema';   Token = 'schema' },
    @{ Needle = 'special';  Token = 'special' },
    @{ Needle = 'bound';    Token = 'bounds' }
)

function Get-CanonicalToken {
    param([string]$Message)
    foreach ($t in $tokens) {
        if ($Message -like "*$($t.Needle)*") { return $t.Token }
    }
    return "unmapped:$Message"
}

function Import-Expect {
    param([string]$Path)
    $out = @{}
    foreach ($raw in (Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($raw) -or $raw.StartsWith('#')) { continue }
        $eq = $raw.IndexOf('=')   # FIRST equals: a label may contain a space
        if ($eq -lt 0) { continue }
        $out[$raw.Substring(0, $eq)] = $raw.Substring($eq + 1)
    }
    $out
}

function Test-Case {
    param([string]$Name)
    # -Raw keeps the bytes as they are. Get-Content without it splits lines and
    # would quietly repair the very malformations the corpus is testing.
    $text = Get-Content -LiteralPath (Join-Path $corpus "$Name.report") -Raw -ErrorAction SilentlyContinue
    if ($null -eq $text) { $text = '' }
    $expect = Import-Expect (Join-Path $corpus "$Name.expect")
    $problems = New-Object System.Collections.Generic.List[string]
    $report = $null

    try {
        $report = ConvertFrom-WhoamiReport -Text $text
        if ($expect['status'] -eq 'error') {
            $problems.Add('read succeeded, but this case exists to be refused')
        }
    }
    catch {
        $got = Get-CanonicalToken $_.Exception.Message
        if ($expect['status'] -ne 'error') {
            $problems.Add("threw '$($_.Exception.Message)' but the case expects a successful read")
        }
        elseif ($expect.ContainsKey('error') -and $got -ne $expect['error']) {
            $problems.Add("error token '$got', corpus says '$($expect['error'])'")
        }
    }

    if ($null -ne $report) {
        foreach ($key in ($expect.Keys | Sort-Object)) {
            $want = $expect[$key]
            if ($key -in @('status', 'error')) { continue }
            if ($key.StartsWith('field.')) {
                $label = $key.Substring(6)
                $got = if ($report.Fields.Contains($label)) { $report.Fields[$label] } else { $null }
                if ($got -ne $want) { $problems.Add("field '$label' is '$got', corpus says '$want'") }
            }
            elseif ($key -eq 'major'    -and "$($report.Major)" -ne $want)    { $problems.Add("major $($report.Major), corpus says $want") }
            elseif ($key -eq 'revision' -and "$($report.Revision)" -ne $want) { $problems.Add("revision $($report.Revision), corpus says $want") }
            elseif ($key -eq 'speaks') {
                $got = ($report.Speaks -join ' ')
                if ($got -ne $want) { $problems.Add("speaks '$got', corpus says '$want'") }
            }
            elseif ($key -eq 'refusal') {
                $got = if ($report.Refusal) { 'true' } else { 'false' }
                if ($got -ne $want) { $problems.Add("refusal $got, corpus says $want") }
            }
            elseif ($key -eq 'blocks' -and "$($report.SpecialBlocks)" -ne $want) {
                $problems.Add("blocks $($report.SpecialBlocks), corpus says $want")
            }
        }
    }
    , $problems
}

$names = Get-Content -LiteralPath (Join-Path $corpus 'INDEX') | Where-Object { $_.Trim() }
$bad = 0
foreach ($name in $names) {
    $problems = Test-Case $name
    if ($problems.Count -gt 0) { $bad++ }
    "  {0,-4} {1}" -f $(if ($problems.Count) { 'FAIL' } else { 'ok' }), $name
    foreach ($p in $problems) { "        $p" }
}
""
"  powershell: {0} cases, {1} failed" -f $names.Count, $bad
exit $(if ($bad) { 1 } else { 0 })
