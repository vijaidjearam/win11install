#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#===================================================================
#  CONFIGURATION
#===================================================================
$Script:TempFolder       = "C:\Temp"
$Script:PersistentScript = "C:\Temp\DriverUpdateScript.ps1"
$Script:StateFile        = "C:\Temp\DriverUpdateState.json"
$Script:LogFile          = "C:\Temp\DriverUpdateScript.log"
$Script:RunOnceKey       = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
$Script:RunOnceName      = 'DriverUpdateScript_RunOnce'
$Script:DriverTimeout    = 300
$Script:CooldownSeconds  = 5
$Script:DriverProcesses  = @('drvinst','pnputil','DPInst','DPInst64','SetupAPI')
$Script:SpinnerFrames    = @('[ ]','[= ]','[== ]','[=== ]','[====]','[ ===]','[ ==]','[ =]')
$Script:ChocoSourceName  = 'chocosia'
$Script:ChocoSourceUrl   = 'http://choco.local.xyz.com/repository/chocolatey-group'

#===================================================================
#  INITIALISATION
#===================================================================
function Initialize-PersistentScript {
    if (-not (Test-Path $Script:TempFolder)) {
        New-Item -Path $Script:TempFolder -ItemType Directory -Force | Out-Null
    }
    $currentScript = $MyInvocation.ScriptName
    if (-not $currentScript) { $currentScript = $PSCommandPath }
    if ($currentScript -and $currentScript -ne $Script:PersistentScript) {
        if (Test-Path $currentScript) {
            Write-Host "[INIT] Copying script to $Script:PersistentScript" -ForegroundColor Yellow
            Copy-Item -Path $currentScript -Destination $Script:PersistentScript -Force
            Write-Host "[INIT] Script copied successfully." -ForegroundColor Green
        }
    }
    if (-not (Test-Path $Script:PersistentScript)) {
        Write-Host "[ERROR] Persistent script could not be created." -ForegroundColor Red
        return $false
    }
    return $true
}

#===================================================================
#  LOGGING HELPERS
#===================================================================
function Write-Status {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ERROR','WARN','INFO','STEP','OK','PROGRESS','DEBUG','DRIVER','TIME','SKIP','KILL')]
        [string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = switch ($Level.ToUpper()) {
        'ERROR'    { 'Red' }
        'WARN'     { 'Yellow' }
        'INFO'     { 'Cyan' }
        'STEP'     { 'Magenta' }
        'OK'       { 'Green' }
        'PROGRESS' { 'White' }
        'DEBUG'    { 'DarkGray' }
        'DRIVER'   { 'Blue' }
        'TIME'     { 'DarkYellow' }
        'SKIP'     { 'DarkMagenta' }
        'KILL'     { 'Red' }
        default    { 'White' }
    }
    $prefix = switch ($Level.ToUpper()) {
        'ERROR'    { '[X]' }
        'WARN'     { '[!]' }
        'INFO'     { '[i]' }
        'STEP'     { '[>]' }
        'OK'       { '[+]' }
        'PROGRESS' { '[o]' }
        'DEBUG'    { '[.]' }
        'DRIVER'   { '[D]' }
        'TIME'     { '[T]' }
        'SKIP'     { '[S]' }
        'KILL'     { '[K]' }
        default    { '[ ]' }
    }
    Write-Host "[$timestamp] $prefix $Message" -ForegroundColor $color
}

function Write-Banner {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Magenta
    Write-Host "  $Text" -ForegroundColor Magenta
    Write-Host ("=" * 70) -ForegroundColor Magenta
    Write-Host ""
}

function Write-SubBanner {
    param([string]$Text)
    Write-Host ""
    Write-Host "--- $Text ---" -ForegroundColor Yellow
    Write-Host ""
}

function Format-Duration {
    param([double]$Seconds)
    if ($Seconds -lt 60) {
        return "{0:N1}s" -f $Seconds
    }
    elseif ($Seconds -lt 3600) {
        $m = [math]::Floor($Seconds / 60)
        $s = $Seconds % 60
        return "{0}m {1:N0}s" -f $m, $s
    }
    else {
        $h = [math]::Floor($Seconds / 3600)
        $m = [math]::Floor(($Seconds % 3600) / 60)
        return "{0}h {1}m" -f $h, $m
    }
}

function Get-ConsoleWidth {
    $w = 100
    try {
        $w = [Console]::WindowWidth - 5
        if ($w -lt 50) { $w = 100 }
    }
    catch { }
    return $w
}

function Write-DriverHeader {
    param([string]$DriverName, [int]$Current, [int]$Total)
    if ($Total -le 0) { $Total = 1 }
    $pct = [math]::Round(($Current / $Total) * 100)
    $filled = [math]::Floor($pct / 5)
    $empty = 20 - $filled
    $bar = "[" + ("#" * $filled) + ("-" * $empty) + "]"
    Write-Host ""
    Write-Host "  ======================================================================" -ForegroundColor DarkCyan
    Write-Host "  $bar $pct% ($Current of $Total drivers)" -ForegroundColor Cyan
    Write-Host "  Driver: $DriverName" -ForegroundColor White
    Write-Host "  Timeout: $Script:DriverTimeout seconds | Monitoring: drvinst.exe" -ForegroundColor DarkGray
    Write-Host "  ======================================================================" -ForegroundColor DarkCyan
}

#===================================================================
#  PROCESS-HANDLING HELPERS
#===================================================================
function Get-DriverInstallProcesses {
    [System.Collections.ArrayList]$collector = @()
    foreach ($name in $Script:DriverProcesses) {
        $found = $null
        try { $found = Get-Process -Name $name -ErrorAction SilentlyContinue } catch { }
        if ($null -ne $found) {
            foreach ($p in @($found)) { [void]$collector.Add($p) }
        }
    }
    $arr = [object[]]$collector.ToArray()
    return ,$arr
}

function Stop-DriverInstallProcesses {
    param([switch]$Silent)
    $killed = 0
    foreach ($name in $Script:DriverProcesses) {
        $found = $null
        try { $found = Get-Process -Name $name -ErrorAction SilentlyContinue } catch { }
        if ($null -ne $found) {
            foreach ($proc in @($found)) {
                if (-not $Silent) {
                    Write-Status KILL "Terminating: $($proc.ProcessName) (PID $($proc.Id))"
                }
                try { $proc.CloseMainWindow() | Out-Null } catch { }
                Start-Sleep -Milliseconds 300
                try {
                    if (-not $proc.HasExited) {
                        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                    }
                }
                catch { }
                $killed++
            }
        }
    }
    foreach ($name in $Script:DriverProcesses) {
        try {
            $saveEA = $ErrorActionPreference
            $ErrorActionPreference = 'SilentlyContinue'
            $null = cmd.exe /c "taskkill /F /IM `"$name.exe`" >nul 2>&1"
            $ErrorActionPreference = $saveEA
        }
        catch {
            try { $ErrorActionPreference = $saveEA } catch { }
        }
    }
    return $killed
}

function Wait-ForDriverProcesses {
    param([int]$TimeoutSeconds = 30)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $procs = Get-DriverInstallProcesses
        $procCount = ($procs | Measure-Object).Count
        if ($procCount -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Clear-DriverInstallEnvironment {
    $procs = Get-DriverInstallProcesses
    $procCount = ($procs | Measure-Object).Count
    if ($procCount -gt 0) {
        Write-Status WARN "Found $procCount leftover driver process(es) - cleaning up..."
        $k = Stop-DriverInstallProcesses
        Write-Status INFO "Terminated $k process(es)"
        Start-Sleep -Seconds 2
    }
}

#===================================================================
#  VERBOSE COMMAND EXECUTION (real-time stdout/stderr streaming)
#===================================================================
function Invoke-CommandVerbose {
    <#
    .SYNOPSIS
        Starts a process, streams stdout/stderr line-by-line with timestamps,
        shows a heartbeat if silent for 30s, saves a full log, returns exit code.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not (Test-Path $FilePath)) {
        Write-Status ERROR "Executable not found: $FilePath"
        return 999
    }

    $exeName = Split-Path $FilePath -Leaf
    Write-Status INFO "Executing: $exeName $Arguments"
    Write-Host ""

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi

    try {
        $null = $process.Start()
    }
    catch {
        Write-Status ERROR "Failed to start $exeName : $($_.Exception.Message)"
        return 999
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastActivity = [System.Diagnostics.Stopwatch]::StartNew()
    $heartbeatSec = 30
    $logLines = [System.Collections.ArrayList]::new()

    # Async line readers for stdout and stderr
    $stdoutTask = $process.StandardOutput.ReadLineAsync()
    $stderrTask = $process.StandardError.ReadLineAsync()
    $stdoutDone = $false
    $stderrDone = $false

    while ((-not $stdoutDone) -or (-not $stderrDone)) {
        $activity = $false

        # --- stdout ---
        if ((-not $stdoutDone) -and $stdoutTask.IsCompleted) {
            $line = $null
            try { $line = $stdoutTask.Result } catch { $stdoutDone = $true; continue }
            if ($null -ne $line) {
                $trimmed = $line.Trim()
                if ($trimmed) {
                    $ts = Get-Date -Format 'HH:mm:ss'
                    Write-Host "  [$ts] [$Label] $trimmed" -ForegroundColor White
                    [void]$logLines.Add("[$ts] $trimmed")
                }
                $stdoutTask = $process.StandardOutput.ReadLineAsync()
                $activity = $true
                $lastActivity.Restart()
            }
            else {
                $stdoutDone = $true
            }
        }

        # --- stderr ---
        if ((-not $stderrDone) -and $stderrTask.IsCompleted) {
            $line = $null
            try { $line = $stderrTask.Result } catch { $stderrDone = $true; continue }
            if ($null -ne $line) {
                $trimmed = $line.Trim()
                if ($trimmed) {
                    $ts = Get-Date -Format 'HH:mm:ss'
                    Write-Host "  [$ts] [$Label] $trimmed" -ForegroundColor Yellow
                    [void]$logLines.Add("[$ts] [WARN] $trimmed")
                }
                $stderrTask = $process.StandardError.ReadLineAsync()
                $activity = $true
                $lastActivity.Restart()
            }
            else {
                $stderrDone = $true
            }
        }

        # --- heartbeat when process is silent ---
        if ((-not $activity) -and ($lastActivity.Elapsed.TotalSeconds -ge $heartbeatSec)) {
            $ts = Get-Date -Format 'HH:mm:ss'
            $elapsed = [math]::Round($sw.Elapsed.TotalSeconds)
            Write-Host "  [$ts] [$Label] ... still running (${elapsed}s elapsed)" -ForegroundColor DarkGray
            [void]$logLines.Add("[$ts] [heartbeat] ${elapsed}s elapsed")
            $lastActivity.Restart()
        }

        if (-not $activity) {
            Start-Sleep -Milliseconds 100
        }
    }

    $process.WaitForExit()
    $sw.Stop()
    $exitCode = $process.ExitCode

    # Save detailed log
    $safeLabel = $Label -replace '[^a-zA-Z0-9]', '_'
    $logFile = Join-Path $Script:TempFolder "${safeLabel}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    try {
        $header = "Command : $FilePath $Arguments`nExit    : $exitCode`nDuration: $(Format-Duration $sw.Elapsed.TotalSeconds)`n$('=' * 60)`n"
        $body = ($logLines | ForEach-Object { $_ }) -join "`n"
        "$header$body" | Out-File $logFile -Encoding UTF8 -Force
    }
    catch { }

    Write-Host ""
    Write-Status TIME "Completed in $(Format-Duration $sw.Elapsed.TotalSeconds)"
    Write-Status INFO "Exit code: $exitCode"
    Write-Status DEBUG "Log: $logFile"

    try { $process.Dispose() } catch { }
    return $exitCode
}

#===================================================================
#  CHOCOLATEY PATH HELPER
#===================================================================
function Get-ChocoExePath {
    $cmd = Get-Command choco -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }
    $default = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (Test-Path $default) { return $default }
    return $null
}

#===================================================================
#  DEVICE SCANNING & INF MATCHING
#===================================================================
function Get-SystemDeviceIds {
    $ids = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $deviceCount = 0
    $problemDeviceNames = [System.Collections.ArrayList]::new()
    try {
        $devices = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop)
        $deviceCount = ($devices | Measure-Object).Count
        foreach ($dev in $devices) {
            if ($null -ne $dev.HardwareID) {
                foreach ($hwid in @($dev.HardwareID)) {
                    if ($hwid) { [void]$ids.Add($hwid) }
                }
            }
            if ($null -ne $dev.CompatibleID) {
                foreach ($cid in @($dev.CompatibleID)) {
                    if ($cid) { [void]$ids.Add($cid) }
                }
            }
            if ($null -ne $dev.ConfigManagerErrorCode -and $dev.ConfigManagerErrorCode -ne 0) {
                $devName = $dev.Name
                if (-not $devName) { $devName = $dev.DeviceID }
                [void]$problemDeviceNames.Add("$devName (error $($dev.ConfigManagerErrorCode))")
            }
        }
    }
    catch {
        Write-Status WARN "WMI device scan failed: $($_.Exception.Message)"
    }
    if ($ids.Count -eq 0) {
        Write-Status INFO "Trying Get-PnpDevice as fallback..."
        try {
            $pnpDevs = @(Get-PnpDevice -ErrorAction SilentlyContinue)
            $deviceCount = ($pnpDevs | Measure-Object).Count
            foreach ($dev in $pnpDevs) {
                try {
                    $hwProp = $dev | Get-PnpDeviceProperty -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction SilentlyContinue
                    if ($null -ne $hwProp -and $null -ne $hwProp.Data) {
                        foreach ($id in @($hwProp.Data)) { if ($id) { [void]$ids.Add($id) } }
                    }
                }
                catch { }
                try {
                    $cProp = $dev | Get-PnpDeviceProperty -KeyName 'DEVPKEY_Device_CompatibleIds' -ErrorAction SilentlyContinue
                    if ($null -ne $cProp -and $null -ne $cProp.Data) {
                        foreach ($id in @($cProp.Data)) { if ($id) { [void]$ids.Add($id) } }
                    }
                }
                catch { }
            }
        }
        catch {
            Write-Status WARN "Get-PnpDevice fallback also failed: $($_.Exception.Message)"
        }
    }
    Write-Status OK "Scanned $deviceCount device(s), found $($ids.Count) unique hardware/compatible ID(s)."
    $probCount = ($problemDeviceNames | Measure-Object).Count
    if ($probCount -gt 0) {
        Write-Status WARN "$probCount device(s) with problems (may need drivers):"
        foreach ($pd in $problemDeviceNames) {
            Write-Status INFO "  - $pd"
        }
    }
    else {
        Write-Status OK "No devices with driver problems detected."
    }
    return $ids
}

function Get-InfHardwareIds {
    param([Parameter(Mandatory)][string]$InfPath)
    $hardwareIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    try { $lines = @(Get-Content $InfPath -ErrorAction Stop) }
    catch { return @($hardwareIds) }
    $lineCount = ($lines | Measure-Object).Count
    if ($lineCount -eq 0) { return @($hardwareIds) }
    $modelSections = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $inManufacturer = $false
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith(';')) { continue }
        if ($trimmed -match '^\[Manufacturer\]\s*$') { $inManufacturer = $true; continue }
        if ($inManufacturer) {
            if ($trimmed -match '^\[') { $inManufacturer = $false; continue }
            if (-not $trimmed) { continue }
            if ($trimmed -match '=') {
                $rightSide = ($trimmed -split '=', 2)[1]
                if ($null -eq $rightSide) { continue }
                $parts = $rightSide -split ','
                $baseName = $parts[0].Trim()
                if (-not $baseName) { continue }
                [void]$modelSections.Add($baseName)
                $partCount = ($parts | Measure-Object).Count
                for ($j = 1; $j -lt $partCount; $j++) {
                    $decoration = $parts[$j].Trim()
                    if ($decoration) { [void]$modelSections.Add("$baseName.$decoration") }
                }
            }
        }
    }
    foreach ($section in @($modelSections)) {
        $sectionHeader = "[$section]"
        $inSection = $false
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed.StartsWith(';')) { continue }
            if ($trimmed -ieq $sectionHeader) { $inSection = $true; continue }
            if ($inSection) {
                if ($trimmed -match '^\[') { $inSection = $false; continue }
                if (-not $trimmed) { continue }
                if ($trimmed -match '=') {
                    $rightSide = ($trimmed -split '=', 2)[1]
                    if ($null -eq $rightSide) { continue }
                    $idParts = $rightSide -split ','
                    $idPartCount = ($idParts | Measure-Object).Count
                    for ($j = 1; $j -lt $idPartCount; $j++) {
                        $hwid = $idParts[$j].Trim().Trim('"').Trim()
                        if ($hwid -and $hwid -match '\\') { [void]$hardwareIds.Add($hwid) }
                    }
                }
            }
        }
    }
    return @($hardwareIds)
}

function Test-InfMatchesSystem {
    param(
        [Parameter(Mandatory)][string]$InfPath,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$SystemIds
    )
    $infIds = Get-InfHardwareIds -InfPath $InfPath
    $infIdCount = ($infIds | Measure-Object).Count
    if ($infIdCount -eq 0) { return $true }
    foreach ($infId in $infIds) {
        if ($SystemIds.Contains($infId)) { return $true }
    }
    return $false
}

#===================================================================
#  STATE-MANAGEMENT HELPERS
#===================================================================
function Get-ScriptState {
    if (Test-Path $Script:StateFile) {
        try {
            $json = Get-Content $Script:StateFile -Raw -ErrorAction Stop | ConvertFrom-Json
            $defaults = @{
                Phase = 0; VentoyCompleted = $false; VentoyRebootDone = $false
                VentoyProcessedDrivers = @(); VentoyDriverRoot = ""
                ManufacturerPhase = 0; DellADRFailed = $false; LastExitCode = 0
                RebootCount = 0; TotalDriversAdded = 0; TotalDriversInstalled = 0
                TotalDriversFailed = 0; TotalDriversSkipped = 0
                TotalDriversTimedOut = 0; TotalTimeSpent = 0; TotalProcessesKilled = 0
            }
            foreach ($k in $defaults.Keys) {
                if (-not $json.PSObject.Properties[$k]) {
                    $json | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] -Force
                }
            }
            return $json
        }
        catch {
            Write-Status WARN "Failed reading state file - starting fresh: $($_.Exception.Message)"
        }
    }
    return [PSCustomObject]@{
        Phase = 0; VentoyCompleted = $false; VentoyRebootDone = $false
        VentoyProcessedDrivers = @(); VentoyDriverRoot = ""
        ManufacturerPhase = 0; DellADRFailed = $false; LastExitCode = 0
        RebootCount = 0; TotalDriversAdded = 0; TotalDriversInstalled = 0
        TotalDriversFailed = 0; TotalDriversSkipped = 0
        TotalDriversTimedOut = 0; TotalTimeSpent = 0; TotalProcessesKilled = 0
    }
}

function Set-ScriptState {
    param([pscustomobject]$State)
    $State | ConvertTo-Json -Depth 10 | Out-File $Script:StateFile -Encoding UTF8 -Force
}

function Remove-ScriptState {
    Write-Status INFO "Removing state file and RunOnce entry..."
    if (Test-Path $Script:StateFile) { Remove-Item $Script:StateFile -Force -ErrorAction SilentlyContinue }
    try {
        $rk64 = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        ).OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', $true)
        if ($null -ne $rk64) { $rk64.DeleteValue($Script:RunOnceName, $false); $rk64.Close() }
    }
    catch { }
    $fallback = "$($Script:RunOnceName)_Task"
    try {
        $existingTask = Get-ScheduledTask -TaskName $fallback -ErrorAction SilentlyContinue
        if ($null -ne $existingTask) {
            Unregister-ScheduledTask -TaskName $fallback -Confirm:$false -ErrorAction SilentlyContinue
            Write-Status INFO "Deleted fallback Scheduled-Task: $fallback"
        }
    }
    catch { }
    Write-Status OK "Cleanup finished."
}

#===================================================================
#  RUNONCE HELPERS
#===================================================================
function Set-RunOnceEntry {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Command)
    try {
        $rk64 = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        ).OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', $true)
        $rk64.SetValue($Name, $Command, [Microsoft.Win32.RegistryValueKind]::String)
        $rk64.Close()
        Write-Status OK "RunOnce entry created (64-bit): $Name"
        return $true
    }
    catch {
        Write-Status WARN "Failed to write RunOnce (64-bit): $($_.Exception.Message)"
        return $false
    }
}

function Set-RunOnceTask {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$ScriptPath)
    $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $taskTrigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
    try {
        Register-ScheduledTask -TaskName $Name -Action $taskAction -Trigger $taskTrigger -Principal $principal -Force -ErrorAction Stop
        Write-Status OK "Fallback Scheduled-Task created: $Name"
        return $true
    }
    catch {
        Write-Status ERROR "Could not create fallback Scheduled-Task: $($_.Exception.Message)"
        return $false
    }
}

function Schedule-RebootAndContinue {
    param([pscustomobject]$State, [string]$Reason = "Script requires reboot to continue")
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Yellow
    Write-Host "  REBOOT REQUIRED" -ForegroundColor Yellow
    Write-Host "======================================================================" -ForegroundColor Yellow
    Write-Host "  Reason: $Reason" -ForegroundColor Yellow
    Write-Host "  The script will automatically resume after reboot." -ForegroundColor Yellow
    Write-Host "======================================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Status INFO "Cleaning up driver processes before reboot..."
    Stop-DriverInstallProcesses -Silent | Out-Null
    $State.RebootCount++
    Set-ScriptState -State $State
    $cmd = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script:PersistentScript`""
    $runOnceCreated = Set-RunOnceEntry -Name $Script:RunOnceName -Command $cmd
    if (-not $runOnceCreated) {
        $fallbackName = "$($Script:RunOnceName)_Task"
        $taskCreated = Set-RunOnceTask -Name $fallbackName -ScriptPath $Script:PersistentScript
        if (-not $taskCreated) {
            Write-Status ERROR "Unable to schedule script after reboot - manual restart required."
        }
    }
    Write-Status INFO "Reboot scheduled - system will restart in 15 seconds..."
    for ($i = 15; $i -ge 1; $i--) {
        Write-Host "  Rebooting in $i seconds..." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
    Write-Host ""
    Write-Host "  Rebooting NOW!" -ForegroundColor Red
    Write-Host ""
    try { Stop-Transcript } catch { }
    Restart-Computer -Force
    exit 0
}

#===================================================================
#  DRIVER INSTALLATION (single driver with timeout & monitoring)
#===================================================================
function Install-SingleDriver {
    param(
        [Parameter(Mandatory)][string]$InfPath,
        [Parameter(Mandatory)][string]$DriverName,
        [Parameter(Mandatory)][int]$CurrentNumber,
        [Parameter(Mandatory)][int]$TotalCount,
        [int]$TimeoutSeconds = $Script:DriverTimeout
    )
    $result = [PSCustomObject]@{
        InfPath = $InfPath; DriverName = $DriverName; Success = $false
        ExitCode = -1; Added = $false; Installed = $false; AlreadyExists = $false
        NeedsReboot = $false; TimedOut = $false; ProcessesKilled = 0
        ErrorMessage = ""; Output = ""; Duration = 0
    }
    Write-DriverHeader -DriverName $DriverName -Current $CurrentNumber -Total $TotalCount
    Write-Status DRIVER "Path: $InfPath"
    Clear-DriverInstallEnvironment
    Write-Status INFO "Starting installation with process monitoring..."
    Write-Host ""
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $consoleWidth = Get-ConsoleWidth
    $tempScript = [IO.Path]::GetTempFileName() + ".ps1"
    $outFile = [IO.Path]::GetTempFileName()
    $exitFile = [IO.Path]::GetTempFileName()
    $wrapperContent = @"
try {
    `$out = & pnputil.exe /add-driver "$InfPath" /install 2>&1 | Out-String
    `$out | Out-File -FilePath "$outFile" -Encoding UTF8
    `$LASTEXITCODE | Out-File -FilePath "$exitFile" -Encoding UTF8
} catch {
    `$_.Exception.Message | Out-File -FilePath "$outFile" -Encoding UTF8
    "999" | Out-File -FilePath "$exitFile" -Encoding UTF8
}
"@
    $wrapperContent | Out-File -FilePath $tempScript -Encoding UTF8
    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$tempScript`"" -PassThru -WindowStyle Hidden
    $frameIdx = 0
    $frameCount = $Script:SpinnerFrames.Length
    $animLine = 0
    try { $animLine = [Console]::CursorTop } catch { }
    while ((-not $proc.HasExited) -and ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)) {
        $elapsed = $stopwatch.Elapsed.TotalSeconds
        $remaining = [math]::Max(0, $TimeoutSeconds - $elapsed)
        $pct = [math]::Round(($elapsed / $TimeoutSeconds) * 100)
        $spinner = $Script:SpinnerFrames[$frameIdx % $frameCount]
        $frameIdx++
        $line = "  $spinner $pct% | Elapsed: $([math]::Round($elapsed))s | Remaining: $([math]::Round($remaining))s"
        $padded = $line.PadRight($consoleWidth)
        try {
            [Console]::SetCursorPosition(0, $animLine)
            [Console]::ForegroundColor = [ConsoleColor]::Cyan
            [Console]::Write($padded)
            [Console]::ResetColor()
        }
        catch { Write-Host "`r$padded" -NoNewline -ForegroundColor Cyan }
        Start-Sleep -Milliseconds 150
    }
    try {
        [Console]::SetCursorPosition(0, $animLine)
        [Console]::Write(' ' * $consoleWidth)
        [Console]::SetCursorPosition(0, $animLine)
    }
    catch { Write-Host "`r$(' ' * $consoleWidth)`r" -NoNewline }
    $stopwatch.Stop()
    $result.Duration = $stopwatch.Elapsed.TotalSeconds
    if (-not $proc.HasExited) {
        Write-Host ""
        Write-Status SKIP "TIMEOUT after $(Format-Duration $TimeoutSeconds)!"
        try { $proc.Kill() } catch { }
        $result.TimedOut = $true
        $result.ErrorMessage = "Timeout after $TimeoutSeconds seconds"
        $killed = Stop-DriverInstallProcesses
        $result.ProcessesKilled = $killed
        Write-Status KILL "Terminated $killed driver-process(es)"
        $null = Wait-ForDriverProcesses -TimeoutSeconds 10
        Remove-Item $tempScript, $outFile, $exitFile -Force -ErrorAction SilentlyContinue
        Write-Status TIME "Time spent: $(Format-Duration $result.Duration) (TIMEOUT)"
        if ($Script:CooldownSeconds -gt 0) { Start-Sleep -Seconds $Script:CooldownSeconds }
        Write-Host ""
        return $result
    }
    $out = ""
    $exit = -1
    if (Test-Path $outFile) { $out = Get-Content $outFile -Raw -ErrorAction SilentlyContinue }
    if (Test-Path $exitFile) {
        $raw = Get-Content $exitFile -Raw -ErrorAction SilentlyContinue
        if ($null -ne $raw) { [int]::TryParse($raw.Trim(), [ref]$exit) | Out-Null }
    }
    Remove-Item $tempScript, $outFile, $exitFile -Force -ErrorAction SilentlyContinue
    $result.ExitCode = $exit
    $result.Output = $out
    if ($null -ne $out) {
        if ($out -match 'added|successfully added|driver package added') {
            $result.Added = $true; Write-Status OK "Driver added to store"
        }
        if ($out -match 'install.*device|installed to device') {
            $result.Installed = $true; Write-Status OK "Driver installed on device"
        }
        if ($out -match 'already exists|up to date') {
            $result.AlreadyExists = $true; Write-Status INFO "Driver already up-to-date"
        }
        if ($out -match 'reboot|restart') {
            $result.NeedsReboot = $true; Write-Status WARN "Reboot required (output)"
        }
    }
    switch ($exit) {
        0    { $result.Success = $true; Write-Status OK "Exit code 0 - Success" }
        1    { $result.Success = $true; Write-Status INFO "Exit code 1 - Success with warnings" }
        259  { $result.Success = $true; Write-Status INFO "Exit code 259 - staged (no matching device)" }
        3010 { $result.Success = $true; $result.NeedsReboot = $true; Write-Status WARN "Exit code 3010 - Reboot required" }
        482  { $result.Success = $true; $result.NeedsReboot = $true; Write-Status WARN "Exit code 482 - Partial success, reboot needed" }
        default {
            if ($exit -ge 0) {
                if ($result.Added -or $result.Installed -or $result.AlreadyExists) {
                    $result.Success = $true; Write-Status INFO "Exit code $exit - driver processed"
                }
                else {
                    $result.Success = $false; $result.ErrorMessage = "Exit code $exit"
                    Write-Status ERROR "Exit code $exit - failure"
                }
            }
            else { $result.Success = $true; Write-Status WARN "Unable to determine exit code" }
        }
    }
    Write-Status TIME "Time taken: $(Format-Duration $result.Duration)"
    if ($Script:CooldownSeconds -gt 0) { Start-Sleep -Seconds $Script:CooldownSeconds }
    return $result
}

#===================================================================
#  PHASE-0: VENTOY OFFLINE DRIVER INSTALLATION
#===================================================================
function Install-VentoyDrivers {
    param([string[]]$FolderCandidates = @('DriversOS','Drivers'), [pscustomobject]$State)
    Write-Banner "PHASE-0: VENTOY OFFLINE DRIVER INSTALLATION"
    Write-Status INFO "Performing initial cleanup..."
    Clear-DriverInstallEnvironment
    $log = Join-Path $env:WINDIR 'Temp\InstallVentoyDrivers.log'
    "=== Install-VentoyDrivers start $(Get-Date) ===" | Out-File $log -Encoding UTF8 -Append
    $result = [PSCustomObject]@{
        Success = $false; NeedsReboot = $false; NotFound = $false
        TotalFound = 0; TotalMatched = 0; TotalSkippedNoMatch = 0
        TotalAdded = 0; TotalInstalled = 0; TotalFailed = 0; TotalSkipped = 0
        TotalAlreadyExist = 0; TotalTimedOut = 0; TotalTime = 0; TotalKilled = 0
    }
    $root = $null
    if ($State.VentoyDriverRoot -and (Test-Path $State.VentoyDriverRoot)) {
        $root = $State.VentoyDriverRoot
        Write-Status OK "Using saved driver root: $root"
    }
    else {
        $driveLetters = @('D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z')
        foreach ($drive in $driveLetters) {
            foreach ($folder in $FolderCandidates) {
                $candidate = "${drive}:\$folder"
                if (Test-Path $candidate) { $root = $candidate; Write-Status OK "Found driver folder: $root"; break }
            }
            if ($null -ne $root) { break }
        }
    }
    if ($null -eq $root) {
        Write-Status INFO "No Ventoy driver folder found."
        $result.NotFound = $true; $result.Success = $true; return $result
    }
    $State.VentoyDriverRoot = $root; Set-ScriptState -State $State
    $allInfFiles = @(Get-ChildItem -Path $root -Filter "*.inf" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName)
    $totalFound = ($allInfFiles | Measure-Object).Count
    if ($totalFound -eq 0) {
        Write-Status WARN "No .inf files discovered."
        $result.NotFound = $true; $result.Success = $true; return $result
    }
    $result.TotalFound = $totalFound
    Write-Status OK "Found $totalFound INF file(s) in driver folder."
    $processed = @()
    if ($State.VentoyProcessedDrivers) { $processed = @($State.VentoyProcessedDrivers) }
    $processedCount = ($processed | Measure-Object).Count
    if ($processedCount -gt 0) { Write-Status INFO "$processedCount driver(s) already processed." }
    Write-SubBanner "Scanning System Devices"
    $scanSw = [System.Diagnostics.Stopwatch]::StartNew()
    $systemIds = Get-SystemDeviceIds
    $scanSw.Stop()
    Write-Status TIME "Device scan took $(Format-Duration $scanSw.Elapsed.TotalSeconds)"
    Write-SubBanner "Matching Drivers to System Devices"
    $matchSw = [System.Diagnostics.Stopwatch]::StartNew()
    $matchedInfs = [System.Collections.ArrayList]::new()
    $skippedNoMatch = [System.Collections.ArrayList]::new()
    $fallbackMode = $false
    if ($systemIds.Count -eq 0) {
        Write-Status WARN "Could not enumerate any device IDs - installing ALL drivers as fallback."
        $fallbackMode = $true
        foreach ($inf in $allInfFiles) { [void]$matchedInfs.Add($inf) }
    }
    else {
        foreach ($inf in $allInfFiles) {
            $rel = $inf.FullName.Substring($root.Length + 1)
            if ($rel -in $processed) { continue }
            $isMatch = Test-InfMatchesSystem -InfPath $inf.FullName -SystemIds $systemIds
            if ($isMatch) { [void]$matchedInfs.Add($inf) }
            else { [void]$skippedNoMatch.Add($inf); Write-Status SKIP "No matching device: $rel" }
        }
    }
    $matchSw.Stop()
    $matchedCount = ($matchedInfs | Measure-Object).Count
    $skippedNoMatchCount = ($skippedNoMatch | Measure-Object).Count
    $result.TotalMatched = $matchedCount
    $result.TotalSkippedNoMatch = $skippedNoMatchCount
    Write-Host ""
    Write-Host "  ======================================================================" -ForegroundColor DarkCyan
    Write-Host "                     DRIVER MATCHING RESULTS" -ForegroundColor Cyan
    Write-Host "  ======================================================================" -ForegroundColor DarkCyan
    Write-Host "  Total INF files found:        $totalFound" -ForegroundColor White
    Write-Host "  Already processed:            $processedCount" -ForegroundColor DarkGray
    Write-Host "  Matched to system devices:    $matchedCount" -ForegroundColor Green
    Write-Host "  Skipped (no matching device): $skippedNoMatchCount" -ForegroundColor Yellow
    Write-Host "  Matching time:                $(Format-Duration $matchSw.Elapsed.TotalSeconds)" -ForegroundColor DarkGray
    $modeLabel = if ($fallbackMode) { "FALLBACK (all drivers)" } else { "TARGETED (matched only)" }
    $modeColor = if ($fallbackMode) { 'Red' } else { 'Green' }
    Write-Host "  Mode:                         $modeLabel" -ForegroundColor $modeColor
    Write-Host "  ======================================================================" -ForegroundColor DarkCyan
    Write-Host ""
    if ($matchedCount -eq 0) {
        Write-Status OK "No new drivers to install."
        $result.Success = $true; return $result
    }
    $overallSw = [System.Diagnostics.Stopwatch]::StartNew()
    $globalReboot = $false
    $i = 0
    Write-SubBanner "Installing $matchedCount Matched Driver(s)"
    foreach ($inf in $matchedInfs) {
        $i++
        $rel = $inf.FullName.Substring($root.Length + 1)
        if ($rel -in $processed) { continue }
        $drvResult = Install-SingleDriver -InfPath $inf.FullName -DriverName $rel -CurrentNumber $i -TotalCount $matchedCount
        $result.TotalTime += $drvResult.Duration
        $result.TotalKilled += $drvResult.ProcessesKilled
        if ($drvResult.TimedOut) { $result.TotalTimedOut++ }
        elseif ($drvResult.Added) { $result.TotalAdded++ }
        if ($drvResult.Installed) { $result.TotalInstalled++ }
        if ($drvResult.AlreadyExists) { $result.TotalAlreadyExist++ }
        if ((-not $drvResult.Success) -and (-not $drvResult.TimedOut)) { $result.TotalFailed++ }
        if ($drvResult.NeedsReboot) { $globalReboot = $true }
        $processed += $rel
        $State.VentoyProcessedDrivers = $processed
        $State.TotalDriversAdded = $result.TotalAdded
        $State.TotalDriversInstalled = $result.TotalInstalled
        $State.TotalDriversFailed = $result.TotalFailed
        $State.TotalDriversSkipped = $result.TotalSkippedNoMatch
        $State.TotalDriversTimedOut = $result.TotalTimedOut
        $State.TotalTimeSpent = $result.TotalTime
        $State.TotalProcessesKilled = $result.TotalKilled
        Set-ScriptState -State $State
    }
    $overallSw.Stop()
    $failColor = if ($result.TotalFailed -gt 0) { 'Red' } else { 'Green' }
    $timeoutColor = if ($result.TotalTimedOut -gt 0) { 'Yellow' } else { 'Green' }
    $killColor = if ($result.TotalKilled -gt 0) { 'Yellow' } else { 'Green' }
    $rebootColor = if ($globalReboot) { 'Yellow' } else { 'Green' }
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Green
    Write-Host "               VENTOY DRIVER INSTALLATION SUMMARY" -ForegroundColor Green
    Write-Host "======================================================================" -ForegroundColor Green
    Write-Host "  Total INFs found:       $($result.TotalFound)" -ForegroundColor White
    Write-Host "  Matched to devices:     $($result.TotalMatched)" -ForegroundColor Green
    Write-Host "  Skipped (no match):     $($result.TotalSkippedNoMatch)" -ForegroundColor Yellow
    Write-Host "  Added to store:         $($result.TotalAdded)" -ForegroundColor Green
    Write-Host "  Installed on hardware:  $($result.TotalInstalled)" -ForegroundColor Green
    Write-Host "  Already up-to-date:     $($result.TotalAlreadyExist)" -ForegroundColor Cyan
    Write-Host "  Failed:                 $($result.TotalFailed)" -ForegroundColor $failColor
    Write-Host "  Timed out:              $($result.TotalTimedOut)" -ForegroundColor $timeoutColor
    Write-Host "  Processes killed:       $($result.TotalKilled)" -ForegroundColor $killColor
    Write-Host "  Total install time:     $(Format-Duration $overallSw.Elapsed.TotalSeconds)" -ForegroundColor Magenta
    Write-Host "  Reboot required:        $globalReboot" -ForegroundColor $rebootColor
    Write-Host "======================================================================" -ForegroundColor Green
    Write-Host ""
    $result.Success = $true
    $result.NeedsReboot = $globalReboot
    return $result
}

#===================================================================
#  INTERNET CONNECTIVITY CHECK
#===================================================================
function Test-InternetConnectivity {
    param([int]$MaxRetries = 15, [int]$RetryDelay = 10)
    Write-Banner "CHECKING INTERNET CONNECTIVITY"
    $w = Get-ConsoleWidth
    $totalFrames = $Script:SpinnerFrames.Length
    for ($i = 1; $i -le $MaxRetries; $i++) {
        Write-Status PROGRESS "Attempt $i of $MaxRetries..."
        try {
            $r = Invoke-WebRequest -Uri "https://www.google.com" -Method Head -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            if ($r.StatusCode -eq 200) { Write-Status OK "Internet reachable."; return $true }
        }
        catch {
            Write-Status WARN "Attempt $i failed: $($_.Exception.Message)"
            if ($i -lt $MaxRetries) {
                Write-Status INFO "Retrying in $RetryDelay seconds..."
                for ($s = $RetryDelay; $s -ge 1; $s--) {
                    $spinner = $Script:SpinnerFrames[($RetryDelay - $s) % $totalFrames]
                    $line = "  $spinner Waiting $s sec..."
                    $pad = $line.PadRight($w)
                    try {
                        [Console]::SetCursorPosition(0, [Console]::CursorTop)
                        [Console]::ForegroundColor = [ConsoleColor]::DarkGray
                        [Console]::Write($pad)
                        [Console]::ResetColor()
                    }
                    catch { Write-Host "`r$pad" -NoNewline -ForegroundColor DarkGray }
                    Start-Sleep -Seconds 1
                }
            }
        }
    }
    Write-Status ERROR "No internet after $MaxRetries attempts."
    return $false
}

#===================================================================
#  MANUFACTURER DETECTION
#===================================================================
function Get-SystemManufacturer {
    Write-SubBanner "Detecting System Manufacturer"
    $cs = Get-CimInstance Win32_ComputerSystem
    $man = $cs.Manufacturer.Trim()
    $mod = $cs.Model.Trim()
    Write-Status INFO "Manufacturer: $man"
    Write-Status INFO "Model:        $mod"
    return $man
}

#===================================================================
#  CHOCOLATEY INSTALL + SOURCE CONFIGURATION
#===================================================================
function Set-ChocolateySource {
    Write-SubBanner "Configuring Chocolatey Sources"
    $chocoExe = Get-ChocoExePath
    if (-not $chocoExe) {
        Write-Status ERROR "Chocolatey executable not found - cannot configure sources."
        return
    }

    # Check if source exists
    Write-Status INFO "Checking existing Chocolatey sources..."
    $listExit = Invoke-CommandVerbose -FilePath $chocoExe -Arguments "source list" -Label "CHOCO"

    # Try adding the custom source
    Write-Status INFO "Adding custom source: $($Script:ChocoSourceName) -> $($Script:ChocoSourceUrl)"
    $addExit = Invoke-CommandVerbose -FilePath $chocoExe -Arguments "source add -n `"$($Script:ChocoSourceName)`" -s `"$($Script:ChocoSourceUrl)`" --priority=1 --allow-self-service" -Label "CHOCO"
    if ($addExit -eq 0) {
        Write-Status OK "Custom source '$($Script:ChocoSourceName)' configured."
    }
    else {
        Write-Status WARN "Source add returned exit code $addExit (may already exist - OK)."
    }

    # Disable default community source
    Write-Status INFO "Disabling default Chocolatey community source..."
    $disableExit = Invoke-CommandVerbose -FilePath $chocoExe -Arguments "source disable -n `"chocolatey`"" -Label "CHOCO"
    if ($disableExit -eq 0) {
        Write-Status OK "Default community source disabled."
    }
    else {
        Write-Status WARN "Could not disable default source (may not exist)."
    }

    # Verify final state
    Write-Status INFO "Final source configuration:"
    $null = Invoke-CommandVerbose -FilePath $chocoExe -Arguments "source list" -Label "CHOCO"
}

function Install-ChocolateyIfNeeded {
    Write-SubBanner "Ensuring Chocolatey"
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Status INFO "Chocolatey not present - installing..."
        Write-Host ""
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression (Invoke-RestMethod https://community.chocolatey.org/install.ps1)
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
        Write-Host ""
        Write-Status OK "Chocolatey installed."
    }
    else {
        Write-Status OK "Chocolatey already installed."
    }
    Set-ChocolateySource
}

function Install-ChocoPackage {
    <#
    .SYNOPSIS
        Installs a chocolatey package using Invoke-CommandVerbose so every line
        of choco output (download progress, install steps, etc.) is visible.
    #>
    param(
        [Parameter(Mandatory)][string]$PackageName,
        [string]$DisplayName
    )
    if (-not $DisplayName) { $DisplayName = $PackageName }
    $chocoExe = Get-ChocoExePath
    if (-not $chocoExe) {
        Write-Status ERROR "Chocolatey executable not found."
        return $false
    }

    Write-SubBanner "Installing $DisplayName via Chocolatey"
    Write-Status INFO "Source: $($Script:ChocoSourceName) ($($Script:ChocoSourceUrl))"
    Write-Host ""

    # Try custom source first
    $chocoArgs = "install $PackageName -y --source=`"$($Script:ChocoSourceName)`""
    $exitCode = Invoke-CommandVerbose -FilePath $chocoExe -Arguments $chocoArgs -Label "CHOCO"

    if ($exitCode -ne 0) {
        Write-Status WARN "Install from custom source returned $exitCode - trying default sources..."
        $chocoArgs = "install $PackageName -y"
        $exitCode = Invoke-CommandVerbose -FilePath $chocoExe -Arguments $chocoArgs -Label "CHOCO"
    }

    if ($exitCode -eq 0) {
        Write-Status OK "$DisplayName installed successfully."
        return $true
    }
    else {
        Write-Status ERROR "$DisplayName installation failed (exit $exitCode)."
        return $false
    }
}

#===================================================================
#  DELL UPDATE LOGIC  (fully verbose - no spinners)
#===================================================================
function Invoke-DellUpdates {
    param([pscustomobject]$State)
    Write-Banner "DELL SYSTEM UPDATE"

    # Locate dcu-cli.exe
    $cli = @(
        'C:\Program Files\Dell\CommandUpdate\dcu-cli.exe',
        'C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $cli) {
        $installed = Install-ChocoPackage -PackageName "dellcommandupdate" -DisplayName "Dell Command Update"
        if ($installed) { Start-Sleep -Seconds 5 }
        $cli = @(
            'C:\Program Files\Dell\CommandUpdate\dcu-cli.exe',
            'C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe'
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    }

    if (-not $cli) {
        Write-Status ERROR "Dell Command Update CLI still missing - aborting Dell section."
        return $false
    }

    Write-Status OK "Dell CLI located: $cli"
    Write-Host ""

    switch ($State.ManufacturerPhase) {
        0 {
            # --- Phase-0: Advanced Driver Restore ---
            if ($State.DellADRFailed) {
                Write-Status WARN "ADR previously failed - skipping to phase-2."
                $State.ManufacturerPhase = 2
                Set-ScriptState -State $State
                return (Invoke-DellUpdates -State $State)
            }

            Write-SubBanner "Dell Phase-0: Configuring ADR"
            Write-Status INFO "Enabling Advanced Driver Restore..."
            $configExit = Invoke-CommandVerbose -FilePath $cli -Arguments "/configure -advancedDriverRestore=enable" -Label "DCU-CFG"
            Write-Host ""

            Write-SubBanner "Dell Phase-0: ADR Driver Install"
            Write-Status STEP "This will download and install drivers matching your Dell system."
            Write-Status STEP "All progress and driver names will be displayed below."
            Write-Host ""
            $dellExit = Invoke-CommandVerbose -FilePath $cli -Arguments "/driverinstall" -Label "DCU"

            switch ($dellExit) {
                0 {
                    Write-Status OK "ADR driver install succeeded."
                    $State.ManufacturerPhase = 2
                    Set-ScriptState -State $State
                    return (Invoke-DellUpdates -State $State)
                }
                1 {
                    Write-Status WARN "Drivers installed - reboot required."
                    $State.ManufacturerPhase = 1
                    Schedule-RebootAndContinue -State $State -Reason "Dell ADR driver install (exit 1) requires reboot"
                }
                5 {
                    Write-Status WARN "Reboot required to complete operation."
                    $State.ManufacturerPhase = 1
                    Schedule-RebootAndContinue -State $State -Reason "Dell ADR driver install (exit 5) requires reboot"
                }
                2 {
                    Write-Status ERROR "ADR crashed - marking as failed, skipping to updates."
                    $State.DellADRFailed = $true
                    $State.ManufacturerPhase = 2
                    Set-ScriptState -State $State
                    return (Invoke-DellUpdates -State $State)
                }
                3 {
                    Write-Status OK "All drivers already up to date."
                    $State.ManufacturerPhase = 2
                    Set-ScriptState -State $State
                    return (Invoke-DellUpdates -State $State)
                }
                default {
                    Write-Status ERROR "ADR returned $dellExit - skipping to phase-2."
                    $State.DellADRFailed = $true
                    $State.ManufacturerPhase = 2
                    Set-ScriptState -State $State
                    return (Invoke-DellUpdates -State $State)
                }
            }
        }
        1 {
            # --- Phase-1: Post-reboot scan ---
            Write-SubBanner "Dell Phase-1: Post-Reboot Scan"
            Write-Status INFO "Scanning for remaining Dell drivers after reboot..."
            Write-Host ""
            $null = Invoke-CommandVerbose -FilePath $cli -Arguments "/scan" -Label "DCU"
            $State.ManufacturerPhase = 2
            Set-ScriptState -State $State
            return (Invoke-DellUpdates -State $State)
        }
        2 {
            # --- Phase-2: Apply all updates ---
            Write-SubBanner "Dell Phase-2: Apply BIOS / Firmware / Driver Updates"
            Write-Status STEP "Downloading and installing all available Dell updates."
            Write-Status STEP "Each update name, download progress, and install status shown below."
            Write-Host ""
            $dellExit = Invoke-CommandVerbose -FilePath $cli -Arguments "/applyupdates -forceUpdate=enable -autoSuspendBitLocker=enable" -Label "DCU"

            switch ($dellExit) {
                0 {
                    Write-Status OK "All Dell updates applied successfully."
                    $State.ManufacturerPhase = 3
                    Set-ScriptState -State $State
                    return $true
                }
                1 {
                    Write-Status WARN "Updates applied - reboot required."
                    $State.ManufacturerPhase = 3
                    Schedule-RebootAndContinue -State $State -Reason "Dell updates (exit 1) require reboot"
                }
                5 {
                    Write-Status WARN "Reboot required to finish updates."
                    $State.ManufacturerPhase = 3
                    Schedule-RebootAndContinue -State $State -Reason "Dell updates (exit 5) require reboot"
                }
                3 {
                    Write-Status OK "System already up to date."
                    $State.ManufacturerPhase = 3
                    Set-ScriptState -State $State
                    return $true
                }
                default {
                    Write-Status WARN "Apply-updates returned $dellExit - continuing."
                    $State.ManufacturerPhase = 3
                    Set-ScriptState -State $State
                    return $true
                }
            }
        }
        default {
            Write-Status OK "Dell updates already completed."
            return $true
        }
    }
    return $true
}

#===================================================================
#  HP UPDATE LOGIC  (fully verbose - no spinners)
#===================================================================
function Invoke-HPUpdates {
    param([pscustomobject]$State)
    Write-Banner "HP SYSTEM UPDATE"

    $hpiaPaths = @(
        'C:\HP\HPIA\HPImageAssistant.exe',
        'C:\Program Files\HP\HPIA\HPImageAssistant.exe',
        'C:\Program Files (x86)\HP\HPIA\HPImageAssistant.exe'
    )
    $hpia = $hpiaPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $hpia) {
        $installed = Install-ChocoPackage -PackageName "hpimageassistant" -DisplayName "HP Image Assistant"
        if ($installed) { Start-Sleep -Seconds 5 }
        $hpia = $hpiaPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    }

    if (-not $hpia) {
        Write-Status ERROR "HP Image Assistant still missing - aborting HP section."
        return $false
    }

    Write-Status OK "HP Image Assistant located: $hpia"
    Write-Host ""

    Write-SubBanner "HP Image Assistant: Analyze & Install All Updates"
    Write-Status STEP "Scanning for BIOS, firmware, driver, and software updates."
    Write-Status STEP "Each update name and install progress will be displayed below."
    Write-Host ""

    $hpiaArgs = "/Operation:Analyze /Action:Install /Selection:All /Silent /Noninteractive /ReportFolder:C:\Temp\HPIA"
    $hpExit = Invoke-CommandVerbose -FilePath $hpia -Arguments $hpiaArgs -Label "HPIA"

    switch ($hpExit) {
        0    { Write-Status OK "HP updates completed successfully."; return $true }
        256  { Write-Status WARN "HP updates require reboot (exit $hpExit)."; return $true }
        3010 { Write-Status WARN "HP updates require reboot (exit $hpExit)."; return $true }
        default {
            Write-Status WARN "HP updates returned $hpExit - continuing."
            return $true
        }
    }
}

#===================================================================
#  MAIN EXECUTION
#===================================================================
try {
    if (-not (Initialize-PersistentScript)) {
        throw "Failed to initialise persistent script."
    }
    Start-Transcript -Path $Script:LogFile -Append -Force
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "       DRIVER UPDATE SCRIPT - PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "  User:       $env:USERNAME" -ForegroundColor Cyan
    Write-Host "  Computer:   $env:COMPUTERNAME" -ForegroundColor Cyan
    Write-Host "  PID:        $PID" -ForegroundColor Cyan
    Write-Host "  Time:       $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    Write-Host "  Script:     $Script:PersistentScript" -ForegroundColor Cyan
    Write-Host "  Timeout:    $Script:DriverTimeout seconds per driver" -ForegroundColor Cyan
    Write-Host "  ChocoSrc:   $Script:ChocoSourceName -> $Script:ChocoSourceUrl" -ForegroundColor Cyan
    Write-Host "  Mode:       TARGETED (device-matched) + VERBOSE output" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Status INFO "Checking for orphan driver processes..."
    $orphanKilled = Stop-DriverInstallProcesses -Silent
    if ($orphanKilled -gt 0) {
        Write-Status WARN "Terminated $orphanKilled leftover processes."
        Start-Sleep -Seconds 2
    }
    $state = Get-ScriptState
    Write-Host "----------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  CURRENT STATE" -ForegroundColor DarkGray
    Write-Host "----------------------------------------------------------------------" -ForegroundColor DarkGray
    foreach ($prop in $state.PSObject.Properties) {
        Write-Host ("  {0,-25}: {1}" -f $prop.Name, $prop.Value) -ForegroundColor DarkGray
    }
    Write-Host "----------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""

    # PHASE-0: Ventoy offline drivers
    if ($state.Phase -eq 0) {
        if (-not $state.VentoyCompleted) {
            $ventoyResult = Install-VentoyDrivers -State $state
            $state.TotalDriversAdded = $ventoyResult.TotalAdded
            $state.TotalDriversInstalled = $ventoyResult.TotalInstalled
            $state.TotalDriversSkipped = $ventoyResult.TotalSkippedNoMatch
            $state.TotalDriversTimedOut = $ventoyResult.TotalTimedOut
            $state.TotalProcessesKilled = $ventoyResult.TotalKilled
            $state.TotalTimeSpent = $ventoyResult.TotalTime
            if ($ventoyResult.NotFound) {
                Write-Status INFO "No Ventoy drivers - moving to online phase."
                $state.VentoyCompleted = $true; $state.Phase = 1
                Set-ScriptState -State $state
            }
            elseif ($ventoyResult.NeedsReboot) {
                Write-Status STEP "Ventoy driver install requires reboot."
                $state.VentoyCompleted = $true; $state.VentoyRebootDone = $false
                Set-ScriptState -State $state
                Schedule-RebootAndContinue -State $state -Reason "Ventoy driver install - reboot required"
            }
            else {
                Write-Status OK "Ventoy drivers installed - no reboot needed."
                $state.VentoyCompleted = $true; $state.Phase = 1
                Set-ScriptState -State $state
            }
        }
        else {
            Write-Status OK "Post-reboot: Ventoy driver installation finalized."
            $state.VentoyRebootDone = $true; $state.Phase = 1
            Set-ScriptState -State $state
        }
    }

    # PHASE-1: Online updates
    if ($state.Phase -ge 1) {
        Write-Banner "PHASE 1: ONLINE UPDATES"
        if (-not (Test-InternetConnectivity -MaxRetries 15 -RetryDelay 10)) {
            Write-Status ERROR "No internet - cannot continue."
            Write-Status INFO "Connect to a network and re-run the script."
            try { Stop-Transcript } catch { }
            exit 1
        }
        Install-ChocolateyIfNeeded
        $manufacturer = Get-SystemManufacturer
        if ($manufacturer -like '*Dell*') {
            Invoke-DellUpdates -State $state | Out-Null
        }
        elseif ($manufacturer -match 'HP|Hewlett[-\s]?Packard') {
            Invoke-HPUpdates -State $state | Out-Null
        }
        else {
            Write-Status WARN "Unsupported manufacturer: $manufacturer - only Dell and HP are handled."
        }
    }

    # FINAL CLEAN-UP
    Write-Status INFO "Final clean-up - terminating any remaining driver processes."
    Stop-DriverInstallProcesses -Silent | Out-Null
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Green
    Write-Host "      DRIVER UPDATE SCRIPT COMPLETED SUCCESSFULLY!" -ForegroundColor Green
    Write-Host "======================================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Total reboots:          $($state.RebootCount)" -ForegroundColor White
    Write-Host "  Drivers added:          $($state.TotalDriversAdded)" -ForegroundColor White
    Write-Host "  Drivers installed:      $($state.TotalDriversInstalled)" -ForegroundColor White
    Write-Host "  Drivers skipped:        $($state.TotalDriversSkipped)" -ForegroundColor White
    Write-Host "  Drivers failed:         $($state.TotalDriversFailed)" -ForegroundColor White
    Write-Host "  Drivers timed out:      $($state.TotalDriversTimedOut)" -ForegroundColor White
    Write-Host "  Processes killed:       $($state.TotalProcessesKilled)" -ForegroundColor White
    Write-Host "  Total time spent:       $(Format-Duration $state.TotalTimeSpent)" -ForegroundColor White
    Write-Host "  Dell ADR failed:        $($state.DellADRFailed)" -ForegroundColor White
    Write-Host "  Choco source:           $($Script:ChocoSourceName)" -ForegroundColor White
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Green
    Write-Host ""
    Remove-ScriptState
}
catch {
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Red
    Write-Host "  SCRIPT ERROR" -ForegroundColor Red
    Write-Host "======================================================================" -ForegroundColor Red
    Write-Status ERROR "Message: $($_.Exception.Message)"
    Write-Status ERROR "Line:    $($_.InvocationInfo.ScriptLineNumber)"
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    Write-Host ""
    Write-Status INFO "Attempting emergency clean-up..."
    try {
        $saveEA = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        Stop-DriverInstallProcesses -Silent | Out-Null
        $ErrorActionPreference = $saveEA
    }
    catch { try { $ErrorActionPreference = $saveEA } catch { } }
    Write-Status INFO "State file kept - re-run script to continue."
}
finally {
    try { Stop-Transcript } catch { }
}