#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Windows 11 Recovery Partition Creator — Final Version (with Auto-Partition Creation)
    
.DESCRIPTION
    All fixes included:
    - STEP 0: Auto-shrink C: and create recovery partition
    - VSS Shadow Copy for WIM capture
    - Hardcoded DISM paths (no variables, no delayed expansion)
    - ping instead of timeout (WinRE compatible)
    - Separate diskpart calls for re-hide
    - Full logging to Desktop log file
    - Unattend.xml for silent OOBE
    - Hidden partition support
    - Desktop shortcuts

.NOTES
    Run as Administrator
    Step 0 will create the recovery partition automatically if needed
#>

# ============================================================
# CONFIGURATION
# ============================================================
$RecoveryDriveLetter = ""
$RecoveryFolderName  = "RecoveryImage"
$RecoveryVolumeLabel = "Recovery"
$ImageName           = "Windows11CustomRecovery"
$ImageDescription    = "FullSystemWithAppsAndDrivers"
$CompressionType     = "maximum"
$LogFile             = "$env:USERPROFILE\Desktop\RecoverySetup_Log.txt"
$ShadowMountPoint    = "C:\ShadowCopyMount"

# Step 0 defaults
$DefaultShrinkSizeGB       = 50
$DefaultNewDriveLetter     = "R"
$DefaultNewVolumeLabel     = "Recovery"

# ============================================================
# LOGGING
# ============================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry  = "[$timestamp] [$Level] $Message"
    switch ($Level) {
        "INFO"    { Write-Host $logEntry -ForegroundColor Cyan }
        "SUCCESS" { Write-Host $logEntry -ForegroundColor Green }
        "WARNING" { Write-Host $logEntry -ForegroundColor Yellow }
        "ERROR"   { Write-Host $logEntry -ForegroundColor Red }
        "STEP"    {
            Write-Host ""
            Write-Host ("=" * 70) -ForegroundColor Magenta
            Write-Host "  $Message" -ForegroundColor Magenta
            Write-Host ("=" * 70) -ForegroundColor Magenta
        }
    }
    Add-Content -Path $LogFile -Value $logEntry
}

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║  Windows 11 - Recovery Partition Creator (Final)           ║" -ForegroundColor Cyan
    Write-Host "  ║  Full System Restore — Apps + Drivers + Settings           ║" -ForegroundColor Cyan
    Write-Host "  ║  Auto-Partition — WinRE — Logging — Hidden Partition      ║" -ForegroundColor Cyan
    Write-Host "  ╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================
# STEP 0: SHRINK C: AND CREATE RECOVERY PARTITION
# ============================================================

function Invoke-Step0_CreateRecoveryPartition {
    param(
        [int]$ShrinkSizeGB       = $DefaultShrinkSizeGB,
        [string]$NewDriveLetter  = $DefaultNewDriveLetter,
        [string]$NewVolumeLabel  = $DefaultNewVolumeLabel
    )

    Write-Log "STEP 0: SHRINK C: AND CREATE RECOVERY PARTITION" "STEP"

    $ShrinkSizeMB = $ShrinkSizeGB * 1024
    $ShrinkSizeBytes = [int64]$ShrinkSizeGB * 1GB

    # ────────────────────────────────────────────────────
    #  Sub-step 0a: Check if recovery partition already exists
    # ────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  ── Checking for existing recovery partition ──" -ForegroundColor Yellow

    $existingVol = Get-Volume -DriveLetter $NewDriveLetter -ErrorAction SilentlyContinue
    if ($existingVol) {
        $existingSizeGB = [math]::Round($existingVol.Size / 1GB, 2)
        $existingFreeGB = [math]::Round($existingVol.SizeRemaining / 1GB, 2)
        $existingLabel  = if ($existingVol.FileSystemLabel) { $existingVol.FileSystemLabel } else { "No Label" }

        Write-Host ""
        Write-Host "  ┌──────────────────────────────────────────────────┐" -ForegroundColor Yellow
        Write-Host "  │  ⚠  Drive ${NewDriveLetter}: already exists!     " -ForegroundColor Yellow
        Write-Host "  │  Label      : $existingLabel" -ForegroundColor Yellow
        Write-Host "  │  Size       : $existingSizeGB GB" -ForegroundColor Yellow
        Write-Host "  │  Free Space : $existingFreeGB GB" -ForegroundColor Yellow
        Write-Host "  │  FileSystem : $($existingVol.FileSystem)" -ForegroundColor Yellow
        Write-Host "  └──────────────────────────────────────────────────┘" -ForegroundColor Yellow
        Write-Host ""

        $useExisting = Read-Host "  Use existing ${NewDriveLetter}: as recovery partition? (Y/N) [Y]"
        if ([string]::IsNullOrEmpty($useExisting)) { $useExisting = 'Y' }

        if ($useExisting -eq 'Y' -or $useExisting -eq 'y') {
            Write-Log "Using existing drive ${NewDriveLetter}: as recovery partition." "SUCCESS"
            return @{
                Success     = $true
                DriveLetter = "${NewDriveLetter}:"
                Skipped     = $true
            }
        }
        else {
            Write-Log "Drive ${NewDriveLetter}: exists but user declined to use it." "ERROR"
            Write-Host "  Please free up drive letter ${NewDriveLetter}: or choose a different letter." -ForegroundColor Red
            return @{
                Success     = $false
                DriveLetter = $null
                Skipped     = $false
            }
        }
    }

    # Also check if any volume labeled "Recovery" exists on a different letter
    $recoveryVols = Get-Volume | Where-Object {
        $_.FileSystemLabel -eq $NewVolumeLabel -and
        $_.DriveType -eq 'Fixed' -and
        $_.DriveLetter -and
        $_.DriveLetter -ne 'C'
    }
    if ($recoveryVols) {
        foreach ($rv in $recoveryVols) {
            $rvSizeGB = [math]::Round($rv.Size / 1GB, 2)
            Write-Host "  Found volume labeled '$NewVolumeLabel' on $($rv.DriveLetter): ($rvSizeGB GB)" -ForegroundColor Yellow
        }
        $useLabeled = Read-Host "  Use one of these instead of creating a new partition? (Y/N) [N]"
        if ([string]::IsNullOrEmpty($useLabeled)) { $useLabeled = 'N' }

        if ($useLabeled -eq 'Y' -or $useLabeled -eq 'y') {
            $selectedLetter = ($recoveryVols | Select-Object -First 1).DriveLetter
            Write-Log "Using existing labeled volume ${selectedLetter}: as recovery partition." "SUCCESS"
            return @{
                Success     = $true
                DriveLetter = "${selectedLetter}:"
                Skipped     = $true
            }
        }
    }

    Write-Host "  No existing recovery partition found. Will create one." -ForegroundColor Cyan
    Write-Host ""

    # ────────────────────────────────────────────────────
    #  Sub-step 0b: Validate free space on C:
    # ────────────────────────────────────────────────────
    Write-Host "  ── Validating C: drive ──" -ForegroundColor Yellow

    $cVolume      = Get-Volume -DriveLetter C
    $cFreeSpaceGB = [math]::Round($cVolume.SizeRemaining / 1GB, 2)
    $cTotalSizeGB = [math]::Round($cVolume.Size / 1GB, 2)
    $cUsedGB      = [math]::Round(($cVolume.Size - $cVolume.SizeRemaining) / 1GB, 2)
    $bufferGB     = 10  # Keep 10GB free after shrink

    Write-Host "    Total Size  : $cTotalSizeGB GB" -ForegroundColor Gray
    Write-Host "    Used Space  : $cUsedGB GB" -ForegroundColor Gray
    Write-Host "    Free Space  : $cFreeSpaceGB GB" -ForegroundColor Gray
    Write-Host "    Shrink Size : $ShrinkSizeGB GB" -ForegroundColor Gray
    Write-Host "    Buffer      : $bufferGB GB (minimum remaining free space)" -ForegroundColor Gray
    Write-Host ""

    if ($cFreeSpaceGB -lt ($ShrinkSizeGB + $bufferGB)) {
        Write-Log "Insufficient free space on C: to shrink by $ShrinkSizeGB GB." "ERROR"
        Write-Host "    Need at least $($ShrinkSizeGB + $bufferGB) GB free, have $cFreeSpaceGB GB." -ForegroundColor Red
        Write-Host ""

        # Offer custom size
        $maxShrink = [math]::Floor($cFreeSpaceGB - $bufferGB)
        if ($maxShrink -ge 20) {
            Write-Host "    Maximum safe shrink size: $maxShrink GB" -ForegroundColor Yellow
            $customSize = Read-Host "    Enter custom shrink size in GB (minimum 20, or 0 to cancel)"
            if ($customSize -and [int]$customSize -ge 20 -and [int]$customSize -le $maxShrink) {
                $ShrinkSizeGB    = [int]$customSize
                $ShrinkSizeMB    = $ShrinkSizeGB * 1024
                $ShrinkSizeBytes = [int64]$ShrinkSizeGB * 1GB
                Write-Log "Custom shrink size: $ShrinkSizeGB GB" "INFO"
            }
            else {
                return @{ Success = $false; DriveLetter = $null; Skipped = $false }
            }
        }
        else {
            Write-Host "    Not enough space even for minimum 20 GB partition." -ForegroundColor Red
            return @{ Success = $false; DriveLetter = $null; Skipped = $false }
        }
    }

    Write-Host "  [✓] Sufficient free space available." -ForegroundColor Green

    # ────────────────────────────────────────────────────
    #  Sub-step 0c: Check partition support size
    # ────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  ── Checking partition constraints ──" -ForegroundColor Yellow

    $cPartition     = Get-Partition -DriveLetter C
    $currentSizeBytes = $cPartition.Size
    $newSizeBytes   = $currentSizeBytes - $ShrinkSizeBytes

    try {
        $supportedSize = Get-PartitionSupportedSize -DriveLetter C
        $minSizeGB     = [math]::Round($supportedSize.SizeMin / 1GB, 2)
        $maxSizeGB     = [math]::Round($supportedSize.SizeMax / 1GB, 2)
        $newSizeGB     = [math]::Round($newSizeBytes / 1GB, 2)

        Write-Host "    Current partition : $([math]::Round($currentSizeBytes / 1GB, 2)) GB" -ForegroundColor Gray
        Write-Host "    New size after    : $newSizeGB GB" -ForegroundColor Gray
        Write-Host "    Minimum allowed   : $minSizeGB GB" -ForegroundColor Gray
        Write-Host ""

        if ($newSizeBytes -lt $supportedSize.SizeMin) {
            Write-Log "Cannot shrink: new size ($newSizeGB GB) below minimum ($minSizeGB GB)." "ERROR"
            Write-Host "    Unmovable files may be blocking. Try:" -ForegroundColor Yellow
            Write-Host "    1. Disable hibernation: powercfg /hibernate off" -ForegroundColor White
            Write-Host "    2. Disable page file temporarily" -ForegroundColor White
            Write-Host "    3. Disable System Restore temporarily" -ForegroundColor White
            Write-Host "    4. Run defrag C: /O" -ForegroundColor White
            return @{ Success = $false; DriveLetter = $null; Skipped = $false }
        }

        Write-Host "  [✓] Partition can be shrunk to $newSizeGB GB." -ForegroundColor Green
    }
    catch {
        Write-Log "Warning: Could not verify partition supported size: $_" "WARNING"
        Write-Host "  [!] Could not verify partition limits. Proceeding anyway..." -ForegroundColor Yellow
    }

    # ────────────────────────────────────────────────────
    #  Sub-step 0d: Confirm with user
    # ────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
    Write-Host "  │  Summary of changes:                                      │" -ForegroundColor Yellow
    Write-Host "  │                                                            │" -ForegroundColor Yellow
    Write-Host "  │  C: drive will be shrunk by    : $ShrinkSizeGB GB" -ForegroundColor Yellow
    Write-Host "  │  New partition drive letter     : ${NewDriveLetter}:" -ForegroundColor Yellow
    Write-Host "  │  New partition label            : $NewVolumeLabel" -ForegroundColor Yellow
    Write-Host "  │  New partition file system      : NTFS (Quick Format)" -ForegroundColor Yellow
    Write-Host "  │  New partition size             : ~$ShrinkSizeGB GB" -ForegroundColor Yellow
    Write-Host "  │                                                            │" -ForegroundColor Yellow
    Write-Host "  │  ⚠  This operation modifies disk partitions!              │" -ForegroundColor Yellow
    Write-Host "  │  ⚠  Ensure you have a backup of important data!           │" -ForegroundColor Yellow
    Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
    Write-Host ""

    $confirm = Read-Host "  Type 'CREATE' to shrink C: and create the partition (anything else to cancel)"
    if ($confirm -ne 'CREATE') {
        Write-Log "Partition creation cancelled by user." "WARNING"
        return @{ Success = $false; DriveLetter = $null; Skipped = $false }
    }

    # ────────────────────────────────────────────────────
    #  Sub-step 0e: Shrink C: drive
    # ────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  ── Shrinking C: by $ShrinkSizeGB GB ($ShrinkSizeMB MB) ──" -ForegroundColor Yellow
    Write-Log "Shrinking C: by $ShrinkSizeGB GB..." "INFO"

    try {
        Resize-Partition -DriveLetter C -Size $newSizeBytes -ErrorAction Stop

        # Verify
        $updatedPartition = Get-Partition -DriveLetter C
        $updatedSizeGB    = [math]::Round($updatedPartition.Size / 1GB, 2)
        Write-Host "  [✓] C: successfully shrunk to $updatedSizeGB GB." -ForegroundColor Green
        Write-Log "C: shrunk to $updatedSizeGB GB." "SUCCESS"
    }
    catch {
        Write-Log "Failed to shrink C: drive: $_" "ERROR"
        Write-Host ""
        Write-Host "  ── Troubleshooting ──" -ForegroundColor Yellow
        Write-Host "    1. Run: powercfg /hibernate off" -ForegroundColor White
        Write-Host "    2. Disable page file on C: temporarily" -ForegroundColor White
        Write-Host "    3. Disable System Restore: vssadmin delete shadows /all" -ForegroundColor White
        Write-Host "    4. Defrag: defrag C: /O /V" -ForegroundColor White
        Write-Host "    5. Try a smaller shrink size" -ForegroundColor White
        return @{ Success = $false; DriveLetter = $null; Skipped = $false }
    }

    # ────────────────────────────────────────────────────
    #  Sub-step 0f: Create new partition
    # ────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  ── Creating new partition (${NewDriveLetter}:) ──" -ForegroundColor Yellow
    Write-Log "Creating new partition with drive letter ${NewDriveLetter}..." "INFO"

    try {
        $diskNumber = (Get-Partition -DriveLetter C).DiskNumber

        $newPartition = New-Partition -DiskNumber $diskNumber `
                                      -UseMaximumSize `
                                      -DriveLetter $NewDriveLetter `
                                      -ErrorAction Stop

        Write-Host "  [✓] Partition created on Disk $diskNumber with letter ${NewDriveLetter}:." -ForegroundColor Green
        Write-Log "Partition created: Disk $diskNumber, Letter ${NewDriveLetter}:." "SUCCESS"
    }
    catch {
        Write-Log "Failed to create partition: $_" "ERROR"
        Write-Host "  Attempting rollback is not automatic. You may need to extend C: manually." -ForegroundColor Red
        return @{ Success = $false; DriveLetter = $null; Skipped = $false }
    }

    # ────────────────────────────────────────────────────
    #  Sub-step 0g: Quick format as NTFS
    # ────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  ── Formatting ${NewDriveLetter}: as NTFS (Quick Format) ──" -ForegroundColor Yellow
    Write-Log "Formatting ${NewDriveLetter}: as NTFS with label '$NewVolumeLabel'..." "INFO"

    try {
        Format-Volume -DriveLetter $NewDriveLetter `
                      -FileSystem NTFS `
                      -NewFileSystemLabel $NewVolumeLabel `
                      -Confirm:$false `
                      -ErrorAction Stop

        Write-Host "  [✓] Format completed successfully." -ForegroundColor Green
        Write-Log "Format completed: NTFS, label '$NewVolumeLabel'." "SUCCESS"
    }
    catch {
        Write-Log "Failed to format partition: $_" "ERROR"
        return @{ Success = $false; DriveLetter = $null; Skipped = $false }
    }

    # ────────────────────────────────────────────────────
    #  Sub-step 0h: Display summary
    # ────────────────────────────────────────────────────
    $updatedC  = Get-Volume -DriveLetter C
    $newVol    = Get-Volume -DriveLetter $NewDriveLetter

    Write-Host ""
    Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor Green
    Write-Host "  │  ✅ RECOVERY PARTITION CREATED SUCCESSFULLY!              │" -ForegroundColor Green
    Write-Host "  │                                                            │" -ForegroundColor Green
    Write-Host "  │  C: Drive:                                                 │" -ForegroundColor Green
    Write-Host "  │    Size       : $([math]::Round($updatedC.Size / 1GB, 2)) GB" -ForegroundColor Green
    Write-Host "  │    Free Space : $([math]::Round($updatedC.SizeRemaining / 1GB, 2)) GB" -ForegroundColor Green
    Write-Host "  │                                                            │" -ForegroundColor Green
    Write-Host "  │  ${NewDriveLetter}: Drive:                                 " -ForegroundColor Green
    Write-Host "  │    Label      : $($newVol.FileSystemLabel)" -ForegroundColor Green
    Write-Host "  │    Size       : $([math]::Round($newVol.Size / 1GB, 2)) GB" -ForegroundColor Green
    Write-Host "  │    FileSystem : $($newVol.FileSystem)" -ForegroundColor Green
    Write-Host "  │    Health     : $($newVol.HealthStatus)" -ForegroundColor Green
    Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor Green
    Write-Host ""

    Write-Log "Recovery partition creation complete." "SUCCESS"

    return @{
        Success     = $true
        DriveLetter = "${NewDriveLetter}:"
        Skipped     = $false
    }
}

# ============================================================
# PARTITION SELECTION & PREREQUISITES
# ============================================================

function Show-AvailablePartitions {
    $volumes = Get-Volume | Where-Object {
        $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.DriveLetter -ne 'C'
    } | Sort-Object DriveLetter

    if ($volumes.Count -eq 0) {
        Write-Log "No suitable partitions found!" "ERROR"
        Write-Host ""
        Write-Host "  No non-C: fixed partitions detected." -ForegroundColor Yellow
        Write-Host ""
        return $null
    }

    Write-Host "  Available Drives:" -ForegroundColor Yellow
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor Gray
    foreach ($vol in $volumes) {
        $sizeGB = [math]::Round($vol.Size / 1GB, 2)
        $freeGB = [math]::Round($vol.SizeRemaining / 1GB, 2)
        $label  = if ($vol.FileSystemLabel) { $vol.FileSystemLabel } else { "No Label" }
        Write-Host ("  [{0}:]  {1,-20}  Total: {2,8} GB  |  Free: {3,8} GB" -f
            $vol.DriveLetter, $label, $sizeGB, $freeGB) -ForegroundColor White
    }
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor Gray
    Write-Host ""
    return $volumes
}

function Get-RecoveryDrive {
    $volumes = Show-AvailablePartitions
    if ($null -eq $volumes) { return $null }
    do {
        $inputDrive = Read-Host "  Enter Recovery partition drive letter (e.g., R, D, E)"
        $inputDrive = $inputDrive.Trim().ToUpper().TrimEnd(':')
        $selectedVol = $volumes | Where-Object { $_.DriveLetter -eq $inputDrive }
        if (-not $selectedVol) { Write-Log "Invalid drive letter. Try again." "WARNING" }
    } while (-not $selectedVol)
    return "${inputDrive}:"
}

function Test-Prerequisites {
    param([string]$RecoveryDrive)

    Write-Log "Running prerequisite checks..." "INFO"
    Write-Host ""
    $allPassed = $true

    # Admin check
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "  [✓] Administrator privileges" -ForegroundColor Green
    } else {
        Write-Host "  [✗] Administrator privileges" -ForegroundColor Red
        $allPassed = $false
    }

    # DISM check
    if (Test-Path "$env:SystemRoot\System32\Dism.exe") {
        Write-Host "  [✓] DISM.exe found" -ForegroundColor Green
    } else {
        Write-Host "  [✗] DISM.exe not found" -ForegroundColor Red
        $allPassed = $false
    }

    # Recovery drive check
    if (Test-Path "$RecoveryDrive\") {
        Write-Host "  [✓] Recovery drive ($RecoveryDrive) accessible" -ForegroundColor Green
    } else {
        Write-Host "  [✗] Recovery drive ($RecoveryDrive) not accessible" -ForegroundColor Red
        $allPassed = $false
    }

    # VSS check
    $vssSvc = Get-Service -Name VSS -ErrorAction SilentlyContinue
    if ($vssSvc) {
        Write-Host "  [✓] VSS Service available ($($vssSvc.Status))" -ForegroundColor Green
    } else {
        Write-Host "  [✗] VSS Service not found" -ForegroundColor Red
        $allPassed = $false
    }

    # Free space check
    $recVol = Get-Volume -DriveLetter ($RecoveryDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
    $srcVol = Get-Volume -DriveLetter 'C' -ErrorAction SilentlyContinue
    if ($recVol -and $srcVol) {
        $usedGB     = [math]::Round(($srcVol.Size - $srcVol.SizeRemaining) / 1GB, 2)
        $requiredGB = [math]::Round($usedGB * 0.7, 2)
        $freeGB     = [math]::Round($recVol.SizeRemaining / 1GB, 2)
        if ($freeGB -ge $requiredGB) {
            Write-Host "  [✓] Free space OK (Need ~${requiredGB}GB, Have ${freeGB}GB)" -ForegroundColor Green
        } else {
            Write-Host "  [✗] Insufficient space (Need ~${requiredGB}GB, Have ${freeGB}GB)" -ForegroundColor Red
            $allPassed = $false
        }
        Write-Host "  [i] C: used space: ${usedGB} GB" -ForegroundColor Gray
    }

    Write-Host ""
    return $allPassed
}

# ============================================================
# VSS SHADOW COPY
# ============================================================

function New-ShadowCopy {
    Write-Log "Creating VSS Shadow Copy of C: drive..." "INFO"

    Start-Service VSS -ErrorAction SilentlyContinue
    Start-Service swprv -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    try {
        $result = (Get-WmiObject -List Win32_ShadowCopy).Create("C:\", "ClientAccessible")

        if ($result.ReturnValue -ne 0) {
            Write-Log "Shadow copy failed with code: $($result.ReturnValue)" "ERROR"
            return $null
        }

        $shadowID   = $result.ShadowID
        $shadowCopy = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $shadowID }
        $shadowPath = $shadowCopy.DeviceObject

        Write-Log "Shadow copy created: $shadowPath" "SUCCESS"
        return @{
            ID         = $shadowID
            DevicePath = $shadowPath
        }
    }
    catch {
        Write-Log "Shadow copy exception: $_" "ERROR"
        return $null
    }
}

function Mount-ShadowCopy {
    param([string]$ShadowDevicePath, [string]$MountPoint)

    if (Test-Path $MountPoint) {
        cmd /c "rmdir `"$MountPoint`"" 2>$null
    }

    $deviceWithSlash = $ShadowDevicePath
    if (-not $deviceWithSlash.EndsWith('\')) {
        $deviceWithSlash += '\'
    }

    cmd /c "mklink /d `"$MountPoint`" `"$deviceWithSlash`"" 2>&1 | Out-Null

    if ((Test-Path $MountPoint) -and (Get-ChildItem $MountPoint -ErrorAction SilentlyContinue)) {
        Write-Log "Shadow copy mounted at $MountPoint" "SUCCESS"
        return $true
    }

    Write-Log "Shadow copy mount failed!" "ERROR"
    return $false
}

function Remove-ShadowCopyAndMount {
    param([string]$ShadowID, [string]$MountPoint)

    if (Test-Path $MountPoint) {
        cmd /c "rmdir `"$MountPoint`"" 2>$null
    }

    if ($ShadowID) {
        try {
            $shadow = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $ShadowID }
            if ($shadow) { $shadow.Delete() }
            Write-Log "Shadow copy cleaned up." "SUCCESS"
        }
        catch {
            Write-Log "Shadow cleanup warning: $_" "WARNING"
        }
    }
}

# ============================================================
# STEP 1: CAPTURE WIM IMAGE
# ============================================================

function Invoke-Step1_CaptureWIM {
    param(
        [string]$RecoveryDrive,
        [string]$FolderName,
        [string]$Name,
        [string]$Description,
        [string]$Compression
    )

    Write-Log "STEP 1: CAPTURE WIM IMAGE (via VSS Shadow Copy)" "STEP"

    $recoveryPath = Join-Path $RecoveryDrive $FolderName
    $wimFile      = Join-Path $recoveryPath "install.wim"
    $shadowInfo   = $null

    try {
        # Create folder
        if (-not (Test-Path $recoveryPath)) {
            New-Item -Path $recoveryPath -ItemType Directory -Force | Out-Null
            Write-Log "Created folder: $recoveryPath" "INFO"
        }

        # Check existing WIM
        if (Test-Path $wimFile) {
            $fileSize = [math]::Round((Get-Item $wimFile).Length / 1GB, 2)
            Write-Host ""
            Write-Host "  ⚠  Existing WIM found: $wimFile ($fileSize GB)" -ForegroundColor Yellow
            $overwrite = Read-Host "  Overwrite? (Y/N)"
            if ($overwrite -ne 'Y' -and $overwrite -ne 'y') {
                Write-Log "Using existing WIM file." "WARNING"
                return @{ Success = $true; WimFile = $wimFile; Skipped = $true }
            }
            Remove-Item $wimFile -Force
        }

        # Create shadow copy
        $shadowInfo = New-ShadowCopy
        if ($null -eq $shadowInfo) {
            return @{ Success = $false; WimFile = $null; Skipped = $false }
        }

        # Mount shadow copy
        $mounted = Mount-ShadowCopy -ShadowDevicePath $shadowInfo.DevicePath -MountPoint $ShadowMountPoint
        if (-not $mounted) {
            return @{ Success = $false; WimFile = $null; Skipped = $false }
        }

        # Capture
        Write-Host ""
        Write-Host "  ⏳ Capturing image... This takes 20-60 minutes." -ForegroundColor Yellow
        Write-Host "  ⚠  Do NOT restart or shut down your PC." -ForegroundColor Yellow
        Write-Host ""

        $startTime = Get-Date

        $batchFile = "$env:TEMP\dism_capture.cmd"
        @"
@echo off
DISM.exe /Capture-Image /ImageFile:"$wimFile" /CaptureDir:"$ShadowMountPoint" /Name:"$Name" /Description:"$Description" /Compress:$Compression
exit /b %errorlevel%
"@ | Out-File -FilePath $batchFile -Encoding ASCII -Force

        $proc = Start-Process -FilePath "cmd.exe" `
                              -ArgumentList "/c `"$batchFile`"" `
                              -NoNewWindow -Wait -PassThru

        $duration = (Get-Date) - $startTime
        Remove-Item $batchFile -Force -ErrorAction SilentlyContinue

        if ($proc.ExitCode -eq 0 -and (Test-Path $wimFile)) {
            $wimSize = [math]::Round((Get-Item $wimFile).Length / 1GB, 2)

            Write-Host ""
            Write-Host "  ┌──────────────────────────────────────────────────┐" -ForegroundColor Green
            Write-Host "  │  ✅ CAPTURE SUCCESSFUL!                           │" -ForegroundColor Green
            Write-Host "  │  File     : $wimFile" -ForegroundColor Green
            Write-Host "  │  Size     : $wimSize GB" -ForegroundColor Green
            Write-Host "  │  Duration : $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Green
            Write-Host "  └──────────────────────────────────────────────────┘" -ForegroundColor Green
            Write-Host ""

            # Verify
            Write-Log "Verifying captured image..." "INFO"
            & DISM.exe /Get-ImageInfo /ImageFile:"$wimFile"

            return @{ Success = $true; WimFile = $wimFile; Skipped = $false }
        }
        else {
            Write-Log "DISM capture FAILED! Exit code: $($proc.ExitCode)" "ERROR"
            Write-Host "  Check DISM log: notepad C:\Windows\Logs\DISM\dism.log" -ForegroundColor Yellow
            return @{ Success = $false; WimFile = $null; Skipped = $false }
        }
    }
    catch {
        Write-Log "Exception during capture: $_" "ERROR"
        return @{ Success = $false; WimFile = $null; Skipped = $false }
    }
    finally {
        # Always clean up shadow copy
        Write-Log "Cleaning up shadow copy..." "INFO"
        if ($shadowInfo) {
            Remove-ShadowCopyAndMount -ShadowID $shadowInfo.ID -MountPoint $ShadowMountPoint
        }
        elseif (Test-Path $ShadowMountPoint) {
            cmd /c "rmdir `"$ShadowMountPoint`"" 2>$null
        }
    }
}

# ============================================================
# STEP 1.5: UNATTEND.XML GENERATION
# ============================================================

function Get-CurrentSystemLocale {
    $culture  = Get-Culture
    $uiLang   = Get-WinSystemLocale
    $timezone = (Get-TimeZone).Id
    $keyboard = (Get-WinUserLanguageList)[0].InputMethodTips[0]
    $kbLayout = if ($keyboard) { $keyboard } else { "0409:00000409" }

    return @{
        SystemLocale = $uiLang.Name
        UILanguage   = $culture.Name
        UserLocale   = $culture.Name
        InputLocale  = $kbLayout
        TimeZone     = $timezone
        LanguageName = $culture.DisplayName
    }
}

function Get-UnattendSettings {
    Write-Log "STEP 1.5: CONFIGURE SILENT OOBE (unattend.xml)" "STEP"

    $currentLocale = Get-CurrentSystemLocale

    Write-Host ""
    Write-Host "  ── Detected System Settings ──" -ForegroundColor Yellow
    Write-Host "    Language  : $($currentLocale.LanguageName)" -ForegroundColor Gray
    Write-Host "    Locale    : $($currentLocale.SystemLocale)" -ForegroundColor Gray
    Write-Host "    Keyboard  : $($currentLocale.InputLocale)" -ForegroundColor Gray
    Write-Host "    Time Zone : $($currentLocale.TimeZone)" -ForegroundColor Gray
    Write-Host ""

    $useCurrentLocale = Read-Host "  Use current region/keyboard/language? (Y/N) [Y]"
    if ([string]::IsNullOrEmpty($useCurrentLocale)) { $useCurrentLocale = 'Y' }

    if ($useCurrentLocale -eq 'Y' -or $useCurrentLocale -eq 'y') {
        $locale      = $currentLocale.SystemLocale
        $uiLanguage  = $currentLocale.UILanguage
        $userLocale  = $currentLocale.UserLocale
        $inputLocale = $currentLocale.InputLocale
        $timeZone    = $currentLocale.TimeZone
    }
    else {
        Write-Host "  Common codes: en-US, fr-FR, de-DE, es-ES, nl-NL, pt-BR, ja-JP" -ForegroundColor Gray
        $locale      = Read-Host "  System Locale (e.g., fr-FR)"
        $uiLanguage  = Read-Host "  UI Language (e.g., fr-FR)"
        $userLocale  = Read-Host "  User Locale (e.g., fr-FR)"
        $inputLocale = Read-Host "  Keyboard (e.g., 040c:0000040c for French)"
        $timeZone    = Read-Host "  Time Zone (e.g., Romance Standard Time)"
    }

    Write-Host ""
    Write-Host "  ── Local User Account ──" -ForegroundColor Yellow

    $currentUser = $env:USERNAME
    $username    = Read-Host "  Username [$currentUser]"
    if ([string]::IsNullOrEmpty($username)) { $username = $currentUser }

    $password    = Read-Host "  Password (leave blank for no password)"
    $hasPassword = -not [string]::IsNullOrEmpty($password)

    $isAdmin     = Read-Host "  Make Administrator? (Y/N) [Y]"
    if ([string]::IsNullOrEmpty($isAdmin)) { $isAdmin = 'Y' }
    $groupName   = if ($isAdmin -eq 'Y' -or $isAdmin -eq 'y') { "Administrators" } else { "Users" }

    $currentPC    = $env:COMPUTERNAME
    $computerName = Read-Host "  Computer Name [$currentPC]"
    if ([string]::IsNullOrEmpty($computerName)) { $computerName = $currentPC }

    $autoLogon = Read-Host "  Auto-login after restore? (Y/N) [Y]"
    if ([string]::IsNullOrEmpty($autoLogon)) { $autoLogon = 'Y' }

    # Summary
    Write-Host ""
    Write-Host "  ┌──────────────────────────────────────────────────┐" -ForegroundColor White
    Write-Host "  │  Locale     : $locale" -ForegroundColor White
    Write-Host "  │  Keyboard   : $inputLocale" -ForegroundColor White
    Write-Host "  │  Time Zone  : $timeZone" -ForegroundColor White
    Write-Host "  │  Username   : $username" -ForegroundColor White
    Write-Host "  │  Password   : $(if ($hasPassword) {'****'} else {'(none)'})" -ForegroundColor White
    Write-Host "  │  Admin      : $groupName" -ForegroundColor White
    Write-Host "  │  PC Name    : $computerName" -ForegroundColor White
    Write-Host "  │  Auto-login : $autoLogon" -ForegroundColor White
    Write-Host "  └──────────────────────────────────────────────────┘" -ForegroundColor White
    Write-Host ""

    $confirm = Read-Host "  Confirm these settings? (Y/N)"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') { return $null }

    return @{
        Locale       = $locale
        UILanguage   = $uiLanguage
        UserLocale   = $userLocale
        InputLocale  = $inputLocale
        TimeZone     = $timeZone
        Username     = $username
        Password     = $password
        HasPassword  = $hasPassword
        GroupName    = $groupName
        ComputerName = $computerName
        AutoLogon    = ($autoLogon -eq 'Y' -or $autoLogon -eq 'y')
    }
}

function New-UnattendXml {
    param([hashtable]$S)

    $arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "x86" }

    $passwordBlock = if ($S.HasPassword) {
        $encodedPwd = [Convert]::ToBase64String(
            [System.Text.Encoding]::Unicode.GetBytes($S.Password + "Password")
        )
        "<Password><Value>$encodedPwd</Value><PlainText>false</PlainText></Password>"
    } else {
        "<Password><Value></Value><PlainText>true</PlainText></Password>"
    }

    $autoLogonBlock = ""
    if ($S.AutoLogon) {
        $autoLogonBlock = @"
                <AutoLogon>
                    <Enabled>true</Enabled>
                    <Username>$($S.Username)</Username>
                    <Password>
                        <Value>$($S.Password)</Value>
                        <PlainText>true</PlainText>
                    </Password>
                    <LogonCount>3</LogonCount>
                </AutoLogon>
"@
    }

    return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup"
                   processorArchitecture="$arch"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral" versionScope="nonSxS">
            <ComputerName>$($S.ComputerName)</ComputerName>
        </component>
        <component name="Microsoft-Windows-Deployment"
                   processorArchitecture="$arch"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core"
                   processorArchitecture="$arch"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral" versionScope="nonSxS">
            <InputLocale>$($S.InputLocale)</InputLocale>
            <SystemLocale>$($S.Locale)</SystemLocale>
            <UILanguage>$($S.UILanguage)</UILanguage>
            <UILanguageFallback>en-US</UILanguageFallback>
            <UserLocale>$($S.UserLocale)</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup"
                   processorArchitecture="$arch"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral" versionScope="nonSxS">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>3</ProtectYourPC>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
            </OOBE>
            <TimeZone>$($S.TimeZone)</TimeZone>
            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Name>$($S.Username)</Name>
                        <Group>$($S.GroupName)</Group>
                        <DisplayName>$($S.Username)</DisplayName>
                        $passwordBlock
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
$autoLogonBlock
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <CommandLine>reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</CommandLine>
                    <RequiresUserInput>false</RequiresUserInput>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <CommandLine>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\OOBE" /v DisablePrivacyExperience /t REG_DWORD /d 1 /f</CommandLine>
                    <RequiresUserInput>false</RequiresUserInput>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>
    </settings>
</unattend>
"@
}

function Save-UnattendXml {
    param([string]$RecoveryPath, [hashtable]$Settings)

    if ($null -eq $Settings) {
        Write-Log "Unattend configuration skipped." "WARNING"
        return
    }

    $xml = New-UnattendXml -S $Settings
    $unattendFile = Join-Path $RecoveryPath "unattend.xml"
    $xml | Out-File -FilePath $unattendFile -Encoding UTF8 -Force
    Write-Log "Saved: $unattendFile" "SUCCESS"
}

# ============================================================
# STEP 2: CREATE RECOVERY SCRIPTS
# ============================================================

function Invoke-Step2_CreateRecoveryScripts {
    param(
        [string]$RecoveryDrive,
        [string]$RecoveryPath,
        [string]$WimFile
    )

    Write-Log "STEP 2: CREATE RECOVERY SCRIPTS" "STEP"

    $diskNumber = (Get-Partition -DriveLetter C).DiskNumber
    $cPartNum   = (Get-Partition -DriveLetter C).PartitionNumber
    $partitions = Get-Partition -DiskNumber $diskNumber
    $efiPart    = $partitions | Where-Object {
        $_.Type -eq 'System' -or $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    }
    $efiPartNum = if ($efiPart) { $efiPart.PartitionNumber } else { 1 }

    $recDriveLetter = $RecoveryDrive.TrimEnd(':')
    $recPartition   = Get-Partition -DriveLetter $recDriveLetter
    $recPartNum     = $recPartition.PartitionNumber
    $recDiskNum     = $recPartition.DiskNumber
    $osPartSize     = [math]::Round((Get-Partition -DriveLetter C).Size / 1GB, 0)

    Write-Host ""
    Write-Host "  ── Partition Layout ──" -ForegroundColor Yellow
    Write-Host "    OS Disk       : $diskNumber, Partition $cPartNum (C:)" -ForegroundColor Gray
    Write-Host "    EFI           : $diskNumber, Partition $efiPartNum" -ForegroundColor Gray
    Write-Host "    Recovery      : $recDiskNum, Partition $recPartNum" -ForegroundColor Gray
    Write-Host ""

    # ════════════════════════════════════════════════════════
    #  RESTORE.CMD
    # ════════════════════════════════════════════════════════

    $restoreScript = @"
@echo off
cls
color 1F

mkdir C:\temp 2>nul

echo ================================================== > C:\temp\restore_log.txt
echo  FACTORY RESET LOG >> C:\temp\restore_log.txt
echo  Started: %date% %time% >> C:\temp\restore_log.txt
echo ================================================== >> C:\temp\restore_log.txt

echo.
echo  ========================================================
echo   FACTORY RESET - FULL SYSTEM RESTORE
echo   All data on C: will be PERMANENTLY DELETED!
echo   Log: C:\temp\restore_log.txt
echo  ========================================================
echo.

if /i "%1"=="AUTO" goto SKIP_CONFIRM

echo  Type YES to confirm factory reset:
set /p CONFIRM=
if /i not "%CONFIRM%"=="YES" (
    echo  Cancelled.
    echo  [%time%] Cancelled >> C:\temp\restore_log.txt
    pause
    exit /b 0
)

:SKIP_CONFIRM
echo  [%time%] Confirmed >> C:\temp\restore_log.txt

REM ──────────────────────────────────────────────────────
REM  STEP 1/6: FIND the recovery image
REM ──────────────────────────────────────────────────────

echo.
echo  [1/6] Searching for recovery image...
echo.
echo  [%time%] STEP 1: Finding recovery image >> C:\temp\restore_log.txt

set RECOVERY_DRIVE=
set WIM_FOUND=0

REM ── Method A: Scan all existing drive letters ──
echo  Scanning all drive letters...
echo  [%time%] Scanning drive letters A-Z >> C:\temp\restore_log.txt

if exist C:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=C:
    set WIM_FOUND=1
    echo  Found on C:
    echo  [%time%] Found on C: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist D:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=D:
    set WIM_FOUND=1
    echo  Found on D:
    echo  [%time%] Found on D: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist E:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=E:
    set WIM_FOUND=1
    echo  Found on E:
    echo  [%time%] Found on E: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist F:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=F:
    set WIM_FOUND=1
    echo  Found on F:
    echo  [%time%] Found on F: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist G:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=G:
    set WIM_FOUND=1
    echo  Found on G:
    echo  [%time%] Found on G: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist H:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=H:
    set WIM_FOUND=1
    echo  Found on H:
    echo  [%time%] Found on H: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist I:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=I:
    set WIM_FOUND=1
    echo  Found on I:
    echo  [%time%] Found on I: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist J:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=J:
    set WIM_FOUND=1
    echo  Found on J:
    echo  [%time%] Found on J: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist K:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=K:
    set WIM_FOUND=1
    echo  Found on K:
    echo  [%time%] Found on K: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist L:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=L:
    set WIM_FOUND=1
    echo  Found on L:
    echo  [%time%] Found on L: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist M:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=M:
    set WIM_FOUND=1
    echo  Found on M:
    echo  [%time%] Found on M: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist N:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=N:
    set WIM_FOUND=1
    echo  Found on N:
    echo  [%time%] Found on N: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist O:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=O:
    set WIM_FOUND=1
    echo  Found on O:
    echo  [%time%] Found on O: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist P:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=P:
    set WIM_FOUND=1
    echo  Found on P:
    echo  [%time%] Found on P: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist Q:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=Q:
    set WIM_FOUND=1
    echo  Found on Q:
    echo  [%time%] Found on Q: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist R:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=R:
    set WIM_FOUND=1
    echo  Found on R:
    echo  [%time%] Found on R: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist S:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=S:
    set WIM_FOUND=1
    echo  Found on S:
    echo  [%time%] Found on S: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist T:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=T:
    set WIM_FOUND=1
    echo  Found on T:
    echo  [%time%] Found on T: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist U:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=U:
    set WIM_FOUND=1
    echo  Found on U:
    echo  [%time%] Found on U: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist V:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=V:
    set WIM_FOUND=1
    echo  Found on V:
    echo  [%time%] Found on V: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist W:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=W:
    set WIM_FOUND=1
    echo  Found on W:
    echo  [%time%] Found on W: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist X:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=X:
    set WIM_FOUND=1
    echo  Found on X:
    echo  [%time%] Found on X: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist Y:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=Y:
    set WIM_FOUND=1
    echo  Found on Y:
    echo  [%time%] Found on Y: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)
if exist Z:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=Z:
    set WIM_FOUND=1
    echo  Found on Z:
    echo  [%time%] Found on Z: >> C:\temp\restore_log.txt
    goto FOUND_WIM
)

REM ── Method B: Not found on any letter — mount via diskpart ──
echo.
echo  Not found on any lettered drive.
echo  Mounting hidden partition (Disk $recDiskNum, Part $recPartNum) as R: ...
echo  [%time%] Not on any letter. Trying diskpart mount... >> C:\temp\restore_log.txt

(
echo select disk $recDiskNum
echo select partition $recPartNum
echo assign letter=R
echo exit
) > %TEMP%\dp_mount.txt

diskpart /s %TEMP%\dp_mount.txt >> C:\temp\restore_log.txt 2>&1
echo  [%time%] diskpart mount exit: %errorlevel% >> C:\temp\restore_log.txt
del %TEMP%\dp_mount.txt 2>nul

ping -n 5 127.0.0.1 > nul

if exist R:\$RecoveryFolderName\install.wim (
    set RECOVERY_DRIVE=R:
    set WIM_FOUND=1
    echo  Found after diskpart mount on R:
    echo  [%time%] Found on R: after diskpart >> C:\temp\restore_log.txt
    goto FOUND_WIM
)

REM ── ALL METHODS FAILED ──
echo.
echo  ════════════════════════════════════════════════════
echo   ERROR: Recovery image not found anywhere!
echo  ════════════════════════════════════════════════════
echo.
echo  [%time%] FATAL: Recovery image not found! >> C:\temp\restore_log.txt
echo  [%time%] Dumping volume list: >> C:\temp\restore_log.txt
(echo list volume
echo exit) > %TEMP%\dp_dbg.txt
diskpart /s %TEMP%\dp_dbg.txt >> C:\temp\restore_log.txt 2>&1
diskpart /s %TEMP%\dp_dbg.txt
del %TEMP%\dp_dbg.txt 2>nul
echo.
echo  Check log: C:\temp\restore_log.txt
pause
exit /b 1

:FOUND_WIM
echo.
echo  Recovery drive : %RECOVERY_DRIVE%
echo  Image file     : %RECOVERY_DRIVE%\$RecoveryFolderName\install.wim
echo.
echo  [%time%] Using drive: %RECOVERY_DRIVE% >> C:\temp\restore_log.txt

REM ──────────────────────────────────────────────────────
REM  STEP 2/6: Format C:
REM ──────────────────────────────────────────────────────

echo  [2/6] Formatting C: drive...
echo.
echo  [%time%] STEP 2: Formatting C: >> C:\temp\restore_log.txt

REM ── Save log before format ──
mkdir %RECOVERY_DRIVE%\temp 2>nul
copy /y C:\temp\restore_log.txt %RECOVERY_DRIVE%\temp\restore_log.txt > nul 2>nul

format C: /FS:NTFS /Q /Y /V:Windows
set FMT_ERR=%errorlevel%

REM ── Restore log after format ──
mkdir C:\temp 2>nul
copy /y %RECOVERY_DRIVE%\temp\restore_log.txt C:\temp\restore_log.txt > nul 2>nul
echo  [%time%] format exit: %FMT_ERR% >> C:\temp\restore_log.txt

if %FMT_ERR% neq 0 (
    echo  format.exe failed, using diskpart...
    echo  [%time%] format failed, trying diskpart >> C:\temp\restore_log.txt

    (
    echo select disk $diskNumber
    echo select partition $cPartNum
    echo format fs=ntfs quick label=Windows
    echo assign letter=C
    echo exit
    ) > %TEMP%\dp_fmt.txt

    diskpart /s %TEMP%\dp_fmt.txt >> C:\temp\restore_log.txt 2>&1
    del %TEMP%\dp_fmt.txt 2>nul

    mkdir C:\temp 2>nul
    copy /y %RECOVERY_DRIVE%\temp\restore_log.txt C:\temp\restore_log.txt > nul 2>nul
)

echo  C: formatted.
echo  [%time%] Format done >> C:\temp\restore_log.txt

REM ──────────────────────────────────────────────────────
REM  STEP 3/6: Apply recovery image
REM ──────────────────────────────────────────────────────

echo.
echo  [3/6] Applying recovery image (15-30 minutes)...
echo  DO NOT turn off your computer!
echo.
echo  [%time%] STEP 3: Applying image >> C:\temp\restore_log.txt
echo  [%time%] Source: %RECOVERY_DRIVE%\$RecoveryFolderName\install.wim >> C:\temp\restore_log.txt

DISM.exe /Apply-Image /ImageFile:%RECOVERY_DRIVE%\$RecoveryFolderName\install.wim /Index:1 /ApplyDir:C:\
set DISM_ERR=%errorlevel%
echo  [%time%] DISM exit: %DISM_ERR% >> C:\temp\restore_log.txt

if %DISM_ERR% neq 0 (
    echo.
    echo  Attempt 1 failed (code: %DISM_ERR%).
    echo  Trying without trailing backslash...
    echo  [%time%] Trying /ApplyDir:C: >> C:\temp\restore_log.txt

    DISM.exe /Apply-Image /ImageFile:%RECOVERY_DRIVE%\$RecoveryFolderName\install.wim /Index:1 /ApplyDir:C:
    set DISM_ERR2=%errorlevel%
    echo  [%time%] DISM attempt 2 exit: %DISM_ERR2% >> C:\temp\restore_log.txt

    if %DISM_ERR2% neq 0 (
        echo.
        echo  ALL DISM ATTEMPTS FAILED!
        echo  [%time%] ALL DISM FAILED >> C:\temp\restore_log.txt
        echo.
        echo  Source: %RECOVERY_DRIVE%\$RecoveryFolderName\install.wim
        echo  Target: C:\
        echo  Log: C:\temp\restore_log.txt
        pause
        exit /b 1
    )
)

echo.
echo  Image applied successfully!
echo  [%time%] Image applied OK >> C:\temp\restore_log.txt

REM ──────────────────────────────────────────────────────
REM  STEP 4/6: Rebuild boot
REM ──────────────────────────────────────────────────────

echo.
echo  [4/6] Rebuilding boot configuration...
echo.
echo  [%time%] STEP 4: Boot config >> C:\temp\restore_log.txt

(
echo select disk $diskNumber
echo select partition $efiPartNum
echo assign letter=S
echo exit
) > %TEMP%\dp_efi.txt

diskpart /s %TEMP%\dp_efi.txt >> C:\temp\restore_log.txt 2>&1
del %TEMP%\dp_efi.txt 2>nul

ping -n 3 127.0.0.1 > nul

echo  [%time%] bcdboot C:\Windows /s S: /f UEFI >> C:\temp\restore_log.txt
bcdboot C:\Windows /s S: /f UEFI >> C:\temp\restore_log.txt 2>&1
set BCD_ERR=%errorlevel%
echo  [%time%] bcdboot exit: %BCD_ERR% >> C:\temp\restore_log.txt

if %BCD_ERR% neq 0 (
    echo  [%time%] Trying without /s S: >> C:\temp\restore_log.txt
    bcdboot C:\Windows /f UEFI >> C:\temp\restore_log.txt 2>&1
)

(
echo select disk $diskNumber
echo select partition $efiPartNum
echo remove letter=S
echo exit
) > %TEMP%\dp_efi2.txt

diskpart /s %TEMP%\dp_efi2.txt >> C:\temp\restore_log.txt 2>&1
del %TEMP%\dp_efi2.txt 2>nul

echo  Boot rebuilt.
echo  [%time%] Boot done >> C:\temp\restore_log.txt

REM ──────────────────────────────────────────────────────
REM  STEP 5/6: Unattend.xml
REM ──────────────────────────────────────────────────────

echo.
echo  [5/6] Applying unattend.xml...
echo.
echo  [%time%] STEP 5: Unattend >> C:\temp\restore_log.txt

if exist %RECOVERY_DRIVE%\$RecoveryFolderName\unattend.xml (
    echo  [%time%] unattend.xml found >> C:\temp\restore_log.txt

    mkdir C:\Windows\Panther\unattend 2>nul
    mkdir C:\Windows\System32\Sysprep 2>nul

    copy /y %RECOVERY_DRIVE%\$RecoveryFolderName\unattend.xml C:\Windows\Panther\unattend\unattend.xml >> C:\temp\restore_log.txt 2>&1
    copy /y %RECOVERY_DRIVE%\$RecoveryFolderName\unattend.xml C:\Windows\Panther\unattend.xml >> C:\temp\restore_log.txt 2>&1
    copy /y %RECOVERY_DRIVE%\$RecoveryFolderName\unattend.xml C:\Windows\System32\Sysprep\unattend.xml >> C:\temp\restore_log.txt 2>&1

    reg load HKLM\OFFLINE_SW C:\Windows\System32\config\SOFTWARE >> C:\temp\restore_log.txt 2>&1
    reg add "HKLM\OFFLINE_SW\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f >> C:\temp\restore_log.txt 2>&1
    reg add "HKLM\OFFLINE_SW\Policies\Microsoft\Windows\OOBE" /v DisablePrivacyExperience /t REG_DWORD /d 1 /f >> C:\temp\restore_log.txt 2>&1
    reg unload HKLM\OFFLINE_SW >> C:\temp\restore_log.txt 2>&1

    echo  Unattend.xml applied.
    echo  [%time%] Unattend OK >> C:\temp\restore_log.txt
) else (
    echo  No unattend.xml found.
    echo  [%time%] No unattend.xml >> C:\temp\restore_log.txt
)

REM ──────────────────────────────────────────────────────
REM  STEP 6/6: Re-hide recovery partition
REM ──────────────────────────────────────────────────────

echo.
echo  [6/6] Re-hiding recovery partition...
echo.
echo  [%time%] STEP 6: Re-hide >> C:\temp\restore_log.txt

REM ── 6a: Remove whatever letter recovery has ──
echo  [%time%] 6a: Removing recovery drive letter >> C:\temp\restore_log.txt

(
echo select disk $recDiskNum
echo select partition $recPartNum
echo remove
echo exit
) > %TEMP%\dp_rh1.txt

diskpart /s %TEMP%\dp_rh1.txt >> C:\temp\restore_log.txt 2>&1
echo  [%time%] Remove letter exit: %errorlevel% >> C:\temp\restore_log.txt
del %TEMP%\dp_rh1.txt 2>nul

ping -n 3 127.0.0.1 > nul

REM ── 6b: Set partition type ──
echo  [%time%] 6b: Setting partition type >> C:\temp\restore_log.txt

(
echo select disk $recDiskNum
echo select partition $recPartNum
echo set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac override
echo exit
) > %TEMP%\dp_rh2.txt

diskpart /s %TEMP%\dp_rh2.txt >> C:\temp\restore_log.txt 2>&1
echo  [%time%] Set type exit: %errorlevel% >> C:\temp\restore_log.txt
del %TEMP%\dp_rh2.txt 2>nul

ping -n 3 127.0.0.1 > nul

REM ── 6c: Set GPT attributes ──
echo  [%time%] 6c: Setting GPT attributes >> C:\temp\restore_log.txt

(
echo select disk $recDiskNum
echo select partition $recPartNum
echo gpt attributes=0x8000000000000001
echo exit
) > %TEMP%\dp_rh3.txt

diskpart /s %TEMP%\dp_rh3.txt >> C:\temp\restore_log.txt 2>&1
echo  [%time%] Set GPT exit: %errorlevel% >> C:\temp\restore_log.txt
del %TEMP%\dp_rh3.txt 2>nul

echo  Re-hide complete.
echo  [%time%] Re-hide done >> C:\temp\restore_log.txt

REM ── Verify ──
echo  [%time%] Final volume list: >> C:\temp\restore_log.txt
(echo list volume
echo exit) > %TEMP%\dp_vfy.txt
diskpart /s %TEMP%\dp_vfy.txt >> C:\temp\restore_log.txt 2>&1
del %TEMP%\dp_vfy.txt 2>nul

REM ──────────────────────────────────────────────────────
REM  DONE
REM ──────────────────────────────────────────────────────

echo. >> C:\temp\restore_log.txt
echo ================================================== >> C:\temp\restore_log.txt
echo  COMPLETED: %date% %time% >> C:\temp\restore_log.txt
echo ================================================== >> C:\temp\restore_log.txt

echo.
echo  ========================================================
echo.
echo   FACTORY RESET COMPLETE!
echo   All applications, drivers, and settings restored.
echo   Log: C:\temp\restore_log.txt
echo.
echo   Restarting in 15 seconds...
echo.
echo  ========================================================
echo.

echo  15...
ping -n 4 127.0.0.1 > nul
echo  12...
ping -n 4 127.0.0.1 > nul
echo  8...
ping -n 5 127.0.0.1 > nul
echo  3...
ping -n 4 127.0.0.1 > nul

wpeutil reboot
"@

    # ════════════════════════════════════════════════════════
    #  DIAGNOSE.CMD
    # ════════════════════════════════════════════════════════

    $diagnoseScript = @"
@echo off
cls
color 1F

mkdir C:\temp 2>nul

echo RECOVERY DIAGNOSTICS LOG > C:\temp\diagnose_log.txt
echo %date% %time% >> C:\temp\diagnose_log.txt

echo.
echo  ========================================================
echo   RECOVERY DIAGNOSTICS (safe - no changes)
echo   Log: C:\temp\diagnose_log.txt
echo  ========================================================
echo.

echo  ── Current volumes ──
echo.
(echo list volume
echo exit) > %TEMP%\dd1.txt
diskpart /s %TEMP%\dd1.txt
diskpart /s %TEMP%\dd1.txt >> C:\temp\diagnose_log.txt 2>&1
del %TEMP%\dd1.txt 2>nul

echo.
echo  ── Partitions on Disk $diskNumber ──
echo.
(echo select disk $diskNumber
echo list partition
echo exit) > %TEMP%\dd2.txt
diskpart /s %TEMP%\dd2.txt
diskpart /s %TEMP%\dd2.txt >> C:\temp\diagnose_log.txt 2>&1
del %TEMP%\dd2.txt 2>nul

echo.
echo  ── Expected layout ──
echo    Windows  : Disk $diskNumber, Partition $cPartNum (C:)
echo    EFI      : Disk $diskNumber, Partition $efiPartNum
echo    Recovery : Disk $recDiskNum, Partition $recPartNum

echo.
echo  ── Scanning ALL drives for install.wim ──
echo.
echo  Scanning... >> C:\temp\diagnose_log.txt

if exist C:\$RecoveryFolderName\install.wim echo  FOUND on C:
if exist D:\$RecoveryFolderName\install.wim echo  FOUND on D:
if exist E:\$RecoveryFolderName\install.wim echo  FOUND on E:
if exist F:\$RecoveryFolderName\install.wim echo  FOUND on F:
if exist G:\$RecoveryFolderName\install.wim echo  FOUND on G:
if exist H:\$RecoveryFolderName\install.wim echo  FOUND on H:
if exist I:\$RecoveryFolderName\install.wim echo  FOUND on I:
if exist J:\$RecoveryFolderName\install.wim echo  FOUND on J:
if exist K:\$RecoveryFolderName\install.wim echo  FOUND on K:
if exist R:\$RecoveryFolderName\install.wim echo  FOUND on R:

echo.
echo  ── Trying diskpart mount (Disk $recDiskNum, Part $recPartNum as R:) ──
echo.
(echo select disk $recDiskNum
echo select partition $recPartNum
echo assign letter=R
echo exit) > %TEMP%\dd3.txt
diskpart /s %TEMP%\dd3.txt >> C:\temp\diagnose_log.txt 2>&1
del %TEMP%\dd3.txt 2>nul

ping -n 5 127.0.0.1 > nul

if exist R:\$RecoveryFolderName\install.wim (
    echo  FOUND on R: after diskpart mount
    DISM.exe /Get-ImageInfo /ImageFile:R:\$RecoveryFolderName\install.wim
) else (
    echo  NOT FOUND on R: after mount
    echo  R: contents:
    dir R:\ 2>nul
)

echo.
echo  ── Cleanup ──
(echo select disk $recDiskNum
echo select partition $recPartNum
echo remove
echo exit) > %TEMP%\dd4.txt
diskpart /s %TEMP%\dd4.txt >> C:\temp\diagnose_log.txt 2>&1
del %TEMP%\dd4.txt 2>nul

echo.
echo  ========================================================
echo   DONE. Log: C:\temp\diagnose_log.txt
echo.
echo   restore.cmd will auto-find the WIM on any drive letter.
echo   Just run: [drive]:\$RecoveryFolderName\restore.cmd
echo  ========================================================
echo.
pause
"@

    # ════════════════════════════════════════════════════════
    #  QUICK_RESTORE.CMD
    # ════════════════════════════════════════════════════════

    $quickRestoreScript = @"
@echo off
cls
mkdir C:\temp 2>nul
echo QUICK RESTORE %date% %time% > C:\temp\quick_restore_log.txt

echo  AUTOMATED FACTORY RESET...

set RECOVERY_DRIVE=
set WIM_FOUND=0

REM ── Scan all letters ──
if exist C:\$RecoveryFolderName\install.wim set RECOVERY_DRIVE=C:& set WIM_FOUND=1& goto QF
if exist D:\$RecoveryFolderName\install.wim set RECOVERY_DRIVE=D:& set WIM_FOUND=1& goto QF
if exist E:\$RecoveryFolderName\install.wim set RECOVERY_DRIVE=E:& set WIM_FOUND=1& goto QF
if exist F:\$RecoveryFolderName\install.wim set RECOVERY_DRIVE=F:& set WIM_FOUND=1& goto QF
if exist G:\$RecoveryFolderName\install.wim set RECOVERY_DRIVE=G:& set WIM_FOUND=1& goto QF
if exist H:\$RecoveryFolderName\install.wim set RECOVERY_DRIVE=H:& set WIM_FOUND=1& goto QF
if exist R:\$RecoveryFolderName\install.wim set RECOVERY_DRIVE=R:& set WIM_FOUND=1& goto QF

REM ── Diskpart mount ──
(echo select disk $recDiskNum
echo select partition $recPartNum
echo assign letter=R
echo exit) > %TEMP%\qm.txt
diskpart /s %TEMP%\qm.txt >> C:\temp\quick_restore_log.txt 2>&1
del %TEMP%\qm.txt 2>nul
ping -n 5 127.0.0.1 > nul

if exist R:\$RecoveryFolderName\install.wim set RECOVERY_DRIVE=R:& set WIM_FOUND=1& goto QF

echo FATAL: Not found! >> C:\temp\quick_restore_log.txt
echo FATAL: Recovery image not found!
pause
exit /b 1

:QF
echo  Found on %RECOVERY_DRIVE% >> C:\temp\quick_restore_log.txt

mkdir %RECOVERY_DRIVE%\temp 2>nul
copy /y C:\temp\quick_restore_log.txt %RECOVERY_DRIVE%\temp\quick_restore_log.txt > nul 2>nul

format C: /FS:NTFS /Q /Y /V:Windows

if errorlevel 1 (
    (echo select disk $diskNumber
    echo select partition $cPartNum
    echo format fs=ntfs quick label=Windows
    echo assign letter=C
    echo exit) > %TEMP%\qf.txt
    diskpart /s %TEMP%\qf.txt > nul 2>&1
    del %TEMP%\qf.txt 2>nul
)

mkdir C:\temp 2>nul
copy /y %RECOVERY_DRIVE%\temp\quick_restore_log.txt C:\temp\quick_restore_log.txt > nul 2>nul

DISM.exe /Apply-Image /ImageFile:%RECOVERY_DRIVE%\$RecoveryFolderName\install.wim /Index:1 /ApplyDir:C:\

if errorlevel 1 (
    DISM.exe /Apply-Image /ImageFile:%RECOVERY_DRIVE%\$RecoveryFolderName\install.wim /Index:1 /ApplyDir:C:
    if errorlevel 1 (
        echo DISM FAILED! >> C:\temp\quick_restore_log.txt
        echo CRITICAL: DISM failed!
        pause
        exit /b 1
    )
)

(echo select disk $diskNumber
echo select partition $efiPartNum
echo assign letter=S
echo exit) > %TEMP%\qe.txt
diskpart /s %TEMP%\qe.txt > nul 2>&1
del %TEMP%\qe.txt 2>nul
ping -n 3 127.0.0.1 > nul

bcdboot C:\Windows /s S: /f UEFI > nul 2>&1

if exist %RECOVERY_DRIVE%\$RecoveryFolderName\unattend.xml (
    mkdir C:\Windows\Panther\unattend 2>nul
    copy /y %RECOVERY_DRIVE%\$RecoveryFolderName\unattend.xml C:\Windows\Panther\unattend\unattend.xml
    copy /y %RECOVERY_DRIVE%\$RecoveryFolderName\unattend.xml C:\Windows\Panther\unattend.xml
    copy /y %RECOVERY_DRIVE%\$RecoveryFolderName\unattend.xml C:\Windows\System32\Sysprep\unattend.xml
    reg load HKLM\OFFLINE_SW C:\Windows\System32\config\SOFTWARE 2>nul
    reg add "HKLM\OFFLINE_SW\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f 2>nul
    reg add "HKLM\OFFLINE_SW\Policies\Microsoft\Windows\OOBE" /v DisablePrivacyExperience /t REG_DWORD /d 1 /f 2>nul
    reg unload HKLM\OFFLINE_SW 2>nul
)

(echo select disk $diskNumber
echo select partition $efiPartNum
echo remove letter=S
echo exit) > %TEMP%\qe2.txt
diskpart /s %TEMP%\qe2.txt > nul 2>&1
del %TEMP%\qe2.txt 2>nul
ping -n 3 127.0.0.1 > nul

(echo select disk $recDiskNum
echo select partition $recPartNum
echo remove
echo exit) > %TEMP%\qr1.txt
diskpart /s %TEMP%\qr1.txt > nul 2>&1
del %TEMP%\qr1.txt 2>nul
ping -n 3 127.0.0.1 > nul

(echo select disk $recDiskNum
echo select partition $recPartNum
echo set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac override
echo exit) > %TEMP%\qr2.txt
diskpart /s %TEMP%\qr2.txt > nul 2>&1
del %TEMP%\qr2.txt 2>nul
ping -n 3 127.0.0.1 > nul

(echo select disk $recDiskNum
echo select partition $recPartNum
echo gpt attributes=0x8000000000000001
echo exit) > %TEMP%\qr3.txt
diskpart /s %TEMP%\qr3.txt > nul 2>&1
del %TEMP%\qr3.txt 2>nul

echo COMPLETE >> C:\temp\quick_restore_log.txt
wpeutil reboot
"@

    # ── Save ──
    $restoreScript      | Out-File (Join-Path $RecoveryPath "restore.cmd") -Encoding ASCII -Force
    $diagnoseScript     | Out-File (Join-Path $RecoveryPath "diagnose.cmd") -Encoding ASCII -Force
    $quickRestoreScript | Out-File (Join-Path $RecoveryPath "quick_restore.cmd") -Encoding ASCII -Force

    @"
Recovery Partition Metadata
===========================
Created       : $(Get-Date)
OS Disk       : $diskNumber
OS Partition  : $cPartNum (C:, ~${osPartSize} GB)
EFI Partition : $efiPartNum
Recovery Disk : $recDiskNum
Recovery Part : $recPartNum
Folder        : $RecoveryFolderName

How restore.cmd finds the image:
  1. Scans ALL drive letters C: through Z:
  2. If not found, mounts Disk $recDiskNum Part $recPartNum as R:
  3. Uses whichever letter has the WIM

Re-hide uses separate diskpart calls:
  Step 1: remove (letter)
  Step 2: set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac
  Step 3: gpt attributes=0x8000000000000001
"@ | Out-File (Join-Path $RecoveryPath "recovery_metadata.txt") -Encoding ASCII -Force

    Write-Log "Created: restore.cmd" "SUCCESS"
    Write-Log "Created: diagnose.cmd" "SUCCESS"
    Write-Log "Created: quick_restore.cmd" "SUCCESS"

    Write-Host ""
    Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor Green
    Write-Host "  │  ✅ Recovery Scripts Created                              │" -ForegroundColor Green
    Write-Host "  │                                                            │" -ForegroundColor Green
    Write-Host "  │  Image search order:                                       │" -ForegroundColor Green
    Write-Host "  │  1. Scan ALL drive letters (C: through Z:)                │" -ForegroundColor Green
    Write-Host "  │  2. Diskpart mount Disk $recDiskNum Part $recPartNum as R:" -ForegroundColor Green
    Write-Host "  │  3. Use whichever letter has install.wim                  │" -ForegroundColor Green
    Write-Host "  │                                                            │" -ForegroundColor Green
    Write-Host "  │  Works whether partition is D:, R:, or hidden!            │" -ForegroundColor Green
    Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor Green

    return $true
}

# ============================================================
# STEP 3: CREATE DESKTOP SHORTCUTS
# ============================================================

function Invoke-Step3_CreateShortcuts {
    param(
        [string]$RecoveryDrive,
        [string]$RecoveryPath
    )

    Write-Log "STEP 3: CREATE DESKTOP SHORTCUTS" "STEP"

    $recPartition = Get-Partition -DriveLetter ($RecoveryDrive.TrimEnd(':'))
    $recPartNum   = $recPartition.PartitionNumber
    $recDiskNum   = $recPartition.DiskNumber

    $createShortcut = Read-Host "  Create desktop shortcuts? (Y/N) [Y]"
    if ([string]::IsNullOrEmpty($createShortcut)) { $createShortcut = 'Y' }

    if ($createShortcut -ne 'Y' -and $createShortcut -ne 'y') {
        Write-Log "Desktop shortcuts skipped." "INFO"
        return $true
    }

    # ── PowerShell Launcher ──
    $launcherPS = @"
#Requires -RunAsAdministrator
Add-Type -AssemblyName System.Windows.Forms

`$msg = "WARNING: This will ERASE ALL DATA on C: and restore the factory image with all original apps and drivers.`n`nALL personal files will be DELETED.`n`nProceed?"
`$r = [System.Windows.Forms.MessageBox]::Show(`$msg, "FACTORY RESET", "YesNo", "Warning")

if (`$r -eq "Yes") {
    `$r2 = [System.Windows.Forms.MessageBox]::Show(
        "FINAL CONFIRMATION`n`nComputer will restart into recovery.`nEstimated time: 20-40 minutes.`n`nContinue?",
        "CONFIRM FACTORY RESET", "YesNo", "Stop")

    if (`$r2 -eq "Yes") {
        Write-Host "Preparing recovery environment..."
        reagentc /enable 2>`$null
        reagentc /boottore
        shutdown /r /t 5 /c "Restarting for Factory Reset..."
    }
}
"@

    # ── Batch Wrapper (auto-elevates) ──
    $batchWrapper = @"
@echo off
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process cmd -ArgumentList '/c cd /d \"%~dp0\" && powershell -ExecutionPolicy Bypass -File \"%~dp0FactoryReset_Launcher.ps1\"' -Verb RunAs"
    exit /b
)
powershell -ExecutionPolicy Bypass -File "%~dp0FactoryReset_Launcher.ps1"
"@

    # ── Instructions ──
    $instructions = @"
FACTORY RESET INSTRUCTIONS
===========================

AUTOMATIC (Windows boots normally):
  1. Double-click "Factory Reset.bat" on Desktop
  2. Confirm twice
  3. PC restarts into recovery mode
  4. In recovery CMD, mount R: and run restore:
     diskpart
     select disk $recDiskNum
     select partition $recPartNum
     assign letter=R
     exit
     R:\$RecoveryFolderName\restore.cmd

MANUAL (SHIFT + Restart):
  1. Hold SHIFT + click Restart
  2. Troubleshoot → Command Prompt
  3. Run the diskpart + restore commands above

USB BOOT (Windows won't start):
  1. Boot from Windows 11 USB
  2. Repair → Command Prompt
  3. Run the diskpart + restore commands above

DIAGNOSTICS (safe test first):
  Mount R: then run: R:\$RecoveryFolderName\diagnose.cmd

LOG FILES:
  C:\temp\restore_log.txt   (after restore)
  C:\temp\diagnose_log.txt  (after diagnostics)

PARTITION INFO:
  Recovery: Disk $recDiskNum, Partition $recPartNum
"@

    # ── Save files ──
    $desktop = "$env:USERPROFILE\Desktop"

    $launcherPS   | Out-File "$desktop\FactoryReset_Launcher.ps1" -Encoding UTF8 -Force
    $batchWrapper | Out-File "$desktop\Factory Reset.bat" -Encoding ASCII -Force
    $instructions | Out-File "$desktop\Factory Reset - Instructions.txt" -Encoding UTF8 -Force
    $instructions | Out-File (Join-Path $RecoveryPath "INSTRUCTIONS.txt") -Encoding UTF8 -Force

    Write-Host "    ✓ Factory Reset.bat" -ForegroundColor Green
    Write-Host "    ✓ FactoryReset_Launcher.ps1" -ForegroundColor Green
    Write-Host "    ✓ Factory Reset - Instructions.txt" -ForegroundColor Green
    Write-Host "    ✓ INSTRUCTIONS.txt (on recovery partition)" -ForegroundColor Green

    Write-Log "Desktop shortcuts created." "SUCCESS"
    return $true
}

# ============================================================
# STEP 4: HIDE PARTITION (Optional)
# ============================================================

function Invoke-Step4_HidePartition {
    param([string]$RecoveryDrive)

    Write-Log "STEP 4: HIDE & PROTECT RECOVERY PARTITION" "STEP"

    $driveLetter = $RecoveryDrive.TrimEnd(':')

    # Find volume number
    $dpListFile = "$env:TEMP\dp_list.txt"
    "list volume" | Out-File -FilePath $dpListFile -Encoding ASCII
    $dpOutput = & diskpart /s $dpListFile 2>&1
    Remove-Item $dpListFile -Force -ErrorAction SilentlyContinue

    $volumeNumber = $null
    foreach ($line in $dpOutput) {
        if ($line -match "Volume\s+(\d+)\s+$driveLetter\s") {
            $volumeNumber = $Matches[1]
            break
        }
    }

    if ($null -eq $volumeNumber) {
        Write-Log "Could not find volume for ${driveLetter}:." "ERROR"
        return $false
    }

    Write-Host ""
    Write-Host "  This will:" -ForegroundColor Yellow
    Write-Host "    • Remove drive letter ${driveLetter}:" -ForegroundColor White
    Write-Host "    • Hide partition from File Explorer" -ForegroundColor White
    Write-Host "    • Set GPT recovery attributes" -ForegroundColor White
    Write-Host "    • Restore scripts will auto-mount it as R:" -ForegroundColor White
    Write-Host ""
    Write-Host "  Volume $volumeNumber = ${driveLetter}:" -ForegroundColor Cyan
    Write-Host ""

    $confirm = Read-Host "  Type 'HIDE' to proceed (anything else to cancel)"

    if ($confirm -eq 'HIDE') {
        # Separate operations for reliability

        # Remove letter
        $dp1 = @"
select volume $volumeNumber
remove letter=$driveLetter
exit
"@
        $dp1 | Out-File "$env:TEMP\dp_h1.txt" -Encoding ASCII
        & diskpart /s "$env:TEMP\dp_h1.txt"
        Remove-Item "$env:TEMP\dp_h1.txt" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

        # Set partition type
        $dp2 = @"
select volume $volumeNumber
set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac override
exit
"@
        $dp2 | Out-File "$env:TEMP\dp_h2.txt" -Encoding ASCII
        & diskpart /s "$env:TEMP\dp_h2.txt"
        Remove-Item "$env:TEMP\dp_h2.txt" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

        # Set GPT attributes
        $dp3 = @"
select volume $volumeNumber
gpt attributes=0x8000000000000001
exit
"@
        $dp3 | Out-File "$env:TEMP\dp_h3.txt" -Encoding ASCII
        & diskpart /s "$env:TEMP\dp_h3.txt"
        Remove-Item "$env:TEMP\dp_h3.txt" -Force -ErrorAction SilentlyContinue

        Write-Host ""
        Write-Host "  ┌──────────────────────────────────────────────────┐" -ForegroundColor Green
        Write-Host "  │  ✅ Partition hidden and protected!               │" -ForegroundColor Green
        Write-Host "  │                                                    │" -ForegroundColor Green
        Write-Host "  │  To unhide later:                                 │" -ForegroundColor Green
        Write-Host "  │  diskpart → list volume → select volume X →       │" -ForegroundColor Green
        Write-Host "  │  assign letter=R                                  │" -ForegroundColor Green
        Write-Host "  └──────────────────────────────────────────────────┘" -ForegroundColor Green

        Write-Log "Partition hidden successfully." "SUCCESS"
        return $true
    }

    Write-Log "Hide cancelled by user." "WARNING"
    return $false
}

# ============================================================
# MAIN
# ============================================================

function Main {
    "Recovery Setup Log (Final + Auto-Partition) - $(Get-Date)" | Out-File -FilePath $LogFile -Force

    Show-Banner

    # ── Admin check ──
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Must run as Administrator!" "ERROR"
        Write-Host "  Right-click PowerShell → Run as Administrator" -ForegroundColor Yellow
        Read-Host "  Press Enter to exit"
        exit 1
    }

    Write-Log "Running with Administrator privileges." "SUCCESS"

    # ═══════════════════════════════════
    #  STEP 0: CREATE OR SELECT RECOVERY PARTITION
    # ═══════════════════════════════════
    Write-Host ""
    Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "  │  How would you like to set up the recovery partition?     │" -ForegroundColor Cyan
    Write-Host "  │                                                            │" -ForegroundColor Cyan
    Write-Host "  │  [1] AUTO — Shrink C: and create new partition            │" -ForegroundColor Cyan
    Write-Host "  │             (Recommended — creates R: automatically)       │" -ForegroundColor Cyan
    Write-Host "  │                                                            │" -ForegroundColor Cyan
    Write-Host "  │  [2] MANUAL — Select an existing partition                │" -ForegroundColor Cyan
    Write-Host "  │             (Use if you already created one)              │" -ForegroundColor Cyan
    Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
    Write-Host ""

    $partitionChoice = Read-Host "  Enter choice (1 or 2) [1]"
    if ([string]::IsNullOrEmpty($partitionChoice)) { $partitionChoice = '1' }

    if ($partitionChoice -eq '1') {
        # ── AUTO: Shrink C: and create partition ──
        Write-Host ""
        Write-Host "  ── Auto-Partition Configuration ──" -ForegroundColor Yellow
        Write-Host ""

        $sizeInput = Read-Host "  Recovery partition size in GB [$DefaultShrinkSizeGB]"
        if ([string]::IsNullOrEmpty($sizeInput)) { $shrinkGB = $DefaultShrinkSizeGB } else { $shrinkGB = [int]$sizeInput }

        $letterInput = Read-Host "  Drive letter [$DefaultNewDriveLetter]"
        if ([string]::IsNullOrEmpty($letterInput)) { $newLetter = $DefaultNewDriveLetter } else { $newLetter = $letterInput.Trim().ToUpper() }

        $labelInput = Read-Host "  Volume label [$DefaultNewVolumeLabel]"
        if ([string]::IsNullOrEmpty($labelInput)) { $newLabel = $DefaultNewVolumeLabel } else { $newLabel = $labelInput.Trim() }

        $step0 = Invoke-Step0_CreateRecoveryPartition `
            -ShrinkSizeGB $shrinkGB `
            -NewDriveLetter $newLetter `
            -NewVolumeLabel $newLabel

        if (-not $step0.Success) {
            Write-Log "Step 0 FAILED. Cannot continue without a recovery partition." "ERROR"
            Read-Host "  Press Enter to exit"
            exit 1
        }

        $RecoveryDriveLetter = $step0.DriveLetter
        Write-Log "Recovery partition ready: $RecoveryDriveLetter" "SUCCESS"
    }
    else {
        # ── MANUAL: Select existing partition ──
        if ([string]::IsNullOrEmpty($RecoveryDriveLetter)) {
            $RecoveryDriveLetter = Get-RecoveryDrive
            if ($null -eq $RecoveryDriveLetter) {
                Write-Log "No recovery partition selected. Exiting." "ERROR"
                Read-Host "  Press Enter to exit"
                exit 1
            }
        }
    }

    Write-Log "Selected recovery drive: $RecoveryDriveLetter" "INFO"

    # ── Prerequisites ──
    if (-not (Test-Prerequisites -RecoveryDrive $RecoveryDriveLetter)) {
        Write-Log "Prerequisites FAILED. Fix issues above and re-run." "ERROR"
        Read-Host "  Press Enter to exit"
        exit 1
    }

    Write-Log "All prerequisites PASSED." "SUCCESS"

    # ── Confirm ──
    Write-Host ""
    Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
    Write-Host "  │  Process:                                                 │" -ForegroundColor Yellow
    Write-Host "  │                                                            │" -ForegroundColor Yellow
    Write-Host "  │  Step 0  : ✅ Recovery partition ready ($RecoveryDriveLetter)" -ForegroundColor Yellow
    Write-Host "  │  Step 1  : Capture WIM (VSS Shadow Copy)                  │" -ForegroundColor Yellow
    Write-Host "  │  Step 1.5: Generate unattend.xml (silent OOBE)            │" -ForegroundColor Yellow
    Write-Host "  │  Step 2  : Create restore scripts (WinRE-compatible)      │" -ForegroundColor Yellow
    Write-Host "  │  Step 3  : Desktop shortcuts                              │" -ForegroundColor Yellow
    Write-Host "  │  Step 4  : (Optional) Hide partition                      │" -ForegroundColor Yellow
    Write-Host "  │                                                            │" -ForegroundColor Yellow
    Write-Host "  │  ✅ All apps, drivers, settings preserved on restore      │" -ForegroundColor Yellow
    Write-Host "  │  ⏱  Estimated: 30-75 minutes                              │" -ForegroundColor Yellow
    Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
    Write-Host ""

    $proceed = Read-Host "  Proceed? (Y/N)"
    if ($proceed -ne 'Y' -and $proceed -ne 'y') {
        Write-Log "User cancelled." "WARNING"
        exit 0
    }

    $recoveryFolderPath = Join-Path $RecoveryDriveLetter $RecoveryFolderName

    # ═══════════════════════════════════
    #  STEP 1: Capture WIM
    # ═══════════════════════════════════
    $step1 = Invoke-Step1_CaptureWIM `
        -RecoveryDrive $RecoveryDriveLetter `
        -FolderName $RecoveryFolderName `
        -Name $ImageName `
        -Description $ImageDescription `
        -Compression $CompressionType

    if (-not $step1.Success) {
        Write-Log "Step 1 FAILED. Check DISM log." "ERROR"
        Write-Host "  notepad C:\Windows\Logs\DISM\dism.log" -ForegroundColor Yellow
        Read-Host "  Press Enter to exit"
        exit 1
    }

    # ═══════════════════════════════════
    #  STEP 1.5: Unattend.xml
    # ═══════════════════════════════════
    Write-Host ""
    $doUnattend = Read-Host "  Configure silent recovery (skip OOBE screens)? (Y/N) [Y]"
    if ([string]::IsNullOrEmpty($doUnattend)) { $doUnattend = 'Y' }

    if ($doUnattend -eq 'Y' -or $doUnattend -eq 'y') {
        $settings = Get-UnattendSettings
        Save-UnattendXml -RecoveryPath $recoveryFolderPath -Settings $settings
    }
    else {
        Write-Log "Unattend.xml skipped. OOBE screens will appear on restore." "INFO"
    }

    # ═══════════════════════════════════
    #  STEP 2: Recovery Scripts
    # ═══════════════════════════════════
    Invoke-Step2_CreateRecoveryScripts `
        -RecoveryDrive $RecoveryDriveLetter `
        -RecoveryPath $recoveryFolderPath `
        -WimFile $step1.WimFile

    # ═══════════════════════════════════
    #  STEP 3: Desktop Shortcuts
    # ═══════════════════════════════════
    Invoke-Step3_CreateShortcuts `
        -RecoveryDrive $RecoveryDriveLetter `
        -RecoveryPath $recoveryFolderPath

    # ═══════════════════════════════════
    #  STEP 4: Hide Partition
    # ═══════════════════════════════════
    Write-Host ""
    Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "  │  Hide recovery partition?                                 │" -ForegroundColor Cyan
    Write-Host "  │                                                            │" -ForegroundColor Cyan
    Write-Host "  │  [Y] Production — hidden from Explorer, auto-mounted     │" -ForegroundColor Cyan
    Write-Host "  │  [N] Testing — keep visible for debugging                │" -ForegroundColor Cyan
    Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
    Write-Host ""

    $hide = Read-Host "  (Y/N)"
    if ($hide -eq 'Y' -or $hide -eq 'y') {
        Invoke-Step4_HidePartition -RecoveryDrive $RecoveryDriveLetter
    }
    else {
        Write-Log "Partition not hidden (testing mode)." "INFO"
    }

    # ═══════════════════════════════════
    #  COMPLETE
    # ═══════════════════════════════════
    Write-Host ""
    Write-Host "  ╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "  ║  ✅  RECOVERY PARTITION SETUP COMPLETE!                    ║" -ForegroundColor Green
    Write-Host "  ╠════════════════════════════════════════════════════════════╣" -ForegroundColor Green
    Write-Host "  ║                                                            ║" -ForegroundColor Green
    Write-Host "  ║  Recovery Partition Contents:                               ║" -ForegroundColor Green
    Write-Host "  ║  ├── install.wim           (full system image)            ║" -ForegroundColor Green
    Write-Host "  ║  ├── unattend.xml          (silent OOBE)                  ║" -ForegroundColor Green
    Write-Host "  ║  ├── restore.cmd           (interactive restore + log)    ║" -ForegroundColor Green
    Write-Host "  ║  ├── diagnose.cmd          (safe testing)                 ║" -ForegroundColor Green
    Write-Host "  ║  ├── quick_restore.cmd     (automated)                    ║" -ForegroundColor Green
    Write-Host "  ║  ├── recovery_metadata.txt (partition info)               ║" -ForegroundColor Green
    Write-Host "  ║  └── INSTRUCTIONS.txt      (how to restore)              ║" -ForegroundColor Green
    Write-Host "  ║                                                            ║" -ForegroundColor Green
    Write-Host "  ║  Desktop Files:                                            ║" -ForegroundColor Green
    Write-Host "  ║  ├── Factory Reset.bat                                    ║" -ForegroundColor Green
    Write-Host "  ║  ├── FactoryReset_Launcher.ps1                            ║" -ForegroundColor Green
    Write-Host "  ║  └── Factory Reset - Instructions.txt                     ║" -ForegroundColor Green
    Write-Host "  ║                                                            ║" -ForegroundColor Green
    Write-Host "  ║  HOW TO RESTORE:                                           ║" -ForegroundColor Green
    Write-Host "  ║  1. SHIFT+Restart → Troubleshoot → CMD                    ║" -ForegroundColor Green
    Write-Host "  ║  2. Mount R: (diskpart commands in Instructions.txt)      ║" -ForegroundColor Green
    Write-Host "  ║  3. R:\$RecoveryFolderName\diagnose.cmd  (test first)"       -ForegroundColor Green
    Write-Host "  ║  4. R:\$RecoveryFolderName\restore.cmd   (restore)"          -ForegroundColor Green
    Write-Host "  ║                                                            ║" -ForegroundColor Green
    Write-Host "  ║  LOG FILES (after restore):                                ║" -ForegroundColor Green
    Write-Host "  ║  C:\temp\restore_log.txt                                  ║" -ForegroundColor Green
    Write-Host "  ║  C:\temp\diagnose_log.txt                                 ║" -ForegroundColor Green
    Write-Host "  ║                                                            ║" -ForegroundColor Green
    Write-Host "  ║  Setup log: $LogFile" -ForegroundColor Green
    Write-Host "  ║                                                            ║" -ForegroundColor Green
    Write-Host "  ╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""

    Write-Log "Setup completed successfully." "SUCCESS"
    Read-Host "  Press Enter to exit"
}

# ── Run ──
Main
