#Requires -Version 5.1
<#
.SYNOPSIS
    PS-NETMON - live network dashboard and layered monitor for Windows
    PowerShell 5.1. No modules to install.

.DESCRIPTION
    One script, several modes, so there is one thing to deploy:

        .\PS-NETMON.ps1                  full-screen live dashboard (8 tabs)
        .\PS-NETMON.ps1 -Mode Collect      headless: one probe cycle, append one row, exit
        .\PS-NETMON.ps1 -Mode SpeedTest    headless: one speed test, exit
        .\PS-NETMON.ps1 -Mode Report       headless: write the HTML report, exit
        .\PS-NETMON.ps1 -Mode Install      register the two Scheduled Tasks
        .\PS-NETMON.ps1 -Mode Uninstall    remove them
        .\PS-NETMON.ps1 -Mode Status       print current state and exit

    Separation of concerns, unchanged:
        Collector writes rows. It never charts and never renders.
        Reporter reads rows and writes HTML. If it breaks, the data is safe.
        Dashboard is a VIEWER. It samples live state for the screen and reads
        the collector's files for history, but it never writes a probe row -
        otherwise "is it collecting?" would depend on a window being open.

    The dashboard draws with ANSI escape sequences into a cell buffer and
    issues one write per frame. Windows Terminal is the expected host.

    Every headless run is a fresh process that exits. There is no long-running
    loop: it would die with the session, and a days-long PowerShell process
    leaks memory.

    Keep this file pure ASCII: PowerShell 5.1 reads BOM-less scripts as ANSI.
    Characters that must be non-ASCII (sparkline blocks) are built from
    character codes at runtime.

.PARAMETER Show
    Collect mode: print the row that was written. For testing by hand;
    leave it off in the Scheduled Task.

.PARAMETER Force
    SpeedTest mode: run even if the line looks busy.

.PARAMETER Scheduled
    Set by the Scheduled Tasks. A scheduled speed test keeps the minimum gap
    (SpeedTestMinGapMinutes); a manual one does not.

.PARAMETER Days
    Report mode: how many days back to include. Default 30.
#>
[CmdletBinding()]
param(
    [ValidateSet('Dashboard', 'Collect', 'SpeedTest', 'Report', 'Install', 'Uninstall', 'Status')]
    [string]$Mode = 'Dashboard',

    [string]$ConfigPath,

    [int]$Days = 30,

    [switch]$Show,

    [switch]$Force,

    [switch]$Scheduled
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$script:NetmonVersion = '2.0.0'
$script:ScriptDir     = $PSScriptRoot
$script:ScriptPath    = $PSCommandPath
$script:ScriptName    = 'PS-NETMON.ps1'
if ($PSCommandPath) { $script:ScriptName = Split-Path -Leaf $PSCommandPath }
$script:DataDir       = Join-Path $PSScriptRoot 'data'   # replaced once config loads
$script:Invariant     = [System.Globalization.CultureInfo]::InvariantCulture
$script:Utf8Bom       = New-Object System.Text.UTF8Encoding $true
$script:Utf8NoBom     = New-Object System.Text.UTF8Encoding $false
$script:TaskPath      = '\PS-NETMON\'
$script:TaskCollect   = 'PS-NETMON Collect'
$script:TaskSpeed     = 'PS-NETMON SpeedTest'

# One source of truth for the default config path: a second literal elsewhere
# drifts the moment the product is renamed.
$script:DefaultConfigPath = Join-Path $PSScriptRoot 'PS-NETMON.config.json'
if (-not $ConfigPath) { $ConfigPath = $script:DefaultConfigPath }

# .NET 4.x under PS 5.1 may not offer TLS 1.2 unless asked.
[System.Net.ServicePointManager]::SecurityProtocol =
    [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

#region ---- Time / logging --------------------------------------------------

function Get-Timestamp {
    # ISO 8601 WITH offset. Never write bare local time (Sydney DST).
    param([DateTimeOffset]$When = [DateTimeOffset]::Now)
    $When.ToString("yyyy-MM-dd'T'HH:mm:sszzz", $script:Invariant)
}

function ConvertFrom-Timestamp {
    # Parses our own timestamps back. Returns $null rather than throwing, so
    # one malformed row cannot take down a report over 500k good ones.
    param([string]$Text)
    if (-not $Text) { return $null }
    $dto = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($Text, $script:Invariant,
            [System.Globalization.DateTimeStyles]::None, [ref]$dto)) { return $dto }
    return $null
}

function Write-NetmonLog {
    # Operational log (data\PS-NETMON.log). Must never take the collector down.
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] [{2}] {3}' -f (Get-Timestamp), $Level, $Mode, $Message
    try {
        if (-not (Test-Path -LiteralPath $script:DataDir)) {
            $null = New-Item -ItemType Directory -Path $script:DataDir -Force
        }
        $log = Join-Path $script:DataDir 'PS-NETMON.log'
        [System.IO.File]::AppendAllText($log, $line + "`r`n", $script:Utf8NoBom)
        # Keep the log from growing without bound: trim at 2 MB, keep the tail.
        $fi = New-Object System.IO.FileInfo $log
        if ($fi.Length -gt 2097152) {
            $keep = @(Get-Content -LiteralPath $log -Tail 2000)
            [System.IO.File]::WriteAllText($log, (($keep -join "`r`n") + "`r`n"), $script:Utf8NoBom)
        }
    } catch { }
}

function ConvertTo-Num {
    # CSV comes back as strings. Blank stays blank ($null), never 0 - the
    # difference between "no sample" and "zero milliseconds" matters.
    param($Value)
    if ($null -eq $Value) { return $null }
    $s = ([string]$Value).Trim()
    if (-not $s) { return $null }
    $d = 0.0
    if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float, $script:Invariant, [ref]$d)) { return $d }
    return $null
}

function ConvertTo-Flag {
    param($Value)
    $s = ([string]$Value).Trim()
    return ($s -eq '1' -or $s -eq 'True' -or $s -eq 'true')
}

#endregion
#region ---- Config ----------------------------------------------------------

function Get-DefaultConfig {
    [ordered]@{
        # --- storage ---
        DataDir              = 'data'        # relative to the script, or absolute; %VARS% expanded
        RetentionDays        = 90            # 0 = keep everything
        ReportDir            = 'reports'

        # --- fast probe ---
        ProbeIntervalSeconds = 60
        PingTargets          = @('1.1.1.1', '8.8.8.8', '9.9.9.9')
        PingCount            = 5             # echoes per target per cycle
        PingTimeoutMs        = 1000
        PingGapMs            = 200           # pause between echo rounds

        HopCount             = 2             # 1 = gateway, 2 = ISP edge
        HopSamples           = 2
        HopTimeoutMs         = 1000

        DnsTestDomain        = 'example.com' # queried as <random>.example.com; NXDOMAIN = success
        TcpTestHost          = '1.1.1.1'     # an IP, so this layer does not depend on DNS
        TcpTestPort          = 443
        TcpTimeoutMs         = 3000

        HttpsUrl             = 'https://www.cloudflare.com/cdn-cgi/trace'
        HttpsExpectText      = 'visit_scheme='
        HttpsTimeoutMs       = 5000

        # Live dashboard targets, shown side by side on the Health panel.
        # Separate from PingTargets on purpose: PingTargets feeds the logged
        # series and must stay fixed for history to stay comparable, while
        # these are yours to change whenever you like (press c on the
        # dashboard, or edit them here). Format: address, or address=label.
        LiveTargets          = @('1.1.1.1=Cloudflare', '8.8.8.8=Google', '9.9.9.9=Quad9')
        # Two more columns on the Health panel, yours to point anywhere.
        # Empty means unset. Press c on the dashboard to set or clear them.
        CustomTargets        = @('', '')

        IPv6Targets          = @('2606:4700:4700::1111', '2001:4860:4860::8888')
        IPv6Count            = 3
        IPv6TimeoutMs        = 1000
        CollectIPv6          = $true
        CollectWifi          = $true

        # --- state machine ---
        # Thresholds are deliberately generous until a baseline is learned.
        BaselineWindow       = 1440          # EWMA window, in samples (a day at 60s)
        BaselineMinSamples   = 240           # below this, fall back to the absolute thresholds
        DegradedLatencyMult  = 3.0           # degraded above baseline * this
        DegradedLatencyMinMs = 30            # ...and at least this far above baseline
        DegradedLatencyMs    = 150           # absolute fallback before a baseline exists
        DegradedLossPct      = 2.0
        DegradedJitterMs     = 30
        FailuresToDown       = 3             # consecutive cycles before declaring Down
        SuccessesToUp        = 2             # consecutive cycles before declaring recovered
        SamplesToDegraded    = 2
        CaptureDiagOnDown    = $true
        CaptureDiagOnDegraded = $false
        DiagTracerouteHops   = 12
        DiagTimeoutSeconds   = 30

        # --- speed test ---
        SpeedTestIntervalHours   = 6
        SpeedTestBackend         = 'cloudflare'   # cloudflare | ookla | file
        SpeedTestMaxBusyPct      = 5              # skip if the line is already this busy
        SpeedTestBusySampleMs    = 1000
        SpeedTestDownloadBytes   = 104857600      # 100 MB per download request; streams repeat until time is up
        SpeedTestUploadBytes     = 26214400       # 25 MB per upload request; streams repeat until time is up
        SpeedTestTimeoutMs       = 60000
        SpeedTestMaxSecondsPerDirection = 15      # seconds of transfer per direction
        SpeedTestStreams         = 6              # parallel connections (cloudflare backend)
        SpeedTestMinGapMinutes   = 15             # scheduled runs only; manual runs are not limited
        SpeedTestSkipIfMeteredHint = $true
        CloudflareDownUrl        = 'https://speed.cloudflare.com/__down'
        CloudflareUpUrl          = 'https://speed.cloudflare.com/__up'
        OoklaExePath             = ''             # speedtest.exe; also looked for in tools\ookla
        OoklaServerId            = 0              # 0 = let Ookla pick; else the ID from speedtest.exe -L
        SpeedTestFileUrl         = ''             # 'file' backend: a known-size download

        # --- display ---
        # auto    = braille if the console can encode it, else ascii
        # braille = dot-matrix charts (finest, and the default)
        # blocks  = eighth-block bars, if your font's braille coverage is poor
        # ascii   = plain ramp, no non-ASCII characters at all
        Glyphs               = 'auto'
        RefreshMs            = 500       # full redraw interval; keys stay responsive regardless
        HealthAvgMinutes     = 60        # Health panel average window: 5 min .. 7 days

        # --- report ---
        ReportRawHours       = 24            # raw resolution for this long
        ReportHourlyDays     = 30            # hourly buckets out to here, daily beyond
    }
}

function Import-NetmonConfig {
    # Defaults, overlaid with the JSON file. Keys missing from the file are
    # added and the file rewritten, so new settings appear as the tool grows.
    param([Parameter(Mandatory = $true)][string]$Path)

    $defaults = Get-DefaultConfig
    $cfg = [ordered]@{}
    foreach ($k in $defaults.Keys) { $cfg[$k] = $defaults[$k] }
    $dirty = $true

    if (Test-Path -LiteralPath $Path) {
        $raw = [System.IO.File]::ReadAllText($Path)
        try { $loaded = ConvertFrom-Json -InputObject $raw }
        catch { throw "Config file '$Path' is not valid JSON: $($_.Exception.Message)" }

        $seen = @{}
        foreach ($p in $loaded.PSObject.Properties) {
            $seen[$p.Name] = $true
            $cfg[$p.Name] = $p.Value
            if (-not $defaults.Contains($p.Name)) {
                Write-NetmonLog -Level WARN "Unknown config key '$($p.Name)' in $Path (typo?)"
            }
        }
        $dirty = $false
        foreach ($k in $defaults.Keys) { if (-not $seen.ContainsKey($k)) { $dirty = $true } }
    }

    # $null =, because Save-NetmonConfig returns a success flag and an
    # un-swallowed return value here would be emitted alongside the config
    # itself. The caller would then hold an ARRAY of [bool, config], every
    # lookup into it would come back empty, and the collector would silently
    # write a short row - on the first run, and again after every upgrade that
    # adds a config key. Found exactly that way.
    if ($dirty) { $null = Save-NetmonConfig -Config $cfg -Path $Path }

    Test-NetmonConfig -Config $cfg
    $cfg
}

function Save-NetmonConfig {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)][string]$Path)
    try {
        $json = ConvertTo-Json -InputObject $Config -Depth 5
        [System.IO.File]::WriteAllText($Path, $json, $script:Utf8NoBom)
        Write-NetmonLog "Wrote config: $Path"
        return $true
    } catch {
        Write-NetmonLog -Level WARN "Could not write config '$Path': $($_.Exception.Message)"
        return $false
    }
}

function Test-NetmonConfig {
    param([Parameter(Mandatory = $true)]$Config)

    $intKeys = 'RetentionDays', 'ProbeIntervalSeconds', 'PingCount', 'PingTimeoutMs', 'PingGapMs',
               'HopCount', 'HopSamples', 'HopTimeoutMs', 'TcpTestPort', 'TcpTimeoutMs', 'HttpsTimeoutMs',
               'IPv6Count', 'IPv6TimeoutMs', 'BaselineWindow', 'BaselineMinSamples',
               'FailuresToDown', 'SuccessesToUp', 'SamplesToDegraded',
               'DiagTracerouteHops', 'DiagTimeoutSeconds',
               'SpeedTestIntervalHours', 'SpeedTestBusySampleMs', 'SpeedTestDownloadBytes',
               'SpeedTestUploadBytes', 'SpeedTestTimeoutMs', 'SpeedTestMaxSecondsPerDirection',
               'SpeedTestStreams', 'SpeedTestMinGapMinutes', 'OoklaServerId',
               'RefreshMs', 'ReportRawHours', 'ReportHourlyDays', 'HealthAvgMinutes'
    foreach ($k in $intKeys) {
        $v = 0
        if (-not [int]::TryParse([string]$Config[$k], [ref]$v) -or $v -lt 0) {
            throw "Config '$k' must be a non-negative whole number (got '$($Config[$k])')."
        }
        $Config[$k] = $v
    }

    $numKeys = 'DegradedLatencyMult', 'DegradedLatencyMinMs', 'DegradedLatencyMs',
               'DegradedLossPct', 'DegradedJitterMs', 'SpeedTestMaxBusyPct'
    foreach ($k in $numKeys) {
        $d = 0.0
        if (-not [double]::TryParse([string]$Config[$k], [System.Globalization.NumberStyles]::Float,
                $script:Invariant, [ref]$d) -or $d -lt 0) {
            throw "Config '$k' must be a non-negative number (got '$($Config[$k])')."
        }
        $Config[$k] = $d
    }

    foreach ($k in 'CollectIPv6', 'CollectWifi', 'CaptureDiagOnDown', 'CaptureDiagOnDegraded',
                   'SpeedTestSkipIfMeteredHint') {
        $Config[$k] = [bool]$Config[$k]
    }

    if ($Config['PingCount'] -lt 1) { throw "Config 'PingCount' must be at least 1." }
    if ($Config['HopCount'] -gt 8) { throw "Config 'HopCount' above 8 is not useful here; use tracert for a full path." }
    foreach ($k in 'FailuresToDown', 'SuccessesToUp', 'SamplesToDegraded') {
        if ($Config[$k] -lt 1) { throw "Config '$k' must be at least 1." }
    }
    if ($Config['BaselineWindow'] -lt 10) { throw "Config 'BaselineWindow' must be at least 10." }
    # Per-request sizes, not totals (each test runs for a fixed time). Small
    # upload requests leave a gap per request and read low, so older configs
    # with 8 MB are raised.
    if ($Config['SpeedTestUploadBytes'] -lt 26214400) { $Config['SpeedTestUploadBytes'] = 26214400 }
    if ($Config['SpeedTestDownloadBytes'] -lt 26214400) { $Config['SpeedTestDownloadBytes'] = 26214400 }
    if ($Config['SpeedTestStreams'] -lt 1) { $Config['SpeedTestStreams'] = 1 }
    if ($Config['SpeedTestStreams'] -gt 16) { $Config['SpeedTestStreams'] = 16 }
    if ($Config['SpeedTestMaxSecondsPerDirection'] -lt 5) { $Config['SpeedTestMaxSecondsPerDirection'] = 5 }
    if ($Config['HealthAvgMinutes'] -lt 5) { $Config['HealthAvgMinutes'] = 5 }
    if ($Config['HealthAvgMinutes'] -gt 10080) { $Config['HealthAvgMinutes'] = 10080 }
    if ($Config['RefreshMs'] -lt 100) { $Config['RefreshMs'] = 100 }
    if ($Config['RefreshMs'] -gt 5000) { $Config['RefreshMs'] = 5000 }

    $glyphs = ([string]$Config['Glyphs']).ToLowerInvariant()
    if ('auto', 'braille', 'blocks', 'ascii' -notcontains $glyphs) {
        throw "Config 'Glyphs' must be auto, braille, blocks or ascii (got '$glyphs')."
    }
    $Config['Glyphs'] = $glyphs

    $backend = ([string]$Config['SpeedTestBackend']).ToLowerInvariant()
    if ('cloudflare', 'ookla', 'file' -notcontains $backend) {
        throw "Config 'SpeedTestBackend' must be cloudflare, ookla or file (got '$backend')."
    }
    $Config['SpeedTestBackend'] = $backend

    $targets = @($Config['PingTargets'] | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })
    if ($targets.Count -lt 1) { throw "Config 'PingTargets' needs at least one address." }
    foreach ($t in $targets) {
        $ip = $null
        if (-not [System.Net.IPAddress]::TryParse($t, [ref]$ip)) {
            throw "Config 'PingTargets': '$t' is not an IP address. Use IPs so this layer does not depend on DNS."
        }
    }
    $Config['PingTargets'] = $targets

    $live = @($Config['LiveTargets'] | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })
    if ($live.Count -lt 1) { $live = @('1.1.1.1=Cloudflare') }
    if ($live.Count -gt 3) { $live = $live[0..2] }   # three fixed columns on the Health panel
    foreach ($t in $live) {
        $addr = ($t -split '=')[0].Trim()
        $ip = $null
        if (-not [System.Net.IPAddress]::TryParse($addr, [ref]$ip)) {
            throw "Config 'LiveTargets': '$addr' is not an IP address. Use addresses, not names, so this panel does not depend on DNS."
        }
    }
    $Config['LiveTargets'] = $live

    # Exactly two custom slots, positions preserved: an empty first slot must
    # stay the first slot, so empties are kept rather than filtered out.
    $custom = @($Config['CustomTargets'])
    $norm = @('', '')
    for ($ci = 0; $ci -lt [math]::Min(2, $custom.Count); $ci++) {
        $t = ([string]$custom[$ci]).Trim()
        if ($t) {
            $addr = ($t -split '=')[0].Trim()
            $ip = $null
            if (-not [System.Net.IPAddress]::TryParse($addr, [ref]$ip)) {
                throw "Config 'CustomTargets': '$addr' is not an IP address."
            }
        }
        $norm[$ci] = $t
    }
    $Config['CustomTargets'] = $norm

    $v6 = @($Config['IPv6Targets'] | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })
    foreach ($t in $v6) {
        $ip = $null
        if (-not [System.Net.IPAddress]::TryParse($t, [ref]$ip)) { throw "Config 'IPv6Targets': '$t' is not an IP address." }
    }
    $Config['IPv6Targets'] = $v6
    if ($v6.Count -lt 1) { $Config['CollectIPv6'] = $false }

    if ($Config['ProbeIntervalSeconds'] -lt 15) {
        Write-NetmonLog -Level WARN "ProbeIntervalSeconds=$($Config['ProbeIntervalSeconds']) is very short."
    }

    # Rough worst case when every layer times out. Hops and IPv6 run in
    # sequence, so they count in full.
    $worstMs = $Config['PingCount'] * ($Config['PingTimeoutMs'] + $Config['PingGapMs']) +
               $Config['HopCount'] * $Config['HopSamples'] * $Config['HopTimeoutMs'] +
               10000 + $Config['TcpTimeoutMs'] + $Config['HttpsTimeoutMs'] + 2000
    if ($Config['CollectIPv6']) { $worstMs += $Config['IPv6Count'] * $Config['IPv6TimeoutMs'] }
    if ($worstMs -ge $Config['ProbeIntervalSeconds'] * 1000) {
        Write-NetmonLog -Level WARN ("Worst-case cycle (~{0}s) is not shorter than ProbeIntervalSeconds ({1}s). " +
            "Runs may overlap; reduce PingCount or timeouts." -f [math]::Round($worstMs / 1000), $Config['ProbeIntervalSeconds'])
    }
}

function Get-KnownTargetName {
    # A name for well-known public resolvers, so a target written without a
    # label ("9.9.9.9" rather than "9.9.9.9=Quad9") still gets one.
    param([string]$Address)
    $known = @{
        '1.1.1.1' = 'Cloudflare'; '1.0.0.1' = 'Cloudflare'; '1.1.1.2' = 'Cloudflare'; '1.1.1.3' = 'Cloudflare'
        '8.8.8.8' = 'Google'; '8.8.4.4' = 'Google'
        '9.9.9.9' = 'Quad9'; '149.112.112.112' = 'Quad9'; '9.9.9.10' = 'Quad9'; '9.9.9.11' = 'Quad9'
        '208.67.222.222' = 'OpenDNS'; '208.67.220.220' = 'OpenDNS'
        '4.2.2.1' = 'Level3'; '4.2.2.2' = 'Level3'
        '94.140.14.14' = 'AdGuard'; '94.140.15.15' = 'AdGuard'
        '76.76.2.0' = 'Control D'; '185.228.168.9' = 'CleanBrowsing'
        '2606:4700:4700::1111' = 'Cloudflare'; '2001:4860:4860::8888' = 'Google'; '2620:fe::fe' = 'Quad9'
    }
    if ($known.ContainsKey($Address)) { return $known[$Address] }
    return ''
}

function Get-LiveTargets {
    # 'address' or 'address=label' -> objects. The label is cosmetic; the
    # address is what gets pinged.
    param([Parameter(Mandatory = $true)]$Config)
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($t in @($Config['LiveTargets'])) {
        $parts = ([string]$t) -split '=', 2
        $addr = $parts[0].Trim()
        $label = ''
        if ($parts.Count -gt 1) { $label = $parts[1].Trim() }
        if (-not $label -and $addr) { $label = Get-KnownTargetName -Address $addr }
        $out.Add((New-Object PSObject -Property ([ordered]@{ Address = $addr; Label = $label })))
    }
    $out.ToArray()
}

function Get-CustomTargets {
    # Always two slots. Address is '' for an unset slot.
    param([Parameter(Mandatory = $true)]$Config)
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($t in @($Config['CustomTargets'])) {
        $parts = ([string]$t) -split '=', 2
        $addr = $parts[0].Trim()
        $label = ''
        if ($parts.Count -gt 1) { $label = $parts[1].Trim() }
        if (-not $label -and $addr) { $label = Get-KnownTargetName -Address $addr }
        $out.Add((New-Object PSObject -Property ([ordered]@{ Address = $addr; Label = $label })))
    }
    while ($out.Count -lt 2) {
        $out.Add((New-Object PSObject -Property ([ordered]@{ Address = ''; Label = '' })))
    }
    $out.ToArray()
}

function Set-DataDir {
    param([Parameter(Mandatory = $true)]$Config)
    $dd = [Environment]::ExpandEnvironmentVariables([string]$Config['DataDir'])
    if (-not $dd) { $dd = 'data' }
    if (-not [System.IO.Path]::IsPathRooted($dd)) { $dd = Join-Path $script:ScriptDir $dd }
    $script:DataDir = $dd
    if (-not (Test-Path -LiteralPath $dd)) { $null = New-Item -ItemType Directory -Path $dd -Force }
}

function Get-ReportDir {
    param([Parameter(Mandatory = $true)]$Config)
    $rd = [Environment]::ExpandEnvironmentVariables([string]$Config['ReportDir'])
    if (-not $rd) { $rd = 'reports' }
    if (-not [System.IO.Path]::IsPathRooted($rd)) { $rd = Join-Path $script:ScriptDir $rd }
    if (-not (Test-Path -LiteralPath $rd)) { $null = New-Item -ItemType Directory -Path $rd -Force }
    $rd
}

#endregion
#region ---- State (carried between runs) ------------------------------------

# Each headless run is a fresh process, so anything that needs the previous run
# - byte counters for throughput, the learned baseline, the hysteresis counters
# - lives in data\state.json.

function Get-NetmonState {
    $path = Join-Path $script:DataDir 'state.json'
    if (-not (Test-Path -LiteralPath $path)) { return @{} }
    try {
        $obj = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path))
        return (ConvertTo-Hashtable -Object $obj)
    } catch {
        Write-NetmonLog -Level WARN "state.json unreadable, starting fresh: $($_.Exception.Message)"
        return @{}
    }
}

function ConvertTo-Hashtable {
    # ConvertFrom-Json gives PSCustomObjects; nested hashtables are easier to
    # mutate and round-trip.
    param($Object)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable -Object $p.Value }
        return $h
    }
    return $Object
}

function Save-NetmonState {
    param([Parameter(Mandatory = $true)]$State)
    $path = Join-Path $script:DataDir 'state.json'
    try {
        # Write-then-replace, so a crash mid-write cannot leave a truncated file.
        $tmp = $path + '.tmp'
        [System.IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $State -Depth 8), $script:Utf8NoBom)
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } catch {
        Write-NetmonLog -Level WARN "Could not save state: $($_.Exception.Message)"
    }
}

#endregion
#region ---- Retention -------------------------------------------------------

function Remove-OldData {
    # Deletes PS-NETMON's own CSVs and diagnostic dumps older than RetentionDays.
    # Once a day at most, and only files matching our own naming - never a
    # blanket wildcard delete in a folder a user might have put things in.
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$State,
          [Parameter(Mandatory = $true)][DateTimeOffset]$Now)

    $days = [int]$Config['RetentionDays']
    if ($days -le 0) { return }

    $today = $Now.ToString('yyyy-MM-dd', $script:Invariant)
    if ($State.ContainsKey('LastPruneDate') -and [string]$State['LastPruneDate'] -eq $today) { return }
    $State['LastPruneDate'] = $today

    $cutoff = $Now.Date.AddDays(-$days)
    $removed = 0
    try {
        $rx = '^(probe|speedtest|events)_(\d{4}-\d{2}-\d{2})(_v\d+)?\.csv$'
        foreach ($f in @(Get-ChildItem -LiteralPath $script:DataDir -Filter '*.csv' -File -ErrorAction SilentlyContinue)) {
            $m = [regex]::Match($f.Name, $rx)
            if (-not $m.Success) { continue }
            $d = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($m.Groups[2].Value, 'yyyy-MM-dd', $script:Invariant,
                    [System.Globalization.DateTimeStyles]::None, [ref]$d)) { continue }
            if ($d -lt $cutoff) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; $removed++ }
        }
        $diagDir = Join-Path $script:DataDir 'diag'
        if (Test-Path -LiteralPath $diagDir) {
            foreach ($f in @(Get-ChildItem -LiteralPath $diagDir -Filter 'diag_*.txt' -File -ErrorAction SilentlyContinue)) {
                if ($f.LastWriteTime -lt $cutoff) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; $removed++ }
            }
        }
    } catch { }
    if ($removed -gt 0) { Write-NetmonLog "Retention: removed $removed file(s) older than $days days." }
}

#endregion
#region ---- CSV writer ------------------------------------------------------

function ConvertTo-CsvField {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { if ($Value) { return '1' } else { return '0' } }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        $s = $Value.ToString('0.###', $script:Invariant)
    } else {
        $s = [string]$Value
    }
    if ($s -match '[",\r\n]') { $s = '"' + $s.Replace('"', '""') + '"' }
    $s
}

function Get-FirstLine {
    # Read the header without fighting whoever else has the file open.
    param([Parameter(Mandatory = $true)][string]$Path)
    $fs = $null; $sr = $null
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open,
                                              [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, $script:Utf8NoBom, $true)
        return $sr.ReadLine()
    } finally {
        if ($sr) { $sr.Dispose() } elseif ($fs) { $fs.Dispose() }
    }
}

function Write-CsvLine {
    # Append with retries. If the file stays locked (typically: open in Excel),
    # park the row in <file>.pending; the next run flushes it back in order.
    param([string]$Path, [string]$Line)
    for ($try = 1; $try -le 5; $try++) {
        try {
            [System.IO.File]::AppendAllText($Path, $Line + "`r`n", $script:Utf8NoBom)
            return
        } catch {
            Start-Sleep -Milliseconds (300 * $try)
        }
    }
    [System.IO.File]::AppendAllText($Path + '.pending', $Line + "`r`n", $script:Utf8NoBom)
    Write-NetmonLog -Level WARN "$(Split-Path -Leaf $Path) is locked (open in Excel?). Row parked in .pending."
}

function Sync-PendingRows {
    $pending = @(Get-ChildItem -LiteralPath $script:DataDir -Filter '*.csv.pending' -ErrorAction SilentlyContinue)
    foreach ($p in $pending) {
        $target = $p.FullName.Substring(0, $p.FullName.Length - '.pending'.Length)
        try {
            $text = [System.IO.File]::ReadAllText($p.FullName)
            [System.IO.File]::AppendAllText($target, $text, $script:Utf8NoBom)
            Remove-Item -LiteralPath $p.FullName -Force
            Write-NetmonLog "Flushed parked rows into $(Split-Path -Leaf $target)"
        } catch { }
    }
}

function Add-CsvRow {
    # <kind>_yyyy-MM-dd.csv in DataDir. Header written once, then appended.
    # If today's file has a different header (columns added by a newer
    # version), write to <kind>_yyyy-MM-dd_v2.csv etc. rather than misalign.
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][DateTimeOffset]$When
    )
    if (-not (Test-Path -LiteralPath $script:DataDir)) {
        $null = New-Item -ItemType Directory -Path $script:DataDir -Force
    }
    Sync-PendingRows

    $hdr = foreach ($k in $Row.Keys) { ConvertTo-CsvField $k }
    $val = foreach ($k in $Row.Keys) { ConvertTo-CsvField $Row[$k] }
    $header = $hdr -join ','
    $line   = $val -join ','
    $date   = $When.ToString('yyyy-MM-dd', $script:Invariant)

    for ($n = 1; $n -le 50; $n++) {
        if ($n -eq 1) { $name = '{0}_{1}.csv' -f $Kind, $date }
        else          { $name = '{0}_{1}_v{2}.csv' -f $Kind, $date, $n }
        $path = Join-Path $script:DataDir $name

        if (-not (Test-Path -LiteralPath $path)) {
            # BOM on creation so Excel reads it as UTF-8.
            [System.IO.File]::WriteAllText($path, $header + "`r`n" + $line + "`r`n", $script:Utf8Bom)
            return $path
        }

        $first = $null
        try { $first = Get-FirstLine -Path $path }
        catch {
            # Can't even read it: assume it's ours and let Write-CsvLine park the row.
            Write-CsvLine -Path $path -Line $line
            return $path
        }
        if ($first -eq $header) {
            Write-CsvLine -Path $path -Line $line
            return $path
        }
    }
    throw "Could not find a CSV file for '$Kind' on $date with a matching header."
}

#endregion
#region ---- CSV reader ------------------------------------------------------

function Get-DataFiles {
    # PS-NETMON's own files of one kind, oldest first, optionally from a date on.
    param([Parameter(Mandatory = $true)][string]$Kind, [datetime]$Since = [datetime]::MinValue)
    $rx = '^' + [regex]::Escape($Kind) + '_(\d{4}-\d{2}-\d{2})(_v\d+)?\.csv$'
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($f in @(Get-ChildItem -LiteralPath $script:DataDir -Filter "$Kind*.csv" -File -ErrorAction SilentlyContinue)) {
        $m = [regex]::Match($f.Name, $rx)
        if (-not $m.Success) { continue }
        $d = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($m.Groups[1].Value, 'yyyy-MM-dd', $script:Invariant,
                [System.Globalization.DateTimeStyles]::None, [ref]$d)) { continue }
        if ($d.Date -lt $Since.Date) { continue }
        $out.Add((New-Object PSObject -Property ([ordered]@{ Date = $d; Path = $f.FullName; Name = $f.Name })))
    }
    # No comma-wrap on the return: it makes @(Get-DataFiles ...) collapse to
    # a single element at the call site, which is a silent, nasty bug.
    @($out | Sort-Object Date, Name)
}

function Import-DataRows {
    # Reads rows of one kind across files. Import-Csv is used rather than a
    # hand parser so quoted fields behave; a file that fails to parse is
    # skipped with a warning rather than aborting the whole report.
    param([Parameter(Mandatory = $true)][string]$Kind, [datetime]$Since = [datetime]::MinValue)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($f in (Get-DataFiles -Kind $Kind -Since $Since)) {
        try {
            foreach ($r in @(Import-Csv -LiteralPath $f.Path)) { $rows.Add($r) }
        } catch {
            Write-NetmonLog -Level WARN "Could not read $($f.Name): $($_.Exception.Message)"
        }
    }
    # ToArray, not @(...): wrapping a generic list of dictionaries in @() can
    # fail outright. No comma-wrap either - see Get-DataFiles.
    $rows.ToArray()
}

function Get-LatestDataFile {
    param([Parameter(Mandatory = $true)][string]$Kind)
    $files = @(Get-DataFiles -Kind $Kind)
    if ($files.Count -lt 1) { return $null }
    $files[$files.Count - 1].Path
}

function Get-TailRows {
    # Tail of the newest file only. The TUI must not read a year of rows to
    # draw a sparkline.
    param([Parameter(Mandatory = $true)][string]$Kind, [int]$Count = 200)
    $path = Get-LatestDataFile -Kind $Kind
    if (-not $path) { return @() }
    try {
        $header = Get-FirstLine -Path $path
        if (-not $header) { return @() }
        $tail = @(Get-Content -LiteralPath $path -Tail $Count -ErrorAction Stop)
        $body = @($tail | Where-Object { $_ -and $_ -ne $header })
        if ($body.Count -lt 1) { return @() }
        return @(ConvertFrom-Csv -InputObject (@($header) + $body))
    } catch {
        return @()
    }
}

#endregion
#region ---- Probes: latency -------------------------------------------------

function Get-PingStats {
    param($Samples, [int]$Sent)
    $s = [ordered]@{ sent = $Sent; loss_pct = $null; min_ms = $null; avg_ms = $null; max_ms = $null; sd_ms = $null }
    $n = 0; $sum = 0.0; $min = [double]::MaxValue; $max = [double]::MinValue
    foreach ($x in $Samples) {
        $n++; $sum += $x
        if ($x -lt $min) { $min = $x }
        if ($x -gt $max) { $max = $x }
    }
    if ($Sent -gt 0) { $s['loss_pct'] = [math]::Round(100.0 * ($Sent - $n) / $Sent, 1) }
    if ($n -gt 0) {
        $avg = $sum / $n
        $sq = 0.0
        foreach ($x in $Samples) { $sq += ($x - $avg) * ($x - $avg) }
        $s['min_ms'] = $min
        $s['avg_ms'] = [math]::Round($avg, 1)
        $s['max_ms'] = $max
        $s['sd_ms']  = [math]::Round([math]::Sqrt($sq / $n), 1)   # jitter
    }
    $s
}

function Invoke-PingSet {
    # Pings every target concurrently, $Count rounds. Returns one stats
    # dictionary per target, in the same order as $Targets.
    param([string[]]$Targets, [int]$Count, [int]$TimeoutMs, [int]$GapMs)

    $n = $Targets.Count
    $samples = New-Object 'object[]' $n
    for ($i = 0; $i -lt $n; $i++) { $samples[$i] = New-Object 'System.Collections.Generic.List[double]' }

    for ($round = 0; $round -lt $Count; $round++) {
        $pingers = New-Object 'object[]' $n
        $tasks   = New-Object 'object[]' $n
        for ($i = 0; $i -lt $n; $i++) {
            try {
                $pingers[$i] = New-Object System.Net.NetworkInformation.Ping
                $tasks[$i]   = $pingers[$i].SendPingAsync($Targets[$i], $TimeoutMs)
            } catch { $tasks[$i] = $null }
        }

        $live = @($tasks | Where-Object { $null -ne $_ })
        if ($live.Count -gt 0) {
            # Throws AggregateException if any ping faulted; we inspect each task below.
            try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$live, $TimeoutMs + 2000) } catch { }
        }

        for ($i = 0; $i -lt $n; $i++) {
            $t = $tasks[$i]
            if ($null -ne $t -and $t.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
                $reply = $t.Result
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $samples[$i].Add([double]$reply.RoundtripTime)
                }
            }
            if ($null -ne $pingers[$i]) { try { $pingers[$i].Dispose() } catch { } }
        }

        if ($round -lt $Count - 1 -and $GapMs -gt 0) { Start-Sleep -Milliseconds $GapMs }
    }

    for ($i = 0; $i -lt $n; $i++) { Get-PingStats -Samples $samples[$i] -Sent $Count }
}

function Get-HopLatency {
    # First hops via TTL-limited echo, not tracert.exe: no process spawn, no
    # 30-hop wait, and the numbers land in the same row as everything else.
    # Hop 1 is normally the gateway; hop 2 is the ISP edge, which is the one
    # that matters in an ISP conversation.
    # A hop that does not answer is not a fault - many routers drop TTL-expired
    # ICMP or rate-limit it - so a blank here means "no answer", not "down".
    param([string]$Target, [int]$Hops, [int]$Samples, [int]$TimeoutMs)

    $buffer = New-Object byte[] 32
    $out = New-Object 'System.Collections.Generic.List[object]'

    for ($ttl = 1; $ttl -le $Hops; $ttl++) {
        $addr = ''
        $best = $null
        $opts = New-Object System.Net.NetworkInformation.PingOptions($ttl, $false)
        for ($s = 0; $s -lt $Samples; $s++) {
            $p = $null
            try {
                $p = New-Object System.Net.NetworkInformation.Ping
                $r = $p.Send($Target, $TimeoutMs, $buffer, $opts)
                $st = $r.Status
                if ($st -eq [System.Net.NetworkInformation.IPStatus]::TtlExpired -or
                    $st -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    if (-not $addr -and $r.Address) { $addr = $r.Address.ToString() }
                    $rtt = [double]$r.RoundtripTime
                    if ($null -eq $best -or $rtt -lt $best) { $best = $rtt }
                }
            } catch {
            } finally {
                if ($p) { try { $p.Dispose() } catch { } }
            }
        }
        $out.Add((New-Object PSObject -Property ([ordered]@{ Ttl = $ttl; Address = $addr; Ms = $best })))
    }
    $out.ToArray()
}

#endregion
#region ---- Probes: route / adapter / DNS servers ---------------------------

function Get-PrimaryRoute {
    # The route Windows would actually use to reach $Probe right now.
    param([Parameter(Mandatory = $true)][string]$Probe)
    $found = @(Find-NetRoute -RemoteIPAddress $Probe -ErrorAction Stop)
    $route = $null; $addr = $null
    foreach ($o in $found) {
        $cls = $o.CimClass.CimClassName
        if ($cls -eq 'MSFT_NetRoute' -and -not $route) { $route = $o }
        elseif ($cls -eq 'MSFT_NetIPAddress' -and -not $addr) { $addr = $o }
    }
    if (-not $route) { return $null }

    $gw = [string]$route.NextHop
    if ($gw -eq '0.0.0.0' -or $gw -eq '::') { $gw = '' }   # on-link, no gateway
    $ip = ''
    if ($addr) { $ip = [string]$addr.IPAddress }
    New-Object PSObject -Property ([ordered]@{
        Gateway = $gw
        IfIndex = [int]$route.InterfaceIndex
        IfAlias = [string]$route.InterfaceAlias
        LocalIP = $ip
    })
}

function Get-AdapterInfo {
    # Link speed and duplex catch a NIC that renegotiated to 100Mb half.
    param([int]$IfIndex)
    $info = [ordered]@{
        adapter_desc = ''; adapter_mac = ''; adapter_status = ''
        link_speed   = ''; link_bps = $null; duplex = ''
        adapter_name = ''
    }
    $a = Get-NetAdapter -InterfaceIndex $IfIndex -ErrorAction Stop
    $info['adapter_name']   = [string]$a.Name
    $info['adapter_desc']   = [string]$a.InterfaceDescription
    $info['adapter_mac']    = [string]$a.MacAddress
    $info['adapter_status'] = [string]$a.Status
    $info['link_speed']     = [string]$a.LinkSpeed          # human form, e.g. "1 Gbps"
    try { $info['link_bps'] = [double]$a.Speed } catch { }  # machine form, for utilisation
    try {
        if ($a.FullDuplex -eq $true) { $info['duplex'] = 'full' }
        elseif ($a.FullDuplex -eq $false) { $info['duplex'] = 'half' }
    } catch { }
    $info
}

function Get-GatewayMac {
    # Changes when the router is swapped, or when something else starts
    # answering for the gateway address.
    param([string]$Gateway, [int]$IfIndex)
    if (-not $Gateway) { return '' }
    $n = @(Get-NetNeighbor -IPAddress $Gateway -InterfaceIndex $IfIndex -ErrorAction Stop |
           Where-Object { $_.LinkLayerAddress -and $_.State -ne 'Unreachable' })
    if ($n.Count -lt 1) { return '' }
    [string]$n[0].LinkLayerAddress
}

function Get-DnsServersInUse {
    # Detects a DHCP change that quietly repointed the machine's resolvers.
    param([int]$IfIndex)
    $s = @(Get-DnsClientServerAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -ErrorAction Stop)
    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($e in $s) { foreach ($a in @($e.ServerAddresses)) { if ($a) { [void]$list.Add([string]$a) } } }
    $list -join ';'
}

#endregion
#region ---- Probes: DNS / TCP / HTTPS ---------------------------------------

function Test-DnsLayer {
    # Uncacheable name, so the query really leaves the machine.
    # NXDOMAIN is SUCCESS: we test that the resolver answers, not what it says.
    # An A record for a name that cannot exist means something is synthesising
    # replies (ISP NXDOMAIN hijacking, a filtering resolver, a captive portal):
    # dns_hijack flags it and dns_answer records the evidence.
    param([Parameter(Mandatory = $true)][string]$Domain)
    $name = 'nm-{0}.{1}' -f [guid]::NewGuid().ToString('N').Substring(0, 12), $Domain
    $ok = $true; $result = 'answer'; $answer = ''; $hijack = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $rec = @(Resolve-DnsName -Name $name -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop)
        $ips = New-Object 'System.Collections.Generic.List[string]'
        foreach ($r in $rec) {
            try { if ($r.IPAddress) { [void]$ips.Add([string]$r.IPAddress) } } catch { }
        }
        $answer = $ips -join ';'
        if ($ips.Count -gt 0) { $hijack = $true }
        else { $result = 'nodata' }
    } catch {
        $code = 0
        if ($_.Exception -is [System.ComponentModel.Win32Exception]) { $code = $_.Exception.NativeErrorCode }
        $fqid = [string]$_.FullyQualifiedErrorId
        if ($code -eq 9003 -or $fqid -like 'DNS_ERROR_RCODE_NAME_ERROR*') { $result = 'nxdomain' }
        elseif ($code -eq 9501 -or $fqid -like 'DNS_INFO_NO_RECORDS*') { $result = 'nodata' }
        else {
            $ok = $false
            $result = ($fqid -split ',')[0]
            if (-not $result) { $result = $_.Exception.Message }
        }
    }
    $sw.Stop()
    [ordered]@{
        dns_ok     = $ok
        dns_ms     = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        dns_result = $result
        dns_answer = $answer
        dns_hijack = $hijack
    }
}

function Test-TcpLayer {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs)   # not $Host: that's reserved
    $client = New-Object System.Net.Sockets.TcpClient
    $ok = $false; $err = ''
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $task = $client.ConnectAsync($TargetHost, $Port)
        if ($task.Wait($TimeoutMs)) { $ok = $client.Connected } else { $err = 'timeout' }
    } catch {
        $err = $_.Exception.GetBaseException().Message
    } finally {
        $sw.Stop()
        try { $client.Close() } catch { }
    }
    $ms = $null
    if ($ok) { $ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) }
    [ordered]@{ tcp_ok = $ok; tcp_ms = $ms; tcp_err = $err }
}

function Test-HttpsLayer {
    # Full GET, cache-busted, no redirects followed (a captive portal redirects).
    # If the endpoint is a cdn-cgi/trace-style body, the public IP and the
    # edge location come out of this same response - no second request, and
    # so no extra traffic just to learn our own address.
    param([string]$Url, [string]$Expect, [int]$TimeoutMs)
    $sep = '?'
    if ($Url.Contains('?')) { $sep = '&' }
    $u = '{0}{1}nm={2}' -f $Url, $sep, [guid]::NewGuid().ToString('N')

    $ok = $false; $status = $null; $err = ''; $publicIp = ''; $colo = ''
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($u)
        $req.Method            = 'GET'
        $req.Timeout           = $TimeoutMs
        $req.ReadWriteTimeout  = $TimeoutMs
        $req.KeepAlive         = $false
        $req.AllowAutoRedirect = $false
        $req.UserAgent         = "PS-NETMON/$script:NetmonVersion"
        $req.CachePolicy       = New-Object System.Net.Cache.RequestCachePolicy ([System.Net.Cache.RequestCacheLevel]::NoCacheNoStore)
        $req.Headers.Add('Cache-Control', 'no-cache')
        $req.Headers.Add('Pragma', 'no-cache')

        $resp   = $req.GetResponse()
        $status = [int]$resp.StatusCode
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $body   = $reader.ReadToEnd()
        $reader.Dispose()

        if ($status -ge 300 -and $status -lt 400) {
            $err = 'redirect to ' + [string]$resp.Headers['Location']
        } elseif ($status -ge 200 -and $status -lt 300) {
            if ($Expect -and -not $body.Contains($Expect)) { $err = 'unexpected content (captive portal?)' }
            else { $ok = $true }
        } else {
            $err = "HTTP $status"
        }

        if ($body) {
            $m = [regex]::Match($body, '(?m)^ip=(\S+)\s*$')
            if ($m.Success) { $publicIp = $m.Groups[1].Value }
            $m = [regex]::Match($body, '(?m)^colo=(\S+)\s*$')
            if ($m.Success) { $colo = $m.Groups[1].Value }
        }
    } catch {
        $e = $_.Exception
        while ($e -and -not ($e -is [System.Net.WebException])) { $e = $e.InnerException }
        if ($e) {
            if ($e.Response) { $status = [int]$e.Response.StatusCode; $e.Response.Close() }
            $err = [string]$e.Status
            if ($e.Status -eq [System.Net.WebExceptionStatus]::TrustFailure) { $err = 'TrustFailure (cert invalid: interception or captive portal?)' }
        } else {
            $err = $_.Exception.GetBaseException().Message
        }
    } finally {
        $sw.Stop()
        if ($resp) { try { $resp.Close() } catch { } }
    }
    $ms = $null
    if ($ok) { $ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) }
    [ordered]@{
        https_ok = $ok; https_ms = $ms; https_status = $status; https_err = $err
        public_ip = $publicIp; https_colo = $colo
    }
}

#endregion
#region ---- Probes: IPv6 ----------------------------------------------------

function Test-IPv6Layer {
    # Tested on its own because IPv6 breaks independently of IPv4 and silently:
    # the browser falls back to v4 and nothing looks wrong until it does not.
    param([string[]]$Targets, [int]$Count, [int]$TimeoutMs)

    $res = [ordered]@{ v6_global = $false; v6_addr = ''; v6_ok = $false
                       v6_loss_pct = $null; v6_min_ms = $null; v6_avg_ms = $null }

    try {
        $addrs = @(Get-NetIPAddress -AddressFamily IPv6 -ErrorAction Stop |
                   Where-Object { $_.PrefixOrigin -ne 'WellKnown' -and
                                  $_.IPAddress -notlike 'fe80*' -and
                                  $_.IPAddress -ne '::1' -and
                                  $_.SuffixOrigin -ne 'Link' })
        if ($addrs.Count -gt 0) {
            $res['v6_global'] = $true
            $res['v6_addr'] = [string]$addrs[0].IPAddress
        }
    } catch { }

    if (-not $res['v6_global'] -or $Targets.Count -lt 1) { return $res }

    $stats = @(Invoke-PingSet -Targets $Targets -Count $Count -TimeoutMs $TimeoutMs -GapMs 0)
    $best = $null
    foreach ($s in $stats) {
        if ($null -ne $s['avg_ms']) {
            if ($null -eq $best -or $s['avg_ms'] -lt $best['avg_ms']) { $best = $s }
        }
    }
    if ($best) {
        $res['v6_ok']       = $true
        $res['v6_loss_pct'] = $best['loss_pct']
        $res['v6_min_ms']   = $best['min_ms']
        $res['v6_avg_ms']   = $best['avg_ms']
    } else {
        $res['v6_loss_pct'] = 100
    }
    $res
}

#endregion
#region ---- Probes: Wi-Fi ---------------------------------------------------

function Get-WifiInfo {
    # netsh is the only place this data is exposed without a module.
    # Its output is localised, so on a non-English Windows these columns come
    # back blank rather than wrong - wifi_parsed says which happened.
    $res = [ordered]@{
        wifi_present = $false; wifi_parsed = $false; wifi_iface = ''; wifi_ssid = ''
        wifi_bssid = ''; wifi_signal_pct = $null; wifi_channel = $null; wifi_band = ''
        wifi_radio = ''; wifi_rx_mbps = $null; wifi_tx_mbps = $null
    }

    $lines = $null
    try {
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $lines = & netsh.exe wlan show interfaces 2>&1
        $ErrorActionPreference = $old
    } catch { return $res }
    if (-not $lines) { return $res }

    $text = ($lines | Out-String)
    # No wireless hardware, or the WLAN AutoConfig service is stopped.
    if ($text -match 'not running' -or $text -match 'no wireless interface') { return $res }

    $fields = @{}
    $started = $false
    foreach ($ln in @($lines)) {
        $s = [string]$ln
        $i = $s.IndexOf(':')
        if ($i -lt 1) { continue }
        $k = $s.Substring(0, $i).Trim().ToLowerInvariant()
        $v = $s.Substring($i + 1).Trim()
        if ($k -eq 'name') {
            if ($started) { break }   # second adapter: keep only the first
            $started = $true
        }
        if (-not $fields.ContainsKey($k)) { $fields[$k] = $v }
    }
    if ($fields.Count -eq 0) { return $res }
    $res['wifi_present'] = $true

    if ($fields.ContainsKey('name')) { $res['wifi_iface'] = $fields['name'] }
    if ($fields.ContainsKey('state') -and $fields['state'] -notmatch 'connected') { return $res }

    if ($fields.ContainsKey('ssid'))       { $res['wifi_ssid']  = $fields['ssid'] }
    if ($fields.ContainsKey('bssid'))      { $res['wifi_bssid'] = $fields['bssid'] }
    if ($fields.ContainsKey('radio type')) { $res['wifi_radio'] = $fields['radio type'] }
    if ($fields.ContainsKey('band'))       { $res['wifi_band']  = $fields['band'] }

    $n = 0
    if ($fields.ContainsKey('signal') -and [int]::TryParse(($fields['signal'] -replace '[^\d]', ''), [ref]$n)) {
        $res['wifi_signal_pct'] = $n
    }
    if ($fields.ContainsKey('channel') -and [int]::TryParse($fields['channel'], [ref]$n)) {
        $res['wifi_channel'] = $n
        if (-not $res['wifi_band']) {
            if ($n -le 14) { $res['wifi_band'] = '2.4 GHz' }
            elseif ($n -le 177) { $res['wifi_band'] = '5 GHz' }
            else { $res['wifi_band'] = '6 GHz' }
        }
    }
    $d = 0.0
    if ($fields.ContainsKey('receive rate (mbps)') -and
        [double]::TryParse($fields['receive rate (mbps)'], [System.Globalization.NumberStyles]::Float, $script:Invariant, [ref]$d)) {
        $res['wifi_rx_mbps'] = $d
    }
    if ($fields.ContainsKey('transmit rate (mbps)') -and
        [double]::TryParse($fields['transmit rate (mbps)'], [System.Globalization.NumberStyles]::Float, $script:Invariant, [ref]$d)) {
        $res['wifi_tx_mbps'] = $d
    }

    if ($res['wifi_ssid'] -or $res['wifi_bssid']) { $res['wifi_parsed'] = $true }
    $res
}

#endregion
#region ---- Probes: throughput ----------------------------------------------

function Get-Throughput {
    # Byte counters are cumulative, so the rate needs the previous run's
    # reading: that is what state.json carries. A reboot, an adapter change or
    # a counter reset yields a blank rate rather than a fabricated spike.
    # busy_pct is what gates the speed test in a later stage.
    param([string]$AdapterName, $LinkBps, [Parameter(Mandatory = $true)]$State,
          [Parameter(Mandatory = $true)][DateTimeOffset]$Now)

    $res = [ordered]@{ rx_bps = $null; tx_bps = $null; busy_pct = $null; stats_span_s = $null }
    if (-not $AdapterName) { return $res }

    $st = Get-NetAdapterStatistics -Name $AdapterName -ErrorAction Stop
    $rx = [double]$st.ReceivedBytes
    $tx = [double]$st.SentBytes
    $nowTicks = $Now.UtcTicks

    $prevKey = 'Throughput'
    $prev = $null
    if ($State.ContainsKey($prevKey)) { $prev = $State[$prevKey] }

    if ($prev) {
        $pName = ''; $pRx = -1.0; $pTx = -1.0; $pTicks = 0.0
        try {
            $pName  = [string]$prev.Adapter
            $pRx    = [double]$prev.Rx
            $pTx    = [double]$prev.Tx
            $pTicks = [double]$prev.Ticks
        } catch { }

        $span = ($nowTicks - $pTicks) / 10000000.0
        if ($pName -eq $AdapterName -and $span -gt 0.5 -and $span -lt 3600 -and $rx -ge $pRx -and $tx -ge $pTx) {
            $res['stats_span_s'] = [math]::Round($span, 1)
            $rxBps = ($rx - $pRx) * 8.0 / $span
            $txBps = ($tx - $pTx) * 8.0 / $span
            $res['rx_bps'] = [math]::Round($rxBps, 0)
            $res['tx_bps'] = [math]::Round($txBps, 0)
            if ($LinkBps -and [double]$LinkBps -gt 0) {
                $busy = 100.0 * [math]::Max($rxBps, $txBps) / [double]$LinkBps
                $res['busy_pct'] = [math]::Round([math]::Min($busy, 100.0), 2)
            }
        }
    }

    $State[$prevKey] = [ordered]@{ Adapter = $AdapterName; Rx = $rx; Tx = $tx; Ticks = $nowTicks }
    $res
}

#endregion
#region ---- Collect ---------------------------------------------------------

function Add-ToRow {
    param($Row, $Values, [string]$Prefix)
    foreach ($k in $Values.Keys) {
        if ($Prefix) { $Row["{0}_{1}" -f $Prefix, $k] = $Values[$k] } else { $Row[$k] = $Values[$k] }
    }
}

function Invoke-Collect {
    # One probe cycle -> one ordered row. Every layer runs every time and
    # every column is always present, so the header never varies.
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$State,
          [Parameter(Mandatory = $true)][DateTimeOffset]$Started)

    $cycle   = [System.Diagnostics.Stopwatch]::StartNew()
    $errors  = New-Object 'System.Collections.Generic.List[string]'
    $targets = @($Config['PingTargets'])

    $row = [ordered]@{}
    $row['timestamp'] = Get-Timestamp -When $Started

    # Layer 0: is there a route at all, and via which interface/gateway?
    $route = $null
    try { $route = Get-PrimaryRoute -Probe $targets[0] }
    catch { [void]$errors.Add('route: ' + $_.Exception.Message) }
    $gw = ''; $iface = ''; $localIp = ''; $ifIndex = 0
    if ($route) { $gw = $route.Gateway; $iface = $route.IfAlias; $localIp = $route.LocalIP; $ifIndex = $route.IfIndex }
    $row['iface']    = $iface
    $row['local_ip'] = $localIp
    $row['gateway']  = $gw

    # Local facts about the interface the traffic is actually using.
    $adapter = [ordered]@{ adapter_desc = ''; adapter_mac = ''; adapter_status = ''
                           link_speed = ''; link_bps = $null; duplex = ''; adapter_name = '' }
    if ($ifIndex -gt 0) {
        try { $adapter = Get-AdapterInfo -IfIndex $ifIndex }
        catch { [void]$errors.Add('adapter: ' + $_.Exception.Message) }
    }
    $adapterName = [string]$adapter['adapter_name']
    $row['adapter_desc']   = $adapter['adapter_desc']
    $row['adapter_mac']    = $adapter['adapter_mac']
    $row['adapter_status'] = $adapter['adapter_status']
    $row['link_speed']     = $adapter['link_speed']
    $row['link_bps']       = $adapter['link_bps']
    $row['duplex']         = $adapter['duplex']

    $row['gw_mac'] = ''
    if ($gw -and $ifIndex -gt 0) {
        try { $row['gw_mac'] = Get-GatewayMac -Gateway $gw -IfIndex $ifIndex }
        catch { [void]$errors.Add('gw_mac: ' + $_.Exception.Message) }
    }

    $row['dns_servers'] = ''
    if ($ifIndex -gt 0) {
        try { $row['dns_servers'] = Get-DnsServersInUse -IfIndex $ifIndex }
        catch { [void]$errors.Add('dns_servers: ' + $_.Exception.Message) }
    }

    # Layers 1+2: gateway and public targets, pinged concurrently.
    $pingList = $targets
    if ($gw) { $pingList = @($gw) + $targets }
    # The two custom targets ride in the same concurrent round, so recording
    # them costs no extra time. Unset slots are simply not pinged.
    $customs = @(Get-CustomTargets -Config $Config)
    $customIdx = @(-1, -1)
    for ($ci = 0; $ci -lt 2; $ci++) {
        if ($customs[$ci].Address) {
            $customIdx[$ci] = @($pingList).Count
            $pingList = @($pingList) + @($customs[$ci].Address)
        }
    }
    $stats = @()
    try {
        $stats = @(Invoke-PingSet -Targets $pingList -Count $Config['PingCount'] `
                                  -TimeoutMs $Config['PingTimeoutMs'] -GapMs $Config['PingGapMs'])
    } catch { [void]$errors.Add('ping: ' + $_.Exception.Message) }
    if ($stats.Count -ne $pingList.Count) {
        $stats = @(foreach ($t in $pingList) { Get-PingStats -Samples @() -Sent 0 })
    }

    $offset = 0
    if ($gw) { $gwStats = $stats[0]; $offset = 1 }
    else     { $gwStats = Get-PingStats -Samples @() -Sent 0 }
    Add-ToRow -Row $row -Values $gwStats -Prefix 'gw'

    $up = 0
    for ($i = 0; $i -lt $targets.Count; $i++) {
        $p = 't{0}' -f ($i + 1)            # slot names keep the header stable if targets change
        $row["${p}_addr"] = $targets[$i]
        $s = $stats[$i + $offset]
        Add-ToRow -Row $row -Values $s -Prefix $p
        if ($s['sent'] -gt 0 -and $s['loss_pct'] -lt 100) { $up++ }
    }
    $row['targets_up'] = $up

    # Custom slots: fixed columns whether set or not, so the header is stable.
    for ($ci = 0; $ci -lt 2; $ci++) {
        $p = 'c{0}' -f ($ci + 1)
        $row["${p}_addr"] = [string]$customs[$ci].Address
        if ($customIdx[$ci] -ge 0) { $cs = $stats[$customIdx[$ci]] } else { $cs = Get-PingStats -Samples @() -Sent 0 }
        Add-ToRow -Row $row -Values $cs -Prefix $p
    }

    # First hops. Fixed slot count so the header does not move.
    $hops = @()
    try {
        $hops = @(Get-HopLatency -Target $targets[0] -Hops $Config['HopCount'] `
                                 -Samples $Config['HopSamples'] -TimeoutMs $Config['HopTimeoutMs'])
    } catch { [void]$errors.Add('hops: ' + $_.Exception.Message) }
    for ($h = 1; $h -le $Config['HopCount']; $h++) {
        $addr = ''; $ms = $null
        if ($hops.Count -ge $h) { $addr = $hops[$h - 1].Address; $ms = $hops[$h - 1].Ms }
        $row["hop${h}_addr"] = $addr
        $row["hop${h}_ms"]   = $ms
    }

    # Layer 3: DNS
    try { $dns = Test-DnsLayer -Domain $Config['DnsTestDomain'] }
    catch {
        [void]$errors.Add('dns: ' + $_.Exception.Message)
        $dns = [ordered]@{ dns_ok = $false; dns_ms = $null; dns_result = 'error'; dns_answer = ''; dns_hijack = $false }
    }
    Add-ToRow -Row $row -Values $dns

    # Layer 4: TCP 443
    try { $tcp = Test-TcpLayer -TargetHost $Config['TcpTestHost'] -Port $Config['TcpTestPort'] -TimeoutMs $Config['TcpTimeoutMs'] }
    catch { [void]$errors.Add('tcp: ' + $_.Exception.Message); $tcp = [ordered]@{ tcp_ok = $false; tcp_ms = $null; tcp_err = 'error' } }
    Add-ToRow -Row $row -Values $tcp

    # Layer 5: HTTPS (also yields public IP and edge location)
    try { $https = Test-HttpsLayer -Url $Config['HttpsUrl'] -Expect $Config['HttpsExpectText'] -TimeoutMs $Config['HttpsTimeoutMs'] }
    catch {
        [void]$errors.Add('https: ' + $_.Exception.Message)
        $https = [ordered]@{ https_ok = $false; https_ms = $null; https_status = $null; https_err = 'error'
                             public_ip = ''; https_colo = '' }
    }
    Add-ToRow -Row $row -Values $https

    # IPv6, scored separately from everything above.
    $v6 = [ordered]@{ v6_global = $false; v6_addr = ''; v6_ok = $false
                      v6_loss_pct = $null; v6_min_ms = $null; v6_avg_ms = $null }
    if ($Config['CollectIPv6']) {
        try { $v6 = Test-IPv6Layer -Targets $Config['IPv6Targets'] -Count $Config['IPv6Count'] -TimeoutMs $Config['IPv6TimeoutMs'] }
        catch { [void]$errors.Add('ipv6: ' + $_.Exception.Message) }
    }
    Add-ToRow -Row $row -Values $v6

    # Wi-Fi radio state. wifi_primary says whether the traffic in this row
    # actually went over that radio, or over Ethernet with Wi-Fi idle.
    $wifi = [ordered]@{
        wifi_present = $false; wifi_parsed = $false; wifi_iface = ''; wifi_ssid = ''
        wifi_bssid = ''; wifi_signal_pct = $null; wifi_channel = $null; wifi_band = ''
        wifi_radio = ''; wifi_rx_mbps = $null; wifi_tx_mbps = $null
    }
    if ($Config['CollectWifi']) {
        try { $wifi = Get-WifiInfo }
        catch { [void]$errors.Add('wifi: ' + $_.Exception.Message) }
    }
    Add-ToRow -Row $row -Values $wifi
    $row['wifi_primary'] = ($wifi['wifi_iface'] -and $iface -and $wifi['wifi_iface'] -eq $iface)

    # Throughput, needed to interpret every latency number above.
    $thr = [ordered]@{ rx_bps = $null; tx_bps = $null; busy_pct = $null; stats_span_s = $null }
    if ($adapterName) {
        try { $thr = Get-Throughput -AdapterName $adapterName -LinkBps $adapter['link_bps'] -State $State -Now $Started }
        catch { [void]$errors.Add('throughput: ' + $_.Exception.Message) }
    }
    Add-ToRow -Row $row -Values $thr

    # Which layers failed, lowest first. Interpretation (Up/Degraded/Down,
    # baseline, hysteresis) comes later; this row just records facts.
    $failed = New-Object 'System.Collections.Generic.List[string]'
    if (-not $route) { [void]$failed.Add('route') }
    elseif ($gw -and $gwStats['loss_pct'] -ge 100) { [void]$failed.Add('gateway') }
    if ($up -eq 0) { [void]$failed.Add('internet') }
    if (-not $row['dns_ok'])   { [void]$failed.Add('dns') }
    if (-not $row['tcp_ok'])   { [void]$failed.Add('tcp') }
    if (-not $row['https_ok']) { [void]$failed.Add('https') }

    $row['failed_layers'] = $failed -join ';'
    if ($failed.Count -gt 0) { $row['first_fail'] = $failed[0] } else { $row['first_fail'] = 'none' }

    $cycle.Stop()
    $row['cycle_ms'] = [int]$cycle.Elapsed.TotalMilliseconds
    $row['errors']   = ($errors -join ' | ') -replace '\s+', ' '
    $row['netmon_ver'] = $script:NetmonVersion
    $row
}

#endregion
#region ---- Health: three states, learned baseline, hysteresis ---------------

# Two states is not enough. Most real problems are degradation, and a binary
# monitor either misses them or screams. Thresholds are learned from this
# line's own behaviour rather than hardcoded, because a Sydney fibre service
# and rural fixed-wireless have nothing in common.

function Get-Field {
    # Rows arrive either as the ordered dictionary the collector just built or
    # as the PSCustomObject Import-Csv hands back. One accessor for both.
    param($Row, [string]$Name)
    if ($null -eq $Row) { return $null }
    if ($Row -is [System.Collections.IDictionary]) {
        if ($Row.Contains($Name)) { return $Row[$Name] }
        return $null
    }
    $p = $Row.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Format-Duration {
    param($Seconds)
    if ($null -eq $Seconds) { return '' }
    $s = [double]$Seconds
    if ($s -lt 0) { $s = 0 }
    $ts = [TimeSpan]::FromSeconds($s)
    if ($ts.TotalDays -ge 1) { return ('{0}d {1}h {2}m' -f [int]$ts.TotalDays, $ts.Hours, $ts.Minutes) }
    if ($ts.TotalHours -ge 1) { return ('{0}h {1}m' -f [int]$ts.TotalHours, $ts.Minutes) }
    if ($ts.TotalMinutes -ge 1) { return ('{0}m {1}s' -f [int]$ts.TotalMinutes, $ts.Seconds) }
    return ('{0}s' -f [int]$ts.TotalSeconds)
}

function Get-RowMetrics {
    # The few numbers the state machine actually judges on, pulled out of a
    # wide row. Latency is the BEST responding target: if one provider is
    # having a bad day that is their problem, not this line's.
    param($Row)

    $m = [ordered]@{
        LatencyMs = $null; LossPct = $null; JitterMs = $null
        TargetsUp = 0; TargetCount = 0
        DnsOk = $false; TcpOk = $false; HttpsOk = $false
        FirstFail = ''; FailedLayers = ''
        GwLossPct = $null; GwLatencyMs = $null
    }

    for ($i = 1; $i -le 16; $i++) {
        $addr = Get-Field $Row ('t{0}_addr' -f $i)
        if ($null -eq $addr -or [string]$addr -eq '') { break }
        $m['TargetCount'] = $i
        $loss = ConvertTo-Num (Get-Field $Row ('t{0}_loss_pct' -f $i))
        $avg  = ConvertTo-Num (Get-Field $Row ('t{0}_avg_ms' -f $i))
        $sd   = ConvertTo-Num (Get-Field $Row ('t{0}_sd_ms' -f $i))

        if ($null -ne $loss -and $loss -lt 100) { $m['TargetsUp']++ }
        # Worst loss across targets: one target dropping is worth seeing even
        # when another is clean.
        if ($null -ne $loss) {
            if ($null -eq $m['LossPct'] -or $loss -gt $m['LossPct']) { $m['LossPct'] = $loss }
        }
        if ($null -ne $avg) {
            if ($null -eq $m['LatencyMs'] -or $avg -lt $m['LatencyMs']) {
                $m['LatencyMs'] = $avg
                $m['JitterMs']  = $sd
            }
        }
    }

    $u = ConvertTo-Num (Get-Field $Row 'targets_up')
    if ($null -ne $u) { $m['TargetsUp'] = [int]$u }

    $m['GwLossPct']   = ConvertTo-Num (Get-Field $Row 'gw_loss_pct')
    $m['GwLatencyMs'] = ConvertTo-Num (Get-Field $Row 'gw_avg_ms')
    $m['DnsOk']       = ConvertTo-Flag (Get-Field $Row 'dns_ok')
    $m['TcpOk']       = ConvertTo-Flag (Get-Field $Row 'tcp_ok')
    $m['HttpsOk']     = ConvertTo-Flag (Get-Field $Row 'https_ok')
    $m['FirstFail']   = [string](Get-Field $Row 'first_fail')
    $m['FailedLayers'] = [string](Get-Field $Row 'failed_layers')
    $m
}

function Get-BaselineView {
    # The learned normal, or $null while still warming up.
    param($State, $Config)
    if (-not $State.ContainsKey('Baseline')) { return $null }
    $b = $State['Baseline']
    if ($null -eq $b) { return $null }
    $n = 0
    try { $n = [int]$b['N'] } catch { return $null }
    if ($n -lt [int]$Config['BaselineMinSamples']) { return $null }
    $lat = $null
    try { $lat = [double]$b['LatencyMs'] } catch { }
    if ($null -eq $lat -or $lat -le 0) { return $null }
    New-Object PSObject -Property ([ordered]@{ N = $n; LatencyMs = $lat })
}

function Update-Baseline {
    # EWMA over healthy cycles only, so an outage does not teach the monitor
    # that outages are normal.
    param($State, $Config, $Metrics)
    if ($null -eq $Metrics['LatencyMs']) { return }

    if (-not $State.ContainsKey('Baseline') -or $null -eq $State['Baseline']) {
        $State['Baseline'] = @{ N = 0; LatencyMs = $null; LossPct = 0.0 }
    }
    $b = $State['Baseline']
    $n = 0; try { $n = [int]$b['N'] } catch { $n = 0 }
    $cur = $null; try { $cur = [double]$b['LatencyMs'] } catch { }
    $curLoss = 0.0; try { $curLoss = [double]$b['LossPct'] } catch { }

    $alpha = 2.0 / ([double]$Config['BaselineWindow'] + 1.0)
    if ($n -lt 1 -or $null -eq $cur -or $cur -le 0) {
        $b['LatencyMs'] = [double]$Metrics['LatencyMs']
        $b['LossPct']   = [double](&{ if ($null -ne $Metrics['LossPct']) { $Metrics['LossPct'] } else { 0.0 } })
    } else {
        $b['LatencyMs'] = [math]::Round($cur + $alpha * ([double]$Metrics['LatencyMs'] - $cur), 2)
        $l = 0.0
        if ($null -ne $Metrics['LossPct']) { $l = [double]$Metrics['LossPct'] }
        $b['LossPct'] = [math]::Round($curLoss + $alpha * ($l - $curLoss), 3)
    }
    $b['N'] = $n + 1
    $State['Baseline'] = $b
}

function Get-RawHealth {
    # What this single cycle looks like, before hysteresis. Down means the
    # link is unusable; Degraded means it works but badly; Up means normal
    # for THIS line, per the learned baseline.
    param($Row, $Metrics, $Config, $Baseline)

    $reasons = New-Object 'System.Collections.Generic.List[string]'
    $ff = [string]$Metrics['FirstFail']

    # --- Down -------------------------------------------------------------
    if ($ff -eq 'route') { return (New-Object PSObject -Property @{ State = 'Down'; Reason = 'no route to the internet' }) }
    if ($ff -eq 'gateway') { return (New-Object PSObject -Property @{ State = 'Down'; Reason = 'gateway not responding (LAN or router)' }) }
    if ([int]$Metrics['TargetsUp'] -le 0) {
        return (New-Object PSObject -Property @{ State = 'Down'; Reason = 'all public targets unreachable' })
    }
    if (-not $Metrics['DnsOk'] -and -not $Metrics['TcpOk'] -and -not $Metrics['HttpsOk']) {
        # ICMP answers but nothing usable flows: shaped ICMP, DPI, or a portal.
        return (New-Object PSObject -Property @{ State = 'Down'; Reason = 'ping works but no usable traffic (DNS, TCP and HTTPS all failed)' })
    }

    # --- Degraded ---------------------------------------------------------
    if (-not $Metrics['DnsOk'])   { [void]$reasons.Add('DNS failing') }
    if (-not $Metrics['TcpOk'])   { [void]$reasons.Add('TCP 443 failing') }
    if (-not $Metrics['HttpsOk']) {
        $he = [string](Get-Field $Row 'https_err')
        if ($he) { [void]$reasons.Add('HTTPS failing (' + $he + ')') } else { [void]$reasons.Add('HTTPS failing') }
    }

    $loss = $Metrics['LossPct']
    if ($null -ne $loss -and $loss -gt [double]$Config['DegradedLossPct']) {
        [void]$reasons.Add(('packet loss {0}%' -f $loss))
    }

    $lat = $Metrics['LatencyMs']
    if ($null -ne $lat) {
        if ($Baseline) {
            $limit = [math]::Max($Baseline.LatencyMs * [double]$Config['DegradedLatencyMult'],
                                 $Baseline.LatencyMs + [double]$Config['DegradedLatencyMinMs'])
            if ($lat -gt $limit) {
                [void]$reasons.Add(('latency {0}ms vs baseline {1}ms' -f $lat, [math]::Round($Baseline.LatencyMs, 1)))
            }
        } elseif ($lat -gt [double]$Config['DegradedLatencyMs']) {
            # No baseline yet: an absolute number, deliberately loose.
            [void]$reasons.Add(('latency {0}ms (no baseline yet)' -f $lat))
        }
    }

    $jit = $Metrics['JitterMs']
    if ($null -ne $jit -and $jit -gt [double]$Config['DegradedJitterMs']) {
        [void]$reasons.Add(('jitter {0}ms' -f $jit))
    }

    if ($reasons.Count -gt 0) {
        return (New-Object PSObject -Property @{ State = 'Degraded'; Reason = ($reasons -join '; ') })
    }
    New-Object PSObject -Property @{ State = 'Up'; Reason = '' }
}

function New-HealthState {
    param([string]$State, [DateTimeOffset]$When)
    @{
        State        = $State
        Since        = (Get-Timestamp -When $When)
        Pending      = ''
        PendingCount = 0
        Reason       = ''
    }
}

function Update-Health {
    # Applies hysteresis and writes an events row on a confirmed transition.
    # Without hysteresis a flapping link produces an event every minute and
    # the events log becomes as useless as the raw log.
    param($Row, $Metrics, $Config, $State, [DateTimeOffset]$When)

    $raw = Get-RawHealth -Row $Row -Metrics $Metrics -Config $Config -Baseline (Get-BaselineView -State $State -Config $Config)

    if ($raw.State -eq 'Up') { Update-Baseline -State $State -Config $Config -Metrics $Metrics }

    if (-not $State.ContainsKey('Health') -or $null -eq $State['Health']) {
        $State['Health'] = New-HealthState -State $raw.State -When $When
        $State['Health']['Reason'] = $raw.Reason
        Write-EventRow -Row $Row -Metrics $Metrics -Config $Config `
                       -From '' -To $raw.State -DurationS $null -Reason 'monitoring started' -When $When
        return (New-Object PSObject -Property @{ State = $raw.State; Raw = $raw.State; Reason = $raw.Reason; Changed = $true })
    }

    $h = $State['Health']
    $current = [string]$h['State']
    $changed = $false

    if ($raw.State -eq $current) {
        $h['Pending'] = ''
        $h['PendingCount'] = 0
        if ($raw.State -ne 'Up') { $h['Reason'] = $raw.Reason }   # keep the freshest description
    } else {
        if ([string]$h['Pending'] -eq $raw.State) { $h['PendingCount'] = [int]$h['PendingCount'] + 1 }
        else { $h['Pending'] = $raw.State; $h['PendingCount'] = 1 }

        $need = switch ($raw.State) {
            'Down'     { [int]$Config['FailuresToDown'] }
            'Degraded' { [int]$Config['SamplesToDegraded'] }
            default    { [int]$Config['SuccessesToUp'] }
        }
        # Falling back from Down to Degraded is still an improvement, so it
        # uses the recovery threshold rather than the degraded one.
        if ($current -eq 'Down' -and $raw.State -eq 'Degraded') { $need = [int]$Config['SuccessesToUp'] }

        if ([int]$h['PendingCount'] -ge $need) {
            $since = ConvertFrom-Timestamp ([string]$h['Since'])
            $dur = $null
            if ($since) { $dur = [math]::Round(($When - $since).TotalSeconds, 0) }

            Write-EventRow -Row $Row -Metrics $Metrics -Config $Config `
                           -From $current -To $raw.State -DurationS $dur -Reason $raw.Reason -When $When

            $h['State'] = $raw.State
            $h['Since'] = Get-Timestamp -When $When
            $h['Pending'] = ''
            $h['PendingCount'] = 0
            $h['Reason'] = $raw.Reason
            $changed = $true
        }
    }

    $State['Health'] = $h
    New-Object PSObject -Property @{ State = [string]$h['State']; Raw = $raw.State; Reason = $raw.Reason; Changed = $changed }
}

#endregion
#region ---- Events log + failure diagnostics --------------------------------

# State transitions ONLY. "How many outages this month" is trivial from this
# file and a chore from 500k raw rows. This is also the file to hand an ISP -
# which is why the diagnostics are captured at the moment of failure. A log
# saying "23:14 failed" is worthless; a traceroute showing where packets died
# at 23:14 is evidence.

function Write-EventRow {
    param($Row, $Metrics, $Config, [string]$From, [string]$To, $DurationS, [string]$Reason,
          [DateTimeOffset]$When)

    $diagFile = ''
    $wantDiag = ($To -eq 'Down' -and $Config['CaptureDiagOnDown']) -or
                ($To -eq 'Degraded' -and $Config['CaptureDiagOnDegraded'])
    if ($wantDiag -and $From) {   # not on the very first row
        try { $diagFile = Invoke-FailureDiagnostics -Config $Config -Row $Row -When $When -Reason $Reason }
        catch { Write-NetmonLog -Level WARN "Diagnostics capture failed: $($_.Exception.Message)" }
    }

    $ev = [ordered]@{
        timestamp       = Get-Timestamp -When $When
        from_state      = $From
        to_state        = $To
        prev_duration_s = $DurationS
        prev_duration   = (Format-Duration $DurationS)
        reason          = $Reason
        first_fail      = $Metrics['FirstFail']
        failed_layers   = $Metrics['FailedLayers']
        latency_ms      = $Metrics['LatencyMs']
        loss_pct        = $Metrics['LossPct']
        jitter_ms       = $Metrics['JitterMs']
        targets_up      = $Metrics['TargetsUp']
        gw_loss_pct     = $Metrics['GwLossPct']
        iface           = [string](Get-Field $Row 'iface')
        local_ip        = [string](Get-Field $Row 'local_ip')
        gateway         = [string](Get-Field $Row 'gateway')
        gw_mac          = [string](Get-Field $Row 'gw_mac')
        public_ip       = [string](Get-Field $Row 'public_ip')
        dns_servers     = [string](Get-Field $Row 'dns_servers')
        wifi_ssid       = [string](Get-Field $Row 'wifi_ssid')
        wifi_bssid      = [string](Get-Field $Row 'wifi_bssid')
        wifi_signal_pct = (Get-Field $Row 'wifi_signal_pct')
        diag_file       = $diagFile
        netmon_ver      = $script:NetmonVersion
    }
    try {
        $null = Add-CsvRow -Kind 'events' -Row $ev -When $When
        $arrow = '->'
        if (-not $From) { Write-NetmonLog ("State: {0} ({1})" -f $To, $Reason) }
        else { Write-NetmonLog ("State {0} {1} {2} after {3} ({4})" -f $From, $arrow, $To, (Format-Duration $DurationS), $Reason) }
    } catch {
        Write-NetmonLog -Level ERROR "Could not write events row: $($_.Exception.Message)"
    }
}

function Invoke-CaptureCommand {
    # Runs an external tool with a hard timeout and returns its output as text.
    # A hung tracert must not hold up the next probe cycle.
    param([string]$FilePath, [string]$Arguments, [int]$TimeoutSec)

    $out = [System.IO.Path]::GetTempFileName()
    $err = [System.IO.Path]::GetTempFileName()
    $text = ''
    $p = $null
    try {
        $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -PassThru `
                           -RedirectStandardOutput $out -RedirectStandardError $err
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch { }
            $text = "[netmon] timed out after ${TimeoutSec}s`r`n"
        }
        Start-Sleep -Milliseconds 100
        if (Test-Path -LiteralPath $out) { $text += [System.IO.File]::ReadAllText($out) }
        $e = ''
        if (Test-Path -LiteralPath $err) { $e = [System.IO.File]::ReadAllText($err) }
        if ($e.Trim()) { $text += "`r`n[stderr] " + $e }
    } catch {
        $text = "[netmon] could not run ${FilePath}: $($_.Exception.Message)"
    } finally {
        foreach ($f in @($out, $err)) { try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { } }
    }
    $text
}

function Invoke-FailureDiagnostics {
    # Everything an ISP will ask for, captured while the fault is live.
    param($Config, $Row, [DateTimeOffset]$When, [string]$Reason)

    $dir = Join-Path $script:DataDir 'diag'
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }

    $stamp = $When.ToString('yyyy-MM-dd_HHmmss', $script:Invariant)
    $name  = "diag_$stamp.txt"
    $path  = Join-Path $dir $name
    $tmo   = [int]$Config['DiagTimeoutSeconds']
    if ($tmo -lt 5) { $tmo = 5 }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('PS-NETMON failure diagnostics')
    [void]$sb.AppendLine('captured : ' + (Get-Timestamp -When $When))
    [void]$sb.AppendLine('machine  : ' + $env:COMPUTERNAME)
    [void]$sb.AppendLine('reason   : ' + $Reason)
    [void]$sb.AppendLine('version  : PS-NETMON ' + $script:NetmonVersion)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('--- probe row at failure ---')
    foreach ($k in @($Row.Keys)) {
        [void]$sb.AppendLine(('{0,-16} {1}' -f $k, [string]$Row[$k]))
    }

    $target = ''
    $targets = @($Config['PingTargets'])
    if ($targets.Count -gt 0) { $target = $targets[0] }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("--- tracert -d -h $($Config['DiagTracerouteHops']) $target ---")
    if ($target) {
        [void]$sb.AppendLine((Invoke-CaptureCommand -FilePath 'tracert.exe' `
            -Arguments ("-d -h {0} -w 500 {1}" -f $Config['DiagTracerouteHops'], $target) -TimeoutSec $tmo))
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('--- ipconfig /all ---')
    [void]$sb.AppendLine((Invoke-CaptureCommand -FilePath 'ipconfig.exe' -Arguments '/all' -TimeoutSec 15))

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('--- arp -a ---')
    [void]$sb.AppendLine((Invoke-CaptureCommand -FilePath 'arp.exe' -Arguments '-a' -TimeoutSec 15))

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('--- adapters ---')
    try {
        [void]$sb.AppendLine((Get-NetAdapter -ErrorAction Stop |
            Select-Object Name, InterfaceDescription, Status, LinkSpeed, FullDuplex, MacAddress |
            Format-Table -AutoSize | Out-String))
    } catch { [void]$sb.AppendLine('Get-NetAdapter failed: ' + $_.Exception.Message) }

    [void]$sb.AppendLine('--- adapter statistics ---')
    try {
        [void]$sb.AppendLine((Get-NetAdapterStatistics -ErrorAction Stop |
            Select-Object Name, ReceivedBytes, SentBytes, ReceivedUnicastPackets, OutboundPacketsDiscarded, ReceivedPacketErrors |
            Format-Table -AutoSize | Out-String))
    } catch { [void]$sb.AppendLine('Get-NetAdapterStatistics failed: ' + $_.Exception.Message) }

    [void]$sb.AppendLine('--- neighbours (ARP table, gateway entry included) ---')
    try {
        [void]$sb.AppendLine((Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.State -ne 'Permanent' } |
            Select-Object ifIndex, IPAddress, LinkLayerAddress, State |
            Format-Table -AutoSize | Out-String))
    } catch { [void]$sb.AppendLine('Get-NetNeighbor failed: ' + $_.Exception.Message) }

    [void]$sb.AppendLine('--- routes ---')
    try {
        [void]$sb.AppendLine((Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop |
            Sort-Object RouteMetric |
            Select-Object -First 25 ifIndex, DestinationPrefix, NextHop, RouteMetric, InterfaceAlias |
            Format-Table -AutoSize | Out-String))
    } catch { [void]$sb.AppendLine('Get-NetRoute failed: ' + $_.Exception.Message) }

    [void]$sb.AppendLine('--- DNS client servers ---')
    try {
        [void]$sb.AppendLine((Get-DnsClientServerAddress -ErrorAction Stop |
            Where-Object { $_.ServerAddresses } |
            Select-Object InterfaceAlias, AddressFamily, @{ n = 'Servers'; e = { $_.ServerAddresses -join ';' } } |
            Format-Table -AutoSize | Out-String))
    } catch { [void]$sb.AppendLine('Get-DnsClientServerAddress failed: ' + $_.Exception.Message) }

    if ($Config['CollectWifi']) {
        [void]$sb.AppendLine('--- netsh wlan show interfaces ---')
        [void]$sb.AppendLine((Invoke-CaptureCommand -FilePath 'netsh.exe' -Arguments 'wlan show interfaces' -TimeoutSec 15))
    }

    [System.IO.File]::WriteAllText($path, $sb.ToString(), $script:Utf8NoBom)
    Write-NetmonLog "Captured diagnostics: $name"
    $name
}

#endregion
#region ---- Speed test -------------------------------------------------------

# A speed test is not just another probe:
#   it CONSUMES what it measures - hundreds of MB a run, which is real money
#     on a metered plan, a 4G failover service or a capped connection;
#   it RUINS what it measures - run one during a Teams call and you degrade
#     the call and record a bad number at the same time;
#   it is MEANINGLESS on a busy line - you measure leftover capacity.
# Hence: its own schedule, its own file, a busy-line guard, and a refusal to
# run more often than every 15 minutes.

function Get-BusyPercent {
    # Two counter reads a second apart. This is the guard that decides whether
    # running a test right now would be rude and produce a wrong answer.
    param([string]$AdapterName, $LinkBps, [int]$SampleMs)
    if (-not $AdapterName) { return $null }
    if ($SampleMs -lt 200) { $SampleMs = 200 }
    try {
        $a = Get-NetAdapterStatistics -Name $AdapterName -ErrorAction Stop
        $t0 = [System.Diagnostics.Stopwatch]::StartNew()
        Start-Sleep -Milliseconds $SampleMs
        $b = Get-NetAdapterStatistics -Name $AdapterName -ErrorAction Stop
        $t0.Stop()
        $span = $t0.Elapsed.TotalSeconds
        if ($span -le 0) { return $null }
        $rx = ([double]$b.ReceivedBytes - [double]$a.ReceivedBytes) * 8.0 / $span
        $tx = ([double]$b.SentBytes - [double]$a.SentBytes) * 8.0 / $span
        if ($rx -lt 0 -or $tx -lt 0) { return $null }
        if (-not $LinkBps -or [double]$LinkBps -le 0) { return $null }
        return [math]::Round([math]::Min(100.0, 100.0 * [math]::Max($rx, $tx) / [double]$LinkBps), 2)
    } catch {
        return $null
    }
}

function Get-IqmMs {
    # Interquartile mean: the average of the middle half. It is what Ookla
    # reports for latency, so the two can be compared like for like; it
    # ignores the odd stall without pretending the spread is not there.
    param($Values)
    $v = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($v.Count -lt 1) { return $null }
    if ($v.Count -lt 4) { return [math]::Round((($v | Measure-Object -Average).Average), 1) }
    $lo = [int][math]::Floor($v.Count / 4)
    $hi = $v.Count - $lo
    $sum = 0.0
    for ($i = $lo; $i -lt $hi; $i++) { $sum += $v[$i] }
    [math]::Round($sum / ($hi - $lo), 1)
}

function Start-LatencySampler {
    # Samples round-trip time in a background runspace, every IntervalMs,
    # until stopped. Run while a transfer saturates the line, the rise over
    # idle latency is bufferbloat: what makes calls and games fall apart when
    # someone else on the network starts a download.
    # With -TcpPort it times a TCP connect to that port (one round trip), the
    # way Ookla measures to its test server. Without it: ICMP first, falling
    # back to TCP 443 where ping is blocked.
    param([string]$Target, [int]$IntervalMs = 250, [int]$TimeoutMs = 1000, [int]$TcpPort = 0)
    if (-not $Target) { return $null }
    $shared = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $ctl = [hashtable]::Synchronized(@{ Stop = $false; Method = '' })
    $ps = [PowerShell]::Create()
    $null = $ps.AddScript({
        param($T, $I, $To, $Bag, $Flag, $Port)
        $p = New-Object System.Net.NetworkInformation.Ping
        $icmp = ($Port -le 0)
        $connPort = 443
        if ($Port -gt 0) { $connPort = $Port }
        $icmpFails = 0
        try {
            while (-not $Flag.Stop) {
                $ms = $null
                if ($icmp) {
                    try {
                        $reply = $p.Send($T, $To)
                        if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $ms = [double]$reply.RoundtripTime; $icmpFails = 0 }
                        else { $icmpFails++ }
                    } catch { $icmpFails++ }
                    # Three misses in a row with nothing ever answering: give up on ICMP.
                    if ($icmpFails -ge 3 -and $Bag.Count -eq 0) { $icmp = $false }
                }
                if (-not $icmp) {
                    $c = New-Object System.Net.Sockets.TcpClient
                    try {
                        $sw = [System.Diagnostics.Stopwatch]::StartNew()
                        $task = $c.ConnectAsync($T, $connPort)
                        if ($task.Wait($To) -and $c.Connected) { $ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) }
                    } catch { } finally { $c.Close() }
                }
                if ($null -ne $ms) {
                    [void]$Bag.Add($ms)
                    if ($icmp) { $Flag.Method = 'icmp' } else { $Flag.Method = 'tcp' + $connPort }
                }
                Start-Sleep -Milliseconds $I
            }
        } finally { $p.Dispose() }
    }, $true)
    $null = $ps.AddArgument($Target).AddArgument($IntervalMs).AddArgument($TimeoutMs).AddArgument($shared).AddArgument($ctl).AddArgument($TcpPort)
    @{ PS = $ps; Handle = $ps.BeginInvoke(); Bag = $shared; Flag = $ctl }
}

function Stop-LatencySampler {
    # Returns @{ Ms = IQM; Jitter = mean gap between samples; Count; Method }.
    param($Sampler)
    $res = @{ Ms = $null; Jitter = $null; Count = 0; Method = '' }
    if (-not $Sampler) { return $res }
    $Sampler.Flag.Stop = $true
    try { $null = $Sampler.Handle.AsyncWaitHandle.WaitOne(2500); $null = $Sampler.PS.EndInvoke($Sampler.Handle) } catch { }
    try { $Sampler.PS.Dispose() } catch { }
    $vals = @($Sampler.Bag.ToArray() | ForEach-Object { [double]$_ })
    $res.Count = $vals.Count
    $res.Method = [string]$Sampler.Flag.Method
    if ($vals.Count -lt 1) { return $res }
    $res.Ms = Get-IqmMs $vals
    if ($vals.Count -gt 1) {
        $sum = 0.0
        for ($i = 1; $i -lt $vals.Count; $i++) { $sum += [math]::Abs($vals[$i] - $vals[$i - 1]) }
        $res.Jitter = [math]::Round($sum / ($vals.Count - 1), 1)
    }
    $res
}

function Measure-IdleLatency {
    # The line at rest, just before the transfer: same sampler, ~3 seconds.
    param([string]$Target, [int]$TcpPort = 0)
    $smp = Start-LatencySampler -Target $Target -IntervalMs 200 -TcpPort $TcpPort
    Start-Sleep -Milliseconds 3000
    Stop-LatencySampler $smp
}

function Measure-HttpDownload {
    # Times the body only, not connection setup, and stops at MaxSeconds so a
    # slow line yields a real measurement of a shorter transfer rather than a
    # timeout and no data at all.
    param([string]$Url, [int]$TimeoutMs, [int]$MaxSeconds)

    $res = [ordered]@{ ok = $false; bytes = 0.0; seconds = $null; mbps = $null; err = ''; truncated = $false }
    $resp = $null; $stream = $null
    try {
        $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Url)
        $req.Method           = 'GET'
        $req.Timeout          = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.KeepAlive        = $false
        $req.AllowAutoRedirect = $true
        $req.UserAgent        = "PS-NETMON/$script:NetmonVersion"
        $req.Proxy            = $null      # a proxy would measure the proxy
        $req.CachePolicy      = New-Object System.Net.Cache.RequestCachePolicy ([System.Net.Cache.RequestCacheLevel]::NoCacheNoStore)

        $resp   = $req.GetResponse()
        $stream = $resp.GetResponseStream()
        $buf = New-Object byte[] 131072
        $total = 0.0
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $total += $n
            if ($sw.Elapsed.TotalSeconds -ge $MaxSeconds) { $res['truncated'] = $true; break }
        }
        $sw.Stop()
        $res['bytes']   = $total
        $res['seconds'] = [math]::Round($sw.Elapsed.TotalSeconds, 3)
        if ($sw.Elapsed.TotalSeconds -gt 0.05 -and $total -gt 0) {
            $res['mbps'] = [math]::Round($total * 8.0 / $sw.Elapsed.TotalSeconds / 1000000.0, 2)
            $res['ok'] = $true
        } else {
            $res['err'] = 'transfer too short to measure'
        }
    } catch {
        $res['err'] = $_.Exception.GetBaseException().Message
    } finally {
        if ($stream) { try { $stream.Dispose() } catch { } }
        if ($resp) { try { $resp.Close() } catch { } }
    }
    $res
}


function Invoke-MultiStreamTransfer {
    <#
      Several parallel HTTP streams for a fixed time, the way Ookla and every
      browser speed test work. One stream cannot fill a fast line: TCP's window
      and the round-trip time cap it, and upload suffers most. Each stream
      loops requests until told to stop; the main thread samples the combined
      byte count every 100 ms and the first WarmupSeconds (TCP slow start)
      are left out of the result, as Ookla does.
    #>
    param([ValidateSet('Down', 'Up')][string]$Direction, [string]$Url, [int]$Streams = 6,
          [int]$Seconds = 10, [long]$ChunkBytes = 26214400, [int]$TimeoutMs = 15000,
          [double]$WarmupSeconds = 2.0)

    $res = [ordered]@{ ok = $false; bytes = 0.0; seconds = $null; mbps = $null; err = ''; truncated = $false
                       streams = $Streams; peak_mbps = $null }
    if ($Streams -lt 1) { $Streams = 1 }
    if ($Seconds -lt 4) { $Seconds = 4 }

    # .NET's defaults are tuned for polite web clients, not measurement: two
    # connections per host (the other streams would queue), and a
    # 100-continue round trip before every upload body.
    if ([System.Net.ServicePointManager]::DefaultConnectionLimit -lt 64) { [System.Net.ServicePointManager]::DefaultConnectionLimit = 64 }
    [System.Net.ServicePointManager]::Expect100Continue = $false

    $shared = [hashtable]::Synchronized(@{ Stop = $false })
    for ($i = 0; $i -lt $Streams; $i++) { $shared['b' + $i] = [long]0; $shared['e' + $i] = '' }

    $downBody = {
        param($Url, $Idx, $St, $TimeoutMs, $Chunk)
        $buf = New-Object byte[] 262144
        $total = [long]0
        $key = 'b' + $Idx
        while (-not $St.Stop) {
            $req = $null; $resp = $null; $s = $null
            try {
                $sep = '?'; if ($Url.Contains('?')) { $sep = '&' }
                $u = '{0}{1}bytes={2}&r={3}' -f $Url, $sep, $Chunk, [guid]::NewGuid().ToString('N')
                $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($u)
                $req.Timeout = $TimeoutMs; $req.ReadWriteTimeout = $TimeoutMs
                $req.KeepAlive = $true; $req.Proxy = $null; $req.UserAgent = 'PS-NETMON'
                $resp = $req.GetResponse()
                $s = $resp.GetResponseStream()
                while (-not $St.Stop) {
                    $n = $s.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    $total += $n
                    $St[$key] = $total
                }
                if ($St.Stop) { $req.Abort() }
            } catch {
                if (-not $St.Stop) { $St['e' + $Idx] = $_.Exception.GetBaseException().Message; Start-Sleep -Milliseconds 200 }
            } finally {
                if ($s) { try { $s.Dispose() } catch { } }
                if ($resp) { try { $resp.Close() } catch { } }
            }
        }
    }
    $upBody = {
        # Raw socket (plus TLS) rather than HttpWebRequest: some .NET versions
        # buffer a request body before sending it, which would count bytes
        # the moment they are copied rather than when the network takes them.
        # A socket write blocks once the send buffer is full, so what is
        # counted here is what the connection actually accepted.
        param($Url, $Idx, $St, $TimeoutMs, $Chunk)
        $piece = New-Object byte[] 65536
        (New-Object Random).NextBytes($piece)     # incompressible
        $total = [long]0
        $key = 'b' + $Idx
        while (-not $St.Stop) {
            $tcp = $null; $stream = $null
            try {
                $sep = '?'; if ($Url.Contains('?')) { $sep = '&' }
                $uri = [uri]('{0}{1}r={2}' -f $Url, $sep, [guid]::NewGuid().ToString('N'))
                $tcp = New-Object System.Net.Sockets.TcpClient
                $tcp.NoDelay = $true
                $tcp.SendTimeout = $TimeoutMs; $tcp.ReceiveTimeout = $TimeoutMs
                $tcp.Connect($uri.Host, $uri.Port)
                $stream = $tcp.GetStream()
                if ($uri.Scheme -eq 'https') {
                    $ssl = New-Object System.Net.Security.SslStream($stream, $false)
                    $ssl.AuthenticateAsClient($uri.Host, $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)
                    $stream = $ssl
                }
                $hdr = "POST {0} HTTP/1.1`r`nHost: {1}`r`nUser-Agent: PS-NETMON`r`nContent-Type: application/octet-stream`r`nContent-Length: {2}`r`nConnection: close`r`n`r`n" -f $uri.PathAndQuery, $uri.Host, $Chunk
                $hb = [System.Text.Encoding]::ASCII.GetBytes($hdr)
                $stream.Write($hb, 0, $hb.Length)
                $sent = [long]0
                while ($sent -lt $Chunk -and -not $St.Stop) {
                    $n = [int][math]::Min([long]$piece.Length, $Chunk - $sent)
                    $stream.Write($piece, 0, $n)
                    $sent += $n
                    $total += $n
                    $St[$key] = $total
                }
                if (-not $St.Stop) {
                    # Let the server finish reading and answer before reconnecting.
                    $stream.Flush()
                    $rb = New-Object byte[] 1024
                    $null = $stream.Read($rb, 0, $rb.Length)
                }
            } catch {
                if (-not $St.Stop) { $St['e' + $Idx] = $_.Exception.GetBaseException().Message; Start-Sleep -Milliseconds 200 }
            } finally {
                if ($stream) { try { $stream.Dispose() } catch { } }
                if ($tcp) { try { $tcp.Close() } catch { } }
            }
        }
    }
    $body = $downBody
    if ($Direction -eq 'Up') { $body = $upBody }

    $pool = [RunspaceFactory]::CreateRunspacePool(1, $Streams)
    $pool.Open()
    $jobs = New-Object 'System.Collections.Generic.List[object]'
    try {
        for ($i = 0; $i -lt $Streams; $i++) {
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $pool
            $null = $ps.AddScript($body, $true).AddArgument($Url).AddArgument($i).AddArgument($shared).AddArgument($TimeoutMs).AddArgument($ChunkBytes)
            $jobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
        }

        $times = New-Object 'System.Collections.Generic.List[double]'
        $bytes = New-Object 'System.Collections.Generic.List[double]'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
            Start-Sleep -Milliseconds 100
            $sum = 0.0
            for ($i = 0; $i -lt $Streams; $i++) { $sum += [double]$shared['b' + $i] }
            $times.Add($sw.Elapsed.TotalSeconds)
            $bytes.Add($sum)
        }
        $shared.Stop = $true
    } finally {
        $shared.Stop = $true
        foreach ($j in $jobs) {
            try { $null = $j.Handle.AsyncWaitHandle.WaitOne(3000) } catch { }
            try { $j.PS.Stop() } catch { }
            try { $j.PS.Dispose() } catch { }
        }
        try { $pool.Close(); $pool.Dispose() } catch { }
    }

    $n = $bytes.Count
    if ($n -lt 2) { $res['err'] = 'no samples'; return $res }
    $res['bytes'] = $bytes[$n - 1]
    # Steady state: from the end of the warm-up to the end.
    $k = 0
    while ($k -lt $n - 1 -and $times[$k] -lt $WarmupSeconds) { $k++ }
    $span = $times[$n - 1] - $times[$k]
    if ($span -lt 1.0) { $k = 0; $span = $times[$n - 1] }
    $res['seconds'] = [math]::Round($span, 2)
    $got = $bytes[$n - 1] - $(if ($k -gt 0) { $bytes[$k] } else { 0.0 })
    if ($got -gt 0 -and $span -gt 0) {
        $res['mbps'] = [math]::Round($got * 8.0 / $span / 1000000.0, 2)
        $res['ok'] = $true
        # Best one-second window after the warm-up, for the note.
        $peak = 0.0
        for ($a = $k; $a -lt $n; $a++) {
            for ($b = $a + 1; $b -lt $n; $b++) {
                if ($times[$b] - $times[$a] -ge 1.0) {
                    $r = ($bytes[$b] - $bytes[$a]) * 8.0 / ($times[$b] - $times[$a]) / 1000000.0
                    if ($r -gt $peak) { $peak = $r }
                    break
                }
            }
        }
        $res['peak_mbps'] = [math]::Round($peak, 2)
    }
    $errs = @()
    for ($i = 0; $i -lt $Streams; $i++) { if ($shared['e' + $i]) { $errs += [string]$shared['e' + $i] } }
    $errs = @($errs | Select-Object -Unique)
    if (-not $res['ok']) {
        if ($errs.Count -gt 0) { $res['err'] = $errs[0] } else { $res['err'] = 'nothing transferred' }
    } elseif ($errs.Count -gt 0) {
        $res['err'] = 'some streams failed: ' + $errs[0]
    }
    $res
}

function Resolve-SpeedServerIp {
    # The test server's IPv4 address, resolved once so the latency samples
    # time the network, not DNS.
    param([string]$Url)
    try {
        $h = ([uri]$Url).Host
        foreach ($a in [System.Net.Dns]::GetHostAddresses($h)) {
            if ($a.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { return $a.ToString() }
        }
    } catch { }
    $null
}

function Invoke-CloudflareSpeedTest {
    # Free, no account, no licence question. Measured the way Ookla measures:
    # parallel streams for a fixed time, warm-up excluded, and latency to the
    # test server itself (TCP connect time, reported as IQM) - at rest, then
    # while downloading, then while uploading.
    param($Config)
    $secs    = [int]$Config['SpeedTestMaxSecondsPerDirection']
    $tmo     = [int]$Config['SpeedTestTimeoutMs']
    $streams = [int]$Config['SpeedTestStreams']

    $server = Resolve-SpeedServerIp -Url ([string]$Config['CloudflareDownUrl'])
    $latTarget = $server; $latPort = ([uri][string]$Config['CloudflareDownUrl']).Port
    if (-not $latTarget) { $latTarget = [string]@($Config['PingTargets'])[0]; $latPort = 0 }

    $idle = Measure-IdleLatency -Target $latTarget -TcpPort $latPort

    $smp = Start-LatencySampler -Target $latTarget -TcpPort $latPort
    $down = Invoke-MultiStreamTransfer -Direction Down -Url ([string]$Config['CloudflareDownUrl']) -Streams $streams `
                -Seconds $secs -ChunkBytes ([long]$Config['SpeedTestDownloadBytes']) -TimeoutMs $tmo
    $downLat = (Stop-LatencySampler $smp).Ms

    $smp = Start-LatencySampler -Target $latTarget -TcpPort $latPort
    $up = Invoke-MultiStreamTransfer -Direction Up -Url ([string]$Config['CloudflareUpUrl']) -Streams $streams `
                -Seconds $secs -ChunkBytes ([long]$Config['SpeedTestUploadBytes']) -TimeoutMs $tmo
    $upLat = (Stop-LatencySampler $smp).Ms

    New-Object PSObject -Property ([ordered]@{
        Backend = 'cloudflare'
        Down = $down; Up = $up
        LatencyMs = $idle.Ms; JitterMs = $idle.Jitter; DownLatencyMs = $downLat; UpLatencyMs = $upLat
        LatencyMethod = $idle.Method; Server = ('Cloudflare ' + $server).Trim(); ResultUrl = ''
    })
}

function Get-OoklaExe {
    # OoklaExePath, then the copy Install-OoklaCli puts next to the script,
    # then PATH.
    param($Config)
    $exe = [string]$Config['OoklaExePath']
    if ($exe -and (Test-Path -LiteralPath $exe)) { return $exe }
    $local = Join-Path $script:ScriptDir 'tools\ookla\speedtest.exe'
    if (Test-Path -LiteralPath $local) { return $local }
    $cmd = Get-Command 'speedtest.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $null
}

function Install-OoklaCli {
    # Ookla's official CLI (free for personal use; check the licence before
    # using it at a client site). Downloaded into tools\ookla beside the script.
    $dir = Join-Path $script:ScriptDir 'tools\ookla'
    $zip = Join-Path ([System.IO.Path]::GetTempPath()) 'ookla-speedtest-win64.zip'
    $url = 'https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip'
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $null = New-Item -ItemType Directory -Path $dir -Force
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -ErrorAction Stop
        Expand-Archive -Path $zip -DestinationPath $dir -Force -ErrorAction Stop
    } finally {
        $ProgressPreference = $old
        try { Remove-Item -LiteralPath $zip -Force -ErrorAction Stop } catch { }
    }
    $exe = Join-Path $dir 'speedtest.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "downloaded, but speedtest.exe was not in the archive" }
    $exe
}

function Invoke-OoklaSpeedTest {
    # The number people recognise. Check the licence before using it at a
    # client site: the official CLI is free for personal use, not commercial.
    param($Config)

    $exe = Get-OoklaExe -Config $Config
    if (-not $exe) {
        throw "Ookla backend selected but speedtest.exe was not found. Switch the backend to ookla in Settings (9) to download it, set OoklaExePath, or use the cloudflare backend."
    }

    # The website and the CLI can pick different servers; pin one with
    # OoklaServerId to compare like for like.
    $cliArgs = '-f json --accept-license --accept-gdpr'
    if ([int]$Config['OoklaServerId'] -gt 0) { $cliArgs += ' -s ' + [int]$Config['OoklaServerId'] }
    $secs = [math]::Max(90, [int]($Config['SpeedTestTimeoutMs'] / 1000))
    $json = Invoke-CaptureCommand -FilePath $exe -Arguments $cliArgs -TimeoutSec $secs
    $obj = $null
    try { $obj = ConvertFrom-Json -InputObject $json } catch { throw "Could not parse speedtest.exe output: $($_.Exception.Message)" }

    $down = [ordered]@{ ok = $false; bytes = 0.0; seconds = $null; mbps = $null; err = ''; truncated = $false }
    $up   = [ordered]@{ ok = $false; bytes = 0.0; seconds = $null; mbps = $null; err = ''; truncated = $false }
    $lat = $null; $jit = $null; $server = ''; $resultUrl = ''
    try {
        # bandwidth is bytes per second in the Ookla JSON, not bits.
        $down['mbps'] = [math]::Round([double]$obj.download.bandwidth * 8.0 / 1000000.0, 2)
        $down['bytes'] = [double]$obj.download.bytes
        $down['seconds'] = [math]::Round([double]$obj.download.elapsed / 1000.0, 3)
        $down['ok'] = $true
    } catch { $down['err'] = 'no download section in output' }
    try {
        $up['mbps'] = [math]::Round([double]$obj.upload.bandwidth * 8.0 / 1000000.0, 2)
        $up['bytes'] = [double]$obj.upload.bytes
        $up['seconds'] = [math]::Round([double]$obj.upload.elapsed / 1000.0, 3)
        $up['ok'] = $true
    } catch { $up['err'] = 'no upload section in output' }
    try { $lat = [math]::Round([double]$obj.ping.latency, 2) } catch { }
    try { $jit = [math]::Round([double]$obj.ping.jitter, 2) } catch { }
    $dLat = $null; $uLat = $null
    try { if ($null -ne $obj.download.latency.iqm) { $dLat = [math]::Round([double]$obj.download.latency.iqm, 1) } } catch { }
    try { if ($null -ne $obj.upload.latency.iqm) { $uLat = [math]::Round([double]$obj.upload.latency.iqm, 1) } } catch { }
    try { $server = [string]$obj.server.name + ' (' + [string]$obj.server.location + ')' } catch { }
    try { $resultUrl = [string]$obj.result.url } catch { }

    New-Object PSObject -Property ([ordered]@{
        Backend = 'ookla'
        Down = $down; Up = $up
        LatencyMs = $lat; JitterMs = $jit; DownLatencyMs = $dLat; UpLatencyMs = $uLat
        LatencyMethod = 'ookla'; Server = $server; ResultUrl = $resultUrl
    })
}

function Invoke-FileSpeedTest {
    # Crude but dependency-free: time a download of something of known size.
    # Download only - there is nowhere to upload to.
    param($Config)
    $url = [string]$Config['SpeedTestFileUrl']
    if (-not $url) { throw "The 'file' backend needs SpeedTestFileUrl set in the config." }
    $pingTo = [string]@($Config['PingTargets'])[0]
    $idle = Measure-IdleLatency -Target $pingTo
    $smp = Start-LatencySampler -Target $pingTo
    $down = Measure-HttpDownload -Url $url -TimeoutMs ([int]$Config['SpeedTestTimeoutMs']) `
                                 -MaxSeconds ([int]$Config['SpeedTestMaxSecondsPerDirection'])
    $downLat = (Stop-LatencySampler $smp).Ms
    $up = [ordered]@{ ok = $false; bytes = 0.0; seconds = $null; mbps = $null; err = 'not measured by this backend'; truncated = $false }
    New-Object PSObject -Property ([ordered]@{
        Backend = 'file'; Down = $down; Up = $up
        LatencyMs = $idle.Ms; JitterMs = $idle.Jitter; DownLatencyMs = $downLat; UpLatencyMs = $null
        LatencyMethod = $idle.Method; Server = ([uri]$url).Host; ResultUrl = ''
    })
}

function Invoke-SpeedTest {
    # One test, one row, exit. Never blocks the fast probe: it is a separate
    # Scheduled Task in a separate process.
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$State,
          [Parameter(Mandatory = $true)][DateTimeOffset]$Started, [switch]$IgnoreBusy, [switch]$Manual)

    $row = [ordered]@{
        timestamp = Get-Timestamp -When $Started
        status    = 'ok'
        backend   = [string]$Config['SpeedTestBackend']
        down_mbps = $null; up_mbps = $null
        down_bytes = $null; up_bytes = $null
        down_s = $null; up_s = $null
        truncated = $false
        latency_ms = $null; jitter_ms = $null
        latency_down_ms = $null; latency_up_ms = $null; latency_method = ''
        server = ''; result_url = ''
        busy_pct_before = $null
        iface = ''; link_speed = ''; public_ip = ''
        note = ''
        netmon_ver = $script:NetmonVersion
    }

    # Which interface are we about to saturate?
    $adapterName = ''; $linkBps = $null
    try {
        $targets = @($Config['PingTargets'])
        $route = Get-PrimaryRoute -Probe $targets[0]
        if ($route) {
            $row['iface'] = $route.IfAlias
            $ad = Get-AdapterInfo -IfIndex $route.IfIndex
            $adapterName = [string]$ad['adapter_name']
            $linkBps = $ad['link_bps']
            $row['link_speed'] = [string]$ad['link_speed']
        }
    } catch {
        $row['note'] = 'could not identify the active adapter: ' + $_.Exception.Message
    }

    # Guard 1: is the line already carrying real traffic? Recording a low
    # number from a busy line is worse than recording nothing, because it
    # looks like a fault later.
    $busy = Get-BusyPercent -AdapterName $adapterName -LinkBps $linkBps -SampleMs ([int]$Config['SpeedTestBusySampleMs'])
    $row['busy_pct_before'] = $busy
    if (-not $IgnoreBusy -and $null -ne $busy -and $busy -gt [double]$Config['SpeedTestMaxBusyPct']) {
        $row['status'] = 'skipped: line busy'
        $row['note'] = ('{0}% of {1} in use; threshold is {2}%' -f $busy, $row['link_speed'], $Config['SpeedTestMaxBusyPct'])
        $null = Add-CsvRow -Kind 'speedtest' -Row $row -When $Started
        Write-NetmonLog "Speed test skipped: line busy ($busy%)."
        return $row
    }

    # Guard 2: a schedule must not hammer the line. Someone who asked for a
    # test by hand gets one.
    $minGap = [int]$Config['SpeedTestMinGapMinutes']
    if ($State.ContainsKey('LastSpeedTest')) {
        $last = ConvertFrom-Timestamp ([string]$State['LastSpeedTest'])
        if ($last) {
            $mins = ($Started - $last).TotalMinutes
            if (-not $Manual -and $mins -lt $minGap) {
                $row['status'] = 'skipped: too soon'
                $row['note'] = ('last test was {0} minutes ago; minimum gap for scheduled tests is {1} minutes' -f [math]::Round($mins, 1), $minGap)
                $null = Add-CsvRow -Kind 'speedtest' -Row $row -When $Started
                Write-NetmonLog -Level WARN "Speed test skipped: only $([math]::Round($mins,1)) minutes since the last one."
                return $row
            }
        }
    }

    # While this file exists an open dashboard pauses its packet capture:
    # pktmon inspecting every packet at full line rate costs enough CPU to
    # pull the result down, upload most of all.
    $lock = Join-Path $script:DataDir 'speedtest.running'
    try { Set-Content -LiteralPath $lock -Value $PID -ErrorAction Stop; Start-Sleep -Milliseconds 1500 } catch { }
    try {
        switch ([string]$Config['SpeedTestBackend']) {
            'ookla'      { $r = Invoke-OoklaSpeedTest -Config $Config }
            'file'       { $r = Invoke-FileSpeedTest -Config $Config }
            default      { $r = Invoke-CloudflareSpeedTest -Config $Config }
        }

        $row['backend']    = $r.Backend
        $row['down_mbps']  = $r.Down['mbps']
        $row['down_bytes'] = $r.Down['bytes']
        $row['down_s']     = $r.Down['seconds']
        $row['up_mbps']    = $r.Up['mbps']
        $row['up_bytes']   = $r.Up['bytes']
        $row['up_s']       = $r.Up['seconds']
        $row['truncated']  = ($r.Down['truncated'] -or $r.Up['truncated'])
        $row['latency_ms'] = $r.LatencyMs
        $row['jitter_ms']  = $r.JitterMs
        $row['latency_down_ms'] = $r.DownLatencyMs
        $row['latency_up_ms']   = $r.UpLatencyMs
        $row['latency_method']  = $r.LatencyMethod
        $row['server']     = $r.Server
        $row['result_url'] = $r.ResultUrl

        $notes = New-Object 'System.Collections.Generic.List[string]'
        if ($row['note']) { [void]$notes.Add([string]$row['note']) }
        if (-not $r.Down['ok']) { [void]$notes.Add('download: ' + $r.Down['err']) }
        if (-not $r.Up['ok'] -and $r.Up['err']) { [void]$notes.Add('upload: ' + $r.Up['err']) }
        if ($row['truncated']) { [void]$notes.Add('transfer capped at ' + $Config['SpeedTestMaxSecondsPerDirection'] + 's; rate is still valid') }
        $row['note'] = $notes -join '; '

        if (-not $r.Down['ok'] -and -not $r.Up['ok']) { $row['status'] = 'failed' }
        elseif (-not $r.Down['ok'] -or (-not $r.Up['ok'] -and $r.Backend -ne 'file')) { $row['status'] = 'partial' }
    } catch {
        $row['status'] = 'failed'
        $row['note'] = $_.Exception.Message
    } finally {
        try { Remove-Item -LiteralPath $lock -Force -ErrorAction Stop } catch { }
    }

    # Reuse the probe's public IP if a recent row has one - cheaper than asking again.
    try {
        $recent = @(Get-TailRows -Kind 'probe' -Count 3)
        if ($recent.Count -gt 0) { $row['public_ip'] = [string](Get-Field $recent[$recent.Count - 1] 'public_ip') }
    } catch { }

    $State['LastSpeedTest'] = Get-Timestamp -When $Started
    $null = Add-CsvRow -Kind 'speedtest' -Row $row -When $Started
    Write-NetmonLog ("Speed test {0}: down {1} Mbps, up {2} Mbps, latency idle {3} / down {4} / up {5} ms" -f
        $row['status'], $row['down_mbps'], $row['up_mbps'], $row['latency_ms'], $row['latency_down_ms'], $row['latency_up_ms'])
    $row
}

#endregion
#region ---- Scheduled tasks ---------------------------------------------------

# Two tasks, deliberately separate: a hung speed test must not be able to
# block the fast probe, and they run on completely different cadences.

function Test-Elevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-HostExecutable {
    # Always the Windows PowerShell 5.1 host this script was written for,
    # never whatever "pwsh" happens to be on PATH.
    $exe = Join-Path $PSHOME 'powershell.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    return 'powershell.exe'
}

function Test-ScheduledTaskSupport {
    if (-not (Get-Command 'Register-ScheduledTask' -ErrorAction SilentlyContinue)) {
        throw "The ScheduledTasks module is not available on this machine, so PS-NETMON cannot register its tasks. Create them by hand in Task Scheduler, or use schtasks.exe."
    }
}

function New-NetmonTaskArgument {
    param([string]$TaskMode)
    $a = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode {1} -Scheduled' -f
         $script:ScriptPath, $TaskMode
    if ($ConfigPath -and $ConfigPath -ne $script:DefaultConfigPath) {
        $a += ' -ConfigPath "{0}"' -f $ConfigPath
    }
    $a
}

function Register-NetmonTask {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$TaskMode,
        [Parameter(Mandatory = $true)][TimeSpan]$Interval,
        [Parameter(Mandatory = $true)][string]$Description,
        [int]$TimeLimitMinutes = 10
    )

    # Every ScheduledTasks cmdlet gets -ErrorAction Stop explicitly. They live
    # in a module, and a module does not see this script's
    # $ErrorActionPreference = 'Stop': without it a rejected registration is
    # only a warning, the code carries on, and "Registered" is printed for a
    # task that does not exist.
    $action = New-ScheduledTaskAction -Execute (Get-HostExecutable) `
                                      -Argument (New-NetmonTaskArgument -TaskMode $TaskMode) `
                                      -WorkingDirectory $script:ScriptDir -ErrorAction Stop

    # One trigger: starts a minute from now, then repeats indefinitely.
    # StartWhenAvailable is what makes it pick itself up again after a reboot
    # or after the machine has been asleep.
    # Not TimeSpan.MaxValue as the duration: Windows 10/11 accept it when the
    # trigger is built and then reject the whole task at registration
    # ("value incorrectly formatted or out of range"). An empty duration is
    # Task Scheduler's own spelling of "indefinitely".
    $start = (Get-Date).AddMinutes(1)
    $trigger = $null
    try {
        $trigger = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval $Interval -ErrorAction Stop
    } catch {
        # Older builds insist on a duration.
        $trigger = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval $Interval `
                        -RepetitionDuration ([TimeSpan]::FromDays(3650)) -ErrorAction Stop
    }
    if ($trigger.Repetition -and [string]$trigger.Repetition.Duration -like 'P99999999*') { $trigger.Repetition.Duration = '' }

    $settings = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes $TimeLimitMinutes) `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ErrorAction Stop
    # Not -Hidden: that hides the task from Task Scheduler's own list (and from
    # Get-ScheduledTask), which only makes an installed task look missing.
    # No console window appears either way: the action runs powershell.exe
    # with -WindowStyle Hidden, and as SYSTEM it runs in session 0.

    if (Test-Elevated) {
        # SYSTEM: runs whether or not anyone is logged in, which is the point.
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest -ErrorAction Stop
    } else {
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited -ErrorAction Stop
    }

    $regArgs = @{
        TaskName = $Name; TaskPath = $script:TaskPath; Action = $action; Trigger = $trigger
        Settings = $settings; Principal = $principal; Description = $Description; Force = $true; ErrorAction = 'Stop'
    }
    try {
        $null = Register-ScheduledTask @regArgs
    } catch {
        # One retry with a plain ten-year duration, in case this build also
        # dislikes the empty one. Anything else is a real error: report it.
        $first = $_.Exception.Message
        try {
            $trigger.Repetition.Duration = 'P3650D'
            $regArgs['Trigger'] = $trigger
            $null = Register-ScheduledTask @regArgs
        } catch {
            throw ("Task Scheduler rejected '{0}': {1}" -f $Name, $first)
        }
    }

    # Read it back. Registered must mean Task Scheduler can see it.
    try { $null = Get-ScheduledTask -TaskName $Name -TaskPath $script:TaskPath -ErrorAction Stop }
    catch { throw ("'{0}' was accepted but cannot be found afterwards: {1}" -f $Name, $_.Exception.Message) }
}

function Install-NetmonTasks {
    param([Parameter(Mandatory = $true)]$Config)

    Test-ScheduledTaskSupport
    if (-not $script:ScriptPath) { throw "Cannot register tasks: the script path is unknown (run the .ps1 from disk, not pasted into a console)." }

    $lines = New-Object 'System.Collections.Generic.List[string]'

    # --- fast probe ---
    $sec = [int]$Config['ProbeIntervalSeconds']
    if ($sec -lt 60) {
        $lines.Add("  note: Task Scheduler cannot repeat faster than once a minute; using 60s, not ${sec}s.")
        $sec = 60
    }
    Register-NetmonTask -Name $script:TaskCollect -TaskMode 'Collect' `
        -Interval ([TimeSpan]::FromSeconds($sec)) `
        -Description "PS-NETMON layered network probe, every ${sec}s. One row per cycle in $script:DataDir." `
        -TimeLimitMinutes 5
    $lines.Add("  $script:TaskCollect  - every ${sec}s")

    # --- speed test ---
    $hours = [int]$Config['SpeedTestIntervalHours']
    if ($hours * 60 -lt 15) {
        throw "SpeedTestIntervalHours=$hours is under the 15 minute minimum. A speed test consumes what it measures; running one every few minutes can burn 100GB a day and will produce wrong numbers. Raise it in the config."
    }
    Register-NetmonTask -Name $script:TaskSpeed -TaskMode 'SpeedTest' `
        -Interval ([TimeSpan]::FromHours($hours)) `
        -Description "PS-NETMON speed test, every ${hours}h, skipped automatically when the line is busy." `
        -TimeLimitMinutes 10
    $lines.Add("  $script:TaskSpeed - every ${hours}h ($($Config['SpeedTestBackend']) backend)")

    if (Test-Elevated) {
        $lines.Add('  running as SYSTEM: collection continues when nobody is logged in.')
    } else {
        $lines.Add('  running as ' + $env:USERNAME + ': collection only happens while you are logged in.')
        $lines.Add('  re-run this from an elevated PowerShell to have it run as SYSTEM instead.')
    }
    # Read them back: "registered" should mean Task Scheduler can see them.
    foreach ($t in @(Get-NetmonTaskStatus)) {
        if ($t.Installed) { $lines.Add(('  check: {0} found, {1}, next run {2}' -f $t.Name, $t.State, $t.NextRun)) }
        else { $lines.Add(('  check: {0} NOT found after registering {1}' -f $t.Name, $t.Error)) }
    }
    Write-NetmonLog ('Registered scheduled tasks (probe {0}s, speed {1}h).' -f $sec, $hours)
    $lines.ToArray()
}

function Uninstall-NetmonTasks {
    # Removes the tasks from whichever folder they were found in, cmdlets
    # first and schtasks.exe as the fallback. Failures are thrown, not hidden.
    $removed = New-Object 'System.Collections.Generic.List[string]'
    $errors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($t in @(Get-NetmonTaskStatus)) {
        if (-not $t.Installed) { continue }
        $path = $t.Path
        if (-not $path) { $path = $script:TaskPath }
        $ok = $false
        if (Get-Command 'Unregister-ScheduledTask' -ErrorAction SilentlyContinue) {
            try {
                Unregister-ScheduledTask -TaskName $t.Name -TaskPath $path -Confirm:$false -ErrorAction Stop
                $ok = $true
            } catch { $errors.Add($t.Name + ': ' + $_.Exception.Message) }
        }
        if (-not $ok) {
            $null = & schtasks.exe /Delete /TN ($path + $t.Name) /F 2>&1
            if ($LASTEXITCODE -eq 0) { $ok = $true; $errors.Clear() }
        }
        if ($ok) { $removed.Add($t.Name) }
    }
    if ($removed.Count -gt 0) { Write-NetmonLog ('Removed scheduled tasks: ' + ($removed -join ', ')) }
    if ($errors.Count -gt 0 -and $removed.Count -eq 0) { throw ($errors -join '; ') }
    $removed.ToArray()
}

function Get-NetmonTaskStatus {
    # Same code the Settings tab runs in the background, so the command line
    # and the dashboard can never disagree about what is installed.
    $r = & $script:TaskStatusScript $script:TaskPath ([string[]]@($script:TaskCollect, $script:TaskSpeed))
    @($r.Tasks)
}

#endregion
#region ---- Reporter ----------------------------------------------------------

# Reads the CSVs and writes ONE self-contained HTML file: data embedded as
# JSON, charts drawn client-side, no server, no CDN, no internet needed to
# open it. Double-click, or email it to a client.
#
# Downsampling is not optional. A browser chart dies somewhere past 10-20k
# points and a year of minute data is 525,600. Aggregation by age keeps it
# under a few thousand - and every bucket keeps MIN and MAX alongside the
# average, because averaging an hour that contains a 90 second outage makes
# the outage disappear into a slightly elevated mean, and the outages are the
# entire point of the exercise.

function Get-EpochMs {
    param([DateTimeOffset]$When)
    $epoch = New-Object DateTime(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    [long](($When.UtcDateTime - $epoch).TotalMilliseconds)
}

function New-Bucket {
    @{ N = 0; LatN = 0; Sum = 0.0; Min = $null; Max = $null
       LossSum = 0.0; LossN = 0; LossMax = $null; Up = 0 }
}

function Get-ReportModel {
    # Everything the HTML needs, and nothing else.
    param([Parameter(Mandatory = $true)]$Config, [int]$Days = 30)

    $now   = [DateTimeOffset]::Now
    $since = $now.AddDays(-[math]::Abs($Days))

    $rawCutoff    = $now.AddHours(-[int]$Config['ReportRawHours'])
    $hourlyCutoff = $now.AddDays(-[int]$Config['ReportHourlyDays'])

    $buckets = @{}
    $heatUp  = New-Object 'int[][]' 7
    $heatAll = New-Object 'int[][]' 7
    for ($i = 0; $i -lt 7; $i++) {
        $heatUp[$i]  = New-Object 'int[]' 24
        $heatAll[$i] = New-Object 'int[]' 24
    }

    $total = 0; $upCount = 0
    $latSum = 0.0; $latN = 0; $latMax = $null
    $lossSum = 0.0; $lossN = 0

    foreach ($r in (Import-DataRows -Kind 'probe' -Since $since.DateTime)) {
        $ts = ConvertFrom-Timestamp ([string](Get-Field $r 'timestamp'))
        if (-not $ts -or $ts -lt $since) { continue }

        $m = Get-RowMetrics -Row $r
        $lat = $m['LatencyMs']
        $loss = $m['LossPct']
        $healthy = -not [string](Get-Field $r 'failed_layers')

        $total++
        if ($healthy) { $upCount++ }
        if ($null -ne $lat) {
            $latSum += $lat; $latN++
            if ($null -eq $latMax -or $lat -gt $latMax) { $latMax = $lat }
        }
        if ($null -ne $loss) { $lossSum += $loss; $lossN++ }

        # Local wall clock at capture: "every weekday at 5pm" is a local-time
        # statement, and the offset in the timestamp is what makes that safe
        # across a DST boundary.
        $local = $ts.DateTime
        $dow = [int]$local.DayOfWeek      # Sunday = 0
        $dow = ($dow + 6) % 7             # shift so Monday = 0
        $heatAll[$dow][$local.Hour]++
        if ($healthy) { $heatUp[$dow][$local.Hour]++ }

        # Bucket by age.
        if ($ts -ge $rawCutoff) {
            $key = [long]((Get-EpochMs -When $ts) / 1000)
        } elseif ($ts -ge $hourlyCutoff) {
            $h = New-Object DateTimeOffset($local.Year, $local.Month, $local.Day, $local.Hour, 0, 0, $ts.Offset)
            $key = [long]((Get-EpochMs -When $h) / 1000)
        } else {
            $d = New-Object DateTimeOffset($local.Year, $local.Month, $local.Day, 0, 0, 0, $ts.Offset)
            $key = [long]((Get-EpochMs -When $d) / 1000)
        }

        if (-not $buckets.ContainsKey($key)) { $buckets[$key] = New-Bucket }
        $b = $buckets[$key]
        $b['N']++
        if ($healthy) { $b['Up']++ }
        if ($null -ne $lat) {
            $b['Sum'] += $lat; $b['LatN']++
            if ($null -eq $b['Min'] -or $lat -lt $b['Min']) { $b['Min'] = $lat }
            if ($null -eq $b['Max'] -or $lat -gt $b['Max']) { $b['Max'] = $lat }
        }
        if ($null -ne $loss) {
            $b['LossSum'] += $loss; $b['LossN']++
            if ($null -eq $b['LossMax'] -or $loss -gt $b['LossMax']) { $b['LossMax'] = $loss }
        }
    }

    $series = New-Object 'System.Collections.Generic.List[object]'
    foreach ($k in @($buckets.Keys | Sort-Object)) {
        $b = $buckets[$k]
        # Averaged over the cycles that actually produced a latency figure -
        # a cycle where everything timed out must not count as 0ms.
        $avg = $null
        if ($b['LatN'] -gt 0) { $avg = [math]::Round($b['Sum'] / $b['LatN'], 1) }

        $lossAvg = $null
        if ($b['LossN'] -gt 0) { $lossAvg = [math]::Round($b['LossSum'] / $b['LossN'], 2) }

        $series.Add([ordered]@{
            t       = [long]$k * 1000
            avg     = $avg
            min     = $b['Min']
            max     = $b['Max']
            loss    = $lossAvg
            lossMax = $b['LossMax']
            n       = $b['N']
            up      = $b['Up']
        })
    }

    # --- events -----------------------------------------------------------
    $events = New-Object 'System.Collections.Generic.List[object]'
    $outages = 0; $degradations = 0; $downSeconds = 0.0; $lastDown = $null
    foreach ($e in (Import-DataRows -Kind 'events' -Since $since.DateTime)) {
        $ts = ConvertFrom-Timestamp ([string](Get-Field $e 'timestamp'))
        if (-not $ts -or $ts -lt $since) { continue }
        $to = [string](Get-Field $e 'to_state')
        $from = [string](Get-Field $e 'from_state')
        $dur = ConvertTo-Num (Get-Field $e 'prev_duration_s')
        if ($to -eq 'Down') { $outages++; $lastDown = $ts }
        if ($to -eq 'Degraded') { $degradations++ }
        if ($from -eq 'Down' -and $null -ne $dur) { $downSeconds += $dur }
        $events.Add([ordered]@{
            t      = Get-EpochMs -When $ts
            from   = $from
            to     = $to
            dur    = $dur
            reason = [string](Get-Field $e 'reason')
            diag   = [string](Get-Field $e 'diag_file')
        })
    }
    # An outage still in progress has not written its recovery row yet, so its
    # time would otherwise be missing from the total.
    if ($events.Count -gt 0) {
        $lastEv = $events[$events.Count - 1]
        if ([string]$lastEv['to'] -eq 'Down') {
            $downSeconds += ((Get-EpochMs -When $now) - [long]$lastEv['t']) / 1000.0
        }
    }

    # --- speed tests ------------------------------------------------------
    $speed = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in (Import-DataRows -Kind 'speedtest' -Since $since.DateTime)) {
        $ts = ConvertFrom-Timestamp ([string](Get-Field $s 'timestamp'))
        if (-not $ts -or $ts -lt $since) { continue }
        $status = [string](Get-Field $s 'status')
        if ($status -like 'skipped*' -or $status -eq 'failed') { continue }
        $d = ConvertTo-Num (Get-Field $s 'down_mbps')
        $u = ConvertTo-Num (Get-Field $s 'up_mbps')
        if ($null -eq $d -and $null -eq $u) { continue }
        $speed.Add([ordered]@{ t = Get-EpochMs -When $ts; down = $d; up = $u })
    }

    # --- heatmap ----------------------------------------------------------
    $heat = New-Object 'object[]' 7
    for ($d = 0; $d -lt 7; $d++) {
        $rowArr = New-Object 'object[]' 24
        for ($h = 0; $h -lt 24; $h++) {
            if ($heatAll[$d][$h] -gt 0) {
                $rowArr[$h] = [math]::Round(100.0 * $heatUp[$d][$h] / $heatAll[$d][$h], 2)
            } else { $rowArr[$h] = $null }
        }
        $heat[$d] = $rowArr
    }

    $summary = [ordered]@{
        rows         = $total
        uptimePct    = $(if ($total -gt 0) { [math]::Round(100.0 * $upCount / $total, 3) } else { $null })
        outages      = $outages
        degradations = $degradations
        downSeconds  = [math]::Round($downSeconds, 0)
        avgLatency   = $(if ($latN -gt 0) { [math]::Round($latSum / $latN, 2) } else { $null })
        maxLatency   = $latMax
        avgLoss      = $(if ($lossN -gt 0) { [math]::Round($lossSum / $lossN, 3) } else { $null })
        lastDown     = $(if ($lastDown) { Get-EpochMs -When $lastDown } else { $null })
    }

    [ordered]@{
        version     = $script:NetmonVersion
        host        = $(if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'this machine' })
        generatedMs = Get-EpochMs -When $now
        rangeText   = ('{0} to {1} ({2} days)' -f $since.ToString('d MMM yyyy', $script:Invariant),
                                                  $now.ToString('d MMM yyyy', $script:Invariant),
                                                  [math]::Abs($Days))
        rawHours    = [int]$Config['ReportRawHours']
        hourlyDays  = [int]$Config['ReportHourlyDays']
        summary     = $summary
        series      = $series.ToArray()
        speed       = $speed.ToArray()
        events      = $events.ToArray()
        heat        = $heat
    }
}

function Get-ReportTemplate {
    $tpl = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>
  :root{
    --bg:#0f1216; --panel:#161b22; --line:#232b36; --ink:#dfe6ee; --muted:#8b97a6;
    --accent:#4da3ff; --accent-soft:rgba(77,163,255,.16);
    --bad:#ff6b6b; --warn:#ffb454; --good:#3ddc97;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--ink);
       font:14px/1.5 "Segoe UI",system-ui,-apple-system,sans-serif}
  header{padding:22px 24px 14px;border-bottom:1px solid var(--line)}
  h1{margin:0 0 4px;font-size:19px;font-weight:600;letter-spacing:.2px}
  .sub{color:var(--muted);font-size:12.5px}
  main{padding:18px 24px 60px;max-width:1280px;margin:0 auto}
  .cards{display:flex;flex-wrap:wrap;gap:12px;margin:18px 0 26px}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:8px;
        padding:12px 16px;min-width:152px;flex:1 1 152px}
  .card .k{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.7px}
  .card .v{font-size:22px;font-weight:600;margin-top:3px;font-variant-numeric:tabular-nums;white-space:nowrap}
  .card .n{color:var(--muted);font-size:11.5px;margin-top:2px}
  section{background:var(--panel);border:1px solid var(--line);border-radius:8px;
          padding:16px 18px 20px;margin-bottom:20px}
  section h2{margin:0 0 2px;font-size:14px;font-weight:600}
  section .hint{color:var(--muted);font-size:12px;margin:0 0 14px}
  .wrap{position:relative;width:100%}
  canvas{display:block;width:100%}
  .legend{display:flex;gap:16px;flex-wrap:wrap;color:var(--muted);font-size:12px;margin-top:10px}
  .legend i{display:inline-block;width:11px;height:11px;border-radius:2px;margin-right:6px;vertical-align:-1px}
  table{border-collapse:collapse;width:100%;font-size:12.5px}
  th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top}
  th{color:var(--muted);font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.6px}
  td.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
  .pill{display:inline-block;padding:1px 8px;border-radius:99px;font-size:11px;font-weight:600}
  .p-down{background:rgba(255,107,107,.16);color:var(--bad)}
  .p-deg{background:rgba(255,180,84,.16);color:var(--warn)}
  .p-up{background:rgba(61,220,151,.14);color:var(--good)}
  .empty{color:var(--muted);font-style:italic;padding:12px 0}
  .tip{position:absolute;pointer-events:none;background:#0b0e12;border:1px solid var(--line);
       border-radius:6px;padding:7px 10px;font-size:12px;white-space:nowrap;opacity:0;
       transition:opacity .08s;z-index:5;box-shadow:0 6px 20px rgba(0,0,0,.45)}
  .hm{overflow-x:auto}
  .hm table{border-collapse:separate;border-spacing:2px;width:auto}
  .hm td,.hm th{border:none;padding:0}
  .hm th{padding:2px 6px;font-size:10.5px}
  .hm .cell{width:26px;height:22px;border-radius:3px;background:#1b2028}
  .scale{display:flex;align-items:center;gap:8px;color:var(--muted);font-size:11.5px;margin-top:12px}
  .scale .sw{width:15px;height:12px;border-radius:2px}
  footer{color:var(--muted);font-size:11.5px;padding:0 24px 30px;max-width:1280px;margin:0 auto}
  code{background:#0b0e12;padding:1px 5px;border-radius:4px;font-size:12px}
</style>
</head>
<body>
<header>
  <h1>__TITLE__</h1>
  <div class="sub" id="sub"></div>
</header>
<main>
  <div class="cards" id="cards"></div>

  <section>
    <h2>Latency</h2>
    <p class="hint">Best responding target per cycle. The band is min to max within each bucket &mdash;
       averages alone hide a 90 second spike inside an hour.</p>
    <div class="wrap"><canvas id="cLat" height="260"></canvas><div class="tip" id="tLat"></div></div>
    <div class="legend">
      <span><i style="background:#4da3ff"></i>average</span>
      <span><i style="background:rgba(77,163,255,.35)"></i>min&ndash;max range</span>
    </div>
  </section>

  <section>
    <h2>Packet loss</h2>
    <p class="hint">Worst loss across the public targets in each bucket. All three failing means this end;
       one failing usually means that provider.</p>
    <div class="wrap"><canvas id="cLoss" height="190"></canvas><div class="tip" id="tLoss"></div></div>
  </section>

  <section>
    <h2>Speed tests</h2>
    <p class="hint">Separate cadence from the probe. Tests skipped because the line was busy are not plotted.</p>
    <div class="wrap"><canvas id="cSpeed" height="220"></canvas><div class="tip" id="tSpeed"></div></div>
    <div class="legend">
      <span><i style="background:#3ddc97"></i>download Mbps</span>
      <span><i style="background:#ffb454"></i>upload Mbps</span>
    </div>
  </section>

  <section>
    <h2>Availability by hour and weekday</h2>
    <p class="hint">Share of cycles fully healthy, by local time of day. This is usually the chart that
       finds the pattern &mdash; every weekday at 5pm, or always at 3am.</p>
    <div class="hm" id="heat"></div>
    <div class="scale">
      <span>worse</span>
      <span class="sw" style="background:#ff6b6b"></span>
      <span class="sw" style="background:#ffb454"></span>
      <span class="sw" style="background:#b7d94c"></span>
      <span class="sw" style="background:#3ddc97"></span>
      <span>better</span>
      <span style="margin-left:12px"><span class="sw" style="background:#1b2028;display:inline-block"></span> no data</span>
    </div>
  </section>

  <section>
    <h2>Outages and state changes</h2>
    <p class="hint">Transitions only. This is the table to send an ISP; where a diagnostic capture exists,
       the traceroute taken at that moment is in <code>data\diag</code>.</p>
    <div id="events"></div>
  </section>
</main>
<footer id="foot"></footer>

<script id="netmon-data" type="application/json">__DATA__</script>
<script>
(function(){
"use strict";
var D = JSON.parse(document.getElementById("netmon-data").textContent);
var CSS = getComputedStyle(document.documentElement);
var C = {
  ink: CSS.getPropertyValue("--ink").trim() || "#dfe6ee",
  muted: CSS.getPropertyValue("--muted").trim() || "#8b97a6",
  line: CSS.getPropertyValue("--line").trim() || "#232b36",
  accent: "#4da3ff", band: "rgba(77,163,255,.22)",
  bad: "#ff6b6b", warn: "#ffb454", good: "#3ddc97"
};

function pad(n){ return (n<10?"0":"")+n; }
function fmtClock(ms){ var d=new Date(ms); return pad(d.getHours())+":"+pad(d.getMinutes()); }
function fmtDay(ms){ var d=new Date(ms); return pad(d.getDate())+"/"+pad(d.getMonth()+1); }
function fmtFull(ms){ var d=new Date(ms);
  return d.getFullYear()+"-"+pad(d.getMonth()+1)+"-"+pad(d.getDate())+" "+pad(d.getHours())+":"+pad(d.getMinutes()); }
function fmtShort(ms){ var d=new Date(ms);
  return pad(d.getDate())+"/"+pad(d.getMonth()+1)+" "+pad(d.getHours())+":"+pad(d.getMinutes()); }
function agoText(ms){ var s=(D.generatedMs-ms)/1000;
  if(s<0) return ""; return fmtDur(s)+" ago"; }
function fmtDur(s){
  if(s===null||s===undefined||s==="") return "";
  s=Math.round(s);
  if(s<60) return s+"s";
  if(s<3600) return Math.floor(s/60)+"m "+(s%60)+"s";
  if(s<86400) return Math.floor(s/3600)+"h "+Math.floor((s%3600)/60)+"m";
  return Math.floor(s/86400)+"d "+Math.floor((s%86400)/3600)+"h";
}
function esc(s){ return String(s===null||s===undefined?"":s)
  .replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;"); }

function niceMax(v){
  if(!(v>0)) return 1;
  var e = Math.pow(10, Math.floor(Math.log(v)/Math.LN10));
  var m = v/e;
  var s = m<=1?1:m<=2?2:m<=2.5?2.5:m<=5?5:10;
  return s*e;
}

// --- canvas plumbing -------------------------------------------------------
function prep(cv){
  var dpr = window.devicePixelRatio||1;
  var w = cv.clientWidth, h = parseInt(cv.getAttribute("height"),10);
  cv.width = Math.round(w*dpr); cv.height = Math.round(h*dpr);
  cv.style.height = h+"px";
  var ctx = cv.getContext("2d");
  ctx.setTransform(dpr,0,0,dpr,0,0);
  ctx.clearRect(0,0,w,h);
  return {ctx:ctx,w:w,h:h};
}

function frame(g, pad, xmin, xmax, ymax, ylabel, spanDays){
  var ctx=g.ctx, w=g.w, h=g.h;
  var pl=pad.l, pr=pad.r, pt=pad.t, pb=pad.b;
  ctx.strokeStyle=C.line; ctx.fillStyle=C.muted; ctx.lineWidth=1;
  ctx.font='11px "Segoe UI",system-ui,sans-serif';
  var rows=4;
  for(var i=0;i<=rows;i++){
    var y = pt + (h-pt-pb)*i/rows;
    ctx.beginPath(); ctx.moveTo(pl,Math.round(y)+.5); ctx.lineTo(w-pr,Math.round(y)+.5); ctx.stroke();
    var v = ymax*(1-i/rows);
    ctx.textAlign="right"; ctx.textBaseline="middle";
    ctx.fillText(ylabel(v), pl-8, y);
  }
  var ticks=6;
  ctx.textAlign="center"; ctx.textBaseline="top";
  for(var j=0;j<=ticks;j++){
    var t = xmin + (xmax-xmin)*j/ticks;
    var x = pl + (w-pl-pr)*j/ticks;
    ctx.fillText(spanDays>2?fmtDay(t):fmtClock(t), x, h-pb+7);
  }
  return {
    x:function(t){ return pl + (w-pl-pr)*(xmax-xmin===0?0:(t-xmin)/(xmax-xmin)); },
    y:function(v){ return pt + (h-pt-pb)*(1-Math.min(v,ymax)/(ymax||1)); },
    pl:pl,pr:pr,pt:pt,pb:pb,w:w,h:h
  };
}

function attachTip(cv, tipEl, pts, render){
  if(!pts.length) return;
  cv.addEventListener("mousemove", function(ev){
    var r = cv.getBoundingClientRect();
    var mx = ev.clientX - r.left;
    var best=0, bd=1e9;
    for(var i=0;i<pts.length;i++){ var d=Math.abs(pts[i].px-mx); if(d<bd){bd=d;best=i;} }
    if(bd>40){ tipEl.style.opacity=0; return; }
    tipEl.innerHTML = render(pts[best]);
    tipEl.style.opacity=1;
    var tw = tipEl.offsetWidth;
    var left = Math.min(Math.max(pts[best].px - tw/2, 2), cv.clientWidth - tw - 2);
    tipEl.style.left = left+"px";
    tipEl.style.top  = Math.max(2, pts[best].py - tipEl.offsetHeight - 10)+"px";
  });
  cv.addEventListener("mouseleave", function(){ tipEl.style.opacity=0; });
}

// --- charts ----------------------------------------------------------------
function drawLatency(){
  var cv=document.getElementById("cLat"), g=prep(cv);
  var s=D.series;
  if(!s.length){ noData(g); return; }
  var xmin=s[0].t, xmax=s[s.length-1].t;
  if(xmax<=xmin) xmax=xmin+60000;
  var top=0;
  for(var i=0;i<s.length;i++){ if(s[i].max!==null && s[i].max>top) top=s[i].max; }
  var ymax=niceMax(top*1.12)||10;
  var spanDays=(xmax-xmin)/86400000;
  var A=frame(g,{l:52,r:14,t:12,b:26},xmin,xmax,ymax,function(v){return Math.round(v)+" ms";},spanDays);
  var ctx=g.ctx;

  ctx.beginPath(); var started=false;
  for(var i2=0;i2<s.length;i2++){ var p=s[i2]; if(p.max===null) continue;
    var X=A.x(p.t), Y=A.y(p.max); if(!started){ctx.moveTo(X,Y);started=true;} else ctx.lineTo(X,Y); }
  for(var i3=s.length-1;i3>=0;i3--){ var q=s[i3]; if(q.min===null) continue; ctx.lineTo(A.x(q.t),A.y(q.min)); }
  ctx.closePath(); ctx.fillStyle=C.band; ctx.fill();

  ctx.beginPath(); started=false;
  var pts=[];
  for(var i4=0;i4<s.length;i4++){ var r=s[i4]; if(r.avg===null) continue;
    var X2=A.x(r.t), Y2=A.y(r.avg);
    if(!started){ctx.moveTo(X2,Y2);started=true;} else ctx.lineTo(X2,Y2);
    pts.push({px:X2,py:Y2,d:r});
  }
  ctx.strokeStyle=C.accent; ctx.lineWidth=1.6; ctx.lineJoin="round"; ctx.stroke();

  attachTip(cv, document.getElementById("tLat"), pts, function(p){
    var d=p.d;
    return "<b>"+fmtFull(d.t)+"</b><br>avg "+d.avg+" ms &nbsp; min "+d.min+" &nbsp; max "+d.max+
           "<br>loss "+(d.loss===null?"-":d.loss+"%")+" &nbsp; "+d.n+" cycle"+(d.n===1?"":"s");
  });
}

function drawLoss(){
  var cv=document.getElementById("cLoss"), g=prep(cv);
  var s=D.series;
  if(!s.length){ noData(g); return; }
  var xmin=s[0].t, xmax=s[s.length-1].t; if(xmax<=xmin) xmax=xmin+60000;
  var top=0; for(var i=0;i<s.length;i++){ if(s[i].lossMax!==null && s[i].lossMax>top) top=s[i].lossMax; }
  var ymax = top<=0 ? 5 : Math.min(100, niceMax(top*1.15));   // loss is a percentage; never scale past 100
  var spanDays=(xmax-xmin)/86400000;
  var A=frame(g,{l:52,r:14,t:12,b:26},xmin,xmax,ymax,function(v){return (Math.round(v*10)/10)+"%";},spanDays);
  var ctx=g.ctx;
  var bw=Math.max(1,(A.w-A.pl-A.pr)/Math.max(s.length,1)*0.8);
  var pts=[];
  for(var j=0;j<s.length;j++){
    var p=s[j]; if(p.lossMax===null||p.lossMax<=0){ continue; }
    var X=A.x(p.t), Y=A.y(p.lossMax), base=A.y(0);
    ctx.fillStyle = p.lossMax>=50 ? C.bad : (p.lossMax>=2 ? C.warn : C.accent);
    ctx.fillRect(X-bw/2, Y, bw, Math.max(1,base-Y));
    pts.push({px:X,py:Y,d:p});
  }
  if(!pts.length){
    ctx.fillStyle=C.good; ctx.textAlign="center"; ctx.textBaseline="middle";
    ctx.font='12px "Segoe UI",system-ui,sans-serif';
    ctx.fillText("no packet loss recorded in this period", g.w/2, g.h/2);
  }
  attachTip(cv, document.getElementById("tLoss"), pts, function(p){
    return "<b>"+fmtFull(p.d.t)+"</b><br>worst loss "+p.d.lossMax+"% &nbsp; avg "+p.d.loss+"%";
  });
}

function drawSpeed(){
  var cv=document.getElementById("cSpeed"), g=prep(cv);
  var s=D.speed;
  if(!s.length){ noData(g,"no speed tests recorded yet"); return; }
  var xmin=s[0].t, xmax=s[s.length-1].t; if(xmax<=xmin){ xmin-=3600000; xmax+=3600000; }
  var top=0;
  for(var i=0;i<s.length;i++){ if(s[i].down>top) top=s[i].down; if(s[i].up>top) top=s[i].up; }
  var ymax=niceMax(top*1.15)||10;
  var spanDays=(xmax-xmin)/86400000;
  var A=frame(g,{l:52,r:14,t:12,b:26},xmin,xmax,ymax,function(v){return Math.round(v)+"";},spanDays);
  var ctx=g.ctx;
  function line(key,col){
    ctx.beginPath(); var st=false;
    for(var i=0;i<s.length;i++){ var v=s[i][key]; if(v===null) continue;
      var X=A.x(s[i].t), Y=A.y(v); if(!st){ctx.moveTo(X,Y);st=true;} else ctx.lineTo(X,Y); }
    ctx.strokeStyle=col; ctx.lineWidth=1.6; ctx.stroke();
    for(var j=0;j<s.length;j++){ var v2=s[j][key]; if(v2===null) continue;
      ctx.beginPath(); ctx.arc(A.x(s[j].t),A.y(v2),2.6,0,6.284); ctx.fillStyle=col; ctx.fill(); }
  }
  line("down",C.good); line("up",C.warn);
  var pts=[];
  for(var k=0;k<s.length;k++){ pts.push({px:A.x(s[k].t),py:A.y(Math.max(s[k].down||0,s[k].up||0)),d:s[k]}); }
  attachTip(cv, document.getElementById("tSpeed"), pts, function(p){
    return "<b>"+fmtFull(p.d.t)+"</b><br>down "+(p.d.down===null?"-":p.d.down+" Mbps")+
           " &nbsp; up "+(p.d.up===null?"-":p.d.up+" Mbps");
  });
}

function noData(g,msg){
  var ctx=g.ctx;
  ctx.fillStyle=C.muted; ctx.textAlign="center"; ctx.textBaseline="middle";
  ctx.font='12.5px "Segoe UI",system-ui,sans-serif';
  ctx.fillText(msg||"no data in this period", g.w/2, g.h/2);
}

// --- heatmap ---------------------------------------------------------------
function heatColor(v){
  if(v===null) return "#1b2028";
  if(v>=99.5) return "#3ddc97";
  if(v>=99)   return "#7ad486";
  if(v>=97)   return "#b7d94c";
  if(v>=94)   return "#ffb454";
  if(v>=85)   return "#ff8f5e";
  return "#ff6b6b";
}
function drawHeat(){
  var days=["Mon","Tue","Wed","Thu","Fri","Sat","Sun"];
  var h="<table><tr><th></th>";
  for(var x=0;x<24;x++){ h+="<th>"+(x%2===0?pad(x):"")+"</th>"; }
  h+="</tr>";
  for(var d=0;d<7;d++){
    h+="<tr><th>"+days[d]+"</th>";
    for(var hr=0;hr<24;hr++){
      var c=D.heat[d][hr];
      var t = c===null ? days[d]+" "+pad(hr)+":00 - no data"
                       : days[d]+" "+pad(hr)+":00 - "+c.toFixed(1)+"% healthy";
      h+='<td><div class="cell" style="background:'+heatColor(c)+'" title="'+esc(t)+'"></div></td>';
    }
    h+="</tr>";
  }
  h+="</table>";
  document.getElementById("heat").innerHTML=h;
}

// --- tables and cards ------------------------------------------------------
function pill(s){
  var c = s==="Down"?"p-down":(s==="Degraded"?"p-deg":"p-up");
  return '<span class="pill '+c+'">'+esc(s)+"</span>";
}
function drawEvents(){
  var e=D.events, el=document.getElementById("events");
  if(!e.length){ el.innerHTML='<div class="empty">No state changes recorded in this period.</div>'; return; }
  var h="<table><tr><th>When</th><th>Change</th><th>Previous state lasted</th><th>Why</th><th>Diagnostics</th></tr>";
  var LIMIT=300, shown=0;
  for(var i=e.length-1;i>=0 && shown<LIMIT;i--){ shown++;
    var r=e[i];
    var chg = (r.from? pill(r.from)+" &rarr; " : "") + pill(r.to);
    h+="<tr><td class='num'>"+esc(fmtFull(r.t))+"</td><td>"+chg+"</td><td class='num'>"+
       esc(fmtDur(r.dur))+"</td><td>"+esc(r.reason)+"</td><td>"+
       (r.diag?"<code>"+esc(r.diag)+"</code>":"")+"</td></tr>";
  }
  if(e.length>LIMIT) h+="<tr><td colspan='5' class='empty'>Showing the most recent "+LIMIT+
     " of "+e.length+" state changes. The full list is in the events CSVs.</td></tr>";
  document.getElementById("events").innerHTML=h+"</table>";
}
function card(k,v,n){
  return '<div class="card"><div class="k">'+esc(k)+'</div><div class="v">'+v+
         '</div><div class="n">'+esc(n||"")+"</div></div>";
}
function drawCards(){
  var s=D.summary, h="";
  h+=card("Availability", s.uptimePct===null?"-":s.uptimePct.toFixed(2)+"%", s.rows+" cycles");
  h+=card("Outages", s.outages, s.degradations+" degraded periods");
  h+=card("Down time", fmtDur(s.downSeconds)||"none", "across the period");
  h+=card("Latency", s.avgLatency===null?"-":s.avgLatency.toFixed(1)+" ms",
          s.maxLatency===null?"":"peak "+s.maxLatency.toFixed(0)+" ms");
  h+=card("Packet loss", s.avgLoss===null?"-":s.avgLoss.toFixed(2)+"%", "mean across cycles");
  if(s.lastDown) h+=card("Last outage", esc(fmtShort(s.lastDown)), esc(agoText(s.lastDown)));
  if(D.speed.length){
    var last=D.speed[D.speed.length-1];
    h+=card("Last speed test",(last.down===null?"-":last.down.toFixed(0))+" / "+
            (last.up===null?"-":last.up.toFixed(0)), "Mbps down / up");
  }
  document.getElementById("cards").innerHTML=h;
}

function render(){
  drawCards(); drawLatency(); drawLoss(); drawSpeed(); drawHeat(); drawEvents();
}

document.getElementById("sub").textContent =
  "Generated " + fmtFull(D.generatedMs) + "  |  " + D.rangeText + "  |  " + D.host;
document.getElementById("foot").textContent =
  "netmon " + D.version + ". Buckets: raw for the last " + D.rawHours + "h, hourly to " +
  D.hourlyDays + " days, daily beyond. Min and max are kept alongside the average at every " +
  "resolution, so short outages survive aggregation.";

render();
var rt;
window.addEventListener("resize", function(){ clearTimeout(rt); rt=setTimeout(render,180); });
})();
</script>
</body>
</html>
'@
    $tpl
}

function Write-NetmonReport {
    param([Parameter(Mandatory = $true)]$Config, [int]$Days = 30, [string]$OutPath)

    $model = Get-ReportModel -Config $Config -Days $Days
    $json  = ConvertTo-Json -InputObject $model -Depth 8 -Compress
    # The payload sits inside a <script> element, so any literal "</" in the
    # data would end the element early. "<\/" is a valid JSON escape.
    $json = $json.Replace('</', '<\/')

    $name = $env:COMPUTERNAME
    if (-not $name) { $name = 'this machine' }
    $title = 'PS-NETMON report - {0}' -f $name
    $html = (Get-ReportTemplate).Replace('__TITLE__', $title).Replace('__DATA__', $json)

    if (-not $OutPath) {
        $dir = Get-ReportDir -Config $Config
        $OutPath = Join-Path $dir ('PS-NETMON_report_{0}.html' -f
                   ([DateTimeOffset]::Now.ToString('yyyy-MM-dd_HHmm', $script:Invariant)))
    }
    [System.IO.File]::WriteAllText($OutPath, $html, $script:Utf8Bom)
    Write-NetmonLog ('Wrote report: {0} ({1} cycles, {2} buckets)' -f
                     (Split-Path -Leaf $OutPath), $model['summary']['rows'], $model['series'].Count)
    New-Object PSObject -Property ([ordered]@{
        Path    = $OutPath
        Rows    = $model['summary']['rows']
        Buckets = $model['series'].Count
        Outages = $model['summary']['outages']
        Uptime  = $model['summary']['uptimePct']
    })
}

#endregion
#region ---- Render engine ------------------------------------------------------

# A full-screen dashboard cannot be drawn with Write-Host. Hundreds of coloured
# Write-Host calls per frame is what makes a PowerShell TUI flicker and crawl.
#
# Instead: a cell buffer (one char, one foreground, one background per cell),
# widgets that write into it, and ONE [Console]::Write per frame carrying ANSI
# escapes. Colour changes are emitted only where they actually change, so a
# typical frame is a few kilobytes and one syscall.
#
# Everything here stays ASCII in the source; box-drawing and block characters
# are built from code points at load time.

$script:ESC = [string][char]27

# Box drawing and block characters, built from code points so this file stays
# pure ASCII. Which set is actually used is decided at startup by
# Initialize-Glyphs, because a console whose output encoding is a single-byte
# code page turns every one of these into a literal "?".

$script:GfxUnicode = @{
    TL = [string][char]0x256D; TR = [string][char]0x256E    # rounded corners
    BL = [string][char]0x2570; BR = [string][char]0x256F
    H  = [string][char]0x2500; V  = [string][char]0x2502
    LT = [string][char]0x251C; RT = [string][char]0x2524
    Dot = [string][char]0x25CF                              # status dot
    Up = [string][char]0x25B2; Down = [string][char]0x25BC   # triangles
    Arrow = [string][char]0x2192
    Star = [string][char]0x2605                             # "lowest" marker
    Track = [string][char]0x2591                            # meter track
}
$script:GfxAscii = @{
    TL = '+'; TR = '+'; BL = '+'; BR = '+'
    H  = '-'; V  = '|'; LT = '+'; RT = '+'
    Dot = 'o'; Up = '^'; Down = 'v'; Arrow = '->'; Star = '*'
    Track = '.'
}
# Eighth blocks, and an ASCII ramp that still reads as increasing height.
$script:Bar8Unicode = @(' ',
    [string][char]0x2581, [string][char]0x2582, [string][char]0x2583, [string][char]0x2584,
    [string][char]0x2585, [string][char]0x2586, [string][char]0x2587, [string][char]0x2588)
$script:Bar8Ascii = @(' ', '.', '.', ':', ':', '-', '=', '*', '#')

# Braille dot masks. BrDot* place one dot at a given row inside the cell;
# BrFill* fill N rows up from the cell's base.
$script:BrDot0  = @(0x01, 0x02, 0x04, 0x40)
$script:BrDot1  = @(0x08, 0x10, 0x20, 0x80)
$script:BrFill0 = @(0, 0x40, 0x44, 0x46, 0x47)
$script:BrFill1 = @(0, 0x80, 0xA0, 0xB0, 0xB8)

$script:Gfx = $script:GfxUnicode
$script:Bar8 = $script:Bar8Unicode
$script:GlyphMode = 'braille'

function Set-GlyphMode {
    # braille = dot-matrix charts (the default and the best looking)
    # blocks  = eighth-block bars, for fonts with poor braille coverage
    # ascii   = no non-ASCII characters at all
    param([ValidateSet('braille', 'blocks', 'ascii')][string]$Mode)
    if ($Mode -eq 'ascii') {
        $script:Gfx = $script:GfxAscii
        $script:Bar8 = $script:Bar8Ascii
    } else {
        $script:Gfx = $script:GfxUnicode
        $script:Bar8 = $script:Bar8Unicode
    }
    $script:GlyphMode = $Mode
}

function Initialize-Glyphs {
    <#
      Windows PowerShell 5.1 leaves the console output encoding on the OEM code
      page, which cannot represent a block character: every bar in every chart
      arrives as "?". Setting UTF-8 fixes it. If the host refuses, fall back to
      an ASCII ramp so the charts stay readable instead of turning to noise.
      Returns the original encoding so the caller can put it back on exit.
    #>
    param([string]$Prefer = 'auto')
    $original = $null
    try { $original = [Console]::OutputEncoding } catch { }
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }

    $ok = $false
    try {
        $probe = [string][char]0x2588 + [string][char]0x256D + [string][char]0x28FF
        $enc = [Console]::OutputEncoding
        $ok = ($enc.GetString($enc.GetBytes($probe)) -eq $probe)
    } catch { $ok = $false }

    if ('ascii', 'blocks', 'braille' -contains $Prefer) { Set-GlyphMode -Mode $Prefer }
    elseif ($ok) { Set-GlyphMode -Mode 'braille' }
    else { Set-GlyphMode -Mode 'ascii' }
    $original
}

function Restore-ConsoleEncoding {
    param($Original)
    if ($null -eq $Original) { return }
    try { [Console]::OutputEncoding = $Original } catch { }
}

# 256-colour palette indices. Kept in one place so the whole app can be
# retinted from here.
$script:Col = @{
    Text = 253; Dim = 248; Faint = 243; White = 231
    Cyan = 80;  Blue = 75;  Green = 84; Yellow = 222; Orange = 215
    Red = 210;  Magenta = 182; Purple = 147
    Panel = 237; PanelDim = 234; Sel = 24
    Ok = 84; Warn = 222; Bad = 210; Off = 244
}

function Enable-VirtualTerminal {
    # Windows Terminal has VT on by default; the legacy console host does not.
    # Without it the escape sequences would print as garbage, so if this fails
    # the app refuses to start rather than vomiting escape codes.
    if (-not ('PsnmVt' -as [type])) {
        $src = @'
using System;
using System.Runtime.InteropServices;
public static class PsnmVt {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
    public static bool Enable() {
        IntPtr h = GetStdHandle(-11);
        uint mode;
        if (!GetConsoleMode(h, out mode)) { return false; }
        mode |= 0x0004;  // ENABLE_VIRTUAL_TERMINAL_PROCESSING
        return SetConsoleMode(h, mode);
    }
}
'@
        try { Add-Type -TypeDefinition $src -ErrorAction Stop } catch { return $false }
    }
    try { return [PsnmVt]::Enable() } catch { return $false }
}

function Get-TerminalSize {
    $w = 120; $h = 40
    try { $w = [Console]::WindowWidth; $h = [Console]::WindowHeight } catch { }
    if ($w -lt 20) { $w = 20 }
    if ($h -lt 10) { $h = 10 }
    New-Object PSObject -Property @{ W = $w; H = $h }
}

function New-Screen {
    param([int]$Width, [int]$Height)
    $n = $Width * $Height
    # Prototype rows of a blank screen, built once. Clearing is then three
    # array copies instead of tens of thousands of PowerShell loop iterations,
    # which at 100x40 was a measurable slice of every single frame.
    $blankCh = New-Object 'char[]' $n
    $blankFg = New-Object 'int[]' $n
    $blankBg = New-Object 'int[]' $n
    $sp = [char]' '
    for ($i = 0; $i -lt $n; $i++) {
        $blankCh[$i] = $sp
        $blankFg[$i] = $script:Col.Text
        $blankBg[$i] = -1
    }
    @{
        W = $Width; H = $Height; N = $n
        Ch = New-Object 'char[]' $n
        Fg = New-Object 'int[]' $n
        Bg = New-Object 'int[]' $n
        BlankCh = $blankCh; BlankFg = $blankFg; BlankBg = $blankBg
    }
}

function Clear-Screen {
    param($Screen)
    $n = $Screen.N
    [System.Array]::Copy($Screen.BlankCh, $Screen.Ch, $n)
    [System.Array]::Copy($Screen.BlankFg, $Screen.Fg, $n)
    [System.Array]::Copy($Screen.BlankBg, $Screen.Bg, $n)
}

function Set-Cell {
    param($Screen, [int]$X, [int]$Y, [char]$Char, [int]$Fg = -2, [int]$Bg = -2)
    if ($X -lt 0 -or $Y -lt 0 -or $X -ge $Screen.W -or $Y -ge $Screen.H) { return }
    $i = $Y * $Screen.W + $X
    $Screen.Ch[$i] = $Char
    if ($Fg -ne -2) { $Screen.Fg[$i] = $Fg }
    if ($Bg -ne -2) { $Screen.Bg[$i] = $Bg }
}

function Write-Buf {
    # The workhorse. Clips at the right edge, and at $MaxWidth when given, so a
    # long process name or a wide remote address can never spill into the
    # column beside it.
    param($Screen, [int]$X, [int]$Y, [string]$Text, [int]$Fg = -2, [int]$Bg = -2, [int]$MaxWidth = 0)
    if ($null -eq $Text -or $Y -lt 0 -or $Y -ge $Screen.H) { return }
    $limit = $Screen.W - $X
    if ($MaxWidth -gt 0 -and $MaxWidth -lt $limit) { $limit = $MaxWidth }
    if ($limit -le 0) { return }
    $t = $Text
    if ($t.Length -gt $limit) { $t = $t.Substring(0, $limit) }
    $w = $Screen.W
    $ch = $Screen.Ch; $fgArr = $Screen.Fg; $bgArr = $Screen.Bg
    $i = $Y * $w + $X
    $len = $t.Length
    for ($k = 0; $k -lt $len; $k++) {
        $xx = $X + $k
        if ($xx -lt 0) { continue }
        if ($xx -ge $w) { break }
        $ch[$i + $k] = $t[$k]
        if ($Fg -ne -2) { $fgArr[$i + $k] = $Fg }
        if ($Bg -ne -2) { $bgArr[$i + $k] = $Bg }
    }
}

function Fill-Rect {
    param($Screen, [int]$X, [int]$Y, [int]$W, [int]$H, [char]$Char = ' ', [int]$Fg = -2, [int]$Bg = -2)
    $sw = $Screen.W; $sh = $Screen.H
    $ch = $Screen.Ch; $fgArr = $Screen.Fg; $bgArr = $Screen.Bg
    $x0 = [math]::Max(0, $X); $x1 = [math]::Min($sw - 1, $X + $W - 1)
    $y0 = [math]::Max(0, $Y); $y1 = [math]::Min($sh - 1, $Y + $H - 1)
    for ($r = $y0; $r -le $y1; $r++) {
        $base = $r * $sw
        for ($c = $x0; $c -le $x1; $c++) {
            $ch[$base + $c] = $Char
            if ($Fg -ne -2) { $fgArr[$base + $c] = $Fg }
            if ($Bg -ne -2) { $bgArr[$base + $c] = $Bg }
        }
    }
}

function Draw-Box {
    # Rounded panel with an optional inline title, like the reference layout.
    param($Screen, [int]$X, [int]$Y, [int]$W, [int]$H,
          [string]$Title = '', [int]$Fg = -1, [int]$TitleFg = -1)
    if ($Fg -lt 0) { $Fg = $script:Col.Faint }
    if ($TitleFg -lt 0) { $TitleFg = $script:Col.Cyan }
    if ($W -lt 2 -or $H -lt 2) { return }
    $g = $script:Gfx

    Write-Buf $Screen $X $Y ($g.TL + ($g.H * ($W - 2)) + $g.TR) $Fg
    for ($r = $Y + 1; $r -lt $Y + $H - 1; $r++) {
        Set-Cell $Screen $X $r ([char]$g.V) $Fg
        Set-Cell $Screen ($X + $W - 1) $r ([char]$g.V) $Fg
    }
    Write-Buf $Screen $X ($Y + $H - 1) ($g.BL + ($g.H * ($W - 2)) + $g.BR) $Fg

    if ($Title) {
        $t = ' ' + $Title + ' '
        if ($t.Length -gt $W - 4) { $t = $t.Substring(0, [math]::Max(0, $W - 4)) }
        Write-Buf $Screen ($X + 2) $Y $t $TitleFg
    }
}

function Write-Render {
    # One frame -> one string -> one write. Colour escapes are emitted only at
    # a run boundary, and each row is positioned absolutely so nothing can
    # scroll the view.
    param($Screen)
    $sb = New-Object System.Text.StringBuilder (($Screen.W * $Screen.H * 2))
    $e = $script:ESC
    $w = $Screen.W
    $chArr = $Screen.Ch; $fgArr = $Screen.Fg; $bgArr = $Screen.Bg
    for ($y = 0; $y -lt $Screen.H; $y++) {
        [void]$sb.Append($e).Append('[').Append($y + 1).Append(';1H')
        $curFg = -99; $curBg = -99
        $base = $y * $w
        for ($x = 0; $x -lt $w; $x++) {
            $i = $base + $x
            $f = $fgArr[$i]; $b = $bgArr[$i]
            if ($f -ne $curFg) {
                [void]$sb.Append($e).Append('[38;5;').Append($f).Append('m')
                $curFg = $f
            }
            if ($b -ne $curBg) {
                if ($b -lt 0) { [void]$sb.Append($e).Append('[49m') }
                else { [void]$sb.Append($e).Append('[48;5;').Append($b).Append('m') }
                $curBg = $b
            }
            [void]$sb.Append($chArr[$i])
        }
        [void]$sb.Append($e).Append('[0m')
    }
    [Console]::Write($sb.ToString())
}

function Enter-FullScreen {
    # Alternate screen buffer, so quitting gives the user their scrollback and
    # prompt back exactly as they left it.
    [Console]::Write($script:ESC + '[?1049h' + $script:ESC + '[?25l' + $script:ESC + '[2J')
}

function Exit-FullScreen {
    [Console]::Write($script:ESC + '[0m' + $script:ESC + '[?25h' + $script:ESC + '[?1049l')
}

#endregion
#region ---- Widgets -------------------------------------------------------------

function Format-Rate {
    param($Bps)
    if ($null -eq $Bps) { return '-' }
    $b = [double]$Bps
    if ($b -lt 1000) { return ('{0:0} B/s' -f $b) }
    if ($b -lt 1000000) { return ('{0:0.0} KB/s' -f ($b / 1024)) }
    if ($b -lt 1000000000) { return ('{0:0.0} MB/s' -f ($b / 1048576)) }
    return ('{0:0.00} GB/s' -f ($b / 1073741824))
}

function Format-Bytes {
    param($Bytes)
    if ($null -eq $Bytes) { return '-' }
    $b = [double]$Bytes
    if ($b -lt 1024) { return ('{0:0} B' -f $b) }
    if ($b -lt 1048576) { return ('{0:0.0} KB' -f ($b / 1024)) }
    if ($b -lt 1073741824) { return ('{0:0.0} MB' -f ($b / 1048576)) }
    return ('{0:0.00} GB' -f ($b / 1073741824))
}

function Format-Ms {
    param($Ms, [int]$Decimals = 1)
    if ($null -eq $Ms) { return '-' }
    ('{0:0.' + ('#' * $Decimals) + '} ms') -f [double]$Ms
}

function Format-LinkStatus {
    # "Disconnected" does not fit an 8 column status field, and a truncated
    # "DISCONNE" reads like a fault code.
    param([string]$Status)
    switch -Wildcard ($Status) {
        'Up'            { return 'UP' }
        'Disconnected'  { return 'DOWN' }
        'Not Present'   { return 'ABSENT' }
        'Disabled'      { return 'DISABLED' }
        default         { return $Status.ToUpperInvariant() }
    }
}

function Get-LatencyTone {
    # Colour by how this compares with THIS line's learned normal, not with a
    # number someone picked out of the air.
    param($Value, $Baseline)
    if ($null -eq $Value) { return $script:Col.Faint }
    $b = 20.0
    if ($null -ne $Baseline -and $Baseline -gt 0) { $b = [double]$Baseline }
    if ($Value -gt [math]::Max($b * 3, $b + 30)) { return $script:Col.Red }
    if ($Value -gt [math]::Max($b * 1.7, $b + 12)) { return $script:Col.Yellow }
    return $script:Col.Green
}

function Get-LatencyTones {
    <#
      Builds a whole colour array in one pass, into a pre-sized typed array.
      The obvious "$tones += ..." in a loop reallocates the array on every
      append, which is quadratic and was the single most expensive thing in
      the frame once the histories grew to a few hundred samples.
      Trims to the window that will actually be drawn, so nothing is computed
      for samples that fall off the left edge.
    #>
    param($Values, $Baseline, [int]$Keep = 0)
    $v = @($Values)
    if ($Keep -gt 0 -and $v.Count -gt $Keep) { $v = $v[($v.Count - $Keep)..($v.Count - 1)] }
    $b = 20.0
    if ($null -ne $Baseline -and $Baseline -gt 0) { $b = [double]$Baseline }
    $warn = [math]::Max($b * 1.7, $b + 12)
    $bad  = [math]::Max($b * 3, $b + 30)
    $cg = $script:Col.Green; $cy2 = $script:Col.Yellow; $cr = $script:Col.Red; $cf = $script:Col.Faint
    $out = New-Object 'int[]' $v.Count
    for ($i = 0; $i -lt $v.Count; $i++) {
        $x = $v[$i]
        if ($null -eq $x) { $out[$i] = $cf }
        elseif ($x -gt $bad) { $out[$i] = $cr }
        elseif ($x -gt $warn) { $out[$i] = $cy2 }
        else { $out[$i] = $cg }
    }
    New-Object PSObject -Property ([ordered]@{ Values = $v; Tones = $out })
}

function Get-LossTone {
    param($Value)
    if ($null -eq $Value -or $Value -le 0) { return $script:Col.Green }
    if ($Value -ge 50) { return $script:Col.Red }
    if ($Value -ge 2) { return $script:Col.Yellow }
    return $script:Col.Orange
}

function Draw-Sparkline {
    # Single row. In braille mode this is a one-row dot chart, which fits twice
    # as many samples across the same width.
    param($Screen, [int]$X, [int]$Y, $Values, [int]$Width, [int]$Fg = -1, $Colors = $null)
    if ($Fg -lt 0) { $Fg = $script:Col.Cyan }
    if ($script:GlyphMode -eq 'braille') {
        Draw-BrailleChart -Screen $Screen -X $X -Y $Y -Width $Width -Height 1 `
            -Values $Values -Fg $Fg -Colors $Colors
        return
    }
    $v = @($Values)
    if ($v.Count -lt 1) { return }
    if ($v.Count -gt $Width) { $v = $v[($v.Count - $Width)..($v.Count - 1)] }
    # NOT $x: that is the $X coordinate parameter under PowerShell's
    # case-insensitive variable rules, and clobbering it puts every bar
    # off-screen.
    $max = 0.0
    foreach ($val in $v) { if ($null -ne $val -and $val -gt $max) { $max = [double]$val } }
    if ($max -le 0) { $max = 1 }
    $off = $Width - $v.Count      # right-align: newest at the right edge
    for ($i = 0; $i -lt $v.Count; $i++) {
        if ($null -eq $v[$i]) { continue }
        $lvl = [int][math]::Ceiling([double]$v[$i] / $max * 8)
        if ($lvl -lt 1 -and $v[$i] -gt 0) { $lvl = 1 }
        if ($lvl -gt 8) { $lvl = 8 }
        if ($lvl -lt 0) { $lvl = 0 }
        $c = $Fg
        if ($Colors -and $i -lt @($Colors).Count -and $Colors[$i] -ge 0) { $c = $Colors[$i] }
        Write-Buf $Screen ($X + $off + $i) $Y $script:Bar8[$lvl] $c
    }
}

function Draw-AreaChart {
    # Block-character column chart, used when braille is unavailable. Writes
    # into the cell buffer directly: a Write-Buf call per cell made this the
    # most expensive thing on the screen.
    param($Screen, [int]$X, [int]$Y, [int]$Width, [int]$Height, $Values,
          [int]$Fg = -1, $Colors = $null, [double]$Max = 0)
    if ($Fg -lt 0) { $Fg = $script:Col.Cyan }
    $v = @($Values)
    if ($v.Count -lt 1 -or $Width -lt 1 -or $Height -lt 1) { return }
    if ($v.Count -gt $Width) { $v = $v[($v.Count - $Width)..($v.Count - 1)] }

    $top = $Max
    if ($top -le 0) {
        foreach ($val in $v) { if ($null -ne $val -and $val -gt $top) { $top = [double]$val } }
    }
    if ($top -le 0) { $top = 1 }

    $sw = $Screen.W; $sh = $Screen.H
    $chBuf = $Screen.Ch; $fgBuf = $Screen.Fg
    $bars = $script:Bar8
    $off = $Width - $v.Count

    for ($i = 0; $i -lt $v.Count; $i++) {
        if ($null -eq $v[$i]) { continue }
        $sx = $X + $off + $i
        if ($sx -lt 0 -or $sx -ge $sw) { continue }
        $eighths = [int][math]::Round([double]$v[$i] / $top * $Height * 8)
        if ($eighths -le 0) { continue }
        $c = $Fg
        if ($Colors -and $i -lt @($Colors).Count -and $Colors[$i] -ge 0) { $c = $Colors[$i] }
        for ($r = 0; $r -lt $Height; $r++) {
            $cell = $eighths - ($r * 8)
            if ($cell -le 0) { break }
            if ($cell -gt 8) { $cell = 8 }
            $sy = $Y + $Height - 1 - $r
            if ($sy -lt 0 -or $sy -ge $sh) { continue }
            $idx = $sy * $sw + $sx
            $chBuf[$idx] = [char]$bars[$cell]
            $fgBuf[$idx] = $c
        }
    }
}

function Draw-BrailleChart {
    <#
      Braille gives each character cell a 2 wide by 4 tall dot grid, so a chart
      drawn this way has twice the horizontal resolution of one drawn with
      block characters, and the fill edge is a curve rather than a staircase.

      Dot bit values inside a cell:
          0x01 0x08
          0x02 0x10
          0x04 0x20
          0x40 0x80
      The character is U+2800 plus the combined mask.
    #>
    param(
        $Screen, [int]$X, [int]$Y, [int]$Width, [int]$Height, $Values,
        [int]$Fg = -1, $Colors = $null, [double]$Max = 0, [switch]$Line
    )
    if ($Fg -lt 0) { $Fg = $script:Col.Cyan }
    $v = @($Values)
    if ($v.Count -lt 1 -or $Width -lt 1 -or $Height -lt 1) { return }

    $cols = $Width * 2
    if ($v.Count -gt $cols) { $v = $v[($v.Count - $cols)..($v.Count - 1)] }

    # Column -> sample map. With more samples than columns it is one to one on
    # the most recent window; with fewer, each sample is stretched across
    # several columns so the panel is filled rather than half blank. Stretching
    # repeats measured values; it never invents one.
    $map = New-Object 'int[]' $cols
    if ($v.Count -ge $cols) {
        for ($k = 0; $k -lt $cols; $k++) { $map[$k] = $k }
    } else {
        for ($k = 0; $k -lt $cols; $k++) { $map[$k] = [int][math]::Floor($k * $v.Count / $cols) }
    }

    $top = $Max
    if ($top -le 0) {
        foreach ($val in $v) { if ($null -ne $val -and $val -gt $top) { $top = [double]$val } }
    }
    if ($top -le 0) { $top = 1 }

    $dotRows = $Height * 4
    $n = $Width * $Height
    $mask = New-Object 'int[]' $n
    $tint = New-Object 'int[]' $n
    for ($k = 0; $k -lt $n; $k++) { $tint[$k] = -1 }

    for ($col = 0; $col -lt $cols; $col++) {
        $si = $map[$col]
        if ($si -lt 0 -or $si -ge $v.Count) { continue }
        $val = $v[$si]
        if ($null -eq $val) { continue }

        $h = [int][math]::Round([double]$val / $top * $dotRows)
        if ($h -lt 1 -and [double]$val -gt 0) { $h = 1 }
        if ($h -gt $dotRows) { $h = $dotRows }
        if ($h -lt 1) { continue }

        $c = $Fg
        if ($Colors -and $si -lt @($Colors).Count -and $Colors[$si] -ge 0) { $c = $Colors[$si] }

        $cx = [int][math]::Floor($col / 2)
        if ($cx -lt 0 -or $cx -ge $Width) { continue }
        $side = $col % 2

        if ($Line) {
            $fromTop = $dotRows - $h
            $cy = [int][math]::Floor($fromTop / 4)
            if ($cy -lt 0 -or $cy -ge $Height) { continue }
            $idx = $cy * $Width + $cx
            if ($side -eq 0) { $mask[$idx] = $mask[$idx] -bor $script:BrDot0[$fromTop % 4] }
            else { $mask[$idx] = $mask[$idx] -bor $script:BrDot1[$fromTop % 4] }
            $tint[$idx] = $c
        } else {
            # Only the cells this column actually touches are visited, so the
            # cost is Height per column rather than one iteration per dot.
            for ($cy = $Height - 1; $cy -ge 0; $cy--) {
                $cellBase = $dotRows - 4 * $cy
                $filled = $h - ($cellBase - 4)
                if ($filled -le 0) { break }
                if ($filled -gt 4) { $filled = 4 }
                $idx = $cy * $Width + $cx
                if ($side -eq 0) { $mask[$idx] = $mask[$idx] -bor $script:BrFill0[$filled] }
                else { $mask[$idx] = $mask[$idx] -bor $script:BrFill1[$filled] }
                $tint[$idx] = $c
            }
        }
    }

    $sw = $Screen.W; $sh = $Screen.H
    $chBuf = $Screen.Ch; $fgBuf = $Screen.Fg
    for ($cy = 0; $cy -lt $Height; $cy++) {
        $sy = $Y + $cy
        if ($sy -lt 0 -or $sy -ge $sh) { continue }
        $rowBase = $sy * $sw
        $cellBase = $cy * $Width
        for ($cx = 0; $cx -lt $Width; $cx++) {
            $m = $mask[$cellBase + $cx]
            if ($m -eq 0) { continue }
            $sx = $X + $cx
            if ($sx -lt 0 -or $sx -ge $sw) { continue }
            $c = $tint[$cellBase + $cx]
            if ($c -lt 0) { $c = $Fg }
            $chBuf[$rowBase + $sx] = [char](0x2800 + $m)
            $fgBuf[$rowBase + $sx] = $c
        }
    }
}

function Draw-Chart {
    # One entry point for every chart in the app, so the whole dashboard
    # switches representation together when the glyph mode changes.
    param(
        $Screen, [int]$X, [int]$Y, [int]$Width, [int]$Height, $Values,
        [int]$Fg = -1, $Colors = $null, [double]$Max = 0, [switch]$Line
    )
    if ($script:GlyphMode -eq 'braille') {
        Draw-BrailleChart -Screen $Screen -X $X -Y $Y -Width $Width -Height $Height `
            -Values $Values -Fg $Fg -Colors $Colors -Max $Max -Line:$Line
    } else {
        Draw-AreaChart -Screen $Screen -X $X -Y $Y -Width $Width -Height $Height `
            -Values $Values -Fg $Fg -Colors $Colors -Max $Max
    }
}

function Get-LogFraction {
    <#
      Where a latency sits on a shared log scale, 0.1 ms to 1 s. A linear
      scale cannot hold a 0.6 ms gateway and a 40 ms WAN hop in the same
      picture - one of them always reads as nothing. On a log scale every
      decade gets the same height, so all seven columns stay comparable:
          1 ms = 25%   10 ms = 50%   100 ms = 75%   1 s = 100%
    #>
    param($Ms, [double]$MinMs = 0.1, [double]$MaxMs = 1000.0)
    if ($null -eq $Ms) { return 0.0 }
    $v = [double]$Ms
    if ($v -lt $MinMs) { $v = $MinMs }
    if ($v -gt $MaxMs) { $v = $MaxMs }
    ([math]::Log10($v) - [math]::Log10($MinMs)) / ([math]::Log10($MaxMs) - [math]::Log10($MinMs))
}

function Draw-VerticalBar {
    <#
      Fills from the bottom. In braille mode each cell holds four dot rows, so
      the bar has the same dotted texture as every other chart on the screen,
      and the unfilled track is the same dots, dimmed - one material, lit to
      the level. Otherwise eighth blocks give eight levels per row.
      Anything with a non-zero value always shows at least one level, so a
      sub-millisecond reading never looks like missing data.
    #>
    param($Screen, [int]$X, [int]$Y, [int]$Width, [int]$Height, [double]$Fraction,
          [int]$Fg = -1, [int]$TrackFg = -1, [switch]$NoTrack)
    if ($Fg -lt 0) { $Fg = $script:Col.Cyan }
    if ($TrackFg -lt 0) { $TrackFg = $script:Col.PanelDim }
    if ($Width -lt 1 -or $Height -lt 1) { return }
    if ($Fraction -lt 0) { $Fraction = 0 }
    if ($Fraction -gt 1) { $Fraction = 1 }

    $sw = $Screen.W; $sh = $Screen.H
    $chBuf = $Screen.Ch; $fgBuf = $Screen.Fg
    $braille = ($script:GlyphMode -eq 'braille')

    $perRow = $(if ($braille) { 4 } else { 8 })
    $units = [int][math]::Round($Fraction * $Height * $perRow)
    if ($Fraction -gt 0 -and $units -lt 1) { $units = 1 }

    if ($braille) {
        $fullGlyph = [char](0x2800 + 0xFF)
        $trackGlyph = $fullGlyph
    } else {
        $fullGlyph = [char]$script:Bar8[8]
        $trackGlyph = [char]$script:Gfx.Track
    }

    for ($r = 0; $r -lt $Height; $r++) {
        $sy = $Y + $Height - 1 - $r
        if ($sy -lt 0 -or $sy -ge $sh) { continue }
        $cell = $units - ($r * $perRow)
        $glyph = $null; $col = $Fg
        if ($cell -ge $perRow) {
            $glyph = $fullGlyph
        } elseif ($cell -gt 0) {
            if ($braille) { $glyph = [char](0x2800 + ($script:BrFill0[$cell] -bor $script:BrFill1[$cell])) }
            else { $glyph = [char]$script:Bar8[$cell] }
        } elseif (-not $NoTrack) {
            $glyph = $trackGlyph; $col = $TrackFg
        }
        if ($null -eq $glyph) { continue }
        $base = $sy * $sw
        for ($c = 0; $c -lt $Width; $c++) {
            $sx = $X + $c
            if ($sx -lt 0 -or $sx -ge $sw) { continue }
            $chBuf[$base + $sx] = $glyph
            $fgBuf[$base + $sx] = $col
        }
    }
}

function Write-Centered {
    param($Screen, [int]$X, [int]$Y, [int]$Width, [string]$Text, [int]$Fg = -2)
    if (-not $Text) { return }
    $t = $Text
    if ($t.Length -gt $Width) { $t = $t.Substring(0, $Width) }
    $pad = [int][math]::Floor(($Width - $t.Length) / 2)
    Write-Buf $Screen ($X + $pad) $Y $t $Fg
}

function Draw-MeterBar {
    # Horizontal proportion bar, used for per-hop latency and loss.
    param($Screen, [int]$X, [int]$Y, [int]$Width, [double]$Fraction, [int]$Fg = -1, [int]$TrackFg = -1)
    if ($Fg -lt 0) { $Fg = $script:Col.Cyan }
    if ($TrackFg -lt 0) { $TrackFg = $script:Col.Faint }
    if ($Width -lt 1) { return }
    if ($Fraction -lt 0) { $Fraction = 0 }
    if ($Fraction -gt 1) { $Fraction = 1 }
    $eighths = [int][math]::Round($Fraction * $Width * 8)
    for ($i = 0; $i -lt $Width; $i++) {
        $cell = $eighths - ($i * 8)
        if ($cell -ge 8) { Write-Buf $Screen ($X + $i) $Y $script:Bar8[8] $Fg }
        elseif ($cell -gt 0) { Write-Buf $Screen ($X + $i) $Y $script:Bar8[8] $Fg }
        else { Write-Buf $Screen ($X + $i) $Y $script:Gfx.Track $TrackFg }
    }
}

function Draw-Table {
    <#
      Columns : @( @{ Name='Process'; Width=18; Align='L' }, ... )
      Rows    : array of arrays of @{ Text=''; Fg=n } or plain strings.
      Returns the number of rows actually drawn.
    #>
    param($Screen, [int]$X, [int]$Y, [int]$Width, [int]$MaxRows, $Columns, $Rows,
          [int]$HeaderFg = -1, [int]$Selected = -1)
    if ($HeaderFg -lt 0) { $HeaderFg = $script:Col.Magenta }

    $cx = $X
    foreach ($c in $Columns) {
        if ($cx -ge $X + $Width) { break }
        Write-Buf $Screen $cx $Y ([string]$c.Name) $HeaderFg -2 ([math]::Min($c.Width, $X + $Width - $cx))
        $cx += $c.Width + 1
    }

    $n = 0
    foreach ($row in @($Rows)) {
        if ($n -ge $MaxRows) { break }
        $ry = $Y + 1 + $n
        if ($ry -ge $Screen.H) { break }
        $bg = -2
        if ($Selected -eq $n) { $bg = $script:Col.Sel; Fill-Rect $Screen $X $ry $Width 1 ' ' -2 $bg }
        $cx = $X
        for ($i = 0; $i -lt @($Columns).Count; $i++) {
            $col = $Columns[$i]
            if ($cx -ge $X + $Width) { break }
            $cell = $null
            if ($i -lt @($row).Count) { $cell = $row[$i] }
            $text = ''; $fg = $script:Col.Text
            if ($cell -is [System.Collections.IDictionary]) {
                $text = [string]$cell['Text']
                if ($cell.Contains('Fg')) { $fg = [int]$cell['Fg'] }
            } elseif ($null -ne $cell) {
                $text = [string]$cell
            }
            $w = [math]::Min($col.Width, $X + $Width - $cx)
            if ([string]$col.Align -eq 'R' -and $text.Length -lt $col.Width) {
                $text = $text.PadLeft($col.Width)
            }
            Write-Buf $Screen $cx $ry $text $fg $bg $w
            $cx += $col.Width + 1
        }
        $n++
    }
    $n
}

function Draw-Heatmap {
    # Availability grid: one cell per hour, coloured by health. Two characters
    # wide so it reads as a block rather than a smear.
    param($Screen, [int]$X, [int]$Y, $Grid, $RowLabels, [int]$LabelWidth = 5)
    for ($r = 0; $r -lt @($Grid).Count; $r++) {
        Write-Buf $Screen $X ($Y + $r) ([string]$RowLabels[$r]).PadRight($LabelWidth) $script:Col.Dim
        for ($c = 0; $c -lt @($Grid[$r]).Count; $c++) {
            $v = $Grid[$r][$c]
            $bg = $script:Col.PanelDim
            if ($null -ne $v) {
                if ($v -ge 99.5) { $bg = 29 }
                elseif ($v -ge 99) { $bg = 65 }
                elseif ($v -ge 97) { $bg = 143 }
                elseif ($v -ge 94) { $bg = 179 }
                elseif ($v -ge 85) { $bg = 167 }
                else { $bg = 124 }
            }
            Write-Buf $Screen ($X + $LabelWidth + $c * 2) ($Y + $r) '  ' $script:Col.Text $bg
        }
    }
}

#endregion
#region ---- Background workers ---------------------------------------------------

# Everything the dashboard shows costs real time to fetch: Get-NetTCPConnection
# with process attribution is 100-400ms, adapter statistics another 50-150ms, a
# gateway ping up to its timeout. Done inline that is most of a second, and the
# UI would stutter and ignore keystrokes.
#
# So the slow work runs in background runspaces (built into PowerShell, no
# module needed) and the render loop only ever reads the last result that came
# back. The screen stays at a steady frame rate no matter how slow a CIM query
# decides to be.

function Initialize-Workers {
    $script:Pool = [RunspaceFactory]::CreateRunspacePool(1, 4)
    $script:Pool.ApartmentState = 'MTA'
    $script:Pool.Open()
    $script:Jobs = @{}
}

function Start-Worker {
    # $Body, not $Script: a parameter called $Script sitting next to the
    # $script: scope prefix is asking for trouble in a case-insensitive language.
    param([string]$Name, [scriptblock]$Body, $ArgumentList = @(), [int]$TimeoutSec = 30)
    if ($script:Jobs.ContainsKey($Name) -and $null -ne $script:Jobs[$Name]) {
        # Already running. Unless it is stuck: a hung job would otherwise
        # freeze its panel for good, because it is never started again.
        $j = $script:Jobs[$Name]
        if (([DateTimeOffset]::Now - $j.Started).TotalSeconds -lt $j.Timeout) { return }
        try { $null = $j.PS.BeginStop($null, $null) } catch { }
        $script:Jobs[$Name] = $null
    }
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $script:Pool
    # useLocalScope = $true. Pooled runspaces are reused; without a local
    # scope every job's variables land in that runspace's global scope and
    # the next job inherits them. A typed [string[]]$Names left behind by the
    # task check turned the snapshot's $names hashtable into a string.
    $null = $ps.AddScript($Body, $true)
    foreach ($a in @($ArgumentList)) { $null = $ps.AddArgument($a) }
    $script:Jobs[$Name] = @{ PS = $ps; Handle = $ps.BeginInvoke(); Started = [DateTimeOffset]::Now; Timeout = $TimeoutSec }
}

function Receive-Worker {
    # Returns the result if the worker has finished, otherwise $null. Never blocks.
    param([string]$Name)
    if (-not $script:Jobs.ContainsKey($Name)) { return $null }
    $j = $script:Jobs[$Name]
    if ($null -eq $j) { return $null }
    if (-not $j.Handle.IsCompleted) { return $null }
    $result = $null
    try { $result = $j.PS.EndInvoke($j.Handle) } catch { $result = $null }
    try { $j.PS.Dispose() } catch { }
    $script:Jobs[$Name] = $null
    if ($null -eq $result) { return $null }
    # A runspace returns a collection; we always emit exactly one object.
    foreach ($r in $result) { if ($null -ne $r) { return $r } }
    return $null
}

function Stop-Workers {
    if ($script:Jobs) {
        foreach ($k in @($script:Jobs.Keys)) {
            $j = $script:Jobs[$k]
            if ($j) { try { $j.PS.Stop(); $j.PS.Dispose() } catch { } }
        }
    }
    if ($script:Pool) { try { $script:Pool.Close(); $script:Pool.Dispose() } catch { } }
}

#endregion
#region ---- Sampler: interfaces, connections, processes -------------------------

# Runs in a background runspace, so it can only use plain cmdlets - none of
# this script's own functions exist in there.
$script:SnapshotScript = {
    param([string]$ProbeTarget)

    $out = @{
        Time = [DateTimeOffset]::Now
        Adapters = @(); Tcp = @(); Udp = @()
        Route = $null; DnsServers = ''
        Error = ''
    }

    try {
        $stats = @{}
        foreach ($s in @(Get-NetAdapterStatistics -ErrorAction SilentlyContinue)) { $stats[[string]$s.Name] = $s }

        $ips = @{}
        foreach ($a in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
            if (-not $ips.ContainsKey([int]$a.InterfaceIndex)) { $ips[[int]$a.InterfaceIndex] = [string]$a.IPAddress }
        }

        $list = New-Object 'System.Collections.Generic.List[object]'
        foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue)) {
            $st = $null
            if ($stats.ContainsKey([string]$a.Name)) { $st = $stats[[string]$a.Name] }
            $ip = ''
            if ($ips.ContainsKey([int]$a.ifIndex)) { $ip = $ips[[int]$a.ifIndex] }
            $rxE = 0; $txE = 0; $rxD = 0; $txD = 0
            if ($st) {
                try { $rxE = [double]$st.ReceivedPacketErrors } catch { }
                try { $txE = [double]$st.OutboundPacketErrors } catch { }
                try { $rxD = [double]$st.ReceivedDiscardedPackets } catch { }
                try { $txD = [double]$st.OutboundDiscardedPackets } catch { }
            }
            $list.Add([pscustomobject]@{
                Name = [string]$a.Name
                Desc = [string]$a.InterfaceDescription
                IfIndex = [int]$a.ifIndex
                Status = [string]$a.Status
                LinkSpeed = [string]$a.LinkSpeed
                Speed = $(try { [double]$a.Speed } catch { $null })
                Mac = [string]$a.MacAddress
                Media = [string]$a.MediaType
                Ip = $ip
                Rx = $(if ($st) { [double]$st.ReceivedBytes } else { $null })
                Tx = $(if ($st) { [double]$st.SentBytes } else { $null })
                RxPkt = $(if ($st) { [double]$st.ReceivedUnicastPackets } else { $null })
                TxPkt = $(if ($st) { [double]$st.SentUnicastPackets } else { $null })
                RxErr = $rxE; TxErr = $txE; RxDisc = $rxD; TxDisc = $txD
            })
        }
        $out.Adapters = $list.ToArray()
    } catch { $out.Error += 'adapters: ' + $_.Exception.Message + ' ' }

    # PID -> name, resolved once rather than per connection.
    $names = @{}
    try {
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $names[[int]$p.Id] = [string]$p.ProcessName }
    } catch { }

    try {
        $tl = New-Object 'System.Collections.Generic.List[object]'
        # Depending on how the NetTCPIP module's type data loads, State can
        # arrive as its number rather than its name. Everything downstream
        # compares names, so normalise here, once.
        $stateNames = @{ 1 = 'Closed'; 2 = 'Listen'; 3 = 'SynSent'; 4 = 'SynReceived'; 5 = 'Established'
                         6 = 'FinWait1'; 7 = 'FinWait2'; 8 = 'CloseWait'; 9 = 'Closing'; 10 = 'LastAck'
                         11 = 'TimeWait'; 12 = 'DeleteTCB'; 100 = 'Bound' }
        foreach ($c in @(Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
            $pid2 = 0
            try { $pid2 = [int]$c.OwningProcess } catch { }
            $nm = 'pid ' + $pid2
            if ($names.ContainsKey($pid2)) { $nm = $names[$pid2] }
            $st = [string]$c.State
            if ($st -match '^\d+$' -and $stateNames.ContainsKey([int]$st)) { $st = $stateNames[[int]$st] }
            $tl.Add([pscustomobject]@{
                Proc = $nm; ProcId = $pid2
                Local = ('{0}:{1}' -f $c.LocalAddress, $c.LocalPort)
                Remote = ('{0}:{1}' -f $c.RemoteAddress, $c.RemotePort)
                LocalIp = [string]$c.LocalAddress
                LocalPort = [int]$c.LocalPort
                RemoteIp = [string]$c.RemoteAddress
                RemotePort = [int]$c.RemotePort
                State = $st
                Proto = 'TCP'
            })
        }
        $out.Tcp = $tl.ToArray()
    } catch { $out.Error += 'tcp: ' + $_.Exception.Message + ' ' }

    try {
        $ul = New-Object 'System.Collections.Generic.List[object]'
        foreach ($c in @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue)) {
            $pid3 = 0
            try { $pid3 = [int]$c.OwningProcess } catch { }
            $nm = 'pid ' + $pid3
            if ($names.ContainsKey($pid3)) { $nm = $names[$pid3] }
            $ul.Add([pscustomobject]@{
                Proc = $nm; ProcId = $pid3
                Local = ('{0}:{1}' -f $c.LocalAddress, $c.LocalPort)
                LocalIp = [string]$c.LocalAddress; LocalPort = [int]$c.LocalPort
                Remote = '*:*'; RemoteIp = ''; RemotePort = 0
                State = 'LISTEN'; Proto = 'UDP'
            })
        }
        $out.Udp = $ul.ToArray()
    } catch { }

    try {
        $found = @(Find-NetRoute -RemoteIPAddress $ProbeTarget -ErrorAction SilentlyContinue)
        $route = $null; $addr = $null
        foreach ($o in $found) {
            $cls = $o.CimClass.CimClassName
            if ($cls -eq 'MSFT_NetRoute' -and -not $route) { $route = $o }
            elseif ($cls -eq 'MSFT_NetIPAddress' -and -not $addr) { $addr = $o }
        }
        if ($route) {
            $gw = [string]$route.NextHop
            if ($gw -eq '0.0.0.0' -or $gw -eq '::') { $gw = '' }
            $out.Route = [pscustomobject]@{
                Gateway = $gw
                IfIndex = [int]$route.InterfaceIndex
                IfAlias = [string]$route.InterfaceAlias
                LocalIp = $(if ($addr) { [string]$addr.IPAddress } else { '' })
            }
            $srv = New-Object 'System.Collections.Generic.List[string]'
            foreach ($d in @(Get-DnsClientServerAddress -InterfaceIndex ([int]$route.InterfaceIndex) -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
                foreach ($x in @($d.ServerAddresses)) { if ($x) { $srv.Add([string]$x) } }
            }
            $out.DnsServers = ($srv -join ', ')
        }
    } catch { $out.Error += 'route: ' + $_.Exception.Message }

    [pscustomobject]$out
}

# Health: the live "is it working right now" numbers. Short timeouts, because
# this must come back long before the next frame needs it.
$script:HealthScript = {
    param([string]$Gateway, [string]$DnsDomain, $Targets, [int]$Count)

    function Measure-Ping {
        param([string]$Address, [int]$N, [int]$TimeoutMs)
        $got = New-Object 'System.Collections.Generic.List[double]'
        for ($i = 0; $i -lt $N; $i++) {
            $p = $null
            try {
                $p = New-Object System.Net.NetworkInformation.Ping
                $r = $p.Send($Address, $TimeoutMs)
                if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $got.Add([double]$r.RoundtripTime) }
            } catch { } finally { if ($p) { try { $p.Dispose() } catch { } } }
        }
        $avg = $null; $mn = $null; $mx = $null
        if ($got.Count -gt 0) {
            $sum = 0.0
            foreach ($x in $got) {
                $sum += $x
                if ($null -eq $mn -or $x -lt $mn) { $mn = $x }
                if ($null -eq $mx -or $x -gt $mx) { $mx = $x }
            }
            $avg = [math]::Round($sum / $got.Count, 1)
        }
        [pscustomobject]@{
            Address = $Address; Avg = $avg; Min = $mn; Max = $mx
            Loss = [math]::Round(100.0 * ($N - $got.Count) / [math]::Max(1, $N), 0)
        }
    }

    $gw = $null
    if ($Gateway) { $gw = Measure-Ping -Address $Gateway -N $Count -TimeoutMs 800 }

    # Each live target measured separately, so one provider having a bad
    # minute is visibly THEIR problem rather than looking like the line.
    $results = New-Object 'System.Collections.Generic.List[object]'
    foreach ($t in @($Targets)) {
        $addr = [string]$t
        if (-not $addr) { continue }
        $results.Add((Measure-Ping -Address $addr -N $Count -TimeoutMs 800))
    }

    # Uncacheable name, so the query really leaves the machine. NXDOMAIN is a
    # pass: we are testing that the resolver answers, not what it says.
    $dnsMs = $null; $dnsOk = $false; $hijack = $false
    $name = 'nw-' + ([guid]::NewGuid().ToString('N').Substring(0, 10)) + '.' + $DnsDomain
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $rec = @(Resolve-DnsName -Name $name -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop)
        $dnsOk = $true
        foreach ($r in $rec) { try { if ($r.IPAddress) { $hijack = $true } } catch { } }
    } catch {
        $fq = [string]$_.FullyQualifiedErrorId
        if ($fq -like 'DNS_ERROR_RCODE_NAME_ERROR*' -or $fq -like 'DNS_INFO_NO_RECORDS*') { $dnsOk = $true }
    }
    $sw.Stop()
    $dnsMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)

    [pscustomobject]@{
        Time = [DateTimeOffset]::Now
        Gw = $gw; Targets = $results.ToArray()
        DnsOk = $dnsOk; DnsMs = $dnsMs; DnsHijack = $hijack
    }
}

# Path to the internet. Slow by nature (seconds), so it runs rarely and always
# in the background.
$script:TraceScript = {
    param([string]$Target, [int]$MaxHops, [int]$Samples, [int]$TimeoutMs)

    $buffer = New-Object byte[] 32
    $hops = New-Object 'System.Collections.Generic.List[object]'
    $done = $false
    for ($ttl = 1; $ttl -le $MaxHops -and -not $done; $ttl++) {
        $addr = ''; $best = $null; $ok = 0
        $opts = New-Object System.Net.NetworkInformation.PingOptions($ttl, $false)
        for ($s = 0; $s -lt $Samples; $s++) {
            $p = $null
            try {
                $p = New-Object System.Net.NetworkInformation.Ping
                $r = $p.Send($Target, $TimeoutMs, $buffer, $opts)
                $st = $r.Status
                if ($st -eq [System.Net.NetworkInformation.IPStatus]::TtlExpired -or
                    $st -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    if (-not $addr -and $r.Address) { $addr = $r.Address.ToString() }
                    $rtt = [double]$r.RoundtripTime
                    if ($null -eq $best -or $rtt -lt $best) { $best = $rtt }
                    $ok++
                    if ($st -eq [System.Net.NetworkInformation.IPStatus]::Success) { $done = $true }
                }
            } catch { } finally { if ($p) { try { $p.Dispose() } catch { } } }
        }
        $hops.Add([pscustomobject]@{
            Ttl = $ttl; Address = $addr; Ms = $best
            Loss = [math]::Round(100.0 * ($Samples - $ok) / [math]::Max(1, $Samples), 0)
            Final = $done
        })
    }
    [pscustomobject]@{ Time = [DateTimeOffset]::Now; Hops = $hops.ToArray(); Target = $Target }
}

#endregion
#region ---- Packet capture (pktmon) ---------------------------------------------

# pktmon ships with Windows 10/11, so nothing has to be installed - but it
# needs administrator, and its command line and output format have changed
# between builds. This is written defensively: it tries the documented
# invocations, keeps the raw output, and shows it on the Packets tab when the
# parser does not recognise it, rather than silently displaying zeroes.

$script:PktScript = {
    param($Queue, [string]$Args1, [string]$Args2)

    function Push { param($Q, [string]$S) $Q.Enqueue($S) }

    # Leave no previous session running, whatever state it was in.
    try {
        $stop = New-Object System.Diagnostics.ProcessStartInfo
        $stop.FileName = 'pktmon.exe'; $stop.Arguments = 'stop'
        $stop.UseShellExecute = $false; $stop.CreateNoWindow = $true
        $stop.RedirectStandardOutput = $true; $stop.RedirectStandardError = $true
        $sp = [System.Diagnostics.Process]::Start($stop)
        $null = $sp.StandardOutput.ReadToEnd(); $null = $sp.StandardError.ReadToEnd()
        $sp.WaitForExit(5000)
    } catch { }

    foreach ($argset in @($Args1, $Args2)) {
        if (-not $argset) { continue }
        Push $Queue ('#CMD pktmon ' + $argset)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'pktmon.exe'
        $psi.Arguments = $argset
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $proc = $null
        try { $proc = [System.Diagnostics.Process]::Start($psi) }
        catch {
            Push $Queue ('#ERR could not start pktmon: ' + $_.Exception.Message)
            Push $Queue '#END'
            return
        }

        $lines = 0
        try {
            while (-not $proc.StandardOutput.EndOfStream) {
                $line = $proc.StandardOutput.ReadLine()
                if ($null -eq $line) { break }
                if ($line.Trim()) { Push $Queue $line; $lines++ }
            }
        } catch { Push $Queue ('#ERR read: ' + $_.Exception.Message) }

        try {
            $err = $proc.StandardError.ReadToEnd()
            if ($err -and $err.Trim()) { foreach ($l in $err -split "`r?`n") { if ($l.Trim()) { Push $Queue ('#ERR ' + $l) } } }
        } catch { }

        try { $proc.WaitForExit(3000) } catch { }
        if ($lines -gt 3) { Push $Queue '#END'; return }   # that invocation worked
        Push $Queue ('#RETRY produced ' + $lines + ' lines')
    }
    Push $Queue '#END'
}

function Start-PacketCapture {
    param($Config)
    $script:Pkt = @{
        Running = $false; Elevated = (Test-Elevated); Queue = $null; Job = $null
        Lines = (New-Object 'System.Collections.Generic.List[string]')
        Total = 0; Drops = 0; RxCount = 0; TxCount = 0
        Parsed = 0; Unparsed = 0
        PerSecond = (New-Object 'System.Collections.Generic.List[double]')
        DropsPerSecond = (New-Object 'System.Collections.Generic.List[double]')
        LastTick = [DateTimeOffset]::Now; TickTotal = 0; TickDrops = 0
        Protocols = @{}; Started = $null; Note = ''
    }
    if (-not $script:Pkt.Elevated) {
        $script:Pkt.Note = 'Packet capture needs administrator. Restart this dashboard from an elevated PowerShell.'
        return
    }
    if (-not (Get-Command 'pktmon.exe' -ErrorAction SilentlyContinue)) {
        $script:Pkt.Note = 'pktmon.exe was not found. It ships with Windows 10 1809 and later.'
        return
    }

    $script:Pkt.Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    # Two forms: newer builds want --log-mode real-time, older ones -m real-time.
    Start-Worker -Name 'pkt' -TimeoutSec 2147483 -Body $script:PktScript -ArgumentList @(
        $script:Pkt.Queue,
        'start --capture --pkt-size 0 --log-mode real-time',
        'start -c -m real-time'
    )
    $script:Pkt.Running = $true
    $script:Pkt.Started = [DateTimeOffset]::Now
    $script:Pkt.Note = 'starting capture...'
}

function Update-PacketCapture {
    # Drains whatever the capture pushed since the last frame and folds it into
    # counters. Tolerant on purpose: anything it cannot classify is counted as
    # unparsed and kept verbatim for the raw pane.
    if (-not $script:Pkt -or -not $script:Pkt.Running -or -not $script:Pkt.Queue) { return }

    $line = ''
    $drained = 0
    while ($drained -lt 2000 -and $script:Pkt.Queue.TryDequeue([ref]$line)) {
        $drained++
        if ($line.StartsWith('#')) {
            if ($line.StartsWith('#ERR')) { $script:Pkt.Note = $line.Substring(4).Trim() }
            elseif ($line.StartsWith('#CMD')) { $script:Pkt.Note = 'running: ' + $line.Substring(4).Trim() }
            elseif ($line -eq '#END') { $script:Pkt.Running = $false }
            $script:Pkt.Lines.Add($line)
            continue
        }

        $script:Pkt.Lines.Add($line)
        while ($script:Pkt.Lines.Count -gt 300) { $script:Pkt.Lines.RemoveAt(0) }

        $recognised = $false

        # Direction, however this build spells it.
        if ($line -match '(?i)\bDir(ection)?\s*[: ]\s*(\d+|in|out|rx|tx)\b') {
            $d = $Matches[2].ToLowerInvariant()
            if ($d -eq '1' -or $d -eq 'in' -or $d -eq 'rx') { $script:Pkt.RxCount++ } else { $script:Pkt.TxCount++ }
            $recognised = $true
        }
        if ($line -match '(?i)drop') {
            $script:Pkt.Drops++; $script:Pkt.TickDrops++
            $recognised = $true
            if ($line -match '(?i)DropReason\s*[: ]\s*([A-Za-z0-9_]+)') {
                $k = 'drop:' + $Matches[1]
                if (-not $script:Pkt.Protocols.ContainsKey($k)) { $script:Pkt.Protocols[$k] = 0 }
                $script:Pkt.Protocols[$k]++
            }
        }
        # Protocol and port, when the build prints a parsed header.
        if ($line -match '(?i)\b(TCP|UDP|ICMP|ICMPv6|ARP|IGMP)\b') {
            $k = $Matches[1].ToUpperInvariant()
            if (-not $script:Pkt.Protocols.ContainsKey($k)) { $script:Pkt.Protocols[$k] = 0 }
            $script:Pkt.Protocols[$k]++
            $recognised = $true
        }

        if ($recognised) { $script:Pkt.Parsed++ } else { $script:Pkt.Unparsed++ }
        $script:Pkt.Total++
        $script:Pkt.TickTotal++
    }

    $now = [DateTimeOffset]::Now
    if (($now - $script:Pkt.LastTick).TotalMilliseconds -ge 1000) {
        $script:Pkt.PerSecond.Add([double]$script:Pkt.TickTotal)
        $script:Pkt.DropsPerSecond.Add([double]$script:Pkt.TickDrops)
        while ($script:Pkt.PerSecond.Count -gt 240) { $script:Pkt.PerSecond.RemoveAt(0) }
        while ($script:Pkt.DropsPerSecond.Count -gt 240) { $script:Pkt.DropsPerSecond.RemoveAt(0) }
        $script:Pkt.TickTotal = 0; $script:Pkt.TickDrops = 0
        $script:Pkt.LastTick = $now
        if ($script:Pkt.Total -gt 0 -and $script:Pkt.Note -like 'running:*') {
            $script:Pkt.Note = 'capturing'
        }
    }
}

# Averages over the Health window, read from the collector's probe CSVs in
# the worker pool: seven days is ~10,000 rows, which would freeze the screen
# for seconds on the drawing thread. Keyed by 'gw', 'dns' or the address.
$script:CurrentHealthWindow = 60   # set from the config every frame

$script:PingAvgScript = {
    param([string[]]$Files, [long]$SinceUtcTicks)
    $acc = @{}
    $add = {
        param($Key, $Avg, $Min, $Loss)
        if (-not $Key) { return }
        if (-not $acc.ContainsKey($Key)) { $acc[$Key] = @{ Sum = 0.0; N = 0; MinSum = 0.0; MinN = 0; LossSum = 0.0; LossN = 0; Best = [double]::MaxValue } }
        $e = $acc[$Key]
        $d = 0.0
        if ($Avg -and [double]::TryParse([string]$Avg, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
            $e.Sum += $d; $e.N++
        }
        if ($Min -and [double]::TryParse([string]$Min, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
            $e.MinSum += $d; $e.MinN++
            if ($d -lt $e.Best) { $e.Best = $d }
        }
        if ($Loss -and [double]::TryParse([string]$Loss, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
            $e.LossSum += $d; $e.LossN++
        }
    }
    $rows = 0
    foreach ($f in $Files) {
        try {
            foreach ($r in (Import-Csv -LiteralPath $f)) {
                $ts = [DateTimeOffset]::MinValue
                if (-not [DateTimeOffset]::TryParse([string]$r.timestamp, [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::None, [ref]$ts)) { continue }
                if ($ts.UtcTicks -lt $SinceUtcTicks) { continue }
                $rows++
                & $add 'gw' $r.gw_avg_ms $r.gw_min_ms $r.gw_loss_pct
                & $add 'dns' $r.dns_ms $r.dns_ms $null
                foreach ($p in 't1', 't2', 't3', 't4', 't5', 'c1', 'c2') {
                    $addr = [string]$r.($p + '_addr')
                    if ($addr) { & $add $addr $r.($p + '_avg_ms') $r.($p + '_min_ms') $r.($p + '_loss_pct') }
                }
            }
        } catch { }
    }
    $out = @{}
    foreach ($k in $acc.Keys) {
        $e = $acc[$k]
        $o = @{ Avg = $null; MinAvg = $null; Best = $null; Loss = $null; N = $e.N }
        if ($e.N -gt 0) { $o.Avg = [math]::Round($e.Sum / $e.N, 1) }
        if ($e.MinN -gt 0) { $o.MinAvg = [math]::Round($e.MinSum / $e.MinN, 1); $o.Best = $e.Best }
        if ($e.LossN -gt 0) { $o.Loss = [math]::Round($e.LossSum / $e.LossN, 2) }
        $out[$k] = $o
    }
    New-Object PSObject -Property @{ ByKey = $out; Rows = $rows; At = [DateTimeOffset]::Now }
}

function Update-PingAverages {
    # Every minute for short windows, every five for long ones: a 7-day
    # average does not move in a minute, and reading it is not free.
    param($Config)
    $r = Receive-Worker -Name 'pingavg'
    if ($r) { $script:Live.PingAvg = $r }
    $mins = [int]$Config['HealthAvgMinutes']
    $every = 60
    if ($mins -gt 180) { $every = 300 }
    if (([DateTimeOffset]::Now - $script:Live.LastAvgAt).TotalSeconds -lt $every) { return }
    $script:Live.LastAvgAt = [DateTimeOffset]::Now
    $since = [DateTimeOffset]::Now.AddMinutes(-$mins)
    $files = @(Get-DataFiles -Kind 'probe' -Since $since.LocalDateTime.Date | ForEach-Object { $_.Path })
    Start-Worker -Name 'pingavg' -TimeoutSec 120 -Body $script:PingAvgScript -ArgumentList @([string[]]$files, $since.UtcTicks)
}

function Format-Window {
    # 5 -> '5 min', 180 -> '3 h', 1440 -> '1 day', 10080 -> '7 days'
    param([int]$Minutes)
    if ($Minutes -lt 60) { return ('{0} min' -f $Minutes) }
    if ($Minutes -lt 1440) { return ('{0} h' -f [math]::Round($Minutes / 60.0, 1)) }
    $d = [math]::Round($Minutes / 1440.0, 1)
    if ($d -eq 1) { return '1 day' }
    '{0} days' -f $d
}

function Update-CapturePause {
    # A speed test (from here, or the scheduled task in another process)
    # leaves speedtest.running in the data folder while it measures. Capture
    # stops for that window and starts again afterwards. A marker older than
    # ten minutes is a leftover from a crash and is ignored.
    param($Config)
    if (-not $script:Pkt -or -not $script:Pkt.Elevated) { return }
    $now = [DateTimeOffset]::Now
    if (($now - $script:Live.LastLockCheck).TotalMilliseconds -lt 1000) { return }
    $script:Live.LastLockCheck = $now

    $active = $false
    $lock = Join-Path $script:DataDir 'speedtest.running'
    if (Test-Path -LiteralPath $lock) {
        try { $active = (((Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime).TotalMinutes -lt 10) } catch { $active = $true }
    }
    if ($active -and $script:Pkt.Running) {
        Stop-PacketCapture
        $j = $script:Jobs['pkt']
        if ($j) {
            try { $null = $j.Handle.AsyncWaitHandle.WaitOne(3000) } catch { }
            try { $j.PS.Stop(); $j.PS.Dispose() } catch { }
            $script:Jobs['pkt'] = $null
        }
        $script:Pkt.Running = $false
        $script:Pkt.PausedForSpeed = $true
        $script:Pkt.Note = 'paused while a speed test runs, so capture does not slow it down'
    } elseif (-not $active -and $script:Pkt.PausedForSpeed) {
        Start-PacketCapture -Config $Config
    }
}

function Stop-PacketCapture {
    # Leaving a pktmon session running would keep costing the machine after we
    # exit, so this runs from the app's finally block.
    if (-not $script:Pkt -or -not $script:Pkt.Elevated) { return }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'pktmon.exe'; $psi.Arguments = 'stop'
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $null = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit(5000)
    } catch { }
}

#endregion
#region ---- Derived live model ---------------------------------------------------

function Update-InterfaceRates {
    # Byte counters are cumulative; the rate needs the previous reading and the
    # real elapsed time between them, not the nominal refresh interval.
    param($Snapshot)
    if (-not $script:Live.PrevSnap) {
        $script:Live.PrevSnap = $Snapshot
        return
    }
    $prev = $script:Live.PrevSnap
    $span = ($Snapshot.Time - $prev.Time).TotalSeconds
    if ($span -le 0.05) { return }

    $prevMap = @{}
    foreach ($a in @($prev.Adapters)) { $prevMap[$a.Name] = $a }

    foreach ($a in @($Snapshot.Adapters)) {
        $rxR = $null; $txR = $null
        if ($prevMap.ContainsKey($a.Name)) {
            $p = $prevMap[$a.Name]
            if ($null -ne $a.Rx -and $null -ne $p.Rx -and $a.Rx -ge $p.Rx) { $rxR = ($a.Rx - $p.Rx) / $span }
            if ($null -ne $a.Tx -and $null -ne $p.Tx -and $a.Tx -ge $p.Tx) { $txR = ($a.Tx - $p.Tx) / $span }
        }
        Add-Member -InputObject $a -NotePropertyName RxRate -NotePropertyValue $rxR -Force
        Add-Member -InputObject $a -NotePropertyName TxRate -NotePropertyValue $txR -Force
    }

    # Whole-machine totals drive the two big graphs.
    $rxTot = 0.0; $txTot = 0.0; $any = $false
    foreach ($a in @($Snapshot.Adapters)) {
        if ($null -ne $a.RxRate) { $rxTot += $a.RxRate; $any = $true }
        if ($null -ne $a.TxRate) { $txTot += $a.TxRate }
    }
    if ($any) {
        $script:Live.RxHistory.Add($rxTot)
        $script:Live.TxHistory.Add($txTot)
        while ($script:Live.RxHistory.Count -gt 600) { $script:Live.RxHistory.RemoveAt(0) }
        while ($script:Live.TxHistory.Count -gt 600) { $script:Live.TxHistory.RemoveAt(0) }
        $script:Live.RxRate = $rxTot
        $script:Live.TxRate = $txTot
    }
    $script:Live.PrevSnap = $Snapshot
}

function Initialize-LiveModel {
    # Declared up front: under Set-StrictMode, reading an unset variable
    # throws, and the Packets panel reads this before capture starts.
    if (-not (Test-Path 'variable:script:Pkt')) { $script:Pkt = $null }
    $script:Live = @{
        Snap = $null; PrevSnap = $null; SnapAt = [DateTimeOffset]::MinValue
        Health = $null
        Trace = $null
        RxRate = 0.0; TxRate = 0.0
        RxHistory = (New-Object 'System.Collections.Generic.List[double]')
        TxHistory = (New-Object 'System.Collections.Generic.List[double]')
        GwHistory = (New-Object 'System.Collections.Generic.List[double]')
        DnsHistory = (New-Object 'System.Collections.Generic.List[double]')
        TargetHistory = @{}      # address -> List[double], one series per live target
        LastSnapAt = [DateTimeOffset]::MinValue
        LastLockCheck = [DateTimeOffset]::MinValue
        PingAvg = $null          # per-target averages over HealthAvgMinutes, from the collector's CSVs
        LastAvgAt = [DateTimeOffset]::MinValue
        LastHealthAt = [DateTimeOffset]::MinValue
        LastTraceAt = [DateTimeOffset]::MinValue
        ConnSeen = @{}           # connection key -> first time it was seen
        Tasks = $null            # scheduled task status, for the Settings tab
        LastTaskAt = [DateTimeOffset]::MinValue
        Speed = @()              # last three speed tests, newest first
        LastSpeedAt = [DateTimeOffset]::MinValue
        LastHistAt = [DateTimeOffset]::MinValue
        Hist = $null          # rows from the collector's CSVs, for Stats/Timeline
        Events = $null
    }
}

function Update-ConnectionAges {
    # Remembers when each connection first appeared, so the Dashboard can show
    # what is new rather than the same alphabetical handful every refresh.
    param($Snapshot)
    $seen = $script:Live.ConnSeen
    $now = [DateTimeOffset]::Now
    $present = @{}
    foreach ($c in @($Snapshot.Tcp)) {
        $k = Get-ConnectionKey $c
        $present[$k] = $true
        if (-not $seen.ContainsKey($k)) {
            # Everything already open at start-up gets the start time: it is
            # old news, not a burst of new connections.
            $seen[$k] = $now
        }
    }
    foreach ($k in @($seen.Keys)) { if (-not $present.ContainsKey($k)) { $seen.Remove($k) } }
}

function Get-TopConnections {
    # Established, outbound, newest first. Loopback chatter is filtered out:
    # it is never what someone opened this to see.
    param([int]$Limit = 8)
    if (-not $script:Live.Snap) { return @() }
    $seen = $script:Live.ConnSeen
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($c in @($script:Live.Snap.Tcp)) {
        if ([string]$c.State -ne 'Established') { continue }
        if ($c.RemoteIp -eq '127.0.0.1' -or $c.RemoteIp -eq '::1' -or $c.RemoteIp -eq '0.0.0.0') { continue }
        $first = [DateTimeOffset]::Now
        $k = Get-ConnectionKey $c
        if ($seen.ContainsKey($k)) { $first = $seen[$k] }
        $list.Add([pscustomobject]@{ Conn = $c; First = $first })
    }
    $sorted = @($list.ToArray() | Sort-Object -Property @{ Expression = 'First'; Descending = $true }, @{ Expression = { $_.Conn.Proc } })
    if ($sorted.Count -gt $Limit) { $sorted = $sorted[0..($Limit - 1)] }
    $sorted
}

function Format-Age {
    param([TimeSpan]$Span)
    if ($Span.TotalSeconds -lt 60) { return ('{0}s' -f [int]$Span.TotalSeconds) }
    if ($Span.TotalMinutes -lt 60) { return ('{0}m' -f [int]$Span.TotalMinutes) }
    if ($Span.TotalHours -lt 24) { return ('{0}h' -f [int]$Span.TotalHours) }
    '{0}d' -f [int]$Span.TotalDays
}

function Get-TopConnectionsEmptyText {
    # When the Dashboard list is empty, say what was actually seen, so an
    # empty panel explains itself instead of looking like a fault.
    $snap = $script:Live.Snap
    if (-not $snap) { return 'waiting for the first connection sample...' }
    if ($snap.Error) { return 'could not read connections: ' + $snap.Error }
    $tcp = @($snap.Tcp)
    if ($tcp.Count -lt 1) { return 'no TCP sockets reported' }
    $by = @{}
    foreach ($c in $tcp) { $k = [string]$c.State; if (-not $by.ContainsKey($k)) { $by[$k] = 0 }; $by[$k]++ }
    $top = @($by.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 4 | ForEach-Object { '{0} {1}' -f $_.Key, $_.Value })
    'no established outbound connections ({0} TCP sockets: {1})' -f $tcp.Count, ($top -join ', ')
}

#endregion
#region ---- Actions: close a connection, end a process -------------------------

$script:TcpCloserReady = $null

function Initialize-TcpCloser {
    # SetTcpEntry with state DELETE_TCB resets one TCP connection. It is the
    # only per-connection close Windows offers: IPv4 TCP only, admin only.
    if ($null -ne $script:TcpCloserReady) { return $script:TcpCloserReady }
    if ('PsnmTcp' -as [type]) { $script:TcpCloserReady = $true; return $true }
    $src = @"
using System;
using System.Net;
using System.Runtime.InteropServices;
public static class PsnmTcp {
    [StructLayout(LayoutKind.Sequential)]
    public struct MIB_TCPROW {
        public uint dwState; public uint dwLocalAddr; public uint dwLocalPort;
        public uint dwRemoteAddr; public uint dwRemotePort;
    }
    [DllImport("iphlpapi.dll")]
    static extern int SetTcpEntry(ref MIB_TCPROW row);
    static uint Port(int p) { return (uint)(((p & 0xFF) << 8) | ((p >> 8) & 0xFF)); }
    static uint Addr(string ip) { return BitConverter.ToUInt32(IPAddress.Parse(ip).GetAddressBytes(), 0); }
    public static int Close(string localIp, int localPort, string remoteIp, int remotePort) {
        MIB_TCPROW r = new MIB_TCPROW();
        r.dwState = 12;
        r.dwLocalAddr = Addr(localIp); r.dwLocalPort = Port(localPort);
        r.dwRemoteAddr = Addr(remoteIp); r.dwRemotePort = Port(remotePort);
        return SetTcpEntry(ref r);
    }
}
"@
    try { Add-Type -TypeDefinition $src -ErrorAction Stop; $script:TcpCloserReady = $true }
    catch { $script:TcpCloserReady = $false }
    $script:TcpCloserReady
}

function Split-Endpoint {
    # "1.2.3.4:443" or "fe80::1:443" -> ip, port (split on the LAST colon).
    param([string]$Text)
    $i = $Text.LastIndexOf(':')
    if ($i -lt 1) { return @{ Ip = $Text; Port = 0 } }
    $port = 0
    [void][int]::TryParse($Text.Substring($i + 1), [ref]$port)
    @{ Ip = $Text.Substring(0, $i).Trim('[', ']'); Port = $port }
}

function Close-TcpConnection {
    # Returns a one-line result for the status bar.
    param($Conn)
    if ($Conn.Proto -ne 'TCP') { return 'UDP has no connection to close; use p to end the process' }
    if ([string]$Conn.State -notin @('Established', 'SynSent', 'SynReceived', 'CloseWait', 'FinWait1', 'FinWait2')) {
        return ('cannot close a {0} socket; use p to end the process' -f $Conn.State)
    }
    $lo = Split-Endpoint $Conn.Local
    $re = Split-Endpoint $Conn.Remote
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($lo.Ip, [ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork') {
        return 'Windows can only close IPv4 connections individually; use p to end the process'
    }
    if (-not (Test-ElevatedCached)) { return 'closing a connection needs PS-NETMON running as administrator' }
    if (-not (Initialize-TcpCloser)) { return 'could not load the connection-closing helper' }
    $rc = [PsnmTcp]::Close($lo.Ip, $lo.Port, $re.Ip, $re.Port)
    switch ($rc) {
        0   { return ('closed {0} -> {1} ({2})' -f $Conn.Local, $Conn.Remote, $Conn.Proc) }
        5   { return 'access denied: run PS-NETMON as administrator' }
        317 { return 'Windows refused (code 317): needs administrator, or the connection already closed' }
        default { return ('Windows refused to close it (code {0}); it may already be gone' -f $rc) }
    }
}

$script:ProtectedProcesses = @('system', 'idle', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass',
                               'lsaiso', 'svchost', 'dwm', 'fontdrvhost', 'registry', 'memory compression',
                               'secure system', 'spoolsv', 'msmpeng')

function Stop-ConnectionOwner {
    # Ends the process that owns a socket, after the caller has confirmed.
    param($Conn)
    $procId = [int]$Conn.ProcId
    if ($procId -le 4) { return 'that socket belongs to the system; it cannot be ended' }
    if ($procId -eq $PID) { return 'that is PS-NETMON itself' }
    if ($script:ProtectedProcesses -contains ([string]$Conn.Proc).ToLowerInvariant()) {
        return ('{0} is a core Windows process; ending it could crash or lock the machine' -f $Conn.Proc)
    }
    try {
        Stop-Process -Id $procId -Force -ErrorAction Stop
        return ('ended {0} (pid {1})' -f $Conn.Proc, $procId)
    } catch {
        $m = $_.Exception.Message
        if ($m -match 'denied') { return ('access denied ending {0}: run as administrator' -f $Conn.Proc) }
        return ('could not end {0}: {1}' -f $Conn.Proc, $m)
    }
}

function Get-ConnectionKey {
    # Identity of a row that survives re-sorting and refreshes.
    param($Conn)
    '{0}|{1}|{2}|{3}' -f $Conn.Proto, $Conn.Local, $Conn.Remote, $Conn.ProcId
}

#endregion
#region ---- Sampler: rollups ------------------------------------------------------

function Get-ProcessSummary {
    # Per-process rollup. Windows does not attribute bytes to a process without
    # ETW, so this counts sockets and states - and the column headers say so
    # rather than implying a byte count we cannot measure.
    if (-not $script:Live.Snap) { return @() }
    $agg = @{}
    foreach ($c in (@($script:Live.Snap.Tcp) + @($script:Live.Snap.Udp))) {
        $k = $c.Proc
        if (-not $agg.ContainsKey($k)) {
            $agg[$k] = [pscustomobject]@{
                Proc = $k; ProcId = $c.ProcId; Total = 0; Established = 0
                Listen = 0; Wait = 0; Udp = 0; Remotes = (New-Object 'System.Collections.Generic.HashSet[string]')
            }
        }
        $a = $agg[$k]
        $a.Total++
        if ($c.Proto -eq 'UDP') { $a.Udp++ }
        elseif ($c.State -eq 'Established') { $a.Established++; if ($c.RemoteIp) { $null = $a.Remotes.Add($c.RemoteIp) } }
        elseif ($c.State -like 'Listen*') { $a.Listen++ }
        else { $a.Wait++ }
    }
    @($agg.Values | Sort-Object -Property @{ Expression = 'Established'; Descending = $true }, @{ Expression = 'Total'; Descending = $true })
}

#endregion
#region ---- Chrome: tab bar and status bar ---------------------------------------

$script:TabNames = @('Dashboard', 'Connections', 'Interfaces', 'Packets', 'Stats', 'Topology', 'Timeline', 'Processes', 'Settings')

function Draw-Chrome {
    param($Screen)
    $Pal = $script:Col
    $w = $Screen.W

    Fill-Rect $Screen 0 0 $w 1 ' ' $Pal.Text $Pal.Panel

    # Live state dot: the collector's verdict, not a guess made here.
    $state = 'unknown'
    if ($script:App.State) { $state = [string]$script:App.State.State }
    $dotCol = switch ($state) {
        'Up' { $Pal.Ok } 'Degraded' { $Pal.Warn } 'Down' { $Pal.Bad } default { $Pal.Off }
    }
    Write-Buf $Screen 1 0 $script:Gfx.Dot $dotCol $Pal.Panel
    Write-Buf $Screen 3 0 'PS-NETMON' $Pal.White $Pal.Panel

    # Full names when they fit, otherwise the active tab's name only, and in
    # the last resort just the numbers - the bar never truncates mid-word.
    $need = 14
    foreach ($n in $script:TabNames) { $need += $n.Length + 5 }
    $mode = 0
    if ($need -gt $w - 11) { $mode = 1 }
    if (14 + $script:TabNames.Count * 4 + $script:TabNames[$script:App.Tab].Length + 2 -gt $w - 11) { $mode = 2 }

    $x = 14
    for ($i = 0; $i -lt $script:TabNames.Count; $i++) {
        $active = ($i -eq $script:App.Tab)
        $show = ($mode -eq 0) -or ($mode -eq 1 -and $active)
        Write-Buf $Screen $x 0 ('[{0}]' -f ($i + 1)) $(if ($active) { $Pal.Yellow } else { $Pal.Dim }) $Pal.Panel
        $x += 3
        if ($show) {
            $nm = ' ' + $script:TabNames[$i]
            Write-Buf $Screen $x 0 $nm $(if ($active) { $Pal.White } else { $Pal.Faint }) $Pal.Panel
            $x += $nm.Length
        }
        $x += 1
    }

    $clock = (Get-Date).ToString('HH:mm:ss')
    if ($script:App.Paused) { $clock = 'PAUSED  ' + $clock }
    Write-Buf $Screen ($w - $clock.Length - 1) 0 $clock $(if ($script:App.Paused) { $Pal.Yellow } else { $Pal.Dim }) $Pal.Panel

    # Status bar.
    $y = $Screen.H - 1
    Fill-Rect $Screen 0 $y $w 1 ' ' $Pal.Text -1
    $keys = @(
        @('1-9', 'tab'), @('Tab', 'next'), @('p', 'pause'), @('r', 'refresh'),
        @('s', 'sort'), @('f', 'filter'), @('c', 'target'), @('g', 'glyphs'), @('t', 'trace'), @('R', 'report'), @('q', 'quit')
    )
    $x = 1
    foreach ($k in $keys) {
        if ($x + $k[0].Length + $k[1].Length + 3 -ge $w) { break }
        Write-Buf $Screen $x $y $k[0] $Pal.Yellow
        $x += $k[0].Length
        Write-Buf $Screen $x $y (':' + $k[1] + '  ') $Pal.Faint
        $x += $k[1].Length + 3
    }
    if ($script:App.Message) {
        $m = $script:App.Message
        if ($m.Length -gt $w - $x - 2) { $m = $m.Substring(0, [math]::Max(0, $w - $x - 2)) }
        Write-Buf $Screen ($w - $m.Length - 1) $y $m $Pal.Cyan
    }
}

function Draw-Empty {
    param($Screen, [int]$X, [int]$Y, [int]$W, [string]$Text)
    Write-Buf $Screen ($X + 2) $Y $Text $script:Col.Faint -2 ($W - 4)
}

#endregion
#region ---- Tab 1: Dashboard -----------------------------------------------------

function Draw-TabDashboard {
    param($Screen, [int]$X, [int]$Y, [int]$W, [int]$H)
    $Pal = $script:Col
    $cy = $Y
    $snap = $script:Live.Snap

    # --- interfaces -------------------------------------------------------
    $adapters = @()
    if ($snap) { $adapters = @($snap.Adapters | Where-Object { $_.Status -ne 'Not Present' }) }
    $ifRows = [math]::Min($adapters.Count, [math]::Max(2, [int](($H - 16) / 1)))
    if ($ifRows -lt 1) { $ifRows = 1 }
    # The speed test block sits to the right of the table and needs six rows
    # (header plus five), so on a wide screen the panel is never shorter.
    # Three tests when there is room, two on a narrower window, none below that.
    $tableW = 87     # the seven columns below plus the gaps between them
    $speedN = 3
    $speedW = 11 + 12 * $speedN
    if ($W - 4 -lt $tableW + 3 + $speedW) { $speedN = 2; $speedW = 11 + 12 * $speedN }
    $showSpeed = ($W - 4 -ge $tableW + 3 + $speedW)
    # Header, six rows and the countdown: eight rows inside the box.
    if ($showSpeed -and $ifRows -lt 7 -and $H -ge 36) { $ifRows = 7 }
    $ifH = $ifRows + 3
    if ($ifH -gt $H - 10) { $ifH = [math]::Max(4, $H - 10); $ifRows = $ifH - 3 }

    Draw-Box $Screen $X $cy $W $ifH 'Interfaces'
    if ($adapters.Count -lt 1) {
        Draw-Empty $Screen $X ($cy + 1) $W 'waiting for the first adapter sample...'
    } else {
        $cols = @(
            @{ Name = 'Interface'; Width = 14 }, @{ Name = 'IP Address'; Width = 16 },
            @{ Name = 'RX Rate'; Width = 11; Align = 'R' }, @{ Name = 'TX Rate'; Width = 11; Align = 'R' },
            @{ Name = 'RX Total'; Width = 10; Align = 'R' }, @{ Name = 'TX Total'; Width = 10; Align = 'R' },
            @{ Name = 'Status'; Width = 8 }
        )
        $rows = @()
        foreach ($a in $adapters) {
            $up = ($a.Status -eq 'Up')
            $rows += , @(
                @{ Text = $a.Name; Fg = $(if ($up) { $Pal.White } else { $Pal.Faint }) }
                @{ Text = $(if ($a.Ip) { $a.Ip } else { '-' }); Fg = $Pal.Text }
                @{ Text = (Format-Rate $a.RxRate); Fg = $(if ($a.RxRate -gt 0) { $Pal.Green } else { $Pal.Faint }) }
                @{ Text = (Format-Rate $a.TxRate); Fg = $(if ($a.TxRate -gt 0) { $Pal.Cyan } else { $Pal.Faint }) }
                @{ Text = (Format-Bytes $a.Rx); Fg = $Pal.Dim }
                @{ Text = (Format-Bytes $a.Tx); Fg = $Pal.Dim }
                @{ Text = (Format-LinkStatus $a.Status); Fg = $(if ($up) { $Pal.Ok } else { $Pal.Off }) }
            )
        }
        $tw = $W - 4
        if ($showSpeed) { $tw = $tableW }
        $null = Draw-Table $Screen ($X + 2) ($cy + 1) $tw $ifRows $cols $rows
    }
    if ($showSpeed) {
        Draw-SpeedSummary $Screen ($X + $W - 2 - $speedW) ($cy + 1) $speedW ($ifH - 2) $speedN
    }
    $cy += $ifH

    # --- throughput graphs ------------------------------------------------
    # Space is budgeted from the bottom up: the Health gauges get what they
    # need first, and the graphs take what is left. Otherwise the gauges are
    # the thing that silently falls off the bottom of the screen.
    $healthNeed = 16
    $healthMin = 10
    $connNeed = 7
    $spare = $H - $ifH - $healthNeed - $connNeed
    $gH = [math]::Max(3, [math]::Min(6, [int]($spare / 2) - 2))
    foreach ($dir in @('RX', 'TX')) {
        if ($cy + $gH + 2 -gt $Y + $H) { break }
        $hist = $(if ($dir -eq 'RX') { $script:Live.RxHistory } else { $script:Live.TxHistory })
        $rate = $(if ($dir -eq 'RX') { $script:Live.RxRate } else { $script:Live.TxRate })
        $tone = $(if ($dir -eq 'RX') { $Pal.Green } else { $Pal.Cyan })
        $mark = $(if ($dir -eq 'RX') { $script:Gfx.Down } else { $script:Gfx.Up })

        # Name only what is actually carrying traffic: listing every virtual
        # and disconnected adapter pushes the rate off the end of the title.
        $active = @($adapters | Where-Object { $_.Status -eq 'Up' -and (($_.RxRate -gt 0) -or ($_.TxRate -gt 0)) })
        if ($active.Count -lt 1) { $active = @($adapters | Where-Object { $_.Status -eq 'Up' }) }
        $names = (@($active | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ' + ')
        if ($active.Count -gt 3) { $names += (' +{0} more' -f ($active.Count - 3)) }
        if (-not $names) { $names = 'no active interface' }
        $title = '{0} {1}   {2}   last {3}s' -f $mark, $names, (Format-Rate $rate), $hist.Count
        if ($title.Length -gt $W - 6) { $title = $title.Substring(0, $W - 6) }

        Draw-Box $Screen $X $cy $W ($gH + 2) ''
        Write-Buf $Screen ($X + 2) $cy (' ' + $title + ' ') $tone
        Draw-Chart $Screen ($X + 2) ($cy + 1) ($W - 4) $gH $hist $tone
        $cy += $gH + 2
    }

    # --- top connections --------------------------------------------------
    $remaining = ($Y + $H) - $cy
    if ($remaining -ge 6) {
        # Respect the budget reserved above, or Top Connections eats the rows
        # the Health gauges need.
        $connH = [math]::Max(4, [math]::Min($connNeed, $remaining - $healthMin))
        $conns = @(Get-TopConnections -Limit ($connH - 3))
        $est = 0
        if ($script:Live.Snap) { $est = @($script:Live.Snap.Tcp | Where-Object { [string]$_.State -eq 'Established' }).Count }
        $title = 'Top Connections'
        if ($script:Live.Snap) {
            $title = 'Top Connections  ({0} established, newest first' -f $est
            if ($script:Live.SnapAt -gt [DateTimeOffset]::MinValue) {
                $title += ', updated {0}s ago' -f [math]::Floor(([DateTimeOffset]::Now - $script:Live.SnapAt).TotalSeconds)
            }
            $title += ')'
        }
        Draw-Box $Screen $X $cy $W $connH $title
        if ($conns.Count -lt 1) {
            Draw-Empty $Screen $X ($cy + 1) $W (Get-TopConnectionsEmptyText)
        } else {
            $cols = @(
                @{ Name = 'Process'; Width = 20 }, @{ Name = 'PID'; Width = 7; Align = 'R' },
                @{ Name = 'Age'; Width = 5; Align = 'R' }, @{ Name = 'Local'; Width = 24 },
                @{ Name = 'Remote'; Width = 44 }
            )
            $rows = @()
            $now = [DateTimeOffset]::Now
            foreach ($t in $conns) {
                $c = $t.Conn
                $age = $now - $t.First
                # Opened in the last ten seconds: worth a second look.
                $ageFg = $Pal.Dim
                if ($age.TotalSeconds -lt 10) { $ageFg = $Pal.Yellow }
                $rows += , @(
                    @{ Text = $c.Proc; Fg = $Pal.Text }
                    @{ Text = [string]$c.ProcId; Fg = $Pal.Faint }
                    @{ Text = (Format-Age $age); Fg = $ageFg }
                    @{ Text = $c.Local; Fg = $Pal.Dim }
                    @{ Text = $c.Remote; Fg = $Pal.Cyan }
                )
            }
            $null = Draw-Table $Screen ($X + 2) ($cy + 1) ($W - 4) ($connH - 3) $cols $rows
        }
        $cy += $connH
    }

    # --- health gauges ----------------------------------------------------
    $remaining = ($Y + $H) - $cy
    if ($remaining -ge 6) {
        Draw-HealthGauges $Screen $X $cy $W ([math]::Min($remaining, 22))
    }
}

function Format-Mbps {
    param($Value)
    if ($null -eq $Value -or [string]$Value -eq '') { return '-' }
    $v = [double]$Value
    if ($v -ge 1000) { return ('{0:0.00} Gb/s' -f ($v / 1000.0)) }
    if ($v -ge 100) { return ('{0:0} Mb/s' -f $v) }
    return ('{0:0.0} Mb/s' -f $v)
}

function Format-LatMs {
    param($Value)
    if ($null -eq $Value -or [string]$Value -eq '') { return '-' }
    $v = [double]$Value
    if ($v -ge 100) { return ('{0:0} ms' -f $v) }
    return ('{0} ms' -f [math]::Round($v, 1))
}

function Get-BloatTone {
    # Loaded latency judged by how far it rises over idle, the usual
    # bufferbloat grading: under 30 ms extra is fine, over 100 ms hurts calls.
    param($Loaded, $Idle)
    $Pal = $script:Col
    if ($null -eq $Loaded -or [string]$Loaded -eq '') { return $Pal.Faint }
    if ($null -eq $Idle -or [string]$Idle -eq '') { return $Pal.Text }
    $rise = [double]$Loaded - [double]$Idle
    if ($rise -lt 30) { return $Pal.Ok }
    if ($rise -lt 100) { return $Pal.Warn }
    return $Pal.Bad
}

function Get-SpeedValue {
    # One field of the Nth speed test, or $null when missing or blank.
    param($Tests, [int]$Index, [string]$Field)
    $list = @($Tests)
    if ($Index -ge $list.Count) { return $null }
    $v = Get-Field $list[$Index].Row $Field
    if ($null -eq $v -or [string]$v -eq '') { return $null }
    $v
}

function Get-NextSpeedTestText {
    # Countdown to the SpeedTest task's next run, from Task Scheduler's own
    # NextRunTime. Counted locally between refreshes, so it ticks every frame.
    $A = $script:App
    if ($A.SetJob -and $A.SetJob.Mode -eq 'SpeedTest') { return @{ Text = 'running now'; Tone = 'run' } }
    $info = $script:Live.Tasks
    if (-not $info) { return @{ Text = 'checking...'; Tone = 'dim' } }
    $t = $null
    foreach ($c in @($info.Tasks)) { if ($c.Name -eq $script:TaskSpeed) { $t = $c } }
    if (-not $t -or -not $t.Installed) {
        if ($t -and $t.Error) { return @{ Text = 'unknown (task check failed)'; Tone = 'warn' } }
        return @{ Text = 'not scheduled - 9 to install'; Tone = 'dim' }
    }
    if ($t.Running) { return @{ Text = 'running now'; Tone = 'run' } }
    if ($t.State -eq 'Disabled') { return @{ Text = 'task disabled'; Tone = 'warn' } }
    if (-not $t.NextRunAt) { return @{ Text = 'no next run set'; Tone = 'warn' } }
    $left = ([datetime]$t.NextRunAt) - (Get-Date)
    if ($left.TotalSeconds -le 0) { return @{ Text = 'due now'; Tone = 'run' } }
    $clock = '{0}:{1:00}:{2:00}' -f [int][math]::Floor($left.TotalHours), $left.Minutes, $left.Seconds
    $at = ([datetime]$t.NextRunAt).ToString('HH:mm')
    if (([datetime]$t.NextRunAt).Date -ne (Get-Date).Date) { $at = ([datetime]$t.NextRunAt).ToString('ddd HH:mm') }
    @{ Text = ('in {0}  at {1}' -f $clock, $at); Tone = 'ok' }
}

function Get-ServerShortName {
    # Which engine and server produced a column, in eleven characters or
    # fewer: results from different servers are not directly comparable.
    param($Tests, [int]$Index)
    $b = [string](Get-SpeedValue $Tests $Index 'backend')
    $srv = [string](Get-SpeedValue $Tests $Index 'server')
    if ($Index -ge @($Tests).Count) { return '' }
    $txt = $srv
    switch ($b) {
        'cloudflare' { $txt = 'Cloudflare' }
        'ookla'      { $txt = ($srv -split ' \(')[0]; if (-not $txt) { $txt = 'Ookla' } }
        'file'       { if (-not $txt) { $txt = 'file' } }
        default      { if (-not $txt) { $txt = $b } }
    }
    if ($txt.Length -gt 11) { $txt = $txt.Substring(0, 11) }
    $txt
}

function Draw-SpeedSummary {
    # The last speed tests beside the interface table: rates, then latency at
    # rest and under load in each direction, then the countdown to the next.
    param($Screen, [int]$X, [int]$Y, [int]$W, [int]$H, [int]$Count = 3)
    $Pal = $script:Col
    for ($r = 0; $r -lt $H; $r++) { Set-Cell $Screen ($X - 2) ($Y + $r) ([char]$script:Gfx.V) $Pal.PanelDim }

    $tests = @($script:Live.Speed)
    if ($tests.Count -lt 1) {
        Write-Buf $Screen $X $Y 'Speed test' $Pal.Magenta
        Write-Buf $Screen $X ($Y + 2) 'no results yet' $Pal.Faint -2 $W
        Write-Buf $Screen $X ($Y + 3) '9 > Run a speed test' $Pal.Faint -2 $W
    } else {
        $today = (Get-Date).Date
        $cols = @(@{ Name = 'Speed test'; Width = 10 })
        for ($i = 0; $i -lt $Count; $i++) {
            $hd = '-'
            if ($i -lt $tests.Count) {
                $when = $tests[$i].When
                if ($when.Date -eq $today) { $hd = $when.ToString('HH:mm') } else { $hd = $when.ToString('ddd HH:mm') }
            }
            $cols += @{ Name = $hd.PadLeft(11); Width = 11; Align = 'R' }
        }

        $spec = @(
            @{ Label = 'Download'; Field = 'down_mbps'; Kind = 'rate'; Fg = $Pal.Green },
            @{ Label = 'Upload';   Field = 'up_mbps';   Kind = 'rate'; Fg = $Pal.Cyan },
            @{ Label = 'ID-Latency'; Field = 'latency_ms'; Kind = 'idle' },
            @{ Label = 'DL-Latency'; Field = 'latency_down_ms'; Kind = 'load' },
            @{ Label = 'UL-Latency'; Field = 'latency_up_ms'; Kind = 'load' },
            @{ Label = 'Server';     Field = 'server'; Kind = 'server' }
        )
        $rows = @()
        foreach ($sp in $spec) {
            $cells = @(@{ Text = $sp.Label; Fg = $Pal.Dim })
            for ($i = 0; $i -lt $Count; $i++) {
                $v = Get-SpeedValue $tests $i $sp.Field
                if ($sp.Kind -eq 'rate') {
                    $fg = $sp.Fg
                    if ($null -eq $v) { $fg = $Pal.Faint }
                    elseif ($i -gt 0) { $fg = $Pal.Dim }     # older tests recede
                    $cells += @{ Text = (Format-Mbps $v); Fg = $fg }
                } elseif ($sp.Kind -eq 'server') {
                    $cells += @{ Text = (Get-ServerShortName $tests $i); Fg = $Pal.Faint }
                } elseif ($sp.Kind -eq 'idle') {
                    $fg = $Pal.Text
                    if ($null -eq $v) { $fg = $Pal.Faint }
                    $cells += @{ Text = (Format-LatMs $v); Fg = $fg }
                } else {
                    $cells += @{ Text = (Format-LatMs $v); Fg = (Get-BloatTone $v (Get-SpeedValue $tests $i 'latency_ms')) }
                }
            }
            $rows += , $cells
        }
        $null = Draw-Table $Screen $X $Y $W 6 $cols $rows
    }

    # Countdown on the last row.
    if ($H -ge 8) {
        $ny = $Y + 7
        $nx = Get-NextSpeedTestText
        $fg = $Pal.Dim
        switch ($nx.Tone) { 'ok' { $fg = $Pal.Yellow } 'run' { $fg = $Pal.Green } 'warn' { $fg = $Pal.Warn } }
        Write-Buf $Screen $X $ny 'Next test' $Pal.Dim
        $txt = [string]$nx.Text
        if ($txt.Length -gt $W - 11) { $txt = $txt.Substring(0, $W - 11) }
        Write-Buf $Screen ($X + $W - $txt.Length) $ny $txt $fg
    }
}

function Get-GaugeColumns {
    # The seven columns, in the order they are drawn: the two local checks,
    # the three fixed internet targets, then the two custom slots.
    $hl = $script:Live.Health
    $snap = $script:Live.Snap
    $byAddr = @{}
    if ($hl) { foreach ($t in @($hl.Targets)) { $byAddr[[string]$t.Address] = $t } }

    $cols = New-Object 'System.Collections.Generic.List[object]'

    $gwAddr = ''
    if ($snap -and $snap.Route) { $gwAddr = [string]$snap.Route.Gateway }
    $gwVal = $null; $gwLoss = $null
    if ($hl -and $hl.Gw) { $gwVal = $hl.Gw.Avg; $gwLoss = $hl.Gw.Loss }
    $cols.Add([pscustomobject]@{
        Title = 'Gateway'; Sub = $(if ($gwAddr) { $gwAddr } else { 'no route' })
        Value = $gwVal; Loss = $gwLoss; History = $script:Live.GwHistory
        Kind = 'gw'; Unset = (-not $gwAddr); Failed = $false
    })

    # The resolver actually answering, which is often the router rather than
    # a public service - worth seeing, because that is what is being timed.
    $dnsSub = 'resolver'
    if ($snap -and $snap.DnsServers) {
        $srv = (([string]$snap.DnsServers) -split ',')[0].Trim()
        $dnsSub = $(if (('via ' + $srv).Length -le 17) { 'via ' + $srv } else { $srv })
    }
    $dnsVal = $null; $dnsFail = $false
    if ($hl) { $dnsVal = $hl.DnsMs; $dnsFail = (-not $hl.DnsOk) }
    $cols.Add([pscustomobject]@{
        Title = 'DNS Lookup'; Sub = $dnsSub
        Value = $dnsVal; Loss = $null; History = $script:Live.DnsHistory
        Kind = 'dns'; Unset = $false; Failed = $dnsFail
    })

    foreach ($slot in @($script:App.LiveTargets)) {
        $r = $null
        if ($byAddr.ContainsKey([string]$slot.Address)) { $r = $byAddr[[string]$slot.Address] }
        $h = $null
        if ($script:Live.TargetHistory.ContainsKey([string]$slot.Address)) { $h = $script:Live.TargetHistory[[string]$slot.Address] }
        $cols.Add([pscustomobject]@{
            Title = $slot.Address; Sub = $slot.Label
            Value = $(if ($r) { $r.Avg } else { $null })
            Loss = $(if ($r) { $r.Loss } else { $null })
            History = $h; Kind = 'wan'; Unset = $false
            Failed = ($r -and $null -eq $r.Avg)
        })
    }

    $n = 1
    foreach ($slot in @($script:App.CustomTargets)) {
        if (-not $slot.Address) {
            $cols.Add([pscustomobject]@{
                Title = ('Custom ' + $n); Sub = 'press c to set'
                Value = $null; Loss = $null; History = $null
                Kind = 'custom'; Unset = $true; Failed = $false
            })
        } else {
            $r = $null
            if ($byAddr.ContainsKey([string]$slot.Address)) { $r = $byAddr[[string]$slot.Address] }
            $h = $null
            if ($script:Live.TargetHistory.ContainsKey([string]$slot.Address)) { $h = $script:Live.TargetHistory[[string]$slot.Address] }
            $cols.Add([pscustomobject]@{
                Title = $slot.Address; Sub = $(if ($slot.Label) { $slot.Label } else { 'custom ' + $n })
                Value = $(if ($r) { $r.Avg } else { $null })
                Loss = $(if ($r) { $r.Loss } else { $null })
                History = $h; Kind = 'custom'; Unset = $false
                Failed = ($r -and $null -eq $r.Avg)
            })
        }
        $n++
    }
    # Averages over the configured window, from the collector's history.
    $avg = $null
    if ($script:Live.PingAvg) { $avg = $script:Live.PingAvg.ByKey }
    foreach ($c in $cols) {
        $k = [string]$c.Title
        if ($c.Kind -eq 'gw') { $k = 'gw' } elseif ($c.Kind -eq 'dns') { $k = 'dns' }
        $a = $null
        if ($avg -and -not $c.Unset -and $avg.ContainsKey($k)) { $a = $avg[$k] }
        Add-Member -InputObject $c -NotePropertyName Avg -NotePropertyValue $a -Force
        Add-Member -InputObject $c -NotePropertyName Lowest -NotePropertyValue $false -Force
    }
    # The lowest-latency internet provider: public and custom targets only -
    # the gateway and the DNS lookup are not providers.
    $best = $null
    foreach ($c in $cols) {
        # Needs a few samples, and fast-but-lossy does not win.
        if (($c.Kind -ne 'wan' -and $c.Kind -ne 'custom') -or -not $c.Avg) { continue }
        $lossOk = ($null -eq $c.Avg.Loss -or [double]$c.Avg.Loss -lt 5)
        if ($null -ne $c.Avg.Avg -and $c.Avg.N -ge 3 -and $lossOk) {
            if ($null -eq $best -or [double]$c.Avg.Avg -lt [double]$best.Avg.Avg) { $best = $c }
        }
    }
    if ($best) { $best.Lowest = $true }
    $cols.ToArray()
}

function Draw-HealthGauges {
    <#
      One column per check, each a vertical bar on a shared log scale with its
      exact value, loss and recent trend underneath. The shared scale is the
      point: a 0.6 ms gateway, a 17 ms DNS lookup and a 40 ms WAN hop can be
      compared at a glance, which no pair of per-column scales allows.
    #>
    param($Screen, [int]$X, [int]$Y, [int]$W, [int]$H)
    $Pal = $script:Col

    Draw-Box $Screen $X $Y $W $H 'Health'
    $inner = $H - 2
    if ($inner -lt 4) { return }

    $cols = @(Get-GaugeColumns)
    $bl = $null
    if ($script:App.State) { $bl = $script:App.State.Baseline }

    # Drop the extras before squashing the bars.
    $showSub = ($inner -ge 9)
    $showSpark = ($inner -ge 11)
    $showAvg = ($inner -ge 10)
    $fixed = 1 + 1 + 1 + 1                     # title, value, loss, footer
    if ($showSub) { $fixed++ }
    if ($showSpark) { $fixed++ }
    if ($showAvg) { $fixed++ }
    $winTxt = Format-Window ([int]$script:CurrentHealthWindow)
    $barH = $inner - $fixed
    if ($barH -lt 2) { $barH = 2 }

    # Shared axis on the left: one label per decade.
    $gutter = 7
    $top = $Y + 1 + 1 + $(if ($showSub) { 1 } else { 0 })
    # Each tick sits on the row where a bar of exactly that value would end,
    # so the labels line up with the bars rather than with a rounded guess.
    $usedRows = @{}
    foreach ($tick in @(@(1000.0, '1s'), @(100.0, '100ms'), @(10.0, '10ms'), @(1.0, '1ms'))) {
        $f = Get-LogFraction $tick[0]
        $fromBottom = [int][math]::Ceiling($f * $barH) - 1
        if ($fromBottom -lt 0) { $fromBottom = 0 }
        $row = $top + $barH - 1 - $fromBottom
        if ($row -lt $top -or $row -ge $top + $barH -or $usedRows.ContainsKey($row)) { continue }
        $usedRows[$row] = $true
        Write-Buf $Screen ($X + 1) $row ([string]$tick[1]).PadLeft($gutter - 1) $Pal.Faint
    }

    $colW = [int][math]::Floor(($W - $gutter - 2) / [math]::Max(1, $cols.Count))
    $barW = [math]::Max(2, [math]::Min(7, [int]($colW / 3)))

    for ($i = 0; $i -lt $cols.Count; $i++) {
        $c = $cols[$i]
        $cx = $X + $gutter + $i * $colW
        $ry = $Y + 1

        $titleFg = $Pal.White
        if ($c.Unset) { $titleFg = $Pal.Faint }
        $title = [string]$c.Title
        if ($c.Lowest) { $title = $script:Gfx.Star + ' ' + $title; $titleFg = $Pal.Ok }
        Write-Centered $Screen $cx $ry $colW $title $titleFg
        $ry++
        if ($showSub) {
            Write-Centered $Screen $cx $ry $colW ([string]$c.Sub) $Pal.Faint
            $ry++
        }

        # Tone: loss outranks latency, a failure outranks both.
        $tone = $Pal.Faint
        if ($c.Failed) { $tone = $Pal.Bad }
        elseif ($null -ne $c.Value) {
            if ($c.Kind -eq 'dns') { $tone = Get-LatencyTone $c.Value 30 }
            elseif ($c.Kind -eq 'gw') { $tone = Get-LatencyTone $c.Value 1 }
            else { $tone = Get-LatencyTone $c.Value $bl }
            if ($null -ne $c.Loss -and $c.Loss -gt 0) { $tone = Get-LossTone $c.Loss }
        }

        $frac = 0.0
        if ($null -ne $c.Value) {
            $frac = Get-LogFraction $c.Value
            # Anything measured gets at least a sliver, so "under a
            # millisecond" never looks like "no data".
            $minFrac = 1.0 / ($barH * 8)
            if ($frac -lt $minFrac) { $frac = $minFrac }
        }
        $bx = $cx + [int][math]::Floor(($colW - $barW) / 2)
        Draw-VerticalBar $Screen $bx $ry $barW $barH $frac $tone $Pal.PanelDim
        $ry += $barH

        # Exact value under the bar.
        $valTxt = '-'
        if ($c.Unset) { $valTxt = 'unset' }
        elseif ($c.Failed -and $c.Kind -eq 'dns') { $valTxt = 'FAILED' }
        elseif ($c.Failed) { $valTxt = 'no reply' }
        elseif ($null -ne $c.Value) {
            if ([double]$c.Value -lt 1) { $valTxt = '<1 ms' } else { $valTxt = Format-Ms $c.Value }
        }
        Write-Centered $Screen $cx $ry $colW $valTxt $(if ($c.Unset) { $Pal.Faint } else { $tone })
        $ry++

        $lossTxt = ''
        $lossFg = $Pal.Faint
        if ($c.Kind -eq 'dns') {
            if ($null -ne $c.Value) { $lossTxt = $(if ($c.Failed) { 'no answer' } else { 'answered' }) }
        } elseif ($null -ne $c.Loss) {
            $lossTxt = ('{0}% loss' -f $c.Loss)
            $lossFg = Get-LossTone $c.Loss
            if ($c.Loss -le 0) { $lossFg = $Pal.Dim }
        }
        Write-Centered $Screen $cx $ry $colW $lossTxt $lossFg
        $ry++

        # Average over the configured window, from the recorded history.
        if ($showAvg) {
            $avgTxt = ''
            $avgFg = $Pal.Dim
            if (-not $c.Unset) {
                if ($c.Avg -and $null -ne $c.Avg.Avg) {
                    $v = [double]$c.Avg.Avg
                    if ($v -lt 1) { $avgTxt = 'avg <1 ms' } else { $avgTxt = 'avg ' + (Format-Ms $v) }
                    if ($c.Lowest) {
                        $avgFg = $Pal.Ok
                        if (($avgTxt + ' lowest').Length -le $colW - 1) { $avgTxt += ' lowest' }
                    }
                } elseif ($script:Live.PingAvg) {
                    $avgTxt = 'avg -'
                    $avgFg = $Pal.Faint
                }
            }
            Write-Centered $Screen $cx $ry $colW $avgTxt $avgFg
            $ry++
        }

        if ($showSpark) {
            $hist = $c.History
            if ($hist -and @($hist).Count -gt 1) {
                $sparkW = [math]::Max(4, $colW - 3)
                $shaped = Get-LatencyTones -Values $hist -Baseline $(if ($c.Kind -eq 'dns') { 30 } elseif ($c.Kind -eq 'gw') { 1 } else { $bl }) -Keep ($sparkW * 2)
                Draw-Sparkline $Screen ($cx + 1) $ry $shaped.Values $sparkW -1 $shaped.Tones
            }
            $ry++
        }
    }

    # Footer: interface counters and capture, which have no column of their own.
    $fy = $Y + $H - 2
    $snap = $script:Live.Snap
    $errs = 0.0; $drops = 0.0
    if ($snap) {
        foreach ($a in @($snap.Adapters)) {
            $errs += [double]$a.RxErr + [double]$a.TxErr
            $drops += [double]$a.RxDisc + [double]$a.TxDisc
        }
    }
    $eTxt = 'adapter errors {0}   discards {1}' -f [long]$errs, [long]$drops
    Write-Buf $Screen ($X + 2) $fy $eTxt $(if ($errs + $drops -gt 0) { $Pal.Yellow } else { $Pal.Faint })
    $pk = 'capture off'
    if ($script:Pkt -and $script:Pkt.Running) { $pk = ('capture {0} pkts, {1} drops' -f $script:Pkt.Total, $script:Pkt.Drops) }
    elseif ($script:Pkt -and $script:Pkt.Note) { $pk = 'capture: ' + $script:Pkt.Note }
    Write-Centered $Screen ($X + 40) $fy ($W - 80) $pk $Pal.Faint
    $hint = 'avg = last ' + $winTxt + '   log scale   c: set custom'
    if (-not $script:Live.PingAvg) { $hint = 'averages loading...   log scale   c: set custom' }
    elseif ($script:Live.PingAvg.Rows -lt 1) { $hint = 'no history in the last ' + $winTxt + ' (collector running?)' }
    Write-Buf $Screen ($X + $W - $hint.Length - 2) $fy $hint $Pal.Faint
}

#endregion
#region ---- Tab 2: Connections ---------------------------------------------------

function Get-ConnectionRows {
    if (-not $script:Live.Snap) { return @() }
    $all = @($script:Live.Snap.Tcp) + @($script:Live.Snap.Udp)
    if ($script:App.Filter) {
        $f = $script:App.Filter.ToLowerInvariant()
        $all = @($all | Where-Object {
            $_.Proc.ToLowerInvariant().Contains($f) -or $_.Remote.ToLowerInvariant().Contains($f) -or
            $_.Local.ToLowerInvariant().Contains($f) -or $_.State.ToLowerInvariant().Contains($f)
        })
    }
    switch ($script:App.Sort) {
        'proc'   { $all = @($all | Sort-Object Proc, RemoteIp) }
        'state'  { $all = @($all | Sort-Object State, Proc) }
        'remote' { $all = @($all | Sort-Object RemoteIp, RemotePort) }
        'port'   { $all = @($all | Sort-Object RemotePort, Proc) }
        default  { $all = @($all | Sort-Object Proc, RemoteIp) }
    }
    $all
}

function Resolve-ConnectionSelection {
    # Index of the selected connection in the current list; re-found by key
    # after every refresh, clamped when the connection has gone.
    param($Rows)
    $A = $script:App
    $list = @($Rows)
    if ($list.Count -lt 1) { $A.ConnSel = 0; return 0 }
    if ($A.ConnKey) {
        for ($i = 0; $i -lt $list.Count; $i++) {
            if ((Get-ConnectionKey $list[$i]) -eq $A.ConnKey) { $A.ConnSel = $i; return $i }
        }
    }
    $i = [math]::Max(0, [math]::Min([int]$A.ConnSel, $list.Count - 1))
    $A.ConnSel = $i
    $A.ConnKey = Get-ConnectionKey $list[$i]
    $i
}

function Draw-TabConnections {
    param($Screen, [int]$X, [int]$Y, [int]$W, [int]$H)
    $Pal = $script:Col
    $rows = @(Get-ConnectionRows)
    $title = 'Connections  ({0} sockets, sorted by {1}{2})' -f $rows.Count, $script:App.Sort,
             $(if ($script:App.Filter) { ", filter '" + $script:App.Filter + "'" } else { '' })
    Draw-Box $Screen $X $Y $W $H $title

    if ($rows.Count -lt 1) {
        Draw-Empty $Screen $X ($Y + 2) $W 'no sockets match'
        return
    }

    # The selection follows its connection, not its row number: the list is
    # re-read every 1.5 s and re-sorted, and a highlighted row that silently
    # became a different connection would make x dangerous.
    $A = $script:App
    $visible = $H - 4
    $sel = Resolve-ConnectionSelection $rows
    $maxScroll = [math]::Max(0, $rows.Count - $visible)
    $start = $A.Scroll[1]
    if ($sel -lt $start) { $start = $sel }
    if ($sel -ge $start + $visible) { $start = $sel - $visible + 1 }
    if ($start -gt $maxScroll) { $start = $maxScroll }
    if ($start -lt 0) { $start = 0 }
    $A.Scroll[1] = $start
    $slice = @($rows[$start..([math]::Min($rows.Count - 1, $start + $visible - 1))])

    $cols = @(
        @{ Name = 'Process'; Width = 22 }, @{ Name = 'PID'; Width = 7; Align = 'R' },
        @{ Name = 'Proto'; Width = 6 }, @{ Name = 'State'; Width = 13 },
        @{ Name = 'Local'; Width = 24 }, @{ Name = 'Remote'; Width = 40 }
    )
    $tbl = @()
    foreach ($c in $slice) {
        $stCol = switch -Wildcard ($c.State) {
            'Established' { $Pal.Green } 'Listen*' { $Pal.Dim } 'TimeWait' { $Pal.Faint }
            'CloseWait'   { $Pal.Yellow } 'SynSent' { $Pal.Yellow } default { $Pal.Text }
        }
        $tbl += , @(
            @{ Text = $c.Proc; Fg = $Pal.White }
            @{ Text = [string]$c.ProcId; Fg = $Pal.Faint }
            @{ Text = $c.Proto; Fg = $(if ($c.Proto -eq 'UDP') { $Pal.Purple } else { $Pal.Dim }) }
            @{ Text = $c.State.ToUpperInvariant(); Fg = $stCol }
            @{ Text = $c.Local; Fg = $Pal.Dim }
            @{ Text = $c.Remote; Fg = $Pal.Cyan }
        )
    }
    $null = Draw-Table $Screen ($X + 2) ($Y + 1) ($W - 4) $visible $cols $tbl -Selected ($sel - $start)

    $info = '{0} of {1}   up/down select   x close connection / end process' -f ($sel + 1), $rows.Count
    if ($info.Length -gt $W - 6) { $info = '{0}/{1}  x: close' -f ($sel + 1), $rows.Count }
    Write-Buf $Screen ($X + $W - $info.Length - 3) ($Y + $H - 1) (' ' + $info + ' ') $Pal.Faint
}

#endregion
#region ---- Tab 3: Interfaces ----------------------------------------------------

function Draw-TabInterfaces {
    param($Screen, [int]$X, [int]$Y, [int]$W, [int]$H)
    $Pal = $script:Col
    Draw-Box $Screen $X $Y $W $H 'Interfaces'
    if (-not $script:Live.Snap) { Draw-Empty $Screen $X ($Y + 2) $W 'sampling...'; return }

    $adapters = @($script:Live.Snap.Adapters | Sort-Object @{ Expression = { $_.Status -eq 'Up' }; Descending = $true }, Name)
    $cy = $Y + 1
    $route = $script:Live.Snap.Route

    foreach ($a in $adapters) {
        if ($cy + 4 -gt $Y + $H - 1) { break }
        $isPrimary = ($route -and $route.IfAlias -eq $a.Name)
        $nameCol = $(if ($a.Status -eq 'Up') { $Pal.White } else { $Pal.Faint })

        Write-Buf $Screen ($X + 2) $cy $script:Gfx.Dot $(if ($a.Status -eq 'Up') { $Pal.Ok } else { $Pal.Off })
        Write-Buf $Screen ($X + 4) $cy $a.Name $nameCol -2 22
        Write-Buf $Screen ($X + 26) $cy $a.Desc $Pal.Dim -2 34
        if ($isPrimary) { Write-Buf $Screen ($X + 62) $cy '[default route]' $Pal.Yellow }
        Write-Buf $Screen ($X + $W - 12) $cy (Format-LinkStatus $a.Status) $(if ($a.Status -eq 'Up') { $Pal.Ok } else { $Pal.Off })

        $cy++
        $detail = 'ip {0}   mac {1}   link {2}   media {3}' -f
                  $(if ($a.Ip) { $a.Ip } else { '-' }), $(if ($a.Mac) { $a.Mac } else { '-' }),
                  $(if ($a.LinkSpeed) { $a.LinkSpeed } else { '-' }), $(if ($a.Media) { $a.Media } else { '-' })
        Write-Buf $Screen ($X + 4) $cy $detail $Pal.Dim -2 ($W - 8)

        $cy++
        $rates = 'rx {0}  ({1})    tx {2}  ({3})    errors {4}/{5}    discards {6}/{7}' -f
                 (Format-Rate $a.RxRate), (Format-Bytes $a.Rx),
                 (Format-Rate $a.TxRate), (Format-Bytes $a.Tx),
                 [long]$a.RxErr, [long]$a.TxErr, [long]$a.RxDisc, [long]$a.TxDisc
        $errCol = $(if (([double]$a.RxErr + [double]$a.TxErr + [double]$a.RxDisc + [double]$a.TxDisc) -gt 0) { $Pal.Yellow } else { $Pal.Text })
        Write-Buf $Screen ($X + 4) $cy $rates $errCol -2 ($W - 8)

        $cy += 2
    }

    if ($route) {
        if ($cy + 2 -le $Y + $H - 1) {
            Write-Buf $Screen ($X + 2) $cy ($script:Gfx.H * ($W - 4)) $Pal.Faint
            $cy++
            $txt = 'default route via {0} on {1}   local {2}   dns {3}' -f
                   $route.Gateway, $route.IfAlias, $route.LocalIp, $script:Live.Snap.DnsServers
            Write-Buf $Screen ($X + 2) $cy $txt $Pal.Cyan -2 ($W - 4)
        }
    }
}

#endregion
#region ---- Tab 4: Packets -------------------------------------------------------

function Draw-TabPackets {
    param($Screen, [int]$X, [int]$Y, [int]$W, [int]$H)
    $Pal = $script:Col
    Draw-Box $Screen $X $Y $W $H 'Packet capture (pktmon)'

    $p = $script:Pkt
    if (-not $p) { Draw-Empty $Screen $X ($Y + 2) $W 'capture not initialised'; return }

    if (-not $p.Elevated) {
        Write-Buf $Screen ($X + 3) ($Y + 2) 'Packet capture requires administrator.' $Pal.Yellow
        Write-Buf $Screen ($X + 3) ($Y + 4) 'pktmon can attach to the network stack only when elevated. Close this and run:' $Pal.Dim
        Write-Buf $Screen ($X + 3) ($Y + 6) ('  Start-Process powershell -Verb RunAs -ArgumentList ''-File "{0}"''' -f $script:ScriptPath) $Pal.Cyan
        Write-Buf $Screen ($X + 3) ($Y + 8) 'Everything else in this dashboard works without elevation.' $Pal.Faint
        return
    }

    $cy = $Y + 1
    $up = ''
    if ($p.Started) { $up = ' for ' + (Format-Duration ([DateTimeOffset]::Now - $p.Started).TotalSeconds) }
    Write-Buf $Screen ($X + 2) $cy ('status  ' + $(if ($p.Running) { 'capturing' + $up } else { 'stopped' })) `
        $(if ($p.Running) { $Pal.Ok } else { $Pal.Off })
    if ($p.Note) { Write-Buf $Screen ($X + 34) $cy $p.Note $Pal.Dim -2 ($W - 38) }
    $cy += 2

    $stats = @(
        @('packets', $p.Total, $Pal.White), @('drops', $p.Drops, $(if ($p.Drops -gt 0) { $Pal.Bad } else { $Pal.Dim })),
        @('in', $p.RxCount, $Pal.Green), @('out', $p.TxCount, $Pal.Cyan),
        @('parsed', $p.Parsed, $Pal.Dim), @('unrecognised', $p.Unparsed, $(if ($p.Unparsed -gt 0) { $Pal.Yellow } else { $Pal.Dim }))
    )
    $cx = $X + 2
    foreach ($s in $stats) {
        Write-Buf $Screen $cx $cy ([string]$s[0]) $Pal.Faint
        Write-Buf $Screen $cx ($cy + 1) ([string]$s[1]) $s[2]
        $cx += [math]::Max(14, ([string]$s[0]).Length + 3)
    }
    $cy += 3

    $chartH = [math]::Min(7, [math]::Max(3, [int](($Y + $H - $cy - 12))))
    if ($chartH -ge 3 -and @($p.PerSecond).Count -gt 0) {
        Write-Buf $Screen ($X + 2) $cy 'packets per second' $Pal.Faint
        Draw-Chart $Screen ($X + 2) ($cy + 1) ($W - 6) $chartH $p.PerSecond $Pal.Blue
        $cy += $chartH + 2
    }

    $left = ($Y + $H) - $cy - 1
    if ($left -ge 4) {
        $protoH = [math]::Min(7, $left)
        Write-Buf $Screen ($X + 2) $cy 'by protocol and drop reason' $Pal.Faint
        $keys = @($p.Protocols.Keys | Sort-Object { -$p.Protocols[$_] })
        $n = 0
        foreach ($k in $keys) {
            if ($n -ge $protoH - 2) { break }
            $col = $(if ($k -like 'drop:*') { $Pal.Bad } else { $Pal.Text })
            Write-Buf $Screen ($X + 4) ($cy + 1 + $n) ([string]$k).PadRight(24) $col
            Write-Buf $Screen ($X + 28) ($cy + 1 + $n) ([string]$p.Protocols[$k]) $Pal.Dim
            $n++
        }
        if ($keys.Count -lt 1) { Write-Buf $Screen ($X + 4) ($cy + 1) 'nothing classified yet' $Pal.Faint }
        $cy += $protoH
    }

    # Raw tail. If the parser does not understand this build's format, this is
    # what tells us why - far better than a screen of confident zeroes.
    $left = ($Y + $H) - $cy - 1
    if ($left -ge 3) {
        Write-Buf $Screen ($X + 2) $cy 'raw output (newest last)' $Pal.Faint
        $lines = @($p.Lines)
        $show = [math]::Min($left - 1, 8)
        if ($lines.Count -gt $show) { $lines = $lines[($lines.Count - $show)..($lines.Count - 1)] }
        for ($i = 0; $i -lt $lines.Count; $i++) {
            Write-Buf $Screen ($X + 4) ($cy + 1 + $i) $lines[$i] $Pal.Faint -2 ($W - 8)
        }
    }
}

#endregion
#region ---- Tab 5: Stats ---------------------------------------------------------

function Draw-TabStats {
    param($Screen, [int]$X, [int]$Y, [int]$W, [int]$H)
    $Pal = $script:Col
    Draw-Box $Screen $X $Y $W $H 'Statistics from the logged history'

    $rows = @($script:Live.Hist)
    if ($rows.Count -lt 1) {
        Write-Buf $Screen ($X + 3) ($Y + 2) 'No probe rows yet.' $Pal.Yellow
        Write-Buf $Screen ($X + 3) ($Y + 4) 'This tab reads what the background collector writes, not the live samples above.' $Pal.Dim
        Write-Buf $Screen ($X + 3) ($Y + 5) ('Install the scheduled tasks:  {0} -Mode Install' -f $script:ScriptName) $Pal.Cyan
        return
    }

    $lat = New-Object 'System.Collections.Generic.List[double]'
    $healthy = 0; $layerFail = @{}
    foreach ($r in $rows) {
        $m = Get-RowMetrics -Row $r
        if ($null -ne $m['LatencyMs']) { $lat.Add([double]$m['LatencyMs']) }
        $fl = [string](Get-Field $r 'failed_layers')
        if (-not $fl) { $healthy++ }
        else { foreach ($l in $fl.Split(';')) { if ($l) { $layerFail[$l] = 1 + $(if ($layerFail.ContainsKey($l)) { $layerFail[$l] } else { 0 }) } } }
    }
    $sorted = @($lat | Sort-Object)
    function Pct { param($Sample, [double]$P) if ($Sample.Count -lt 1) { return $null }; $Sample[[int][math]::Floor(($Sample.Count - 1) * $P)] }

    $cy = $Y + 1
    $uptime = [math]::Round(100.0 * $healthy / $rows.Count, 3)
    $cards = @(
        @('cycles', [string]$rows.Count, $Pal.White),
        @('availability', ('{0}%' -f $uptime), $(if ($uptime -ge 99.9) { $Pal.Ok } elseif ($uptime -ge 99) { $Pal.Warn } else { $Pal.Bad })),
        @('median', (Format-Ms (Pct $sorted 0.5)), $Pal.Green),
        @('p95', (Format-Ms (Pct $sorted 0.95)), $Pal.Yellow),
        @('p99', (Format-Ms (Pct $sorted 0.99)), $Pal.Orange),
        @('peak', (Format-Ms $(if ($sorted.Count -gt 0) { $sorted[$sorted.Count - 1] } else { $null })), $Pal.Bad)
    )
    $cx = $X + 2
    foreach ($c in $cards) {
        Write-Buf $Screen $cx $cy ([string]$c[0]) $Pal.Faint
        Write-Buf $Screen $cx ($cy + 1) ([string]$c[1]) $c[2]
        $cx += 16
    }
    $cy += 3

    # Latency over the loaded window, bucketed so it fits the width.
    $avail = ($Y + $H) - $cy - 2
    if ($avail -ge 6) {
        $chartH = [math]::Min(9, $avail - 4)
        $to = [DateTimeOffset]::Now
        $from = $to.AddHours(-24)
        $width = $W - 12
        $bs = [int][math]::Ceiling(86400.0 / [math]::Max(10, $width))
        $series = @(Get-SeriesFromRows -Rows $rows -BucketSeconds $bs -From $from -To $to)

        $bl = $null
        if ($script:App.State) { $bl = $script:App.State.Baseline }
        $peak = @($series | ForEach-Object { $_.Max })
        $shaped = Get-LatencyTones -Values $peak -Baseline $bl
        $peak = $shaped.Values
        $tones = $shaped.Tones

        Write-Buf $Screen ($X + 2) $cy 'latency, last 24 hours (bar height is the bucket peak, colour is severity)' $Pal.Faint
        Draw-Chart $Screen ($X + 8) ($cy + 1) $width $chartH $peak $Pal.Blue $tones
        $topv = 0.0
        foreach ($v in $peak) { if ($null -ne $v -and $v -gt $topv) { $topv = [double]$v } }
        Write-Buf $Screen ($X + 2) ($cy + 1) ('{0,5:0}' -f $topv) $Pal.Faint
        Write-Buf $Screen ($X + 2) ($cy + $chartH) '    0' $Pal.Faint
        $cy += $chartH + 2

        $lossVals = @($series | ForEach-Object { $_.Loss })
        $anyLoss = $false
        foreach ($v in $lossVals) { if ($null -ne $v -and $v -gt 0) { $anyLoss = $true } }
        if (($Y + $H) - $cy -ge 3) {
            Write-Buf $Screen ($X + 2) $cy 'loss' $Pal.Faint
            if ($anyLoss) {
                $lt = @()
                foreach ($v in $lossVals) { $lt += (Get-LossTone $v) }
                Draw-Sparkline $Screen ($X + 8) $cy $lossVals $width -1 $lt
            } else {
                Write-Buf $Screen ($X + 8) $cy 'none recorded in this window' $Pal.Ok
            }
            $cy++
        }
    }

    if (($Y + $H) - $cy -ge 2 -and $layerFail.Count -gt 0) {
        $txt = 'failed layers: ' + (@($layerFail.Keys | Sort-Object | ForEach-Object { '{0} x{1}' -f $_, $layerFail[$_] }) -join '   ')
        Write-Buf $Screen ($X + 2) $cy $txt $Pal.Yellow -2 ($W - 4)
        $cy += 2
    }

    # Availability by hour and weekday. This is usually the chart that finds
    # the pattern - every weekday at 5pm, or always at 3am.
    if (($Y + $H) - $cy -ge 11) {
        # Only the last 24h is held in memory: loading 30 days of minute data
        # would stall a live view for the better part of a minute. The full
        # 30-day version of this grid is in the HTML report.
        Write-Buf $Screen ($X + 2) $cy 'availability by hour and weekday (last 24 hours; press R for the 30 day version)' $Pal.Faint
        $cy++
        Write-Buf $Screen ($X + 7) $cy (Get-HourRuler) $Pal.Faint
        $cy++
        $grid = Get-AvailabilityGrid
        Draw-Heatmap $Screen ($X + 2) $cy $grid @('Mon','Tue','Wed','Thu','Fri','Sat','Sun') 5
        $cy += 7
        if (($Y + $H) - $cy -ge 2) {
            $cx = $X + 2
            Write-Buf $Screen $cx ($cy + 1) 'worse' $Pal.Faint
            $cx += 6
            foreach ($sw in @(124, 167, 179, 143, 65, 29)) {
                Write-Buf $Screen $cx ($cy + 1) '  ' $Pal.Text $sw
                $cx += 3
            }
            Write-Buf $Screen $cx ($cy + 1) 'better        blank = no data' $Pal.Faint
        }
    }
}

function Get-HourRuler {
    $sb = New-Object System.Text.StringBuilder
    for ($hh = 0; $hh -lt 24; $hh++) {
        if ($hh % 2 -eq 0) { [void]$sb.Append(('{0:00}' -f $hh)) } else { [void]$sb.Append('  ') }
    }
    $sb.ToString()
}

function Get-AvailabilityGrid {
    # Share of cycles with no failed layer, by local hour and weekday.
    $up = New-Object 'int[][]' 7
    $all = New-Object 'int[][]' 7
    for ($d = 0; $d -lt 7; $d++) { $up[$d] = New-Object 'int[]' 24; $all[$d] = New-Object 'int[]' 24 }
    foreach ($r in @($script:Live.Hist)) {
        $ts = ConvertFrom-Timestamp ([string](Get-Field $r 'timestamp'))
        if (-not $ts) { continue }
        $lt2 = $ts.DateTime
        $dw = (([int]$lt2.DayOfWeek) + 6) % 7
        $all[$dw][$lt2.Hour]++
        if (-not [string](Get-Field $r 'failed_layers')) { $up[$dw][$lt2.Hour]++ }
    }
    $grid = New-Object 'object[]' 7
    for ($d = 0; $d -lt 7; $d++) {
        $row = New-Object 'object[]' 24
        for ($hh = 0; $hh -lt 24; $hh++) {
            if ($all[$d][$hh] -gt 0) { $row[$hh] = [math]::Round(100.0 * $up[$d][$hh] / $all[$d][$hh], 2) }
            else { $row[$hh] = $null }
        }
        $grid[$d] = $row
    }
    $grid
}

#endregion
#region ---- Tab 6: Topology ------------------------------------------------------

function Draw-TabTopology {
    param($Screen, [int]$X, [int]$Y, [int]$W, [int]$H)
    $Pal = $script:Col
    Draw-Box $Screen $X $Y $W $H 'Path to the internet'

    $tr = $script:Live.Trace
    if (-not $tr) {
        Write-Buf $Screen ($X + 3) ($Y + 2) 'tracing the path...' $Pal.Dim
        Write-Buf $Screen ($X + 3) ($Y + 4) 'A hop that does not answer is not a fault: many routers rate-limit or drop' $Pal.Faint
        Write-Buf $Screen ($X + 3) ($Y + 5) 'TTL-expired ICMP. Only the final target being unreachable matters.' $Pal.Faint
        return
    }

    $hops = @($tr.Hops)
    $maxMs = 1.0
    foreach ($hop in $hops) { if ($null -ne $hop.Ms -and $hop.Ms -gt $maxMs) { $maxMs = [double]$hop.Ms } }

    $cy = $Y + 1
    Write-Buf $Screen ($X + 2) $cy ('to {0}   {1} hops   updated {2}' -f $tr.Target, $hops.Count,
        $tr.Time.ToString('HH:mm:ss')) $Pal.Dim
    $cy += 2

    $snap = $script:Live.Snap
    $localIp = ''
    if ($snap -and $snap.Route) { $localIp = $snap.Route.LocalIp }
    Write-Buf $Screen ($X + 4) $cy ('this machine  ' + $localIp) $Pal.White
    $cy++

    $bl = $null
    if ($script:App.State) { $bl = $script:App.State.Baseline }

    foreach ($hop in $hops) {
        if ($cy + 1 -gt $Y + $H - 1) { break }
        Write-Buf $Screen ($X + 5) $cy ([string][char]0x2502) $Pal.Faint
        $cy++
        if ($cy + 1 -gt $Y + $H - 1) { break }

        $label = '{0,2}. {1}' -f $hop.Ttl, $(if ($hop.Address) { $hop.Address } else { '* no reply' })
        $lblCol = $Pal.Text
        if (-not $hop.Address) { $lblCol = $Pal.Faint }
        elseif ($hop.Ttl -eq 1) { $lblCol = $Pal.Cyan }
        elseif ($hop.Final) { $lblCol = $Pal.Green }
        Write-Buf $Screen ($X + 4) $cy $label $lblCol -2 30

        $tag = ''
        if ($hop.Ttl -eq 1) { $tag = 'gateway' }
        elseif ($hop.Ttl -eq 2) { $tag = 'ISP edge' }
        elseif ($hop.Final) { $tag = 'target' }
        if ($tag) { Write-Buf $Screen ($X + 35) $cy $tag $Pal.Faint }

        if ($null -ne $hop.Ms) {
            $tone = Get-LatencyTone $hop.Ms $bl
            Write-Buf $Screen ($X + 46) $cy ((Format-Ms $hop.Ms).PadLeft(9)) $tone
            $barW = [math]::Max(6, $W - 70)
            Draw-MeterBar $Screen ($X + 57) $cy $barW ([double]$hop.Ms / $maxMs) $tone
        }
        if ($hop.Loss -gt 0) {
            Write-Buf $Screen ($X + $W - 11) $cy ('{0}% loss' -f $hop.Loss) (Get-LossTone $hop.Loss)
        }
        $cy++
    }

    if ($cy + 2 -le $Y + $H - 1) {
        Write-Buf $Screen ($X + 2) ($cy + 1) 'Hop 2 is normally the ISP edge: that is the number that carries weight in an ISP call.' $Pal.Faint -2 ($W - 4)
    }
}

#endregion
#region ---- Tab 7: Timeline ------------------------------------------------------

function Draw-TabTimeline {
    param($Screen, [int]$X, [int]$Y, [int]$W, [int]$H)
    $Pal = $script:Col
    Draw-Box $Screen $X $Y $W $H 'Timeline - state changes and outages'

    $evs = @($script:Live.Events)
    if ($evs.Count -lt 1) {
        Write-Buf $Screen ($X + 3) ($Y + 2) 'No state changes recorded.' $Pal.Dim
        Write-Buf $Screen ($X + 3) ($Y + 4) 'That is either good news, or the collector has not run yet.' $Pal.Faint
        return
    }

    $visible = $H - 4
    $ordered = @($evs)
    [array]::Reverse($ordered)
    $maxScroll = [math]::Max(0, $ordered.Count - $visible)
    if ($script:App.Scroll[6] -gt $maxScroll) { $script:App.Scroll[6] = $maxScroll }
    $start = $script:App.Scroll[6]
    $slice = @($ordered[$start..([math]::Min($ordered.Count - 1, $start + $visible - 1))])

    $cols = @(
        @{ Name = 'When'; Width = 19 }, @{ Name = 'Change'; Width = 22 },
        @{ Name = 'Lasted'; Width = 12; Align = 'R' }, @{ Name = 'Why'; Width = 40 },
        @{ Name = 'Diagnostics'; Width = 26 }
    )
    $tbl = @()
    foreach ($e in $slice) {
        $ts = ConvertFrom-Timestamp ([string](Get-Field $e 'timestamp'))
        $from = [string](Get-Field $e 'from_state')
        $to = [string](Get-Field $e 'to_state')
        $toCol = switch ($to) { 'Up' { $Pal.Ok } 'Degraded' { $Pal.Warn } 'Down' { $Pal.Bad } default { $Pal.Text } }
        $chg = $(if ($from) { '{0} {1} {2}' -f $from, $script:Gfx.Arrow, $to } else { 'start: ' + $to })
        $tbl += , @(
            @{ Text = $(if ($ts) { $ts.ToString('yyyy-MM-dd HH:mm') } else { '?' }); Fg = $Pal.Dim }
            @{ Text = $chg; Fg = $toCol }
            @{ Text = [string](Get-Field $e 'prev_duration'); Fg = $Pal.Dim }
            @{ Text = [string](Get-Field $e 'reason'); Fg = $Pal.Text }
            @{ Text = [string](Get-Field $e 'diag_file'); Fg = $Pal.Cyan }
        )
    }
    $null = Draw-Table $Screen ($X + 2) ($Y + 1) ($W - 4) $visible $cols $tbl

    $downs = @($evs | Where-Object { [string](Get-Field $_ 'to_state') -eq 'Down' }).Count
    $info = '{0} events, {1} outages' -f $evs.Count, $downs
    if ($maxScroll -gt 0) { $info += '   {0}-{1}   up/down to scroll' -f ($start + 1), ($start + $slice.Count) }
    Write-Buf $Screen ($X + $W - $info.Length - 3) ($Y + $H - 1) (' ' + $info + ' ') $Pal.Faint
}

#endregion
#region ---- Tab 8: Processes -----------------------------------------------------

function Draw-TabProcesses {
    param($Screen, [int]$X, [int]$Y, [int]$W, [int]$H)
    $Pal = $script:Col
    Draw-Box $Screen $X $Y $W $H 'Processes using the network'

    $procs = @(Get-ProcessSummary)
    if ($procs.Count -lt 1) { Draw-Empty $Screen $X ($Y + 2) $W 'sampling...'; return }

    $visible = $H - 5
    $maxScroll = [math]::Max(0, $procs.Count - $visible)
    if ($script:App.Scroll[7] -gt $maxScroll) { $script:App.Scroll[7] = $maxScroll }
    $start = $script:App.Scroll[7]
    $slice = @($procs[$start..([math]::Min($procs.Count - 1, $start + $visible - 1))])

    $maxEst = 1
    foreach ($p in $procs) { if ($p.Established -gt $maxEst) { $maxEst = $p.Established } }

    $cols = @(
        @{ Name = 'Process'; Width = 26 }, @{ Name = 'PID'; Width = 7; Align = 'R' },
        @{ Name = 'Established'; Width = 12; Align = 'R' }, @{ Name = 'Peers'; Width = 7; Align = 'R' },
        @{ Name = 'Listening'; Width = 10; Align = 'R' }, @{ Name = 'UDP'; Width = 6; Align = 'R' },
        @{ Name = 'Other'; Width = 6; Align = 'R' }, @{ Name = ''; Width = 20 }
    )
    $tbl = @()
    foreach ($p in $slice) {
        $tbl += , @(
            @{ Text = $p.Proc; Fg = $Pal.White }
            @{ Text = [string]$p.ProcId; Fg = $Pal.Faint }
            @{ Text = [string]$p.Established; Fg = $(if ($p.Established -gt 0) { $Pal.Green } else { $Pal.Faint }) }
            @{ Text = [string]$p.Remotes.Count; Fg = $Pal.Cyan }
            @{ Text = [string]$p.Listen; Fg = $Pal.Dim }
            @{ Text = [string]$p.Udp; Fg = $Pal.Purple }
            @{ Text = [string]$p.Wait; Fg = $Pal.Faint }
            @{ Text = ''; Fg = $Pal.Text }
        )
    }
    $drawn = Draw-Table $Screen ($X + 2) ($Y + 1) ($W - 4) $visible $cols $tbl

    # Proportion bar in the last column, drawn after the table so it is not clipped.
    for ($i = 0; $i -lt $drawn; $i++) {
        $p = $slice[$i]
        $barX = $X + 2 + 26 + 1 + 7 + 1 + 12 + 1 + 7 + 1 + 10 + 1 + 6 + 1 + 6 + 1
        $barW = [math]::Min(20, $X + $W - 3 - $barX)
        if ($barW -gt 2) {
            Draw-MeterBar $Screen $barX ($Y + 2 + $i) $barW ([double]$p.Established / $maxEst) $Pal.Green
        }
    }

    $note = 'Windows does not attribute bytes to a process without ETW, so this counts sockets, not traffic.'
    Write-Buf $Screen ($X + 2) ($Y + $H - 2) $note $Pal.Faint -2 ($W - 4)
}

#endregion
#region ---- Tab 9: Settings - run the headless modes and edit the config ----------

# Everything the command line can do, from inside the dashboard. The slow modes
# (Collect, SpeedTest, an elevated Install) run in a separate hidden
# powershell.exe exactly as the scheduled task would, so the dashboard keeps
# drawing while they work and a failure in one cannot take the viewer down.

$script:IsElevated = $null

$script:SettingsItems = @(
    @{ Section = 'Run now'; Kind = 'action'; Id = 'Collect'; Label = 'Run a probe cycle'
       Cmd = '-Mode Collect'; Help = 'headless: one probe cycle, append one row, exit' }
    @{ Section = 'Run now'; Kind = 'action'; Id = 'SpeedTest'; Label = 'Run a speed test'
       Cmd = '-Mode SpeedTest'; Help = 'headless: one speed test, exit. Uses real data, skipped if the line is busy' }
    @{ Section = 'Run now'; Kind = 'action'; Id = 'Report'; Label = 'Build the HTML report'
       Cmd = '-Mode Report'; Help = 'headless: write the HTML report (30 days), then open it' }
    @{ Section = 'Run now'; Kind = 'action'; Id = 'Status'; Label = 'Show status'
       Cmd = '-Mode Status'; Help = 'print current state, baseline and the scheduled tasks' }
    @{ Section = 'Scheduled tasks'; Kind = 'action'; Id = 'Install'; Label = 'Install scheduled tasks'
       Cmd = '-Mode Install'; Help = 'register the two Scheduled Tasks (asks whether to run them as SYSTEM)' }
    @{ Section = 'Scheduled tasks'; Kind = 'action'; Id = 'Uninstall'; Label = 'Uninstall scheduled tasks'
       Cmd = '-Mode Uninstall'; Help = 'remove them. Collected data is kept' }
    @{ Section = 'Options'; Kind = 'int'; Id = 'ProbeIntervalSeconds'; Label = 'Probe every'; Unit = 's'
       Help = 'how often the Collect task runs. Task Scheduler minimum is 60. Re-install to apply' }
    @{ Section = 'Options'; Kind = 'int'; Id = 'SpeedTestIntervalHours'; Label = 'Speed test every'; Unit = 'h'
       Help = 'how often the SpeedTest task runs. Each test downloads real data. Re-install to apply' }
    @{ Section = 'Options'; Kind = 'choice'; Id = 'SpeedTestBackend'; Label = 'Speed test backend'
       Choices = @('cloudflare', 'ookla', 'file'); Help = 'ookla = the speedtest.net engine (offers to download it). Enter or left/right' }
    @{ Section = 'Options'; Kind = 'int'; Id = 'OoklaServerId'; Label = 'Ookla server ID'; Unit = ''
       Help = '0 = automatic. To match the website, use its server: list IDs with speedtest.exe -L' }
    @{ Section = 'Options'; Kind = 'int'; Id = 'SpeedTestStreams'; Label = 'Parallel streams'; Unit = ''
       Help = 'connections per direction for the cloudflare test (1-16). Ookla uses 4-8' }
    @{ Section = 'Options'; Kind = 'int'; Id = 'SpeedTestMaxSecondsPerDirection'; Label = 'Test length'; Unit = 's'
       Help = 'seconds of transfer each way. Longer is steadier but uses more data' }
    @{ Section = 'Options'; Kind = 'int'; Id = 'SpeedTestMinGapMinutes'; Label = 'Min gap (scheduled)'; Unit = ' min'
       Help = 'scheduled tests closer together than this are skipped. Manual tests are never limited' }
    @{ Section = 'Options'; Kind = 'int'; Id = 'RetentionDays'; Label = 'Keep data for'; Unit = ' days'
       Help = 'older CSV files are deleted by the collector. 0 keeps everything' }
    @{ Section = 'Options'; Kind = 'choice'; Id = 'HealthAvgMinutes'; Label = 'Health average over'; Format = 'window'
       Choices = @('5', '15', '30', '60', '180', '360', '720', '1440', '4320', '10080')
       Help = 'window for the avg line and the lowest-provider marker in the Health panel. Enter or left/right' }
    @{ Section = 'Options'; Kind = 'int'; Id = 'RefreshMs'; Label = 'Screen refresh'; Unit = ' ms'
       Help = 'how often this dashboard redraws (100 - 5000). Applies immediately' }
    @{ Section = 'Options'; Kind = 'choice'; Id = 'Glyphs'; Label = 'Graphics'
       Choices = @('auto', 'braille', 'blocks', 'ascii'); Help = 'chart characters. Applies immediately' }
    @{ Section = 'Options'; Kind = 'custom'; Id = 'Custom1'; Slot = 0; Label = 'Custom target 1'
       Help = 'Health panel column 6. Address or address=label, blank clears' }
    @{ Section = 'Options'; Kind = 'custom'; Id = 'Custom2'; Slot = 1; Label = 'Custom target 2'
       Help = 'Health panel column 7. Address or address=label, blank clears' }
)

# Runs in the worker pool: Get-ScheduledTask can take half a second, which
# would be a visible stutter if it ran on the drawing thread.
$script:TaskStatusScript = {
    # Two independent routes, because either can fail on a given machine:
    # the ScheduledTasks cmdlets (CIM) and schtasks.exe. Tasks are matched by
    # name in any folder, so one registered under an older path still shows.
    # Errors are reported, never swallowed: "not installed" must mean exactly that.
    param([string]$TaskPath, [string[]]$Names)
    # Local only: called in-process, the script's 'Stop' would turn schtasks'
    # "not found" on stderr into an exception instead of an exit code.
    $ErrorActionPreference = 'Continue'
    $list = New-Object 'System.Collections.Generic.List[object]'
    $haveCmdlets = [bool](Get-Command 'Get-ScheduledTask' -ErrorAction SilentlyContinue)
    $schtasks = ''
    $haveSchtasks = $false
    if ($env:SystemRoot) {
        $schtasks = Join-Path $env:SystemRoot 'System32\schtasks.exe'
        $haveSchtasks = Test-Path -LiteralPath $schtasks
    }

    $all = $null
    $cimError = ''
    if ($haveCmdlets) {
        try { $all = @(Get-ScheduledTask -ErrorAction Stop) }
        catch { $cimError = $_.Exception.Message; $all = $null }
    }

    foreach ($n in $Names) {
        $rec = [ordered]@{ Name = $n; Installed = $false; State = ''; LastRun = ''; LastResult = ''
                           NextRun = ''; RunAs = ''; Path = ''; Source = ''; Error = ''
                           NextRunAt = $null; Running = $false }
        $found = $false

        if ($null -ne $all) {
            $rec['Source'] = 'cmdlets'
            $t = $null
            foreach ($cand in $all) { if ($cand.TaskName -eq $n) { $t = $cand; if ($cand.TaskPath -eq $TaskPath) { break } } }
            if ($t) {
                $found = $true
                $rec['Installed'] = $true
                $rec['Path'] = [string]$t.TaskPath
                $rec['State'] = [string]$t.State
                try { $rec['RunAs'] = [string]$t.Principal.UserId } catch { }
                try {
                    $i = Get-ScheduledTaskInfo -InputObject $t -ErrorAction Stop
                    if ($i.LastRunTime -and $i.LastRunTime.Year -gt 1900) { $rec['LastRun'] = $i.LastRunTime.ToString('ddd HH:mm:ss') }
                    if ($i.NextRunTime -and $i.NextRunTime.Year -gt 1900) {
                        $rec['NextRun'] = $i.NextRunTime.ToString('ddd HH:mm:ss')
                        $rec['NextRunAt'] = [datetime]$i.NextRunTime
                    }
                    $rec['LastResult'] = [string][int64]$i.LastTaskResult
                } catch { $rec['Error'] = 'info: ' + $_.Exception.Message }
            }
        }

        # Not found by the cmdlets does not prove absence: tasks registered as
        # hidden are left out of Get-ScheduledTask's list, but schtasks /TN
        # still finds them by name.
        if (-not $found -and $haveSchtasks) {
            # Columns of /V /FO CSV are fixed by position whatever the display
            # language: 3 next run, 4 status, 6 last run, 7 last result, 15 run as.
            $rec['Source'] = 'schtasks'
            try {
                $raw = @(& $schtasks /Query /TN ($TaskPath + $n) /FO CSV /V /NH 2>&1 | ForEach-Object { [string]$_ })
                if ($LASTEXITCODE -eq 0) {
                    $line = @($raw | Where-Object { $_ -and $_.Trim() -and $_ -notmatch '^(ERROR|INFO):' })[0]
                    $hdr = @(1..30 | ForEach-Object { 'c' + $_ })
                    $row = $line | ConvertFrom-Csv -Header $hdr
                    $found = $true
                    $rec['Installed'] = $true
                    $rec['Path'] = $TaskPath
                    $rec['NextRun'] = [string]$row.c3
                    $nra = [datetime]::MinValue
                    if ([datetime]::TryParse([string]$row.c3, [ref]$nra)) { $rec['NextRunAt'] = $nra }
                    $rec['State'] = [string]$row.c4
                    $rec['LastRun'] = [string]$row.c6
                    $rec['LastResult'] = [string]$row.c7
                    $rec['RunAs'] = [string]$row.c15
                    $rec['Error'] = ''
                }
            } catch { $rec['Error'] = 'schtasks: ' + $_.Exception.Message }
        }

        if (-not $found -and $cimError -and -not $rec['Error']) { $rec['Error'] = 'Get-ScheduledTask: ' + $cimError }

        if ([string]$rec['State'] -eq 'Running') { $rec['Running'] = $true }
        # Result codes as text.
        $lr = [string]$rec['LastResult']
        if ($lr -match '^-?\d+$') {
            $code = [int64]$lr
            if ($code -eq 0) { $rec['LastResult'] = 'ok' }
            elseif ($code -eq 267009) { $rec['LastResult'] = 'running'; $rec['Running'] = $true }
            elseif ($code -eq 267011) { $rec['LastResult'] = 'not yet run' }
            else { $rec['LastResult'] = '0x{0:X}' -f ($code -band 0xFFFFFFFF) }
        }
        $list.Add((New-Object PSObject -Property $rec))
    }
    New-Object PSObject -Property @{ Supported = ($haveCmdlets -or $haveSchtasks); Tasks = $list.ToArray(); At = [DateTimeOffset]::Now }
}

function Get-NetmonStatusLines {
    # Shared by -Mode Status and the Settings tab so the two never disagree.
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $s = Get-CollectorState
    $lines.Add(('state    {0}' -f $s.State))
    if ($s.Reason) { $lines.Add(('reason   {0}' -f $s.Reason)) }
    if ($null -ne $s.Baseline) { $lines.Add(('baseline {0} ms from {1} cycles' -f [math]::Round($s.Baseline, 1), $s.BaselineN)) }
    foreach ($t in @(Get-NetmonTaskStatus)) {
        if ($t.Installed) {
            $lines.Add(('task     {0,-20} {1,-10} last {2} ({3})  next {4}  as {5}' -f $t.Name, $t.State, $t.LastRun, $t.LastResult, $t.NextRun, $t.RunAs))
            if ($t.Path -and $t.Path -ne $script:TaskPath) { $lines.Add(('         found in {0}, expected {1}' -f $t.Path, $script:TaskPath)) }
        }
        else { $lines.Add(('task     {0,-20} not installed' -f $t.Name)) }
        if ($t.Error) { $lines.Add(('         error: {0}' -f $t.Error)) }
    }
    $lines.ToArray()
}

function Set-SettingsOutput {
    param([string]$Title, $Lines)
    $script:App.SetOutTitle = $Title
    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($l in @($Lines)) {
        if ($null -eq $l) { continue }
        foreach ($part in ([string]$l -split "`r?`n")) { $list.Add($part.TrimEnd()) }
    }
    # Format-List output arrives wrapped in blank lines; they waste the panel.
    while ($list.Count -gt 0 -and $list[0] -eq '') { $list.RemoveAt(0) }
    while ($list.Count -gt 0 -and $list[$list.Count - 1] -eq '') { $list.RemoveAt($list.Count - 1) }
    $script:App.SetOut = $list
}

function Start-ChildMode {
    # One headless run of this script in its own hidden powershell.exe, output
    # captured to a temp file. -Elevated goes through UAC.
    param([string]$ChildMode, [switch]$Elevated)
    $A = $script:App
    if ($A.SetJob) { $A.Message = 'busy: ' + $A.SetJob.Name + ' is still running'; return }
    if (-not $script:ScriptPath) { $A.Message = 'script path unknown: run PS-NETMON.ps1 from disk'; return }

    $out = Join-Path ([System.IO.Path]::GetTempPath()) ('psnetmon-{0}-{1}.txt' -f $ChildMode.ToLowerInvariant(), [guid]::NewGuid().ToString('N').Substring(0, 8))
    $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
    $call = '& {0} -Mode {1}' -f (& $q $script:ScriptPath), $ChildMode
    if ($ChildMode -eq 'Collect' -or $ChildMode -eq 'SpeedTest') { $call += ' -Show' }
    if ($ConfigPath) { $call += ' -ConfigPath ' + (& $q $ConfigPath) }
    $cmd = "`$ProgressPreference = 'SilentlyContinue'; try { $call *>&1 | Out-File -FilePath $(& $q $out) -Encoding utf8 -Width 200 } " +
           "catch { ('failed: ' + `$_.Exception.Message) | Out-File -FilePath $(& $q $out) -Encoding utf8 -Append -Width 200; exit 1 }"
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    $argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ' + $enc

    try {
        if ($Elevated) {
            $p = Start-Process -FilePath (Get-HostExecutable) -ArgumentList $argLine -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop
        } else {
            $p = Start-Process -FilePath (Get-HostExecutable) -ArgumentList $argLine -WindowStyle Hidden -PassThru -ErrorAction Stop
        }
    } catch {
        if ($Elevated) { $A.Message = $ChildMode + ': administrator prompt was declined' }
        else { $A.Message = $ChildMode + ' could not start: ' + $_.Exception.Message }
        return
    }
    $label = $ChildMode
    if ($Elevated) { $label += ' (admin)' }
    $A.SetJob = @{ Name = $label; Mode = $ChildMode; Proc = $p; Out = $out; Started = [DateTimeOffset]::Now }
    Set-SettingsOutput -Title $label -Lines @(('running  .\{0} -Mode {1}' -f $script:ScriptName, $ChildMode), '')
    $A.Message = $label + ' started'
}

function Update-SettingsJob {
    # Called every loop turn. Cheap until the child exits.
    $A = $script:App
    $j = $A.SetJob
    if (-not $j) { return $false }
    $done = $true
    try { $done = $j.Proc.HasExited } catch { $done = $true }
    if (-not $done) {
        # Hard stop well past anything the collector or speed test should take.
        if (([DateTimeOffset]::Now - $j.Started).TotalMinutes -lt 15) { return $false }
        try { $j.Proc.Kill() } catch { }
    }

    $code = $null
    try { $code = $j.Proc.ExitCode } catch { }
    $lines = @()
    if (Test-Path -LiteralPath $j.Out) {
        try { $lines = @(Get-Content -LiteralPath $j.Out -Encoding UTF8 -ErrorAction Stop) } catch { }
        try { Remove-Item -LiteralPath $j.Out -Force -ErrorAction Stop } catch { }
    }
    if ($lines.Count -lt 1) { $lines = @('(no output captured)') }
    $secs = [math]::Round(([DateTimeOffset]::Now - $j.Started).TotalSeconds)
    $tail = 'finished in {0}s' -f $secs
    if ($null -ne $code -and $code -ne 0) { $tail += ', exit code ' + $code }
    Set-SettingsOutput -Title $j.Name -Lines (@($lines) + @('', $tail))
    $A.Message = $j.Name + ' ' + $tail
    $A.SetJob = $null

    # Whatever it did probably changed what the other tabs show.
    $script:Live.LastTaskAt = [DateTimeOffset]::MinValue
    $A.LastStateAt = [DateTimeOffset]::MinValue
    if ($j.Mode -eq 'Collect') { Update-History -Force }
    if ($j.Mode -eq 'SpeedTest') { Update-SpeedHistory -Force }
    return $true
}

function Update-TaskStatus {
    # Every 10s on the Settings tab; every minute otherwise, which is enough
    # for the Dashboard's next-speed-test countdown (it counts down locally).
    $r = Receive-Worker -Name 'tasks'
    if ($r) { $script:Live.Tasks = $r }
    $every = 60
    if ($script:App.Tab -eq 8) { $every = 10 }
    if (([DateTimeOffset]::Now - $script:Live.LastTaskAt).TotalSeconds -lt $every) { return }
    $script:Live.LastTaskAt = [DateTimeOffset]::Now
    Start-Worker -Name 'tasks' -Body $script:TaskStatusScript `
        -ArgumentList @($script:TaskPath, [string[]]@($script:TaskCollect, $script:TaskSpeed))
}

function Invoke-ReportAction {
    param($Screen, $Config)
    $A = $script:App
    $A.Message = 'building report...'
    Draw-Frame $Screen $Config
    try {
        $r = Write-NetmonReport -Config $Config -Days 30
        $A.Message = 'report: ' + (Split-Path -Leaf $r.Path)
        try { Start-Process $r.Path | Out-Null } catch { }
        return @(('{0} cycles -> {1} buckets, {2} outages, {3}% availability' -f $r.Rows, $r.Buckets, $r.Outages, $r.Uptime), $r.Path)
    } catch {
        $A.Message = 'report failed: ' + $_.Exception.Message
        return @('failed: ' + $_.Exception.Message)
    }
}

function Set-CustomTarget {
    # Shared by the c key and the Settings tab.
    param($Config, [int]$Slot, [string]$Value)
    $A = $script:App
    $Value = $Value.Trim()
    $addr = ''
    if ($Value) {
        $addr = ($Value -split '=')[0].Trim()
        $ip = $null
        if (-not [System.Net.IPAddress]::TryParse($addr, [ref]$ip)) {
            $A.Message = "'$addr' is not an IP address"
            return
        }
    }
    # Validate on a copy first: a bad value must not be able to break the
    # running dashboard or the collector's config.
    $trial = [ordered]@{}
    foreach ($k in @($Config.Keys)) { $trial[$k] = $Config[$k] }
    $ct = @($Config['CustomTargets'])
    while ($ct.Count -lt 2) { $ct += '' }
    $ct[$Slot] = $Value
    $trial['CustomTargets'] = $ct
    try { Test-NetmonConfig -Config $trial }
    catch { $A.Message = 'rejected: ' + $_.Exception.Message; return }

    $Config['CustomTargets'] = $trial['CustomTargets']
    $A.CustomTargets = Get-CustomTargets -Config $Config
    if ($addr) { $script:Live.TargetHistory[$addr] = New-Object 'System.Collections.Generic.List[double]' }
    $script:Live.LastHealthAt = [DateTimeOffset]::MinValue
    $what = $(if ($addr) { $addr } else { 'cleared' })
    $n = $Slot + 1
    if (Save-NetmonConfig -Config $Config -Path $ConfigPath) { $A.Message = "custom $n`: $what" }
    else { $A.Message = "custom $n`: $what (config not saved)" }
}

function Set-ConfigValue {
    # Validate on a copy, then apply and save. Returns $true when applied.
    param($Config, [string]$Key, $Value)
    $A = $script:App
    $trial = [ordered]@{}
    foreach ($k in @($Config.Keys)) { $trial[$k] = $Config[$k] }
    $trial[$Key] = $Value
    try { Test-NetmonConfig -Config $trial }
    catch { $A.Message = 'rejected: ' + $_.Exception.Message; return $false }
    $Config[$Key] = $trial[$Key]
    $saved = Save-NetmonConfig -Config $Config -Path $ConfigPath
    $A.Message = '{0} = {1}' -f $Key, $Config[$Key]
    if (-not $saved) { $A.Message += ' (config not saved)' }

    if ($Key -eq 'HealthAvgMinutes') { $script:Live.LastAvgAt = [DateTimeOffset]::MinValue }
    if ($Key -eq 'Glyphs') {
        $g = [string]$Config['Glyphs']
        if ($g -eq 'auto') { $g = 'braille' }
        Set-GlyphMode -Mode $g
    }
    if ($Key -eq 'ProbeIntervalSeconds' -or $Key -eq 'SpeedTestIntervalHours') {
        $inst = $false
        if ($script:Live.Tasks) { foreach ($t in @($script:Live.Tasks.Tasks)) { if ($t.Installed) { $inst = $true } } }
        if ($inst) {
            $A.SetReinstall = $true
            $A.Message += ' - run Install scheduled tasks to apply'
        }
    }
    return $true
}

function Get-SettingValueText {
    param($Config, $Item)
    switch ($Item.Kind) {
        'action' { return '.\' + $script:ScriptName + ' ' + $Item.Cmd }
        'custom' {
            $t = @($script:App.CustomTargets)[$Item.Slot]
            if ($t -and $t.Address) {
                if ($t.Label -and $t.Label -ne $t.Address) { return $t.Address + ' = ' + $t.Label }
                return $t.Address
            }
            return '(not set)'
        }
        'choice' {
            $v = [string]$Config[$Item.Id]
            if ($Item.Format -eq 'window') { $v = Format-Window ([int]$Config[$Item.Id]) }
            return '< ' + $v + ' >'
        }
        default  { return [string]$Config[$Item.Id] + $Item.Unit }
    }
}

function Invoke-SettingsItem {
    param($Screen, $Config, [int]$Direction = 0)
    $A = $script:App
    $item = $script:SettingsItems[$A.SetSel]

    if ($item.Kind -eq 'choice') {
        $ch = @($item.Choices)
        $i = [array]::IndexOf($ch, [string]$Config[$item.Id])
        $step = $Direction
        if ($step -eq 0) { $step = 1 }
        $i = ($i + $step + $ch.Count) % $ch.Count
        $applied = Set-ConfigValue -Config $Config -Key $item.Id -Value $ch[$i]
        if ($applied -and $item.Id -eq 'SpeedTestBackend' -and $ch[$i] -eq 'ookla' -and -not (Get-OoklaExe -Config $Config)) {
            $ans = Read-Prompt $Screen "speedtest.exe not found. Download Ookla's official CLI into tools\ookla? free for personal use (y/n):" ''
            if ($null -ne $ans -and $ans.Trim() -match '^[yY]') {
                $A.Message = 'downloading speedtest.exe...'
                Draw-Frame $Screen $Config
                try {
                    $exe = Install-OoklaCli
                    Set-SettingsOutput -Title 'Ookla CLI' -Lines @('installed: ' + $exe, 'first run accepts the Ookla licence (--accept-license)')
                    $A.Message = 'speedtest.exe ready'
                } catch {
                    Set-SettingsOutput -Title 'Ookla CLI' -Lines @('failed: ' + $_.Exception.Message, 'download it from speedtest.net/apps/cli and set OoklaExePath')
                    $A.Message = 'download failed'
                }
            } else {
                $A.Message = 'ookla selected, but tests will fail until speedtest.exe is available'
            }
        }
        return
    }
    if ($Direction -ne 0) { return }     # left/right mean nothing to the others

    if ($item.Kind -eq 'int') {
        $v = Read-Prompt $Screen ($item.Label + ' (now ' + $Config[$item.Id] + $item.Unit + '):') ''
        if ($null -eq $v -or -not $v.Trim()) { return }
        $null = Set-ConfigValue -Config $Config -Key $item.Id -Value $v.Trim()
        return
    }
    if ($item.Kind -eq 'custom') {
        $v = Read-Prompt $Screen ($item.Label + ' - address or address=label, blank to clear:') ''
        if ($null -eq $v) { return }
        Set-CustomTarget -Config $Config -Slot $item.Slot -Value $v
        return
    }

    switch ($item.Id) {
        'Collect'   { Start-ChildMode -ChildMode 'Collect' }
        'SpeedTest' { Start-ChildMode -ChildMode 'SpeedTest' }
        'Report'    { Set-SettingsOutput -Title 'Report' -Lines (Invoke-ReportAction $Screen $Config) }
        'Status'    {
            try { Set-SettingsOutput -Title 'Status' -Lines (Get-NetmonStatusLines) }
            catch { Set-SettingsOutput -Title 'Status' -Lines @('failed: ' + $_.Exception.Message) }
        }
        'Install'   {
            if ($A.SetJob) { $A.Message = 'busy: ' + $A.SetJob.Name + ' is still running'; return }
            if (Test-Elevated) {
                try { Set-SettingsOutput -Title 'Install' -Lines (@('Registered:') + @(Install-NetmonTasks -Config $Config)) }
                catch { Set-SettingsOutput -Title 'Install' -Lines @('failed: ' + $_.Exception.Message) }
            } else {
                # As SYSTEM the probes keep running when nobody is logged in,
                # but that takes an administrator prompt.
                $ans = Read-Prompt $Screen 'run the tasks as SYSTEM so they work when logged out? needs admin (y/n):' ''
                if ($null -eq $ans) { return }
                if ($ans.Trim() -match '^[yY]') { Start-ChildMode -ChildMode 'Install' -Elevated; $A.SetReinstall = $false; return }
                try { Set-SettingsOutput -Title 'Install' -Lines (@('Registered:') + @(Install-NetmonTasks -Config $Config)) }
                catch { Set-SettingsOutput -Title 'Install' -Lines @('failed: ' + $_.Exception.Message) }
            }
            $A.SetReinstall = $false
            $script:Live.LastTaskAt = [DateTimeOffset]::MinValue
            $A.Message = 'scheduled tasks installed'
        }
        'Uninstall' {
            if ($A.SetJob) { $A.Message = 'busy: ' + $A.SetJob.Name + ' is still running'; return }
            $ans = Read-Prompt $Screen 'remove both scheduled tasks? collected data is kept (y/n):' ''
            if ($null -eq $ans -or $ans.Trim() -notmatch '^[yY]') { return }
            $removed = @()
            $uerr = ''
            try { $removed = @(Uninstall-NetmonTasks) } catch { $uerr = $_.Exception.Message }
            $left = @(Get-NetmonTaskStatus | Where-Object { $_.Installed })
            if ($left.Count -gt 0 -and -not (Test-Elevated)) {
                # Tasks registered as SYSTEM can only be removed by an admin.
                $ans = Read-Prompt $Screen ('{0} task(s) need admin rights to remove - retry as administrator? (y/n):' -f $left.Count) ''
                if ($null -ne $ans -and $ans.Trim() -match '^[yY]') { Start-ChildMode -ChildMode 'Uninstall' -Elevated; return }
            }
            $msg = @()
            if ($removed.Count -gt 0) { $msg += 'Removed: ' + ($removed -join ', ') } else { $msg += 'Nothing removed.' }
            if ($left.Count -gt 0) { $msg += 'Still installed: ' + (($left | ForEach-Object { $_.Name }) -join ', ') }
            if ($uerr) { $msg += 'failed: ' + $uerr }
            Set-SettingsOutput -Title 'Uninstall' -Lines $msg
            $script:Live.LastTaskAt = [DateTimeOffset]::MinValue
            $A.Message = $msg[0]
        }
    }
}

function Invoke-SettingsKey {
    # Returns $true when the Settings tab used the key.
    param($Screen, $Key, $Config)
    $A = $script:App
    $n = $script:SettingsItems.Count
    switch ($Key.Key) {
        ([ConsoleKey]::UpArrow)    { $A.SetSel = ($A.SetSel - 1 + $n) % $n; return $true }
        ([ConsoleKey]::DownArrow)  { $A.SetSel = ($A.SetSel + 1) % $n; return $true }
        ([ConsoleKey]::Home)       { $A.SetSel = 0; return $true }
        ([ConsoleKey]::End)        { $A.SetSel = $n - 1; return $true }
        ([ConsoleKey]::Enter)      { Invoke-SettingsItem $Screen $Config 0; return $true }
        ([ConsoleKey]::LeftArrow)  { Invoke-SettingsItem $Screen $Config -1; return $true }
        ([ConsoleKey]::RightArrow) { Invoke-SettingsItem $Screen $Config 1; return $true }
    }
    return $false
}

function Draw-TabSettings {
    param($Screen, [int]$X, [int]$Y, [int]$W, [int]$H, $Config)
    $Pal = $script:Col
    $A = $script:App
    $items = $script:SettingsItems

    # Two columns when there is room, otherwise stacked.
    $wide = ($W -ge 110)
    $listW = $W
    if ($wide) { $listW = [math]::Max(62, [int]($W * 0.52)) }
    $rowsNeeded = $items.Count + 3 + 2 + 3     # items, 3 headings, 2 gaps, help
    $listH = $H
    if (-not $wide) { $listH = [math]::Min($H, $rowsNeeded + 2) }

    Draw-Box $Screen $X $Y $listW $listH 'Settings - up/down select, Enter run or edit'

    # Lay the list out as display rows so it can scroll as a whole.
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $sec = ''
    $selRow = 0
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($items[$i].Section -ne $sec) {
            if ($sec) { $rows.Add(@{ Kind = 'gap' }) }
            $sec = $items[$i].Section
            $rows.Add(@{ Kind = 'head'; Text = $sec })
        }
        if ($i -eq $A.SetSel) { $selRow = $rows.Count }
        $rows.Add(@{ Kind = 'item'; Index = $i })
    }

    $inner = $listW - 4
    $helpRows = 3
    $visible = $listH - 2 - $helpRows
    if ($visible -lt 3) { $visible = $listH - 2; $helpRows = 0 }
    $first = 0
    if ($selRow -ge $visible) { $first = $selRow - $visible + 1 }
    $labelW = 26
    $cy = $Y + 1
    for ($r = $first; $r -lt $rows.Count -and $cy -lt $Y + 1 + $visible; $r++) {
        $row = $rows[$r]
        if ($row.Kind -eq 'head') {
            $t = $row.Text
            if ($t -eq 'Options') { $t += '  (saved to ' + (Split-Path -Leaf $ConfigPath) + ')' }
            Write-Buf $Screen ($X + 2) $cy $t $Pal.Magenta -2 $inner
        } elseif ($row.Kind -eq 'item') {
            $it = $items[$row.Index]
            $sel = ($row.Index -eq $A.SetSel)
            $bg = -2
            if ($sel) { $bg = $Pal.Sel; Fill-Rect $Screen ($X + 1) $cy ($listW - 2) 1 ' ' -2 $bg }
            $mark = ' '
            if ($sel) { $mark = $script:Gfx.Arrow }
            Write-Buf $Screen ($X + 2) $cy $mark $Pal.Yellow $bg
            $lf = $Pal.Text
            if ($sel) { $lf = $Pal.White }
            Write-Buf $Screen ($X + 4) $cy $it.Label $lf $bg ($labelW - 1)
            $val = Get-SettingValueText -Config $Config -Item $it
            $vf = $Pal.Cyan
            if ($it.Kind -eq 'action') { $vf = $Pal.Dim }
            if ($it.Kind -eq 'custom' -and $val -eq '(not set)') { $vf = $Pal.Faint }
            if ($it.Id -eq 'Install' -and $A.SetReinstall) { $val = 'needed to apply new intervals'; $vf = $Pal.Warn }
            if ($A.SetJob -and $A.SetJob.Mode -eq $it.Id) {
                $val = 'running {0}s' -f [math]::Round(([DateTimeOffset]::Now - $A.SetJob.Started).TotalSeconds)
                $vf = $Pal.Yellow
            }
            Write-Buf $Screen ($X + 4 + $labelW) $cy $val $vf $bg ($inner - 2 - $labelW)
        }
        $cy++
    }
    if ($first -gt 0) { Write-Buf $Screen ($X + $listW - 4) ($Y + 1) $script:Gfx.Up $Pal.Faint }

    if ($helpRows -gt 0) {
        $hy = $Y + $listH - 1 - $helpRows
        Write-Buf $Screen ($X + 1) $hy ($script:Gfx.H * ($listW - 2)) $Pal.PanelDim
        $it = $items[$A.SetSel]
        if ($it.Kind -eq 'action') {
            Write-Buf $Screen ($X + 2) ($hy + 1) ('.\' + $script:ScriptName + ' ' + $it.Cmd) $Pal.Yellow -2 $inner
        } else {
            Write-Buf $Screen ($X + 2) ($hy + 1) $it.Label $Pal.Yellow -2 $inner
        }
        Write-Buf $Screen ($X + 2) ($hy + 2) $it.Help $Pal.Faint -2 $inner
    }

    # ---- scheduled tasks and paths ----
    if ($wide) {
        $px = $X + $listW + 1; $pw = $W - $listW - 1; $py = $Y
    } else {
        $px = $X; $pw = $W; $py = $Y + $listH
    }
    $remain = $Y + $H - $py
    if ($remain -lt 4) { return }
    # Sized to its content (two lines per task, the admin note, three paths)
    # so the output panel below gets the rest.
    $taskH = [math]::Min(11, $remain)
    if (-not $wide -and $remain -lt 15) { $taskH = [math]::Max(4, $remain - 4) }
    # On a short window, once something has run its output matters more.
    $hasOut = ($A.SetJob -or ($A.SetOut -and $A.SetOut.Count -gt 0))
    if (-not $wide -and $remain -lt 10 -and $hasOut) { $taskH = 0 }
    $iw = $pw - 4
    if ($taskH -gt 0) {
        Draw-Box $Screen $px $py $pw $taskH 'Scheduled tasks'
        $ty = $py + 1
        $info = $script:Live.Tasks
        if (-not $info) {
            Write-Buf $Screen ($px + 2) $ty 'checking Task Scheduler...' $Pal.Faint -2 $iw
            $ty++
        } elseif (-not $info.Supported) {
            Write-Buf $Screen ($px + 2) $ty 'Task Scheduler cmdlets are not available here.' $Pal.Warn -2 $iw
            $ty++
        } else {
            foreach ($t in @($info.Tasks)) {
                if ($ty -ge $py + $taskH - 1) { break }
                $short = ($t.Name -replace '^PS-NETMON\s*', '')
                if (-not $t.Installed) {
                    # With an error the lookup failed: that is not the same as absent.
                    $nt = 'not installed'; $nc = $Pal.Faint; $dc = $Pal.Off
                    if ($t.Error) { $nt = 'could not check'; $nc = $Pal.Warn; $dc = $Pal.Warn }
                    Write-Buf $Screen ($px + 2) $ty ($script:Gfx.Dot) $dc
                    Write-Buf $Screen ($px + 4) $ty $short $Pal.Text -2 12
                    Write-Buf $Screen ($px + 16) $ty $nt $nc -2 ($iw - 14)
                    $ty++
                    if ($t.Error -and $ty -lt $py + $taskH - 1) {
                        Write-Buf $Screen ($px + 4) $ty $t.Error $Pal.Bad -2 ($iw - 2)
                        $ty++
                    }
                    continue
                }
                $sc = $Pal.Ok
                if ($t.State -eq 'Disabled') { $sc = $Pal.Warn }
                if ($t.LastResult -and $t.LastResult -ne 'ok' -and $t.LastResult -ne 'running' -and $t.LastResult -ne 'not yet run') { $sc = $Pal.Bad }
                Write-Buf $Screen ($px + 2) $ty ($script:Gfx.Dot) $sc
                Write-Buf $Screen ($px + 4) $ty $short $Pal.White -2 12
                $who = $t.RunAs
                if ($who -match 'SYSTEM') { $who = 'SYSTEM' } elseif ($who) { $who = ($who -split '\\')[-1] }
                Write-Buf $Screen ($px + 16) $ty ('{0}, as {1}' -f $t.State, $who) $sc -2 ($iw - 14)
                $ty++
                if ($ty -lt $py + $taskH - 1) {
                    $line = 'last {0} ({1})   next {2}' -f $(if ($t.LastRun) { $t.LastRun } else { '-' }), $t.LastResult, $(if ($t.NextRun) { $t.NextRun } else { '-' })
                    Write-Buf $Screen ($px + 4) $ty $line $Pal.Dim -2 ($iw - 2)
                    $ty++
                }
                if ($t.Path -and $t.Path -ne $script:TaskPath -and $ty -lt $py + $taskH - 1) {
                    Write-Buf $Screen ($px + 4) $ty ('in ' + $t.Path + ' (older install?)') $Pal.Warn -2 ($iw - 2)
                    $ty++
                }
                if ($t.Error -and $ty -lt $py + $taskH - 1) {
                    Write-Buf $Screen ($px + 4) $ty $t.Error $Pal.Bad -2 ($iw - 2)
                    $ty++
                }
            }
        }
        $adm = 'not elevated: Install offers to run the tasks as SYSTEM'
        $admCol = $Pal.Faint
        if (Test-ElevatedCached) { $adm = 'elevated: tasks are installed as SYSTEM'; $admCol = $Pal.Ok }
        $pathRows = @(
            @('script', $script:ScriptPath),
            @('config', $ConfigPath),
            @('data', $script:DataDir)
        )
        if ($ty -lt $py + $taskH - 1) { $ty++ }
        if ($ty -lt $py + $taskH - 1) { Write-Buf $Screen ($px + 2) $ty $adm $admCol -2 $iw; $ty++ }
        foreach ($pr in $pathRows) {
            if ($ty -ge $py + $taskH - 1) { break }
            Write-Buf $Screen ($px + 2) $ty $pr[0] $Pal.Faint -2 7
            Write-Buf $Screen ($px + 9) $ty ([string]$pr[1]) $Pal.Dim -2 ($iw - 7)
            $ty++
        }
    }

    # ---- output of the last action ----
    $oy = $py + $taskH
    $oh = $Y + $H - $oy
    if ($oh -lt 3) { return }
    $title = 'Output'
    if ($A.SetOutTitle) { $title += ' - ' + $A.SetOutTitle }
    if ($A.SetJob) { $title += ' (running {0}s)' -f [math]::Round(([DateTimeOffset]::Now - $A.SetJob.Started).TotalSeconds) }
    Draw-Box $Screen $px $oy $pw $oh $title
    $lines = $A.SetOut
    if (-not $lines -or $lines.Count -lt 1) {
        Write-Buf $Screen ($px + 2) ($oy + 1) 'Select an action and press Enter. Its output appears here.' $Pal.Faint -2 $iw
        return
    }
    # Show the end: that is where the result is.
    $room = $oh - 2
    $start = [math]::Max(0, $lines.Count - $room)
    $ly = $oy + 1
    for ($i = $start; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        $lc = $Pal.Text
        if ($l -match '^(failed:|ERROR)|exit code') { $lc = $Pal.Bad }
        elseif ($l -match '^(finished|Registered|Removed|state )') { $lc = $Pal.Ok }
        elseif ($l -match '^running') { $lc = $Pal.Yellow }
        Write-Buf $Screen ($px + 2) $ly $l $lc -2 $iw
        $ly++
    }
}

function Test-ElevatedCached {
    if ($null -eq $script:IsElevated) { $script:IsElevated = [bool](Test-Elevated) }
    $script:IsElevated
}

#endregion
#region ---- Shared history helpers ------------------------------------------------

function Get-SeriesFromRows {
    # Buckets probe rows into fixed time slots, keeping min/avg/max/loss for
    # each. Same rule as the HTML report: never average an outage away.
    param($Rows, [int]$BucketSeconds, [DateTimeOffset]$From, [DateTimeOffset]$To)

    $count = [int][math]::Ceiling(($To - $From).TotalSeconds / [math]::Max(1, $BucketSeconds))
    if ($count -lt 1) { $count = 1 }
    if ($count -gt 600) { $count = 600 }

    $sum = New-Object 'double[]' $count
    $n   = New-Object 'int[]' $count
    $mn  = New-Object 'object[]' $count
    $mx  = New-Object 'object[]' $count
    $ls  = New-Object 'object[]' $count
    $tot = New-Object 'int[]' $count
    $up  = New-Object 'int[]' $count

    foreach ($r in @($Rows)) {
        $ts = ConvertFrom-Timestamp ([string](Get-Field $r 'timestamp'))
        if (-not $ts -or $ts -lt $From -or $ts -gt $To) { continue }
        $i = [int][math]::Floor(($ts - $From).TotalSeconds / $BucketSeconds)
        if ($i -lt 0 -or $i -ge $count) { continue }

        $m = Get-RowMetrics -Row $r
        $tot[$i]++
        if (-not [string](Get-Field $r 'failed_layers')) { $up[$i]++ }
        if ($null -ne $m['LatencyMs']) {
            $sum[$i] += $m['LatencyMs']; $n[$i]++
            if ($null -eq $mn[$i] -or $m['LatencyMs'] -lt $mn[$i]) { $mn[$i] = $m['LatencyMs'] }
            if ($null -eq $mx[$i] -or $m['LatencyMs'] -gt $mx[$i]) { $mx[$i] = $m['LatencyMs'] }
        }
        if ($null -ne $m['LossPct']) {
            if ($null -eq $ls[$i] -or $m['LossPct'] -gt $ls[$i]) { $ls[$i] = $m['LossPct'] }
        }
    }

    $out = New-Object 'object[]' $count
    for ($i = 0; $i -lt $count; $i++) {
        $avg = $null
        if ($n[$i] -gt 0) { $avg = [math]::Round($sum[$i] / $n[$i], 1) }
        $upPct = $null
        if ($tot[$i] -gt 0) { $upPct = [math]::Round(100.0 * $up[$i] / $tot[$i], 2) }
        $out[$i] = New-Object PSObject -Property ([ordered]@{
            Start = $From.AddSeconds($i * $BucketSeconds)
            Avg = $avg; Min = $mn[$i]; Max = $mx[$i]; Loss = $ls[$i]
            Count = $tot[$i]; UpPct = $upPct
        })
    }
    $out
}

function Get-CollectorState {
    # The collector's verdict, read from state.json. The dashboard reports what
    # the collector decided rather than forming a second opinion, so the header
    # can never disagree with the events log.
    $st = Get-NetmonState
    $res = [ordered]@{ State = 'no data'; Since = $null; Reason = ''; Baseline = $null; BaselineN = 0 }
    if ($st.ContainsKey('Baseline') -and $st['Baseline']) {
        try { $res['Baseline'] = [double]$st['Baseline']['LatencyMs'] } catch { }
        try { $res['BaselineN'] = [int]$st['Baseline']['N'] } catch { }
    }
    if ($st.ContainsKey('Health') -and $st['Health']) {
        $res['State'] = [string]$st['Health']['State']
        $res['Since'] = ConvertFrom-Timestamp ([string]$st['Health']['Since'])
        $res['Reason'] = [string]$st['Health']['Reason']
    }
    New-Object PSObject -Property $res
}

function Update-History {
    param([switch]$Force)
    $now = [DateTimeOffset]::Now
    if (-not $Force -and ($now - $script:Live.LastHistAt).TotalSeconds -lt 60) { return }
    $script:Live.LastHistAt = $now
    try {
        $script:Live.Hist = @(Import-DataRows -Kind 'probe' -Since $now.AddHours(-25).Date)
        $script:Live.Events = @(Import-DataRows -Kind 'events' -Since $now.AddDays(-30).Date)
    } catch {
        $script:Live.Hist = @(); $script:Live.Events = @()
    }
}

function Update-SpeedHistory {
    # The last three usable speed tests, newest first, for the Dashboard.
    # Speed tests are a few rows a day, so reading six weeks of them is cheap;
    # still, only every two minutes.
    param([switch]$Force)
    $now = [DateTimeOffset]::Now
    if (-not $Force -and ($now - $script:Live.LastSpeedAt).TotalSeconds -lt 120) { return }
    $script:Live.LastSpeedAt = $now
    try {
        $good = New-Object 'System.Collections.Generic.List[object]'
        foreach ($r in (Import-DataRows -Kind 'speedtest' -Since $now.AddDays(-45).Date)) {
            $st = [string](Get-Field $r 'status')
            if ($st -ne 'ok' -and $st -ne 'partial') { continue }
            $ts = ConvertFrom-Timestamp ([string](Get-Field $r 'timestamp'))
            if (-not $ts) { continue }
            $good.Add((New-Object PSObject -Property @{ When = $ts; Row = $r }))
        }
        # Files are per day and may have _v2 siblings, so order by time, not file.
        $sorted = @($good.ToArray() | Sort-Object -Property When -Descending | Select-Object -First 3)
        $script:Live.Speed = $sorted
    } catch {
        $script:Live.Speed = @()
    }
}

#endregion
#region ---- Input ------------------------------------------------------------------

function Read-Prompt {
    # A small inline prompt on the status row. It blocks, which is fine: the
    # user is typing, not watching.
    param($Screen, [string]$Label, [string]$Initial = '')
    $text = $Initial
    while ($true) {
        $y = $Screen.H - 1
        Fill-Rect $Screen 0 $y $Screen.W 1 ' ' $script:Col.Text -1
        Write-Buf $Screen 1 $y ($Label + ' ') $script:Col.Yellow
        Write-Buf $Screen (2 + $Label.Length) $y ($text + '_') $script:Col.White
        Write-Render $Screen

        $k = [Console]::ReadKey($true)
        if ($k.Key -eq [ConsoleKey]::Enter) { return $text }
        if ($k.Key -eq [ConsoleKey]::Escape) { return $null }
        if ($k.Key -eq [ConsoleKey]::Backspace) {
            if ($text.Length -gt 0) { $text = $text.Substring(0, $text.Length - 1) }
            continue
        }
        if ($k.KeyChar -and [int]$k.KeyChar -ge 32) { $text += $k.KeyChar }
    }
}

function Invoke-ConnectionsKey {
    # Returns $true when the Connections tab used the key.
    param($Screen, $Key)
    $A = $script:App
    $rows = @(Get-ConnectionRows)
    if ($rows.Count -lt 1) { return $false }
    $sel = Resolve-ConnectionSelection $rows
    $move = $null
    switch ($Key.Key) {
        ([ConsoleKey]::UpArrow)   { $move = $sel - 1 }
        ([ConsoleKey]::DownArrow) { $move = $sel + 1 }
        ([ConsoleKey]::PageUp)    { $move = $sel - 10 }
        ([ConsoleKey]::PageDown)  { $move = $sel + 10 }
        ([ConsoleKey]::Home)      { $move = 0 }
        ([ConsoleKey]::End)       { $move = $rows.Count - 1 }
    }
    if ($null -ne $move) {
        $move = [math]::Max(0, [math]::Min($move, $rows.Count - 1))
        $A.ConnSel = $move
        $A.ConnKey = Get-ConnectionKey $rows[$move]
        return $true
    }
    if ($Key.Key -ne [ConsoleKey]::Delete -and [string]$Key.KeyChar -ne 'x') { return $false }

    $c = $rows[$sel]
    $what = '{0} (pid {1})  {2} {3} -> {4}' -f $c.Proc, $c.ProcId, $c.Proto, $c.Local, $c.Remote
    $ans = Read-Prompt $Screen ($what + '   c: close connection  p: end process  Esc: cancel:') ''
    if ($null -eq $ans) { return $true }
    switch -Regex ($ans.Trim()) {
        '^[cC]' { $A.Message = Close-TcpConnection $c }
        '^[pP]' {
            $ok = Read-Prompt $Screen ('end {0} (pid {1})? every connection it has will drop (y/n):' -f $c.Proc, $c.ProcId) ''
            if ($null -ne $ok -and $ok.Trim() -match '^[yY]') { $A.Message = Stop-ConnectionOwner $c }
            else { $A.Message = 'cancelled' }
        }
        default { $A.Message = 'cancelled' }
    }
    # Show the result straight away rather than on the next 1.5 s sample.
    $script:Live.LastSnapAt = [DateTimeOffset]::MinValue
    return $true
}

function Invoke-Key {
    param($Screen, $Key, $Config)
    $A = $script:App
    $tab = $A.Tab

    # The Settings tab owns the arrows and Enter: they drive its menu.
    if ($tab -eq 8) { if (Invoke-SettingsKey $Screen $Key $Config) { return } }
    # Connections: the arrows move a selection, x acts on it.
    if ($tab -eq 1) { if (Invoke-ConnectionsKey $Screen $Key) { return } }

    switch ($Key.Key) {
        ([ConsoleKey]::Q)        { $A.Running = $false; return }
        ([ConsoleKey]::Escape)   { if ($A.Filter) { $A.Filter = ''; $A.Message = 'filter cleared' } else { $A.Running = $false }; return }
        ([ConsoleKey]::Tab)      { $A.Tab = ($A.Tab + 1) % $script:TabNames.Count; return }
        ([ConsoleKey]::UpArrow)  { if ($A.Scroll[$tab] -gt 0) { $A.Scroll[$tab]-- }; return }
        ([ConsoleKey]::DownArrow){ $A.Scroll[$tab]++; return }
        ([ConsoleKey]::PageUp)   { $A.Scroll[$tab] = [math]::Max(0, $A.Scroll[$tab] - 10); return }
        ([ConsoleKey]::PageDown) { $A.Scroll[$tab] += 10; return }
        ([ConsoleKey]::Home)     { $A.Scroll[$tab] = 0; return }
    }

    $c = [string]$Key.KeyChar
    if ($c -match '^[1-9]$') { $A.Tab = [int]$c - 1; return }

    switch -CaseSensitive ($c) {
        'p' { $A.Paused = -not $A.Paused; $A.Message = $(if ($A.Paused) { 'paused' } else { 'resumed' }); return }
        'r' {
            $script:Live.LastSnapAt = [DateTimeOffset]::MinValue
            $script:Live.LastHealthAt = [DateTimeOffset]::MinValue
            Update-History -Force
    Update-SpeedHistory -Force
            $A.Message = 'refreshed'
            return
        }
        's' {
            $order = @('proc', 'state', 'remote', 'port')
            $i = [array]::IndexOf($order, $A.Sort)
            $A.Sort = $order[($i + 1) % $order.Count]
            $A.Message = 'sorted by ' + $A.Sort
            return
        }
        'f' {
            $v = Read-Prompt $Screen 'filter:' $A.Filter
            if ($null -ne $v) { $A.Filter = $v.Trim() }
            return
        }
        't' {
            $script:Live.LastTraceAt = [DateTimeOffset]::MinValue
            $A.Message = 'retracing path'
            return
        }
        'R' {
            $lines = Invoke-ReportAction $Screen $Config
            Set-SettingsOutput -Title 'Report' -Lines $lines
            return
        }
        'c' {
            # Two custom columns. Pick the slot, then the address; a blank
            # address clears the slot.
            $which = Read-Prompt $Screen 'set custom column 1 or 2:' ''
            if ($null -eq $which) { return }
            $which = $which.Trim()
            if ($which -ne '1' -and $which -ne '2') { $A.Message = 'custom column must be 1 or 2'; return }
            $slotIdx = [int]$which - 1
            $cur = $A.CustomTargets[$slotIdx].Address
            if (-not $cur) { $cur = 'unset' }
            $v = Read-Prompt $Screen ("custom $which (now $cur) - address or address=label, blank to clear:") ''
            if ($null -eq $v) { return }
            Set-CustomTarget -Config $Config -Slot $slotIdx -Value $v
            return
        }
        'g' {
            # An encoding problem prints "?"; a missing font glyph prints boxes.
            # The probe only catches the first, so this switches by hand.
            $cycle = @('braille', 'blocks', 'ascii')
            $gi = [array]::IndexOf($cycle, $script:GlyphMode)
            Set-GlyphMode -Mode $cycle[(($gi + 1) % $cycle.Count)]
            $A.Message = 'graphics: ' + $script:GlyphMode
            return
        }
        'h' { $A.Tab = 0; return }
    }
}

#endregion
#region ---- Frame ------------------------------------------------------------------

function Draw-Frame {
    param($Screen, $Config)
    Clear-Screen -Screen $Screen
    $script:CurrentHealthWindow = [int]$Config['HealthAvgMinutes']
    Draw-Chrome $Screen

    $x = 0; $y = 1
    $w = $Screen.W; $h = $Screen.H - 2

    switch ($script:App.Tab) {
        0 { Draw-TabDashboard   $Screen $x $y $w $h }
        1 { Draw-TabConnections $Screen $x $y $w $h }
        2 { Draw-TabInterfaces  $Screen $x $y $w $h }
        3 { Draw-TabPackets     $Screen $x $y $w $h }
        4 { Draw-TabStats       $Screen $x $y $w $h }
        5 { Draw-TabTopology    $Screen $x $y $w $h }
        6 { Draw-TabTimeline    $Screen $x $y $w $h }
        7 { Draw-TabProcesses   $Screen $x $y $w $h }
        8 { Draw-TabSettings    $Screen $x $y $w $h $Config }
    }
    Write-Render $Screen
}

function Update-Samplers {
    param($Config)
    $now = [DateTimeOffset]::Now

    # Collect whatever has come back since the last frame.
    $snap = Receive-Worker -Name 'snap'
    if ($snap) {
        $script:Live.Snap = $snap
        $script:Live.SnapAt = [DateTimeOffset]::Now
        Update-InterfaceRates -Snapshot $snap
        Update-ConnectionAges -Snapshot $snap
    }
    $hl = Receive-Worker -Name 'health'
    if ($hl) {
        $script:Live.Health = $hl
        if ($hl.Gw -and $null -ne $hl.Gw.Avg) { $script:Live.GwHistory.Add([double]$hl.Gw.Avg) }
        if ($null -ne $hl.DnsMs) { $script:Live.DnsHistory.Add([double]$hl.DnsMs) }
        foreach ($t in @($hl.Targets)) {
            $key = [string]$t.Address
            if (-not $script:Live.TargetHistory.ContainsKey($key)) {
                $script:Live.TargetHistory[$key] = New-Object 'System.Collections.Generic.List[double]'
            }
            # A timeout is recorded as a gap, not as zero milliseconds.
            if ($null -ne $t.Avg) { $script:Live.TargetHistory[$key].Add([double]$t.Avg) }
            while ($script:Live.TargetHistory[$key].Count -gt 600) { $script:Live.TargetHistory[$key].RemoveAt(0) }
        }
        foreach ($k in @('GwHistory', 'DnsHistory')) {
            while ($script:Live[$k].Count -gt 600) { $script:Live[$k].RemoveAt(0) }
        }
    }
    $tr = Receive-Worker -Name 'trace'
    if ($tr) { $script:Live.Trace = $tr }

    if ($script:App.Paused) { return }

    $target = @($Config['PingTargets'])[0]

    if (($now - $script:Live.LastSnapAt).TotalMilliseconds -ge 1500) {
        $script:Live.LastSnapAt = $now
        Start-Worker -Name 'snap' -Body $script:SnapshotScript -ArgumentList @($target)
    }
    if (($now - $script:Live.LastHealthAt).TotalMilliseconds -ge 2000) {
        $script:Live.LastHealthAt = $now
        $gw = ''
        if ($script:Live.Snap -and $script:Live.Snap.Route) { $gw = $script:Live.Snap.Route.Gateway }
        $addrs = @(@($script:App.LiveTargets) + @($script:App.CustomTargets) |
                   Where-Object { $_.Address } | ForEach-Object { $_.Address })
        Start-Worker -Name 'health' -Body $script:HealthScript `
            -ArgumentList @($gw, [string]$Config['DnsTestDomain'], $addrs, 2)
    }
    if (($now - $script:Live.LastTraceAt).TotalSeconds -ge 60) {
        $script:Live.LastTraceAt = $now
        Start-Worker -Name 'trace' -Body $script:TraceScript -ArgumentList @($target, 8, 2, 1000)
    }
}

function Start-Dashboard {
    param($Config)

    if (-not (Enable-VirtualTerminal)) {
        Write-Host ''
        Write-Host '  This dashboard draws with ANSI escape sequences and this console will not enable them.' -ForegroundColor Yellow
        Write-Host '  Windows Terminal handles it; the old conhost window does not always.' -ForegroundColor Gray
        Write-Host ''
        Write-Host ('  Everything headless still works:  {0} -Mode Collect   and   -Mode Report' -f $script:ScriptName) -ForegroundColor Gray
        Write-Host ''
        return
    }

    # Must happen before anything is drawn: on a console left on the OEM code
    # page every block and box character would otherwise print as "?".
    $originalEncoding = Initialize-Glyphs -Prefer ([string]$Config['Glyphs'])

    Initialize-LiveModel
    Initialize-Workers
    $script:App = @{
        Tab = 0; Paused = $false; Running = $true
        Sort = 'proc'; Filter = ''
        Scroll = @(0, 0, 0, 0, 0, 0, 0, 0, 0)
        Message = $(if ($script:GlyphMode -eq 'ascii') { 'console cannot encode UTF-8: charts drawn in ASCII' } else { '' })
        State = $null
        LiveTargets = (Get-LiveTargets -Config $Config)
        CustomTargets = (Get-CustomTargets -Config $Config)
        LastStateAt = [DateTimeOffset]::MinValue
        ConnSel = 0; ConnKey = '';
        SetSel = 0; SetOut = $null; SetOutTitle = ''; SetJob = $null; SetReinstall = $false
    }

    Start-PacketCapture -Config $Config
    Update-History -Force

    $size = Get-TerminalSize
    $screen = New-Screen -Width $size.W -Height $size.H

    $oldTitle = $null
    try { $oldTitle = $Host.UI.RawUI.WindowTitle } catch { }
    try { $Host.UI.RawUI.WindowTitle = 'PS-NETMON' } catch { }

    # Keys are polled far more often than the screen is redrawn. Tying the two
    # together means choosing between a laggy keyboard and burning a core on
    # redraws nobody asked for; separating them gives both.
    $pollMs = 40
    $lastDraw = [DateTimeOffset]::MinValue
    $needDraw = $true

    Enter-FullScreen
    try {
        while ($script:App.Running) {
            $tick = [DateTimeOffset]::Now

            # Resize: rebuild the buffer rather than drawing into the old shape.
            $sz = Get-TerminalSize
            if ($sz.W -ne $screen.W -or $sz.H -ne $screen.H) {
                $screen = New-Screen -Width $sz.W -Height $sz.H
                [Console]::Write($script:ESC + '[2J')
                $needDraw = $true
            }

            while ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                Invoke-Key $screen $k $Config
                $needDraw = $true          # act on a keystroke immediately
                if (-not $script:App.Running) { break }
            }
            if (-not $script:App.Running) { break }

            Update-Samplers -Config $Config
            Update-PacketCapture
            Update-CapturePause -Config $Config
            Update-PingAverages -Config $Config
            if (($tick - $script:App.LastStateAt).TotalSeconds -ge 3) {
                $script:App.LastStateAt = $tick
                $script:App.State = Get-CollectorState
            }
            if ($script:App.Tab -eq 4 -or $script:App.Tab -eq 6) { Update-History }
            if (Update-SettingsJob) { $needDraw = $true }
            Update-SpeedHistory
            Update-TaskStatus
            $refreshMs = [int]$Config['RefreshMs']     # editable from Settings

            if ($needDraw -or ($tick - $lastDraw).TotalMilliseconds -ge $refreshMs) {
                Draw-Frame $screen $Config
                $lastDraw = [DateTimeOffset]::Now
                $needDraw = $false
            }

            $spent = ([DateTimeOffset]::Now - $tick).TotalMilliseconds
            $sleep = $pollMs - $spent
            if ($sleep -gt 5) { Start-Sleep -Milliseconds ([int]$sleep) }
        }
    } finally {
        # Always give the terminal back, even on Ctrl+C, and never leave a
        # pktmon session running on the machine.
        Stop-PacketCapture
        Stop-Workers
        Exit-FullScreen
        Restore-ConsoleEncoding -Original $originalEncoding
        if ($oldTitle) { try { $Host.UI.RawUI.WindowTitle = $oldTitle } catch { } }
    }
}

#endregion
#region ---- Main ---------------------------------------------------------------------

try {
    $config = Import-NetmonConfig -Path $ConfigPath
    Set-DataDir -Config $config

    switch ($Mode) {

        'Collect' {
            $started = [DateTimeOffset]::Now
            $state   = Get-NetmonState
            $row     = Invoke-Collect -Config $config -State $state -Started $started
            $path    = Add-CsvRow -Kind 'probe' -Row $row -When $started
            try {
                $metrics = Get-RowMetrics -Row $row
                $health  = Update-Health -Row $row -Metrics $metrics -Config $config -State $state -When $started
            } catch {
                Write-NetmonLog -Level ERROR "Health evaluation failed: $($_.Exception.Message)"
                $health = $null
            }
            Remove-OldData -Config $config -State $state -Now $started
            Save-NetmonState -State $state
            if ($Show) {
                New-Object PSObject -Property $row | Format-List | Out-String | Write-Host
                if ($health) { Write-Host ("state: {0} ({1} this cycle)" -f $health.State, $health.Raw) }
                Write-Host "written to: $path"
            }
        }

        'SpeedTest' {
            $started = [DateTimeOffset]::Now
            $state   = Get-NetmonState
            $row     = Invoke-SpeedTest -Config $config -State $state -Started $started -Manual:(-not $Scheduled) -IgnoreBusy:$Force
            Save-NetmonState -State $state
            if ($Show) { New-Object PSObject -Property $row | Format-List | Out-String | Write-Host }
        }

        'Report' {
            $r = Write-NetmonReport -Config $config -Days $Days
            Write-Host ("{0} cycles -> {1} buckets, {2} outages, {3}% availability" -f
                        $r.Rows, $r.Buckets, $r.Outages, $r.Uptime)
            Write-Host $r.Path
        }

        'Install' {
            foreach ($l in (Install-NetmonTasks -Config $config)) { Write-Host $l }
        }

        'Uninstall' {
            $r = @(Uninstall-NetmonTasks)
            if ($r.Count -gt 0) { Write-Host ('Removed: ' + ($r -join ', ')) } else { Write-Host 'Nothing to remove.' }
        }

        'Status' {
            foreach ($l in (Get-NetmonStatusLines)) { Write-Host $l }
        }

        'Dashboard' { Start-Dashboard -Config $config }
    }
    exit 0
}
catch {
    try { Exit-FullScreen } catch { }
    Write-NetmonLog -Level ERROR -Message (($_ | Out-String) -replace '\s+', ' ')
    if ($Mode -eq 'Dashboard' -or $Show -or $Mode -in @('Install', 'Uninstall', 'Report')) { throw }
    exit 1
}

#endregion
