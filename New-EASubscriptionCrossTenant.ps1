#requires -Version 7.2
#requires -Modules Az.Accounts
<#
.SYNOPSIS
Creates a NEW EA subscription and accepts ownership in a separate tenant.
.DESCRIPTION
Azure public cloud. Microsoft.Subscription API 2021-10-01.
Billing remains on the specified EA enrollment. Does not change the directory
of existing subscriptions or migrate resources, RBAC, or managed identities.

Prerequisites:
- Az.Accounts installed: Install-Module Az.Accounts -Scope CurrentUser
- Source context: identity authorized to create subscriptions in the EA
    enrollment account (for service principals, the appropriate EA assignment,
    such as Azure subscription creator, made by the EA administrator).
- Destination context: authenticate AS the principal specified by
    TargetOwnerObjectId, using its Object ID in the destination tenant.
    Do not use the Application/Client ID in place of the Object ID.
- Tenant policies must allow the cross-tenant operation.
- For DevTest, the enrollment account must have the corresponding offer enabled.

Cross-tenant creation: Alias with subscriptionTenantId, then acceptOwnership.
This is not the Change Directory flow for an existing subscription.
Use the same AliasName with -Resume after interruption. Do not generate a new
alias to retry: it could create a second billable subscription.
If a write fails or times out, Azure may already have accepted the operation.
No automatic rollback or cancellation is performed.

.EXAMPLE
Disable-AzContextAutosave -Scope Process | Out-Null
$source = (Connect-AzAccount -Tenant '<EA-TENANT>' -SkipContextPopulation).Context
$target = (Connect-AzAccount -Tenant '<TARGET-TENANT>' -SkipContextPopulation).Context
$p = @{
    SourceContext       = $source
    TargetContext       = $target
    BillingAccountId    = '1234567'
    EnrollmentAccountId = '7654321'
    SubscriptionName    = 'Production - separate tenant'
    AliasName           = 'prod-separate-tenant-001'
    TargetOwnerObjectId = '<PRINCIPAL-OBJECT-ID-IN-TARGET-TENANT>'
}
.\New-EASubscriptionCrossTenant.ps1 @p -WhatIf
.\New-EASubscriptionCrossTenant.ps1 @p
# Recovery after timeout/interruption:
# .\New-EASubscriptionCrossTenant.ps1 @p -Resume

.NOTES
For automation, supply contexts obtained with Connect-AzAccount
-ServicePrincipal and certificate/federated authentication, authorized in each tenant.
The script saves no secrets.
Documentation:
https://learn.microsoft.com/azure/cost-management-billing/manage/programmatically-create-subscription-enterprise-agreement
https://learn.microsoft.com/rest/api/subscription/subscription/accept-ownership?view=rest-subscription-2021-10-01
https://learn.microsoft.com/rest/api/subscription/subscription/accept-ownership-status?view=rest-subscription-2021-10-01
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [object] $SourceContext,
    [Parameter(Mandatory)] [object] $TargetContext,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9]+$')] [string] $BillingAccountId,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9]+$')] [string] $EnrollmentAccountId,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SubscriptionName,
    [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$')]
    [string] $AliasName,
    [Parameter(Mandatory)] [guid] $TargetOwnerObjectId,
    [ValidateSet('Production', 'DevTest')] [string] $Workload = 'Production',
    [ValidateRange(1, 120)] [int] $TimeoutMinutes = 20,
    [switch] $Resume
)
$ErrorActionPreference = 'Stop'
$arm = 'https://management.azure.com'
$api = '2021-10-01'
$sourceTenant = [guid]$SourceContext.Tenant.Id
$targetTenant = [guid]$TargetContext.Tenant.Id
if ($sourceTenant -eq [guid]::Empty -or $targetTenant -eq [guid]::Empty -or
    $TargetOwnerObjectId -eq [guid]::Empty -or $sourceTenant -eq $targetTenant) {
    throw 'Specify distinct tenants, valid contexts, and a nonempty owner.'
}
foreach ($ctx in @($SourceContext, $TargetContext)) {
    if ($ctx.Environment.Name -ne 'AzureCloud') { throw 'Only Azure public cloud (AzureCloud) is supported.' }
}
$billingScope = "/providers/Microsoft.Billing/billingAccounts/$BillingAccountId/enrollmentAccounts/$EnrollmentAccountId"
$aliasPath = "/providers/Microsoft.Subscription/aliases/${AliasName}?api-version=$api"
if (-not $PSCmdlet.ShouldProcess("$SubscriptionName | $billingScope | tenant $targetTenant",
    'Create/resume the EA subscription and accept ownership in the destination tenant')) { return }

function Invoke-Arm {
    param([object]$Context, [string]$Method, [string]$Path, [object]$Body,
          [int[]]$AllowedErrors = @())
    $token = Get-AzAccessToken -ResourceUrl "$arm/" -TenantId $Context.Tenant.Id `
        -DefaultProfile $Context -AsSecureString
    $request = @{
        Uri = "$arm$Path"; Method = $Method; Authentication = 'Bearer'
        Token = $token.Token; ErrorAction = 'Stop'; TimeoutSec = 60
    }
    if ($null -ne $Body) {
        $request.ContentType = 'application/json'
        $request.Body = $Body | ConvertTo-Json -Depth 10
    }
    try { Invoke-RestMethod @request }
    catch {
        $code = if ($null -ne $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($code -in $AllowedErrors) { return $null }
        throw
    }
}

# Verify authentication in both tenants BEFORE creating the subscription.
foreach ($ctx in @($SourceContext, $TargetContext)) {
    $null = Get-AzAccessToken -ResourceUrl "$arm/" -TenantId $ctx.Tenant.Id `
        -DefaultProfile $ctx -AsSecureString
}
$alias = Invoke-Arm $SourceContext GET $aliasPath -AllowedErrors @(404)
if ($null -ne $alias) {
    if (-not $Resume) { throw "Alias '$AliasName' already exists. Inspect it and use -Resume to continue." }
    $p = $alias.properties
    if ($p.billingScope -ine $billingScope -or $p.displayName -cne $SubscriptionName -or
        $p.workload -ine $Workload -or
        $p.additionalProperties.subscriptionTenantId -ine $targetTenant.ToString() -or
        $p.additionalProperties.subscriptionOwnerId -ine $TargetOwnerObjectId.ToString()) {
        throw 'Existing alias does not match the parameters (or metadata is unavailable). No changes made.'
    }
} else {
    if ($Resume) { throw 'Alias not found: -Resume does not create a new subscription.' }
    $body = @{ properties = @{
        billingScope = $billingScope; displayName = $SubscriptionName; workload = $Workload
        additionalProperties = @{
            subscriptionTenantId = $targetTenant.ToString()
            subscriptionOwnerId = $TargetOwnerObjectId.ToString()
        }
    } }
    Write-Host "Creating EA request with alias $AliasName..."
    $alias = Invoke-Arm $SourceContext PUT $aliasPath $body
}

# Do not wait for Succeeded before acceptance: wait for the assigned ID.
$deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
while ($true) {
    if ($alias.properties.provisioningState -in @('Failed', 'Canceled')) {
        throw "Creation failed: $($alias | ConvertTo-Json -Depth 10 -Compress)"
    }
    if ($alias.properties.subscriptionId) { break }
    if ([datetime]::UtcNow -ge $deadline) { throw "Creation timed out. Continue with alias $AliasName and -Resume." }
    Start-Sleep -Seconds 10
    $alias = Invoke-Arm $SourceContext GET $aliasPath -AllowedErrors @(404, 429, 500, 502, 503, 504)
}
$subscriptionId = ([guid]$alias.properties.subscriptionId).ToString()
Write-Host "SubscriptionId: $subscriptionId (retain it for subsequent checks)."
$basePath = "/providers/Microsoft.Subscription/subscriptions/$subscriptionId"
$statusPath = "${basePath}/acceptOwnershipStatus?api-version=$api"
$deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
$acceptSent = $false
while ([datetime]::UtcNow -lt $deadline) {
    $status = Invoke-Arm $TargetContext GET $statusPath -AllowedErrors @(404, 429, 500, 502, 503, 504)
    if ($null -ne $status) {
        if ($status.subscriptionTenantId -ine $targetTenant.ToString()) {
            throw 'The transfer request tenant does not match the expected tenant.'
        }
        if ($status.acceptOwnershipState -eq 'Expired' -or
            $status.provisioningState -in @('Failed', 'Canceled')) {
            throw "Transfer cannot complete: $($status | ConvertTo-Json -Compress)"
        }
        if ($status.acceptOwnershipState -eq 'Completed' -and $status.provisioningState -eq 'Succeeded') {
            [pscustomobject]@{
                SubscriptionId = $subscriptionId; SubscriptionName = $SubscriptionName
                TenantId = $targetTenant; BillingScope = $billingScope
                AliasName = $AliasName; Status = 'Succeeded'
            }
            return
        }
        if ($status.acceptOwnershipState -eq 'Pending' -and -not $acceptSent) {
            Write-Host "Accepting ownership in tenant $targetTenant..."
            $null = Invoke-Arm $TargetContext POST "${basePath}/acceptOwnership?api-version=$api" `
                @{ properties = @{ displayName = $SubscriptionName } }
            $acceptSent = $true
        }
    }
    Start-Sleep -Seconds 10
}
throw "Ownership acceptance timed out for $subscriptionId. Azure may still be processing. Use the same alias with -Resume; do not create another."
