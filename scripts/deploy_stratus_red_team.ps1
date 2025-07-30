<#
.SYNOPSIS
    Standalone Stratus Red Team Installation Script
.DESCRIPTION
    Downloads, installs, and configures Stratus Red Team with enhanced error handling and debugging
.NOTES
    Author: Adversary Lab
    Version: 1.0
    Requires: Administrator privileges (recommended)
.EXAMPLE
    .\deploy_stratus_red_team.ps1
    .\deploy_stratus_red_team.ps1 -ShowDetails -Force
    .\deploy_stratus_red_team.ps1 -InstallPath "C:\Tools\stratus"
#>

[CmdletBinding()]
param(
    [string]$InstallPath = 'C:\Tools\stratus-red-team',
    [switch]$Force,
    [switch]$ShowDetails,
    [switch]$AddToPath
)

# Configuration
$GitHubApiUrl = 'https://api.github.com/repos/DataDog/stratus-red-team/releases/latest'
$StratusExecutable = 'stratus.exe'

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

function Test-GitHubConnectivity {
    try {
        Write-DebugMessage "Testing connectivity to GitHub API"
        $result = Test-NetConnection -ComputerName 'api.github.com' -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
        Write-DebugMessage "GitHub API connectivity: $result"
        return $result
    } catch {
        Write-DebugMessage "GitHub connectivity test failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-StratusStatus {
    try {
        Write-DebugMessage "Checking Stratus Red Team installation status"
        
        $stratusExePath = Join-Path $InstallPath $StratusExecutable
        $inSystemPath = $false
        $version = "Unknown"
        
        # Check if executable exists
        $executableExists = Test-Path $stratusExePath
        Write-DebugMessage "Stratus executable exists at ${stratusExePath}: $executableExists"
        
        # Check if it's in PATH
        if ($executableExists) {
            $pathDirs = $env:PATH -split ';'
            $inSystemPath = $pathDirs -contains $InstallPath
            Write-DebugMessage "Stratus directory in PATH: $inSystemPath"
            
            # Try to get version
            try {
                $versionOutput = & $stratusExePath version 2>$null
                if ($versionOutput) {
                    $version = $versionOutput.Trim()
                    Write-DebugMessage "Stratus version: $version"
                }
            } catch {
                Write-DebugMessage "Could not get version: $($_.Exception.Message)"
            }
        }
        
        return @{
            Installed = $executableExists
            InstallPath = $InstallPath
            ExecutablePath = $stratusExePath
            Version = $version
            InPath = $inSystemPath
            ErrorMessage = $null
        }
        
    } catch {
        Write-DebugMessage "Error checking Stratus status: $($_.Exception.Message)"
        return @{
            Installed = $false
            InstallPath = $InstallPath
            ExecutablePath = Join-Path $InstallPath $StratusExecutable
            Version = "Error"
            InPath = $false
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Get-LatestStratusRelease {
    Write-StatusMessage "[CHECK] Checking for latest Stratus Red Team release..." 'Yellow'
    Write-DebugMessage "Fetching release info from GitHub API"
    
    try {
        # Test GitHub connectivity first
        if (-not (Test-GitHubConnectivity)) {
            throw "Cannot reach GitHub API at api.github.com:443"
        }
        
        Write-DebugMessage "Fetching release data from: $GitHubApiUrl"
        
        # Get release information
        $release = Invoke-RestMethod -Uri $GitHubApiUrl -UseBasicParsing -TimeoutSec 30 -UserAgent "PowerShell Stratus Installer"
        
        Write-DebugMessage "Latest release found: $($release.tag_name)"
        Write-DebugMessage "Release name: $($release.name)"
        Write-DebugMessage "Published: $($release.published_at)"
        
        # Detect system architecture
        $architecture = if ([Environment]::Is64BitOperatingSystem) {
            if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
                "arm64"
            } else {
                "x86_64"
            }
        } else {
            "i386"
        }
        Write-DebugMessage "Detected architecture: $architecture"
        
        # Find Windows binary for our architecture
        $preferredPattern = "*Windows*$architecture*.tar.gz"
        $windowsAsset = $release.assets | Where-Object { $_.name -like $preferredPattern } | Select-Object -First 1
        
        if (-not $windowsAsset) {
            # Fallback to any Windows x86_64 if preferred not found
            Write-DebugMessage "Preferred pattern '$preferredPattern' not found, trying x86_64 fallback"
            $windowsAsset = $release.assets | Where-Object { $_.name -like "*Windows*x86_64*.tar.gz" } | Select-Object -First 1
        }
        
        if (-not $windowsAsset) {
            # Try any Windows tar.gz file
            Write-DebugMessage "x86_64 fallback not found, trying any Windows tar.gz"
            $windowsAsset = $release.assets | Where-Object { $_.name -like "*Windows*.tar.gz" } | Select-Object -First 1
        }
        
        if (-not $windowsAsset) {
            # List all available assets for debugging
            $allAssets = $release.assets.name -join ', '
            throw "No Windows-compatible assets found. Available assets: $allAssets"
        }
        
        Write-DebugMessage "Selected asset: $($windowsAsset.name), Size: $($windowsAsset.size) bytes"
        
        return @{
            Version = $release.tag_name
            DownloadUrl = $windowsAsset.browser_download_url
            FileName = $windowsAsset.name
            Size = $windowsAsset.size
            PublishedAt = $release.published_at
            Architecture = $architecture
        }
        
    } catch {
        Write-StatusMessage "[ERROR] Failed to get release information: $($_.Exception.Message)" 'Red'
        Write-DebugMessage "Release fetch error: $($_.Exception | Format-List * | Out-String)"
        throw $_
    }
}

function Download-StratusRedTeam {
    param($ReleaseInfo)
    
    Write-StatusMessage "[DOWNLOAD] Downloading Stratus Red Team $($ReleaseInfo.Version)..." 'Yellow'
    Write-DebugMessage "Download URL: $($ReleaseInfo.DownloadUrl)"
    Write-DebugMessage "Architecture: $($ReleaseInfo.Architecture)"
    
    $tempArchive = "$env:TEMP\stratus-red-team_$(Get-Date -Format 'yyyyMMdd_HHmmss').tar.gz"
    $tempExtract = "$env:TEMP\stratus-extract_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    
    try {
        Write-DebugMessage "Downloading to: $tempArchive"
        Write-DebugMessage "Expected size: $($ReleaseInfo.Size) bytes"
        
        # Download with progress tracking
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", "PowerShell Stratus Red Team Installer")
        
        # Add progress if possible
        Register-ObjectEvent -InputObject $webClient -EventName DownloadProgressChanged -Action {
            $Global:DownloadProgress = $Event.SourceEventArgs.ProgressPercentage
            if ($Global:DownloadProgress -ne $Global:LastProgress) {
                Write-Progress -Activity "Downloading Stratus Red Team" -Status "$($Global:DownloadProgress)% Complete" -PercentComplete $Global:DownloadProgress
                $Global:LastProgress = $Global:DownloadProgress
            }
        } | Out-Null
        
        $webClient.DownloadFile($ReleaseInfo.DownloadUrl, $tempArchive)
        $webClient.Dispose()
        
        # Remove progress event
        Get-EventSubscriber | Where-Object { $_.SourceObject -is [System.Net.WebClient] } | Unregister-Event
        Write-Progress -Activity "Downloading Stratus Red Team" -Completed
        
        # Verify download
        if (-not (Test-Path $tempArchive)) {
            throw "Download failed - file not found at $tempArchive"
        }
        
        $downloadedSize = (Get-Item $tempArchive).Length
        Write-DebugMessage "Download completed. File size: $downloadedSize bytes"
        
        if ($downloadedSize -lt 1000) {
            $downloadedSizeStr = $downloadedSize.ToString()
            throw "Downloaded file is too small ($downloadedSizeStr bytes) - likely corrupted"
        }
        
        # Extract tar.gz archive
        Write-StatusMessage "[EXTRACT] Extracting Stratus Red Team..." 'Yellow'
        Write-DebugMessage "Extracting to: $tempExtract"
        
        if (Test-Path $tempExtract) {
            Remove-Item -Path $tempExtract -Recurse -Force
        }
        New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null
        
        # Use tar command if available (Windows 10 1903+ has built-in tar)
        $tarAvailable = $false
        try {
            $tarVersion = tar --version 2>$null
            if ($tarVersion) {
                $tarAvailable = $true
                Write-DebugMessage "Using built-in tar command"
            }
        } catch {
            Write-DebugMessage "Built-in tar not available"
        }
        
        if ($tarAvailable) {
            # Use tar command
            $extractResult = Start-Process -FilePath "tar" -ArgumentList @("-xzf", $tempArchive, "-C", $tempExtract) -Wait -PassThru -NoNewWindow
            if ($extractResult.ExitCode -ne 0) {
                throw "tar extraction failed with exit code: $($extractResult.ExitCode)"
            }
        } else {
            # Fallback: Try PowerShell method (limited tar.gz support)
            Write-StatusMessage "[WARNING] Using PowerShell fallback extraction (may not work for all tar.gz files)" 'Yellow'
            
            # First try to decompress .gz to .tar
            try {
                Add-Type -AssemblyName System.IO.Compression
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                
                # This is a basic implementation - may not work for all tar.gz files
                $gzipStream = New-Object System.IO.FileStream($tempArchive, [System.IO.FileMode]::Open)
                $gzipDecompressor = New-Object System.IO.Compression.GZipStream($gzipStream, [System.IO.Compression.CompressionMode]::Decompress)
                $tarFile = "$env:TEMP\temp.tar"
                $outputStream = New-Object System.IO.FileStream($tarFile, [System.IO.FileMode]::Create)
                
                $gzipDecompressor.CopyTo($outputStream)
                
                $outputStream.Close()
                $gzipDecompressor.Close()
                $gzipStream.Close()
                
                Write-DebugMessage "Decompressed .gz to .tar file"
                
                # Now we need to extract the tar file - this is complex without external tools
                # For now, suggest manual extraction
                throw "PowerShell tar.gz extraction is limited. Please install Git for Windows or use WSL for better tar support."
                
            } catch {
                throw "Failed to extract tar.gz file: $($_.Exception.Message). Consider installing Git for Windows which includes tar support."
            }
        }
        
        # Find the stratus executable
        Write-DebugMessage "Searching for stratus.exe in extracted files"
        
        try {
            # Get all files recursively and find stratus.exe
            $allFiles = Get-ChildItem -Path $tempExtract -Recurse -File
            $stratusExeFile = $null
            
            foreach ($file in $allFiles) {
                if ($file.Name -eq $StratusExecutable) {
                    $stratusExeFile = $file
                    break
                }
            }
            
            if (-not $stratusExeFile) {
                # List all files to help debug
                $allFileNames = $allFiles | ForEach-Object { $_.Name }
                Write-DebugMessage "Files in archive: $($allFileNames -join ', ')"
                throw "stratus.exe not found in archive. Available files: $($allFileNames -join ', ')"
            }
            
            $stratusExeFullPath = $stratusExeFile.FullName
            
            Write-DebugMessage "Found Stratus executable at: $stratusExeFullPath"
            Write-DebugMessage "File size: $($stratusExeFile.Length) bytes"
            
        } catch {
            throw "Error finding stratus.exe: $($_.Exception.Message)"
        }
        
        # Create installation directory
        if (-not (Test-Path $InstallPath)) {
            Write-StatusMessage "[INSTALL] Creating installation directory..." 'Yellow'
            Write-DebugMessage "Creating directory: $InstallPath"
            New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
        }
        
        # Copy executable to installation directory
        $finalPath = Join-Path $InstallPath $StratusExecutable
        Write-StatusMessage "[INSTALL] Installing to $InstallPath..." 'Yellow'
        Write-DebugMessage "Copying from $stratusExeFullPath to $finalPath"
        
        Copy-Item -Path $stratusExeFullPath -Destination $finalPath -Force
        
        # Verify installation
        if (-not (Test-Path $finalPath)) {
            throw "Failed to copy Stratus to $finalPath"
        }
        
        $installedSize = (Get-Item $finalPath).Length
        Write-DebugMessage "Stratus installed successfully. Size: $installedSize bytes"
        
        Write-StatusMessage "[SUCCESS] Stratus Red Team downloaded and installed successfully" 'Green'
        return $finalPath
        
    } catch {
        Write-StatusMessage "[ERROR] Failed to download/install Stratus Red Team: $($_.Exception.Message)" 'Red'
        Write-DebugMessage "Download/install error: $($_.Exception | Format-List * | Out-String)"
        throw $_
    } finally {
        # Cleanup temporary files
        if (Test-Path $tempArchive) {
            Remove-Item $tempArchive -Force -ErrorAction SilentlyContinue
            Write-DebugMessage "Cleaned up temporary archive file"
        }
        if (Test-Path $tempExtract) {
            Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
            Write-DebugMessage "Cleaned up temporary extract directory"
        }
        if (Test-Path "$env:TEMP\temp.tar") {
            Remove-Item "$env:TEMP\temp.tar" -Force -ErrorAction SilentlyContinue
        }
    }
}

function Add-StratusToPath {
    param([switch]$Force)
    
    Write-StatusMessage "[CONFIG] Configuring PATH environment..." 'Yellow'
    Write-DebugMessage "Adding $InstallPath to PATH"
    
    try {
        # Add to current session PATH
        $currentPath = $env:PATH
        if ($currentPath -notmatch [regex]::Escape($InstallPath)) {
            $env:PATH = "$currentPath;$InstallPath"
            Write-DebugMessage "Added to current session PATH"
        }
        
        # Add to user PATH permanently
        try {
            $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
            if (-not $userPath) {
                $userPath = $InstallPath
            } elseif ($userPath -notmatch [regex]::Escape($InstallPath)) {
                $userPath = "$userPath;$InstallPath"
            } else {
                Write-DebugMessage "Already in user PATH"
                return $true
            }
            
            [Environment]::SetEnvironmentVariable('PATH', $userPath, 'User')
            Write-StatusMessage "[SUCCESS] Added Stratus to user PATH" 'Green'
            Write-DebugMessage "User PATH updated successfully"
            return $true
            
        } catch {
            Write-StatusMessage "[WARNING] Could not update user PATH: $($_.Exception.Message)" 'Yellow'
            Write-DebugMessage "User PATH update failed: $($_.Exception.Message)"
            
            # Try system PATH if we have admin rights
            if ((Test-Administrator)) {
                try {
                    $systemPath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
                    if ($systemPath -notmatch [regex]::Escape($InstallPath)) {
                        [Environment]::SetEnvironmentVariable('PATH', "$systemPath;$InstallPath", 'Machine')
                        Write-StatusMessage "[SUCCESS] Added Stratus to system PATH (admin)" 'Green'
                        Write-DebugMessage "System PATH updated successfully"
                        return $true
                    }
                } catch {
                    Write-StatusMessage "[WARNING] Could not update system PATH: $($_.Exception.Message)" 'Yellow'
                    Write-DebugMessage "System PATH update failed: $($_.Exception.Message)"
                }
            }
            
            return $false
        }
        
    } catch {
        Write-StatusMessage "[ERROR] Failed to configure PATH: $($_.Exception.Message)" 'Red'
        Write-DebugMessage "PATH configuration error: $($_.Exception | Format-List * | Out-String)"
        return $false
    }
}

function Test-StratusInstallation {
    param([string]$ExecutablePath)
    
    Write-StatusMessage "[VERIFY] Verifying Stratus Red Team installation..." 'Yellow'
    Write-DebugMessage "Testing installation at: $ExecutablePath"
    
    try {
        # Test if executable exists and is executable
        if (-not (Test-Path $ExecutablePath)) {
            throw "Stratus executable not found at $ExecutablePath"
        }
        
        # Test basic functionality
        Write-DebugMessage "Testing basic Stratus functionality"
        
        # Try to get version
        $versionOutput = & $ExecutablePath version 2>$null
        if (-not $versionOutput) {
            Write-DebugMessage "Could not get version, trying help command"
            $helpOutput = & $ExecutablePath --help 2>$null
            if (-not $helpOutput) {
                throw "Stratus executable does not respond to basic commands"
            }
        }
        
        Write-DebugMessage "Version output: $versionOutput"
        
        # Try to list techniques (this should work without any setup)
        Write-DebugMessage "Testing technique listing"
        $listOutput = & $ExecutablePath list 2>$null
        
        if ($listOutput -and $listOutput -notlike "*error*") {
            Write-StatusMessage "[SUCCESS] Stratus Red Team is working correctly!" 'Green'
            Write-StatusMessage "   Version: $($versionOutput)" 'Gray'
            
            # Count available techniques
            $techniqueCount = ($listOutput | Measure-Object -Line).Lines
            if ($techniqueCount -gt 0) {
                Write-StatusMessage "   Available techniques: $techniqueCount" 'Gray'
            }
            
            return $true
        } else {
            Write-StatusMessage "[WARNING] Stratus installed but may have issues listing techniques" 'Yellow'
            Write-StatusMessage "   This might be normal if cloud credentials aren't configured" 'Gray'
            return $true
        }
        
    } catch {
        Write-StatusMessage "[ERROR] Stratus installation verification failed: $($_.Exception.Message)" 'Red'
        Write-DebugMessage "Verification error: $($_.Exception | Format-List * | Out-String)"
        return $false
    }
}

function Show-StratusInfo {
    Write-Host "`n" -NoNewline
    Write-Host "=== Stratus Red Team Information ===" -ForegroundColor Cyan
    Write-Host "====================================" -ForegroundColor Cyan
    
    try {
        $status = Get-StratusStatus
        
        Write-Host "Installation Status: " -NoNewline
        if ($status.Installed) {
            Write-Host "[INSTALLED]" -ForegroundColor Green
        } else {
            Write-Host "[NOT INSTALLED]" -ForegroundColor Red
        }
        
        Write-Host "Installation Path: $($status.InstallPath)" -ForegroundColor Gray
        Write-Host "Executable Path: $($status.ExecutablePath)" -ForegroundColor Gray
        Write-Host "Version: $($status.Version)" -ForegroundColor Gray
        Write-Host "In PATH: $($status.InPath)" -ForegroundColor Gray
        
        if ($status.ErrorMessage) {
            Write-Host "Error: $($status.ErrorMessage)" -ForegroundColor Red
        }
        
        # Show available techniques if Stratus is working
        if ($status.Installed) {
            Write-Host "`nQuick Test:" -ForegroundColor Cyan
            try {
                $quickTest = & $status.ExecutablePath version 2>$null
                if ($quickTest) {
                    Write-Host "  [SUCCESS] Stratus responds correctly" -ForegroundColor Green
                    Write-Host "  Version: $quickTest" -ForegroundColor Gray
                } else {
                    Write-Host "  [WARNING] Stratus may have issues" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "  [ERROR] Stratus test failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        
        # Usage information
        Write-Host "`nUseful Commands:" -ForegroundColor Cyan
        Write-Host "  stratus list                    # List all available techniques" -ForegroundColor Gray
        Write-Host "  stratus show <technique-id>     # Show technique details" -ForegroundColor Gray
        Write-Host "  stratus warmup <technique-id>   # Prepare technique prerequisites" -ForegroundColor Gray
        Write-Host "  stratus detonate <technique-id> # Execute attack technique" -ForegroundColor Gray
        Write-Host "  stratus cleanup <technique-id>  # Clean up after technique" -ForegroundColor Gray
        Write-Host "  stratus status                  # Show status of techniques" -ForegroundColor Gray
        
        Write-Host "`nExample Techniques:" -ForegroundColor Cyan
        Write-Host "  aws.defense-evasion.cloudtrail-stop" -ForegroundColor Gray
        Write-Host "  aws.credential-access.ec2-get-password-data" -ForegroundColor Gray
        Write-Host "  azure.defense-evasion.vm-update-agent" -ForegroundColor Gray
        Write-Host "  gcp.defense-evasion.impersonate-service-account" -ForegroundColor Gray
        
        Write-Host "`nNote: Cloud credentials required for actual technique execution" -ForegroundColor Yellow
        
    } catch {
        Write-Host "Error displaying Stratus information: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Main execution
try {
    Write-Host "=== Stratus Red Team Standalone Installer ===" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    
    if ($ShowDetails) {
        Write-Host "[DEBUG] Detailed logging enabled" -ForegroundColor Magenta
    }
    
    # Check prerequisites
    Write-StatusMessage "`n[CHECK] Checking prerequisites..." 'Yellow'
    
    $isAdmin = Test-Administrator
    if ($isAdmin) {
        Write-StatusMessage "[SUCCESS] Administrator privileges detected" 'Green'
    } else {
        Write-StatusMessage "[WARNING] Not running as Administrator (PATH updates may be limited)" 'Yellow'
    }
    
    # Check current status
    Write-StatusMessage "`n[STATUS] Checking current Stratus Red Team status..." 'Yellow'
    $currentStatus = Get-StratusStatus
    
    Write-DebugMessage "Current status: Installed=$($currentStatus.Installed), InPath=$($currentStatus.InPath)"
    
    if ($currentStatus.Installed -and -not $Force) {
        Write-StatusMessage "[SUCCESS] Stratus Red Team is already installed!" 'Green'
        try {
            Show-StratusInfo
        } catch {
            Write-StatusMessage "Note: There was an issue displaying detailed info, but Stratus is installed." 'Yellow'
        }
        Write-StatusMessage "`nUse -Force to reinstall or -AddToPath to update PATH" 'Yellow'
        exit 0
    } elseif ($currentStatus.Installed -and $Force) {
        Write-StatusMessage "[FORCE] Force reinstall requested." 'Yellow'
        Write-StatusMessage "This will download and install the latest version." 'Yellow'
    }
    
    # Get latest release information
    Write-DebugMessage "Fetching latest release information"
    $releaseInfo = Get-LatestStratusRelease
    Write-StatusMessage "[INFO] Latest version: $($releaseInfo.Version)" 'Cyan'
    Write-StatusMessage "[INFO] Published: $($releaseInfo.PublishedAt)" 'Cyan'
    Write-StatusMessage "[INFO] File: $($releaseInfo.FileName)" 'Cyan'
    
    # Download and install
    Write-DebugMessage "Starting download and installation"
    $installedPath = Download-StratusRedTeam -ReleaseInfo $releaseInfo
    
    # Add to PATH if requested or if admin
    if ($AddToPath -or $isAdmin) {
        Write-DebugMessage "Adding to PATH"
        $pathSuccess = Add-StratusToPath
        if (-not $pathSuccess) {
            Write-StatusMessage "[WARNING] PATH update failed, but installation succeeded" 'Yellow'
            Write-StatusMessage "You can run Stratus using the full path: $installedPath" 'Gray'
        }
    } else {
        Write-StatusMessage "[INFO] Use -AddToPath to add Stratus to your PATH for easy access" 'Cyan'
    }
    
    # Verify installation
    Write-DebugMessage "Verifying installation"
    $verifySuccess = Test-StratusInstallation -ExecutablePath $installedPath
    if (-not $verifySuccess) {
        throw "Stratus Red Team installation verification failed"
    }
    
    # Show final status
    Write-Host "`n=== Stratus Red Team Installation Complete! ===" -ForegroundColor Green
    Show-StratusInfo
    
    Write-Host "`n[QUICK START]" -ForegroundColor Yellow
    Write-Host "  1. List available techniques: " -NoNewline -ForegroundColor Gray
    if ($currentStatus.InPath -or (Get-StratusStatus).InPath) {
        Write-Host "stratus list" -ForegroundColor White
    } else {
        Write-Host "`"$installedPath`" list" -ForegroundColor White
    }
    Write-Host "  2. Show technique details: " -NoNewline -ForegroundColor Gray
    if ($currentStatus.InPath -or (Get-StratusStatus).InPath) {
        Write-Host "stratus show <technique-id>" -ForegroundColor White
    } else {
        Write-Host "`"$installedPath`" show <technique-id>" -ForegroundColor White
    }
    
} catch {
    Write-Host "`n[ERROR] Installation Failed!" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    
    # Show current system state for troubleshooting
    Write-Host "`nCurrent System State:" -ForegroundColor Yellow
    try {
        $debugStatus = Get-StratusStatus
        Write-Host "* Installation directory exists: $(Test-Path $debugStatus.InstallPath)" -ForegroundColor Gray
        Write-Host "* Stratus executable exists: $($debugStatus.Installed)" -ForegroundColor Gray
        Write-Host "* Executable path: $($debugStatus.ExecutablePath)" -ForegroundColor Gray
        Write-Host "* In PATH: $($debugStatus.InPath)" -ForegroundColor Gray
        
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
    Write-Host "* Check internet connectivity to GitHub" -ForegroundColor Gray
    Write-Host "* Temporarily disable antivirus/Windows Defender" -ForegroundColor Gray
    Write-Host "* Run with -ShowDetails for detailed information" -ForegroundColor Gray
    Write-Host "* Try a different -InstallPath if current location has issues" -ForegroundColor Gray
    Write-Host "* Check GitHub releases page manually: https://github.com/DataDog/stratus-red-team/releases" -ForegroundColor Gray
    
    exit 1
}