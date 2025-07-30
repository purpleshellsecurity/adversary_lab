<#
.SYNOPSIS
    Standalone Atomic Red Team Installation Script
.DESCRIPTION
    Downloads, installs, and configures Atomic Red Team with enhanced error handling and debugging
.NOTES
    Author: Adversary Lab
    Version: 1.0
    Requires: Administrator privileges (recommended)
.EXAMPLE
    .\deploy_atomic_red_team.ps1
    .\deploy_atomic_red_team.ps1 -ShowDetails -Force
    .\deploy_atomic_red_team.ps1 -InstallPath "C:\Tools\AtomicRedTeam"
#>

[CmdletBinding()]
param(
    [string]$InstallPath = 'C:\AtomicRedTeam',
    [switch]$Force,
    [switch]$ShowDetails,
    [switch]$SkipAtomics
)

# Configuration
$AtomicInstallerUrl = 'https://raw.githubusercontent.com/redcanaryco/invoke-atomicredteam/master/install-atomicredteam.ps1'
$ModulePath = Join-Path $InstallPath 'invoke-atomicredteam'
$AtomicsPath = Join-Path $InstallPath 'atomics'

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
        Write-DebugMessage "Testing connectivity to GitHub"
        $result = Test-NetConnection -ComputerName 'raw.githubusercontent.com' -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
        Write-DebugMessage "GitHub connectivity: $result"
        return $result
    } catch {
        Write-DebugMessage "GitHub connectivity test failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-AtomicStatus {
    try {
        Write-DebugMessage "Checking Atomic Red Team installation status"
        
        # Check if main directory exists
        $mainDirExists = Test-Path $InstallPath
        Write-DebugMessage "Main directory exists ($InstallPath): $mainDirExists"
        
        # Check if module directory exists
        $moduleDirExists = Test-Path $ModulePath
        Write-DebugMessage "Module directory exists ($ModulePath): $moduleDirExists"
        
        # Check if atomics directory exists
        $atomicsDirExists = Test-Path $AtomicsPath
        Write-DebugMessage "Atomics directory exists ($AtomicsPath): $atomicsDirExists"
        
        # Count techniques if atomics exist
        $techniqueCount = 0
        if ($atomicsDirExists) {
            try {
                $techniques = Get-ChildItem -Path $AtomicsPath -Directory -ErrorAction SilentlyContinue
                $techniqueCount = $techniques.Count
                Write-DebugMessage "Found $techniqueCount technique directories"
            } catch {
                Write-DebugMessage "Could not count techniques: $($_.Exception.Message)"
            }
        }
        
        # Check if module is importable
        $moduleImportable = $false
        $moduleVersion = "Unknown"
        if ($moduleDirExists) {
            try {
                $manifestPath = Join-Path $ModulePath "Invoke-AtomicRedTeam.psd1"
                if (Test-Path $manifestPath) {
                    $manifest = Import-PowerShellDataFile -Path $manifestPath -ErrorAction SilentlyContinue
                    if ($manifest -and $manifest.ModuleVersion) {
                        $moduleVersion = $manifest.ModuleVersion
                        $moduleImportable = $true
                        Write-DebugMessage "Module version: $moduleVersion"
                    }
                }
            } catch {
                Write-DebugMessage "Could not check module version: $($_.Exception.Message)"
            }
        }
        
        # Check if module is currently loaded
        $moduleLoaded = $false
        try {
            $loadedModule = Get-Module -Name 'invoke-atomicredteam' -ErrorAction SilentlyContinue
            $moduleLoaded = $null -ne $loadedModule
            Write-DebugMessage "Module currently loaded: $moduleLoaded"
        } catch {
            Write-DebugMessage "Could not check loaded modules: $($_.Exception.Message)"
        }
        
        return @{
            Installed = $mainDirExists -and $moduleDirExists
            InstallPath = $InstallPath
            ModulePath = $ModulePath
            AtomicsPath = $AtomicsPath
            ModuleExists = $moduleDirExists
            AtomicsExist = $atomicsDirExists
            TechniqueCount = $techniqueCount
            ModuleImportable = $moduleImportable
            ModuleLoaded = $moduleLoaded
            ModuleVersion = $moduleVersion
            ErrorMessage = $null
        }
        
    } catch {
        Write-DebugMessage "Error checking Atomic Red Team status: $($_.Exception.Message)"
        return @{
            Installed = $false
            InstallPath = $InstallPath
            ModulePath = $ModulePath
            AtomicsPath = $AtomicsPath
            ModuleExists = $false
            AtomicsExist = $false
            TechniqueCount = 0
            ModuleImportable = $false
            ModuleLoaded = $false
            ModuleVersion = "Error"
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Download-AtomicInstaller {
    Write-StatusMessage "[DOWNLOAD] Downloading Atomic Red Team installer..." 'Yellow'
    Write-DebugMessage "Download URL: $AtomicInstallerUrl"
    
    try {
        # Test GitHub connectivity first
        if (-not (Test-GitHubConnectivity)) {
            throw "Cannot reach GitHub at raw.githubusercontent.com:443"
        }
        
        Write-DebugMessage "Downloading installer script"
        
        # Download the installer script
        $installerScript = Invoke-WebRequest -Uri $AtomicInstallerUrl -UseBasicParsing -TimeoutSec 60 -UserAgent "PowerShell Atomic Red Team Installer"
        
        if (-not $installerScript.Content) {
            throw "Downloaded installer script is empty"
        }
        
        $scriptLength = $installerScript.Content.Length
        Write-DebugMessage "Downloaded installer script: $scriptLength characters"
        
        # Basic validation - check if it looks like a PowerShell script
        if (-not ($installerScript.Content -match 'function.*Install-AtomicRedTeam')) {
            throw "Downloaded content doesn't appear to be the Atomic Red Team installer"
        }
        
        Write-StatusMessage "[SUCCESS] Atomic Red Team installer downloaded successfully" 'Green'
        return $installerScript.Content
        
    } catch {
        Write-StatusMessage "[ERROR] Failed to download installer: $($_.Exception.Message)" 'Red'
        Write-DebugMessage "Download error: $($_.Exception | Format-List * | Out-String)"
        throw $_
    }
}

function Install-AtomicRedTeam {
    param([string]$InstallerScript)
    
    Write-StatusMessage "[INSTALL] Installing Atomic Red Team..." 'Yellow'
    Write-DebugMessage "Starting Atomic Red Team installation"
    
    try {
        # Create install directory if it doesn't exist
        if (-not (Test-Path $InstallPath)) {
            Write-StatusMessage "[INSTALL] Creating installation directory..." 'Yellow'
            Write-DebugMessage "Creating directory: $InstallPath"
            New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
        }
        
        # Ensure PowerShell automatic variables are available in current scope
        Write-DebugMessage "PowerShell Version: $($PSVersionTable.PSVersion)"
        Write-DebugMessage "Checking/setting automatic variables"
        
        # These should exist in PS 6+ but let's ensure they're available
        if (-not (Test-Path variable:IsLinux)) {
            Write-DebugMessage "Setting IsLinux variable"
            $script:IsLinux = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)
        }
        if (-not (Test-Path variable:IsMacOS)) {
            Write-DebugMessage "Setting IsMacOS variable"
            $script:IsMacOS = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)
        }
        if (-not (Test-Path variable:IsWindows)) {
            Write-DebugMessage "Setting IsWindows variable"
            $script:IsWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
        }
        
        Write-DebugMessage "Platform variables: IsWindows=$IsWindows, IsLinux=$IsLinux, IsMacOS=$IsMacOS"
        
        # Create a script block to execute the installer in proper scope
        $installScriptBlock = [ScriptBlock]::Create(@"
            # Set up environment
            `$ErrorActionPreference = 'Stop'
            
            # Execute the installer functions
            $InstallerScript
            
            # Now call the installation function
            Install-AtomicRedTeam -InstallPath '$InstallPath' -Force:`$Force $(if (-not $SkipAtomics) { '-getAtomics' })
"@)
        
        Write-DebugMessage "Executing installer in isolated script block"
        
        # Execute the script block
        & $installScriptBlock
        
        Write-StatusMessage "[SUCCESS] Atomic Red Team installation completed" 'Green'
        return $true
        
    } catch {
        Write-StatusMessage "[ERROR] Failed to install Atomic Red Team: $($_.Exception.Message)" 'Red'
        Write-DebugMessage "Installation error: $($_.Exception | Format-List * | Out-String)"
        
        # Try alternative installation method
        Write-StatusMessage "[RETRY] Trying alternative installation method..." 'Yellow'
        try {
            Write-DebugMessage "Attempting direct function execution"
            
            # Execute the installer script to define functions
            Invoke-Expression $InstallerScript
            
            # Create parameters hashtable
            $installParams = @{
                InstallPath = $InstallPath
                Force = $Force
            }
            
            if (-not $SkipAtomics) {
                $installParams.getAtomics = $true
            }
            
            Write-DebugMessage "Calling Install-AtomicRedTeam directly with parameters"
            
            # Call the function directly
            & (Get-Command Install-AtomicRedTeam) @installParams
            
            Write-StatusMessage "[SUCCESS] Alternative installation method succeeded" 'Green'
            return $true
            
        } catch {
            Write-StatusMessage "[ERROR] Alternative installation also failed: $($_.Exception.Message)" 'Red'
            Write-DebugMessage "Alternative installation error: $($_.Exception | Format-List * | Out-String)"
            return $false
        }
    }
}

function Configure-AtomicModule {
    Write-StatusMessage "[CONFIG] Configuring Atomic Red Team module..." 'Yellow'
    Write-DebugMessage "Configuring module for persistent access"
    
    try {
        # Check if module path exists
        if (-not (Test-Path $ModulePath)) {
            throw "Module path does not exist: $ModulePath"
        }
        
        # Add to current session PSModulePath
        $currentModulePath = $env:PSModulePath
        if ($currentModulePath -notmatch [regex]::Escape($ModulePath)) {
            $env:PSModulePath = "$currentModulePath;$ModulePath"
            Write-DebugMessage "Added to current session PSModulePath"
        }
        
        # Add to user PSModulePath for persistence
        try {
            $userModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'User')
            if (-not $userModulePath) {
                $userModulePath = $ModulePath
            } elseif ($userModulePath -notmatch [regex]::Escape($ModulePath)) {
                $userModulePath = "$userModulePath;$ModulePath"
            } else {
                Write-DebugMessage "Already in user PSModulePath"
                return $true
            }
            
            [Environment]::SetEnvironmentVariable('PSModulePath', $userModulePath, 'User')
            Write-StatusMessage "[SUCCESS] Added Atomic Red Team to user PSModulePath" 'Green'
            Write-DebugMessage "User PSModulePath updated successfully"
            
        } catch {
            Write-StatusMessage "[WARNING] Could not update user PSModulePath: $($_.Exception.Message)" 'Yellow'
            Write-DebugMessage "User PSModulePath update failed: $($_.Exception.Message)"
            
            # Try system PSModulePath if we have admin rights
            if ((Test-Administrator)) {
                try {
                    $systemModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
                    if ($systemModulePath -notmatch [regex]::Escape($ModulePath)) {
                        [Environment]::SetEnvironmentVariable('PSModulePath', "$systemModulePath;$ModulePath", 'Machine')
                        Write-StatusMessage "[SUCCESS] Added Atomic Red Team to system PSModulePath (admin)" 'Green'
                        Write-DebugMessage "System PSModulePath updated successfully"
                    }
                } catch {
                    Write-StatusMessage "[WARNING] Could not update system PSModulePath: $($_.Exception.Message)" 'Yellow'
                    Write-DebugMessage "System PSModulePath update failed: $($_.Exception.Message)"
                }
            }
        }
        
        # Try to import the module
        Write-StatusMessage "[IMPORT] Importing Atomic Red Team module..." 'Yellow'
        try {
            Import-Module invoke-atomicredteam -Force -ErrorAction Stop
            Write-StatusMessage "[SUCCESS] Module imported successfully" 'Green'
            return $true
        } catch {
            Write-StatusMessage "[WARNING] Could not import module: $($_.Exception.Message)" 'Yellow'
            Write-StatusMessage "Module is installed but may need manual import" 'Gray'
            return $true
        }
        
    } catch {
        Write-StatusMessage "[ERROR] Failed to configure module: $($_.Exception.Message)" 'Red'
        Write-DebugMessage "Module configuration error: $($_.Exception | Format-List * | Out-String)"
        return $false
    }
}

function Test-AtomicInstallation {
    Write-StatusMessage "[VERIFY] Verifying Atomic Red Team installation..." 'Yellow'
    Write-DebugMessage "Testing installation"
    
    try {
        $status = Get-AtomicStatus
        
        # Check basic installation
        if (-not $status.Installed) {
            throw "Basic installation check failed"
        }
        
        # Check module
        if (-not $status.ModuleExists) {
            throw "Module directory not found"
        }
        
        # Try to import module if not already loaded
        if (-not $status.ModuleLoaded) {
            try {
                Import-Module invoke-atomicredteam -Force -ErrorAction Stop
                Write-DebugMessage "Successfully imported module for testing"
            } catch {
                Write-StatusMessage "[WARNING] Module exists but couldn't import: $($_.Exception.Message)" 'Yellow'
                Write-StatusMessage "This might be normal - module can be imported manually" 'Gray'
            }
        }
        
        # Test basic functionality
        try {
            $commands = Get-Command -Module invoke-atomicredteam -ErrorAction SilentlyContinue
            if ($commands) {
                Write-StatusMessage "[SUCCESS] Atomic Red Team is working correctly!" 'Green'
                Write-StatusMessage "   Module Version: $($status.ModuleVersion)" 'Gray'
                Write-StatusMessage "   Available Commands: $($commands.Count)" 'Gray'
                Write-StatusMessage "   Technique Count: $($status.TechniqueCount)" 'Gray'
                return $true
            } else {
                Write-StatusMessage "[WARNING] Module installed but commands not available" 'Yellow'
                Write-StatusMessage "This might be normal - try importing manually" 'Gray'
                return $true
            }
        } catch {
            Write-StatusMessage "[WARNING] Could not test module commands: $($_.Exception.Message)" 'Yellow'
            return $true
        }
        
    } catch {
        Write-StatusMessage "[ERROR] Installation verification failed: $($_.Exception.Message)" 'Red'
        Write-DebugMessage "Verification error: $($_.Exception | Format-List * | Out-String)"
        return $false
    }
}

function Show-AtomicInfo {
    Write-Host "`n" -NoNewline
    Write-Host "=== Atomic Red Team Information ===" -ForegroundColor Cyan
    Write-Host "===================================" -ForegroundColor Cyan
    
    try {
        $status = Get-AtomicStatus
        
        Write-Host "Installation Status: " -NoNewline
        if ($status.Installed) {
            Write-Host "[INSTALLED]" -ForegroundColor Green
        } else {
            Write-Host "[NOT INSTALLED]" -ForegroundColor Red
        }
        
        Write-Host "Installation Path: $($status.InstallPath)" -ForegroundColor Gray
        Write-Host "Module Path: $($status.ModulePath)" -ForegroundColor Gray
        Write-Host "Module Version: $($status.ModuleVersion)" -ForegroundColor Gray
        Write-Host "Module Loaded: $($status.ModuleLoaded)" -ForegroundColor Gray
        Write-Host "Atomics Available: $($status.AtomicsExist)" -ForegroundColor Gray
        Write-Host "Technique Count: $($status.TechniqueCount)" -ForegroundColor Gray
        
        if ($status.ErrorMessage) {
            Write-Host "Error: $($status.ErrorMessage)" -ForegroundColor Red
        }
        
        # Show quick test if installed
        if ($status.Installed) {
            Write-Host "`nQuick Test:" -ForegroundColor Cyan
            try {
                # Try multiple methods to import the module
                $moduleImported = $false
                
                # Method 1: Try direct path import
                $manifestPath = Join-Path $status.ModulePath "Invoke-AtomicRedTeam.psd1"
                if (Test-Path $manifestPath) {
                    try {
                        Import-Module $manifestPath -Force -ErrorAction Stop
                        $moduleImported = $true
                        Write-Host "  [SUCCESS] Module imported using direct path" -ForegroundColor Green
                    } catch {
                        Write-DebugMessage "Direct path import failed: $($_.Exception.Message)"
                    }
                }
                
                # Method 2: Try by name if in module path
                if (-not $moduleImported) {
                    try {
                        Import-Module invoke-atomicredteam -Force -ErrorAction Stop
                        $moduleImported = $true
                        Write-Host "  [SUCCESS] Module imported by name" -ForegroundColor Green
                    } catch {
                        Write-DebugMessage "Name-based import failed: $($_.Exception.Message)"
                    }
                }
                
                if ($moduleImported) {
                    $testCommands = Get-Command -Module invoke-atomicredteam -ErrorAction SilentlyContinue
                    if ($testCommands) {
                        Write-Host "  Available commands: $($testCommands.Count)" -ForegroundColor Gray
                        
                        # Show a few key commands
                        $keyCommands = $testCommands | Where-Object { $_.Name -match '^(Invoke-AtomicTest|Get-AtomicTechnique)' } | Select-Object -First 3
                        if ($keyCommands) {
                            Write-Host "  Key commands available: $($keyCommands.Name -join ', ')" -ForegroundColor Gray
                        }
                    } else {
                        Write-Host "  [WARNING] Module imported but no commands found" -ForegroundColor Yellow
                    }
                } else {
                    Write-Host "  [WARNING] Could not import module automatically" -ForegroundColor Yellow
                    Write-Host "  Try manual import: Import-Module '$manifestPath'" -ForegroundColor Gray
                }
            } catch {
                Write-Host "  [WARNING] Module test failed: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "  Try manual import: Import-Module '$($status.ModulePath)'" -ForegroundColor Gray
            }
        }
        
        # Usage information
        Write-Host "`nUseful Commands:" -ForegroundColor Cyan
        Write-Host "  # Import the module (try these in order)" -ForegroundColor Gray
        Write-Host "  Import-Module '$($status.ModulePath)'" -ForegroundColor White
        Write-Host "  # OR if in module path:" -ForegroundColor Gray
        Write-Host "  Import-Module invoke-atomicredteam" -ForegroundColor White
        Write-Host "" -ForegroundColor Gray
        Write-Host "  # List available techniques" -ForegroundColor Gray
        Write-Host "  Get-ChildItem '$($status.AtomicsPath)' -Directory | Select-Object Name" -ForegroundColor White
        Write-Host "" -ForegroundColor Gray
        Write-Host "  # Show technique details" -ForegroundColor Gray
        Write-Host "  Invoke-AtomicTest T1059.001 -ShowDetailsBrief" -ForegroundColor White
        Write-Host "" -ForegroundColor Gray
        Write-Host "  # Check prerequisites" -ForegroundColor Gray
        Write-Host "  Invoke-AtomicTest T1059.001 -TestNumbers 1 -CheckPrereqs" -ForegroundColor White
        Write-Host "" -ForegroundColor Gray
        Write-Host "  # Execute test (CAUTION!)" -ForegroundColor Gray
        Write-Host "  Invoke-AtomicTest T1059.001 -TestNumbers 1" -ForegroundColor White
        Write-Host "" -ForegroundColor Gray
        Write-Host "  # Cleanup after test" -ForegroundColor Gray
        Write-Host "  Invoke-AtomicTest T1059.001 -TestNumbers 1 -Cleanup" -ForegroundColor White
        
        Write-Host "`nExample Techniques:" -ForegroundColor Cyan
        Write-Host "  T1059.001 - PowerShell execution" -ForegroundColor Gray
        Write-Host "  T1055 - Process injection" -ForegroundColor Gray
        Write-Host "  T1003 - OS credential dumping" -ForegroundColor Gray
        Write-Host "  T1082 - System information discovery" -ForegroundColor Gray
        
        Write-Host "`n[IMPORTANT] Only run tests in isolated lab environments!" -ForegroundColor Yellow
        
    } catch {
        Write-Host "Error displaying Atomic Red Team information: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Main execution
try {
    Write-Host "=== Atomic Red Team Standalone Installer ===" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    
    if ($ShowDetails) {
        Write-Host "[DEBUG] Detailed logging enabled" -ForegroundColor Magenta
    }
    
    # Check prerequisites
    Write-StatusMessage "`n[CHECK] Checking prerequisites..." 'Yellow'
    
    $isAdmin = Test-Administrator
    if ($isAdmin) {
        Write-StatusMessage "[SUCCESS] Administrator privileges detected" 'Green'
    } else {
        Write-StatusMessage "[WARNING] Not running as Administrator (module PATH updates may be limited)" 'Yellow'
    }
    
    # Check current status
    Write-StatusMessage "`n[STATUS] Checking current Atomic Red Team status..." 'Yellow'
    $currentStatus = Get-AtomicStatus
    
    Write-DebugMessage "Current status: Installed=$($currentStatus.Installed), ModuleLoaded=$($currentStatus.ModuleLoaded)"
    
    if ($currentStatus.Installed -and -not $Force) {
        Write-StatusMessage "[SUCCESS] Atomic Red Team is already installed!" 'Green'
        try {
            Show-AtomicInfo
        } catch {
            Write-StatusMessage "Note: There was an issue displaying detailed info, but Atomic Red Team is installed." 'Yellow'
        }
        Write-StatusMessage "`nUse -Force to reinstall" 'Yellow'
        exit 0
    } elseif ($currentStatus.Installed -and $Force) {
        Write-StatusMessage "[FORCE] Force reinstall requested." 'Yellow'
        Write-StatusMessage "This will reinstall Atomic Red Team with the latest version." 'Yellow'
    }
    
    # Download installer
    Write-DebugMessage "Downloading Atomic Red Team installer"
    $installerScript = Download-AtomicInstaller
    
    # Install Atomic Red Team
    Write-DebugMessage "Starting installation"
    $installSuccess = Install-AtomicRedTeam -InstallerScript $installerScript
    if (-not $installSuccess) {
        throw "Atomic Red Team installation failed"
    }
    
    # Configure module access
    Write-DebugMessage "Configuring module"
    $configSuccess = Configure-AtomicModule
    if (-not $configSuccess) {
        Write-StatusMessage "[WARNING] Module configuration had issues, but installation may still work" 'Yellow'
    }
    
    # Verify installation
    Write-DebugMessage "Verifying installation"
    $verifySuccess = Test-AtomicInstallation
    if (-not $verifySuccess) {
        throw "Atomic Red Team installation verification failed"
    }
    
    # Show final status
    Write-Host "`n=== Atomic Red Team Installation Complete! ===" -ForegroundColor Green
    Show-AtomicInfo
    
    Write-Host "`n[QUICK START]" -ForegroundColor Yellow
    Write-Host "  1. Import module: " -NoNewline -ForegroundColor Gray
    Write-Host "Import-Module invoke-atomicredteam" -ForegroundColor White
    Write-Host "  2. List techniques: " -NoNewline -ForegroundColor Gray
    Write-Host "Get-ChildItem C:\AtomicRedTeam\atomics -Directory" -ForegroundColor White
    Write-Host "  3. Show technique: " -NoNewline -ForegroundColor Gray
    Write-Host "Invoke-AtomicTest T1059.001 -ShowDetailsBrief" -ForegroundColor White
    
} catch {
    Write-Host "`n[ERROR] Installation Failed!" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    
    # Show current system state for troubleshooting
    Write-Host "`nCurrent System State:" -ForegroundColor Yellow
    try {
        $debugStatus = Get-AtomicStatus
        Write-Host "* Installation directory exists: $(Test-Path $debugStatus.InstallPath)" -ForegroundColor Gray
        Write-Host "* Module directory exists: $($debugStatus.ModuleExists)" -ForegroundColor Gray
        Write-Host "* Atomics directory exists: $($debugStatus.AtomicsExist)" -ForegroundColor Gray
        Write-Host "* Module importable: $($debugStatus.ModuleImportable)" -ForegroundColor Gray
        Write-Host "* Technique count: $($debugStatus.TechniqueCount)" -ForegroundColor Gray
        
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
    Write-Host "* Try -SkipAtomics to install just the module without techniques" -ForegroundColor Gray
    Write-Host "* Use -InstallPath to try a different installation directory" -ForegroundColor Gray
    Write-Host "* Check PowerShell execution policy: Get-ExecutionPolicy" -ForegroundColor Gray
    
    exit 1
}