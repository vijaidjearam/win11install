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
$Script:NetworkShareBase    = '\\networkshare'
$Script:ShareDriverFolder   = 'driver'
$Script:ManufacturerShareMap = @{
    'Dell'             = 'dell'
    'Dell Inc.'        = 'dell'
    'HP'               = 'hp'
    'Hewlett-Packard'  = 'hp'
}
$Script:USBDriverFolders = @('DriversOS','Drivers')

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
    if ($Seconds -lt 60) { return "{0:N1}s" -f $Seconds }
    elseif ($Seconds -lt 3600) {
        $m = [math]::Floor($Seconds / 60); $s = $Seconds % 60
        return "{0}m {1:N0}s" -f $m, $s
    }
    else {
        $h = [math]::Floor($Seconds / 3600); $m = [math]::Floor(($Seconds % 3600) / 60)
        return "{0}h {1}m" -f $h, $m
    }
}

function Get-ConsoleWidth {
    $w = 100
    try { $w = [Console]::WindowWidth - 5; if ($w -lt 50) { $w = 100 } } catch { }
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
    Write-Host "  Timeout: $Script:DriverTimeout seconds" -ForegroundColor DarkGray
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
                    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
                } catch { }
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
        catch { try { $ErrorActionPreference = $saveEA } catch { } }
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
#  VERBOSE COMMAND EXECUTION
#===================================================================
function Invoke-CommandVerbose {
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
    try { $null = $process.Start() }
    catch {
        Write-Status ERROR "Failed to start $exeName : $($_.Exception.Message)"
        return 999
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastActivity = [System.Diagnostics.Stopwatch]::StartNew()
    $heartbeatSec = 30
    $logLines = [System.Collections.ArrayList]::new()
    $stdoutTask = $process.StandardOutput.ReadLineAsync()
    $stderrTask = $process.StandardError.ReadLineAsync()
    $stdoutDone = $false
    $stderrDone = $false
    while ((-not $stdoutDone) -or (-not $stderrDone)) {
        $activity = $false
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
                $activity = $true; $lastActivity.Restart()
            }
            else { $stdoutDone = $true }
        }
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
                $activity = $true; $lastActivity.Restart()
            }
            else { $stderrDone = $true }
        }
        if ((-not $activity) -and ($lastActivity.Elapsed.TotalSeconds -ge $heartbeatSec)) {
            $ts = Get-Date -Format 'HH:mm:ss'
            $elapsed = [math]::Round($sw.Elapsed.TotalSeconds)
            Write-Host "  [$ts] [$Label] ... still running (${elapsed}s elapsed)" -ForegroundColor DarkGray
            [void]$logLines.Add("[$ts] [heartbeat] ${elapsed}s elapsed")
            $lastActivity.Restart()
        }
        if (-not $activity) { Start-Sleep -Milliseconds 100 }
    }
    $process.WaitForExit()
    $sw.Stop()
    $exitCode = $process.ExitCode
    $safeLabel = $Label -replace '[^a-zA-Z0-9]', '_'
    $logFile = Join-Path $Script:TempFolder "${safeLabel}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    try {
        $header = "Command : $FilePath $Arguments`nExit    : $exitCode`nDuration: $(Format-Duration $sw.Elapsed.TotalSeconds)`n$('=' * 60)`n"
        $body = ($logLines | ForEach-Object { $_ }) -join "`n"
        "$header$body" | Out-File $logFile -Encoding UTF8 -Force
    } catch { }
    Write-Host ""
    Write-Status TIME "Completed in $(Format-Duration $sw.Elapsed.TotalSeconds)"
    Write-Status INFO "Exit code: $exitCode"
    Write-Status DEBUG "Log: $logFile"
    try { $process.Dispose() } catch { }
    return $exitCode
}

function Get-ChocoExePath {
    $cmd = Get-Command choco -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }
    $default = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (Test-Path $default) { return $default }
    return $null
}

#===================================================================
#  SMB GUEST AUTH & SIGNING FIX (Windows 11 GPO workaround)
#===================================================================
function Enable-GuestNetworkAccess {
    <#
    .SYNOPSIS
        Configures Windows to allow insecure guest authentication and disables
        SMB digital signature requirements. Required on Windows 11 to access
        network shares that allow guest/anonymous access.

    .DESCRIPTION
        Windows 11 blocks guest logins to SMB shares by default via GPO.
        This function:
        1. Creates the LanmanWorkstation policy key if missing
        2. Sets AllowInsecureGuestAuth = 1 (policy level)
        3. Sets AllowInsecureGuestAuth = 1 (service parameter level)
        4. Disables RequireSecuritySignature (digitally sign always)
        5. Disables EnableSecuritySignature (digitally sign if server agrees)
        6. Restarts the LanmanWorkstation service to apply changes immediately
    #>

    Write-SubBanner "Configuring SMB Guest Access & Signing"
    Write-Status INFO "Windows 11 blocks guest SMB access by default."
    Write-Status INFO "Applying registry fixes for network share access..."
    Write-Host ""

    $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation'
    $servicePath = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters'
    $changes = 0

    # --- Step 1: Create policy key if it doesn't exist ---
    if (-not (Test-Path $policyPath)) {
        Write-Status INFO "Creating policy key: $policyPath"
        try {
            New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows' -Name 'LanmanWorkstation' -Force | Out-Null
            Write-Status OK "Policy key created."
            $changes++
        }
        catch {
            Write-Status ERROR "Failed to create policy key: $($_.Exception.Message)"
        }
    }
    else {
        Write-Status OK "Policy key already exists."
    }

    # --- Step 2: AllowInsecureGuestAuth at POLICY level ---
    Write-Status INFO "Setting AllowInsecureGuestAuth = 1 (policy level)..."
    try {
        $currentVal = $null
        try { $currentVal = Get-ItemPropertyValue -Path $policyPath -Name 'AllowInsecureGuestAuth' -ErrorAction SilentlyContinue } catch { }
        if ($currentVal -eq 1) {
            Write-Status OK "AllowInsecureGuestAuth (policy) already set to 1."
        }
        else {
            Set-ItemProperty -Path $policyPath -Name 'AllowInsecureGuestAuth' -Value 1 -Type DWord -Force
            Write-Status OK "AllowInsecureGuestAuth (policy) set to 1."
            $changes++
        }
    }
    catch {
        Write-Status ERROR "Failed to set policy AllowInsecureGuestAuth: $($_.Exception.Message)"
    }

    # --- Step 3: AllowInsecureGuestAuth at SERVICE level ---
    Write-Status INFO "Setting AllowInsecureGuestAuth = 1 (service parameters)..."
    try {
        $currentVal = $null
        try { $currentVal = Get-ItemPropertyValue -Path $servicePath -Name 'AllowInsecureGuestAuth' -ErrorAction SilentlyContinue } catch { }
        if ($currentVal -eq 1) {
            Write-Status OK "AllowInsecureGuestAuth (service) already set to 1."
        }
        else {
            Set-ItemProperty -Path $servicePath -Name 'AllowInsecureGuestAuth' -Value 1 -Type DWord -Force
            Write-Status OK "AllowInsecureGuestAuth (service) set to 1."
            $changes++
        }
    }
    catch {
        Write-Status ERROR "Failed to set service AllowInsecureGuestAuth: $($_.Exception.Message)"
    }

    # --- Step 4: Disable RequireSecuritySignature (digitally sign always) ---
    Write-Status INFO "Disabling 'Digitally sign communications (always)'..."
    try {
        $currentVal = $null
        try { $currentVal = Get-ItemPropertyValue -Path $servicePath -Name 'RequireSecuritySignature' -ErrorAction SilentlyContinue } catch { }
        if ($currentVal -eq 0) {
            Write-Status OK "RequireSecuritySignature already disabled."
        }
        else {
            Set-ItemProperty -Path $servicePath -Name 'RequireSecuritySignature' -Value 0 -Type DWord -Force
            Write-Status OK "RequireSecuritySignature disabled."
            $changes++
        }
    }
    catch {
        Write-Status ERROR "Failed to disable RequireSecuritySignature: $($_.Exception.Message)"
    }

    # --- Step 5: Disable EnableSecuritySignature (digitally sign if server agrees) ---
    Write-Status INFO "Disabling 'Digitally sign communications (if server agrees)'..."
    try {
        $currentVal = $null
        try { $currentVal = Get-ItemPropertyValue -Path $servicePath -Name 'EnableSecuritySignature' -ErrorAction SilentlyContinue } catch { }
        if ($currentVal -eq 0) {
            Write-Status OK "EnableSecuritySignature already disabled."
        }
        else {
            Set-ItemProperty -Path $servicePath -Name 'EnableSecuritySignature' -Value 0 -Type DWord -Force
            Write-Status OK "EnableSecuritySignature disabled."
            $changes++
        }
    }
    catch {
        Write-Status ERROR "Failed to disable EnableSecuritySignature: $($_.Exception.Message)"
    }

    # --- Step 6: Restart LanmanWorkstation service if changes were made ---
    if ($changes -gt 0) {
        Write-Status INFO "Restarting LanmanWorkstation service to apply $changes change(s)..."
        try {
            # LanmanWorkstation has dependent services - restart with dependencies
            $saveEA = $ErrorActionPreference
            $ErrorActionPreference = 'SilentlyContinue'
            $null = cmd.exe /c "net stop LanmanWorkstation /y >nul 2>&1"
            Start-Sleep -Seconds 2
            $null = cmd.exe /c "net start LanmanWorkstation >nul 2>&1"
            # Also restart dependent services that may have stopped
            $null = cmd.exe /c "net start LanmanServer >nul 2>&1"
            $null = cmd.exe /c "net start Netlogon >nul 2>&1"
            $ErrorActionPreference = $saveEA
            Start-Sleep -Seconds 3
            Write-Status OK "LanmanWorkstation service restarted."
        }
        catch {
            try { $ErrorActionPreference = $saveEA } catch { }
            Write-Status WARN "Service restart may have partially failed - changes may require reboot."
        }
    }
    else {
        Write-Status OK "No changes needed - all SMB settings already configured."
    }

    # --- Summary ---
    Write-Host ""
    Write-Host "  ======================================================================" -ForegroundColor DarkCyan
    Write-Host "              SMB GUEST ACCESS CONFIGURATION SUMMARY" -ForegroundColor Cyan
    Write-Host "  ======================================================================" -ForegroundColor DarkCyan

    # Read back current values for confirmation
    $readBack = @(
        @{ Name = 'AllowInsecureGuestAuth (policy)';  Path = $policyPath;  Key = 'AllowInsecureGuestAuth'; Expected = 1 }
        @{ Name = 'AllowInsecureGuestAuth (service)'; Path = $servicePath; Key = 'AllowInsecureGuestAuth'; Expected = 1 }
        @{ Name = 'RequireSecuritySignature';         Path = $servicePath; Key = 'RequireSecuritySignature'; Expected = 0 }
        @{ Name = 'EnableSecuritySignature';          Path = $servicePath; Key = 'EnableSecuritySignature'; Expected = 0 }
    )
    foreach ($item in $readBack) {
        $val = $null
        try { $val = Get-ItemPropertyValue -Path $item.Path -Name $item.Key -ErrorAction SilentlyContinue } catch { }
        $valStr = if ($null -ne $val) { $val.ToString() } else { 'NOT SET' }
        $match = ($val -eq $item.Expected)
        $statusColor = if ($match) { 'Green' } else { 'Red' }
        $statusIcon = if ($match) { 'OK' } else { 'FAIL' }
        Write-Host "  [$statusIcon] $($item.Name): $valStr (expected: $($item.Expected))" -ForegroundColor $statusColor
    }

    Write-Host "  Changes applied: $changes" -ForegroundColor White
    Write-Host "  ======================================================================" -ForegroundColor DarkCyan
    Write-Host ""

    return ($changes -ge 0)
}

#===================================================================
#  SYSTEM MODEL & NETWORK SHARE PATH HELPERS
#===================================================================
function Get-SystemInfo {
    $cs = Get-CimInstance Win32_ComputerSystem
    $rawManufacturer = $cs.Manufacturer.Trim()
    $rawModel = $cs.Model.Trim()
    $cleanModel = ($rawModel -replace '\s', '').ToLower()
    return [PSCustomObject]@{
        RawManufacturer = $rawManufacturer
        RawModel        = $rawModel
        CleanModel      = $cleanModel
    }
}

function Get-ManufacturerShareFolder {
    param([Parameter(Mandatory)][string]$Manufacturer)
    foreach ($key in $Script:ManufacturerShareMap.Keys) {
        if ($Manufacturer -like "*$key*") {
            return $Script:ManufacturerShareMap[$key]
        }
    }
    return ($Manufacturer -replace '\s', '').ToLower()
}

function Build-NetworkDriverPath {
    param(
        [Parameter(Mandatory)][string]$ManufacturerFolder,
        [Parameter(Mandatory)][string]$CleanModel
    )
    $path = Join-Path $Script:NetworkShareBase $ManufacturerFolder
    $path = Join-Path $path $Script:ShareDriverFolder
    $path = Join-Path $path $CleanModel
    return $path
}

function Test-NetworkShareAccess {
    param(
        [Parameter(Mandatory)][string]$SharePath,
        [int]$MaxRetries = 10,
        [int]$RetryDelaySec = 10
    )
    Write-Status INFO "Testing access to: $SharePath"
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            if (Test-Path $SharePath -ErrorAction Stop) {
                Write-Status OK "Network share accessible: $SharePath"
                return $true
            }
        }
        catch { }
        if ($i -lt $MaxRetries) {
            Write-Status WARN "Attempt $i/$MaxRetries failed - waiting ${RetryDelaySec}s..."
            Start-Sleep -Seconds $RetryDelaySec
        }
    }
    Write-Status ERROR "Network share not accessible after $MaxRetries attempts: $SharePath"
    return $false
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
                foreach ($hwid in @($dev.HardwareID)) { if ($hwid) { [void]$ids.Add($hwid) } }
            }
            if ($null -ne $dev.CompatibleID) {
                foreach ($cid in @($dev.CompatibleID)) { if ($cid) { [void]$ids.Add($cid) } }
            }
            if ($null -ne $dev.ConfigManagerErrorCode -and $dev.ConfigManagerErrorCode -ne 0) {
                $devName = $dev.Name
                if (-not $devName) { $devName = $dev.DeviceID }
                [void]$problemDeviceNames.Add("$devName (error $($dev.ConfigManagerErrorCode))")
            }
        }
    }
    catch { Write-Status WARN "WMI device scan failed: $($_.Exception.Message)" }
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
                } catch { }
                try {
                    $cProp = $dev | Get-PnpDeviceProperty -KeyName 'DEVPKEY_Device_CompatibleIds' -ErrorAction SilentlyContinue
                    if ($null -ne $cProp -and $null -ne $cProp.Data) {
                        foreach ($id in @($cProp.Data)) { if ($id) { [void]$ids.Add($id) } }
                    }
                } catch { }
            }
        }
        catch { Write-Status WARN "Get-PnpDevice fallback also failed." }
    }
    Write-Status OK "Scanned $deviceCount device(s), found $($ids.Count) unique hardware/compatible ID(s)."
    $probCount = ($problemDeviceNames | Measure-Object).Count
    if ($probCount -gt 0) {
        Write-Status WARN "$probCount device(s) with problems:"
        foreach ($pd in $problemDeviceNames) { Write-Status INFO "  - $pd" }
    }
    else { Write-Status OK "No devices with driver problems detected." }
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
                Phase = 0; USBCompleted = $false; USBRebootDone = $false
                NetworkShareCompleted = $false; NetworkShareRebootDone = $false
                NetworkSharePath = ""; NetworkShareProcessedDrivers = @()
                USBProcessedDrivers = @(); USBDriverRoot = ""
                ManufacturerPhase = 0; DellADRFailed = $false; LastExitCode = 0
                RebootCount = 0; TotalDriversAdded = 0; TotalDriversInstalled = 0
                TotalDriversFailed = 0; TotalDriversSkipped = 0
                TotalDriversTimedOut = 0; TotalTimeSpent = 0; TotalProcessesKilled = 0
                SystemManufacturer = ""; SystemModel = ""; CleanModel = ""
                GuestAuthConfigured = $false
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
        Phase = 0; USBCompleted = $false; USBRebootDone = $false
        NetworkShareCompleted = $false; NetworkShareRebootDone = $false
        NetworkSharePath = ""; NetworkShareProcessedDrivers = @()
        USBProcessedDrivers = @(); USBDriverRoot = ""
        ManufacturerPhase = 0; DellADRFailed = $false; LastExitCode = 0
        RebootCount = 0; TotalDriversAdded = 0; TotalDriversInstalled = 0
        TotalDriversFailed = 0; TotalDriversSkipped = 0
        TotalDriversTimedOut = 0; TotalTimeSpent = 0; TotalProcessesKilled = 0
        SystemManufacturer = ""; SystemModel = ""; CleanModel = ""
        GuestAuthConfigured = $false
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
    } catch { }
    $fallback = "$($Script:RunOnceName)_Task"
    try {
        $existingTask = Get-ScheduledTask -TaskName $fallback -ErrorAction SilentlyContinue
        if ($null -ne $existingTask) {
            Unregister-ScheduledTask -TaskName $fallback -Confirm:$false -ErrorAction SilentlyContinue
        }
    } catch { }
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
        Write-Status OK "RunOnce entry created: $Name"
        return $true
    }
    catch {
        Write-Status WARN "Failed to write RunOnce: $($_.Exception.Message)"
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
        Write-Status OK "Fallback task created: $Name"
        return $true
    }
    catch {
        Write-Status ERROR "Could not create fallback task: $($_.Exception.Message)"
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
    Write-Host "======================================================================" -ForegroundColor Yellow
    Write-Host ""
    Stop-DriverInstallProcesses -Silent | Out-Null
    $State.RebootCount++
    Set-ScriptState -State $State
    $cmd = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script:PersistentScript`""
    $ok = Set-RunOnceEntry -Name $Script:RunOnceName -Command $cmd
    if (-not $ok) { Set-RunOnceTask -Name "$($Script:RunOnceName)_Task" -ScriptPath $Script:PersistentScript | Out-Null }
    for ($i = 15; $i -ge 1; $i--) {
        Write-Host "  Rebooting in $i seconds..." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
    Write-Host "  Rebooting NOW!" -ForegroundColor Red
    try { Stop-Transcript } catch { }
    Restart-Computer -Force
    exit 0
}

#===================================================================
#  DRIVER INSTALLATION (single driver)
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
    Write-Status INFO "Starting installation..."
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
        $result.TimedOut = $true; $result.ErrorMessage = "Timeout"
        $killed = Stop-DriverInstallProcesses
        $result.ProcessesKilled = $killed
        $null = Wait-ForDriverProcesses -TimeoutSeconds 10
        Remove-Item $tempScript, $outFile, $exitFile -Force -ErrorAction SilentlyContinue
        if ($Script:CooldownSeconds -gt 0) { Start-Sleep -Seconds $Script:CooldownSeconds }
        return $result
    }
    $out = ""; $exit = -1
    if (Test-Path $outFile) { $out = Get-Content $outFile -Raw -ErrorAction SilentlyContinue }
    if (Test-Path $exitFile) {
        $raw = Get-Content $exitFile -Raw -ErrorAction SilentlyContinue
        if ($null -ne $raw) { [int]::TryParse($raw.Trim(), [ref]$exit) | Out-Null }
    }
    Remove-Item $tempScript, $outFile, $exitFile -Force -ErrorAction SilentlyContinue
    $result.ExitCode = $exit; $result.Output = $out
    if ($null -ne $out) {
        if ($out -match 'added|successfully added|driver package added') { $result.Added = $true; Write-Status OK "Driver added to store" }
        if ($out -match 'install.*device|installed to device') { $result.Installed = $true; Write-Status OK "Driver installed on device" }
        if ($out -match 'already exists|up to date') { $result.AlreadyExists = $true; Write-Status INFO "Already up-to-date" }
        if ($out -match 'reboot|restart') { $result.NeedsReboot = $true; Write-Status WARN "Reboot required" }
    }
    switch ($exit) {
        0    { $result.Success = $true; Write-Status OK "Exit 0 - Success" }
        1    { $result.Success = $true; Write-Status INFO "Exit 1 - Warnings" }
        259  { $result.Success = $true; Write-Status INFO "Exit 259 - Staged" }
        3010 { $result.Success = $true; $result.NeedsReboot = $true; Write-Status WARN "Exit 3010 - Reboot" }
        482  { $result.Success = $true; $result.NeedsReboot = $true; Write-Status WARN "Exit 482 - Partial" }
        default {
            if ($exit -ge 0) {
                if ($result.Added -or $result.Installed -or $result.AlreadyExists) { $result.Success = $true }
                else { $result.Success = $false; $result.ErrorMessage = "Exit $exit"; Write-Status ERROR "Exit $exit" }
            } else { $result.Success = $true }
        }
    }
    Write-Status TIME "Time: $(Format-Duration $result.Duration)"
    if ($Script:CooldownSeconds -gt 0) { Start-Sleep -Seconds $Script:CooldownSeconds }
    return $result
}

#===================================================================
#  GENERIC DRIVER FOLDER INSTALLER
#===================================================================
function Install-DriversFromFolder {
    param(
        [Parameter(Mandatory)][string]$DriverRoot,
        [Parameter(Mandatory)][string]$Label,
        [string[]]$ProcessedList = @(),
        [switch]$SkipDeviceMatching,
        [System.Collections.Generic.HashSet[string]]$SystemIds = $null
    )
    $result = [PSCustomObject]@{
        Success = $false; NeedsReboot = $false; NotFound = $false
        TotalFound = 0; TotalMatched = 0; TotalSkippedNoMatch = 0
        TotalAdded = 0; TotalInstalled = 0; TotalFailed = 0
        TotalAlreadyExist = 0; TotalTimedOut = 0; TotalTime = 0; TotalKilled = 0
        ProcessedDrivers = @($ProcessedList)
    }
    $allInfFiles = @(Get-ChildItem -Path $DriverRoot -Filter "*.inf" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName)
    $totalFound = ($allInfFiles | Measure-Object).Count
    if ($totalFound -eq 0) {
        Write-Status WARN "No .inf files in: $DriverRoot"
        $result.NotFound = $true; $result.Success = $true; return $result
    }
    $result.TotalFound = $totalFound
    Write-Status OK "Found $totalFound INF file(s) in: $DriverRoot"
    $processed = @($ProcessedList)
    $processedCount = ($processed | Measure-Object).Count
    if ($processedCount -gt 0) { Write-Status INFO "$processedCount already processed." }
    $matchedInfs = [System.Collections.ArrayList]::new()
    $skippedNoMatch = [System.Collections.ArrayList]::new()
    if ($SkipDeviceMatching) {
        Write-Status INFO "Device matching DISABLED - installing ALL drivers."
        foreach ($inf in $allInfFiles) { [void]$matchedInfs.Add($inf) }
    }
    else {
        if ($null -eq $SystemIds -or $SystemIds.Count -eq 0) {
            Write-SubBanner "Scanning System Devices"
            $SystemIds = Get-SystemDeviceIds
        }
        if ($SystemIds.Count -eq 0) {
            Write-Status WARN "No device IDs - installing ALL as fallback."
            foreach ($inf in $allInfFiles) { [void]$matchedInfs.Add($inf) }
        }
        else {
            Write-SubBanner "Matching $Label Drivers to Devices"
            foreach ($inf in $allInfFiles) {
                $rel = $inf.FullName.Substring($DriverRoot.Length + 1)
                if ($rel -in $processed) { continue }
                if (Test-InfMatchesSystem -InfPath $inf.FullName -SystemIds $SystemIds) { [void]$matchedInfs.Add($inf) }
                else { [void]$skippedNoMatch.Add($inf); Write-Status SKIP "No match: $rel" }
            }
        }
    }
    $matchedCount = ($matchedInfs | Measure-Object).Count
    $skippedNoMatchCount = ($skippedNoMatch | Measure-Object).Count
    $result.TotalMatched = $matchedCount; $result.TotalSkippedNoMatch = $skippedNoMatchCount
    Write-Host ""
    Write-Host "  ======================================================================" -ForegroundColor DarkCyan
    Write-Host "              $Label - MATCHING RESULTS" -ForegroundColor Cyan
    Write-Host "  ======================================================================" -ForegroundColor DarkCyan
    Write-Host "  Total INFs:                   $totalFound" -ForegroundColor White
    Write-Host "  Already processed:            $processedCount" -ForegroundColor DarkGray
    Write-Host "  Matched to devices:           $matchedCount" -ForegroundColor Green
    Write-Host "  Skipped (no match):           $skippedNoMatchCount" -ForegroundColor Yellow
    $modeLabel = if ($SkipDeviceMatching) { "ALL (no filtering)" } else { "TARGETED" }
    $modeColor = if ($SkipDeviceMatching) { 'Yellow' } else { 'Green' }
    Write-Host "  Mode:                         $modeLabel" -ForegroundColor $modeColor
    Write-Host "  ======================================================================" -ForegroundColor DarkCyan
    Write-Host ""
    if ($matchedCount -eq 0) {
        Write-Status OK "No new drivers to install."
        $result.Success = $true; return $result
    }
    $overallSw = [System.Diagnostics.Stopwatch]::StartNew()
    $globalReboot = $false; $i = 0
    Write-SubBanner "Installing $matchedCount $Label Driver(s)"
    foreach ($inf in $matchedInfs) {
        $i++
        $rel = $inf.FullName.Substring($DriverRoot.Length + 1)
        if ($rel -in $processed) { continue }
        $drvResult = Install-SingleDriver -InfPath $inf.FullName -DriverName $rel -CurrentNumber $i -TotalCount $matchedCount
        $result.TotalTime += $drvResult.Duration; $result.TotalKilled += $drvResult.ProcessesKilled
        if ($drvResult.TimedOut) { $result.TotalTimedOut++ }
        elseif ($drvResult.Added) { $result.TotalAdded++ }
        if ($drvResult.Installed) { $result.TotalInstalled++ }
        if ($drvResult.AlreadyExists) { $result.TotalAlreadyExist++ }
        if ((-not $drvResult.Success) -and (-not $drvResult.TimedOut)) { $result.TotalFailed++ }
        if ($drvResult.NeedsReboot) { $globalReboot = $true }
        $processed += $rel; $result.ProcessedDrivers = @($processed)
    }
    $overallSw.Stop()
    $failColor = if ($result.TotalFailed -gt 0) { 'Red' } else { 'Green' }
    $timeoutColor = if ($result.TotalTimedOut -gt 0) { 'Yellow' } else { 'Green' }
    $killColor = if ($result.TotalKilled -gt 0) { 'Yellow' } else { 'Green' }
    $rebootColor = if ($globalReboot) { 'Yellow' } else { 'Green' }
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Green
    Write-Host "              $Label DRIVER SUMMARY" -ForegroundColor Green
    Write-Host "======================================================================" -ForegroundColor Green
    Write-Host "  Found:          $($result.TotalFound)" -ForegroundColor White
    Write-Host "  Matched:        $($result.TotalMatched)" -ForegroundColor Green
    Write-Host "  Skipped:        $($result.TotalSkippedNoMatch)" -ForegroundColor Yellow
    Write-Host "  Added:          $($result.TotalAdded)" -ForegroundColor Green
    Write-Host "  Installed:      $($result.TotalInstalled)" -ForegroundColor Green
    Write-Host "  Up-to-date:     $($result.TotalAlreadyExist)" -ForegroundColor Cyan
    Write-Host "  Failed:         $($result.TotalFailed)" -ForegroundColor $failColor
    Write-Host "  Timed out:      $($result.TotalTimedOut)" -ForegroundColor $timeoutColor
    Write-Host "  Killed:         $($result.TotalKilled)" -ForegroundColor $killColor
    Write-Host "  Time:           $(Format-Duration $overallSw.Elapsed.TotalSeconds)" -ForegroundColor Magenta
    Write-Host "  Reboot needed:  $globalReboot" -ForegroundColor $rebootColor
    Write-Host "======================================================================" -ForegroundColor Green
    Write-Host ""
    $result.Success = $true; $result.NeedsReboot = $globalReboot
    return $result
}

#===================================================================
#  PHASE-0A: USB NETWORK DRIVERS
#===================================================================
function Install-USBNetworkDrivers {
    param([pscustomobject]$State)
    Write-Banner "PHASE-0A: USB NETWORK DRIVER INSTALLATION"
    Write-Status STEP "Installing NIC/WiFi drivers from USB to enable network."
    Write-Host ""
    Clear-DriverInstallEnvironment
    $root = $null
    if ($State.USBDriverRoot -and (Test-Path $State.USBDriverRoot)) {
        $root = $State.USBDriverRoot
        Write-Status OK "Using saved USB root: $root"
    }
    else {
        foreach ($drive in @('D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z')) {
            foreach ($folder in $Script:USBDriverFolders) {
                $candidate = "${drive}:\$folder"
                if (Test-Path $candidate) { $root = $candidate; Write-Status OK "Found: $root"; break }
            }
            if ($null -ne $root) { break }
        }
    }
    if ($null -eq $root) {
        Write-Status INFO "No USB driver folder found."
        return [PSCustomObject]@{ Success = $true; NeedsReboot = $false; NotFound = $true }
    }
    $State.USBDriverRoot = $root; Set-ScriptState -State $State
    $processed = @()
    if ($State.USBProcessedDrivers) { $processed = @($State.USBProcessedDrivers) }
    $usbResult = Install-DriversFromFolder -DriverRoot $root -Label "USB NETWORK" -ProcessedList $processed -SkipDeviceMatching
    $State.USBProcessedDrivers = $usbResult.ProcessedDrivers
    $State.TotalDriversAdded += $usbResult.TotalAdded
    $State.TotalDriversInstalled += $usbResult.TotalInstalled
    $State.TotalDriversFailed += $usbResult.TotalFailed
    $State.TotalDriversTimedOut += $usbResult.TotalTimedOut
    $State.TotalTimeSpent += $usbResult.TotalTime
    $State.TotalProcessesKilled += $usbResult.TotalKilled
    Set-ScriptState -State $State
    return $usbResult
}

#===================================================================
#  PHASE-0B: NETWORK SHARE DRIVERS
#===================================================================
function Install-NetworkShareDrivers {
    param([pscustomobject]$State)
    Write-Banner "PHASE-0B: NETWORK SHARE DRIVER INSTALLATION"

    # --- Configure guest auth BEFORE attempting share access ---
    if (-not $State.GuestAuthConfigured) {
        Write-Status STEP "Configuring SMB guest access (required for Windows 11)..."
        $guestOk = Enable-GuestNetworkAccess
        $State.GuestAuthConfigured = $true
        Set-ScriptState -State $State
        if ($guestOk) {
            Write-Status OK "SMB guest access configured."
        }
        else {
            Write-Status WARN "SMB configuration may have issues - will attempt share access anyway."
        }
    }
    else {
        Write-Status OK "SMB guest access already configured (previous run)."
    }

    # --- Get system info ---
    Write-SubBanner "Identifying System Model"
    $sysInfo = Get-SystemInfo
    $State.SystemManufacturer = $sysInfo.RawManufacturer
    $State.SystemModel = $sysInfo.RawModel
    $State.CleanModel = $sysInfo.CleanModel
    Set-ScriptState -State $State
    Write-Status INFO "Manufacturer:  $($sysInfo.RawManufacturer)"
    Write-Status INFO "Model:         $($sysInfo.RawModel)"
    Write-Status INFO "Clean model:   $($sysInfo.CleanModel)"
    $mfgFolder = Get-ManufacturerShareFolder -Manufacturer $sysInfo.RawManufacturer
    Write-Status INFO "Share folder:  $mfgFolder"

    # --- Build path ---
    $sharePath = ""
    if ($State.NetworkSharePath -and (Test-Path $State.NetworkSharePath -ErrorAction SilentlyContinue)) {
        $sharePath = $State.NetworkSharePath
        Write-Status OK "Using saved path: $sharePath"
    }
    else {
        $sharePath = Build-NetworkDriverPath -ManufacturerFolder $mfgFolder -CleanModel $sysInfo.CleanModel
    }
    Write-Host ""
    Write-Host "  ======================================================================" -ForegroundColor DarkCyan
    Write-Host "              NETWORK SHARE PATH RESOLUTION" -ForegroundColor Cyan
    Write-Host "  ======================================================================" -ForegroundColor DarkCyan
    Write-Host "  Base:           $($Script:NetworkShareBase)" -ForegroundColor White
    Write-Host "  Manufacturer:   $mfgFolder" -ForegroundColor White
    Write-Host "  Driver folder:  $($Script:ShareDriverFolder)" -ForegroundColor White
    Write-Host "  Model:          $($sysInfo.CleanModel)" -ForegroundColor White
    Write-Host "  Full path:      $sharePath" -ForegroundColor Green
    Write-Host "  ======================================================================" -ForegroundColor DarkCyan
    Write-Host ""

    # --- Test access ---
    Write-SubBanner "Testing Network Share Access"
    $shareAccessible = Test-NetworkShareAccess -SharePath $sharePath -MaxRetries 10 -RetryDelaySec 10
    if (-not $shareAccessible) {
        Write-Status WARN "Primary path not accessible. Trying alternatives..."
        $alternatives = @(
            ($sysInfo.RawModel -replace '\s', '-').ToLower()
            ($sysInfo.RawModel -replace '\s', '_').ToLower()
            $sysInfo.RawModel.ToLower()
        )
        $altFound = $false
        foreach ($alt in $alternatives) {
            $altPath = Build-NetworkDriverPath -ManufacturerFolder $mfgFolder -CleanModel $alt
            Write-Status INFO "Trying: $altPath"
            if (Test-Path $altPath -ErrorAction SilentlyContinue) {
                $sharePath = $altPath
                Write-Status OK "Found: $sharePath"
                $altFound = $true; break
            }
        }
        if (-not $altFound) {
            Write-Status ERROR "No matching share folder found."
            Write-Status INFO "Expected: $sharePath"
            Write-Status INFO "Ensure the share is accessible and the folder exists."
            return [PSCustomObject]@{ Success = $true; NeedsReboot = $false; NotFound = $true }
        }
    }
    $State.NetworkSharePath = $sharePath; Set-ScriptState -State $State

    # --- Install ---
    $processed = @()
    if ($State.NetworkShareProcessedDrivers) { $processed = @($State.NetworkShareProcessedDrivers) }
    Write-SubBanner "Scanning Devices"
    $systemIds = Get-SystemDeviceIds
    $netResult = Install-DriversFromFolder -DriverRoot $sharePath -Label "NETWORK SHARE" -ProcessedList $processed -SystemIds $systemIds
    $State.NetworkShareProcessedDrivers = $netResult.ProcessedDrivers
    $State.TotalDriversAdded += $netResult.TotalAdded
    $State.TotalDriversInstalled += $netResult.TotalInstalled
    $State.TotalDriversFailed += $netResult.TotalFailed
    $State.TotalDriversSkipped += $netResult.TotalSkippedNoMatch
    $State.TotalDriversTimedOut += $netResult.TotalTimedOut
    $State.TotalTimeSpent += $netResult.TotalTime
    $State.TotalProcessesKilled += $netResult.TotalKilled
    Set-ScriptState -State $State
    return $netResult
}

#===================================================================
#  INTERNET & MANUFACTURER
#===================================================================
function Test-InternetConnectivity {
    param([int]$MaxRetries = 15, [int]$RetryDelay = 10)
    Write-Banner "CHECKING INTERNET CONNECTIVITY"
    $w = Get-ConsoleWidth; $totalFrames = $Script:SpinnerFrames.Length
    for ($i = 1; $i -le $MaxRetries; $i++) {
        Write-Status PROGRESS "Attempt $i of $MaxRetries..."
        try {
            $r = Invoke-WebRequest -Uri "https://www.google.com" -Method Head -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            if ($r.StatusCode -eq 200) { Write-Status OK "Internet reachable."; return $true }
        }
        catch {
            Write-Status WARN "Attempt $i failed: $($_.Exception.Message)"
            if ($i -lt $MaxRetries) {
                for ($s = $RetryDelay; $s -ge 1; $s--) {
                    $spinner = $Script:SpinnerFrames[($RetryDelay - $s) % $totalFrames]
                    $pad = "  $spinner Waiting $s sec...".PadRight($w)
                    try {
                        [Console]::SetCursorPosition(0, [Console]::CursorTop)
                        [Console]::ForegroundColor = [ConsoleColor]::DarkGray
                        [Console]::Write($pad); [Console]::ResetColor()
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

function Get-SystemManufacturer {
    Write-SubBanner "Detecting System Manufacturer"
    $cs = Get-CimInstance Win32_ComputerSystem
    Write-Status INFO "Manufacturer: $($cs.Manufacturer.Trim())"
    Write-Status INFO "Model:        $($cs.Model.Trim())"
    return $cs.Manufacturer.Trim()
}

#===================================================================
#  CHOCOLATEY
#===================================================================
function Set-ChocolateySource {
    Write-SubBanner "Configuring Chocolatey Sources"
    $chocoExe = Get-ChocoExePath
    if (-not $chocoExe) { return }
    $null = Invoke-CommandVerbose -FilePath $chocoExe -Arguments "source add -n `"$($Script:ChocoSourceName)`" -s `"$($Script:ChocoSourceUrl)`" --priority=1 --allow-self-service" -Label "CHOCO"
    $null = Invoke-CommandVerbose -FilePath $chocoExe -Arguments "source disable -n `"chocolatey`"" -Label "CHOCO"
    $null = Invoke-CommandVerbose -FilePath $chocoExe -Arguments "source list" -Label "CHOCO"
}

function Install-ChocolateyIfNeeded {
    Write-SubBanner "Ensuring Chocolatey"
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Status INFO "Installing Chocolatey..."
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression (Invoke-RestMethod https://community.chocolatey.org/install.ps1)
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
        Write-Status OK "Chocolatey installed."
    }
    else { Write-Status OK "Chocolatey present." }
    Set-ChocolateySource
}

function Install-ChocoPackage {
    param([Parameter(Mandatory)][string]$PackageName, [string]$DisplayName)
    if (-not $DisplayName) { $DisplayName = $PackageName }
    $chocoExe = Get-ChocoExePath
    if (-not $chocoExe) { return $false }
    Write-SubBanner "Installing $DisplayName via Chocolatey"
    $exitCode = Invoke-CommandVerbose -FilePath $chocoExe -Arguments "install $PackageName -y --source=`"$($Script:ChocoSourceName)`"" -Label "CHOCO"
    if ($exitCode -ne 0) {
        Write-Status WARN "Custom source failed - trying default..."
        $exitCode = Invoke-CommandVerbose -FilePath $chocoExe -Arguments "install $PackageName -y" -Label "CHOCO"
    }
    if ($exitCode -eq 0) { Write-Status OK "$DisplayName installed."; return $true }
    else { Write-Status ERROR "$DisplayName failed."; return $false }
}

#===================================================================
#  DELL UPDATE LOGIC
#===================================================================
function Invoke-DellUpdates {
    param([pscustomobject]$State)
    Write-Banner "DELL SYSTEM UPDATE"
    $cli = @(
        'C:\Program Files\Dell\CommandUpdate\dcu-cli.exe',
        'C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $cli) {
        Install-ChocoPackage -PackageName "dellcommandupdate" -DisplayName "Dell Command Update" | Out-Null
        Start-Sleep -Seconds 5
        $cli = @(
            'C:\Program Files\Dell\CommandUpdate\dcu-cli.exe',
            'C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe'
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $cli) { Write-Status ERROR "Dell CLI missing."; return $false }
    Write-Status OK "Dell CLI: $cli"
    switch ($State.ManufacturerPhase) {
        0 {
            if ($State.DellADRFailed) { $State.ManufacturerPhase = 2; Set-ScriptState -State $State; return (Invoke-DellUpdates -State $State) }
            Write-SubBanner "Dell Phase-0: Configure ADR"
            $null = Invoke-CommandVerbose -FilePath $cli -Arguments "/configure -advancedDriverRestore=enable" -Label "DCU-CFG"
            Write-SubBanner "Dell Phase-0: ADR Driver Install"
            $dellExit = Invoke-CommandVerbose -FilePath $cli -Arguments "/driverinstall" -Label "DCU"
            switch ($dellExit) {
                0 { $State.ManufacturerPhase = 2; Set-ScriptState -State $State; return (Invoke-DellUpdates -State $State) }
                1 { $State.ManufacturerPhase = 1; Schedule-RebootAndContinue -State $State -Reason "Dell ADR (exit 1)" }
                5 { $State.ManufacturerPhase = 1; Schedule-RebootAndContinue -State $State -Reason "Dell ADR (exit 5)" }
                2 { $State.DellADRFailed = $true; $State.ManufacturerPhase = 2; Set-ScriptState -State $State; return (Invoke-DellUpdates -State $State) }
                3 { $State.ManufacturerPhase = 2; Set-ScriptState -State $State; return (Invoke-DellUpdates -State $State) }
                default { $State.DellADRFailed = $true; $State.ManufacturerPhase = 2; Set-ScriptState -State $State; return (Invoke-DellUpdates -State $State) }
            }
        }
        1 {
            Write-SubBanner "Dell Phase-1: Post-Reboot Scan"
            $null = Invoke-CommandVerbose -FilePath $cli -Arguments "/scan" -Label "DCU"
            $State.ManufacturerPhase = 2; Set-ScriptState -State $State
            return (Invoke-DellUpdates -State $State)
        }
        2 {
            Write-SubBanner "Dell Phase-2: Apply All Updates"
            $dellExit = Invoke-CommandVerbose -FilePath $cli -Arguments "/applyupdates -forceUpdate=enable -autoSuspendBitLocker=enable" -Label "DCU"
            switch ($dellExit) {
                0 { $State.ManufacturerPhase = 3; Set-ScriptState -State $State; return $true }
                1 { $State.ManufacturerPhase = 3; Schedule-RebootAndContinue -State $State -Reason "Dell updates (exit 1)" }
                5 { $State.ManufacturerPhase = 3; Schedule-RebootAndContinue -State $State -Reason "Dell updates (exit 5)" }
                3 { $State.ManufacturerPhase = 3; Set-ScriptState -State $State; return $true }
                default { $State.ManufacturerPhase = 3; Set-ScriptState -State $State; return $true }
            }
        }
        default { Write-Status OK "Dell updates done."; return $true }
    }
    return $true
}

#===================================================================
#  HP UPDATE LOGIC
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
        Install-ChocoPackage -PackageName "hpimageassistant" -DisplayName "HP Image Assistant" | Out-Null
        Start-Sleep -Seconds 5
        $hpia = $hpiaPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $hpia) { Write-Status ERROR "HPIA missing."; return $false }
    Write-SubBanner "HP Image Assistant: Analyze & Install"
    $hpExit = Invoke-CommandVerbose -FilePath $hpia -Arguments "/Operation:Analyze /Action:Install /Selection:All /Silent /Noninteractive /ReportFolder:C:\Temp\HPIA" -Label "HPIA"
    switch ($hpExit) {
        0    { Write-Status OK "HP done."; return $true }
        256  { Write-Status WARN "HP: reboot needed."; return $true }
        3010 { Write-Status WARN "HP: reboot needed."; return $true }
        default { Write-Status WARN "HP exit $hpExit."; return $true }
    }
}

#===================================================================
#  MAIN EXECUTION
#===================================================================
try {
    if (-not (Initialize-PersistentScript)) { throw "Failed to initialise persistent script." }
    Start-Transcript -Path $Script:LogFile -Append -Force

    $sysInfoHeader = Get-SystemInfo
    $mfg = Get-ManufacturerShareFolder -Manufacturer $sysInfoHeader.RawManufacturer
    $expectedPath = Build-NetworkDriverPath -ManufacturerFolder $mfg -CleanModel $sysInfoHeader.CleanModel
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "       DRIVER UPDATE SCRIPT - PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "  User:          $env:USERNAME" -ForegroundColor Cyan
    Write-Host "  Computer:      $env:COMPUTERNAME" -ForegroundColor Cyan
    Write-Host "  Manufacturer:  $($sysInfoHeader.RawManufacturer)" -ForegroundColor Cyan
    Write-Host "  Model:         $($sysInfoHeader.RawModel)" -ForegroundColor Cyan
    Write-Host "  Clean model:   $($sysInfoHeader.CleanModel)" -ForegroundColor Cyan
    Write-Host "  Driver share:  $expectedPath" -ForegroundColor Cyan
    Write-Host "  Timeout:       $Script:DriverTimeout sec/driver" -ForegroundColor Cyan
    Write-Host "  Flow:          USB(NIC) -> GuestAuth -> Share(all) -> OEM(online)" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host ""

    Write-Status INFO "Checking for orphan processes..."
    $orphanKilled = Stop-DriverInstallProcesses -Silent
    if ($orphanKilled -gt 0) { Write-Status WARN "Terminated $orphanKilled."; Start-Sleep -Seconds 2 }

    $state = Get-ScriptState
    Write-Host "----------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  CURRENT STATE" -ForegroundColor DarkGray
    Write-Host "----------------------------------------------------------------------" -ForegroundColor DarkGray
    foreach ($prop in $state.PSObject.Properties) {
        Write-Host ("  {0,-35}: {1}" -f $prop.Name, $prop.Value) -ForegroundColor DarkGray
    }
    Write-Host "----------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""

    # PHASE-0A: USB NIC drivers
    if ($state.Phase -eq 0) {
        if (-not $state.USBCompleted) {
            $usbResult = Install-USBNetworkDrivers -State $state
            if ($usbResult.NeedsReboot) {
                $state.USBCompleted = $true; $state.USBRebootDone = $false
                Set-ScriptState -State $state
                Schedule-RebootAndContinue -State $state -Reason "USB NIC driver install - reboot required"
            }
            else {
                $state.USBCompleted = $true; $state.USBRebootDone = $true
                Set-ScriptState -State $state
            }
        }
        else {
            if (-not $state.USBRebootDone) {
                Write-Status OK "Post-reboot: USB NIC drivers finalized."
                $state.USBRebootDone = $true; Set-ScriptState -State $state
            }
        }

        # PHASE-0B: Network share drivers
        if (-not $state.NetworkShareCompleted) {
            $netResult = Install-NetworkShareDrivers -State $state
            if ($netResult.NeedsReboot) {
                $state.NetworkShareCompleted = $true; $state.NetworkShareRebootDone = $false
                Set-ScriptState -State $state
                Schedule-RebootAndContinue -State $state -Reason "Network share drivers - reboot required"
            }
            else {
                $state.NetworkShareCompleted = $true; $state.NetworkShareRebootDone = $true
                $state.Phase = 1; Set-ScriptState -State $state
            }
        }
        else {
            if (-not $state.NetworkShareRebootDone) {
                Write-Status OK "Post-reboot: Network share drivers finalized."
                $state.NetworkShareRebootDone = $true
            }
            $state.Phase = 1; Set-ScriptState -State $state
        }
    }

    # PHASE-1: Online OEM updates
    if ($state.Phase -ge 1) {
        Write-Banner "PHASE 1: ONLINE OEM UPDATES"
        if (-not (Test-InternetConnectivity -MaxRetries 15 -RetryDelay 10)) {
            Write-Status ERROR "No internet."; try { Stop-Transcript } catch { }; exit 1
        }
        Install-ChocolateyIfNeeded
        $manufacturer = Get-SystemManufacturer
        if ($manufacturer -like '*Dell*') { Invoke-DellUpdates -State $state | Out-Null }
        elseif ($manufacturer -match 'HP|Hewlett[-\s]?Packard') { Invoke-HPUpdates -State $state | Out-Null }
        else { Write-Status WARN "Unsupported: $manufacturer" }
    }

    # FINAL
    Stop-DriverInstallProcesses -Silent | Out-Null
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Green
    Write-Host "      DRIVER UPDATE SCRIPT COMPLETED SUCCESSFULLY!" -ForegroundColor Green
    Write-Host "======================================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  System:            $($state.SystemManufacturer) $($state.SystemModel)" -ForegroundColor White
    Write-Host "  Model (cleaned):   $($state.CleanModel)" -ForegroundColor White
    Write-Host "  Share path:        $($state.NetworkSharePath)" -ForegroundColor White
    Write-Host "  Guest auth:        $($state.GuestAuthConfigured)" -ForegroundColor White
    Write-Host "  Total reboots:     $($state.RebootCount)" -ForegroundColor White
    Write-Host "  Drivers added:     $($state.TotalDriversAdded)" -ForegroundColor White
    Write-Host "  Drivers installed: $($state.TotalDriversInstalled)" -ForegroundColor White
    Write-Host "  Drivers skipped:   $($state.TotalDriversSkipped)" -ForegroundColor White
    Write-Host "  Drivers failed:    $($state.TotalDriversFailed)" -ForegroundColor White
    Write-Host "  Timed out:         $($state.TotalDriversTimedOut)" -ForegroundColor White
    Write-Host "  Killed:            $($state.TotalProcessesKilled)" -ForegroundColor White
    Write-Host "  Total time:        $(Format-Duration $state.TotalTimeSpent)" -ForegroundColor White
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
    try {
        $saveEA = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        Stop-DriverInstallProcesses -Silent | Out-Null
        $ErrorActionPreference = $saveEA
    }
    catch { try { $ErrorActionPreference = $saveEA } catch { } }
    Write-Status INFO "State file kept - re-run to continue."
}
finally {
    try { Stop-Transcript } catch { }
}