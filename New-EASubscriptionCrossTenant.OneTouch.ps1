#requires -Version 7.2
#requires -Modules @{ ModuleName = 'Az.Accounts'; ModuleVersion = '5.3.1' }
<#
.SYNOPSIS
Creates and accepts an EA cross-tenant subscription with unattended certificate authentication.
.DESCRIPTION
Windows launcher for New-EASubscriptionCrossTenant.v2.ps1. Both application
certificates must be registered in Entra and available, including private keys,
in Cert:\CurrentUser\My for the execution identity. No secrets or user prompts
are needed. Configure IDs and thumbprints once; provide a stable alias per request.
CreateAndAccept is the default. Resume never creates a new request. Run only
one process per alias and inspect uncertain failures before resuming.
WhatIf performs no login, certificate lookup or Azure request. Validate performs
read-only Azure checks; it does not prove EA creation permission.
.NOTES
Requires an EA SubscriptionCreator source principal and the specified destination
principal as new owner. Billing remains on the configured EA enrollment account.
Run in a dedicated pwsh process: authentication changes process-local contexts.
See TESTING-AND-EVIDENCE.md for setup, permissions and live acceptance checks.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)] [guid] $EATenantId,
    [Parameter(Mandatory)] [guid] $TargetTenantId,
    [Parameter(Mandatory)] [guid] $SourceApplicationId,
    [Parameter(Mandatory)] [guid] $TargetApplicationId,
    [Parameter(Mandatory)] [guid] $TargetOwnerObjectId,
    [Parameter(Mandatory)] [ValidatePattern('^[A-Fa-f0-9]{40}$')] [string] $SourceCertificateThumbprint,
    [Parameter(Mandatory)] [ValidatePattern('^[A-Fa-f0-9]{40}$')] [string] $TargetCertificateThumbprint,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9]+$')] [string] $BillingAccountId,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9]+$')] [string] $EnrollmentAccountId,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SubscriptionName,
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?$')] [string] $AliasName,
    [ValidateSet('Production', 'DevTest')] [string] $Workload = 'Production',
    [ValidateSet('CreateAndAccept', 'Resume', 'Validate', 'Verify')] [string] $Mode = 'CreateAndAccept',
    [ValidateRange(1, 120)] [int] $TimeoutMinutes = 20
)
$ErrorActionPreference = 'Stop'
if (@($EATenantId, $TargetTenantId, $SourceApplicationId, $TargetApplicationId, $TargetOwnerObjectId) -contains [guid]::Empty -or
    $EATenantId -eq $TargetTenantId -or [string]::IsNullOrWhiteSpace($SubscriptionName)) {
    throw 'Provide non-empty IDs, distinct tenants and a non-blank subscription name.'
}
if (-not $PSCmdlet.ShouldProcess("EA alias '$AliasName' -> tenant $TargetTenantId", "Run $Mode")) { return }
if (-not $IsWindows) { throw 'This launcher requires the Windows CurrentUser certificate store.' }
foreach ($thumbprint in @($SourceCertificateThumbprint, $TargetCertificateThumbprint)) {
    $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$thumbprint" -ErrorAction Stop
    if (-not $certificate.HasPrivateKey -or $certificate.NotBefore.ToUniversalTime() -gt [datetime]::UtcNow -or
        $certificate.NotAfter.ToUniversalTime() -le [datetime]::UtcNow) {
        throw "Certificate '$thumbprint' must have a private key and be currently valid."
    }
}
Disable-AzContextAutosave -Scope Process | Out-Null
$source = (Connect-AzAccount -ServicePrincipal -ApplicationId $SourceApplicationId -Tenant $EATenantId `
    -CertificateThumbprint $SourceCertificateThumbprint -SkipContextPopulation -Scope Process -ErrorAction Stop).Context
$target = (Connect-AzAccount -ServicePrincipal -ApplicationId $TargetApplicationId -Tenant $TargetTenantId `
    -CertificateThumbprint $TargetCertificateThumbprint -SkipContextPopulation -Scope Process -ErrorAction Stop).Context
$request = @{
    SourceContext = $source; TargetContext = $target
    EATenantId = $EATenantId; TargetTenantId = $TargetTenantId; TargetOwnerObjectId = $TargetOwnerObjectId
    BillingAccountId = $BillingAccountId; EnrollmentAccountId = $EnrollmentAccountId
    SubscriptionName = $SubscriptionName; AliasName = $AliasName; Workload = $Workload
    Mode = $Mode; TimeoutMinutes = $TimeoutMinutes
}
try {
    & (Join-Path $PSScriptRoot 'New-EASubscriptionCrossTenant.v2.ps1') @request -Confirm:$false
} catch {
    Write-Warning "Request '$AliasName' did not complete. Retain this alias and all inputs. Inspect with -Mode Verify; use -Mode Resume only for an existing request. Do not generate a replacement alias."
    throw
}