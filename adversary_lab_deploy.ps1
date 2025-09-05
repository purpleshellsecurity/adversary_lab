<#
.SYNOPSIS
    Deploys an Azure logging lab solution with VM, Log Analytics workspace, storage for flow logs.

.DESCRIPTION
    Deploys a comprehensive logging lab solution including VM, Log Analytics workspace, 
    Storage for flow logs, Network security groups, and Azure Activity log integration.
    Uses standard Azure secure parameter approach for password handling.
#>

[CmdletBinding()]
param(
    [string]$ResourceGroupName = "",
    [string]$Location = "",
    [string]$SubscriptionId = "",
    [string]$AdminUsername = "",
    [string]$AdminPassword = "",
    [string]$MyIP = "",
    [string]$namePrefix = "adversarylab",
    [string]$VmSize = "Standard_D2s_v3",
    [int]$RetentionInDays = 30,
    [bool]$EnableAzureActivity = $true,
    [switch]$ForceLogin,
    [bool]$EnableAutoShutdown = $true,
    [string]$ShutdownTime = "2330",
    [string]$ShutdownTimeZone = "Eastern Standard Time",
    [bool]$EnableShutdownNotificationEmails = $false,
    [string]$NotificationEmail = "",
    [int]$NotificationMinutesBefore = 15
)

$ErrorActionPreference = "Stop"

# Helper functions
function Write-ColoredOutput {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

function Test-AzurePowerShell {
    try {
        $null = Get-Command Get-AzContext -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

function Get-PublicIPAddress {
    try {
        $ip = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 10).Trim()
        if ($ip -match '^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$') {
            return $ip
        }
        throw "Invalid IP format"
    }
    catch { 
        Write-ColoredOutput "Could not auto-detect IP" "Yellow"
        return $null
    }
}

function New-CompliantPassword {
    param([int]$Length = 16)
    
    $uppercase = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $lowercase = 'abcdefghijklmnopqrstuvwxyz'
    $numbers = '0123456789'
    $special = '!@#$%^&*+-='
    
    # Ensure at least one from each category
    $password = @()
    $password += $uppercase[(Get-Random -Maximum $uppercase.Length)]
    $password += $lowercase[(Get-Random -Maximum $lowercase.Length)]
    $password += $numbers[(Get-Random -Maximum $numbers.Length)]
    $password += $special[(Get-Random -Maximum $special.Length)]
    
    # Fill remaining with random characters
    $allChars = $uppercase + $lowercase + $numbers + $special
    for ($i = 4; $i -lt $Length; $i++) {
        $password += $allChars[(Get-Random -Maximum $allChars.Length)]
    }
    
    return ($password | Sort-Object { Get-Random }) -join ''
}

function Get-InteractiveParameters {
    Write-Host "`n=== Adversary Lab Deployer ===" -ForegroundColor Cyan
    
    # Collect required parameters if not provided
    if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
        $ResourceGroupName = Read-Host "Enter Resource Group name (e.g., adversary-lab-rg)"
    }
    
    if ([string]::IsNullOrWhiteSpace($Location)) {
        $Location = Read-Host "Enter Azure region (e.g., East US)"
    }
    
    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $SubscriptionId = Read-Host "Enter Azure Subscription ID"
    }
    
    if ([string]::IsNullOrWhiteSpace($AdminUsername)) {
        $AdminUsername = Read-Host "Enter VM administrator username"
    }
    
    # Simple password handling - let Azure validate
    if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
        $generateChoice = Read-Host "Generate password automatically? (y/n)"
        if ($generateChoice -eq 'y' -or $generateChoice -eq 'Y') {
            $AdminPassword = New-CompliantPassword
            Write-Host "Generated password: $AdminPassword" -ForegroundColor Green
            Write-Host "Save this password!" -ForegroundColor Yellow
        } else {
            $AdminPassword = Read-Host "Enter password"
        }
    }
    
    # Auto-detect IP
    if ([string]::IsNullOrWhiteSpace($MyIP)) {
        Write-Host "Detecting your public IP..." -ForegroundColor Yellow
        $MyIP = Get-PublicIPAddress
        if ($MyIP) {
            Write-Host "Detected IP: $MyIP" -ForegroundColor Green
        } else {
            $MyIP = Read-Host "Enter your public IP address"
        }
    }
    
    # Optional: Ask about email notifications
    if ([string]::IsNullOrWhiteSpace($NotificationEmail) -and !$EnableShutdownNotificationEmails) {
        $emailChoice = Read-Host "Enable email notifications for VM shutdown and Billing Alarm? (y/n)"
        if ($emailChoice -eq 'y' -or $emailChoice -eq 'Y') {
            $EnableShutdownNotificationEmails = $true
            $NotificationEmail = Read-Host "Enter email address"
        }
    }
    
    # Show summary
    Write-Host "`n=== Configuration Summary ===" -ForegroundColor Cyan
    Write-Host "Resource Group: $ResourceGroupName" -ForegroundColor White
    Write-Host "Location: $Location" -ForegroundColor White
    Write-Host "Admin Username: $AdminUsername" -ForegroundColor White
    Write-Host "VM Size: $VmSize" -ForegroundColor White
    Write-Host "Your IP: $MyIP" -ForegroundColor White
    
    $confirm = Read-Host "`nProceed with deployment? (y/n)"
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "Deployment cancelled." -ForegroundColor Yellow
        exit 0
    }
    
    return @{
        ResourceGroupName = $ResourceGroupName
        Location = $Location
        SubscriptionId = $SubscriptionId
        AdminUsername = $AdminUsername
        AdminPassword = $AdminPassword
        MyIP = $MyIP
        namePrefix = $namePrefix
        VmSize = $VmSize
        RetentionInDays = $RetentionInDays
        EnableAzureActivity = $EnableAzureActivity
        EnableAutoShutdown = $EnableAutoShutdown
        ShutdownTime = $ShutdownTime
        ShutdownTimeZone = $ShutdownTimeZone
        EnableShutdownNotificationEmails = $EnableShutdownNotificationEmails
        NotificationEmail = $NotificationEmail
        NotificationMinutesBefore = $NotificationMinutesBefore
    }
}

function Initialize-AzureContext {
    param($SubscriptionId)
    
    $context = Get-AzContext
    if ($null -eq $context -or $ForceLogin) {
        Write-ColoredOutput "Connecting to Azure..." "Yellow"
        Connect-AzAccount | Out-Null
        Write-ColoredOutput "Connected to Azure!" "Green"
    }
    
    # Set subscription if different
    if ((Get-AzContext).Subscription.Id -ne $SubscriptionId) {
        Write-ColoredOutput "Setting subscription context..." "Yellow"
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    }
    
    $currentContext = Get-AzContext
    Write-ColoredOutput "`n=== Deploying Adversary Lab ===" "Cyan"
    Write-ColoredOutput "Using subscription: $($currentContext.Subscription.Name)" "Green"
}

function Test-AzurePermissions {
    param($ResourceGroupName, $Location)
    
    $resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if ($null -eq $resourceGroup) {
        Write-ColoredOutput "Creating resource group: $ResourceGroupName" "Yellow"
        New-AzResourceGroup -Name $ResourceGroupName -Location $Location | Out-Null
        Write-ColoredOutput "Resource group created!" "Green"
    } else {
        Write-ColoredOutput "Using existing resource group: $ResourceGroupName" "Green"
    }
}

# Main execution
try {
    Write-ColoredOutput "Starting Adversary Lab deployment..." "Green"
    
    # Check prerequisites
    if (-not (Test-AzurePowerShell)) {
        throw "Azure PowerShell module not found. Install with: Install-Module -Name Az"
    }
    
    # Collect parameters
    $params = Get-InteractiveParameters
    
    # Azure setup
    Initialize-AzureContext -SubscriptionId $params.SubscriptionId
    Test-AzurePermissions -ResourceGroupName $params.ResourceGroupName -Location $params.Location
    
    # Check for Bicep templates
    $mainTemplate = Join-Path $PSScriptRoot "main.bicep"
    $subscriptionTemplate = Join-Path $PSScriptRoot "main_subscription.bicep"
    Write-ColoredOutput "Checking to make sure the bicep files are in order..." "Yellow"
    if (-not (Test-Path $mainTemplate)) { 
        throw "main.bicep not found in script directory" 
    }
    if (-not (Test-Path $subscriptionTemplate)) { 
        throw "main_subscription.bicep not found in script directory" 
    }
    
    Write-ColoredOutput "Bicep templates are in order." "Green"
    
    # Deploy main infrastructure FIRST
    Write-ColoredOutput "Deploying main infrastructure..." "Yellow"
    
    # Convert password to SecureString for Azure deployment
    $securePassword = ConvertTo-SecureString $params.AdminPassword -AsPlainText -Force
    
    $deploymentParams = @{
        ResourceGroupName = $params.ResourceGroupName
        TemplateFile = $mainTemplate
        namePrefix = $params.namePrefix
        Location = $params.Location
        AdminUsername = $params.AdminUsername
        AdminPassword = $securePassword
        MyIP = $params.MyIP
        VmSize = $params.VmSize
        RetentionInDays = $params.RetentionInDays
        EnableAutoShutdown = $params.EnableAutoShutdown
        ShutdownTime = $params.ShutdownTime
        ShutdownTimeZone = $params.ShutdownTimeZone
        EnableShutdownNotificationEmails = $params.EnableShutdownNotificationEmails
        NotificationEmail = $params.NotificationEmail
        NotificationMinutesBefore = $params.NotificationMinutesBefore
    }
    
    $deployment = New-AzResourceGroupDeployment @deploymentParams -ErrorAction Stop
    Write-ColoredOutput "Infrastructure deployment completed!" "Green"
    
    # Deploy subscription-level resources SECOND (Activity logs)
    if ($params.EnableAzureActivity) {
        Write-ColoredOutput "Deploying Azure Activity logs..." "Yellow"
        
        # Get the workspace name and VM name from the main deployment outputs
        $workspaceName = $deployment.Outputs["workspaceName"].Value
        $vmName = $deployment.Outputs["vmName"].Value
        Write-ColoredOutput "Using Log Analytics workspace: $workspaceName" "Green"
        Write-ColoredOutput "Using VM: $vmName" "Green"
        
        # Get the VM's managed identity principal ID
        Write-ColoredOutput "Retrieving VM managed identity..." "Yellow"
        $vm = Get-AzVM -ResourceGroupName $params.ResourceGroupName -Name $vmName
        
        if ($vm.Identity -and $vm.Identity.PrincipalId) {
            $vmPrincipalId = $vm.Identity.PrincipalId
            Write-ColoredOutput "Found VM managed identity: $vmPrincipalId" "Green"
        } else {
            throw "VM '$vmName' does not have a system-assigned managed identity enabled. Please ensure your main.bicep template creates the VM with a managed identity."
        }
        
        $subParams = @{
            Location = $params.Location
            TemplateFile = $subscriptionTemplate
            resourceGroupName = $params.ResourceGroupName
            workspaceName = $workspaceName
            enableAzureActivity = $params.EnableAzureActivity
            vmPrincipalId = $vmPrincipalId  # Add VM principal ID
            vmName = $vmName               # Add VM name
        }
        
        $subscriptionDeployment = New-AzSubscriptionDeployment @subParams -ErrorAction Stop
        Write-ColoredOutput "Activity logs deployment completed!" "Green"
    }
    
    # Deployment summary
    Write-ColoredOutput "`n=== Deployment Summary ===" "Cyan"
    Write-ColoredOutput "✓ Resource Group: $($params.ResourceGroupName)" "Green"
    Write-ColoredOutput "✓ VM Name: $($deployment.Outputs["vmName"].Value)" "Green"
    Write-ColoredOutput "✓ VM Public IP: $($deployment.Outputs["vmPublicIP"].Value)" "Green"
    Write-ColoredOutput "✓ Admin Username: $($params.AdminUsername)" "Green"
    Write-ColoredOutput "✓ Admin Password: $($params.AdminPassword)" "Green"
    Write-ColoredOutput "✓ Log Analytics Workspace: $($deployment.Outputs["workspaceName"].Value)" "Green"
    Write-ColoredOutput "✓ Your IP (RDP Access): $($params.MyIP)" "Green"
    Write-ColoredOutput "✓ Auto-shutdown: $(if($params.EnableAutoShutdown){"Enabled at $($params.ShutdownTime)"}else{"Disabled"})" "Green"
    
    if ($params.EnableAzureActivity) {
        Write-ColoredOutput "✓ Azure Activity Logs: Enabled" "Green"
    }
    
    # Show helpful URLs
    if ($deployment.Outputs.ContainsKey("sentinelUrl")) {
        Write-ColoredOutput "`n=== Useful Links ===" "Cyan"
        Write-ColoredOutput "Sentinel URL: $($deployment.Outputs["sentinelUrl"].Value)" "White"
    }
    
    Write-ColoredOutput "`nDeployment completed successfully!" "Green"
    Write-ColoredOutput "You can now RDP to the VM using: mstsc /v:$($deployment.Outputs["vmPublicIP"].Value)" "Cyan"
    
}
catch {
    Write-ColoredOutput "Deployment failed: $($_.Exception.Message)" "Red"
    Write-ColoredOutput "Full error details:" "Yellow"
    Write-ColoredOutput $_.Exception.ToString() "Red"
    exit 1
}
finally {
    # Clear password from memory
    $params = $null
    $securePassword = $null
    [System.GC]::Collect()
}