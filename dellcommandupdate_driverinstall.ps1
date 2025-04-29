# Function to install Dell Command Update
function Install-DellCommandUpdate {
    try {
        Write-Host "Installing Dell Command Update..." -ForegroundColor Yellow
        choco install -y dellcommandupdate --ignore-checksums
        Write-Host "Dell Command Update installation initiated." -ForegroundColor Green
    } catch {
        Write-Host "Failed to install Dell Command Update: $_" -ForegroundColor Red
        throw
    }
}

# Check if Dell Command Update CLI exists with a loop
$dcuPath = "C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe"
$attempts = 0
$maxAttempts = 10
$waitTime = 120  # 2 minutes in seconds

while ($attempts -lt $maxAttempts) {
    if (Test-Path $dcuPath) {
        Write-Host "Dell Command Update CLI found. Proceeding with execution..." -ForegroundColor Green
        break
    } else {
        Write-Host "Dell Command Update not found. Attempt $($attempts + 1) of $maxAttempts. Retrying in 2 minutes..." -ForegroundColor Yellow
        if ($attempts -eq 0) {
            Install-DellCommandUpdate  # Install only on the first attempt if missing
        }
        Start-Sleep -Seconds $waitTime
        $attempts++
    }
}

# Final check before proceeding
if (-Not (Test-Path $dcuPath)) {
    Write-Host "Dell Command Update installation failed after $maxAttempts attempts. Exiting script." -ForegroundColor Red
    Pause
}

# Configure advanced driver restore
& $dcuPath /configure -advancedDriverRestore=enable
Write-Host "`nAdvanced Driver Restore Enabled" -ForegroundColor Green

# Run driver installation
& $dcuPath /driverInstall

# Check if the driver install went through successfully
if ($LASTEXITCODE -in @(0, 1, 5, 500)) {
    Write-Host "`nStage: dellcommandupdate_driverinstall completed" -ForegroundColor Green
    Set-ItemProperty -Path 'HKCU:\osinstall_local' -Name stage -Value 'dellcommandupdate_applyupdates'
    Set-Runonce
    Stop-Transcript
    Restart-Computer
} else {
    Write-Host "`nStage: dellcommandupdate_driverinstall Failed" -ForegroundColor Red
    Set-ItemProperty -Path 'HKCU:\osinstall_local' -Name stage -Value 'dellcommandupdate_driverinstall'
    Set-Runonce
    Stop-Transcript
    Pause
}
