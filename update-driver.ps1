#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# START
# ============================================================
Write-Host "=== STARTING DRIVER UPDATE SCRIPT (PS $($PSVersionTable.PSVersion)) ===" -ForegroundColor Cyan
Write-Host "User: $env:USERNAME | PID: $PID" -ForegroundColor Cyan

# ============================================================
# Helper: Status Output
# ============================================================
function Write-Status {
    param(
        [Parameter(Mandatory)][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )

    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = switch ($Level.ToUpper()) {
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        'INFO'  { 'Cyan' }
        'STEP'  { 'Magenta' }
        default { 'White' }
    }

    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# ============================================================
# STEP 1: Internet Connectivity
# ============================================================
Write-Status STEP "Checking internet connectivity..."

$connected = $false
$maxRetries = 15
$retryDelay = 10

for ($i = 1; $i -le $maxRetries; $i++) {
    Write-Status INFO "Attempt $i of $maxRetries..."
    try {
        $resp = Invoke-WebRequest -Uri "https://www.google.com" -Method Head -TimeoutSec 10
        if ($resp.StatusCode -eq 200) {
            Write-Status STEP "Internet connection confirmed."
            $connected = $true
            break
        }
    }
    catch {
        Write-Status WARN "Connection failed: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $retryDelay
}

if (-not $connected) {
    Write-Status ERROR "No internet connectivity. Exiting."
    exit 1
}

# ============================================================
# STEP 2: Manufacturer Detection
# ============================================================
Write-Status STEP "Detecting system manufacturer..."
$manufacturer = (Get-CimInstance Win32_ComputerSystem).Manufacturer.Trim()
Write-Status STEP "Manufacturer detected: $manufacturer"

# ============================================================
# STEP 3: Ensure Chocolatey
# ============================================================
Write-Status STEP "Ensuring Chocolatey is installed..."

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Status INFO "Installing Chocolatey..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression (Invoke-RestMethod https://community.chocolatey.org/install.ps1)
    Write-Status STEP "Chocolatey installed."
}
else {
    Write-Status STEP "Chocolatey already installed."
}

# ============================================================
# DELL SYSTEMS
# ============================================================
if ($manufacturer -like '*Dell*') {

    Write-Status STEP "Dell system detected."

    choco install dellcommandupdate -y | Out-Null

    $DCUCliPath = @(
        'C:\Program Files\Dell\CommandUpdate\dcu-cli.exe',
        'C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $DCUCliPath) {
        Write-Status ERROR "Dell Command Update CLI not found."
        exit 1
    }

    Write-Status INFO "DCU CLI: $DCUCliPath"

    if (-not (Test-Path 'C:\Temp')) {
        New-Item C:\Temp -ItemType Directory | Out-Null
    }

    $runOnceKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    $phase2Path = 'C:\Temp\dell-phase2.ps1'
    $phase3Path = 'C:\Temp\dell-phase3.ps1'

    # ---------------- PHASE 3 ----------------
@"
Start-Transcript C:\Temp\dell-phase3.log -Append
`"$DCUCliPath`" /applyupdates -silent -reboot=enable
Stop-Transcript
Remove-Item `"$phase2Path`" -Force -ErrorAction SilentlyContinue
Remove-Item `"$phase3Path`" -Force -ErrorAction SilentlyContinue
"@ | Out-File $phase3Path -Encoding UTF8 -Force

    # ---------------- PHASE 2 ----------------
@"
Start-Transcript C:\Temp\dell-phase2.log -Append
`"$DCUCliPath`" /driverinstall -silent -reboot=disable
if (`$LASTEXITCODE -in 0,1,5) {
    Set-ItemProperty '$runOnceKey' '*DellPhase3' 'powershell.exe -ExecutionPolicy Bypass -File `"$phase3Path`"'
    Restart-Computer -Force
}
Stop-Transcript
"@ | Out-File $phase2Path -Encoding UTF8 -Force

    # ---------------- PHASE 1 ----------------
    Write-Status STEP "Running Dell Phase 1 driver install..."

    & $DCUCliPath /configure -advancedDriverRestore=enable
    & $DCUCliPath /driverinstall -silent -reboot=disable
    $exitCode = $LASTEXITCODE

    if ($exitCode -in 0,1,5) {
        Write-Status STEP "Phase 1 success → scheduling Phase 3."
        Set-ItemProperty $runOnceKey '*DellPhase3' "powershell.exe -ExecutionPolicy Bypass -File `"$phase3Path`""
        Restart-Computer -Force
    }
    elseif ($exitCode -eq 2) {
        Write-Status WARN "ADR crash detected → scheduling Phase 2."
        Set-ItemProperty $runOnceKey '*DellPhase2' "powershell.exe -ExecutionPolicy Bypass -File `"$phase2Path`""
        Restart-Computer -Force
    }
    else {
        Write-Status ERROR "Dell driver install failed with exit code $exitCode."
    }
}

# ============================================================
# HP SYSTEMS
# ============================================================
elseif ($manufacturer -match 'HP|Hewlett-Packard') {

    Write-Status STEP "HP system detected."

    choco install hpimageassistant -y | Out-Null

    $hpia = 'C:\HP\HPIA\HPImageAssistant.exe'
    if (-not (Test-Path $hpia)) {
        Write-Status ERROR "HP Image Assistant not found."
        exit 1
    }

    Write-Status STEP "Running HP Image Assistant..."
    Start-Process $hpia `
        -ArgumentList '/Operation:Analyze /Action:Install /Selection:All /Silent /Noninteractive' `
        -Wait -NoNewWindow
}

# ============================================================
# UNSUPPORTED
# ============================================================
else {
    Write-Status WARN "Unsupported manufacturer. Exiting."
}

# ============================================================
# END
# ============================================================
Write-Status STEP "Driver update script completed."
Write-Host "=== SCRIPT FINISHED ===" -ForegroundColor Green
