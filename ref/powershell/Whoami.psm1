<#
.SYNOPSIS
    Read a whoami report from a board, over HTTP or a serial port.

.DESCRIPTION
    SPDX-License-Identifier: MIT

    The bench-side reader. Windows is where the serial ports and the browsers
    are, so this is usually the first thing that talks to a board nobody has
    identified yet -- which is also why it is written as a reader that does not
    trust what it reads.

    SAME BOUNDS AS THE OTHER IMPLEMENTATIONS, and for the same reason: every
    number in a report is input, not instruction, including the counts that say
    how far to read. The format tells a reader how far to read, and the reader
    decides how far it is willing to. Both halves are required.

    PARSING A LINE IS A SLICE, NOT A SEARCH FOR WHITESPACE. Columns 1-11 are
    the label, right-trimmed; column 12 onward is the value, left-trimmed. That
    fixed width is what lets a label contain a space -- 'front end' -- with no
    escaping. A -split on whitespace reads that label as 'front' and silently
    moves 'end' into the value: a corrupted read that looks like a good one.

.EXAMPLE
    Read-WhoamiReport -Uri 'http://a-board.local/api/whoami' | Format-List

.EXAMPLE
    Read-WhoamiReport -Port COM21 -Command 'whoami' | Select-Object Schema, Speaks

.EXAMPLE
    # Is the thing on this port the board I think it is?
    (Read-WhoamiReport -Port COM21).Fields['appid']
#>

Set-StrictMode -Version Latest

$script:Grid         = 11
$script:MaxLines     = 500
$script:MaxSpecial   = 100
$script:PreambleMax  = 512

function Split-WhoamiLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    $labelPart = if ($Line.Length -ge $script:Grid) { $Line.Substring(0, $script:Grid) } else { $Line }
    $label = $labelPart.TrimEnd()
    if ([string]::IsNullOrEmpty($label)) { return $null }
    $value = if ($Line.Length -gt $script:Grid) { $Line.Substring($script:Grid).TrimStart() } else { '' }
    [pscustomobject]@{ Label = $label; Value = $value }
}

function ConvertFrom-WhoamiReport {
    <#
    .SYNOPSIS
        Parse report text. Throws on a report that breaks its bounds.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)][AllowEmptyString()][string]$Text)

    process {
        if ([string]::IsNullOrEmpty($Text)) { throw 'whoami: empty report' }

        # Bound the preamble read: a device that never sends a newline must not
        # be able to hang the reader, and the preamble's whole value is that
        # the decision is cheap.
        if ($Text.Length -gt $script:PreambleMax) {
            $head = $Text.Substring(0, $script:PreambleMax)
            # Counted with an explicit loop, NOT `(... | Where-Object).Count`.
            # Under Set-StrictMode an empty pipeline result has no .Count, so
            # that form THROWS on the one input this guard exists to stop -- a
            # device sending no newline at all. The bound then fails as a
            # PowerShell error rather than as a refusal, which is a guard that
            # does not guard. Found by the shared corpus, not by reading.
            $newlines = 0
            foreach ($ch in $head.ToCharArray()) {
                if ($ch -eq "`n") { $newlines++ }
            }
            if ($newlines -lt 2) {
                # Worded to name ONE failure. An earlier version said "...before
                # the preamble landed", which is true and still wrong: it
                # contains two classifiable words, so anything matching on text
                # could file a bounds failure as a preamble failure. A
                # diagnostic that can be read two ways gets read the wrong way.
                throw 'whoami: report exceeded its bound (no newline within the first 512 bytes)'
            }
        }

        $lines = $Text -split "`r?`n"
        if ($lines.Count -lt 2) { throw 'whoami: missing or malformed preamble' }

        $first = Split-WhoamiLine $lines[0]
        if ($null -eq $first -or $first.Label -ne 'schema') {
            throw 'whoami: missing or malformed preamble'
        }
        if ($first.Value -notmatch '^\d+\.\d{4}$') {
            # Four digits, zero-padded, always: fixed width is what makes
            # 1.0012 and 1.0002 compare correctly as text.
            throw "whoami: schema value not <major>.<4 digits>: '$($first.Value)'"
        }
        $major, $revision = $first.Value -split '\.'

        $second = Split-WhoamiLine $lines[1]
        if ($null -eq $second -or $second.Label -ne 'speaks') {
            throw 'whoami: missing or malformed preamble'
        }
        $speaks = @($second.Value -split '\s+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })

        $fields  = [ordered]@{}
        $blocks  = 0
        $read    = 2
        $refusal = $true

        for ($i = 2; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $read++
            if ($read -gt $script:MaxLines) { throw 'whoami: report exceeded its line bound' }

            $f = Split-WhoamiLine $line
            if ($null -eq $f) { continue }
            $refusal = $false

            if ($f.Label -eq 'special') {
                # 'special <count> <tag>' -- the count only. Not knowing the
                # tag is the expected case, not an error.
                $countText = ($f.Value -split '\s+')[0]
                if ($countText -notmatch '^\d{1,9}$' -or [int]$countText -gt $script:MaxSpecial) {
                    # An unbounded count from the far end is a request to read
                    # forever. Past the cap it is a malformed report, not an
                    # instruction to obey.
                    throw "whoami: special block count past the bound: '$countText'"
                }
                $i += [int]$countText
                $read += [int]$countText
                $blocks++
                continue
            }
            if (-not $fields.Contains($f.Label)) { $fields[$f.Label] = $f.Value }
        }

        [pscustomobject]@{
            Schema        = $first.Value
            Major         = [int]$major
            Revision      = [int]$revision
            Speaks        = $speaks
            Fields        = $fields
            SpecialBlocks = $blocks
            LinesRead     = $read
            # A refusal is a SUCCESSFUL read: the device answered with the
            # preamble alone, which is what a device that cannot speak the
            # requested major is required to do.
            Refusal       = $refusal
            AppId         = $(if ($fields.Contains('appid')) { $fields['appid'] } else { $null })
        }
    }
}

function Read-WhoamiReport {
    <#
    .SYNOPSIS
        Fetch and parse a report over HTTP or from a serial port.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Http')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Http')][string]$Uri,
        [Parameter(Mandatory, ParameterSetName = 'Serial')][string]$Port,
        [Parameter(ParameterSetName = 'Serial')][int]$Baud = 115200,
        [Parameter(ParameterSetName = 'Serial')][string]$Command = 'whoami',
        [int]$TimeoutSec = 8
    )

    if ($PSCmdlet.ParameterSetName -eq 'Http') {
        $text = (Invoke-WebRequest -Uri $Uri -TimeoutSec $TimeoutSec -UseBasicParsing).Content
        return ConvertFrom-WhoamiReport -Text $text
    }

    $sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
    $sp.ReadTimeout  = $TimeoutSec * 1000
    $sp.NewLine      = "`n"
    try {
        $sp.Open()
        $sp.DiscardInBuffer()
        $sp.WriteLine($Command)
        Start-Sleep -Milliseconds 400
        $raw = $sp.ReadExisting()
        # The board echoes the command it was given; that echo is not part of
        # the report, and leaving it in makes the first line fail to parse.
        $raw = ($raw -split "`r?`n" | Where-Object { $_ -notmatch [regex]::Escape($Command) }) -join "`n"
        ConvertFrom-WhoamiReport -Text $raw
    }
    finally {
        if ($sp.IsOpen) { $sp.Close() }
        $sp.Dispose()
    }
}

Export-ModuleMember -Function Read-WhoamiReport, ConvertFrom-WhoamiReport, Split-WhoamiLine
