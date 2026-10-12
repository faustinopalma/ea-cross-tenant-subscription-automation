#requires -Version 7.2
#requires -Modules Az.Accounts
<#
.SYNOPSIS
Creates an EA subscription using a home-tenant service principal and accepts it in another tenant.
.DESCRIPTION
Version 2.0. Documentation reviewed on 2026-10-09. Azure public cloud only.
Both contexts must use application-backed service principals. User accounts,
including guest users, are intentionally not supported by this implementation.

The source application must be registered in EATenantId and have the EA
SubscriptionCreator billing role on the specified enrollment account.
The target context must authenticate as TargetOwnerObjectId in TargetTenantId.
The target application may be a separate application or a consented instance
of a multitenant application. Its object ID is local to the target tenant.

Validate is the default: identity checks and GET requests only; it cannot prove
permission to create a subscription. WhatIf is offline: no token or API calls.
CreateAndAccept performs two writes. Resume reuses an existing alias; it never
creates one. Verify reads existing state without accepting ownership.
Run only one process per alias. Retain the alias after ambiguous write failures.
No resources, billing-role assignments, or cancellation operations are created.
The subscription remains billed to the supplied EA enrollment account.

This is a new-subscription cross-tenant request, not a Change Directory operation
on an existing populated subscription. There is no transactional rollback.

.NOTES
See TESTING-AND-EVIDENCE.md for authentication examples, tests and API references.
Documentation is evidence for the contracts, not an end-to-end certification.
The source Graph self-read verifies appOwnerOrganizationId. Microsoft documents
that a service principal can read its own details without application permissions.
An unavailable self-read causes the script to stop, never to skip the check.

[D1] https://learn.microsoft.com/azure/cost-management-billing/manage/create-enterprise-subscription
[D2] https://learn.microsoft.com/azure/cost-management-billing/manage/programmatically-create-subscription-enterprise-agreement
[D3] https://learn.microsoft.com/azure/cost-management-billing/manage/assign-roles-azure-service-principals
[D4] https://learn.microsoft.com/rest/api/subscription/alias/create?view=rest-subscription-2021-10-01
[D5] https://learn.microsoft.com/rest/api/subscription/alias/get?view=rest-subscription-2021-10-01
[D6] https://learn.microsoft.com/rest/api/subscription/subscription/accept-ownership?view=rest-subscription-2021-10-01
[D7] https://learn.microsoft.com/rest/api/subscription/subscription/accept-ownership-status?view=rest-subscription-2021-10-01
[D8] https://learn.microsoft.com/graph/api/serviceprincipal-get?view=graph-rest-1.0
[D9] https://learn.microsoft.com/graph/api/resources/serviceprincipal?view=graph-rest-1.0
[D10] https://learn.microsoft.com/powershell/module/az.accounts/get-azaccesstoken
[D11] https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/invoke-webrequest?view=powershell-7.4
[D12] https://learn.microsoft.com/rest/api/resources/subscriptions/get?view=rest-resources-2022-12-01
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)] [object] $SourceContext,
    [Parameter(Mandatory)] [object] $TargetContext,
    [Parameter(Mandatory)] [guid] $EATenantId,
    [Parameter(Mandatory)] [guid] $TargetTenantId,
    [Parameter(Mandatory)] [guid] $TargetOwnerObjectId,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9]+$')] [string] $BillingAccountId,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9]+$')] [string] $EnrollmentAccountId,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SubscriptionName,
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?$')]
    [string] $AliasName,
    [ValidateSet('Production', 'DevTest')] [string] $Workload = 'Production',
    [ValidateSet('Validate', 'CreateAndAccept', 'Resume', 'Verify')] [string] $Mode = 'Validate',
    [ValidateRange(1, 120)] [int] $TimeoutMinutes = 20
)
$ErrorActionPreference = 'Stop'
$arm = 'https://management.azure.com'
$graph = 'https://graph.microsoft.com'
$api = '2021-10-01'
$billingScope = "/providers/Microsoft.Billing/billingAccounts/$BillingAccountId/enrollmentAccounts/$EnrollmentAccountId"
$aliasUri = "$arm/providers/Microsoft.Subscription/aliases/${AliasName}?api-version=$api"
$deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)

function Assert-Context {
    param($Context, [guid]$ExpectedTenant, [string]$Label)
    if ([string]$Context.Environment.Name -ne 'AzureCloud') { throw "$Label must use AzureCloud." }
    if ([string]$Context.Account.Type -ne 'ServicePrincipal') {
        throw "$Label must be a service principal. User and guest contexts are not supported in v2."
    }
    if ([guid]$Context.Tenant.Id -ne $ExpectedTenant) { throw "$Label tenant does not match the expected tenant." }
    $appId = [guid]$Context.Account.Id
    if ($appId -eq [guid]::Empty) { throw "$Label has no valid application ID." }
}

function Wait-Poll {
    param($Headers)
    # Honor Retry-After (seconds or HTTP date) without waiting past the deadline.
    $seconds = 10.0
    if ($null -ne $Headers -and $Headers['Retry-After']) {
        $value = [string]@($Headers['Retry-After'])[0]
        $number = 0
        $date = [datetimeoffset]::MinValue
        if ([int]::TryParse($value, [ref]$number)) { $seconds = [math]::Max(1, $number) }
        elseif ([datetimeoffset]::TryParse($value, [ref]$date)) {
            $seconds = [math]::Max(1, ($date - [datetimeoffset]::UtcNow).TotalSeconds)
        }
    }
    if ([datetime]::UtcNow.AddSeconds($seconds) -ge $deadline) {
        throw "Polling deadline reached. Keep alias '$AliasName'; inspect or use -Mode Resume."
    }
    Start-Sleep -Seconds $seconds
}

function Invoke-Api {
    param($Context, [ValidateSet('GET', 'PUT', 'POST')][string]$Method,
          [string]$Uri, [hashtable]$Body, [int[]]$AllowedStatus = @())
    $endpoint = [uri]$Uri
    if ($endpoint.Scheme -ne 'https' -or $endpoint.UserInfo -or $endpoint.Port -ne 443 -or
        $endpoint.Host -notin @('management.azure.com', 'graph.microsoft.com')) {
        throw 'Unexpected API endpoint.'
    }
    $resource = if ($endpoint.Host -eq 'graph.microsoft.com') { "$graph/" } else { "$arm/" }
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        if ([datetime]::UtcNow -ge $deadline) { throw "Deadline reached for alias '$AliasName'." }
        # [D10] Always request a token for this context's tenant and API audience.
        $access = Get-AzAccessToken -ResourceUrl $resource -TenantId $Context.Tenant.Id `
            -DefaultProfile $Context -AsSecureString -ErrorAction Stop
        if ($access.Token -isnot [securestring]) { throw 'Az.Accounts must return SecureString access tokens.' }
        $request = @{
            Uri = $Uri; Method = $Method; Authentication = 'Bearer'; Token = $access.Token
            SkipHttpErrorCheck = $true; MaximumRedirection = 0; TimeoutSec = 60
            ErrorAction = 'Stop'; Verbose = $false; Debug = $false
        }
        if ($null -ne $Body) {
            $request.ContentType = 'application/json'
            $request.Body = ConvertTo-Json -InputObject $Body -Depth 10 -Compress
        }
        # [D11] Inspect HTTP status explicitly, including 202 and error responses.
        try { $response = Invoke-WebRequest @request }
        catch {
            # Writes are never retried automatically after an ambiguous transport error.
            throw "Transport failure for $Method $Uri. Keep alias '$AliasName'; inspect Azure state before retrying."
        }
        $code = [int]$response.StatusCode
        $data = @{}
        if (-not [string]::IsNullOrWhiteSpace([string]$response.Content)) {
            try { $data = ConvertFrom-Json -InputObject $response.Content -AsHashtable -ErrorAction Stop }
            catch { if ($code -ge 200 -and $code -lt 300) { throw 'Successful API response contains invalid JSON.' } }
        }
        if (($code -ge 200 -and $code -lt 300) -or $code -in $AllowedStatus) {
            return @{ Status = $code; Data = $data; Headers = $response.Headers }
        }
        # Only GET calls are automatically retried. Authentication failures are fatal.
        if ($Method -eq 'GET' -and $code -in @(429, 500, 502, 503, 504) -and $attempt -lt 4) {
            Wait-Poll $response.Headers
            continue
        }
        $errorCode = [string]$data.error.code
        if (-not $errorCode) { $errorCode = [string]$data.code }
        $requestId = [string]@($response.Headers['x-ms-request-id'])[0]
        throw "HTTP $code ($errorCode), $Method $Uri, request-id=$requestId. Keep alias '$AliasName' for recovery."
    }
}

function Get-SelfPrincipal {
    param($Context)
    # [D8] Query only the authenticated application's own service principal.
    $clientId = ([guid]$Context.Account.Id).ToString()
    $uri = "$graph/v1.0/servicePrincipals(appId='$clientId')?`$select=id,appId,appOwnerOrganizationId,servicePrincipalType"
    $r = Invoke-Api -Context $Context -Method GET -Uri $uri
    if ($r.Data.appId -ine $clientId -or $r.Data.servicePrincipalType -ne 'Application' -or -not $r.Data.id) {
        throw 'Graph did not return the expected application-backed service principal.'
    }
    return $r.Data
}

function Normalize-BillingScope {
    param([string]$Scope)
    # [D5] Responses may omit the Microsoft.Billing provider prefix.
    return (($Scope.TrimEnd('/') -replace '(?i)^/providers/Microsoft\.Billing', '').ToLowerInvariant())
}

function Assert-Alias {
    param($Alias)
    # [D5] Response properties are FLAT: there is no additionalProperties here.
    $p = $Alias.properties
    if ($null -eq $p -or
        (Normalize-BillingScope $p.billingScope) -ne (Normalize-BillingScope $billingScope) -or
        $p.displayName -cne $SubscriptionName -or $p.workload -ine $Workload -or
        $p.subscriptionOwnerId -ine $TargetOwnerObjectId.ToString()) {
        throw 'Alias does not match the requested billing scope, name, workload or owner. No further writes allowed.'
    }
    if ($p.provisioningState -in @('Failed', 'Canceled') -or $p.acceptOwnershipState -eq 'Expired') {
        throw 'Alias is failed, canceled or expired. Inspect it in Azure before taking further action.'
    }
}

if ($EATenantId -eq [guid]::Empty -or $TargetTenantId -eq [guid]::Empty -or
    $TargetOwnerObjectId -eq [guid]::Empty -or $EATenantId -eq $TargetTenantId) {
    throw 'Provide non-empty IDs and distinct source and target tenants.'
}
if ([string]::IsNullOrWhiteSpace($SubscriptionName)) { throw 'SubscriptionName must not be blank.' }
Assert-Context $SourceContext $EATenantId 'SourceContext'
Assert-Context $TargetContext $TargetTenantId 'TargetContext'
if ($WhatIfPreference) {
    $null = $PSCmdlet.ShouldProcess("$billingScope -> $TargetTenantId; alias=$AliasName", "Mode $Mode (offline plan)")
    return
}

# [D1,D2,D9] A tenant selection alone does not prove that an identity is native.
# Check the application registration's home tenant before any subscription write.
$sourcePrincipal = Get-SelfPrincipal $SourceContext
if ($sourcePrincipal.appOwnerOrganizationId -ine $EATenantId.ToString()) {
    throw 'Source application is not registered in EATenantId. Creation must use its EA home tenant.'
}
$targetPrincipal = Get-SelfPrincipal $TargetContext
if ($targetPrincipal.id -ine $TargetOwnerObjectId.ToString()) {
    throw 'TargetContext is not the requested TargetOwnerObjectId in TargetTenantId.'
}
# Acquire ARM tokens for both contexts before attempting creation.
foreach ($ctx in @($SourceContext, $TargetContext)) {
    $null = Get-AzAccessToken -ResourceUrl "$arm/" -TenantId $ctx.Tenant.Id `
        -DefaultProfile $ctx -AsSecureString -ErrorAction Stop
}

# [D5] A 403 is not treated as an absent alias. Resume never issues PUT.
$existing = Invoke-Api -Context $SourceContext -Method GET -Uri $aliasUri -AllowedStatus @(404)
$aliasExists = $existing.Status -eq 200
if ($aliasExists) { Assert-Alias $existing.Data }
if ($Mode -eq 'Validate') {
    [pscustomobject]@{
        Result = 'ReadOnlyChecksPassed'; AliasExists = $aliasExists; AliasName = $AliasName
        SourceHomeTenantId = $sourcePrincipal.appOwnerOrganizationId; TargetTenantId = $TargetTenantId
        TargetOwnerObjectId = $targetPrincipal.id; BillingScope = $billingScope
        CreationPermissionVerified = $false
        Note = 'EA billing role, policies, quotas and end-to-end creation still require verification.'
    }
    return
}
if ($Mode -eq 'CreateAndAccept') {
    if ($aliasExists) { throw 'Alias already exists. Inspect it and use -Mode Resume or -Mode Verify.' }
    $payload = @{ properties = @{
        billingScope = $billingScope; displayName = $SubscriptionName; workload = $Workload
        additionalProperties = @{
            subscriptionTenantId = $TargetTenantId.ToString()
            subscriptionOwnerId = $TargetOwnerObjectId.ToString()
        }
    } }
    if (-not $PSCmdlet.ShouldProcess("EA alias '$AliasName'", 'Create a subscription request')) { return }
    # [D2,D4] Creation uses the SOURCE home-tenant token, never the target token.
    $null = Invoke-Api -Context $SourceContext -Method PUT -Uri $aliasUri -Body $payload
} elseif (-not $aliasExists) {
    throw 'Alias not found. Resume and Verify never create a subscription.'
}

# [D5] Wait for a readable, matching alias and subscription ID, not for Succeeded.
while ($true) {
    $r = Invoke-Api -Context $SourceContext -Method GET -Uri $aliasUri -AllowedStatus @(404)
    if ($r.Status -eq 200) {
        Assert-Alias $r.Data
        if ($r.Data.properties.subscriptionId) {
            $subscriptionId = ([guid]$r.Data.properties.subscriptionId).ToString()
            break
        }
    }
    Wait-Poll $r.Headers
}
Write-Information "Subscription ID: $subscriptionId; alias: $AliasName" -InformationAction Continue
$statusUri = "$arm/providers/Microsoft.Subscription/subscriptions/$subscriptionId/acceptOwnershipStatus?api-version=$api"
$acceptUri = "$arm/providers/Microsoft.Subscription/subscriptions/$subscriptionId/acceptOwnership?api-version=$api"
$acceptSent = $false
while ($true) {
    # [D7] Status is queried with the TARGET tenant's identity.
    $r = Invoke-Api -Context $TargetContext -Method GET -Uri $statusUri -AllowedStatus @(404)
    if ($r.Status -eq 200) {
        $s = $r.Data
        if ($s.subscriptionId -ine $subscriptionId -or $s.subscriptionTenantId -ine $TargetTenantId.ToString()) {
            throw 'Ownership status does not match the expected subscription and target tenant.'
        }
        if ($s.acceptOwnershipState -eq 'Expired' -or $s.provisioningState -in @('Failed', 'Canceled')) {
            throw 'Ownership request is expired, failed or canceled.'
        }
        if ($s.acceptOwnershipState -eq 'Completed' -and $s.provisioningState -eq 'Succeeded') { break }
        if ($Mode -eq 'Verify') {
            [pscustomobject]@{ Result = 'NotCompleted'; SubscriptionId = $subscriptionId
                OwnershipState = $s.acceptOwnershipState; ProvisioningState = $s.provisioningState }
            return
        }
        if ($s.acceptOwnershipState -eq 'Pending' -and -not $acceptSent) {
            if (-not $PSCmdlet.ShouldProcess($subscriptionId, "Accept ownership in tenant $TargetTenantId")) { return }
            # [D6] HTTP 202 means accepted for processing, not completed.
            $accepted = Invoke-Api -Context $TargetContext -Method POST -Uri $acceptUri `
                -Body @{ properties = @{ displayName = $SubscriptionName } }
            $acceptSent = $true
            Wait-Poll $accepted.Headers
            continue
        }
    }
    Wait-Poll $r.Headers
}

# [D12] Independently verify the actual subscription's tenant and enabled state.
# A new owner's ARM read may need time to propagate (403/404 only at this stage).
$subscriptionUri = "$arm/subscriptions/${subscriptionId}?api-version=2022-12-01"
while ($true) {
    $r = Invoke-Api -Context $TargetContext -Method GET -Uri $subscriptionUri -AllowedStatus @(403, 404)
    if ($r.Status -eq 200) {
        if ($r.Data.subscriptionId -ine $subscriptionId -or $r.Data.tenantId -ine $TargetTenantId.ToString()) {
            throw 'Final subscription identity or tenant verification failed.'
        }
        if ($r.Data.state -ne 'Enabled') { throw "Subscription exists but its state is '$($r.Data.state)' instead of Enabled." }
        break
    }
    Wait-Poll $r.Headers
}
[pscustomobject]@{
    Result = 'Succeeded'; SubscriptionId = $subscriptionId; AliasName = $AliasName
    TenantId = $TargetTenantId; TargetOwnerObjectId = $TargetOwnerObjectId
    RequestedBillingScope = $billingScope; SubscriptionState = $r.Data.state
    BillingPortalVerificationRequired = $true
}
