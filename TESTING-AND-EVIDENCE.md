# EA Cross-Tenant Subscription - v2.0

For the cloud runbook, follow [DEPLOYMENT.md](DEPLOYMENT.md). The commands below cover direct engine and local-launcher testing.

## Single-Command Execution (October 10, 2026)

[New-EASubscriptionCrossTenant.OneTouch.ps1](New-EASubscriptionCrossTenant.OneTouch.ps1) authenticates both service principals and runs v2 in `CreateAndAccept` mode. The destination principal becomes Owner; billing stays on the selected EA enrollment. See the [README](README.md) for the Automation architecture.

### One-Time Preparation

1. Use Windows, PowerShell 7.2+, and `Az.Accounts` 5.3.1+ in a dedicated `pwsh` session under approved execution/signing policy.
2. Register the source application in its home tenant. Have an authorized administrator assign and verify EA billing `SubscriptionCreator`, role ID `a0bcee42-bf30-4d1b-926a-48d21664ef71`, on the selected enrollment account [D3].
3. Prepare the destination application and principal. Set `TargetOwnerObjectId` to the destination Enterprise application's Object ID.
4. Register a public certificate on each application. Install the matching, valid private-key certificates in the execution identity's `Cert:\CurrentUser\My` store and restrict key access.
5. Verify enrollment status, available capacity, and both tenants' policies. Enable `DevTest` only when the EA offer supports it.

Version 2 requires application-backed service principals in both contexts. Graph reads each calling principal's own details and verifies the source registration tenant through `appOwnerOrganizationId` and the destination principal ID [D8]. The EA administrator separately verifies the billing role. User creation guidance is in [D1].

### Configuration and Startup

Replace the placeholders below. Keep one stable alias and the same parameters for the lifetime of each request.

```powershell
$oneTouch = @{
     EATenantId = '<SOURCE-HOME-TENANT-GUID>'
     TargetTenantId = '<TARGET-TENANT-GUID>'
     SourceApplicationId = '<SOURCE-APPLICATION-CLIENT-ID>'
     TargetApplicationId = '<TARGET-APPLICATION-CLIENT-ID>'
     TargetOwnerObjectId = '<TARGET-ENTERPRISE-APPLICATION-OBJECT-ID>'
     SourceCertificateThumbprint = '<SOURCE-CERTIFICATE-40-HEX-THUMBPRINT>'
     TargetCertificateThumbprint = '<TARGET-CERTIFICATE-40-HEX-THUMBPRINT>'
     BillingAccountId = '<NUMERIC-EA-BILLING-ACCOUNT-ID>'
     EnrollmentAccountId = '<NUMERIC-ENROLLMENT-ACCOUNT-ID>'
     SubscriptionName = 'CNH application production'
     AliasName = 'cnh-application-prod-001'
}

# Offline: no certificate lookup, login, token or HTTP call.
.\New-EASubscriptionCrossTenant.OneTouch.ps1 @oneTouch -WhatIf

# Real read-only checks; does not prove subscription creation permission.
.\New-EASubscriptionCrossTenant.OneTouch.ps1 @oneTouch -Mode Validate

# One invocation creates a REAL subscription and accepts it in the target tenant.
$created = .\New-EASubscriptionCrossTenant.OneTouch.ps1 @oneTouch
$created | Format-List
```

The engine polls until completion and verifies the final subscription. `TimeoutMinutes` sets its polling deadline after sign-in; Azure can continue processing after that deadline. Independently verify destination IAM and source EA billing as described in section 4.

### Errors and Recovery

Run one process per alias. After an interrupted write or timeout, retain its parameters and subscription ID, inspect with `Verify`, and continue with `Resume`.

```powershell
.\New-EASubscriptionCrossTenant.OneTouch.ps1 @oneTouch -Mode Verify
.\New-EASubscriptionCrossTenant.OneTouch.ps1 @oneTouch -Mode Resume
```

`Verify` is read-only. `Resume` requires an existing alias and has creation PUT disabled. If the alias is absent or unreadable after an uncertain error, stop and diagnose before another write. Cancellation requires an administrator.

### Validation Status

Local environment: PowerShell 7.6.6, Az.Accounts 5.3.1, and Pester 5.7.1. Parsing and static checks passed. **Pester discovery was blocked by RemoteSigned policy for unsigned files; executed tests: zero.** Live authentication and Azure creation remain pending. Use approved signing/execution policy before testing.

To select launcher tests, add this filter to the Pester configuration in section 1:

```powershell
$config.Filter.FullName = 'EA cross-tenant one-touch launcher*'
```

Then run the full suite without the filter. Require nonzero executed tests, successful discovery, and a passing result before the live checks in section 4.

Authentication reference: [Service principal certificate login](https://learn.microsoft.com/powershell/azure/authenticate-noninteractive#login-with-a-service-principal).
Related MCA example: [midpcld/subvending](https://github.com/midpcld/subvending). The EA API contract is documented in [D2].

Documentation reviewed on **October 9, 2026**.

## 1. Local Testing Without Azure

Open PowerShell 7.4+ in the repository directory. Install modules from an approved source and run the parser and mocked tests:

```powershell
Install-Module Az.Accounts -Scope CurrentUser
Install-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.999.999 -Scope CurrentUser
Import-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.999.999

bicep build infra/main.bicep --outfile build/main.json
if ($LASTEXITCODE -ne 0) { throw 'Bicep compilation failed.' }

# Parse the production script without running it.
$tokens = $null
$parseErrors = $null
$path = (Resolve-Path .\New-EASubscriptionCrossTenant.v2.ps1).Path
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    $path, [ref]$tokens, [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    $parseErrors | Format-List
    throw 'PowerShell parsing failed.'
}

# Run mocked tests and export an auditable result.
$config = New-PesterConfiguration
$config.Run.Path = '.\New-EASubscriptionCrossTenant.v2.Tests.ps1'
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = '.\pester-results.xml'
$result = Invoke-Pester -Configuration $config
if ($result.Result -ne 'Passed') { throw 'Do not proceed: offline tests failed.' }
```

The suite mocks tokens, HTTP, certificate lookup, sign-in, and polling waits. Coverage includes the engine, local launcher, built cloud artifact, request leases, recovery, and compiled infrastructure security properties. GitHub Actions runs the suite independently of the local signing-policy blocker. Verify real authentication, policies, and service behavior during acceptance testing.

## 2. Authentication and Configuration

For direct engine invocation, authenticate with two registered PFX certificates and pass their contexts. Replace the placeholders and retain the parameters for recovery.

```powershell
Import-Module Az.Accounts
Disable-AzContextAutosave -Scope Process | Out-Null
$eaTenant = '<EA-SOURCE-HOME-TENANT-GUID>'
$targetTenant = '<TARGET-TENANT-GUID>'

$sourceLogin = @{
    ServicePrincipal = $true
    Tenant = $eaTenant
    ApplicationId = '<SOURCE-APPLICATION-CLIENT-ID>'
    CertificatePath = (Resolve-Path '.\source-app.pfx').Path
    CertificatePassword = (Read-Host 'Source PFX password' -AsSecureString)
    ContextName = 'ea-v2-source'
    SkipContextPopulation = $true
    Scope = 'Process'
}
$source = (Connect-AzAccount @sourceLogin).Context

$targetLogin = @{
    ServicePrincipal = $true
    Tenant = $targetTenant
    ApplicationId = '<TARGET-APPLICATION-CLIENT-ID>'
    CertificatePath = (Resolve-Path '.\target-app.pfx').Path
    CertificatePassword = (Read-Host 'Target PFX password' -AsSecureString)
    ContextName = 'ea-v2-target'
    SkipContextPopulation = $true
    Scope = 'Process'
}
$target = (Connect-AzAccount @targetLogin).Context

$p = @{
    SourceContext = $source
    TargetContext = $target
    EATenantId = $eaTenant
    TargetTenantId = $targetTenant
    TargetOwnerObjectId = '<TARGET-ENTERPRISE-APPLICATION-OBJECT-ID>'
    BillingAccountId = '<NUMERIC-EA-BILLING-ACCOUNT-ID>'
    EnrollmentAccountId = '<NUMERIC-ENROLLMENT-ACCOUNT-ID>'
    SubscriptionName = 'EA cross-tenant acceptance test'
    AliasName = 'ea-cross-tenant-test-001'
    Workload = 'Production'
    TimeoutMinutes = 20
}
```

`Production` selects the API offer type. Use `DevTest` when enabled for the enrollment account.

## 3. Planning and Read-Only Checks

```powershell
# Offline plan: no token acquisition and no API calls by the script.
.\New-EASubscriptionCrossTenant.v2.ps1 @p -Mode CreateAndAccept -WhatIf

# Real identity checks and read-only API calls; no subscription creation.
.\New-EASubscriptionCrossTenant.v2.ps1 @p -Mode Validate
```

Expected: `ReadOnlyChecksPassed`, correct identities, and `CreationPermissionVerified = False`. Verify creation authority through the EA billing-role assignment. An alias `404` means the request is absent.

## 4. Controlled Integration Test

After offline tests pass and the EA administrator verifies the role, enrollment, and policies, approve one creation under the designated test enrollment account. This command creates a real, billable subscription:

```powershell
$created = .\New-EASubscriptionCrossTenant.v2.ps1 @p -Mode CreateAndAccept
$created | Format-List
```

Expected: `Result = Succeeded`, `SubscriptionState = Enabled`, and correct tenant and subscription IDs. Then independently verify:

- Check destination IAM for the expected subscription Owner and any required team access.
- Check source EA Cost Management + Billing for the selected enrollment account. Allow for portal propagation. `RequestedBillingScope` records the submitted scope.
- Review organizational automation triggered by the new subscription.

The engine verifies the actual tenant and state through `GET /subscriptions/{id}`.

## 5. Verification, Recovery, and Error Handling

```powershell
# Inspect the same request without changing it.
.\New-EASubscriptionCrossTenant.v2.ps1 @p -Mode Verify

# Continue the same request; never create a replacement alias.
.\New-EASubscriptionCrossTenant.v2.ps1 @p -Mode Resume
```

| Outcome | Action |
| --- | --- |
| Pester test failed | Stop, retain the report, and fix the failure before calling Azure. |
| Guest/user context rejected | Authenticate with the application-backed service principals required by v2. |
| Source application not registered in EATenantId | Use an application registered in the expected source home tenant. |
| HTTP 401/403 during checks | Stop and check identity, audience, permissions, and policies. |
| Interrupted PUT/POST or timeout | The operation may have been accepted. Retain alias and subscription ID; wait and use Verify/Resume on the same alias. |
| Resume: alias absent | Diagnose tenant, identity, and portal state before another write. |
| Request expired | Agree on recovery with the administrator. |
| Verify: NotCompleted | State is readable but the process is incomplete; inspect the request and use Resume if appropriate. |
| Final state not Enabled | Investigate the subscription state before declaring success. |

Run one process per alias. The Account Owner handles cancellation under the organization's procedure. Polling deadlines apply after sign-in; individual authentication and HTTP calls have their own duration.

## Documentary Evidence for Commands and APIs

| Actual command/API | Official source | Verified contract and limitation |
| --- | --- | --- |
| `Connect-AzAccount -ServicePrincipal -Tenant -ApplicationId -CertificatePath -CertificatePassword -ContextName -SkipContextPopulation -Scope` | [Connect-AzAccount][D13] | Authentication and separate contexts. |
| `Disable-AzContextAutosave -Scope Process` | [Disable-AzContextAutosave][D14] | Prevents automatic saving of session contexts. |
| `Get-AzAccessToken -ResourceUrl -TenantId -DefaultProfile -AsSecureString` | [Get-AzAccessToken][D10] | Separate tokens per tenant and audience; tokens remain SecureString. |
| `Invoke-WebRequest -Authentication Bearer -Token -SkipHttpErrorCheck` | [Invoke-WebRequest][D11] | HTTPS transport and explicit status/header reads. |
| `GET /v1.0/servicePrincipals(appId='...')?$select=...` | [Get servicePrincipal][D8], [resource properties][D9] | Self-read of the principal and registration tenant through `appOwnerOrganizationId`. |
| `PUT /providers/Microsoft.Subscription/aliases/{alias}?api-version=2021-10-01` | [EA automation][D2], [Alias Create][D4] | `billingScope`, `displayName`, `workload`, `additionalProperties.subscriptionTenantId`, and `subscriptionOwnerId`. |
| `GET` of the same alias | [Alias Get][D5] | Read owner as `properties.subscriptionOwnerId`; creation uses `properties.additionalProperties.subscriptionOwnerId`. |
| `POST /providers/Microsoft.Subscription/subscriptions/{id}/acceptOwnership?api-version=2021-10-01` | [Accept Ownership][D6] | Destination acceptance; body includes `properties.displayName`; HTTP 202 is asynchronous. |
| `GET .../acceptOwnershipStatus?api-version=2021-10-01` | [Accept Ownership Status][D7] | `acceptOwnershipState`, `provisioningState`, `subscriptionTenantId`, and `subscriptionId`. |
| `GET /subscriptions/{id}?api-version=2022-12-01` | [Subscriptions Get][D12] | Independent checks of `tenantId`, `subscriptionId`, and `state`. |
| `ConvertTo-Json` / `ConvertFrom-Json -AsHashtable` | [ConvertTo-Json][D15], [ConvertFrom-Json][D16] | Request serialization and response parsing. |
| `SupportsShouldProcess` / `ShouldProcess` / `-WhatIf` | [ShouldProcess][D17] | Action control; offline behavior is implemented by the script. |
| `Parser.ParseFile`, `Invoke-Pester`, `Mock`, `Should -Invoke` | [PowerShell Parser][D18], [Pester v5][D19], [Mock][D20] | Syntax validation and mocked local tests. |

The engine uses API `2021-10-01`, as documented in the EA creation guide [D2].

## Evidence to Retain After Acceptance Testing

Retain `pester-results.xml`, `$PSVersionTable`, module versions, script hash, alias, subscription ID, expected/actual tenant, and billing/IAM checks. Keep tokens, PFX passwords, and private keys out of reports.

[D1]: https://learn.microsoft.com/en-us/azure/cost-management-billing/manage/create-enterprise-subscription
[D2]: https://learn.microsoft.com/en-us/azure/cost-management-billing/manage/programmatically-create-subscription-enterprise-agreement
[D3]: https://learn.microsoft.com/en-us/azure/cost-management-billing/manage/assign-roles-azure-service-principals
[D4]: https://learn.microsoft.com/en-us/rest/api/subscription/alias/create?view=rest-subscription-2021-10-01
[D5]: https://learn.microsoft.com/en-us/rest/api/subscription/alias/get?view=rest-subscription-2021-10-01
[D6]: https://learn.microsoft.com/en-us/rest/api/subscription/subscription/accept-ownership?view=rest-subscription-2021-10-01
[D7]: https://learn.microsoft.com/en-us/rest/api/subscription/subscription/accept-ownership-status?view=rest-subscription-2021-10-01
[D8]: https://learn.microsoft.com/en-us/graph/api/serviceprincipal-get?view=graph-rest-1.0
[D9]: https://learn.microsoft.com/en-us/graph/api/resources/serviceprincipal?view=graph-rest-1.0
[D10]: https://learn.microsoft.com/en-us/powershell/module/az.accounts/get-azaccesstoken
[D11]: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/invoke-webrequest?view=powershell-7.4
[D12]: https://learn.microsoft.com/en-us/rest/api/resources/subscriptions/get?view=rest-resources-2022-12-01
[D13]: https://learn.microsoft.com/en-us/powershell/module/az.accounts/connect-azaccount
[D14]: https://learn.microsoft.com/en-us/powershell/module/az.accounts/disable-azcontextautosave
[D15]: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/convertto-json?view=powershell-7.4
[D16]: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/convertfrom-json?view=powershell-7.4
[D17]: https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
[D18]: https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.language.parser.parsefile?view=powershellsdk-7.4.0
[D19]: https://pester.dev/docs/v5/commands/Invoke-Pester
[D20]: https://pester.dev/docs/v5/commands/Mock
