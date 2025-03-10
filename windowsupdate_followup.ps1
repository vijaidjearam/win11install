function windowsupdatefollowup()
{
Try
{
Import-Module -Name PSWindowsUpdate
$temp = Get-WindowsUpdate
if ($temp.Count -gt 0)
{
Set-ItemProperty -Path 'HKCU:\osinstall_local' -Name stage -value 'windowsupdate_followup'
Set-Runonce
#Install-WindowsUpdate -NotCategory "Drivers" -NotTitle OneDrive -NotKBArticleID KB5000802 -AcceptAll -AutoReboot
Install-WindowsUpdate -NotCategory "Drivers" -NotTitle OneDrive -AcceptAll -AutoReboot
write-host "Stage: windowsupdate_followup completed" -ForegroundColor Green
Stop-Transcript
Restart-Computer
}
else {
Set-ItemProperty -Path 'HKCU:\osinstall_local' -Name stage -value 'windows_services'
Set-Runonce
Stop-Transcript
Restart-Computer
}
}

catch
{
write-host "Stage: windowsupdate_followup Failed" -ForegroundColor Red
Set-ItemProperty -Path 'HKCU:\osinstall_local' -Name stage -value windowsupdate_followup
Set-Runonce
Stop-Transcript
Pause
}
}

function Test-RegistryValueExists {
    param (
        [string]$RegistryPath,
        [string]$ValueName
    )

    try {
        $exists = Get-ItemProperty -Path $RegistryPath -Name $ValueName -ErrorAction SilentlyContinue
        return $null -ne $exists.$ValueName
    } catch {
        return $false
    }
}




if(Test-RegistryValueExists -RegistryPath 'HKCU:\osinstall_local' -ValueName 'windowsupdateiteration')
{
 $iter= Get-ItemPropertyValue -Path 'HKCU:\osinstall_local' -Name windowsupdateiteration
 if ($iter -lt 5)
 {
 $iter = $iter + 1
 Set-ItemProperty -Path 'HKCU:\osinstall_local' -Name windowsupdateiteration -Value $iter -Force
 write-host Iteration : $iter -ForegroundColor Green
 windowsupdatefollowup
 }
 else
 {
  Set-ItemProperty -Path 'HKCU:\osinstall_local' -Name stage -value 'windows_services'
  Set-Runonce
  Stop-Transcript
  Restart-Computer 
 }


}
else
{
New-ItemProperty -Path 'HKCU:\osinstall_local' -Name windowsupdateiteration -value 1
windowsupdatefollowup
}

