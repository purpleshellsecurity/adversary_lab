<#
.SYNOPSIS
    Deploys an Azure logging lab solution with VM, Log Analytics workspace, storage for flow logs, and optional auto-shutdown features.

.DESCRIPTION
    The Adversary Lab Deployer orchestrates the deployment of a comprehensive logging lab solution across Resource Group and Subscription levels. 
    It deploys Bicep templates in the correct order: Infrastructure, Log Analytics workspace, Storage for flow logs, and Activity logs.
    
    The script creates a complete lab environment including:
    - Virtual Machine with specified configuration
    - Log Analytics workspace with configurable retention
    - Storage account ready for VNET flow logs
    - Network security groups and virtual networks
    - Optional auto-shutdown scheduling with email notifications
    - Azure Activity log integration
    
    Entra ID logs must be deployed manually due to elevated permissions required.
    VNET flow logs can be configured manually in Azure portal using the created storage account.

.PARAMETER ResourceGroupName
    Name of the resource group to deploy to. This resource group will contain all the lab resources.

.PARAMETER Location
    Azure region for deployment. Use Show-AzureLocations for available regions.
    Examples: "East US", "West US", "Central US", etc.

.PARAMETER SubscriptionId
    Target subscription ID in GUID format. The subscription where resources will be deployed.

.PARAMETER AdminUsername
    VM administrator username. This will be the local administrator account for the deployed VM.

.PARAMETER MyIP
    Your public IP address for RDP access. If not provided, the script will auto-detect your current public IP address.

.PARAMETER NamePrefix
    Prefix for resource names. Default is "adversarylab". All resources will be prefixed with this value.

.PARAMETER VmSize
    Size of the VM to deploy. Default is "Standard_D2s_v3". Choose based on your performance and cost requirements.

.PARAMETER RetentionInDays
    Log Analytics workspace retention period in days. Default is 30 days. Valid range is 7-730 days.

.PARAMETER EnableAzureActivity
    Enable Azure Activity logs collection. Default is $true. Recommended for comprehensive logging.

.PARAMETER ForceLogin
    Force Azure login even if an existing context exists. Use this to ensure you're using the correct Azure account.

.PARAMETER EnableAutoShutdown
    Enable automatic VM shutdown to save costs. Default is $true. Highly recommended for lab environments.

.PARAMETER ShutdownTime
    VM shutdown time in 24-hour format (HHMM). Default is "2330" (11:30 PM).
    Examples: "0830" (8:30 AM), "1900" (7:00 PM), "2330" (11:30 PM)

.PARAMETER ShutdownTimeZone
    Time zone for shutdown schedule. Default is "Eastern Standard Time".
    Use 'tzutil /l' in Command Prompt to list all available time zones.

.PARAMETER EnableShutdownNotificationEmails
    Enable email notifications before shutdown. Default is $false.
    If enabled, NotificationEmail parameter is required.

.PARAMETER NotificationEmail
    Email address for shutdown notifications. Required if EnableShutdownNotificationEmails is $true.
    Must be a valid email address format.

.PARAMETER NotificationMinutesBefore
    Minutes before shutdown to send notification. Default is 15 minutes.
    Valid range is 5-120 minutes.

.EXAMPLE
    .\adversary_lab_deploy.ps1
    
    Interactive deployment - will prompt for required parameters and use defaults for optional ones.

.EXAMPLE
    .\adversary_lab_deploy.ps1 -ResourceGroupName "rg-logging-lab" -Location "East US" -SubscriptionId "12345678-1234-1234-1234-123456789012" -AdminUsername "labadmin"
    
    Basic deployment with required parameters. Will prompt securely for password and use defaults for optional parameters.

.EXAMPLE
    .\adversary_lab_deploy.ps1 -ResourceGroupName "rg-logging-lab" -Location "East US" -SubscriptionId "12345678-1234-1234-1234-123456789012" -AdminUsername "labadmin" -ShutdownTime "1900" -EnableShutdownNotificationEmails $true -NotificationEmail "admin@company.com"
    
    Deployment with custom shutdown time (7:00 PM) and email notifications enabled.

.EXAMPLE
    .\adversary_lab_deploy.ps1 -ResourceGroupName "rg-logging-lab" -Location "West US 2" -SubscriptionId "12345678-1234-1234-1234-123456789012" -AdminUsername "labadmin" -VmSize "Standard_D4s_v3" -RetentionInDays 90 -NamePrefix "mylab"
    
    Deployment with larger VM size, extended log retention, and custom naming prefix.

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    System.Object
    Returns deployment status and resource information upon successful completion.

.NOTES
    Author: Adversary Lab Team
    Version: 2.1
    Requires: PowerShell 7 or later, Azure PowerShell module (Az)
     
    Prerequisites:
    - PowerShell 7 or later
    - Azure PowerShell module (Az) installed
    - Appropriate permissions at Resource Group and Subscription levels
    - Bicep template files (main.bicep, main_subscription.bicep) in same directory
    
    Important:
    - Entra ID logs must be deployed manually due to elevated permissions required
    - VNET flow logs can be configured manually in Azure portal using the created storage account
    - Script will auto-detect your public IP if MyIP parameter is not provided
    - Use confirmation prompts to preview deployment before creating resources
    - Auto-shutdown is highly recommended for lab environments to control costs

.LINK
    https://docs.microsoft.com/en-us/azure/azure-resource-manager/bicep/
    
.LINK
    https://docs.microsoft.com/en-us/azure/azure-monitor/logs/

.FUNCTIONALITY
    Azure Resource Deployment, Logging Infrastructure, Lab Environment Setup
#>

[CmdletBinding()]
param(
    # === REQUIRED PARAMETERS (will collect interactively if not provided) ===
    [Parameter(
        Mandatory = $false,
        HelpMessage = "Enter the name for your resource group (e.g., rg-logging-lab)"
    )]
    [string]$ResourceGroupName = "",
    
    [Parameter(
        Mandatory = $false,
        HelpMessage = "Enter Azure region (e.g., East US, West US 2, Central US)"
    )]
    [ValidateSet(
        "", "East US", "East US 2", "Central US", "North Central US", "South Central US", "West Central US",
        "West US", "West US 2", "West US 3", "Canada Central", "Canada East", "Brazil South",
        "North Europe", "West Europe", "UK South", "UK West", "France Central", "Germany West Central",
        "Switzerland North", "Norway East", "Sweden Central", "Poland Central",
        "Australia East", "Australia Southeast", "Australia Central", "Japan East", "Japan West",
        "Korea Central", "Southeast Asia", "East Asia", "Central India", "South India", "West India",
        "UAE North", "South Africa North"
    )]
    [string]$Location = "",
    
    [Parameter(
        Mandatory = $false,
        HelpMessage = "Enter your Azure subscription ID (GUID format: 12345678-1234-1234-1234-123456789012)"
    )]
    [string]$SubscriptionId = "",
    
    [Parameter(
        Mandatory = $false,
        HelpMessage = "Enter username for VM administrator (e.g., labadmin)"
    )]
    [string]$AdminUsername = "",
    
    [Parameter(
        Mandatory = $false,
        HelpMessage = "Enter your public IP address for RDP access (leave blank for auto-detection)"
    )]
    [string]$MyIP = "",
    
    [Parameter(
        Mandatory = $false,
        HelpMessage = "Enter prefix for resource names (default: adversarylab - matches Bicep)"
    )]
    [string]$NamePrefix = "adversarylab",
    
    [Parameter(
        Mandatory = $false,
        HelpMessage = "Enter VM size (default: Standard_D2s_v3)"
    )]
    [ValidateSet("Standard_B2s", "Standard_D2s_v3", "Standard_D4s_v3", "Standard_D8s_v3")]
    [string]$VmSize = "Standard_D2s_v3",
    
    [Parameter(
        Mandatory = $false,
        HelpMessage = "Enter log retention in days (7-730, default: 30)"
    )]
    [ValidateRange(7, 730)]
    [int]$RetentionInDays = 30,
    
    [Parameter(
        Mandatory = $false,
        HelpMessage = "Enable Azure Activity logs? (default: true)"
    )]
    [bool]$EnableAzureActivity = $true,
    
    [Parameter(
        Mandatory = $false,
        HelpMessage = "Force Azure login even if already connected?"
    )]
    [switch]$ForceLogin,
    
    [Parameter(
        Mandatory = $false,
        HelpMessage = "Enable automatic VM shutdown to save costs? (default: true)"
    )]
    [bool]$EnableAutoShutdown = $true,
    
    [Parameter(
        Mandatory = $false,
        HelpMessage = "Enter shutdown time in 24-hour format HHMM (default: 2330 = 11:30 PM - matches Bicep)"
    )]
    [ValidatePattern('^([01][0-9]|2[0-3])[0-5][0-9]$')]
    [string]$ShutdownTime = "2330",
    
    [Parameter(
        Mandatory = $false,
        HelpMessage = "Enter time zone for shutdown (default: Eastern Standard Time - matches Bicep)"
    )]
    [ValidateScript({
        if ([string]::IsNullOrWhiteSpace($_)) { return $true }
        try {
            [System.TimeZoneInfo]::FindSystemTimeZoneById($_)
            return $true
        }
        catch {
            throw "Invalid time zone: $_. Use 'tzutil /l' to list available time zones."
        }
    })]
    [string]$ShutdownTimeZone = "Eastern Standard Time",
    
    [Parameter(
        Mandatory = $false,
        HelpMessage = "Enable email notifications before shutdown? (default: false)"
    )]
    [bool]$EnableShutdownNotificationEmails = $false,
    
    [Parameter(
        Mandatory = $false,
        HelpMessage = "Enter email for notifications (required if notifications enabled)"
    )]
    [ValidatePattern('^$|^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$')]
    [string]$NotificationEmail = "",
    
    [Parameter(
        Mandatory = $false,
        HelpMessage = "Enter minutes before shutdown to send notification (5-120, default: 15)"
    )]
    [ValidateRange(5, 120)]
    [int]$NotificationMinutesBefore = 15
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Function to write colored output
function Write-ColoredOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

# Check PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "This script requires PowerShell 7 or later. Please install PowerShell 7 and run with 'pwsh' instead of 'powershell'." -ForegroundColor Red
    Write-Host "Download from: https://github.com/PowerShell/PowerShell/releases" -ForegroundColor Yellow
    exit 1
}

# Function to check if Azure PowerShell is available
function Test-AzurePowerShell {
    try {
        $null = Get-Command Get-AzContext -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

# Function to validate IP address format
function Test-IPAddress {
    param([string]$IP)
    return $IP -match '^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
}

# Function to get public IP address
function Get-PublicIPAddress {
    Write-ColoredOutput "Detecting your public IP address from ipify.org..." "Yellow"
    
    try {
        $response = Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 10 -ErrorAction Stop
        $ip = $response.Trim()
        
        if (Test-IPAddress -IP $ip) {
            Write-ColoredOutput "Public IP detected: $ip" "Green"
            return $ip
        } else {
            throw "Invalid IP address format returned: $ip"
        }
    }
    catch {
        Write-ColoredOutput "Failed to get IP from ipify.org: $($_.Exception.Message)" "Red"
        throw "Unable to automatically detect your public IP address. Please provide it manually using the -MyIP parameter."
    }
}

# === INTERACTIVE PARAMETER COLLECTION FUNCTION ===
function Get-InteractiveParameters {
    Write-Host "`n=== Adversary Lab Deployer ===" -ForegroundColor Cyan
    Write-Host "This wizard will help you configure your lab environment.`n" -ForegroundColor White
    
    # Collect required parameters if not provided
    if ([string]::IsNullOrWhiteSpace($script:ResourceGroupName)) {
        $script:ResourceGroupName = Read-Host "Enter Resource Group name (e.g., rg-logging-lab)"
    }
    
    if ([string]::IsNullOrWhiteSpace($script:Location)) {
        Write-Host "`nAvailable regions: East US, West US 2, Central US, North Europe, etc." -ForegroundColor Gray
        $script:Location = Read-Host "Enter Azure region"
    }
    
    if ([string]::IsNullOrWhiteSpace($script:SubscriptionId)) {
        $script:SubscriptionId = Read-Host "Enter Azure Subscription ID (GUID format)"
    }
    
    if ([string]::IsNullOrWhiteSpace($script:AdminUsername)) {
        $script:AdminUsername = Read-Host "Enter VM administrator username"
    }
    
    # Handle password securely
    if (-not $script:AdminPassword) {
        Write-Host "`nVM Administrator Password:" -ForegroundColor Yellow
        Write-Host "  - Must be complex (uppercase, lowercase, number, special character)" -ForegroundColor Gray
        Write-Host "  - Minimum 12 characters recommended" -ForegroundColor Gray
        
        do {
            $script:AdminPassword = Read-Host "Enter password (input hidden)" -AsSecureString
            $confirmPassword = Read-Host "Confirm password (input hidden)" -AsSecureString
            
            # Convert to plain text for comparison
            $pwd1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:AdminPassword))
            $pwd2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirmPassword))
            
            if ($pwd1 -ne $pwd2) {
                Write-Host "Passwords don't match. Please try again." -ForegroundColor Red
                $match = $false
            } else {
                $match = $true
            }
            
            # Clear plain text from memory
            $pwd1 = $null
            $pwd2 = $null
            
        } while (-not $match)
        
        Write-Host "[SUCCESS] Password set successfully" -ForegroundColor Green
    }
    
    # Auto-detect IP if not provided
    if ([string]::IsNullOrWhiteSpace($script:MyIP)) {
        Write-Host "`nDetecting your public IP address..." -ForegroundColor Yellow
        try {
            $script:MyIP = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 10).Trim()
            Write-Host "[SUCCESS] Detected IP: $($script:MyIP)" -ForegroundColor Green
        } catch {
            Write-Host "[WARNING] Could not auto-detect IP. You may need to specify manually." -ForegroundColor Yellow
        }
    }
    
    # === OPTIONAL CONFIGURATION PROMPTS ===
    Write-Host "`nOptional Configuration (press Enter to use defaults):" -ForegroundColor Cyan
    
    # Custom shutdown time
    $customShutdown = Read-Host "Custom shutdown time? (current: $ShutdownTime) [Enter to keep default]"
    if (-not [string]::IsNullOrWhiteSpace($customShutdown)) {
        $script:ShutdownTime = $customShutdown
    }
    
    # Email notifications
    $emailChoice = Read-Host "Enable email notifications for VM and budget? (y/n) [default: n]"
    if ($emailChoice -eq 'y') {
        $script:EnableShutdownNotificationEmails = $true
        $script:NotificationEmail = Read-Host "Enter email address"
        
        $customMinutes = Read-Host "Minutes before shutdown to notify? [default: 15]"
        if (-not [string]::IsNullOrWhiteSpace($customMinutes)) {
            $script:NotificationMinutesBefore = [int]$customMinutes
        }
    }
    
    # VM Size option
    $vmChoice = Read-Host "VM Size (Standard_B2s/Standard_D2s_v3/Standard_D4s_v3/Standard_D8s_v3) [default: $VmSize]"
    if (-not [string]::IsNullOrWhiteSpace($vmChoice)) {
        $script:VmSize = $vmChoice
    }
    
    # Log retention
    $retentionChoice = Read-Host "Log retention in days (7-730) [default: $RetentionInDays]"
    if (-not [string]::IsNullOrWhiteSpace($retentionChoice)) {
        $script:RetentionInDays = [int]$retentionChoice
    }
    
    # Validate notification email if notifications enabled
    if ($script:EnableShutdownNotificationEmails -and [string]::IsNullOrWhiteSpace($script:NotificationEmail)) {
        Write-Host "`nEmail notifications are enabled but no email provided." -ForegroundColor Yellow
        $script:NotificationEmail = Read-Host "Enter notification email address"
    }
    
    # Display configuration summary
    Write-Host "`n=== Configuration Summary ===" -ForegroundColor Cyan
    Write-Host "Resource Group: $($script:ResourceGroupName)" -ForegroundColor White
    Write-Host "Location: $($script:Location)" -ForegroundColor White
    Write-Host "Subscription ID: $($script:SubscriptionId)" -ForegroundColor White
    Write-Host "Admin Username: $($script:AdminUsername)" -ForegroundColor White
    Write-Host "Name Prefix: $NamePrefix" -ForegroundColor White
    Write-Host "VM Size: $($script:VmSize)" -ForegroundColor White
    Write-Host "Auto-shutdown: $EnableAutoShutdown $(if($EnableAutoShutdown){"at $($script:ShutdownTime) ($ShutdownTimeZone)"})" -ForegroundColor White
    Write-Host "Email notifications: $(if($script:EnableShutdownNotificationEmails){"Enabled - $($script:NotificationEmail)"}else{"Disabled"})" -ForegroundColor White
    Write-Host "Your IP: $($script:MyIP)" -ForegroundColor White
    Write-Host "Log Retention: $($script:RetentionInDays) days" -ForegroundColor White
    
    $confirm = Read-Host "`nProceed with deployment? (y/n)"
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "Deployment cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# Function to check and establish Azure PowerShell context
function Initialize-AzureContext {
    try {
        $context = Get-AzContext
        
        if ($null -eq $context -or $ForceLogin) {
            if ($ForceLogin) {
                Write-ColoredOutput "Force login requested. Connecting to Azure..." "Yellow"
            } else {
                Write-ColoredOutput "No Azure context found. Connecting to Azure..." "Yellow"
            }
            
            # Connect to Azure
            $connectResult = Connect-AzAccount -ErrorAction Stop
            
            if ($null -eq $connectResult) {
                throw "Failed to connect to Azure. Please check your credentials."
            }
            
            Write-ColoredOutput "Successfully connected to Azure!" "Green"
            $context = Get-AzContext
        }
        
        # Display current context
        Write-ColoredOutput "Current Azure Context:" "Cyan"
        Write-ColoredOutput "  Account: $($context.Account.Id)" "White"
        Write-ColoredOutput "  Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))" "White"
        Write-ColoredOutput "  Tenant: $($context.Tenant.Id)" "White"
        
        # Set the subscription context if different
        if ($context.Subscription.Id -ne $SubscriptionId) {
            Write-ColoredOutput "Setting subscription context to: $SubscriptionId" "Yellow"
            Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
            Write-ColoredOutput "Subscription context updated successfully!" "Green"
        }
        
        return
    }
    catch {
        throw "Azure context initialization failed: $($_.Exception.Message)"
    }
}

# Function to validate Azure permissions
function Test-AzurePermissions {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName
    )
    
    Write-ColoredOutput "Validating Azure permissions..." "Yellow"
    
    try {
        # Check if resource group exists or if we can create it
        $resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
        
        if ($null -eq $resourceGroup) {
            Write-ColoredOutput "Resource group '$ResourceGroupName' does not exist. Creating it..." "Yellow"
            $resourceGroup = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction Stop
            Write-ColoredOutput "Resource group created successfully!" "Green"
        } else {
            Write-ColoredOutput "Resource group '$ResourceGroupName' already exists." "Green"
        }
        
        # Test subscription-level permissions
        $subscriptionContext = Get-AzContext
        if ($null -eq $subscriptionContext) {
            throw "No subscription context available"
        }
        
        Write-ColoredOutput "Permissions validation completed!" "Green"
        return
    }
    catch {
        Write-ColoredOutput "Permission validation failed: $($_.Exception.Message)" "Red"
        Write-ColoredOutput "Please ensure you have:" "Yellow"
        Write-ColoredOutput "  - Contributor role on the subscription" "White"
        throw
    }
}

# Main deployment function
function Start-LoggingLabDeployment {
    param()
    
    Write-ColoredOutput "=== Adversary Lab Deployer ===" "Cyan"
    Write-ColoredOutput "Starting deployment process..." "Green"
    
    # Interactive parameter collection
    Get-InteractiveParameters
    
    # Validate prerequisites
    Write-ColoredOutput "`n=== Validating Prerequisites ===" "Cyan"
    
    # Check for Azure PowerShell
    if (-not (Test-AzurePowerShell)) {
        throw "Azure PowerShell module is not available. Please install the Az module: Install-Module -Name Az"
    }
    Write-ColoredOutput "[SUCCESS] Azure PowerShell module found" "Green"
    
    Write-ColoredOutput "`n=== Verifying Azure Authentication ===" "Cyan"
    # Initialize Azure context
    Initialize-AzureContext
    
    # Get public IP if not provided
    Write-ColoredOutput "`n=== Determining Public IP ===" "Cyan"
    if (-not $MyIP) {
        $MyIP = Get-PublicIPAddress
    } else {
        # Validate provided IP address
        if (-not (Test-IPAddress -IP $MyIP)) {
            throw "Invalid IP address format: $MyIP"
        }
        Write-ColoredOutput "[SUCCESS] Using provided IP address: $MyIP" "Green"
    }
    
    Write-ColoredOutput "`n=== Validating Permissions ===" "Cyan"
    # Validate Azure permissions
    Test-AzurePermissions -SubscriptionId $script:SubscriptionId -ResourceGroupName $script:ResourceGroupName
    
    # Convert secure string to plain text for deployment
    $PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:AdminPassword))
    
    try {
        Write-ColoredOutput "`n=== Deployment Configuration ===" "Cyan"
        Write-ColoredOutput "Resource Group: $($script:ResourceGroupName)" "White"
        Write-ColoredOutput "Location: $($script:Location)" "White"
        Write-ColoredOutput "Subscription: $($script:SubscriptionId)" "White"
        Write-ColoredOutput "VM Size: $VmSize" "White"
        Write-ColoredOutput "Your IP: $MyIP" "White"
 
        # ===== PHASE 1: Resource Group Level Deployment =====
        Write-ColoredOutput "`n=== Phase 1: Resource Group Level Deployment ===" "Cyan"
        Write-ColoredOutput "This will take a while, make some coffee" "White"
        
        # Params for deployment for resourcegroup level
        $rgParams = @{
            location = $script:Location
            adminUsername = $script:AdminUsername
            adminPassword = $PlainPassword
            namePrefix = $NamePrefix
            vmSize = $script:VmSize
            myIP = $MyIP
            retentionInDays = $script:RetentionInDays
            enableAutoShutdown = $EnableAutoShutdown
            shutdownTime = $script:ShutdownTime
            shutdownTimeZone = $ShutdownTimeZone
            enableShutdownNotificationEmails = $script:EnableShutdownNotificationEmails
            notificationEmail = $script:NotificationEmail
            notificationMinutesBefore = $script:NotificationMinutesBefore
        }
        
        $rgDeploymentParams = @{
            ResourceGroupName = $script:ResourceGroupName
            TemplateFile = "main.bicep"
            TemplateParameterObject = $rgParams
            Name = "Adversary_Lab-Deployment-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        }
        
        if ($true) {
            Write-ColoredOutput "Deploying infrastructure, storage, and Log Analytics workspace..." "Yellow"
            $rgResult = New-AzResourceGroupDeployment @rgDeploymentParams
            
            # Extract outputs from resource group deployment
            $WorkspaceName = $rgResult.Outputs.workspaceName.Value
            $WorkspaceResourceId = $rgResult.Outputs.workspaceResourceId.Value
            $VmPublicIP = $rgResult.Outputs.vmPublicIP.Value
            $SentinelUrl = $rgResult.Outputs.sentinelUrl.Value
            $StorageAccountName = $rgResult.Outputs.storageAccountName.Value
            
            Write-ColoredOutput "[SUCCESS] Resource Group deployment completed successfully!" "Green"
            Write-ColoredOutput "  Workspace Name: $WorkspaceName" "White"
            Write-ColoredOutput "  VM Public IP: $VmPublicIP" "White"
            Write-ColoredOutput "  Storage Account: $StorageAccountName" "White"
            
            # ===== PHASE 2: Subscription Level Deployment =====
            Write-ColoredOutput "`n=== Phase 2: Subscription Level Deployment ===" "Cyan"
            
            # Params for subscription level deployment
            $subParams = @{
                resourceGroupName = $script:ResourceGroupName
                workspaceName = $WorkspaceName
                enableAzureActivity = $EnableAzureActivity
            }
            
            $subDeploymentParams = @{
                Location = $script:Location
                TemplateFile = "main_subscription.bicep"
                TemplateParameterObject = $subParams
                Name = "AdversaryLab-Sub$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            }
            
            Write-ColoredOutput "Deploying Azure Activity logs..." "Yellow"
            $subResult = New-AzSubscriptionDeployment @subDeploymentParams
            Write-ColoredOutput "[SUCCESS] Subscription deployment completed successfully!" "Green"
            
            # ===== DEPLOYMENT SUMMARY =====
            Write-ColoredOutput "`n=== Deployment Summary ===" "Cyan"
            Write-ColoredOutput "[SUCCESS] Resource Group and Subscription deployments completed successfully!" "Green"
            Write-ColoredOutput "Resource Group: $($script:ResourceGroupName)" "White"
            Write-ColoredOutput "Subscription: $($script:SubscriptionId)" "White"
            Write-ColoredOutput "Workspace: $WorkspaceName" "White"
            Write-ColoredOutput "Storage Account: $StorageAccountName (ready for VNET flow logs)" "White"
            
            # Display connection information
            Write-ColoredOutput "`n=== Connection Information ===" "Yellow"
            Write-ColoredOutput "VM Public IP: $VmPublicIP" "White"
            Write-ColoredOutput "RDP Command: mstsc /v:$VmPublicIP" "Cyan"
            Write-ColoredOutput "Sentinel URL: $SentinelUrl" "Cyan"
            
            Write-ColoredOutput "`n=== Manual Steps Required ===" "Yellow"
            Write-ColoredOutput "[MANUAL STEP] Entra ID Audit Logs Deployment:" "Red"
            Write-ColoredOutput "Due to elevated permissions required, please deploy Entra ID logs manually:" "White"
            Write-ColoredOutput "1. Navigate to Azure Portal > Microsoft Entra ID > Diagnostic settings" "White"
            Write-ColoredOutput "2. Add diagnostic setting with the following configuration:" "White"
            Write-ColoredOutput "   - Name: EntraID-AuditLogs" "Gray"
            Write-ColoredOutput "   - Logs: AuditLogs, SignInLogs" "Gray"
            Write-ColoredOutput "   - Destination: Send to Log Analytics workspace" "Gray"
            Write-ColoredOutput "   - Workspace: $WorkspaceName" "Gray"
            Write-ColoredOutput "   - Resource ID: $WorkspaceResourceId" "Gray"
            
            Write-ColoredOutput "`n[MANUAL STEP] VNET Flow Logs Setup:" "Yellow"
            Write-ColoredOutput "A storage account has been created and is ready for VNET flow logs:" "White"
            Write-ColoredOutput "1. Navigate to Azure Portal > Network Watcher > Flow logs" "White"
            Write-ColoredOutput "2. Create a new VNET flow log with the following configuration:" "White"
            Write-ColoredOutput "   - Target: Your Virtual Network" "Gray"
            Write-ColoredOutput "   - Storage Account: $StorageAccountName" "Gray"
            Write-ColoredOutput "   - Log Analytics: $WorkspaceName (optional for Traffic Analytics)" "Gray"
            Write-ColoredOutput "   - Format: JSON Version 2" "Gray"
            
            Write-ColoredOutput "`n=== Next Steps ===" "Yellow"
            Write-ColoredOutput "1. Complete the manual Entra ID logs setup above" "White"
            Write-ColoredOutput "2. Optionally configure VNET flow logs using the created storage account" "White"
            Write-ColoredOutput "3. Wait 10-15 minutes for data connectors to initialize" "White"
            Write-ColoredOutput "4. Access Microsoft Sentinel in the Azure portal" "White"
            Write-ColoredOutput "5. Verify data connectors are receiving data" "White"
            Write-ColoredOutput "6. Connect to the VM using RDP for testing" "White"
            Write-ColoredOutput "7. Admin Username: $($script:AdminUsername)" "White"
            
            Write-ColoredOutput "`n=== Deployment Details ===" "Gray"
            Write-ColoredOutput "Resource Group Deployment: $($rgResult.DeploymentName)" "Gray"
            if ($subResult) { Write-ColoredOutput "Subscription Deployment: $($subResult.DeploymentName)" "Gray" }
        }
    }
    catch {
        Write-ColoredOutput "[ERROR] Deployment failed: $($_.Exception.Message)" "Red"
        Write-ColoredOutput "Error details: $($_.Exception.ToString())" "Red"
        throw
    }
    finally {
        # Clear the plain text password from memory
        $PlainPassword = $null
    }
}

# Main execution
try {
    Start-LoggingLabDeployment
}
catch {
    Write-ColoredOutput "[ERROR] Script execution failed: $($_.Exception.Message)" "Red"
    Write-ColoredOutput "`nTroubleshooting Tips:" "Yellow"
    Write-ColoredOutput "1. Ensure you have the Azure PowerShell module installed: Install-Module -Name Az" "White"
    Write-ColoredOutput "2. Check that you have appropriate permissions in your Azure subscription" "White"
    Write-ColoredOutput "3. Verify your Bicep template files are in the same directory as this script" "White"
    Write-ColoredOutput "4. Use -ForceLogin parameter if you need to re-authenticate" "White"
    Write-ColoredOutput "5. For Entra ID logs, configure manually in Azure Portal as shown in the summary" "White"
    Write-ColoredOutput "6. For VNET flow logs, use the created storage account and configure manually" "White"
    exit 1
}

Write-ColoredOutput "`n[SUCCESS] Deployment orchestration completed successfully!" "Green"
Write-ColoredOutput "Remember to manually configure:" "Yellow"
Write-ColoredOutput "  - Entra ID diagnostic settings as outlined above" "White"
Write-ColoredOutput "  - VNET flow logs using the created storage account (optional)" "White"