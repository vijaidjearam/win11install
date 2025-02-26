# Install Dell Command Update
try {
    choco install dellcommandupdate -y
    Write-Host "Dell Command Update installed successfully." -ForegroundColor Green
} catch {
    Write-Host "Failed to install Dell Command Update: $_" -ForegroundColor Red
    throw
}
# Configure advanced driver restore
& "C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe" /configure -advancedDriverRestore=enable
write-host "`n Advanced Driver Restore Enabled" -ForegroundColor Green
# Run driver installation
& "C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe" /driverInstall
#if ($? -and ($LASTEXITCODE -in @(0, 1, 5, 500)))
# Checking if the driver install went through successfully
if ($LASTEXITCODE -in @(0, 1, 5, 500))
{
    write-host "`nStage: dellcommandupdate_driverinstall completed" -ForegroundColor Green
    Set-ItemProperty -Path 'HKCU:\osinstall_local' -Name stage -value 'dellcommandupdate_applyupdates'
    Set-Runonce
    Stop-Transcript
    Restart-Computer
} 
else 
{
    write-host "`nStage: dellcommandupdate_driverinstall Failed" -ForegroundColor Red
    Set-ItemProperty -Path 'HKCU:\osinstall_local' -Name stage -value 'dellcommandupdate_driverinstall'
    Set-Runonce
    Stop-Transcript
    Pause
}
