$domain = "<tenantname>.onmicrosoft.com" #Use Primary domain found here https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/Overview #note if you created the tenant with your email it will most likely be some form of your email address. 
$userPrincipalName = "adversarylabdeployer@$domain"

Write-Host "Creating user: $userPrincipalName"

$userPassword = ConvertTo-SecureString "TempPassword123!" -AsPlainText -Force #Change this please...

try {
    $newUser = New-AzADUser `
        -DisplayName "Adversary lab deployer" `
        -UserPrincipalName $userPrincipalName `
        -Password $userPassword `
        -MailNickname "adversarylabdeployer"
    
    if ($newUser -and $newUser.Id) {
        Write-Host "User created successfully with ID: $($newUser.Id)"
        
        # Assign Contributor role
        New-AzRoleAssignment `
            -ObjectId $newUser.Id `
            -RoleDefinitionName "Contributor" `
            -Scope "/subscriptions/$((Get-AzContext).Subscription.Id)"
        
        Write-Host "Contributor role assigned successfully"
        
        # Verify the assignment
        Get-AzRoleAssignment -ObjectId $newUser.Id | Select-Object RoleDefinitionName, Scope
        
    } else {
        Write-Host "User creation returned null or empty"
    }
    
} catch {
    Write-Host "Error: $($_.Exception.Message)"
    Write-Host "Full error details:"
    Write-Host $_.Exception.ToString()
}