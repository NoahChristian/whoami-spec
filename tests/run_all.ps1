<#
    Run the shared corpus against every reference implementation.

    SPDX-License-Identifier: MIT

    WHY THIS EXISTS. Ten implementations of one format is the duplication
    problem this repository was written to undo, scaled up -- unless they are
    all held to the same bytes. Each one testing itself would reproduce exactly
    the failure that started this: the first three implementations of the
    emitter were each tested, all three passed, and all three shared a defect,
    because a thing tested only against itself is tested against its own
    assumptions.

    A MISSING TOOLCHAIN IS REPORTED AS 'skipped', NEVER AS A PASS. A runner
    that cannot run has said nothing about its implementation, and a summary
    that counts it as green is a false clean -- the worst outcome here, and the
    one this bench has paid for more than once.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$tests = Join-Path $repo 'tests'
$corpus = Join-Path $tests 'corpus'
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) 'whoami-conformance'
if (-not (Test-Path $scratch)) { New-Item -ItemType Directory $scratch | Out-Null }

# Toolchains that install without putting themselves on PATH. Looked up by
# path rather than assumed absent, because "not on PATH" and "not installed"
# are different facts and only one of them is a reason to skip.
$extra = @(
    'C:\Ruby33-x64\msys64\ucrt64\bin',
    'C:\Program Files\R\R-4.6.2\bin',
    "$env:LOCALAPPDATA\Programs\Julia-1.13.4\bin",
    "$env:USERPROFILE\.cargo\bin",
    "$env:APPDATA\npm"
)
$env:PATH = ($extra -join ';') + ';' +
            [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User')

function Test-Tool {
    param([string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

$results = [ordered]@{}

function Invoke-Impl {
    param([string]$Label, [string]$Needs, [scriptblock]$Body)

    if (-not (Test-Tool $Needs)) {
        Write-Host ("=== {0}: SKIPPED ({1} not installed)" -f $Label, $Needs)
        $results[$Label] = 'skipped'
        return
    }
    Write-Host ("=== {0}" -f $Label)
    $output = & $Body 2>&1
    $tail = $output | Where-Object { $_ -match 'cases,|checks failed' } | Select-Object -Last 1
    $failures = $output | Where-Object { $_ -match '^\s*FAIL ' }
    if ($failures) { $failures | ForEach-Object { Write-Host "  $_" } }
    if ($LASTEXITCODE -eq 0 -and $tail) {
        Write-Host "  $tail"
        $results[$Label] = 'pass'
    } else {
        if ($tail) { Write-Host "  $tail" } else { $output | Select-Object -Last 4 | ForEach-Object { Write-Host "  $_" } }
        $results[$Label] = 'FAIL'
    }
}

Push-Location $repo
try {
    Invoke-Impl 'c' 'gcc' {
        $exe = Join-Path $scratch 'run_c.exe'
        & gcc -std=c11 -Wall -Wextra -O1 'tests/run_c.c' 'ref/c/whoami_parse.c' -o $exe 2>&1 | Out-Null
        if (Test-Path $exe) { & $exe $corpus 2>$null } else { $global:LASTEXITCODE = 1; 'c: build failed' }
    }
    # The EMITTER, round-tripped through the parser. The corpus checks readers
    # only; without this the half of the C core that actually ships on a board
    # would be verified by nothing but the fact that it compiles.
    Invoke-Impl 'c-emitter' 'gcc' {
        $exe = Join-Path $scratch 'run_c_emit.exe'
        & gcc -std=c11 -Wall -Wextra -Werror -O1 'tests/run_c_emit.c' `
              'ref/c/whoami_core.c' 'ref/c/whoami_parse.c' -o $exe 2>&1 | Out-Null
        if (Test-Path $exe) { & $exe } else { $global:LASTEXITCODE = 1; 'c emitter: build failed' }
    }
    Invoke-Impl 'python'     'python'  { & python -I 'tests/run_python.py' }
    Invoke-Impl 'javascript' 'node'    { & node 'tests/run_js.mjs' }
    Invoke-Impl 'typescript' 'npx'     { & npx --yes tsx 'tests/run_ts.ts' $corpus }
    Invoke-Impl 'ruby'       'ruby'    { & ruby 'tests/run_ruby.rb' }
    Invoke-Impl 'rust'       'rustc'   {
        $exe = Join-Path $scratch 'run_rust.exe'
        & rustc --edition 2021 -O 'tests/run_rust.rs' -o $exe 2>&1 | Out-Null
        if (Test-Path $exe) { & $exe $corpus } else { $global:LASTEXITCODE = 1; 'rust: build failed' }
    }
    Invoke-Impl 'java' 'javac' {
        & javac -d $scratch 'ref/java/Whoami.java' 'tests/RunCorpus.java' 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { & java -cp $scratch RunCorpus $corpus }
        else { 'java: build failed' }
    }
    Invoke-Impl 'r'          'Rscript' { & Rscript 'tests/run_r.R' $corpus }
    Invoke-Impl 'julia'      'julia'   { & julia 'tests/run_julia.jl' $corpus }
    Invoke-Impl 'matlab'     'matlab'  {
        Push-Location $tests
        try { & matlab -batch 'run_matlab' } finally { Pop-Location }
    }
    Invoke-Impl 'powershell' 'pwsh'    { & pwsh -NoProfile -File 'tests/run_powershell.ps1' }
}
finally { Pop-Location }

Write-Host ''
Write-Host '=== summary ==='
$pass = 0; $fail = 0; $skip = 0
foreach ($k in $results.Keys) {
    Write-Host ("  {0,-12} {1}" -f $k, $results[$k])
    switch ($results[$k]) {
        'pass'    { $pass++ }
        'skipped' { $skip++ }
        default   { $fail++ }
    }
}
Write-Host ''
Write-Host ("  {0} passed, {1} failed, {2} skipped for a missing toolchain" -f $pass, $fail, $skip)
if ($skip -gt 0) {
    Write-Host '  A skipped implementation has NOT been checked. It is not a pass.'
}
exit $(if ($fail) { 1 } else { 0 })
