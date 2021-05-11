<#
.SYNOPSIS
    Script to pre-create RG's and assocated SPNs, assign rights, and create service connection in ADO.

.DESCRIPTION
    Script to pre-create RG's and assocated SPNs, assign rights, and create service connection in ADO.

.PARAMETER App 
    Enter an abbreviation for the app/service that will be deployed to this resource group.  This will become the suffix of the resource group name.
    Example: "wecm" for Windows Endpoint Configuration Manager

.PARAMETER Tier 
    Enter the Application Tier
    Example: 0 = Identity/Authentication Tier, 1 = Server Administration Tier, 2 = User Workstation Administration Tier

.PARAMETER Cloud
    Enter the name of the Cloud that is being used.
    NOTE: This currently only works for Azure Commercial Cloud.  Other clouds will be added.

.PARAMETER Location
    Enter the region in Azure to which the resource group should be deployed.
    Example: South Central US

.PARAMETER tagDept
    Enter the department requesting the creation of the resource group.
    Example: "Marketing"

.PARAMETER tagEnv
    Enter the environment to which resources in this resource group will be deployed.  This will become the prefix for the resource group name.
    Example: "prd" for production

.PARAMETER DevOpsUrl
    Enter the URL of the the Azure Dev Ops organization in which the service connection will be created.
    Example: "https://dev.azure.com/MyOrganization"

.PARAMETER DevOpsProject
    Enther the name of the project in Azure DevOps in which the service connection will be created.
    Example: "MyInfraProject"

.EXAMPLE
    .\New-CustomResourceGroup.ps1 -App 'logs' -Tier '2' 
#>
[CmdletBinding()]
Param
(
    [parameter(Mandatory=$true,
    HelpMessage='Example: logs. This is the suffix for the Resource Group/SPN. For "logs", it will create "dev-rg-logs" (Resource Group) and "dev-sp-logs" (Service Principal)')]
    [String]$App,

    [parameter(Mandatory=$true,HelpMessage='Example: 0,1,2')]
    [String]$Tier,

    [parameter(Mandatory=$false,HelpMessage='This script only supports Azure Commercial at the momment.')]
    # To Be Added [ValidationSet("AzureCloud","AzureUSGovernment","AzureGermanCloud","AzureChinaCloud")]
    [ValidateSet("AzureCloud")]
    [String]$Cloud = "AzureCloud",

    [parameter(Mandatory=$false,HelpMessage='Example: South Central US')]
    [String]$Location = 'South Central US',

    [parameter(Mandatory=$false,HelpMessage='Example: marketing')]
    [String]$tagDept,

    [parameter(Mandatory=$true,HelpMessage='Example values: lab, dev, tst, stg, uat, prd')]
    [ValidateSet("lab","dev","tst","stg","uat","prd")]
    [String]$tagEnv = "dev",

    [parameter(Mandatory=$true,HelpMessage='Examples: "Dev Subscription" or "Prod Subscription"')]
    [String]$subscriptionName = "Dev Subscription",

    [parameter(Mandatory=$true,HelpMessage='Example: https://dev.azure.com/MyOrganization')]
    [String]$DevOpsUrl,

    [parameter(Mandatory=$true,HelpMessage='The name of the Azure DevOps Project. Example: MyProject')]
    [String]$DevOpsProject
)

#region Ask for Login and Set Environment Variables

#Clear context and login with new context
Clear-AzContext -Force
Write-Host "Login with your Azure Commercial account (account for Azure DevOps)" -ForegroundColor Yellow -BackgroundColor Red
Save-AzContext -Profile (Add-AzAccount -Environment $Cloud -Subscription $subscriptionName) -Path $env:TEMP\com-cloud.json -Force
#Get Token for GCC
$ctx = Get-AzContext
$cacheItems = $ctx.TokenCache.ReadItems()
#Bearer token to access DevOps w/ same account as AAD.
$token = ($cacheItems[0]).AccessToken

Select-AzSubscription -SubscriptionName $subscriptionName 

#The group below must be granted permissions to the build-secrets keyvault, the network, and resource deployments
#It's best to create a custom role with limited permissions.
#For example, a custom role for IaaS might use the following permissions:
#Role Name: "Custom - DevOps template deployment operator"
#Microsoft Key Vault -> Key Vault : Other Actions -> Use Vault for Azure Deployments
#Microsoft Key Valut -> Key Vault -> Secrets : Write: Write Secrets
#Microsoft Network -> Virtual Network : Other Actions -> Join Virtual Network.
#Microsoft Network -> Virtual Network -> Virtual Network Subnet : Other Actions -> Join Virtual Network.
#Microsoft Resources -> Deployment : Read: Get Deployment
#Microsoft Resources -> Deployment : Write: Create Deployment
#Microsoft Resources -> Deployment -> Deployment operation status : Read: Get deployment operation status

#Use this role to assign permissions to the group below on resource groups/subscriptions containing your build-secrets keyvaults and VNETs.  The script will grant
#it contributor permissions on the resource group that gets created. 
$aadGroup = "DevOps $tagEnv Deployment Operators"

#The section below was placed here to prepare for supporting additional clouds.
$az = Get-Content -Path $env:TEMP\com-cloud.json | ConvertFrom-Json
$subScopeId = $az.Contexts.Default.Subscription.SubscriptionId

$subName = $az.Contexts.Default.Subscription.Name
$cloudEnv = $az.Contexts.Default.Environment.Name
$cloudUrl = $az.Contexts.Default.Environment.ResourceManagerUrl
$tenantId = $az.Contexts.Default.Tenant.TenantId
$createdBy = $az.Contexts.Default.Account.Id

#Dynamic variables
$appName = $app
$rgName = "$tagEnv-rg-$appName"
$spName = "$tagEnv-sp-$appName"
$scope = "/subscriptions/$subScopeId/resourceGroups/$rgName"
$tags = @{
    App=$appName;
    Department=$tagDept;
    Environment=$tagEnv
    Tier=$tier
    CreatedBy=$createdBy
}
#endregion

#region Create Resource Group
Write-Host "[INFO] Checking Resource Group:    $rgName" -ForegroundColor Cyan
If ($null -eq (Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue))
{
    Write-Host "[INFO] Creating Resource Group:    $rgName" -ForegroundColor Cyan
    New-AzResourceGroup -Location $Location -Name $rgName -Tag $tags | Out-Null
}
else {Write-Host "[INFO] The Resource Group exists:  $rgName"  -ForegroundColor Cyan}
#endregion

#region Create Service Principal
If ($null -eq (Get-AzADServicePrincipal -DisplayName $spName))
{
    #Create Service Principal and assign rights
    Write-Host "[INFO] Creating Service Principal: $spName. This can take a minute..." -ForegroundColor Cyan
    $sp = New-AzADServicePrincipal -DisplayName $spName -Scope $scope -Role Contributor -WarningAction SilentlyContinue
    $secret = $sp.Secret
    Write-Host "[INFO] Created Service Principal:  $spName." -ForegroundColor Cyan
}
else
{
    #Just get the Service Principal information and create a new password
    $sp = Get-AzADServicePrincipal -DisplayName $spName
    $credProps = @{
        StartDate = Get-Date
        EndDate = (Get-Date -Year 2024)
        KeyId = (New-Guid).ToString()
        Value = (New-Guid).ToString()
    }
    $credentials = New-Object Microsoft.Azure.Graph.RBAC.Models.PasswordCredential -Property $credProps
    Set-AzADServicePrincipal -ObjectId $sp.Id -PasswordCredential $credentials
    $secret = ConvertTo-SecureString -AsPlainText -Force $credProps.Value

}
  
If ($null -ne $sp)
{
    #Assign Contributor
    if ($null -eq (Get-AzRoleAssignment -ObjectId $sp.Id -ResourceGroupName $rgName | Where-Object {$_.RoleDefinitionName -eq "Contributor"}))
    {
        $null = New-AzRoleAssignment -ObjectId $sp.Id -ResourceGroupName $rgName -RoleDefinitionName 'Contributor'
    }
}
#endregion

#region Add Service Principal to appropriate AAD Groups
# Add to DevOps Deployment Operators
if ($null -eq (Get-AzADGroup -DisplayName $aadGroup))
{
    Write-Error -Message "[ERROR] Can't find Azure AD Group `"$aadGroup`"! You may have to do this step after script completes."
}
else 
{
    if ($null -eq (Get-AzADGroupMember -GroupDisplayName $aadGroup | Where-Object {$_.DisplayName -eq $sp.DisplayName}))
    {
        Add-AzADGroupMember -MemberObjectId $sp.Id -TargetGroupDisplayName $aadGroup -Verbose -ErrorAction SilentlyContinue
    }
}
Remove-Item -Path $env:TEMP\com-cloud.json -Force
#endregion

#region Create Service Connection in Azure DevOps
$spNameId = $sp.ApplicationId
#$spNameId = $sp.ServicePrincipalNames | Where-Object {$_ -notlike "http*"} | Select-Object -First 1
$spkey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret))

#Set variables for request body
$params = @{
    data=@{
        SubscriptionId=$subScopeId;
        SubscriptionName=$subName;
        environment=$cloudEnv;
        scopeLevel="Subscription";
        creationMode="Manual"
    }
    name=$spName;
    type="azurerm";
    url=$cloudUrl;
    authorization=@{
        scheme="ServicePrincipal";
        parameters=@{
            servicePrincipalId=$spNameId;servicePrincipalKey=$spKey;authenticationType="spnKey";tenantId=$tenantId;}
        }
    }
$body = $params | ConvertTo-Json

#Set headers and send request
$headers = @{"Authorization" = "Bearer " + $token;"Content-Type" = "application/json"}
$baseUri = "$DevOpsUrl/$DevOpsProject/_apis/serviceendpoint/endpoints?api-version=5.1-preview"
$req = Invoke-RestMethod -Method POST -Uri $baseUri -Headers $headers -Body $body #-ErrorAction SilentlyContinue
If ($req.isReady -eq $true) {Write-Host "[INFO] Success!" -ForegroundColor Green}
Else {
    Write-Host "[ERR] An error occurred!" -ForegroundColor Red
    $Error[0] | Format-List
}
#endregion