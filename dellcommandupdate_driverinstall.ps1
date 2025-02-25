# Install Dell Command Update
try {
    choco install dellcommandupdate -y
    Write-Host "Dell Command Update installed successfully." -ForegroundColor Green
} catch {
    Write-Host "Failed to install Dell Command Update: $_" -ForegroundColor Red
    throw
}

# Define Dell Command Update CLI path
$dcuCLI = "C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe"

# Configure advanced driver restore and show output
try {
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$dcuCLI /configure -advancedDriverRestore=enable`"" -NoNewWindow -Wait
    Write-Host "Dell Command Update configuration completed." -ForegroundColor Green
} catch {
    Write-Host "Failed to configure Dell Command Update: $_" -ForegroundColor Red
    throw
}

# Run driver installation and show output
try {
    $installProcess = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$dcuCLI /driverInstall`"" -NoNewWindow -Wait -PassThru
    $exitCode = $installProcess.ExitCode
} catch {
    Write-Host "Failed to start Dell Command Update driver installation: $_" -ForegroundColor Red
    throw
}

# Check installation success
try {
    if ($? -and ($LASTEXITCODE -in @(0, 1, 5, 500))) {
        Write-Host "Stage: dellcommandupdate_driverinstall completed" -ForegroundColor Green
        Set-ItemProperty -Path 'HKCU:\osinstall_local' -Name stage -Value 'dellcommandupdate_applyupdates'

        # Set to run once on restart
        Set-Runonce
        Stop-Transcript
        Restart-Computer
    } else {
        throw "Dell Command Update driver installation failed with exit code: $exitCode"
    }
} catch {
    Write-Host "Stage: dellcommandupdate_driverinstall Failed - $_" -ForegroundColor Red
    Set-ItemProperty -Path 'HKCU:\osinstall_local' -Name stage -Value 'dellcommandupdate_driverinstall'

    # Ensure script can retry on the next boot
    Set-Runonce
    Stop-Transcript
    Pause
}


<# old version
choco install dellcommandupdate -y
& "C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe" /configure -advancedDriverRestore=enable
& "C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe" /driverInstall
if($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1 -or $LASTEXITCODE -eq 5 -or $LASTEXITCODE -eq 500)
{
write-host "Stage: dellcommandupdate_driverinstall completed" -ForegroundColor Green
Set-ItemProperty -Path 'HKCU:\osinstall_local' -Name stage -value 'dellcommandupdate_applyupdates'
Set-Runonce
Stop-Transcript
Restart-Computer
} 
else 
{
write-host "Stage: dellcommandupdate_driverinstall Failed" -ForegroundColor Red
Set-ItemProperty -Path 'HKCU:\osinstall_local' -Name stage -value dellcommandupdate_driverinstall
Set-Runonce
Stop-Transcript
Pause
}

#>
