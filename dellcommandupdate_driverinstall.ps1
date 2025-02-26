# Function to install Dell Command Update
function Install-DellCommandUpdate {
    try {
        Write-Host "Installing Dell Command Update..." -ForegroundColor Yellow
        choco install dellcommandupdate -y
        Write-Host "Dell Command Update installed successfully." -ForegroundColor Green
    } catch {
        Write-Host "Failed to install Dell Command Update: $_" -ForegroundColor Red
        throw
    }
}

# Check if Dell Command Update CLI exists
$dcuPath = "C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe"
if (-Not (Test-Path $dcuPath)) {
    Write-Host "Dell Command Update CLI not found. Reinstalling..." -ForegroundColor Red
    Install-DellCommandUpdate
}

# Ensure the CLI exists before proceeding
if (Test-Path $dcuPath) {
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
} else {
    Write-Host "Dell Command Update installation failed or path not found. Exiting script." -ForegroundColor Red
    Pause
}
