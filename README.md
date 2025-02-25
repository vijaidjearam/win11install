# Win11Install

A script to streamline the installation of Windows 11.

## Table of Contents

- [Introduction](#introduction)
- [Features](#features)
- [Usage](#usage)
- [Requirements](#requirements)
  
## Introduction

Win11Install is designed to simplify the process of installing Windows 11 by automating tasks and ensuring optimal configuration.

## Features

- Automated installation process
- Pre-configured settings for optimal performance
- Support for various hardware configurations

## Usage
- Registryrunonce.ps1 -> $repopath = "https://raw.githubusercontent.com/vijaidjearam/win11install/main/" change the value according to your Repo
- Autounattend-WinEdu.xml -> change the value in the URI according to you Repo

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
## Requirements
 - The script requires internet to download the file from github, Makesure the PC gets an IP via DHCP.
 - The script could fail to connect to the internet if the network card drivers are not found, to fix this issue download the appropriate driver packs and place it in the folder "drivers" in the root of the driver. The unattended XML points to the root:\drivers folder to check for drivers dusing the winpe setup.
 - Driver pack download:
     - Dell : [https://www.dell.com/support/kbdoc/en-us/000180534/dell-family-driver-packs)(https://www.dell.com/support/kbdoc/en-us/000180534/dell-family-driver-packs)
     - HP : [https://ftp.hp.com/pub/caps-softpaq/cmit/HP_WinPE_DriverPack.html](https://ftp.hp.com/pub/caps-softpaq/cmit/HP_WinPE_DriverPack.html)

