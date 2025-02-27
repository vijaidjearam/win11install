# Win11Install

A script to streamline the installation of Windows 11.

## Table of Contents

- [Introduction](#introduction)
- [Features](#features)
- [Requirements](#requirements)
- [Usage](#usage)
- [ventoy config](#ventoy config)

  
## Introduction

Win11Install is designed to simplify the process of installing Windows 11 by automating tasks and ensuring optimal configuration.

## Features

- Automated installation process
- Pre-configured settings for optimal performance
- Support for various hardware configurations

## Requirements
 - Bios Passwords has to be removed (The script tries to update the BIOS if there is any bios password set , then the script would not be able to complete the process.)
 - The script requires an internet connection to download necessary files from GitHub. Ensure the PC obtains an IP address via DHCP.
 - If the network card drivers are missing, the script may fail to connect to the internet. To resolve this, download the appropriate driver packs and place them in root:\drivers. The unattended XML file is configured to check the root:\drivers folder for drivers during the WinPE setup.
 - Driver pack download:
     - Dell : [Dell Family Driver Packs](https://www.dell.com/support/kbdoc/en-us/000180534/dell-family-driver-packs)
     - HP : [HP WinPE Driver Pack](https://ftp.hp.com/pub/caps-softpaq/cmit/HP_WinPE_DriverPack.html)

## Usage
- Registryrunonce.ps1 -> *$repopath = "https://raw.githubusercontent.com/vijaidjearam/win11install/main/"* change the value according to your Repo
- Autounattend-WinEdu.xml -> change the value in the *$uri* according to you Repo

  ```xml
	<File path="C:\Windows\Setup\Scripts\unattend-01.ps1">
	$attempts = 0
	do {
	    try {
	        $uri = [uri]::new('https://raw.githubusercontent.com/vijaidjearam/win11install/main/registryrunonce.ps1');
	        $file = 'c:\windows\temp\header.ps1';
	        [System.Net.WebClient]::new().DownloadFile($uri,$file);
	        Write-Host "Download successful!"
	        break
	    } catch {
	        Write-Host "Download failed, retrying..."
	        Start-Sleep -Seconds 5
	    }
	    $attempts++
	} while ($attempts -lt 10)
	</File>
  ```
  ## Ventoy-Config

  - Ventoy provides the modularity to add an autounttend.xml to a windows iso ( Without Ventoy we need an iso editor to incorporate the xml to the iso)
  - below image shows how we can attribute and autounattend.xml to iso
  - ![ventoy-part](https://github.com/user-attachments/assets/cbc8e3fd-4be0-45ac-8f09-32fd08317d70)
