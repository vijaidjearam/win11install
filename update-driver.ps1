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

    # Define path to dcu-cli.exe
    $dcuCliPath = "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe"
    if (-not (Test-Path $dcuCliPath)) {
        Write-Status "ERROR" "CRITICAL - Dell Command Update CLI (dcu-cli.exe) not found at expected path: $dcuCliPath"
        exit 1
    }

    # Enable Advanced Driver Restore
    Write-Status "STEP" "Enabling Advanced Driver Restore in Dell Command Update..."
    & $dcuCliPath /configure -advanceddriverrestore=enable
    $dcuCliExitCode = $LASTEXITCODE
    if ($dcuCliExitCode -ne 0) {
        Write-Status "WARN" "WARNING - Failed to enable Advanced Driver Restore (Exit Code: $dcuCliExitCode). Continuing anyway."
    } else {
        Write-Status "STEP" "Advanced Driver Restore enabled."
    }

    # Apply Updates (drivers, firmware, BIOS) and suppress reboot
    Write-Status "STEP" "Applying available updates using Dell Command Update (reboot suppressed)..."
    Write-Status "INFO" "Command: $dcuCliPath /applyupdates -reboot=never"
    & $dcuCliPath /applyupdates -reboot=never
    $dcuCliExitCode = $LASTEXITCODE

    # Handle DCU CLI Exit Codes
    switch ($dcuCliExitCode) {
        0 { Write-Status "STEP" "DCU Report: No applicable updates were found." }
        1 { Write-Status "STEP" "DCU Report: Updates applied successfully. NOTE: BIOS updates might be skipped if a BIOS password is set. Reboot was suppressed." }
        2 { Write-Status "STEP" "DCU Report: Reboot is required to complete installation, but was suppressed." }
        3 { Write-Status "WARN" "DCU Report: Updates available but could not be applied (e.g., missing dependencies or conflicts)." }
        4 { Write-Status "ERROR" "DCU Report: Error initializing update process." }
        5 { Write-Status "ERROR" "DCU Report: System not supported by Dell Command Update." }
        default {
            if ($dcuCliExitCode -gt 5) {
                Write-Status "WARN" "DCU Report: Unexpected exit code: $dcuCliExitCode. Review Dell Command Update logs for details."
            } else {
                Write-Status "WARN" "DCU Report: Unknown specific exit code: $dcuCliExitCode."
            }
        }
    }

    if ($dcuCliExitCode -gt 10) {
        Write-Status "ERROR" "CRITICAL - Dell update process failed with severe exit code: $dcuCliExitCode. Exiting."
        exit $dcuCliExitCode
    } else {
        Write-Status "STEP" "Dell update process completed (non-critical issues tolerated)."
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

    if (-not (Test-Path $hpiaExePath)) {
        Write-Status "ERROR" "CRITICAL - HPImageAssistant.exe not found at C:\HP\HPIA or Program Files."
        exit 1
    }

    Write-Status "INFO" "Found HPImageAssistant.exe at: $hpiaExePath"

    # Run HPIA: Analyze, Apply updates silently, suppress reboot
    Write-Status "STEP" "Running HP Image Assistant to apply driver updates silently (reboot suppressed)..."
    Write-Status "INFO" "Command: $hpiaExePath --analyze --apply --silent --suppress_reboot"

    # Configure ProcessStartInfo for HPIA to run hidden
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $hpiaExePath
    $processInfo.Arguments = "--analyze --apply --silent --suppress_reboot"
    $processInfo.UseShellExecute = $false
    $processInfo.WindowStyle = "Hidden"

    try {
        $hpiaProcess = [System.Diagnostics.Process]::Start($processInfo)
        Write-Status "STEP" "HP Image Assistant launched successfully with Process ID: $($hpiaProcess.Id)"
    }
    catch {
        Write-Status "ERROR" "CRITICAL - Failed to launch HP Image Assistant: $($_.Exception.Message)"
        exit 1
    }

    # Wait for HPIA to complete with a timeout
    $maxHPIAWaitSec = 600 # 10 minutes timeout
    $waitedSec = 0
    Write-Status "INFO" "Waiting for HP Image Assistant to complete (Max wait: $maxHPIAWaitSec seconds)..."

    while (-not $hpiaProcess.HasExited -and $waitedSec -lt $maxHPIAWaitSec) {
        Start-Sleep -Seconds 5
        $waitedSec += 5
        Write-Status "INFO" "HPIA still running... (Elapsed: $waitedSec seconds)"
    }

    # Check if HPIA timed out
    if (-not $hpiaProcess.HasExited) {
        Write-Status "WARN" "WARNING - HP Image Assistant timed out after $maxHPIAWaitSec seconds. Attempting to terminate process."
        try {
            $hpiaProcess.Kill() | Out-Null
            Start-Sleep -Seconds 2
            Write-Status "INFO" "HPIA process terminated."
        }
        catch {
            Write-Status "ERROR" "Failed to terminate HPIA process: $($_.Exception.Message)"
        }
        $hpiaExitCode = -1
    } else {
        $hpiaExitCode = $hpiaProcess.ExitCode
    }

    Write-Status "STEP" "HP Image Assistant exited with code: $hpiaExitCode"

    # Handle HPIA Exit Codes
    switch ($hpiaExitCode) {
        0 { Write-Status "STEP" "HPIA Report: System is up-to-date or no action was needed." }
        1 { Write-Status "STEP" "HPIA Report: Updates were applied successfully. Reboot was suppressed." }
        2 { Write-Status "STEP" "HPIA Report: Reboot is required (but was suppressed)." }
        3 { Write-Status "WARN" "HPIA Report: Analysis completed, but found issues or no applicable action taken." }
        -1 { Write-Status "ERROR" "HPIA Report: Process terminated due to timeout." }
        default { Write-Status "WARN" "HPIA Report: Unknown or unexpected exit code: $hpiaExitCode." }
    }

    Write-Status "STEP" "HP update process completed."
}
else {
    Write-Status "WARN" "Unsupported manufacturer: '$manufacturer'. This script only supports Dell and HP systems. Exiting."
    exit 0
}

# --- Final Message ---
Write-Status "STEP" "Driver update script completed successfully." -ForegroundColor Green
Write-Host "=== SCRIPT FINISHED ===" -ForegroundColor Green
