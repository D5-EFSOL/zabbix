<#
.SYNOPSIS
  Supermicro SEL hardware-error monitor for Zabbix agent (passive checks).
  Runs IPMICFG-Win.exe -sel list -d 1 and parses ECC / CPU / hardware errors.

.DESCRIPTION
  Compatible with Windows Server 2012+ (PowerShell 3.0+). ASCII-only output.
  Handles BOTH Supermicro SEL output formats (real-world layouts):

    Format 1 (two-line pipe, old BMC):
        468 | 2026/08/25 11:32:52 | Memory
            | Assertion:Correctable ECC@DIMMD1(CPU1)

    Format 2 (block, new BMC), events separated by "----" lines:
        Event:119 Time:2026-02-11 17:40:09 SensorType:BIOS
        | Msg = Memory Error, Failing DIMM: ... (P1-DIMMB1) - Assertion
        --------------------------------------------------------------------

  Modes:
    -Mode discover                       -> LLD JSON  ([{#TYPE},{#LOCATION}] list)
    -Mode summary                        -> JSON summary of error counts by category
    -Mode raw                            -> raw IPMICFG -sel list -d 1 text
    -Mode status                         -> "0" if SEL read OK, "1" if read failed (FFh etc.)
    -Mode count  -Type <t> -Location <l> -> integer count for one type+location
    -Mode detail -Type <t> -Location <l> -> latest error message for one type+location

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File supermicro_sel.ps1 -Mode discover
#>

param(
    [ValidateSet("discover","summary","raw","status","count","detail")]
    [string]$Mode = "summary",
    [string]$Location = "",
    [string]$Type = ""
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# CONFIGURATION
# IPMICFG-Win.exe and its companion *.dat files (the SEL event database) must
# live together: IPMICFG looks up *.dat in its OWN working directory, not in the
# script's location. Deploy supermicro_sel.ps1, IPMICFG-Win.exe and the *.dat
# files side by side, and this script auto-detects IPMICFG next to itself and
# sets its working directory accordingly. This matters because the Zabbix agent
# service runs the script from C:\Windows\System32, where the *.dat are absent.
# ---------------------------------------------------------------------------
$candidates = @(
    (Join-Path $PSScriptRoot "IPMICFG-Win.exe"),
    "C:\Program Files\Zabbix Agent 2\scripts\IPMICFG-Win.exe",
    "C:\Program Files\Zabbix Agent\scripts\IPMICFG-Win.exe",
    "C:\Windows\zabbix-agent\scripts\IPMICFG-Win.exe"
)
$IPMICFG = $null
foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c)) { $IPMICFG = $c; break }
}

# ---------------------------------------------------------------------------
# 1. Run IPMICFG and capture stdout/stderr/exit-code (PS 2.0+ safe, no console
#    encoding issues, works when the agent runs as a service)
# ---------------------------------------------------------------------------
function Invoke-SelRaw {
    param([string]$Days = "1")

    if ($null -eq $IPMICFG -or -not (Test-Path -LiteralPath $IPMICFG)) {
        return @{ ok = $false; code = -1; text = "IPMICFG not found (tried: $($candidates -join '; '))" }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $IPMICFG
    $psi.Arguments              = "-sel list -d $Days"
    $psi.WorkingDirectory       = Split-Path -Parent $IPMICFG
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    try {
        $p      = [System.Diagnostics.Process]::Start($psi)
        $stdout = $p.StandardOutput.ReadToEnd()
        $stderr = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        $text = $stdout + "`n" + $stderr
        return @{ ok = ($p.ExitCode -eq 0); code = $p.ExitCode; text = $text }
    } catch {
        return @{ ok = $false; code = -1; text = "Exception: $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------------------
# 2. Detect a failed SEL read ("Failed to get SEL allocation info, Completion
#    Code=FFh" and similar). FFh = IPMI "unspecified error".
# ---------------------------------------------------------------------------
function Test-SelReadFailed {
    param([string]$Text)
    return ($Text -match '(?i)completion\s*code\s*=|failed to get sel|failed to.*sel|invalid.*command|unable to.*sel')
}

# ---------------------------------------------------------------------------
# 3. Parse raw SEL text into event objects (handles both real output formats)
# ---------------------------------------------------------------------------
function ConvertFrom-SelText {
    param([string]$Text)

    $events = New-Object System.Collections.ArrayList
    $lines  = $Text -split "`r?`n"
    $cur    = $null

    foreach ($ln in $lines) {
        $line = $ln.TrimEnd()

        # Ignore format-2 separator lines ("----...") and blank lines
        if ($line -match '^\s*-{4,}\s*$' -or $line.Trim() -eq '') { continue }

        # --- Format 2 header: "Event:N Time:... Severity:... SensorType:..." ---
        if ($line -match '^\s*Event\s*:\s*\d+') {
            if ($cur -ne $null) { [void]$events.Add($cur) }
            $cur = @{ format = 2; sensor = ""; msg = ""; sev = ""; time = "" }
            # SensorType may be at end of line ("...SensorType:BIOS") or followed by "| Msg=..."
            if     ($line -match 'SensorType\s*:\s*([^|]+?)\s*$')   { $cur.sensor = $Matches[1].Trim() }
            elseif ($line -match 'SensorType\s*:\s*([^|]+?)\s*\|')  { $cur.sensor = $Matches[1].Trim() }
            if ($line -match 'Severity\s*:\s*(\S+)')                { $cur.sev    = $Matches[1].Trim() }
            if ($line -match 'Time\s*:\s*(\S+\s+\S+)')              { $cur.time   = $Matches[1].Trim() }
            if ($line -match 'Msg\s*=\s*(.*)$')                     { $cur.msg    = $Matches[1].Trim() }
            continue
        }

        # --- Format 2 continuation: "| Msg = ...", "Msg = ...", "| text" ---
        if ($cur -ne $null -and $cur.format -eq 2) {
            if     ($line -match '^\s*\|\s*Msg\s*=\s*(.*)$') { $cur.msg = ($cur.msg + " " + $Matches[1]).Trim() }
            elseif ($line -match '^\s*\|\s*(.*)$')           { $cur.msg = ($cur.msg + " " + $Matches[1]).Trim() }
            elseif ($line -match 'Msg\s*=\s*(.*)$')          { $cur.msg = ($cur.msg + " " + $Matches[1]).Trim() }
            continue
        }

        # --- Format 1 header: "ID | yyyy/mm/dd hh:mm:ss | SensorType" ---
        if ($line -match '^\s*\d+\s*\|\s*\d{4}/\d{2}/\d{2}') {
            if ($cur -ne $null) { [void]$events.Add($cur) }
            $parts  = $line -split '\s*\|\s*'
            $sensor = ""; $time = ""
            if ($parts.Count -ge 3) { $sensor = $parts[2].Trim() }
            if ($parts.Count -ge 2) { $time   = $parts[1].Trim() }
            $cur = @{ format = 1; sensor = $sensor; msg = ""; sev = ""; time = $time }
            continue
        }

        # --- Format 1 continuation: "    | Assertion:..." ---
        if ($cur -ne $null -and $cur.format -eq 1) {
            if ($line -match '^\s*\|\s*(.*)$') { $cur.msg = ($cur.msg + " " + $Matches[1]).Trim() }
            continue
        }
    }
    if ($cur -ne $null) { [void]$events.Add($cur) }

    return $events
}

# ---------------------------------------------------------------------------
# 4. Classification
# ---------------------------------------------------------------------------
# Returns "" if the event is not a hardware fault of interest.
function Get-EventType {
    param([string]$Text)

    # Informational / recovery / security events are NOT hardware faults.
    if ($Text -match '(?i)deassert|de-assert|recovered|recovery|link down|link up|boot completed|graceful shutdown|non-critical|invalid username|intrusion|first ac power|power on|session audit') {
        return ""
    }

    if ($Text -match '(?i)memory|dimm|ecc') {
        if ($Text -match '(?i)ecc|error|fail|correctable|uncorrectable|failing|multi-?bit|single-?bit') {
            if ($Text -match '(?i)uncorrectable|multi-?bit|non-?correctable') { return "memory_uncorrectable" }
            return "memory_correctable"
        }
    }
    if ($Text -match '(?i)\bcpu\b|processor|ierr|machine.?check|mce|thermal.?trip|prochot|over.?heat|over.?temp') {
        if ($Text -match '(?i)error|fail|ierr|critical|fatal|thermal|over.?heat|over.?temp|trip|prochot') { return "cpu" }
    }
    if ($Text -match '(?i)\berror\b|fail|critical|fatal|non-?recoverable|uncorrectable|hardware.?fail|fault') {
        return "other"
    }
    return ""
}

# Returns a sanitized location token (safe for item keys / LLD macros).
function Get-EventLocation {
    param([string]$Text)

    if     ($Text -match '@\s*([A-Za-z0-9_\-]+)')            { $loc = $Matches[1] }   # ...ECC@DIMMD1(CPU1)
    elseif ($Text -match '\(\s*([^()]*(?:DIMM|CPU)[^()]*)\s*\)') { $loc = ($Matches[1] -replace '\s+','') } # (P1-DIMMB1), (CPU1)
    elseif ($Text -match '(?i)CPU\s*\d+\s*DIMM\s*[A-Za-z0-9]+') { $loc = $Matches[1] } # CPU 0 DIMM 8
    elseif ($Text -match '(?i)((?:P\d+-)?DIMM\s*[A-Za-z0-9_\-]*\d[A-Za-z0-9_\-]*)') { $loc = $Matches[1] } # DIMMD1, DIMM B2 (slot must contain a digit)
    elseif ($Text -match '(?i)(CPU\s*\d+)')                  { $loc = $Matches[1] }   # CPU1
    else                                                     { $loc = "unknown" }

    $loc = $loc -replace '[^A-Za-z0-9_\-]', '-'
    if ($loc -eq '') { $loc = "unknown" }
    return $loc
}

# ---------------------------------------------------------------------------
# 5. Run + parse + classify into a list of fault events
# ---------------------------------------------------------------------------
function Get-SelFaults {
    $r = Invoke-SelRaw -Days 1

    $failed = (-not $r.ok) -or (Test-SelReadFailed -Text $r.text)
    if ($failed) {
        return @{ readOk = $false; raw = $r.text; events = @() }
    }

    $evs = ConvertFrom-SelText -Text $r.text
    $out = @()
    foreach ($ev in $evs) {
        $text = ($ev.sensor + " " + $ev.msg)
        $t = Get-EventType -Text $text
        if ($t -eq "") { continue }
        $loc = Get-EventLocation -Text $text
        # For "other" faults without a specific DIMM/CPU slot, use the sensor name
        # (e.g. VBAT, Power Supply) so each sensor gets its own de-duplicated trigger.
        if ($loc -eq "unknown" -and $ev.sensor -ne "") {
            $loc = ($ev.sensor -replace '[^A-Za-z0-9_\-]', '-')
        }
        if ($loc -eq "") { $loc = "unknown" }
        $out += [pscustomobject]@{
            type     = $t
            location = $loc
            msg      = $ev.msg
            sensor   = $ev.sensor
            sev      = $ev.sev
            time     = $ev.time
        }
    }
    return @{ readOk = $true; raw = $r.text; events = $out }
}

# ---------------------------------------------------------------------------
# 6. Output per mode
# ---------------------------------------------------------------------------
$data = Get-SelFaults

switch ($Mode) {

    "status" {
        if ($data.readOk) { Write-Output "0" } else { Write-Output "1" }
    }

    "raw" {
        Write-Output $data.raw
    }

    "discover" {
        $arr = @()
        foreach ($g in ($data.events | Group-Object type, location)) {
            $arr += [pscustomobject]@{
                "{#TYPE}"     = $g.Group[0].type
                "{#LOCATION}" = $g.Group[0].location
            }
        }
        Write-Output (([pscustomobject]@{ data = $arr }) | ConvertTo-Json -Compress)
    }

    "summary" {
        $mc  = @($data.events | Where-Object { $_.type -eq "memory_correctable"   }).Count
        $mu  = @($data.events | Where-Object { $_.type -eq "memory_uncorrectable" }).Count
        $cpu = @($data.events | Where-Object { $_.type -eq "cpu"                  }).Count
        $oth = @($data.events | Where-Object { $_.type -eq "other"                }).Count
        $obj = [pscustomobject]@{
            readOk              = $data.readOk
            memory_correctable  = $mc
            memory_uncorrectable = $mu
            cpu                 = $cpu
            other               = $oth
            total               = $mc + $mu + $cpu + $oth
        }
        Write-Output ($obj | ConvertTo-Json -Compress)
    }

    "count" {
        $n = @($data.events | Where-Object { $_.type -eq $Type -and $_.location -eq $Location }).Count
        Write-Output $n
    }

    "detail" {
        $m = $data.events | Where-Object { $_.type -eq $Type -and $_.location -eq $Location } | Select-Object -Last 1
        if ($m) { Write-Output $m.msg } else { Write-Output "" }
    }
}
