# Delete Temp Files
Function DeleteTempFiles {
    Write-Host "Cleaning up temporary files and setup scripts..."
    # The folder C:\8336500659725115574 is created during dellcommandupdate /applyupdates
    $tempfolders = @("C:\Windows\Temp\*", "C:\Windows\Prefetch\*", "C:\Documents and Settings\*\Local Settings\temp\*", "C:\Users\*\Appdata\Local\Temp\*","C:\Windows\Setup\Scripts\*","C:\8336500659725115574","C:\AMD","C:\Intel")
    Remove-Item $tempfolders -force -recurse 2>&1 | Out-Null
}

# Clean WinSXS folder (WARNING: this takes a while!)
Function CleanWinSXS {
    Write-Host "Cleaning WinSXS folder, this may take a while, please wait..."
    Dism.exe /online /Cleanup-Image /StartComponentCleanup
}
function dontdisplaylastusername-on-logon{
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name dontdisplaylastusername -Value 1 -Force
}
# Turn On or Off Use sign-in info to auto finish setting up device after update or restart in Windows 10
function disableautosignin-info{
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name DisableAutomaticRestartSignOn -Value 1 -Force
}

function disable-autologon{
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoAdminLogon -Value 0 -Force
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name DefaultDomainName -Force
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name DefaultUserName -Force
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoLogonCount -Value 0 -Force
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoLogonSID -Value 0 -Force
#Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name DefaultPassword -Force
}


function clear-eventlogs{
Write-host "Cleaning Event Log" 
Get-EventLog -LogName * | ForEach { Clear-EventLog $_.Log }
Write-host "Completed Cleaning Event Log" 
}
function Remove-WindowsOld {
    $folderPath = "C:\Windows.old"
    
    if (Test-Path -Path $folderPath) {
        Write-Host "Folder 'Windows.old' found. Removing..." -ForegroundColor Yellow
        try {
            Remove-Item -Path $folderPath -Recurse -Force
            Write-Host "'Windows.old' has been successfully removed." -ForegroundColor Green
        } catch {
            Write-Host "An error occurred while removing 'Windows.old': $_" -ForegroundColor Red
        }
    } else {
        Write-Host "'Windows.old' folder does not exist." -ForegroundColor Red
    }
}
function Uninstall-DellCommandUpdate {
    # Check if DellCommandUpdate is installed via Chocolatey
    $package = choco list | Select-String -Pattern "DellCommandUpdate"

    if ($package) {
        Write-Host "'DellCommandUpdate' found, uninstalling..." -ForegroundColor Yellow
        try {
            choco uninstall DellCommandUpdate -y
            Write-Host "'DellCommandUpdate' has been successfully uninstalled." -ForegroundColor Green
        } catch {
            Write-Host "An error occurred while uninstalling 'DellCommandUpdate': $_" -ForegroundColor Red
        }
    } else {
        Write-Host "'DellCommandUpdate' is not installed via Chocolatey." -ForegroundColor Red
    }
}


try
{
iex CleanWinSXS
Remove-Item -Path HKCU:\osinstall_local
Remove-Item -Path HKCU:\repopath
#dell command update pops up message in the taskbar if there is new driver updates, inspite of setting it to manual schedule update. 
#so uninstall dell command update , if required it can be installed anytime using chocolatey.
iex Uninstall-DellCommandUpdate
#installing kaspersky at the end so that it doesnt block the script at the start up
#choco install f-secure -y
#choco install f-secure-autonome -y
# Remove chocolatey source and forcing to use the choco local server
choco source remove -n=chocolatey
# remove autologon parameters
iex disableautosignin-info
iex disable-autologon
# Reset Administrator password to Blank
#Set-LocalUser -name Administrateur -Password ([securestring]::new())
iex dontdisplaylastusername-on-logon
#remove windows.old folder
iex Remove-WindowsOld
Stop-Transcript
Write-host "The Next step is going to clear Temp File and eventlogs, check the log file for any error message and then continue: "
Pause
iex DeleteTempFiles
iex clear-eventlogs
write-host "Stage: cleaning completed" -ForegroundColor Green

}
catch
{
write-host "Stage: cleaning Failed" -ForegroundColor Red
Set-ItemProperty -Path 'HKCU:\osinstall_local' -Name stage -value cleaning
$repopath = Get-ItemPropertyValue -Path 'HKCU:\osinstall_local' -Name repopath
$repo = $repopath+'header.ps1'
Set-Runonce -command "%systemroot%\System32\WindowsPowerShell\v1.0\powershell.exe -executionpolicy bypass ; iex ((New-Object System.Net.WebClient).DownloadString($repo))"
Stop-Transcript
Pause
}
