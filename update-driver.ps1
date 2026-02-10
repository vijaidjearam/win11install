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
    $DCUCliPath = "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe"
    if (-not (Test-Path $DCUCliPath)) {
        Write-Status "ERROR" "CRITICAL - Dell Command Update CLI (dcu-cli.exe) not found at expected path: $dcuCliPath"
        exit 1
    }

    # Enable Advanced Driver Restore
    Write-Status "STEP" "Enabling Advanced Driver Restore in Dell Command Update..."
    & $DCUCliPath /configure -advanceddriverrestore=enable
    $dcuCliExitCode = $LASTEXITCODE
    if ($dcuCliExitCode -ne 0) {
        Write-Status "WARN" "WARNING - Failed to enable Advanced Driver Restore (Exit Code: $dcuCliExitCode). Continuing anyway."
    } else {
        Write-Status "STEP" "Advanced Driver Restore enabled."
    }
    # =============================================================================
    # DELL DRIVER INSTALL LOOP — with /driverinstall -> /applyupdates fallback
    # =============================================================================

    if (Test-Path $DCUCliPath) {

        Write-Host "=============================================" -ForegroundColor Cyan
        Write-Host " Dell Command Update — Driver Installation"    -ForegroundColor Cyan
        Write-Host "=============================================" -ForegroundColor Cyan

        # ------------------------------------------------------------------
        # STEP 1: Attempt /driverinstall (base drivers only)
        # ------------------------------------------------------------------
        Write-Host "`n[STEP 1] Running DCU /driverinstall ..." -ForegroundColor Cyan

        try {
            $driverInstallProc = Start-Process -FilePath $DCUCliPath `
                -ArgumentList "/driverinstall -silent -reboot=disable" `
                -Wait -PassThru -NoNewWindow -ErrorAction Stop

            $diExitCode = $driverInstallProc.ExitCode
            Write-Host "[INFO] /driverinstall exit code: $diExitCode"

            <#  Dell Command Update CLI Exit Codes:
                    0  = Completed successfully, no reboot required
                    1  = Reboot required (updates applied successfully)
                    2  = Fatal error during update
                    3  = Error occurred during update
                    4  = Invalid XML / CLI input error
                    5  = No updates available
                500  = No updates available (some DCU versions)
            #>

            # Define success codes
            $successCodes = @(0, 1, 5, 500)

            if ($diExitCode -in $successCodes) {
                # ==========================================================
                # SUCCESS PATH: schedule /applyupdates at next logon + reboot
                # ==========================================================
                Write-Host "[SUCCESS] /driverinstall completed successfully (exit code: $diExitCode)." -ForegroundColor Green

                # --- Create a helper script for RunOnce ---
                # This ensures /applyupdates runs elevated with logging
$applyUpdatesScript = @'
Start-Transcript -Path "C:\Temp\dell-applyupdates.log" -Append
Write-Host "[RunOnce] Starting Dell Command Update /applyupdates ..."
try {
    $proc = Start-Process -FilePath "##DCUPATH##" `
        -ArgumentList "/applyupdates -silent -reboot=enable" `
        -Wait -PassThru -NoNewWindow
    Write-Host "[RunOnce] /applyupdates exit code: $($proc.ExitCode)"
} catch {
    Write-Host "[RunOnce] ERROR: $_"
}
Stop-Transcript
'@

                # Now inject the actual DCU path into the script
                $applyUpdatesScript = $applyUpdatesScript.Replace("##DCUPATH##", $DCUCliPath)
                $scriptPath = "C:\Temp\dell-runonce-applyupdates.ps1"

                # Ensure C:\Temp exists
                if (-not (Test-Path "C:\Temp")) {
                    New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null
                }

                # Write the helper script to disk
                $applyUpdatesScript | Out-File -FilePath $scriptPath -Encoding UTF8 -Force
                Write-Host "[INFO] Helper script written to: $scriptPath"

                # --- Register RunOnce entry ---
                # Using '*' prefix on the value name ensures it runs even if
                # the previous run didn't complete (safe-mode resilient).
                $runOnceKey  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
                $runOnceCmd  = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Normal -File `"$scriptPath`""

                if (-not (Test-Path $runOnceKey)) {
                    New-Item -Path $runOnceKey -Force | Out-Null
                }

                Set-ItemProperty -Path $runOnceKey `
                    -Name "*DellApplyUpdates" `
                    -Value $runOnceCmd `
                    -Type String

                Write-Host "[INFO] RunOnce registry entry created:" -ForegroundColor Green
                Write-Host "       Key  : $runOnceKey"
                Write-Host "       Name : *DellApplyUpdates"
                Write-Host "       Value: $runOnceCmd"

                # --- Reboot ---
                Write-Host "`n[INFO] Rebooting in 10 seconds to apply remaining updates at next logon..." -ForegroundColor Yellow
                Start-Sleep -Seconds 10
                Restart-Computer -Force
                # Script execution stops here due to reboot
                exit 0
            }
            else {
                # ==========================================================
                # ERROR PATH: /driverinstall failed → try /applyupdates now
                # ==========================================================
                Write-Host "[WARNING] /driverinstall FAILED (exit code: $diExitCode)." -ForegroundColor Yellow
                Write-Host "[STEP 2] Falling back to /applyupdates ..." -ForegroundColor Yellow

                $applyProc = Start-Process -FilePath $DCUCliPath `
                    -ArgumentList "/applyupdates -silent -reboot=disable" `
                    -Wait -PassThru -NoNewWindow -ErrorAction Stop

                $auExitCode = $applyProc.ExitCode
                Write-Host "[INFO] /applyupdates exit code: $auExitCode"

                if ($auExitCode -in @(0, 1, 5, 500)) {
                    Write-Host "[SUCCESS] /applyupdates completed (exit code: $auExitCode)." -ForegroundColor Green

                    if ($auExitCode -eq 1) {
                        Write-Host "[INFO] Reboot required. Rebooting in 10 seconds..." -ForegroundColor Yellow
                        Start-Sleep -Seconds 10
                        Restart-Computer -Force
                        exit 0
                    }
                }
                else {
                    Write-Host "[ERROR] /applyupdates also failed (exit code: $auExitCode)." -ForegroundColor Red
                    Write-Host "[ERROR] Manual intervention may be required." -ForegroundColor Red
                }
            }
        }
        catch {
            # ==========================================================
            # EXCEPTION PATH: Start-Process itself threw an error
            # ==========================================================
            Write-Host "[ERROR] Exception during Dell driver installation: $_" -ForegroundColor Red
            Write-Host "[STEP 2] Attempting /applyupdates as fallback..." -ForegroundColor Yellow

            try {
                $fallbackProc = Start-Process -FilePath $DCUCliPath `
                    -ArgumentList "/applyupdates -silent -reboot=disable" `
                    -Wait -PassThru -NoNewWindow

                Write-Host "[INFO] Fallback /applyupdates exit code: $($fallbackProc.ExitCode)"
            }
            catch {
                Write-Host "[ERROR] Fallback /applyupdates also failed: $_" -ForegroundColor Red
            }
        }
    }
    else {
        Write-Host "[WARNING] Dell Command Update CLI not found at: $DCUCliPath" -ForegroundColor Yellow
        Write-Host "[WARNING] Skipping Dell driver installation." -ForegroundColor Yellow
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
