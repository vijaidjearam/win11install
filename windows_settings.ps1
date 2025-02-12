$WarningPreference = 'SilentlyContinue'
write-host "Entering Windows-settings Configuration Stage" 
$repopath = Get-ItemPropertyValue -Path 'HKCU:\repopath' -Name path
iex ((New-Object System.Net.WebClient).DownloadString($repopath+'windows_settings.psm1'))

Function RequireAdmin {
	If (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
		Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $PSCommandArgs" -Verb RunAs
		Exit
	}
}


$settings = @()
$PSCommandArgs = @()

Function AddOrRemoveSetting($setting) {
	If ($setting[0] -eq "!") {
		# If the name starts with exclamation mark (!), exclude the app from selection
		$script:settings = $script:settings | Where-Object { $_ -ne $setting.Substring(1) }
	} ElseIf ($settings -ne "") {
		# Otherwise add the app
		$script:apps += $setting
	}
}


try
{

$i = 0
While ($i -lt $args.Length) {
	If ($args[$i].ToLower() -eq "-include") {
		# Resolve full path to the included file
		$include = Resolve-Path $args[++$i] -ErrorAction Stop
		$PSCommandArgs += "-include `"$include`""
		# Import the included file as a module
		Import-Module -Name $include -ErrorAction Stop
	} ElseIf ($args[$i].ToLower() -eq "-preset") {
		# Resolve full path to the preset file
		$preset = Resolve-Path $args[++$i] -ErrorAction Stop
		$PSCommandArgs += "-preset `"$preset`""
		# Load tweak names from the preset file
		Get-Content $preset -ErrorAction Stop | ForEach-Object { AddOrRemoveTweak($_.Split("#")[0].Trim()) }
	} ElseIf ($args[$i].ToLower() -eq "-log") {
		# Resolve full path to the output file
		$log = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($args[++$i])
		$PSCommandArgs += "-log `"$log`""
		# Record session to the output file
		Start-Transcript $log
	} Else {
		$PSCommandArgs += $args[$i]
		# Load tweak names from command line
		AddOrRemoveTweak($args[$i])
	}
	$i++
}


$settings | ForEach-Object {
try{
Invoke-Expression $_ |Out-Null
write-host $_ "---------------------OK" -ForegroundColor Green
}
catch{
write-host  ""
write-host $_ "--------------Nok" -ForegroundColor Red
}
}
write-host "Stage: windows_settings completed" -ForegroundColor Green
Set-ItemProperty -Path 'HKCU:\osinstall_local' -Name stage -value 'windows_debloat'
Set-Runonce
Stop-Transcript
Restart-Computer
}
catch
{
write-host "Stage: windows_settings Failed" -ForegroundColor Red
Set-ItemProperty -Path 'HKCU:\osinstall_local' -Name stage -value 'windows_settings'
Set-Runonce
Stop-Transcript
Pause

}
