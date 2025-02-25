# Win11Install

A script or tool to streamline the installation of Windows 11.

## Table of Contents

- [Introduction](#introduction)
- [Features](#features)
- [Usage](#usage)

## Introduction

Win11Install is designed to simplify the process of installing Windows 11 by automating tasks and ensuring optimal configuration.

## Features

- Automated installation process
- Pre-configured settings for optimal performance
- Support for various hardware configurations
- User-friendly interface

## Usage
- Registryrunonce.ps1 -> $repopath = "https://raw.githubusercontent.com/vijaidjearam/win11install/master/" change the value according to your Repo
- registry_run_once_install_win_with_recovery.ps1 -> $repopath = "https://raw.githubusercontent.com/vijaidjearam/win11install/master/" change the value according to your Repo
- Autounattend-WinEdu.xml -> change the value in the Run synchronous command according to you Repo

  ```xml
  				<RunSynchronousCommand wcm:action="add">
					<Order>1</Order>
					<Path>powershell -NoLogo -Command &quot;(new-object System.Net.WebClient).DownloadFile(&apos;https://raw.githubusercontent.com/vijaidjearam/win11install/master/registryrunonce.ps1&apos;, &apos;c:\windows\temp\header.ps1&apos;)&quot;</Path>
				</RunSynchronousCommand>  
  ```


