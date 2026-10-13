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
        $owner = $EAEngineFixture.P.TargetOwnerObjectId
        if ($EAEngineFixture.Scenario -eq 'WrongAlias') { $owner = '99999999-9999-4999-8999-999999999999' }
        # This fixture follows the GET response contract, not the PUT request body.
        return @{ properties = @{
            billingScope = $scope; displayName = $EAEngineFixture.P.SubscriptionName; workload = 'Production'
            subscriptionOwnerId = $owner; subscriptionId = $EAEngineFixture.SubId
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
        $script:EAEngineFixture = @{
            P = $script:P; SourceTenant = $script:SourceTenant; TargetTenant = $script:TargetTenant
            SourceApp = $script:SourceApp; TargetApp = $script:TargetApp; SubId = $script:SubId
        }
        $EAEngineFixture.Scenario = 'Normal'
        $EAEngineFixture.Exists = $false
        $EAEngineFixture.Accepted = $false
        $EAEngineFixture.StatusReads = 0
        $EAEngineFixture.AliasReads = 0
        $EAEngineFixture.FinalReads = 0
        $EAEngineFixture.Calls = [System.Collections.Generic.List[object]]::new()
        Mock Start-Sleep {}
        Mock Get-AzAccessToken {
            param($ResourceUrl, $TenantId)
            # This string is synthetic test data, never a real bearer token.
            [pscustomobject]@{ Token = (ConvertTo-SecureString "$TenantId|$ResourceUrl" -AsPlainText -Force) }
        } -RemoveParameterType DefaultProfile
        Mock Invoke-WebRequest {
            param($Uri, $Method, $Body, $Token)
            $u = [string]$Uri
            $EAEngineFixture.Calls.Add(@{ Uri = $u; Method = [string]$Method; Body = $Body
                MockToken = (ConvertFrom-SecureString $Token -AsPlainText) })
            if ($u -like 'https://graph.microsoft.com/*') {
                $isSource = $u.Contains($EAEngineFixture.SourceApp)
                $principalHomeTenant = if ($isSource) { $EAEngineFixture.SourceTenant } else { $EAEngineFixture.TargetTenant }
                $id = if ($isSource) { '77777777-7777-4777-8777-777777777777' } else { $EAEngineFixture.P.TargetOwnerObjectId }
                if ($isSource -and $EAEngineFixture.Scenario -eq 'ForeignHome') { $principalHomeTenant = $EAEngineFixture.TargetTenant }
                if (-not $isSource -and $EAEngineFixture.Scenario -eq 'WrongTargetIdentity') {
                    $id = '99999999-9999-4999-8999-999999999999'
                }
                if ($EAEngineFixture.Scenario -eq 'GraphForbidden') { return New-FakeResponse 403 @{ error = @{ code = 'Authorization_RequestDenied' } } }
                $app = if ($isSource) { $EAEngineFixture.SourceApp } else { $EAEngineFixture.TargetApp }
                return New-FakeResponse 200 @{ id = $id; appId = $app; appOwnerOrganizationId = $principalHomeTenant; servicePrincipalType = 'Application' }
            }
            if ($u -like '*/aliases/*') {
                if ($Method -eq 'PUT') {
                    if ($EAEngineFixture.Scenario -eq 'PutTransportFailure') { throw 'Simulated connection loss' }
                    $EAEngineFixture.Exists = $true
                    return New-FakeResponse 201 (New-FakeAlias)
                }
                $EAEngineFixture.AliasReads++
                if ($EAEngineFixture.Scenario -eq 'AliasForbidden') { return New-FakeResponse 403 @{ error = @{ code = 'AuthorizationFailed' } } }
                if ($EAEngineFixture.Scenario -eq 'Throttled' -and $EAEngineFixture.AliasReads -eq 1) {
                    return New-FakeResponse 429 @{} @{ 'Retry-After' = '1' }
                }
                if ($EAEngineFixture.Scenario -eq 'RetryAfterDeadline') {
                    return New-FakeResponse 429 @{} @{ 'Retry-After' = '9999' }
                }
                if (-not $EAEngineFixture.Exists) { return New-FakeResponse 404 @{} }
                return New-FakeResponse 200 (New-FakeAlias)
            }
            if ($u -like '*/acceptOwnershipStatus?*') {
                $EAEngineFixture.StatusReads++
                $tenant = if ($EAEngineFixture.Scenario -eq 'WrongStatusTenant') { $EAEngineFixture.SourceTenant } else { $EAEngineFixture.TargetTenant }
                $ownership = if ($EAEngineFixture.Accepted) { 'Completed' } else { 'Pending' }
                $provisioning = if ($EAEngineFixture.Accepted) { 'Succeeded' } else { 'Accepted' }
                if ($EAEngineFixture.Scenario -eq 'Expired') { $ownership = 'Expired' }
                return New-FakeResponse 200 @{ subscriptionId = $EAEngineFixture.SubId; subscriptionTenantId = $tenant
                    acceptOwnershipState = $ownership; provisioningState = $provisioning }
            }
            if ($u -like '*/acceptOwnership?*') {
                if ($EAEngineFixture.Scenario -eq 'PostTransportFailure') { throw 'Simulated connection loss' }
                $EAEngineFixture.Accepted = $true
                return New-FakeResponse 202 @{} @{ 'Retry-After' = '1' }
            }
            if ($u -like 'https://management.azure.com/subscriptions/*') {
                $EAEngineFixture.FinalReads++
                if ($EAEngineFixture.Scenario -eq 'Propagation' -and $EAEngineFixture.FinalReads -eq 1) { return New-FakeResponse 403 @{} }
                $tenant = if ($EAEngineFixture.Scenario -eq 'WrongFinalTenant') { $EAEngineFixture.SourceTenant } else { $EAEngineFixture.TargetTenant }
                return New-FakeResponse 200 @{ subscriptionId = $EAEngineFixture.SubId; tenantId = $tenant; state = 'Enabled' }
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
        @($EAEngineFixture.Calls | Where-Object Method -ne 'GET').Count | Should -Be 0
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
        $EAEngineFixture.Scenario = 'ForeignHome'
        { & $script:UnderTest @P -Mode CreateAndAccept } | Should -Throw '*not registered*'
        @($EAEngineFixture.Calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }
    It 'rejects the wrong target owner before creation' {
        $EAEngineFixture.Scenario = 'WrongTargetIdentity'
        { & $script:UnderTest @P -Mode CreateAndAccept } | Should -Throw '*TargetOwnerObjectId*'
        @($EAEngineFixture.Calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }
    It 'fails closed when the Graph home-tenant check is unavailable' {
        $EAEngineFixture.Scenario = 'GraphForbidden'
        { & $script:UnderTest @P -Mode CreateAndAccept } | Should -Throw '*HTTP 403*'
        @($EAEngineFixture.Calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }
    It 'never treats alias 403 as not found' {
        $EAEngineFixture.Scenario = 'AliasForbidden'
        { & $script:UnderTest @P -Mode CreateAndAccept } | Should -Throw '*HTTP 403*'
        @($EAEngineFixture.Calls | Where-Object Method -eq 'PUT').Count | Should -Be 0
    }
    It 'uses source tokens for creation and target tokens for acceptance and final verification' {
        $result = & $script:UnderTest @P -Mode CreateAndAccept -Confirm:$false
        $result.Result | Should -Be 'Succeeded'
        $put = @($EAEngineFixture.Calls | Where-Object Method -eq 'PUT')
        $post = @($EAEngineFixture.Calls | Where-Object Method -eq 'POST')
        $put.Count | Should -Be 1
        $post.Count | Should -Be 1
        $put[0].MockToken | Should -Be "$script:SourceTenant|https://management.azure.com/"
        $post[0].MockToken | Should -Be "$script:TargetTenant|https://management.azure.com/"
        $payload = $put[0].Body | ConvertFrom-Json
        $payload.properties.additionalProperties.subscriptionTenantId | Should -Be $script:TargetTenant
        $payload.properties.additionalProperties.subscriptionOwnerId | Should -Be $P.TargetOwnerObjectId
        $EAEngineFixture.StatusReads | Should -BeGreaterThan 1
        $EAEngineFixture.FinalReads | Should -Be 1
    }
    It 'resumes the documented flat alias response without another PUT' {
        $EAEngineFixture.Exists = $true
        $result = & $script:UnderTest @P -Mode Resume -Confirm:$false
        $result.Result | Should -Be 'Succeeded'
        @($EAEngineFixture.Calls | Where-Object Method -eq 'PUT').Count | Should -Be 0
    }
    It 'refuses to create a second subscription for an existing alias' {
        $EAEngineFixture.Exists = $true
        { & $script:UnderTest @P -Mode CreateAndAccept } | Should -Throw '*already exists*'
        @($EAEngineFixture.Calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }
    It 'does not create an alias while resuming a missing request' {
        { & $script:UnderTest @P -Mode Resume } | Should -Throw '*Alias not found*'
        @($EAEngineFixture.Calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }
    It 'rejects a mismatching existing owner' {
        $EAEngineFixture.Exists = $true; $EAEngineFixture.Scenario = 'WrongAlias'
        { & $script:UnderTest @P -Mode Resume } | Should -Throw '*Alias does not match*'
        @($EAEngineFixture.Calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }
    It 'rejects a different target tenant before accepting ownership' {
        $EAEngineFixture.Exists = $true; $EAEngineFixture.Scenario = 'WrongStatusTenant'
        { & $script:UnderTest @P -Mode Resume } | Should -Throw '*Ownership status does not match*'
        @($EAEngineFixture.Calls | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
    It 'does not accept an expired request' {
        $EAEngineFixture.Exists = $true; $EAEngineFixture.Scenario = 'Expired'
        { & $script:UnderTest @P -Mode Resume } | Should -Throw '*expired*'
        @($EAEngineFixture.Calls | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
    It 'verifies a pending request without modifying it' {
        $EAEngineFixture.Exists = $true
        $result = & $script:UnderTest @P -Mode Verify
        $result.Result | Should -Be 'NotCompleted'
        @($EAEngineFixture.Calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }
    It 'does not accept ownership twice after completion' {
        $EAEngineFixture.Exists = $true; $EAEngineFixture.Accepted = $true
        $result = & $script:UnderTest @P -Mode Resume
        $result.Result | Should -Be 'Succeeded'
        @($EAEngineFixture.Calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }
    It 'does not retry an ambiguous PUT transport failure' {
        $EAEngineFixture.Scenario = 'PutTransportFailure'
        { & $script:UnderTest @P -Mode CreateAndAccept -Confirm:$false } | Should -Throw '*Transport failure*'
        @($EAEngineFixture.Calls | Where-Object Method -eq 'PUT').Count | Should -Be 1
        @($EAEngineFixture.Calls | Where-Object Method -eq 'POST').Count | Should -Be 0
    }
    It 'does not retry an ambiguous POST transport failure' {
        $EAEngineFixture.Exists = $true; $EAEngineFixture.Scenario = 'PostTransportFailure'
        { & $script:UnderTest @P -Mode Resume -Confirm:$false } | Should -Throw '*Transport failure*'
        @($EAEngineFixture.Calls | Where-Object Method -eq 'POST').Count | Should -Be 1
    }
    It 'retries a throttled GET and honors Retry-After' {
        $EAEngineFixture.Scenario = 'Throttled'
        $result = & $script:UnderTest @P
        $result.Result | Should -Be 'ReadOnlyChecksPassed'
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 1 }
    }
    It 'waits for final subscription authorization propagation' {
        $EAEngineFixture.Exists = $true; $EAEngineFixture.Accepted = $true; $EAEngineFixture.Scenario = 'Propagation'
        $result = & $script:UnderTest @P -Mode Verify
        $result.Result | Should -Be 'Succeeded'
        $EAEngineFixture.FinalReads | Should -Be 2
    }
    It 'stops when Retry-After would exceed the polling deadline' {
        $EAEngineFixture.Scenario = 'RetryAfterDeadline'
        { & $script:UnderTest @P -TimeoutMinutes 1 } | Should -Throw '*Polling deadline*'
        Should -Invoke Start-Sleep -Times 0 -Exactly
        @($EAEngineFixture.Calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }
    It 'does not report success for a subscription in the wrong actual tenant' {
        $EAEngineFixture.Exists = $true; $EAEngineFixture.Accepted = $true; $EAEngineFixture.Scenario = 'WrongFinalTenant'
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
            if ($LauncherCertificateCase -eq 'MissingTarget' -and $LiteralPath.EndsWith('B' * 40)) {
                throw 'Synthetic missing destination certificate'
            }
            [pscustomobject]@{
                HasPrivateKey = $LauncherCertificateCase -ne 'NoPrivateKey'
                NotBefore = if ($LauncherCertificateCase -eq 'Future') { [datetime]::UtcNow.AddDays(1) } else { [datetime]::UtcNow.AddDays(-1) }
                NotAfter = if ($LauncherCertificateCase -eq 'Expired') { [datetime]::UtcNow.AddDays(-1) } else { [datetime]::UtcNow.AddDays(1) }
            }
        } -ParameterFilter { $LiteralPath -like 'Cert:\CurrentUser\My\*' }
        Mock Disable-AzContextAutosave {}
        Mock Connect-AzAccount {
            param($ApplicationId, $Tenant)
            if ($LauncherTargetLoginFails -and $Tenant -eq $LauncherParameters.TargetTenantId) {
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

Describe 'EA native Automation runbook' {
    BeforeAll {
        $script:CloudFunctionsCreated = @()
        if (-not (Get-Command Get-AutomationVariable -ErrorAction SilentlyContinue)) {
            function global:Get-AutomationVariable { param($Name) throw 'Unexpected asset access.' }
            $script:CloudFunctionsCreated += 'Get-AutomationVariable'
        }
        if (-not (Get-Command Get-AutomationCertificate -ErrorAction SilentlyContinue)) {
            function global:Get-AutomationCertificate { param($Name) throw 'Unexpected certificate access.' }
            $script:CloudFunctionsCreated += 'Get-AutomationCertificate'
        }
        $script:CloudArtifact = Join-Path $TestDrive 'cloud.ps1'
        & (Join-Path $PSScriptRoot 'Publish-EAAutomationRunbook.ps1') -OutputPath $script:CloudArtifact -Confirm:$false | Out-Null
    }
    AfterAll {
        foreach ($functionName in $script:CloudFunctionsCreated) { Remove-Item "Function:\global:$functionName" }
    }
    BeforeEach {
        $script:CloudFixtureSettings = @{
            eaTenantId = '11111111-1111-4111-8111-111111111111'
            targetTenantId = '22222222-2222-4222-8222-222222222222'
            sourceApplicationId = '33333333-3333-4333-8333-333333333333'
            targetApplicationId = '44444444-4444-4444-8444-444444444444'
            targetOwnerObjectId = '66666666-6666-4666-8666-666666666666'
            billingAccountId = '1234567'; enrollmentAccountId = '7654321'
            sourceCertificateAssetName = 'source'; targetCertificateAssetName = 'target'
            requestContainerUri = 'https://fixturestore.blob.core.windows.net/requests'
        }
        $script:CloudFixture = @{
            Record = $null; LeaseHeld = $false; AliasExists = $false; Accepted = $false
            Writes = 0; FailWrite = $false; InvalidCertificate = $false
            SubId = '55555555-5555-4555-8555-555555555555'
        }
        Mock Get-AutomationVariable { $CloudFixtureSettings }
        Mock Get-AutomationCertificate {
            $fakeCertificate = [pscustomobject]@{
                HasPrivateKey = -not $CloudFixture.InvalidCertificate
                NotBefore = [datetime]::UtcNow.AddDays(-1); NotAfter = [datetime]::UtcNow.AddDays(1)
            }
            $fakeCertificate | Add-Member -MemberType ScriptMethod -Name Export -Value { param($Type, $Password) return [byte[]]@(1, 2, 3) }
            $fakeCertificate
        }
        Mock Disable-AzContextAutosave {}
        Mock Connect-AzAccount {
            param($Tenant, $ApplicationId, $Identity)
            [pscustomobject]@{ Context = [pscustomobject]@{
                Tenant = @{ Id = $Tenant }; Environment = @{ Name = 'AzureCloud' }
                Account = @{ Id = $ApplicationId; Type = 'ServicePrincipal' }
            } }
        }
        Mock Get-AzAccessToken {
            param($TenantId, $ResourceUrl)
            [pscustomobject]@{ Token = (ConvertTo-SecureString "$TenantId|$ResourceUrl" -AsPlainText -Force) }
        }
        Mock Start-Sleep {}
        Mock Invoke-WebRequest {
            param($Uri, $Method, $Headers, $Body)
            $fixtureUri = [uri]$Uri
            $fixtureCode = 200
            $fixtureData = @{}
            if ($fixtureUri.Host -eq 'fixturestore.blob.core.windows.net') {
                if ($fixtureUri.Query -eq '?comp=lease') {
                    if ($Headers['x-ms-lease-action'] -eq 'acquire') {
                        if ($CloudFixture.LeaseHeld) { $fixtureCode = 409 }
                        else { $CloudFixture.LeaseHeld = $true; $fixtureCode = 201 }
                    } else { $CloudFixture.LeaseHeld = $false }
                } elseif ($Method -eq 'PUT') {
                    $CloudFixture.Record = ConvertFrom-Json ([Text.Encoding]::UTF8.GetString([byte[]]$Body)) -AsHashtable
                    $fixtureCode = 201
                } elseif ($null -eq $CloudFixture.Record) { $fixtureCode = 404 }
                else { $fixtureData = $CloudFixture.Record }
            } elseif ($fixtureUri.Host -eq 'graph.microsoft.com') {
                $fixtureSource = $Uri.Contains($CloudFixtureSettings.sourceApplicationId)
                $fixtureData = @{
                    id = if ($fixtureSource) { '77777777-7777-4777-8777-777777777777' } else { $CloudFixtureSettings.targetOwnerObjectId }
                    appId = if ($fixtureSource) { $CloudFixtureSettings.sourceApplicationId } else { $CloudFixtureSettings.targetApplicationId }
                    appOwnerOrganizationId = $CloudFixtureSettings.eaTenantId; servicePrincipalType = 'Application'
                }
            } elseif ($fixtureUri.AbsolutePath.Contains('/aliases/')) {
                if ($Method -eq 'PUT') {
                    $CloudFixture.Writes++; $CloudFixture.AliasExists = $true
                    if ($CloudFixture.FailWrite) { throw 'Synthetic interrupted write.' }
                }
                if (-not $CloudFixture.AliasExists) { $fixtureCode = 404 }
                else { $fixtureData = @{ properties = @{
                    billingScope = '/providers/Microsoft.Billing/billingAccounts/1234567/enrollmentAccounts/7654321'
                    displayName = 'Cloud fixture'; workload = 'Production'
                    subscriptionOwnerId = $CloudFixtureSettings.targetOwnerObjectId; subscriptionId = $CloudFixture.SubId
                    provisioningState = 'Succeeded'
                } } }
            } elseif ($fixtureUri.AbsolutePath.EndsWith('/acceptOwnershipStatus')) {
                $fixtureData = @{
                    subscriptionId = $CloudFixture.SubId; subscriptionTenantId = $CloudFixtureSettings.targetTenantId
                    acceptOwnershipState = if ($CloudFixture.Accepted) { 'Completed' } else { 'Pending' }
                    provisioningState = 'Succeeded'
                }
            } elseif ($fixtureUri.AbsolutePath.EndsWith('/acceptOwnership')) {
                $CloudFixture.Writes++; $CloudFixture.Accepted = $true; $fixtureCode = 202
            } elseif ($fixtureUri.AbsolutePath -eq "/subscriptions/$($CloudFixture.SubId)") {
                $fixtureData = @{ subscriptionId = $CloudFixture.SubId; tenantId = $CloudFixtureSettings.targetTenantId; state = 'Enabled' }
            } else { throw "Unexpected fixture endpoint: $Uri" }
            [pscustomobject]@{ StatusCode = $fixtureCode; Content = (ConvertTo-Json $fixtureData -Depth 30); Headers = @{} }
        }
    }
    It 'builds a standalone artifact with one engine and the native input form' {
        $artifactText = [IO.File]::ReadAllText($CloudArtifact)
        $artifactText | Should -Not -Match '__EA_ENGINE__'
        ([regex]::Matches($artifactText, 'function Assert-Alias')).Count | Should -Be 1
        $artifactText | Should -Match 'Get-AutomationCertificate'
    }
    It 'validates identities and storage without writing a request' {
        $result = & $CloudArtifact -SubscriptionName 'Cloud fixture' -AliasName 'cloud-fixture' -Mode Validate
        $result.Result | Should -Be 'ReadOnlyChecksPassed'
        $CloudFixture.Record | Should -BeNullOrEmpty
        $CloudFixture.Writes | Should -Be 0
    }
    It 'creates, accepts, verifies and persists the result under a lease' {
        $result = & $CloudArtifact -SubscriptionName 'Cloud fixture' -AliasName 'cloud-fixture' -Mode CreateAndAccept
        $result.Result | Should -Be 'Succeeded'
        $CloudFixture.Record.state | Should -Be 'Succeeded'
        $CloudFixture.Record.result.SubscriptionId | Should -Be $CloudFixture.SubId
        $CloudFixture.Writes | Should -Be 2
        $CloudFixture.LeaseHeld | Should -BeFalse
    }
    It 'prevents creation replay after success' {
        & $CloudArtifact -SubscriptionName 'Cloud fixture' -AliasName 'cloud-fixture' -Mode CreateAndAccept | Out-Null
        $CloudFixture.Writes = 0
        { & $CloudArtifact -SubscriptionName 'Cloud fixture' -AliasName 'cloud-fixture' -Mode CreateAndAccept } | Should -Throw '*already been attempted*'
        $CloudFixture.Writes | Should -Be 0
    }
    It 'rejects changed inputs before subscription writes' {
        & $CloudArtifact -SubscriptionName 'Cloud fixture' -AliasName 'cloud-fixture' -Mode CreateAndAccept | Out-Null
        $CloudFixture.Writes = 0
        { & $CloudArtifact -SubscriptionName 'Different name' -AliasName 'cloud-fixture' -Mode Resume } | Should -Throw '*does not match*'
        $CloudFixture.Writes | Should -Be 0
    }
    It 'stops before engine execution when another job holds the lease' {
        $CloudFixture.LeaseHeld = $true
        { & $CloudArtifact -SubscriptionName 'Cloud fixture' -AliasName 'cloud-fixture' -Mode CreateAndAccept } | Should -Throw '*HTTP 409*'
        $CloudFixture.Writes | Should -Be 0
        $CloudFixture.LeaseHeld | Should -BeTrue
    }
    It 'marks an interrupted write for review and prohibits creation replay' {
        $CloudFixture.FailWrite = $true
        { & $CloudArtifact -SubscriptionName 'Cloud fixture' -AliasName 'cloud-fixture' -Mode CreateAndAccept } | Should -Throw '*Transport failure*'
        $CloudFixture.Record.state | Should -Be 'NeedsReview'
        $CloudFixture.LeaseHeld | Should -BeFalse
        $CloudFixture.Writes | Should -Be 1
        { & $CloudArtifact -SubscriptionName 'Cloud fixture' -AliasName 'cloud-fixture' -Mode CreateAndAccept } | Should -Throw '*already been attempted*'
        $CloudFixture.Writes | Should -Be 1
    }
    It 'rejects an invalid certificate before either application login' {
        $CloudFixture.InvalidCertificate = $true
        { & $CloudArtifact -SubscriptionName 'Cloud fixture' -AliasName 'cloud-fixture' -Mode CreateAndAccept } | Should -Throw '*private keys*'
        Should -Invoke Connect-AzAccount -Times 0 -Exactly -ParameterFilter { $ServicePrincipal }
        $CloudFixture.Record | Should -BeNullOrEmpty
    }
}

Describe 'EA Automation infrastructure security' {
    BeforeAll {
        $compiledPath = Join-Path $PSScriptRoot 'build/main.json'
        if (-not (Test-Path -LiteralPath $compiledPath)) { throw 'Compile infra/main.bicep before running this suite.' }
        $script:CompiledInfrastructure = ConvertFrom-Json ([IO.File]::ReadAllText($compiledPath)) -AsHashtable -Depth 100
        function Get-InfrastructureResources {
            param([hashtable]$Template)
            $items = if ($Template.resources -is [Collections.IDictionary]) { $Template.resources.Values } else { $Template.resources }
            foreach ($item in $items) {
                if ($item.existing -or $item.copy) { continue }
                $item
                if ($item.type -eq 'Microsoft.Resources/deployments' -and $item.properties.template) {
                    Get-InfrastructureResources $item.properties.template
                }
            }
        }
        $script:InfrastructureResources = @(Get-InfrastructureResources $script:CompiledInfrastructure)
    }
    It 'disables shared keys and anonymous blob access and requires HTTPS and TLS 1.2' {
        $storageResource = @($InfrastructureResources | Where-Object type -EQ 'Microsoft.Storage/storageAccounts')
        $storageResource.Count | Should -Be 1
        $storageResource[0].properties.allowSharedKeyAccess | Should -BeFalse
        $storageResource[0].properties.allowBlobPublicAccess | Should -BeFalse
        $storageResource[0].properties.supportsHttpsTrafficOnly | Should -BeTrue
        $storageResource[0].properties.minimumTlsVersion | Should -Be 'TLS1_2'
        $storageResource[0].properties.encryption.requireInfrastructureEncryption | Should -BeTrue
    }
    It 'creates one private request container and a container-scoped identity role' {
        $containers = @($InfrastructureResources | Where-Object type -EQ 'Microsoft.Storage/storageAccounts/blobServices/containers')
        $containers.Count | Should -Be 1
        $containers[0].properties.publicAccess | Should -Be 'None'
        $storageRoles = @($InfrastructureResources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' -and $_.scope -like '*blobServices*containers*' })
        $storageRoles.Count | Should -Be 1
        $storageRoles[0].properties.principalType | Should -Be 'ServicePrincipal'
    }
    It 'links the draft runbook to the PowerShell runtime' {
        $runbooks = @($InfrastructureResources | Where-Object type -EQ 'Microsoft.Automation/automationAccounts/runbooks')
        $runbooks.Count | Should -Be 1
        $runbooks[0].properties.runtimeEnvironment | Should -Be 'ea-powershell74'
        $runbooks[0].properties.logVerbose | Should -BeFalse
        $runbooks[0].properties.logProgress | Should -BeFalse
    }
    It 'exports only resource identifiers and asset names' {
        $CompiledInfrastructure.outputs.Keys.Count | Should -Be 6
        $CompiledInfrastructure.outputs.Keys | Should -Not -Contain 'keys'
        $CompiledInfrastructure.outputs.Keys | Should -Not -Contain 'connectionString'
    }
}
