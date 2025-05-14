$biossettingsFilePath = "C:\Windows\Setup\Scripts\dellbiosparam.txt"
$biossettings = Get-Content $biossettingsFilePath | Where-Object {$_ -notmatch '^#' -and $_ -notmatch '^!'}


choco install dellcommandconfigure -y
foreach($item in $biossettings){
& "C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe" --$item | Out-Null
if($LASTEXITCODE -eq 0)
{
write-host "setting $item was successfull" -ForegroundColor Green

}
elseif($LASTEXITCODE -eq 42){

write-host "$item is not available or cannot be configured " -ForegroundColor Yellow

}
elseif($LASTEXITCODE -eq 43){

write-host "There was an error setting the option: $item " -ForegroundColor Yellow

}
elseif($LASTEXITCODE -eq 72){

write-host "TpmActivation cannot be modified when TPM is OFF" -ForegroundColor Yellow

}
elseif($LASTEXITCODE -eq 147){
write-host "The Value is not supported on the system: $item " -ForegroundColor Yellow
}
elseif($LASTEXITCODE -eq 58 -or $LASTEXITCODE -eq 65 -or $LASTEXITCODE -eq 66 -or $LASTEXITCODE -eq 67 -or $LASTEXITCODE -eq 109)
{
write-host "Password is set in the BIOS, please clear the BIOS password during restart and continue" -ForegroundColor Red
$biospassword = Read-Host -Prompt 'Enter bios Password to clear it in bios'
& "C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe" --syspwd=   --valsyspwd=$biospassword
& "C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe" --$item | Out-Null
write-host "setting $item was successfull" -ForegroundColor Green
}
else{
write-host "There was an error setting the option: $item  LastExitCode: $LASTEXITCODE" -ForegroundColor Red
Set-ItemProperty -Path 'HKCU:\osinstall_local' -Name stage -value 'dellcommandconfigure'
Set-Runonce 
Stop-Transcript
Pause
Exit
}
}
write-host "Stage: dellcommandconfigure completed" -ForegroundColor Green
Set-ItemProperty -Path 'HKCU:\osinstall_local' -Name stage -value 'chocolatey_apps'
Set-Runonce
Stop-Transcript
Restart-Computer
