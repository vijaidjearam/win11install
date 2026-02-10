# Requires -RunAsAdministrator

# --- Detect PowerShell Version ---
Write-Host "=== STARTING DRIVER UPDATE SCRIPT (PS$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)) ===" -ForegroundColor Cyan
Write-Host "User: $env:USERNAME | PID: $PID" -ForegroundColor Cyan

# --- Helper Function: Write-Host with Level-Based Colors ---
function Write-Status {
    param([string]$Level, [string]$Message)
    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = switch ($Level.ToUpper()) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "INFO"  { "Cyan" }
        "STEP"  { "Magenta" }
        default { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# --- STEP 1: Check Internet Connectivity ---
Write-Status "STEP" "Checking internet connectivity..."
$connected = $false
$attempts = 0
$maxRetries = 15
$retryDelaySec = 10

while ($attempts -lt $maxRetries) {
    $attempts++
    Write-Status "INFO" "Attempt $attempts of $maxRetries to connect to internet..."

    try {
        $response = Invoke-WebRequest -Uri "https://www.google.com" -Method Head -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        if ($response.StatusCode -eq 200) {
            Write-Status "STEP" "SUCCESS - Internet connection confirmed."
            $connected = $true
            break
        }
    }
    catch {
        Write-Status "WARN" "FAILED - Connection failed: $($_.Exception.Message.Trim())"
    }

    Write-Status "INFO" "Waiting $retryDelaySec seconds before retry..."
    Start-Sleep -Seconds $retryDelaySec
}

if (-not $connected) {
    Write-Status "ERROR" "CRITICAL - No internet after $maxRetries attempts. Exiting script."
    exit 1
}

# --- STEP 2: Detect System Manufacturer ---
Write-Status "STEP" "Detecting system manufacturer..."
try {
    $manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer.Trim()
    Write-Status "STEP" "Detected Manufacturer: '$manufacturer'"
}
catch {
    Write-Status "ERROR" "CRITICAL - Failed to retrieve system manufacturer: $($_.Exception.Message)"
    exit 1
}

# --- STEP 3: Ensure Chocolatey Is Installed ---
Write-Status "STEP" "Ensuring Chocolatey (package manager) is installed..."
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Status "INFO" "Chocolatey not found. Attempting to install Chocolatey now..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

    try {
        $installScript = Invoke-RestMethod 'https://community.chocolatey.org/install.ps1'
        & [scriptblock]::Create($installScript)
        Write-Status "STEP" "SUCCESS - Chocolatey installed successfully."
    }
    catch {
        Write-Status "ERROR" "CRITICAL - Chocolatey installation failed: $($_.Exception.Message)"
        exit 1
    }
}
else {
    Write-Status "STEP" "Chocolatey is already installed. Version: $(choco --version)"
}

# --- STEP 4: Process Based on Detected Manufacturer ---
if ($manufacturer -like "*Dell*") {
    Write-Status "STEP" "Detected Dell system. Proceeding with Dell-specific actions..."

    # Install Dell Command | Update
    Write-Status "STEP" "Installing Dell Command Update via Chocolatey..."
    Start-Process -FilePath "choco" -ArgumentList "install -y dellcommandupdate" -Wait -NoNewWindow
    $chocoExitCode = $LASTEXITCODE
    if ($chocoExitCode -ne 0 -and $chocoExitCode -ne 3010) {
        Write-Status "ERROR" "FAILED - Chocolatey install of dellcommandupdate failed with exit code: $chocoExitCode"
        exit $chocoExitCode
    }
    Write-Status "STEP" "Dell Command Update installed successfully."
# =============================================================================
# DELL DRIVER INSTALL LOOP — 3-Phase with RunOnce Chain (No Nested Here-Strings)
# =============================================================================

# --- Find DCU CLI ---
$DCUCliPath = $null
$dcuSearchPaths = @(
    "C:\Program Files\Dell\CommandUpdate\dcu-cli.exe",
    "C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe"
)
foreach ($p in $dcuSearchPaths) {
    if (Test-Path $p) { $DCUCliPath = $p; break }
}

if (-not $DCUCliPath) {
    Write-Host "[ERROR] Dell Command Update CLI not found. Skipping." -ForegroundColor Red
}
else {
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host " Dell Command Update — Phase 1"               -ForegroundColor Cyan
    Write-Host " DCU: $DCUCliPath"                             -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan

    # Ensure C:\Temp exists
    if (-not (Test-Path "C:\Temp")) {
        New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null
    }

    # ──────────────────────────────────────────────────────────
    # PRE-WRITE: Create Phase 2 and Phase 3 scripts up front
    #            (eliminates nested here-string problem)
    # ──────────────────────────────────────────────────────────

    $phase2ScriptPath = "C:\Temp\dell-phase2-driverinstall.ps1"
    $phase3ScriptPath = "C:\Temp\dell-phase3-applyupdates.ps1"
    $runOnceKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"

    # --- Phase 3 Script: /applyupdates ---
    $phase3Script = @'
Start-Transcript -Path "C:\Temp\dell-phase3.log" -Append
Write-Host "============================================="
Write-Host " Dell Command Update — Phase 3: /applyupdates"
Write-Host "============================================="

$DCU = "##DCUPATH##"

# Wait for network (up to 5 minutes)
$timeout = 300; $elapsed = 0; $connected = $false
while ($elapsed -lt $timeout) {
    if (Test-Connection -ComputerName "dell.com" -Count 1 -Quiet -ErrorAction SilentlyContinue) {
        Write-Host "[PHASE 3] Network available after ${elapsed}s."
        $connected = $true
        break
    }
    Write-Host "[PHASE 3] Waiting for network... (${elapsed}s / ${timeout}s)"
    Start-Sleep -Seconds 10
    $elapsed += 10
}

if (-not $connected) {
    Write-Host "[PHASE 3] ERROR: No network after ${timeout}s."
    Stop-Transcript
    exit 1
}

# Run /applyupdates with retry on 500
$maxRetries = 3
for ($i = 1; $i -le $maxRetries; $i++) {
    Write-Host "`n[PHASE 3] Attempt $i/$maxRetries : /applyupdates"
    $proc = Start-Process -FilePath $DCU `
        -ArgumentList "/applyupdates -silent -reboot=enable" `
        -Wait -PassThru -NoNewWindow

    $code = $proc.ExitCode
    Write-Host "[PHASE 3] Exit code: $code"

    if ($code -in @(0, 1, 5)) {
        Write-Host "[PHASE 3] /applyupdates completed successfully."
        break
    }
    if ($code -eq 500 -and $i -lt $maxRetries) {
        Write-Host "[PHASE 3] Network error (500). Retrying in 60s..."
        Start-Sleep -Seconds 60
        continue
    }
    Write-Host "[PHASE 3] /applyupdates failed (exit code: $code)."
}

# Cleanup both phase scripts
Remove-Item -Path "C:\Temp\dell-phase2-driverinstall.ps1" -Force -ErrorAction SilentlyContinue
Remove-Item -Path $MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue
Stop-Transcript
'@
    $phase3Script = $phase3Script.Replace("##DCUPATH##", $DCUCliPath)
    $phase3Script | Out-File -FilePath $phase3ScriptPath -Encoding UTF8 -Force
    Write-Host "[PHASE 1] Phase 3 script written: $phase3ScriptPath"

    # --- Phase 2 Script: /driverinstall retry ---
    $phase2Script = @'
Start-Transcript -Path "C:\Temp\dell-phase2.log" -Append
Write-Host "============================================="
Write-Host " Dell Command Update — Phase 2: /driverinstall retry"
Write-Host "============================================="

$DCU = "##DCUPATH##"
$phase3Path = "##PHASE3PATH##"
$runOnceKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"

Write-Host "[PHASE 2] Running /driverinstall ..."
$proc = Start-Process -FilePath $DCU `
    -ArgumentList "/driverinstall -silent -reboot=disable" `
    -Wait -PassThru -NoNewWindow

$code = $proc.ExitCode
Write-Host "[PHASE 2] /driverinstall exit code: $code"

if ($code -in @(0, 1, 5)) {
    Write-Host "[PHASE 2] /driverinstall succeeded!"
    Write-Host "[PHASE 2] Setting RunOnce for Phase 3 (/applyupdates)..."

    $runOnceCmd = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Normal -File ""$phase3Path"""
    Set-ItemProperty -Path $runOnceKey -Name "*DellPhase3" -Value $runOnceCmd -Type String

    Write-Host "[PHASE 2] RunOnce set. Rebooting in 15s..."

    # Cleanup this script
    Remove-Item -Path $MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 15
    Restart-Computer -Force
    exit 0
}
else {
    Write-Host "[PHASE 2] /driverinstall FAILED again (exit code: $code)."
    Write-Host "[PHASE 2] Manual intervention required."
}

# Cleanup this script
Remove-Item -Path $MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue
Stop-Transcript
'@
    $phase2Script = $phase2Script.Replace("##DCUPATH##", $DCUCliPath)
    $phase2Script = $phase2Script.Replace("##PHASE3PATH##", $phase3ScriptPath)
    $phase2Script | Out-File -FilePath $phase2ScriptPath -Encoding UTF8 -Force
    Write-Host "[PHASE 1] Phase 2 script written: $phase2ScriptPath"

    # ──────────────────────────────────────────────────────────
    # STEP 1: Enable Advanced Driver Restore
    # ──────────────────────────────────────────────────────────
    Write-Host "`n[PHASE 1] Enabling Advanced Driver Restore..." -ForegroundColor Cyan

    $configProc = Start-Process -FilePath $DCUCliPath `
        -ArgumentList "/configure -advancedDriverRestore=enable" `
        -Wait -PassThru -NoNewWindow

    Write-Host "[PHASE 1] Configure exit code: $($configProc.ExitCode)"

    # ──────────────────────────────────────────────────────────
    # STEP 2: Try /driverinstall
    # ──────────────────────────────────────────────────────────
    Write-Host "`n[PHASE 1] Running /driverinstall ..." -ForegroundColor Cyan

    $diProc = Start-Process -FilePath $DCUCliPath `
        -ArgumentList "/driverinstall -silent -reboot=disable" `
        -Wait -PassThru -NoNewWindow

    $diExitCode = $diProc.ExitCode
    Write-Host "[PHASE 1] /driverinstall exit code: $diExitCode"

    # ──────────────────────────────────────────────────────────
    # BRANCH: Decide next step
    # ──────────────────────────────────────────────────────────

    if ($diExitCode -in @(0, 1, 5)) {
        # ═══════════════════════════════════════════════════════
        # SUCCESS → Jump to Phase 3 (skip Phase 2)
        # ═══════════════════════════════════════════════════════
        Write-Host "[PHASE 1] /driverinstall succeeded!" -ForegroundColor Green
        Write-Host "[PHASE 1] Setting RunOnce for Phase 3 (/applyupdates)..." -ForegroundColor Cyan

        $runOnceCmd = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Normal -File `"$phase3ScriptPath`""
        Set-ItemProperty -Path $runOnceKey -Name "*DellPhase3" -Value $runOnceCmd -Type String

        # Clean up Phase 2 script (not needed)
        Remove-Item -Path $phase2ScriptPath -Force -ErrorAction SilentlyContinue

        Write-Host "[PHASE 1] RunOnce set: *DellPhase3" -ForegroundColor Green
        Write-Host "[PHASE 1] Rebooting in 15s..." -ForegroundColor Yellow
        Start-Sleep -Seconds 15
        Restart-Computer -Force
        exit 0
    }
    elseif ($diExitCode -eq 2) {
        # ═══════════════════════════════════════════════════════
        # EXIT CODE 2 (ADR crash) → RunOnce Phase 2 → Reboot
        # ═══════════════════════════════════════════════════════
        Write-Host "[PHASE 1] /driverinstall failed (exit 2: ADR crash)." -ForegroundColor Yellow
        Write-Host "[PHASE 1] Setting RunOnce for Phase 2 (retry after reboot)..." -ForegroundColor Cyan

        $runOnceCmd = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Normal -File `"$phase2ScriptPath`""
        Set-ItemProperty -Path $runOnceKey -Name "*DellPhase2" -Value $runOnceCmd -Type String

        Write-Host "[PHASE 1] RunOnce set: *DellPhase2" -ForegroundColor Green
        Write-Host "[PHASE 1] Rebooting in 15s..." -ForegroundColor Yellow
        Start-Sleep -Seconds 15
        Restart-Computer -Force
        exit 0
    }
    else {
        # ═══════════════════════════════════════════════════════
        # OTHER ERROR → Log and continue
        # ═══════════════════════════════════════════════════════
        Write-Host "[PHASE 1] /driverinstall failed (exit code: $diExitCode)." -ForegroundColor Red
        Write-Host "[PHASE 1] Manual intervention may be required." -ForegroundColor Red

        # Clean up pre-written scripts
        Remove-Item -Path $phase2ScriptPath -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $phase3ScriptPath -Force -ErrorAction SilentlyContinue
    }
}
}
elseif ($manufacturer -like "*Hewlett-Packard*" -or $manufacturer -like "*HP*") {
    Write-Status "STEP" "Detected HP system. Proceeding with HP-specific actions..."

    # Install HP Image Assistant
    Write-Status "STEP" "Installing HP Image Assistant via Chocolatey..."
    Start-Process -FilePath "choco" -ArgumentList "install -y hpimageassistant" -Wait -NoNewWindow
    $chocoExitCode = $LASTEXITCODE
    if ($chocoExitCode -ne 0 -and $chocoExitCode -ne 3010) {
        Write-Status "ERROR" "FAILED - Chocolatey install of hpimageassistant failed with exit code: $chocoExitCode"
        exit $chocoExitCode
    }
    Write-Status "STEP" "HP Image Assistant installed successfully."

    # --- CORRECTED PATH AND EXECUTABLE NAME ---
    # Primary location: C:\HP\HPIA\HPImageAssistant.exe
    $hpiaExePath = "C:\HP\HPIA\HPImageAssistant.exe"
    
    # Fallback location: Program Files (in case installer puts it there)
    if (-not (Test-Path $hpiaExePath)) {
        $hpiaExePath = "${env:ProgramFiles}\HP\HP Image Assistant\HPImageAssistant.exe"
    }
    
    # Fallback 2: Try PATH directly if file not found in standard locations
    if (-not (Test-Path $hpiaExePath)) {
        $hpiaExePath = "HPImageAssistant.exe"
        Write-Status "INFO" "Standard paths not found. Attempting to run from system PATH..."
    }

    if (-not (Test-Path $hpiaExePath) -and !(Get-Command "HPImageAssistant.exe" -ErrorAction SilentlyContinue)) {
        Write-Status "ERROR" "CRITICAL - HPImageAssistant.exe not found at C:\HP\HPIA, Program Files, or in PATH."
        exit 1
    }

    Write-Status "INFO" "Using executable: $hpiaExePath"

    # --- CORRECTED ARGUMENTS (Based on your working script) ---
    # /Operation:Analyze - Scans the system
    # /Action:Install - Installs the missing drivers/software
    # /Selection:All - Selects all applicable updates
    # /Silent /Noninteractive - Runs quietly without user prompts
    $hpiaArgs = "/Operation:Analyze /Action:Install /Selection:All /Silent /Noninteractive"

    Write-Status "STEP" "Running HP Image Assistant silently (This may take a while)..."
    Write-Status "INFO" "Command: $hpiaExePath $hpiaArgs"

    try {
        # Using Start-Process with -Wait to ensure script pauses until HPIA finishes
        # -NoNewWindow keeps it from popping up a new console window unnecessarily
        Start-Process -FilePath $hpiaExePath -ArgumentList $hpiaArgs -Wait -NoNewWindow
        
        # Since HPIA doesn't always return clear exit codes to PowerShell easily in all versions,
        # we assume success if no exception was thrown and the process exited.
        Write-Status "STEP" "HP updates process completed. Check HPIA logs for detailed results."
    }
    catch {
        Write-Status "ERROR" "FAILED - Failed to execute HP Image Assistant. Ensure it is properly installed."
        Write-Status "ERROR" "Error Details: $($_.Exception.Message)"
        exit 1
    }

    Write-Status "STEP" "HP update process finished."
}
else {
    Write-Status "WARN" "Unsupported manufacturer: '$manufacturer'. This script only supports Dell and HP systems. Exiting."
    exit 0
}

# --- Final Message ---
Write-Status "STEP" "Driver update script completed successfully." -ForegroundColor Green
Write-Host "=== SCRIPT FINISHED ===" -ForegroundColor Green
