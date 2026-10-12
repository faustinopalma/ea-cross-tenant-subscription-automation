#requires -Version 7.2
#requires -Modules Az.Accounts, @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# These tests replace token acquisition and ALL HTTP calls. They never contact Azure.
# They validate local control flow, not the real service's authorization or behavior.

BeforeAll {
    Import-Module Az.Accounts
    $script:UnderTest = Join-Path $PSScriptRoot 'New-EASubscriptionCrossTenant.v2.ps1'
    function New-FakeResponse {
        param([int]$Code, [hashtable]$Data = @{}, [hashtable]$Headers = @{})
        [pscustomobject]@{ StatusCode = $Code; Content = ($Data | ConvertTo-Json -Depth 15); Headers = $Headers }
    }
    function New-FakeAlias {
        $scope = '/billingAccounts/1234567/enrollmentAccounts/7654321'
        $owner = $script:P.TargetOwnerObjectId
        if ($script:Scenario -eq 'WrongAlias') { $owner = '99999999-9999-4999-8999-999999999999' }
        # This fixture follows the GET response contract, not the PUT request body.
        return @{ properties = @{
            billingScope = $scope; displayName = $script:P.SubscriptionName; workload = 'Production'
            subscriptionOwnerId = $owner; subscriptionId = $script:SubId
            provisioningState = 'Accepted'; acceptOwnershipState = 'Pending'
        } }
    }
}

Describe 'EA cross-tenant subscription v2' {
    BeforeEach {
        $script:SourceTenant = '11111111-1111-4111-8111-111111111111'
        $script:TargetTenant = '22222222-2222-4222-8222-222222222222'
        $script:SourceApp = '33333333-3333-4333-8333-333333333333'
        $script:TargetApp = '44444444-4444-4444-8444-444444444444'
        $script:SubId = '55555555-5555-4555-8555-555555555555'
        $script:P = @{
            SourceContext = [pscustomobject]@{
                Environment = @{ Name = 'AzureCloud' }; Tenant = @{ Id = $script:SourceTenant }
                Account = @{ Type = 'ServicePrincipal'; Id = $script:SourceApp }
            }
            TargetContext = [pscustomobject]@{
                Environment = @{ Name = 'AzureCloud' }; Tenant = @{ Id = $script:TargetTenant }
                Account = @{ Type = 'ServicePrincipal'; Id = $script:TargetApp }
            }
            EATenantId = $script:SourceTenant; TargetTenantId = $script:TargetTenant
            TargetOwnerObjectId = '66666666-6666-4666-8666-666666666666'
            BillingAccountId = '1234567'; EnrollmentAccountId = '7654321'
            SubscriptionName = 'EA test'; AliasName = 'ea-test-001'
        }
        $script:Scenario = 'Normal'
        $script:Exists = $false
        $script:Accepted = $false
        $script:StatusReads = 0
        $script:AliasReads = 0
        $script:FinalReads = 0
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        Mock Start-Sleep {}
        Mock Get-AzAccessToken {
            param($ResourceUrl, $TenantId)
            # This string is synthetic test data, never a real bearer token.
            [pscustomobject]@{ Token = (ConvertTo-SecureString "$TenantId|$ResourceUrl" -AsPlainText -Force) }
        } -RemoveParameterType DefaultProfile
        Mock Invoke-WebRequest {
            param($Uri, $Method, $Body, $Token)
            $u = [string]$Uri
            $script:Calls.Add(@{ Uri = $u; Method = [string]$Method; Body = $Body
                MockToken = (ConvertFrom-SecureString $Token -AsPlainText) })
            if ($u -like 'https://graph.microsoft.com/*') {
                $isSource = $u.Contains($script:SourceApp)
                $principalHomeTenant = if ($isSource) { $script:SourceTenant } else { $script:TargetTenant }
                $id = if ($isSource) { '77777777-7777-4777-8777-777777777777' } else { $script:P.TargetOwnerObjectId }
                if ($isSource -and $script:Scenario -eq 'ForeignHome') { $principalHomeTenant = $script:TargetTenant }
                if (-not $isSource -and $script:Scenario -eq 'WrongTargetIdentity') {
                    $id = '99999999-9999-4999-8999-999999999999'
                }
                if ($script:Scenario -eq 'GraphForbidden') { return New-FakeResponse 403 @{ error = @{ code = 'Authorization_RequestDenied' } } }
                $app = if ($isSource) { $script:SourceApp } else { $script:TargetApp }
                return New-FakeResponse 200 @{ id = $id; appId = $app; appOwnerOrganizationId = $principalHomeTenant; servicePrincipalType = 'Application' }
            }
            if ($u -like '*/aliases/*') {
                if ($Method -eq 'PUT') {
                    if ($script:Scenario -eq 'PutTransportFailure') { throw 'Simulated connection loss' }
                    $script:Exists = $true
                    return New-FakeResponse 201 (New-FakeAlias)
                }
                $script:AliasReads++
                if ($script:Scenario -eq 'AliasForbidden') { return New-FakeResponse 403 @{ error = @{ code = 'AuthorizationFailed' } } }
                if ($script:Scenario -eq 'Throttled' -and $script:AliasReads -eq 1) {
                    return New-FakeResponse 429 @{} @{ 'Retry-After' = '1' }
                }
                if ($script:Scenario -eq 'RetryAfterDeadline') {
                    return New-FakeResponse 429 @{} @{ 'Retry-After' = '9999' }
                }
                if (-not $script:Exists) { return New-FakeResponse 404 @{} }
                return New-FakeResponse 200 (New-FakeAlias)
            }
            if ($u -like '*/acceptOwnershipStatus?*') {
                $script:StatusReads++
                $tenant = if ($script:Scenario -eq 'WrongStatusTenant') { $script:SourceTenant } else { $script:TargetTenant }
                $ownership = if ($script:Accepted) { 'Completed' } else { 'Pending' }
                $provisioning = if ($script:Accepted) { 'Succeeded' } else { 'Accepted' }
                if ($script:Scenario -eq 'Expired') { $ownership = 'Expired' }
                return New-FakeResponse 200 @{ subscriptionId = $script:SubId; subscriptionTenantId = $tenant
                    acceptOwnershipState = $ownership; provisioningState = $provisioning }
            }
            if ($u -like '*/acceptOwnership?*') {
                if ($script:Scenario -eq 'PostTransportFailure') { throw 'Simulated connection loss' }
                $script:Accepted = $true
                return New-FakeResponse 202 @{} @{ 'Retry-After' = '1' }
            }
            if ($u -like 'https://management.azure.com/subscriptions/*') {
                $script:FinalReads++
                if ($script:Scenario -eq 'Propagation' -and $script:FinalReads -eq 1) { return New-FakeResponse 403 @{} }
                $tenant = if ($script:Scenario -eq 'WrongFinalTenant') { $script:SourceTenant } else { $script:TargetTenant }
                return New-FakeResponse 200 @{ subscriptionId = $script:SubId; tenantId = $tenant; state = 'Enabled' }
            }
            throw "Unmocked request: $Method $u"
        }
    }

    It 'parses without PowerShell syntax errors' {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:UnderTest, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
    It 'makes no token or HTTP calls in WhatIf mode' {
        & $script:UnderTest @P -Mode CreateAndAccept -WhatIf
        Should -Invoke Get-AzAccessToken -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }
    It 'defaults to read-only validation and does not claim creation permission' {
        $result = & $script:UnderTest @P
        $result.Result | Should -Be 'ReadOnlyChecksPassed'
        $result.CreationPermissionVerified | Should -BeFalse
        @($script:Calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }
    It 'rejects user contexts including guests before any API call' {
        $P.SourceContext.Account.Type = 'User'
        { & $script:UnderTest @P -Mode CreateAndAccept } | Should -Throw '*guest*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }
    It 'rejects an unexpected source tenant before any API call' {
        $P.SourceContext.Tenant.Id = $script:TargetTenant
        { & $script:UnderTest @P } | Should -Throw '*tenant does not match*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }
    It 'rejects an application registered outside the source tenant' {
        $script:Scenario = 'ForeignHome'
        { & $script:UnderTest @P -Mode CreateAndAccept } | Should -Throw '*not registered*'
        @($script:Calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }
    It 'rejects the wrong target owner before creation' {
        $script:Scenario = 'WrongTargetIdentity'
        { & $script:UnderTest @P -Mode CreateAndAccept } | Should -Throw '*TargetOwnerObjectId*'
        @($script:Calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }
    It 'fails closed when the Graph home-tenant check is unavailable' {
        $script:Scenario = 'GraphForbidden'
        { & $script:UnderTest @P -Mode CreateAndAccept } | Should -Throw '*HTTP 403*'
        @($script:Calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }
    It 'never treats alias 403 as not found' {
        $script:Scenario = 'AliasForbidden'
        { & $script:UnderTest @P -Mode CreateAndAccept } | Should -Throw '*HTTP 403*'
        @($script:Calls | Where-Object Method -eq 'PUT').Count | Should -Be 0
    }
    It 'uses source tokens for creation and target tokens for acceptance and final verification' {
        $result = & $script:UnderTest @P -Mode CreateAndAccept -Confirm:$false
        $result.Result | Should -Be 'Succeeded'
        $put = @($script:Calls | Where-Object Method -eq 'PUT')
        $post = @($script:Calls | Where-Object Method -eq 'POST')
        $put.Count | Should -Be 1
        $post.Count | Should -Be 1
        $put[0].MockToken | Should -Be "$script:SourceTenant|https://management.azure.com/"
        $post[0].MockToken | Should -Be "$script:TargetTenant|https://management.azure.com/"
        $payload = $put[0].Body | ConvertFrom-Json
        $payload.properties.additionalProperties.subscriptionTenantId | Should -Be $script:TargetTenant
        $payload.properties.additionalProperties.subscriptionOwnerId | Should -Be $P.TargetOwnerObjectId
        $script:StatusReads | Should -BeGreaterThan 1
        $script:FinalReads | Should -Be 1
    }
    It 'resumes the documented flat alias response without another PUT' {
        $script:Exists = $true
        $result = & $script:UnderTest @P -Mode Resume -Confirm:$false
        $result.Result | Should -Be 'Succeeded'
        @($script:Calls | Where-Object Method -eq 'PUT').Count | Should -Be 0
    }
    It 'refuses to create a second subscription for an existing alias' {
        $script:Exists = $true
        { & $script:UnderTest @P -Mode CreateAndAccept } | Should -Throw '*already exists*'
        @($script:Calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }
    It 'does not create an alias while resuming a missing request' {
        { & $script:UnderTest @P -Mode Resume } | Should -Throw '*Alias not found*'
        @($script:Calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }
    It 'rejects a mismatching existing owner' {
        $script:Exists = $true; $script:Scenario = 'WrongAlias'
        { & $script:UnderTest @P -Mode Resume } | Should -Throw '*Alias does not match*'
        @($script:Calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }
    It 'rejects a different target tenant before accepting ownership' {
        $script:Exists = $true; $script:Scenario = 'WrongStatusTenant'
        { & $script:UnderTest @P -Mode Resume } | Should -Throw '*Ownership status does not match*'
        @($script:Calls | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
    It 'does not accept an expired request' {
        $script:Exists = $true; $script:Scenario = 'Expired'
        { & $script:UnderTest @P -Mode Resume } | Should -Throw '*expired*'
        @($script:Calls | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
    It 'verifies a pending request without modifying it' {
        $script:Exists = $true
        $result = & $script:UnderTest @P -Mode Verify
        $result.Result | Should -Be 'NotCompleted'
        @($script:Calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }
    It 'does not accept ownership twice after completion' {
        $script:Exists = $true; $script:Accepted = $true
        $result = & $script:UnderTest @P -Mode Resume
        $result.Result | Should -Be 'Succeeded'
        @($script:Calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }
    It 'does not retry an ambiguous PUT transport failure' {
        $script:Scenario = 'PutTransportFailure'
        { & $script:UnderTest @P -Mode CreateAndAccept -Confirm:$false } | Should -Throw '*Transport failure*'
        @($script:Calls | Where-Object Method -eq 'PUT').Count | Should -Be 1
        @($script:Calls | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
    It 'does not retry an ambiguous POST transport failure' {
        $script:Exists = $true; $script:Scenario = 'PostTransportFailure'
        { & $script:UnderTest @P -Mode Resume -Confirm:$false } | Should -Throw '*Transport failure*'
        @($script:Calls | Where-Object Method -eq 'POST').Count | Should -Be 1
    }
    It 'retries a throttled GET and honors Retry-After' {
        $script:Scenario = 'Throttled'
        $result = & $script:UnderTest @P
        $result.Result | Should -Be 'ReadOnlyChecksPassed'
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 1 }
    }
    It 'waits for final subscription authorization propagation' {
        $script:Exists = $true; $script:Accepted = $true; $script:Scenario = 'Propagation'
        $result = & $script:UnderTest @P -Mode Verify
        $result.Result | Should -Be 'Succeeded'
        $script:FinalReads | Should -Be 2
    }
    It 'stops when Retry-After would exceed the polling deadline' {
        $script:Scenario = 'RetryAfterDeadline'
        { & $script:UnderTest @P -TimeoutMinutes 1 } | Should -Throw '*Polling deadline*'
        Should -Invoke Start-Sleep -Times 0 -Exactly
        @($script:Calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }
    It 'does not report success for a subscription in the wrong actual tenant' {
        $script:Exists = $true; $script:Accepted = $true; $script:Scenario = 'WrongFinalTenant'
        { & $script:UnderTest @P -Mode Verify } | Should -Throw '*Final subscription identity or tenant*'
    }
}

Describe 'EA cross-tenant one-touch launcher' {
    BeforeAll {
        $script:LauncherFixtureRoot = Join-Path $TestDrive 'launcher'
        $null = New-Item -ItemType Directory -Path $script:LauncherFixtureRoot
        $script:LauncherUnderTest = Join-Path $script:LauncherFixtureRoot 'New-EASubscriptionCrossTenant.OneTouch.ps1'
        Copy-Item (Join-Path $PSScriptRoot 'New-EASubscriptionCrossTenant.OneTouch.ps1') $script:LauncherUnderTest
        $fixtureCore = @'
[CmdletBinding(SupportsShouldProcess)]
param($SourceContext, $TargetContext, $EATenantId, $TargetTenantId,
    $TargetOwnerObjectId, $BillingAccountId, $EnrollmentAccountId,
    $SubscriptionName, $AliasName, $Workload, $Mode, $TimeoutMinutes)
if ($AliasName -eq 'fixture-failure') { throw 'Synthetic core failure' }
[pscustomobject]@{ Result = 'FixtureInvoked'; Bound = $PSBoundParameters }
'@
        Set-Content -LiteralPath (Join-Path $script:LauncherFixtureRoot 'New-EASubscriptionCrossTenant.v2.ps1') -Value $fixtureCore
    }
    BeforeEach {
        $script:LauncherParameters = @{
            EATenantId = '11111111-1111-4111-8111-111111111111'
            TargetTenantId = '22222222-2222-4222-8222-222222222222'
            SourceApplicationId = '33333333-3333-4333-8333-333333333333'
            TargetApplicationId = '44444444-4444-4444-8444-444444444444'
            TargetOwnerObjectId = '66666666-6666-4666-8666-666666666666'
            SourceCertificateThumbprint = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
            TargetCertificateThumbprint = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
            BillingAccountId = '1234567'; EnrollmentAccountId = '7654321'
            SubscriptionName = 'EA launcher test'; AliasName = 'ea-launcher-001'
        }
        $script:LauncherCertificateCase = 'Valid'
        $script:LauncherTargetLoginFails = $false
        Mock Get-Item {
            param($LiteralPath)
            if ($script:LauncherCertificateCase -eq 'MissingTarget' -and $LiteralPath.EndsWith('B' * 40)) {
                throw 'Synthetic missing destination certificate'
            }
            [pscustomobject]@{
                HasPrivateKey = $script:LauncherCertificateCase -ne 'NoPrivateKey'
                NotBefore = if ($script:LauncherCertificateCase -eq 'Future') { [datetime]::UtcNow.AddDays(1) } else { [datetime]::UtcNow.AddDays(-1) }
                NotAfter = if ($script:LauncherCertificateCase -eq 'Expired') { [datetime]::UtcNow.AddDays(-1) } else { [datetime]::UtcNow.AddDays(1) }
            }
        } -ParameterFilter { $LiteralPath -like 'Cert:\CurrentUser\My\*' }
        Mock Disable-AzContextAutosave {}
        Mock Connect-AzAccount {
            param($ApplicationId, $Tenant)
            if ($script:LauncherTargetLoginFails -and $Tenant -eq $script:LauncherParameters.TargetTenantId) {
                throw 'Synthetic destination authentication failure'
            }
            [pscustomobject]@{ Context = [pscustomobject]@{
                Environment = @{ Name = 'AzureCloud' }; Tenant = @{ Id = $Tenant }
                Account = @{ Type = 'ServicePrincipal'; Id = $ApplicationId }
            } }
        }
        Mock Get-AzAccessToken { throw 'Unmocked token acquisition' }
        Mock Invoke-WebRequest { throw 'Unmocked HTTP call' }
    }

    It 'makes no certificate, login or HTTP calls for WhatIf' {
        & $script:LauncherUnderTest @LauncherParameters -WhatIf
        Should -Invoke Get-Item -Times 0 -Exactly -ParameterFilter { $LiteralPath -like 'Cert:\*' }
        Should -Invoke Connect-AzAccount -Times 0 -Exactly
        Should -Invoke Disable-AzContextAutosave -Times 0 -Exactly
        Should -Invoke Get-AzAccessToken -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }
    It 'authenticates both principals and defaults to CreateAndAccept without prompting' {
        $result = & $script:LauncherUnderTest @LauncherParameters -Confirm:$false
        $result.Result | Should -Be 'FixtureInvoked'
        $result.Bound.Mode | Should -Be 'CreateAndAccept'
        $result.Bound.Confirm | Should -BeFalse
        $result.Bound.SourceContext.Tenant.Id | Should -Be $LauncherParameters.EATenantId
        $result.Bound.TargetContext.Tenant.Id | Should -Be $LauncherParameters.TargetTenantId
        $result.Bound.SourceContext.Account.Id | Should -Be $LauncherParameters.SourceApplicationId
        $result.Bound.TargetContext.Account.Id | Should -Be $LauncherParameters.TargetApplicationId
        $result.Bound.TargetOwnerObjectId.ToString() | Should -Be $LauncherParameters.TargetOwnerObjectId
        Should -Invoke Disable-AzContextAutosave -Times 1 -Exactly -ParameterFilter { $Scope -eq 'Process' }
        Should -Invoke Connect-AzAccount -Times 1 -Exactly -ParameterFilter {
            $ServicePrincipal -and $SkipContextPopulation -and $Scope -eq 'Process' -and
            $Tenant -eq $LauncherParameters.EATenantId -and $CertificateThumbprint -eq $LauncherParameters.SourceCertificateThumbprint
        }
        Should -Invoke Connect-AzAccount -Times 1 -Exactly -ParameterFilter {
            $ServicePrincipal -and $SkipContextPopulation -and $Scope -eq 'Process' -and
            $Tenant -eq $LauncherParameters.TargetTenantId -and $CertificateThumbprint -eq $LauncherParameters.TargetCertificateThumbprint
        }
    }
    It 'forwards <RequestedMode> with the same alias and request inputs' -ForEach @(
        @{ RequestedMode = 'Resume' }, @{ RequestedMode = 'Verify' }, @{ RequestedMode = 'Validate' }
    ) {
        $result = & $script:LauncherUnderTest @LauncherParameters -Mode $RequestedMode -Workload DevTest -TimeoutMinutes 7 -Confirm:$false
        $result.Bound.Mode | Should -Be $RequestedMode
        $result.Bound.AliasName | Should -Be $LauncherParameters.AliasName
        $result.Bound.SubscriptionName | Should -Be $LauncherParameters.SubscriptionName
        $result.Bound.BillingAccountId | Should -Be $LauncherParameters.BillingAccountId
        $result.Bound.EnrollmentAccountId | Should -Be $LauncherParameters.EnrollmentAccountId
        $result.Bound.Workload | Should -Be 'DevTest'
        $result.Bound.TimeoutMinutes | Should -Be 7
    }
    It 'checks the destination certificate before authenticating either principal' {
        $script:LauncherCertificateCase = 'MissingTarget'
        { & $script:LauncherUnderTest @LauncherParameters -Confirm:$false } | Should -Throw '*missing destination certificate*'
        Should -Invoke Connect-AzAccount -Times 0 -Exactly
    }
    It 'rejects <CertificateCase> certificates before login' -ForEach @(
        @{ CertificateCase = 'NoPrivateKey' }, @{ CertificateCase = 'Expired' }, @{ CertificateCase = 'Future' }
    ) {
        $script:LauncherCertificateCase = $CertificateCase
        { & $script:LauncherUnderTest @LauncherParameters -Confirm:$false } | Should -Throw '*private key and be currently valid*'
        Should -Invoke Connect-AzAccount -Times 0 -Exactly
    }
    It 'does not invoke the core if destination login fails' {
        $script:LauncherTargetLoginFails = $true
        { & $script:LauncherUnderTest @LauncherParameters -Confirm:$false } | Should -Throw '*destination authentication failure*'
        Should -Invoke Connect-AzAccount -Times 2 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }
    It 'rejects identical tenants before login' {
        $LauncherParameters.TargetTenantId = $LauncherParameters.EATenantId
        { & $script:LauncherUnderTest @LauncherParameters -Confirm:$false } | Should -Throw '*distinct tenants*'
        Should -Invoke Connect-AzAccount -Times 0 -Exactly
    }
    It 'retains the alias in diagnostics and does not retry a failed core invocation' {
        $LauncherParameters.AliasName = 'fixture-failure'
        $warnings = @()
        try { & $script:LauncherUnderTest @LauncherParameters -Confirm:$false -WarningVariable warnings -WarningAction SilentlyContinue } catch {
            $_.Exception.Message | Should -Be 'Synthetic core failure'
        }
        @($warnings).Count | Should -Be 1
        $warnings[0].ToString() | Should -BeLike "*fixture-failure*replacement alias*"
        Should -Invoke Connect-AzAccount -Times 2 -Exactly
    }
}
