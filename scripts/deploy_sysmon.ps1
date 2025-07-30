<#
.SYNOPSIS
    Standalone Sysmon Installation Script
.DESCRIPTION
    Downloads, installs, and configures Sysmon with enhanced error handling and debugging
.NOTES
    Author: Adversary Lab
    Version: 1.0
    Requires: Administrator privileges
.EXAMPLE
    .\deploy_sysmon.ps1
    .\deploy_sysmon.ps1 -ShowDetails -UseDefaultConfig
    .\deploy_sysmon.ps1 -ConfigUrl "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml"
#>

[CmdletBinding()]
param(
    [string]$ConfigUrl = 'https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml',
    [switch]$UseDefaultConfig,
    [switch]$Force,
    [switch]$ShowDetails
)

# Configuration
$SysmonPath = 'C:\Windows\System32\Sysmon64.exe'
$SysmonConfigPath = 'C:\Windows\sysmonconfig.xml'
$SysmonDownloadUrl = 'https://download.sysinternals.com/files/Sysmon.zip'

function Write-DebugMessage {
    param([string]$Message)
    if ($ShowDetails) {
        Write-Host "[DETAILS] $Message" -ForegroundColor Magenta
    }
}

function Write-StatusMessage {
    param(
        [string]$Message,
        [ConsoleColor]$Color = 'White'
    )
    Write-Host $Message -ForegroundColor $Color
}

function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-InternetConnectivity {
    param([string]$TestUrl = "8.8.8.8")
    
    try {
        Write-DebugMessage "Testing connectivity to $TestUrl"
        $result = Test-NetConnection -ComputerName $TestUrl -Port 53 -InformationLevel Quiet -WarningAction SilentlyContinue
        Write-DebugMessage "Connectivity test result: $result"
        return $result
    } catch {
        Write-DebugMessage "Connectivity test failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-SysmonStatus {
    try {
        Write-DebugMessage "Checking for existing Sysmon installation"
        
        # Check for Sysmon service
        $sysmonService = Get-Service -Name 'Sysmon*' -ErrorAction SilentlyContinue
        
        if ($sysmonService) {
            Write-DebugMessage "Found Sysmon service: $($sysmonService.Name), Status: $($sysmonService.Status)"
            
            # Check if event log is accessible
            $logAccessible = $false
            try {
                $eventCount = (Get-WinEvent -LogName 'Microsoft-Windows-Sysmon/Operational' -MaxEvents 1 -ErrorAction SilentlyContinue | Measure-Object).Count
                $logAccessible = $true
                Write-DebugMessage "Sysmon event log is accessible with $eventCount recent events"
            } catch {
                Write-DebugMessage "Sysmon event log not accessible: $($_.Exception.Message)"
            }
            
            return @{
                Installed = $true
                ServiceName = $sysmonService.Name
                ServiceStatus = $sysmonService.Status
                Running = $sysmonService.Status -eq 'Running'
                LogAccessible = $logAccessible
                ExecutablePath = $SysmonPath
                ExecutableExists = (Test-Path $SysmonPath)
                ErrorMessage = $null
            }
        } else {
            Write-DebugMessage "No Sysmon service found"
            return @{
                Installed = $false
                ServiceName = 'Not Found'
                ServiceStatus = 'Not Installed'
                Running = $false
                LogAccessible = $false
                ExecutablePath = $SysmonPath
                ExecutableExists = (Test-Path $SysmonPath)
                ErrorMessage = $null
            }
        }
    } catch {
        Write-DebugMessage "Error checking Sysmon status: $($_.Exception.Message)"
        return @{
            Installed = $false
            ServiceName = 'Error'
            ServiceStatus = 'Unknown'
            Running = $false
            LogAccessible = $false
            ExecutablePath = $SysmonPath
            ExecutableExists = $false
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Download-Sysmon {
    Write-StatusMessage "[DOWNLOAD] Downloading Sysmon..." 'Yellow'
    Write-DebugMessage "Starting Sysmon download process"
    
    $tempZip = "$env:TEMP\Sysmon_$(Get-Date -Format 'yyyyMMdd_HHmmss').zip"
    $tempExtract = "$env:TEMP\Sysmon_Extract_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    
    try {
        # Test connectivity to download site
        Write-DebugMessage "Testing connectivity to download.sysinternals.com"
        $connectTest = Test-NetConnection -ComputerName 'download.sysinternals.com' -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
        if (-not $connectTest) {
            throw "Cannot reach download.sysinternals.com:443"
        }
        
        Write-DebugMessage "Downloading from: $SysmonDownloadUrl"
        Write-DebugMessage "Saving to: $tempZip"
        
        # Download with progress
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", "PowerShell Sysmon Installer")
        
        # Add progress if possible
        Register-ObjectEvent -InputObject $webClient -EventName DownloadProgressChanged -Action {
            $Global:DownloadProgress = $Event.SourceEventArgs.ProgressPercentage
            if ($Global:DownloadProgress -ne $Global:LastProgress) {
                Write-Progress -Activity "Downloading Sysmon" -Status "$($Global:DownloadProgress)% Complete" -PercentComplete $Global:DownloadProgress
                $Global:LastProgress = $Global:DownloadProgress
            }
        } | Out-Null
        
        $webClient.DownloadFile($SysmonDownloadUrl, $tempZip)
        $webClient.Dispose()
        
        # Remove progress event
        Get-EventSubscriber | Where-Object { $_.SourceObject -is [System.Net.WebClient] } | Unregister-Event
        Write-Progress -Activity "Downloading Sysmon" -Completed
        
        # Verify download
        if (-not (Test-Path $tempZip)) {
            throw "Download failed - file not found at $tempZip"
        }
        
        $fileSize = (Get-Item $tempZip).Length
        Write-DebugMessage "Download completed. File size: $fileSize bytes"
        
        if ($fileSize -lt 1000) {
            $fileSizeStr = $fileSize.ToString()
            throw "Downloaded file is too small ($fileSizeStr bytes) - likely corrupted"
        }
        
        # Extract
        Write-StatusMessage "[EXTRACT] Extracting Sysmon..." 'Yellow'
        Write-DebugMessage "Extracting to: $tempExtract"
        
        if (Test-Path $tempExtract) {
            Remove-Item -Path $tempExtract -Recurse -Force
        }
        
        Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force
        
        # Find Sysmon64.exe
        $sysmonExe = Get-ChildItem -Path $tempExtract -Name "Sysmon64.exe" -Recurse | Select-Object -First 1
        if (-not $sysmonExe) {
            $allFiles = Get-ChildItem -Path $tempExtract -Recurse | Select-Object -ExpandProperty Name
            throw "Sysmon64.exe not found in archive. Contents: $($allFiles -join ', ')"
        }
        
        $sysmonExePath = Join-Path $tempExtract $sysmonExe
        Write-DebugMessage "Found Sysmon executable at: $sysmonExePath"
        
        # Copy to system directory
        Write-StatusMessage "[INSTALL] Installing to system directory..." 'Yellow'
        Write-DebugMessage "Copying from $sysmonExePath to $SysmonPath"
        
        Copy-Item -Path $sysmonExePath -Destination $SysmonPath -Force
        
        # Verify copy
        if (-not (Test-Path $SysmonPath)) {
            throw "Failed to copy Sysmon to $SysmonPath"
        }
        
        $copiedSize = (Get-Item $SysmonPath).Length
        Write-DebugMessage "Sysmon copied successfully. Size: $copiedSize bytes"
        
        Write-StatusMessage "[SUCCESS] Sysmon downloaded and extracted successfully" 'Green'
        return $true
        
    } catch {
        Write-StatusMessage "[ERROR] Failed to download Sysmon: $($_.Exception.Message)" 'Red'
        Write-DebugMessage "Download error details: $($_.Exception | Format-List * | Out-String)"
        return $false
    } finally {
        # Cleanup
        if (Test-Path $tempZip) {
            Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
            Write-DebugMessage "Cleaned up temporary zip file"
        }
        if (Test-Path $tempExtract) {
            Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
            Write-DebugMessage "Cleaned up temporary extract directory"
        }
    }
}

function Download-SysmonConfig {
    if ($UseDefaultConfig) {
        Write-StatusMessage "[CONFIG] Using default Sysmon configuration" 'Yellow'
        return $null
    }
    
    Write-StatusMessage "[DOWNLOAD] Downloading Sysmon configuration..." 'Yellow'
    Write-DebugMessage "Downloading config from: $ConfigUrl"
    
    try {
        # Test connectivity to config source
        $configHost = ([System.Uri]$ConfigUrl).Host
        Write-DebugMessage "Testing connectivity to $configHost"
        
        $connectTest = Test-NetConnection -ComputerName $configHost -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
        if (-not $connectTest) {
            Write-Warning "Cannot reach $configHost - falling back to default configuration"
            return $null
        }
        
        # Download config
        Invoke-WebRequest -Uri $ConfigUrl -OutFile $SysmonConfigPath -UseBasicParsing -TimeoutSec 30 -UserAgent "PowerShell Sysmon Installer"
        
        # Verify download
        if (Test-Path $SysmonConfigPath) {
            $configSize = (Get-Item $SysmonConfigPath).Length
            Write-DebugMessage "Config downloaded successfully. Size: $configSize bytes"
            
            # Basic validation - check if it's XML
            try {
                $xml = [xml](Get-Content $SysmonConfigPath)
                if ($xml.Sysmon) {
                    Write-StatusMessage "[SUCCESS] Sysmon configuration downloaded and validated" 'Green'
                    return $SysmonConfigPath
                } else {
                    Write-Warning "Downloaded config doesn't appear to be valid Sysmon configuration"
                    Remove-Item $SysmonConfigPath -Force -ErrorAction SilentlyContinue
                    return $null
                }
            } catch {
                Write-Warning "Downloaded config is not valid XML: $($_.Exception.Message)"
                Remove-Item $SysmonConfigPath -Force -ErrorAction SilentlyContinue
                return $null
            }
        } else {
            throw "Config file not created after download"
        }
        
    } catch {
        Write-Warning "Failed to download configuration: $($_.Exception.Message)"
        Write-DebugMessage "Config download error: $($_.Exception | Format-List * | Out-String)"
        
        # Clean up any partial file
        if (Test-Path $SysmonConfigPath) {
            Remove-Item $SysmonConfigPath -Force -ErrorAction SilentlyContinue
        }
        
        return $null
    }
}

function Install-SysmonService {
    param([string]$ConfigPath = $null)
    
    Write-StatusMessage "[INSTALL] Installing Sysmon service..." 'Yellow'
    Write-DebugMessage "Installing Sysmon service with config: $ConfigPath"
    
    try {
        # Check if we need to uninstall first (for -Force scenarios)
        $existingService = Get-Service -Name 'Sysmon*' -ErrorAction SilentlyContinue
        if ($existingService) {
            Write-StatusMessage "[WARNING] Existing Sysmon service found. Uninstalling first..." 'Yellow'
            Write-DebugMessage "Uninstalling existing Sysmon service: $($existingService.Name)"
            
            # Uninstall existing Sysmon
            $uninstallProcess = Start-Process -FilePath $SysmonPath -ArgumentList @('-u', 'force') -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\sysmon_uninstall_out.txt" -RedirectStandardError "$env:TEMP\sysmon_uninstall_err.txt"
            
            Write-DebugMessage "Uninstall process completed with exit code: $($uninstallProcess.ExitCode)"
            
            # Read uninstall output
            if (Test-Path "$env:TEMP\sysmon_uninstall_out.txt") {
                $uninstallStdout = Get-Content "$env:TEMP\sysmon_uninstall_out.txt" -Raw
                if ($uninstallStdout) { Write-DebugMessage "Uninstall stdout: $uninstallStdout" }
            }
            
            if (Test-Path "$env:TEMP\sysmon_uninstall_err.txt") {
                $uninstallStderr = Get-Content "$env:TEMP\sysmon_uninstall_err.txt" -Raw
                if ($uninstallStderr) { Write-DebugMessage "Uninstall stderr: $uninstallStderr" }
            }
            
            # Wait for uninstall to complete
            Write-StatusMessage "[WAIT] Waiting for uninstall to complete..." 'Yellow'
            Start-Sleep -Seconds 3
            
            # Verify uninstall
            $checkService = Get-Service -Name 'Sysmon*' -ErrorAction SilentlyContinue
            if ($checkService) {
                Write-Warning "Sysmon service still exists after uninstall attempt. Proceeding anyway."
            } else {
                Write-StatusMessage "[SUCCESS] Existing Sysmon uninstalled successfully" 'Green'
            }
        }
        
        # Prepare installation arguments
        $installArgs = @('-accepteula', '-i')
        
        if ($ConfigPath -and (Test-Path $ConfigPath)) {
            $installArgs += $ConfigPath
            Write-DebugMessage "Installing with custom configuration: $ConfigPath"
        } else {
            Write-DebugMessage "Installing with default configuration"
        }
        
        Write-DebugMessage "Installation command: $SysmonPath $($installArgs -join ' ')"
        
        # Run installation
        $process = Start-Process -FilePath $SysmonPath -ArgumentList $installArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\sysmon_install_out.txt" -RedirectStandardError "$env:TEMP\sysmon_install_err.txt"
        
        Write-DebugMessage "Installation process completed with exit code: $($process.ExitCode)"
        
        # Read output
        if (Test-Path "$env:TEMP\sysmon_install_out.txt") {
            $stdout = Get-Content "$env:TEMP\sysmon_install_out.txt" -Raw
            if ($stdout) { Write-DebugMessage "Installation stdout: $stdout" }
        }
        
        if (Test-Path "$env:TEMP\sysmon_install_err.txt") {
            $stderr = Get-Content "$env:TEMP\sysmon_install_err.txt" -Raw
            if ($stderr) { Write-DebugMessage "Installation stderr: $stderr" }
        }
        
        # Check for specific error messages
        if ($process.ExitCode -eq 1242) {
            Write-Warning "Sysmon reported it's already installed (exit code 1242). This might be expected during force reinstall."
            # Don't throw an error for 1242 if we're doing a force reinstall
            Write-StatusMessage "[CONTINUE] Attempting to proceed with existing installation..." 'Yellow'
        } elseif ($process.ExitCode -ne 0) {
            throw "Sysmon installation failed with exit code: $($process.ExitCode)"
        }
        
        Write-StatusMessage "[SUCCESS] Sysmon service installation completed" 'Green'
        return $true
        
    } catch {
        Write-StatusMessage "[ERROR] Failed to install Sysmon service: $($_.Exception.Message)" 'Red'
        Write-DebugMessage "Service installation error: $($_.Exception | Format-List * | Out-String)"
        return $false
    } finally {
        # Cleanup temp files
        @("$env:TEMP\sysmon_install_out.txt", "$env:TEMP\sysmon_install_err.txt", "$env:TEMP\sysmon_uninstall_out.txt", "$env:TEMP\sysmon_uninstall_err.txt") | ForEach-Object {
            if (Test-Path $_) {
                Remove-Item $_ -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Test-SysmonInstallation {
    Write-StatusMessage "[VERIFY] Verifying Sysmon installation..." 'Yellow'
    
    $maxRetries = 5
    $retryDelay = 2
    
    for ($i = 1; $i -le $maxRetries; $i++) {
        Write-DebugMessage "Verification attempt $i of $maxRetries"
        
        $status = Get-SysmonStatus
        
        if ($status.Running) {
            Write-StatusMessage "[SUCCESS] Sysmon is running successfully!" 'Green'
            Write-StatusMessage "   Service: $($status.ServiceName)" 'Gray'
            Write-StatusMessage "   Status: $($status.ServiceStatus)" 'Gray'
            Write-StatusMessage "   Log Accessible: $($status.LogAccessible)" 'Gray'
            
            # Try to generate a test event
            Write-DebugMessage "Testing event generation"
            try {
                # This should generate a process creation event
                $null = Start-Process -FilePath "whoami" -Wait -WindowStyle Hidden
                Start-Sleep -Seconds 1
                
                $recentEvents = Get-WinEvent -LogName 'Microsoft-Windows-Sysmon/Operational' -MaxEvents 5 -ErrorAction SilentlyContinue
                if ($recentEvents) {
                    Write-StatusMessage "   Recent Events: $($recentEvents.Count) found" 'Gray'
                    Write-DebugMessage "Sample events: $($recentEvents | ForEach-Object { "ID:$($_.Id) Time:$($_.TimeCreated)" } | Select-Object -First 3)"
                } else {
                    Write-StatusMessage "   Recent Events: None found (may take time)" 'Gray'
                }
            } catch {
                Write-DebugMessage "Could not test event generation: $($_.Exception.Message)"
            }
            
            return $true
        } elseif ($status.Installed) {
            Write-StatusMessage "[WARNING] Sysmon service exists but is not running. Attempting to start..." 'Yellow'
            
            try {
                Start-Service -Name $status.ServiceName -ErrorAction Stop
                Write-DebugMessage "Successfully started Sysmon service"
                Start-Sleep -Seconds $retryDelay
            } catch {
                Write-DebugMessage "Failed to start service: $($_.Exception.Message)"
                if ($i -eq $maxRetries) {
                    Write-StatusMessage "[ERROR] Could not start Sysmon service: $($_.Exception.Message)" 'Red'
                    return $false
                }
            }
        } else {
            Write-DebugMessage "Sysmon not installed or not found"
            if ($i -eq $maxRetries) {
                Write-StatusMessage "[ERROR] Sysmon installation verification failed" 'Red'
                return $false
            }
        }
        
        if ($i -lt $maxRetries) {
            Write-StatusMessage "   Retrying in $retryDelay seconds..." 'Yellow'
            Start-Sleep -Seconds $retryDelay
        }
    }
    
    return $false
}

function Show-SysmonInfo {
    Write-Host "`n" -NoNewline
    Write-Host "=== Sysmon Information ===" -ForegroundColor Cyan
    Write-Host "=========================" -ForegroundColor Cyan
    
    try {
        $status = Get-SysmonStatus
        
        Write-Host "Installation Status: " -NoNewline
        if ($status.Running) {
            Write-Host "[RUNNING]" -ForegroundColor Green
        } elseif ($status.Installed) {
            Write-Host "[INSTALLED BUT NOT RUNNING]" -ForegroundColor Yellow
        } else {
            Write-Host "[NOT INSTALLED]" -ForegroundColor Red
        }
        
        Write-Host "Service Name: $($status.ServiceName)" -ForegroundColor Gray
        Write-Host "Service Status: $($status.ServiceStatus)" -ForegroundColor Gray
        Write-Host "Executable Path: $($status.ExecutablePath)" -ForegroundColor Gray
        Write-Host "Executable Exists: $($status.ExecutableExists)" -ForegroundColor Gray
        Write-Host "Event Log Accessible: $($status.LogAccessible)" -ForegroundColor Gray
        
        if ($status.ErrorMessage) {
            Write-Host "Error: $($status.ErrorMessage)" -ForegroundColor Red
        }
        
        # Show recent events if available
        if ($status.Running -and $status.LogAccessible) {
            Write-Host "`nRecent Events:" -ForegroundColor Cyan
            try {
                $events = Get-WinEvent -LogName 'Microsoft-Windows-Sysmon/Operational' -MaxEvents 3 -ErrorAction SilentlyContinue
                if ($events) {
                    $events | ForEach-Object {
                        try {
                            $eventType = switch ($_.Id) {
                                1 { 'Process Creation' }
                                3 { 'Network Connection' }
                                5 { 'Process Terminated' }
                                7 { 'Image Loaded' }
                                10 { 'Process Access' }
                                11 { 'File Created' }
                                12 { 'Registry Event' }
                                13 { 'Registry Event' }
                                default { "Event ID $($_.Id)" }
                            }
                            $timeStr = $_.TimeCreated.ToString('HH:mm:ss')
                            Write-Host "  $timeStr - $eventType" -ForegroundColor Green
                        } catch {
                            Write-Host "  Event parsing error: $($_.Exception.Message)" -ForegroundColor Yellow
                        }
                    }
                } else {
                    Write-Host "  No recent events found" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "  Could not read events: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        
        # Basic usage commands
        Write-Host "`nUseful Commands:" -ForegroundColor Cyan
        Write-Host "  Get-Service -Name 'Sysmon*'" -ForegroundColor Gray
        Write-Host "  Get-WinEvent -LogName 'Microsoft-Windows-Sysmon/Operational' -MaxEvents 10" -ForegroundColor Gray
        Write-Host "  Clear-EventLog -LogName 'Microsoft-Windows-Sysmon/Operational'" -ForegroundColor Gray
        
    } catch {
        Write-Host "Error displaying Sysmon information: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Main execution
try {
    Write-Host "=== Sysmon Standalone Installer ===" -ForegroundColor Cyan
    Write-Host "===================================" -ForegroundColor Cyan
    
    if ($ShowDetails) {
        Write-Host "[DEBUG] Detailed logging enabled" -ForegroundColor Magenta
    }
    
    # Check prerequisites
    Write-StatusMessage "`n[CHECK] Checking prerequisites..." 'Yellow'
    
    if (-not (Test-Administrator)) {
        throw "This script requires Administrator privileges. Please run as Administrator."
    }
    Write-StatusMessage "[SUCCESS] Administrator privileges confirmed" 'Green'
    
    if (-not (Test-InternetConnectivity)) {
        throw "Internet connectivity is required to download Sysmon."
    }
    Write-StatusMessage "[SUCCESS] Internet connectivity confirmed" 'Green'
    
    # Check current status
    Write-StatusMessage "`n[STATUS] Checking current Sysmon status..." 'Yellow'
    $currentStatus = Get-SysmonStatus
    
    Write-DebugMessage "Current status: Installed=$($currentStatus.Installed), Running=$($currentStatus.Running)"
    
    if ($currentStatus.Running -and -not $Force) {
        Write-StatusMessage "[SUCCESS] Sysmon is already installed and running!" 'Green'
        try {
            Show-SysmonInfo
        } catch {
            Write-StatusMessage "Note: There was an issue displaying detailed info, but Sysmon is working." 'Yellow'
        }
        Write-StatusMessage "`nUse -Force to reinstall" 'Yellow'
        Write-StatusMessage "Installation complete - Sysmon is ready to use!" 'Green'
        exit 0
    } elseif ($currentStatus.Running -and $Force) {
        Write-StatusMessage "[FORCE] Force reinstall requested. Sysmon is currently running." 'Yellow'
        Write-StatusMessage "This will uninstall and reinstall Sysmon with the latest version and configuration." 'Yellow'
    }
    
    if ($currentStatus.Installed -and -not $Force) {
        Write-StatusMessage "[WARNING] Sysmon is installed but not running. Attempting to start..." 'Yellow'
        try {
            Start-Service -Name $currentStatus.ServiceName
            Start-Sleep -Seconds 3
            $newStatus = Get-SysmonStatus
            if ($newStatus.Running) {
                Write-StatusMessage "[SUCCESS] Sysmon started successfully!" 'Green'
                try {
                    Show-SysmonInfo
                } catch {
                    Write-StatusMessage "Note: There was an issue displaying detailed info, but Sysmon is working." 'Yellow'
                }
                Write-StatusMessage "Installation complete - Sysmon is ready to use!" 'Green'
                exit 0
            }
        } catch {
            Write-StatusMessage "[ERROR] Could not start Sysmon: $($_.Exception.Message)" 'Red'
            Write-StatusMessage "Proceeding with reinstallation..." 'Yellow'
        }
    }
    
    # Download Sysmon if needed
    if (-not (Test-Path $SysmonPath) -or $Force) {
        Write-DebugMessage "Need to download Sysmon. Path exists: $(Test-Path $SysmonPath), Force: $Force"
        $downloadSuccess = Download-Sysmon
        if (-not $downloadSuccess) {
            throw "Failed to download Sysmon. Check internet connectivity and firewall settings."
        }
    } else {
        Write-StatusMessage "[SUCCESS] Sysmon executable already exists" 'Green'
    }
    
    # Download configuration
    Write-DebugMessage "Downloading Sysmon configuration"
    $configPath = Download-SysmonConfig
    if ($configPath) {
        Write-DebugMessage "Using config file: $configPath"
    } else {
        Write-DebugMessage "Using default configuration"
    }
    
    # Install Sysmon service
    Write-DebugMessage "Installing Sysmon service"
    $installSuccess = Install-SysmonService -ConfigPath $configPath
    if (-not $installSuccess) {
        throw "Failed to install Sysmon service. The installation process returned an error."
    }
    
    # Wait a moment for service to initialize
    Write-StatusMessage "[WAIT] Waiting for service initialization..." 'Yellow'
    Start-Sleep -Seconds 5
    
    # Verify installation
    Write-DebugMessage "Verifying installation"
    $verifySuccess = Test-SysmonInstallation
    if (-not $verifySuccess) {
        # Get more details about what failed
        $finalStatus = Get-SysmonStatus
        $errorDetails = "Verification failed. "
        $errorDetails += "Service installed: $($finalStatus.Installed), "
        $errorDetails += "Service running: $($finalStatus.Running), "
        $errorDetails += "Executable exists: $($finalStatus.ExecutableExists)"
        if ($finalStatus.ErrorMessage) {
            $errorDetails += ", Error: $($finalStatus.ErrorMessage)"
        }
        throw $errorDetails
    }
    
    # Show final status
    Write-Host "`n=== Sysmon Installation Complete! ===" -ForegroundColor Green
    Show-SysmonInfo
    
} catch {
    Write-Host "`n[ERROR] Installation Failed!" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    
    # Show current system state for troubleshooting
    Write-Host "`nCurrent System State:" -ForegroundColor Yellow
    try {
        $debugStatus = Get-SysmonStatus
        Write-Host "* Sysmon executable exists: $($debugStatus.ExecutableExists)" -ForegroundColor Gray
        Write-Host "* Sysmon service installed: $($debugStatus.Installed)" -ForegroundColor Gray
        Write-Host "* Service name: $($debugStatus.ServiceName)" -ForegroundColor Gray
        Write-Host "* Service status: $($debugStatus.ServiceStatus)" -ForegroundColor Gray
        
        if ($debugStatus.ErrorMessage) {
            Write-Host "* Status check error: $($debugStatus.ErrorMessage)" -ForegroundColor Red
        }
    } catch {
        Write-Host "* Could not get system state: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    if ($ShowDetails) {
        Write-Host "`nDetailed Error Information:" -ForegroundColor Yellow
        Write-Host "Error Type: $($_.Exception.GetType().FullName)" -ForegroundColor Gray
        Write-Host "Error Message: $($_.Exception.Message)" -ForegroundColor Gray
        if ($_.ScriptStackTrace) {
            Write-Host "Stack Trace:" -ForegroundColor Gray
            Write-Host $_.ScriptStackTrace -ForegroundColor Gray
        }
    }
    
    Write-Host "`nTroubleshooting Tips:" -ForegroundColor Yellow
    Write-Host "* Ensure you're running as Administrator" -ForegroundColor Gray
    Write-Host "* Check internet connectivity" -ForegroundColor Gray
    Write-Host "* Temporarily disable antivirus/Windows Defender" -ForegroundColor Gray
    Write-Host "* Run with -ShowDetails for detailed information" -ForegroundColor Gray
    Write-Host "* Try -UseDefaultConfig if config download fails" -ForegroundColor Gray
    Write-Host "* Check Windows Event Viewer for system errors" -ForegroundColor Gray
    
    exit 1
}