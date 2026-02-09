# --- Detect PowerShell Version ---
Write-Host "=== STARTING DRIVER UPDATE SCRIPT (PS$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)) ===" -ForegroundColor Cyan
Write-Host "User: $env:USERNAME | PID: $PID" -ForegroundColor Cyan

# --- Helper Function: Write-Host with Level-Based Colors ---
function Write-Status {
    param([string]$Level, [string]$Message)
    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = switch ($Level.ToUpper()) {
        "ERROR"  { "Red" }
        "WARN"   { "Yellow" }
        "INFO"   { "Cyan" }
        "STEP"   { "Magenta" }
        default  { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# --- STEP 1: Check Internet ---
Write-Status "STEP" "Checking internet connectivity..."
$connected = $false
$attempts = 0
$maxRetries = 15

while ($attempts -lt $maxRetries) {
    $attempts++
    Write-Status "INFO" "Attempt $attempts of $maxRetries..."

    try {
        $response = Invoke-WebRequest -Uri "https://www.google.com" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        if ($response.StatusCode -eq 200) {
            Write-Status "STEP" "✅ Internet connection confirmed."
            $connected = $true
            break
        }
    }
    catch {
        Write-Status "WARN" "❌ Connection failed: $($_.Exception.Message.Trim())"
    }

    Write-Status "INFO" "⏳ Waiting 10 seconds before retry..."
    Start-Sleep -Seconds 10
}

if (-not $connected) {
    Write-Status "ERROR" "❌ No internet after $maxRetries attempts. Exiting."
    exit 1
}

# --- STEP 2: Detect Manufacturer ---
Write-Status "STEP" "Detecting system manufacturer..."
$manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer.Trim()
Write-Status "STEP" "🔍 Detected Manufacturer: '$manufacturer'"

# --- STEP 3: Install Chocolatey if Missing ---
Write-Status "STEP" "Ensuring Chocolatey is installed..."
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Status "INFO" "Chocolatey not found. Installing now..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

    try {
        $installScript = Invoke-RestMethod 'https://community.chocolatey.org/install.ps1'
        & [scriptblock]::Create($installScript)
        Write-Status "STEP" "✅ Chocolatey installed successfully."
    }
    catch {
        Write-Status "ERROR" "🚨 Chocolatey installation failed: $($_.Exception.Message)"
        exit 1
    }
}
else {
    Write-Status "STEP" "✅ Chocolatey already installed. Version: $(choco --version)"
}

# --- STEP 4: Process by Manufacturer ---
if ($manufacturer -like "*Dell*") {
    Write-Status "STEP" "🖥️ Detected Dell system. Applying Dell-specific actions..."

    # Install Dell Command Update
    Write-Status "STEP" "📦 Installing Dell Command Update via Chocolatey..."
    Start-Process -FilePath "choco" -ArgumentList "install -y dellcommandupdate" -Wait -NoNewWindow
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
        Write-Status "ERROR" "❌ Failed to install Dell Command Update. Exit Code: $LASTEXITCODE"
        exit $LASTEXITCODE
    }
    Write-Status "STEP" "✅ Dell Command Update installed."

    $dcuCli = "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe"
    if (-not (Test-Path $dcuCli)) {
        Write-Status "ERROR" "❌ Dell Command Update CLI not found at $dcuCli"
        exit 1
    }

    # Enable Advanced Driver Restore
    Write-Status "STEP" "🛠️ Enabling Advanced Driver Restore..."
    & $dcuCli /configure -advanceddriverrestore=enable
    if ($LASTEXITCODE -ne 0) {
        Write-Status "WARN" "⚠️ Failed to enable Advanced Driver Restore (Exit Code: $LASTEXITCODE)"
    } else {
        Write-Status "STEP" "✅ Advanced Driver Restore enabled."
    }

    # Apply Updates (No Reboot)
    Write-Status "STEP" "🔧 Applying updates (no reboot)..."
    & $dcuCli /applyupdates -reboot=never
    $exitCode = $LASTEXITCODE

    switch ($exitCode) {
        0 { Write-Status "STEP" "ℹ️ DCU: No applicable updates found." }
        1 { Write-Status "STEP" "⚠️ DCU: Updates applied, but BIOS password may have blocked BIOS update. Treating as success." }
        2 { Write-Status "STEP" "ℹ️ DCU: Reboot required, but was suppressed." }
        3 { Write-Status "WARN" "⚠️ DCU: Updates available but could not be applied." }
        4 { Write-Status "ERROR" "🚨 DCU: Error initializing update process." }
        5 { Write-Status "ERROR" "🚨 DCU: System not supported." }
        default {
            if ($exitCode -gt 5) {
                Write-Status "WARN" "⚠️ DCU: Unexpected error (Exit Code: $exitCode). Check DCU logs."
            }
        }
    }

    if ($exitCode -gt 10) {
        Write-Status "ERROR" "🚨 Critical DCU failure (Exit Code: $exitCode). Exiting."
        exit $exitCode
    } else {
        Write-Status "STEP" "✅ Dell update process completed."
    }

}
elseif ($manufacturer -like "*Hewlett-Packard*" -or $manufacturer -like "*HP*") {
    Write-Status "STEP" "🖥️ Detected HP system. Applying HP-specific actions..."

    # Install HP Image Assistant
    Write-Status "STEP" "📦 Installing HP Image Assistant via Chocolatey..."
    Start-Process -FilePath "choco" -ArgumentList "install -y hpimageassistant" -Wait -NoNewWindow
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
        Write-Status "ERROR" "❌ Failed to install HP Image Assistant. Exit Code: $LASTEXITCODE"
        exit $LASTEXITCODE
    }
    Write-Status "STEP" "✅ HP Image Assistant installed."

    $hpiasExe = "${env:ProgramFiles}\HP\HP Image Assistant\HPIA.exe"
    if (-not (Test-Path $hpiasExe)) {
        Write-Status "ERROR" "❌ HPIA.exe not found at $hpiasExe"
        exit 1
    }

    Write-Status "STEP" "🔧 Running HP Image Assistant: --analyze --apply --silent --suppress_reboot"

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $hpiasExe
    $processInfo.Arguments = "--analyze --apply --silent --suppress_reboot"
    $processInfo.UseShellExecute = $false
    $processInfo.WindowStyle = "Hidden"

    try {
        $process = [System.Diagnostics.Process]::Start($processInfo)
        Write-Status "STEP" "✅ HP Image Assistant launched (PID: $($process.Id))"
    }
    catch {
        Write-Status "ERROR" "🚨 Failed to launch HP Image Assistant: $($_.Exception.Message)"
        exit 1
    }

    # Wait up to 10 minutes (600 seconds)
    $maxWait = 600
    $waited = 0

    while (-not $process.HasExited -and $waited -lt $maxWait) {
        Start-Sleep -Seconds 5
        $waited += 5
        Write-Status "INFO" "⏳ Waiting for HPIA to complete... (Elapsed: $waited seconds)"
    }

    if (-not $process.HasExited) {
        Write-Status "WARN" "⚠️ HPIA timed out after $maxWait seconds. Terminating..."
        $process.Kill() | Out-Null
        Start-Sleep -Seconds 2
    }

    $exitCode = $process.ExitCode
    Write-Status "STEP" "📋 HP Image Assistant exited with code: $exitCode"

    switch ($exitCode) {
        0 { Write-Status "STEP" "✅ HPIA: System up-to-date or no action required." }
        1 { Write-Status "STEP" "✅ HPIA: Updates applied successfully (reboot suppressed)." }
        2 { Write-Status "STEP" "ℹ️ HPIA: Reboot required, but was suppressed." }
        3 { Write-Status "WARN" "⚠️ HPIA: Analysis found issues but no action taken." }
        default { Write-Status "WARN" "⚠️ HPIA: Unknown exit code: $exitCode" }
    }

    Write-Status "STEP" "✅ HP update process completed."
}
else {
    Write-Status "WARN" "⚠️ Unsupported manufacturer: '$manufacturer'. Supported: Dell, HP."
    exit 0
}

# --- Final Message ---
Write-Status "STEP" "✅ Driver update script completed successfully." -ForegroundColor Green
Write-Host "=== SCRIPT FINISHED ===" -ForegroundColor Green
