Try {
    # Read services from file, ignore comments (#) and lines starting with (!)
    $serviceStopFilePath = "C:\Windows\Setup\Scripts\service_stop.txt"
    $service_stop = Get-Content $serviceStopFilePath | Where-Object {$_ -notmatch '^#' -and $_ -notmatch '^!'}

    $serviceStartupDisabledFilePath = "C:\Windows\Setup\Scripts\service_startup_disabled.txt"
    $service_startup_disabled = Get-Content $serviceStartupDisabledFilePath | Where-Object {$_ -notmatch '^#' -and $_ -notmatch '^!'}

    $serviceStartupDelayedAutoFilePath = "C:\Windows\Setup\Scripts\service_startup_delayed_auto.txt"
    $service_startup_delayed_auto = Get-Content $serviceStartupDelayedAutoFilePath | Where-Object {$_ -notmatch '^#' -and $_ -notmatch '^!'}

    $counter = 1
    foreach ($item in $service_stop) {
        Write-Progress -Activity 'Stopping Services' -CurrentOperation $item -PercentComplete (($counter / $service_stop.count) * 100)
        Start-Sleep -Milliseconds 200
        if (Get-Service $item -ErrorAction SilentlyContinue) {
            $detail = Get-Service -Name $item 
            Stop-Service -Name $item -Force
            Write-Host "Stopped service -" $detail.DisplayName "-" $item "---------- OK" -ForegroundColor Green
        } else {
            Write-Host "Error stopping service -" $item "---------- NOK" -ForegroundColor Yellow
        }
        $counter++
    }
    
    $counter = 1
    foreach ($item in $service_startup_disabled) {
        Write-Progress -Activity 'Setting service startup to disabled' -CurrentOperation $item -PercentComplete (($counter / $service_startup_disabled.count) * 100)
        Start-Sleep -Milliseconds 200
        if (Get-Service $item -ErrorAction SilentlyContinue) {
            $detail = Get-Service -Name $item
            Set-Service -Name $item -StartupType Disabled 
            Write-Host $detail.DisplayName "-" $item "- Service startup set to Disabled ---------- OK" -ForegroundColor Green
        } else {
            Write-Host $item "- Service unable to set startup Disabled ---------- NOK" -ForegroundColor Yellow
        }
        $counter++
    }
    
    $counter = 1
    foreach ($item in $service_startup_delayed_auto) {
        Write-Progress -Activity 'Setting service startup to delayed auto' -CurrentOperation $item -PercentComplete (($counter / $service_startup_delayed_auto.count) * 100)
        Start-Sleep -Milliseconds 200
        # Check if the service exists
        $serviceExists = Get-Service -Name $Service -ErrorAction SilentlyContinue
        if (-not $serviceExists) {
            Write-Host "Service '$Service' not found." -ForegroundColor Red
            continue
        }
        else{        
        # Set the service to Automatic
        Set-Service -Name $Service -StartupType Automatic
        Write-Host "Service '$Service' set to Automatic."
        
        # Modify the registry to enable Delayed Start
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Service"
        Set-ItemProperty -Path $regPath -Name "DelayedAutoStart" -Value 1
        
        Write-Host "Service '$Service' set to Automatic (Delayed Start)." -ForegroundColor Green
        }
        $counter++
    }
    
    Write-Host "Stage: Windows Services completed" -ForegroundColor Green
    Set-ItemProperty -Path 'HKCU:\osinstall_local' -Name stage -Value 'windows_settings'
    Set-Runonce
    Stop-Transcript
    Restart-Computer
} Catch {
    Write-Host "Stage: Windows Services Failed" -ForegroundColor Red
    Set-ItemProperty -Path 'HKCU:\osinstall_local' -Name stage -Value 'windows_services'
    Set-Runonce
    Stop-Transcript
    Pause
}
