#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Checks for internet connectivity, determines system manufacturer, and installs/updates drivers accordingly.
#>

# 1. Function to check internet connection and prompt user
function Confirm-InternetConnection {
    $connected = $false
    while (-not $connected) {
        Write-Host "Checking for internet connection..." -ForegroundColor Cyan
        # Ping a reliable external server (Google DNS used here)
        $ping = Test-NetConnection -ComputerName 8.8.8.8 -WarningAction SilentlyContinue
        
        if ($ping.PingSucceeded) {
            Write-Host "Internet connection established." -ForegroundColor Green
            $connected = $true
        } else {
            Write-Warning "No internet connection detected."
            $response = Read-Host "Would you like to try again? (Y/N)"
            
            if ($response -notmatch '^[Yy]$') {
                Write-Host "Exiting script." -ForegroundColor Yellow
                exit
            }
        }
    }
}

# 2. Main Execution
Confirm-InternetConnection

# Check system manufacturer
$manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer
Write-Host "System Manufacturer detected: $manufacturer" -ForegroundColor Cyan

# 3. Manufacturer Logic
if ($manufacturer -match "Dell") {
    Write-Host "Starting Dell update process..." -ForegroundColor Green
    
    # Install Dell Command Update via Chocolatey
    Write-Host "Installing Dell Command | Update..."
    choco install -y dellcommandupdate
    
    # Define paths (checking both 64-bit and 32-bit standard install locations)
    $dcuPaths = @(
        "C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe",
        "C:\Program Files\Dell\CommandUpdate\dcu-cli.exe"
    )
    
    $validPath = $dcuPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($validPath) {
        # Enable Advanced Driver Restore
        Write-Host "Enabling Advanced Driver Restore..."
        Start-Process -FilePath $validPath -ArgumentList "/configure -advanceddriverrestore=enable" -Wait -NoNewWindow
        
        # Apply Updates
        Write-Host "Applying system updates..."
        Start-Process -FilePath $validPath -ArgumentList "/applyupdates" -Wait -NoNewWindow
        
        Write-Host "Dell updates have been applied." -ForegroundColor Green
    } else {
        Write-Warning "Dell Command Update CLI (dcu-cli.exe) could not be found. Installation may have failed or installed to a non-standard directory."
    }

} 
elseif ($manufacturer -match "HP" -or $manufacturer -match "Hewlett-Packard") {
    Write-Host "Starting HP update process..." -ForegroundColor Green
    
    # Install HP Image Assistant via Chocolatey
    Write-Host "Installing HP Image Assistant..."
    choco install -y hpimageassistant
    
    # Chocolatey usually places the HPIA executable in the PATH or in a specific directory.
    # We will try to call HPImageAssistant.exe directly assuming the package adds it to the PATH.
    # If it doesn't, you may need to specify the absolute path (e.g., C:\Program Files (x86)\HP\HP Image Assistant\HPImageAssistant.exe)
    
    $hpiaCommand = "HPImageAssistant.exe"
    
    # HPIA arguments for silent, non-interactive installation without rebooting
    # /Operation:Analyze - Scans the system
    # /Action:Install - Installs the missing drivers/software
    # /Selection:All - Selects all applicable updates
    # /Silent /Noninteractive - Runs quietly without user prompts
    $hpiaArgs = "/Operation:Analyze /Action:Install /Selection:All /Silent /Noninteractive"
    
    Write-Host "Running HP Image Assistant silently (This may take a while)..."
    try {
        Start-Process -FilePath $hpiaCommand -ArgumentList $hpiaArgs -Wait -NoNewWindow
        Write-Host "HP updates have been applied successfully." -ForegroundColor Green
    } catch {
        Write-Warning "Failed to execute HP Image Assistant. Ensure it is properly installed and added to your system PATH."
    }

} 
else {
    Write-Host "Manufacturer '$manufacturer' is not supported by this script. No driver tools were installed." -ForegroundColor Yellow
}

Write-Host "Script execution completed." -ForegroundColor Cyan
