<#
.SYNOPSIS
    win10-healthcheck.ps1  -  Offline CPRS test-VM health, privacy & hardening audit.

.DESCRIPTION
    Comprehensive read-only diagnostic for a Windows 10 VM (built for the offline
    VirtualBox CPRS test box, but works on any Win10/11). It audits the machine
    across eleven domains and, for every finding, prints the exact remediation
    command so the analysis never has to be re-discovered:

       1.  System identity & offline posture (build, adapters, internet reach)
       2.  Microsoft telemetry & diagnostic data collection
       3.  Cortana / web-search / Bing integration
       4.  Windows Update & forced-update machinery
       5.  Defender cloud reporting (MAPS/SpyNet) & SmartScreen
       6.  Privacy surveillance (location, error reporting, consumer features)
       7.  Bloat / performance-sapping services & startup items
       8.  Resource health (memory, CPU, disk space, disk health)
       9.  Stability & reliability (uptime, BSOD, pending reboot, SFC/DISM)
      10.  Security posture (firewall, UAC, RDP, SMBv1, autologin, accounts)
      11.  Network-egress hardening (live connections, NCSI probe, hosts file)

    Every check emits a colored glyph status: OK / WARN / FAIL / INFO.
    By DEFAULT the script changes NOTHING - it only reports and prints fixes.

.PARAMETER Harden
    Apply the safe, idempotent remediations (disable telemetry services, set the
    privacy registry policies, disable forced-update orchestration, turn off
    Defender cloud reporting, etc.). Requires an elevated (Administrator) shell.
    Resource/stability/security *audits* are never auto-changed - only the
    telemetry/service/registry desired-state items are enforced.

.PARAMETER Ascii
    Use ASCII status markers ([OK]/[XX]/[!!]/[..]) instead of Unicode glyphs,
    for legacy consoles / raster fonts that render boxes.

.PARAMETER Report
    Write a full transcript to %USERPROFILE%\win10-healthcheck-<timestamp>.log

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\win10-healthcheck.ps1
    powershell -ExecutionPolicy Bypass -File .\win10-healthcheck.ps1 -Report
    # elevated, to actually apply the hardening:
    powershell -ExecutionPolicy Bypass -File .\win10-healthcheck.ps1 -Harden

.NOTES
    Version : 1.0.0
    Target  : Windows 10 (Windows PowerShell 5.1, built-in). PS7 also fine.
    Home    : ~/scripts/win10-healthcheck.ps1 on the Linux host (minty).
    Companion guide: ~/scripts/win10-healthcheck-guide.md
#>

[CmdletBinding()]
param(
    [switch]$Harden,
    [switch]$Ascii,
    [switch]$Report
)

# ============================================================================
#  GLOBALS / SETUP
# ============================================================================

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'
$script:Version        = '1.0.0'
$script:Harden         = [bool]$Harden
$script:Findings       = New-Object System.Collections.Generic.List[object]
$script:CurrentSection = 'general'

# Try to make Unicode glyphs render in the legacy console.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

if ($Ascii) {
    $script:Glyph = @{ OK = '[OK]'; WARN = '[!!]'; FAIL = '[XX]'; INFO = '[..]'; HEAD = '==' }
} else {
    $script:Glyph = @{ OK = [char]0x2714; WARN = [char]0x26A0; FAIL = [char]0x2718; INFO = [char]0x00B7; HEAD = [string]([char]0x2501) }
}
$script:Color = @{ OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Cyan' }

if ($Report) {
    $log = Join-Path $env:USERPROFILE ("win10-healthcheck-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    try { Start-Transcript -Path $log -Force | Out-Null; $script:Transcript = $log } catch {}
}

# ============================================================================
#  HELPERS
# ============================================================================

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Section($title) {
    $script:CurrentSection = $title
    $bar = ($script:Glyph.HEAD * 3)
    Write-Host ''
    Write-Host ("{0} {1} " -f $bar, $title) -ForegroundColor White
}

function Write-Status($kind, $msg, $fix) {
    $g = $script:Glyph[$kind]; $c = $script:Color[$kind]
    Write-Host ("  {0} " -f $g) -ForegroundColor $c -NoNewline
    Write-Host $msg
    if ($fix -and -not $script:Harden) {
        Write-Host ("       fix> " + $fix) -ForegroundColor DarkGray
    }
    $script:Findings.Add([pscustomobject]@{
        Section = $script:CurrentSection; Status = $kind; Message = $msg; Fix = $fix })
}

function Ok  ($m)        { Write-Status 'OK'   $m $null }
function Warn($m, $fix)  { Write-Status 'WARN' $m $fix }
function Fail($m, $fix)  { Write-Status 'FAIL' $m $fix }
function Info($m)        { Write-Status 'INFO' $m $null }

function Get-RegValue($Path, $Name) {
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

function Set-RegValueForce($Path, $Name, $Value, $Type = 'DWord') {
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        return $true
    } catch { return $false }
}

# Desired-state registry check. -Critical => FAIL when wrong, else WARN.
function Check-Reg($Path, $Name, $Want, $Label, [switch]$Critical) {
    $cur = Get-RegValue $Path $Name
    $shown = if ($null -eq $cur) { '<unset>' } else { $cur }
    if ($cur -eq $Want) { Ok "$Label = $shown"; return }

    $fix = "Set: $Path\$Name = $Want (DWord)"
    if ($script:Harden) {
        if (Set-RegValueForce $Path $Name $Want) { Ok "$Label set to $Want  (hardened)" }
        else { Fail "$Label could not be set (access denied?)" $fix }
        return
    }
    $msg = "$Label = $shown  (want $Want)"
    if ($Critical) { Fail $msg $fix } else { Warn $msg $fix }
}

function Get-StartMode($Name) {
    $s = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if ($s) { return $s.StartMode } else { return $null }   # Auto|Manual|Disabled|null
}

function Disable-Svc($Name) {
    # Returns $true on success. Falls back to the Start=4 registry key for
    # services that Set-Service refuses (e.g. WaaSMedicSvc).
    try { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue } catch {}
    try {
        Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
        return $true
    } catch {
        return (Set-RegValueForce "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" 'Start' 4)
    }
}

# Desired-state service check. WantManual => Manual is acceptable (not Disabled).
function Check-Svc($Name, $Label, [switch]$WantManual, [switch]$Critical) {
    $mode = Get-StartMode $Name
    if ($null -eq $mode) { Info "$Label ($Name): not installed"; return }

    $good = if ($WantManual) { @('Disabled', 'Manual') } else { @('Disabled') }
    if ($good -contains $mode) { Ok "$Label ($Name): $mode"; return }

    $fix = "Set-Service $Name -StartupType Disabled; Stop-Service $Name -Force"
    if ($script:Harden) {
        if (Disable-Svc $Name) { Ok "$Label ($Name): disabled  (hardened)" }
        else { Fail "$Label ($Name): could not disable" $fix }
        return
    }
    $msg = "$Label ($Name): $mode  (want $(if($WantManual){'Manual/Disabled'}else{'Disabled'}))"
    if ($Critical) { Fail $msg $fix } else { Warn $msg $fix }
}

function HR($bytes) {
    if ($null -eq $bytes) { return 'n/a' }
    $u = 'B','KB','MB','GB','TB'; $i = 0; $v = [double]$bytes
    while ($v -ge 1024 -and $i -lt 4) { $v /= 1024; $i++ }
    '{0:N1} {1}' -f $v, $u[$i]
}

# ============================================================================
#  BANNER
# ============================================================================

$os  = Get-CimInstance Win32_OperatingSystem
$cs  = Get-CimInstance Win32_ComputerSystem
$elevated = Test-Admin

Write-Host ''
Write-Host ("  Windows 10 Health & Hardening Check  v{0}" -f $script:Version) -ForegroundColor White
Write-Host  "  ====================================" -ForegroundColor White
Write-Host ("  Host        : {0}" -f $env:COMPUTERNAME)
Write-Host ("  OS          : {0}  (build {1})" -f $os.Caption, $os.BuildNumber)
Write-Host ("  Mode        : {0}" -f $(if ($script:Harden) { 'HARDEN (will apply fixes)' } else { 'AUDIT (read-only)' })) -ForegroundColor $(if ($script:Harden) { 'Yellow' } else { 'Cyan' })
Write-Host ("  Elevated    : {0}" -f $(if ($elevated) { 'yes' } else { 'NO - run as Administrator for full coverage' })) -ForegroundColor $(if ($elevated) { 'Green' } else { 'Yellow' })
if ($script:Transcript) { Write-Host ("  Transcript  : {0}" -f $script:Transcript) }

if ($script:Harden -and -not $elevated) {
    Write-Host ''
    Fail "-Harden requested but shell is NOT elevated. Re-run from an Administrator PowerShell." `
         "Right-click PowerShell > Run as administrator, then re-run with -Harden"
    $script:Harden = $false
    Write-Host "  Continuing in AUDIT mode." -ForegroundColor Yellow
}

# ============================================================================
#  1. SYSTEM IDENTITY & OFFLINE POSTURE
# ============================================================================
Section '1. System identity & offline posture'

Info ("Edition  : {0}" -f $os.Caption)
Info ("Version  : {0}  build {1}.{2}" -f (Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'DisplayVersion'), $os.BuildNumber, (Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'UBR'))
Info ("Installed: {0}" -f $os.InstallDate)
Info ("RAM      : {0}   CPUs: {1}" -f (HR ($cs.TotalPhysicalMemory)), $cs.NumberOfLogicalProcessors)

# Network adapters
$adapters = Get-NetAdapter -Physical | Where-Object Status -eq 'Up'
foreach ($a in $adapters) {
    $ip = (Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4).IPAddress -join ','
    Info ("NIC up   : {0}  {1}  [{2}]" -f $a.Name, $a.InterfaceDescription, $ip)
}

# Offline posture: an offline CPRS test VM should NOT reach the public internet.
$online = Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue
if ($online) {
    Warn "VM can reach the public internet (ping 8.8.8.8 succeeded)." `
         "For a truly offline test VM: VirtualBox > Settings > Network > set adapter to 'Host-only' or 'Not attached', or 'VBoxManage modifyvm win10_x64 --nic1 hostonly'"
} else {
    Ok "No public internet reachability (good for an offline test VM)."
}

# ============================================================================
#  2. TELEMETRY & DIAGNOSTIC DATA COLLECTION
# ============================================================================
Section '2. Microsoft telemetry & diagnostic data'

Check-Svc  'DiagTrack'        'Connected User Experiences & Telemetry' -Critical
Check-Svc  'dmwappushservice' 'WAP Push Message Routing (telemetry)'   -Critical
Check-Reg  'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0 'Telemetry policy (AllowTelemetry)' -Critical
Check-Reg  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0 'Telemetry (CurrentVersion)'
Check-Reg  'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1 'Feedback notifications off'
Check-Reg  'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0 'Advertising ID off'
Check-Reg  'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0 'Tailored experiences off'
Check-Reg  'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'AITEnable' 0 'Application Impact Telemetry (AIT) off'
Check-Reg  'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows' 'CEIPEnable' 0 'CEIP off'
Check-Reg  'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy' 'HasAccepted' 0 'Inking/typing data off'

# Telemetry scheduled tasks (CEIP / Application Experience / Autochk proxy)
$telTasks = @(
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
    '\Microsoft\Windows\Autochk\Proxy',
    '\Microsoft\Windows\Feedback\Siuf\DmClient',
    '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'
)
$telOn = @()
foreach ($t in $telTasks) {
    $leaf = Split-Path $t -Leaf; $path = (Split-Path $t -Parent) + '\'
    $task = Get-ScheduledTask -TaskName $leaf -TaskPath $path -ErrorAction SilentlyContinue
    if ($task -and $task.State -ne 'Disabled') { $telOn += $t }
}
if ($telOn.Count -eq 0) {
    Ok "Telemetry scheduled tasks all disabled/absent."
} else {
    $fix = ($telOn | ForEach-Object { "Disable-ScheduledTask -TaskPath '$((Split-Path $_ -Parent))\' -TaskName '$((Split-Path $_ -Leaf))'" }) -join '; '
    if ($script:Harden) {
        foreach ($t in $telOn) { Disable-ScheduledTask -TaskPath ((Split-Path $t -Parent) + '\') -TaskName (Split-Path $t -Leaf) -ErrorAction SilentlyContinue | Out-Null }
        Ok ("Disabled {0} telemetry scheduled task(s).  (hardened)" -f $telOn.Count)
    } else {
        Warn ("{0} telemetry scheduled task(s) still enabled." -f $telOn.Count) $fix
    }
}

# ============================================================================
#  3. CORTANA / WEB SEARCH / BING
# ============================================================================
Section '3. Cortana / web-search / Bing'

Check-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0 'Cortana off'
Check-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWeb' 0 'Web results in Search off'
Check-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch' 1 'Bing web search disabled'
Check-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0 'Start-menu Bing off (user)'
# Windows Search indexing: pure CPU/disk cost on an offline single-app VM.
Check-Svc 'WSearch' 'Windows Search indexer' -WantManual

# ============================================================================
#  4. WINDOWS UPDATE & FORCED-UPDATE MACHINERY
# ============================================================================
Section '4. Windows Update & forced updates'

Check-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 1 'Automatic updates disabled' -Critical
Check-Svc 'wuauserv'      'Windows Update'              -WantManual
Check-Svc 'WaaSMedicSvc'  'Update Medic (re-enables WU)'
Check-Svc 'UsoSvc'        'Update Orchestrator'         -WantManual
Check-Svc 'DoSvc'         'Delivery Optimization (P2P)' -WantManual
Check-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 0 'Delivery Optimization P2P off'

# Update Orchestrator scheduled tasks
$uoTasks = @('Schedule Scan','Schedule Scan Static Task','Universal Orchestrator Start','UpdateModelTask')
$uoOn = @()
foreach ($n in $uoTasks) {
    $task = Get-ScheduledTask -TaskName $n -TaskPath '\Microsoft\Windows\UpdateOrchestrator\' -ErrorAction SilentlyContinue
    if ($task -and $task.State -ne 'Disabled') { $uoOn += $n }
}
if ($uoOn.Count -eq 0) { Ok "UpdateOrchestrator tasks disabled/absent." }
else { Warn ("{0} UpdateOrchestrator task(s) enabled." -f $uoOn.Count) "Disable-ScheduledTask -TaskPath '\Microsoft\Windows\UpdateOrchestrator\' -TaskName '<name>' (note: some are SYSTEM-protected)" }

# ============================================================================
#  5. DEFENDER CLOUD REPORTING & SMARTSCREEN
# ============================================================================
Section '5. Defender cloud (MAPS/SpyNet) & SmartScreen'

$mp = Get-MpPreference -ErrorAction SilentlyContinue
if ($mp) {
    if ($mp.MAPSReporting -eq 0) { Ok "Defender MAPS cloud reporting: off" }
    else { if ($script:Harden) { Set-MpPreference -MAPSReporting 0 -ErrorAction SilentlyContinue; Ok "Defender MAPS reporting disabled (hardened)" } else { Warn ("Defender MAPS reporting = {0} (want 0)" -f $mp.MAPSReporting) "Set-MpPreference -MAPSReporting 0" } }

    if ($mp.SubmitSamplesConsent -eq 2) { Ok "Defender automatic sample submission: never send" }
    else { if ($script:Harden) { Set-MpPreference -SubmitSamplesConsent 2 -ErrorAction SilentlyContinue; Ok "Defender sample submission set to never-send (hardened)" } else { Warn ("Defender SubmitSamplesConsent = {0} (want 2=never)" -f $mp.SubmitSamplesConsent) "Set-MpPreference -SubmitSamplesConsent 2" } }

    $age = $mp.AntivirusSignatureAge
    if ($null -ne $age) { Info ("Defender signature age: {0} day(s) (offline VM can't update - informational)" -f $age) }
    if ($mp.DisableRealtimeMonitoring) { Info "Defender real-time protection: OFF" } else { Ok "Defender real-time protection: on" }
} else {
    Info "Defender PowerShell module not available (Get-MpPreference) - check Windows Security UI."
}
Check-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' 0 'SmartScreen (phones home) off'

# ============================================================================
#  6. PRIVACY SURVEILLANCE
# ============================================================================
Section '6. Privacy surveillance'

Check-Svc 'lfsvc'  'Geolocation service' -WantManual
Check-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocation' 1 'Location sensing disabled'
Check-Svc 'WerSvc' 'Windows Error Reporting (sends dumps to MS)' -WantManual
Check-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1 'Error Reporting disabled'
Check-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1 'Consumer features / suggested apps off'
Check-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1 'Soft-landing tips off'
Check-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0 'Activity history feed off'
Check-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0 'Activity publishing off'
Check-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization' 'AllowInputPersonalization' 0 'Online speech/inking off'

# OneDrive presence
$od = Get-Process OneDrive -ErrorAction SilentlyContinue
if ($od) { Warn "OneDrive is running (cloud sync agent, unneeded on offline VM)." "taskkill /f /im OneDrive.exe; then run %SystemRoot%\SysWOW64\OneDriveSetup.exe /uninstall" }
else { Ok "OneDrive not running." }

# ============================================================================
#  7. BLOAT / PERFORMANCE-SAPPING SERVICES & STARTUP
# ============================================================================
Section '7. Bloat & performance services'

Check-Svc 'SysMain'         'SysMain / Superfetch'           -WantManual
Check-Svc 'XblAuthManager'  'Xbox Live Auth'                 -WantManual
Check-Svc 'XblGameSave'     'Xbox Live Game Save'            -WantManual
Check-Svc 'XboxGipSvc'      'Xbox Accessory Mgmt'            -WantManual
Check-Svc 'XboxNetApiSvc'   'Xbox Live Networking'           -WantManual
Check-Svc 'MapsBroker'      'Downloaded Maps Manager'        -WantManual
Check-Svc 'RetailDemo'      'Retail Demo'                    -WantManual
Check-Svc 'Fax'             'Fax'                            -WantManual
Check-Svc 'WMPNetworkSvc'   'WMP Network Sharing'            -WantManual
Check-Svc 'RemoteRegistry'  'Remote Registry'
Check-Svc 'PhoneSvc'        'Phone Service'                  -WantManual
Check-Svc 'CDPSvc'          'Connected Devices Platform'     -WantManual
Check-Svc 'PcaSvc'          'Program Compatibility Assistant' -WantManual

# Print spooler - only flag if no printers are mapped (CPRS may print).
$printers = Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'OneNote|PDF|XPS|Fax' }
if (-not $printers) { Check-Svc 'Spooler' 'Print Spooler (no real printers found)' -WantManual }
else { Info ("Print Spooler left as-is ({0} printer(s) present)." -f $printers.Count) }

# Startup items (Run keys + Startup folder)
$runKeys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
             'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run')
$startup = @()
foreach ($k in $runKeys) {
    $p = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
    if ($p) { $p.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { $startup += "$($_.Name)" } }
}
if ($startup.Count -gt 0) { Info ("Run-key startup items: {0}" -f ($startup -join ', ')) }
else { Ok "No HKLM/HKCU Run-key startup items." }

# ============================================================================
#  8. RESOURCE HEALTH (memory / CPU / disk)
# ============================================================================
Section '8. Resource health'

# Memory
$totKB = $os.TotalVisibleMemorySize; $freeKB = $os.FreePhysicalMemory
$usedPct = [math]::Round((($totKB - $freeKB) / $totKB) * 100, 1)
$memMsg = "Memory: {0} used of {1} ({2}% used, {3} free)" -f (HR (($totKB-$freeKB)*1KB)), (HR ($totKB*1KB)), $usedPct, (HR ($freeKB*1KB))
if ($usedPct -ge 90) { Fail $memMsg "Close apps / increase VM RAM (VBoxManage modifyvm win10_x64 --memory 8192)" }
elseif ($usedPct -ge 80) { Warn $memMsg "Consider increasing VM RAM if this is sustained." }
else { Ok $memMsg }

Get-Process | Sort-Object WS -Descending | Select-Object -First 5 |
    ForEach-Object { Info ("  top mem: {0,-22} {1}" -f $_.ProcessName, (HR $_.WS)) }

# CPU load (sampled)
$cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
if ($null -ne $cpu) {
    $m = "CPU load: $cpu%"
    if ($cpu -ge 90) { Warn $m "Identify the hot process (Get-Process | Sort CPU -desc | select -first 5)" } else { Ok $m }
}

# Disk space
foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')) {
    $pct = if ($d.Size) { [math]::Round(($d.FreeSpace / $d.Size) * 100, 1) } else { 0 }
    $m = "Disk {0} free: {1} of {2} ({3}%)" -f $d.DeviceID, (HR $d.FreeSpace), (HR $d.Size), $pct
    if ($pct -lt 10) { Fail $m "Free space: cleanmgr /sat, delete C:\Windows\SoftwareDistribution\Download\*, empty Recycle Bin, or grow the VDI" }
    elseif ($pct -lt 15) { Warn $m "Run Disk Cleanup (cleanmgr) and clear update cache." }
    else { Ok $m }
}

# Virtual disk health
try {
    foreach ($pd in (Get-PhysicalDisk -ErrorAction Stop)) {
        if ($pd.HealthStatus -eq 'Healthy') { Ok ("PhysicalDisk '{0}': Healthy" -f $pd.FriendlyName) }
        else { Fail ("PhysicalDisk '{0}': {1}" -f $pd.FriendlyName, $pd.HealthStatus) "Back up immediately; on a VM, check the host disk and the .vdi integrity" }
    }
} catch { Info "PhysicalDisk health API unavailable (older build)." }

# Volume dirty bit (chkdsk needed?)
foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')) {
    $dirty = (fsutil dirty query $d.DeviceID 2>$null) -match 'is Dirty'
    if ($dirty) { Fail ("Volume {0} dirty bit set (filesystem needs chkdsk)." -f $d.DeviceID) ("chkdsk {0} /f  (reboots)" -f $d.DeviceID) }
}

# Cleanup opportunities
$sd = 'C:\Windows\SoftwareDistribution\Download'
if (Test-Path $sd) {
    $sdSize = (Get-ChildItem $sd -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($sdSize -gt 1GB) { Warn ("Windows Update cache is {0}." -f (HR $sdSize)) "net stop wuauserv; del /s /q C:\Windows\SoftwareDistribution\Download\*; net start wuauserv" }
    else { Ok ("Windows Update cache small ({0})." -f (HR $sdSize)) }
}
$tempSize = (Get-ChildItem $env:TEMP -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
if ($tempSize -gt 1GB) { Warn ("User TEMP is {0}." -f (HR $tempSize)) "del /s /q %TEMP%\*" } else { Info ("User TEMP: {0}" -f (HR $tempSize)) }

# ============================================================================
#  9. STABILITY & RELIABILITY
# ============================================================================
Section '9. Stability & reliability'

$boot = $os.LastBootUpTime
$up = (Get-Date) - $boot
Info ("Uptime: {0}d {1}h {2}m  (booted {3})" -f $up.Days, $up.Hours, $up.Minutes, $boot)

# Pending reboot
$pending = $false
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending = $true }
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending = $true }
if (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations') { $pending = $true }
if ($pending) { Warn "A reboot is pending (servicing / file-rename ops queued)." "Restart-Computer" } else { Ok "No pending reboot." }

# Unexpected shutdowns & BSODs in last 7 days
$since = (Get-Date).AddDays(-7)
$dirty6008 = Get-WinEvent -FilterHashtable @{LogName='System'; Id=6008; StartTime=$since} -ErrorAction SilentlyContinue
if ($dirty6008) { Warn ("{0} unexpected shutdown(s) (event 6008) in last 7 days." -f $dirty6008.Count) "Investigate host-side VM resets / power loss." } else { Ok "No unexpected shutdowns (event 6008) in last 7 days." }

$bsod = Get-WinEvent -FilterHashtable @{LogName='System'; Id=1001; ProviderName='Microsoft-Windows-WER-SystemErrorReporting'; StartTime=$since} -ErrorAction SilentlyContinue
if ($bsod) { Fail ("{0} bugcheck/BSOD event(s) in last 7 days." -f $bsod.Count) "Check C:\Windows\Minidump\*.dmp; common VM cause is bad integration/driver state" } else { Ok "No BSOD/bugcheck events in last 7 days." }

# Disk error events (7/51/153)
$diskErr = Get-WinEvent -FilterHashtable @{LogName='System'; Id=7,51,153; StartTime=$since} -ErrorAction SilentlyContinue
if ($diskErr) { Warn ("{0} disk I/O error event(s) (7/51/153) in last 7 days." -f $diskErr.Count) "Check host disk health and the backing .vdi; run chkdsk" } else { Ok "No disk I/O error events in last 7 days." }

# Service crashes (7034)
$svcCrash = Get-WinEvent -FilterHashtable @{LogName='System'; Id=7034; StartTime=$since} -ErrorAction SilentlyContinue
if ($svcCrash) { Info ("{0} service-crash event(s) (7034) in last 7 days." -f $svcCrash.Count) }

# System file integrity - report only (SFC/DISM are slow & online)
Info "Integrity check is manual: 'sfc /scannow' then 'DISM /Online /Cleanup-Image /RestoreHealth' (needs servicing files)."

# Minidumps present?
if (Test-Path 'C:\Windows\Minidump\*.dmp') {
    $n = (Get-ChildItem 'C:\Windows\Minidump\*.dmp').Count
    Warn ("{0} crash minidump(s) present in C:\Windows\Minidump." -f $n) "Analyze with WinDbg/'!analyze -v' or clear after review."
}

# System Protection / restore points - VBox snapshots are the better tool here
Info "Reliability tip: use VirtualBox snapshots ('VBoxManage snapshot win10_x64 take baseline') as the rollback mechanism, not System Restore."

# ============================================================================
#  10. SECURITY POSTURE
# ============================================================================
Section '10. Security posture'

# Firewall - want all profiles ON (blocks unexpected egress on an offline VM)
foreach ($fp in (Get-NetFirewallProfile -ErrorAction SilentlyContinue)) {
    if ($fp.Enabled) { Ok ("Firewall '{0}' profile: enabled" -f $fp.Name) }
    else {
        if ($script:Harden) { Set-NetFirewallProfile -Name $fp.Name -Enabled True -ErrorAction SilentlyContinue; Ok ("Firewall '{0}' enabled (hardened)" -f $fp.Name) }
        else { Fail ("Firewall '{0}' profile: DISABLED" -f $fp.Name) ("Set-NetFirewallProfile -Name {0} -Enabled True" -f $fp.Name) }
    }
}

# UAC
Check-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA' 1 'UAC enabled' -Critical

# RDP - off unless explicitly needed
$rdpDeny = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections'
if ($rdpDeny -eq 1) { Ok "Remote Desktop disabled." }
else { Warn "Remote Desktop is ENABLED." "Set: HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\fDenyTSConnections = 1" }

# SMBv1 - should be off
$smb1 = Get-SmbServerConfiguration -ErrorAction SilentlyContinue
if ($smb1) {
    if (-not $smb1.EnableSMB1Protocol) { Ok "SMBv1 disabled." }
    else { if ($script:Harden) { Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction SilentlyContinue; Ok "SMBv1 disabled (hardened)" } else { Fail "SMBv1 ENABLED (legacy, wormable)." "Set-SmbServerConfiguration -EnableSMB1Protocol `$false -Force" } }
}

# Cleartext autologin password in registry
$alPw = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' 'DefaultPassword'
$alOn = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' 'AutoAdminLogon'
if ($alOn -eq '1' -and $alPw) { Warn "Auto-logon stores a CLEARTEXT password in the registry (Winlogon\DefaultPassword)." "Use Sysinternals Autologon to store it encrypted as LSA secret, or disable auto-logon." }
else { Ok "No cleartext auto-logon password in Winlogon." }

# Guest account
$guest = Get-LocalUser -Name 'Guest' -ErrorAction SilentlyContinue
if ($guest -and $guest.Enabled) { Warn "Guest account is ENABLED." "Disable-LocalUser -Name Guest" } else { Ok "Guest account disabled/absent." }

# AutoPlay / AutoRun
Check-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun' 255 'AutoRun disabled (all drives)'

# ============================================================================
#  11. NETWORK-EGRESS HARDENING
# ============================================================================
Section '11. Network-egress hardening'

# NCSI active probe (msftconnecttest.com) - disable on offline VM
Check-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet' 'EnableActiveProbing' 0 'NCSI active internet probe off'

# Live established connections to public (non-RFC1918) addresses
$priv = '^(127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|0\.0\.0\.0|::1$|fe80|ff00)'
$egress = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
    Where-Object { $_.RemoteAddress -notmatch $priv -and $_.RemoteAddress -ne '::' }
if ($egress) {
    Warn ("{0} live connection(s) to public IPs (telemetry/leak on an offline VM)." -f $egress.Count) "Inspect: Get-NetTCPConnection -State Established | ? RemoteAddress -notmatch '^(10\.|192\.168\.|127\.)' | select RemoteAddress,OwningProcess"
    $egress | Select-Object -First 6 | ForEach-Object {
        $pn = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        Info ("  -> {0}:{1}  ({2})" -f $_.RemoteAddress, $_.RemotePort, $pn)
    }
} else { Ok "No established connections to public IPs." }

# Hosts-file telemetry blocklist
$hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
$hostsTxt = Get-Content $hosts -ErrorAction SilentlyContinue
$blocked = ($hostsTxt | Where-Object { $_ -match 'telemetry|vortex|watson\.microsoft|settings-win|msftconnecttest|data\.microsoft' }).Count
if ($blocked -ge 3) { Ok ("Hosts file blocks {0} known telemetry host(s)." -f $blocked) }
else {
    $fix = "Append a telemetry blocklist to $hosts (run with -Harden to add a curated set)."
    if ($script:Harden) {
        $block = @('vortex.data.microsoft.com','settings-win.data.microsoft.com','watson.telemetry.microsoft.com',
                   'telemetry.microsoft.com','www.msftconnecttest.com','v10.events.data.microsoft.com',
                   'telecommand.telemetry.microsoft.com')
        $add = $block | Where-Object { $hostsTxt -notmatch [regex]::Escape($_) } | ForEach-Object { "0.0.0.0 $_" }
        if ($add) { Add-Content -Path $hosts -Value (@('','# telemetry blocklist (win10-healthcheck)') + $add) -ErrorAction SilentlyContinue; Ok ("Added {0} telemetry host(s) to hosts file (hardened)." -f $add.Count) }
        else { Ok "Hosts telemetry blocklist already present." }
    } else { Warn "Hosts file has no telemetry blocklist." $fix }
}

# ============================================================================
#  SUMMARY
# ============================================================================
$okN   = ($script:Findings | Where-Object Status -eq 'OK').Count
$warnN = ($script:Findings | Where-Object Status -eq 'WARN').Count
$failN = ($script:Findings | Where-Object Status -eq 'FAIL').Count

Section 'Summary'
Write-Host ("  {0} OK    {1} WARN    {2} FAIL" -f $okN, $warnN, $failN)

if (($warnN + $failN) -gt 0 -and -not $script:Harden) {
    Write-Host ''
    Write-Host "  Recommended actions:" -ForegroundColor White
    $i = 1
    foreach ($f in ($script:Findings | Where-Object { $_.Status -in 'FAIL','WARN' -and $_.Fix })) {
        $c = if ($f.Status -eq 'FAIL') { 'Red' } else { 'Yellow' }
        Write-Host ("   {0,2}. " -f $i) -NoNewline
        Write-Host ("[{0}] " -f $f.Status) -ForegroundColor $c -NoNewline
        Write-Host $f.Message
        Write-Host ("        {0}" -f $f.Fix) -ForegroundColor DarkGray
        $i++
    }
    Write-Host ''
    Write-Host "  Re-run elevated with -Harden to auto-apply the telemetry/service/registry fixes." -ForegroundColor Cyan
}

$verdict = if ($failN -gt 0) { 'NEEDS ATTENTION'; $vc='Red' } elseif ($warnN -gt 0) { 'FAIR'; $vc='Yellow' } else { 'HEALTHY & HARDENED'; $vc='Green' }
Write-Host ''
Write-Host ("  Verdict: {0}" -f $verdict) -ForegroundColor $vc
if ($script:Harden) { Write-Host "  Hardening applied. Reboot to settle service/registry changes, then re-run in audit mode to confirm." -ForegroundColor Cyan }
Write-Host ''

if ($script:Transcript) { try { Stop-Transcript | Out-Null } catch {} }

# Exit code: 0 healthy, 1 warnings, 2 failures (useful for automation)
if ($failN -gt 0) { exit 2 } elseif ($warnN -gt 0) { exit 1 } else { exit 0 }
