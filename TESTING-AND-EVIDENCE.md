# EA Cross-Tenant Subscription - v2.0

## Single-Command Execution (October 10, 2026)

`New-EASubscriptionCrossTenant.OneTouch.ps1` integrates both certificate-based
sign-ins and invokes v2 without additional confirmation prompts. The default
mode is `CreateAndAccept`: a single invocation requests the subscription in the
final tenant, accepts ownership, and verifies the tenant and `Enabled` state.
It does not change the directory of an existing subscription, change the
billing owner, or automatically grant access to the user starting the command.
The resulting owner is the destination service principal.

### One-Time Preparation

1. Windows, PowerShell 7.2 or later, and `Az.Accounts` 5.3.1 or later.
    Run in a dedicated `pwsh` session: sign-ins change process-local contexts
    without saving them for future sessions. Use signed scripts according to
    organizational policy; the launcher does not change execution policy.
2. Source application registered in its home tenant, with a service principal
    holding the EA billing role `SubscriptionCreator` on the selected enrollment
    account only. An authorized administrator assigns and verifies this role
    once, according to [D3]. Azure RBAC on an existing subscription is insufficient.
3. Application and service principal in the final tenant. Use the Enterprise
    application's Object ID as `TargetOwnerObjectId`, not the Client ID. The
    process does not require preassigned tenant-root Owner or Global Administrator.
4. Public certificate registered on each application; corresponding certificate
    with private key in the execution identity's `Cert:\CurrentUser\My` store.
    Both must be valid, and keys accessible only to authorized operators. The
    launcher checks presence, validity dates, and private-key availability;
    sign-in verifies actual use of the key. No passwords are requested during
    execution. Certificates are this launcher's choice, not the only method
    supported by Azure APIs.
5. Active enrollment, available capacity, and compatible policies in both
    tenants or appropriate exemptions. Do not enable `DevTest` without checking
    the EA offer. Separate applications are a simple operational choice, not a
    claim that Azure prohibits a multitenant application with a principal per tenant.

There is no need to install `Az.Subscription`, create a pipeline, deploy an
Azure service, or grant broad Graph permissions: the launcher reuses v2,
including the authenticated principal's Graph self-read documented in [D8].

### Configuration and Startup

Prepare nonsecret parameters in the approved launch system. Retain a stable
alias for each request: the subscription display name is not a unique key.
Replace every placeholder before execution.

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

A single invocation does not mean immediate completion. Version 2 waits for
documented states and verifies the actual subscription; HTTP 202 is not final
success. `TimeoutMinutes` bounds the v2 flow after sign-in, not the entire
launcher's wall-clock duration. A local timeout does not cancel Azure work.
Independently verify IAM in the final tenant and the enrollment account in
source Cost Management + Billing: `RequestedBillingScope` is not independent
evidence of the billing backend. User/group role assignments are outside scope.

### Errors and Recovery

Both certificates are checked and both sign-ins completed before invoking v2.
If the second sign-in fails, this launcher creates no request. Version 2 also
verifies the source home tenant and destination identity before any writes.

If the request exists or a write has an uncertain outcome, do not change its
alias or repeat creation. Retain every parameter and any emitted subscription
ID. Run only one process per alias.

```powershell
.\New-EASubscriptionCrossTenant.OneTouch.ps1 @oneTouch -Mode Verify
.\New-EASubscriptionCrossTenant.OneTouch.ps1 @oneTouch -Mode Resume
```

`Verify` reads without accepting; `Resume` continues only an existing request
and never issues PUT. If the alias is unreadable or absent after an uncertain
error, stop recovery and diagnose: do not automatically generate a new alias.
There is no transactional rollback, and the launcher does not cancel subscriptions.

### Local Launcher Evidence

The existing suite now includes a separate launcher `Describe`. It uses a
TestDrive copy, a fake v2 script, and mocked certificate-store and sign-in calls;
it is not a test of Entra connectivity or the real Azure flow. It covers WhatIf,
context separation, sign-in parameters, certificate validity, destination
sign-in failure, Resume/Verify/Validate forwarding, and alias diagnostics.

Detected local environment: PowerShell 7.6.6 and Az.Accounts 5.3.1. Pester 5.7.1
was downloaded to a temporary folder without replacing the user's modules.
PowerShell parsing passed for the launcher, v2, and tests. Installed
`Connect-AzAccount` parameters were checked, as was the absence of credential
prompts or execution-policy changes in the launcher. The existing fixture's
assignment to `$home`, a readonly automatic variable, was corrected to
`$principalHomeTenant`; the AST check confirms zero assignments to HOME.
These static checks do not replace test execution. Pester discovery was blocked
by `RemoteSigned` policy for an unsigned file: **no tests ran and no Passed
result is claimed**. The launcher and tests require authorized execution or
organizational signing before testing. The assistant performed no Azure
sign-ins or live subscription creation.

To run only the launcher tests in an environment with Pester 5 and compatible
policy, use the Pester configuration in section 1 and add:

```powershell
$config.Filter.FullName = 'EA cross-tenant one-touch launcher*'
```

Then run the full suite without the filter. Reject results with zero executed
tests or discovery errors. The live checks in section 4 remain necessary before
declaring the system operational in the CNH environment.

Authentication reference: [Service principal certificate login](https://learn.microsoft.com/powershell/azure/authenticate-noninteractive#login-with-a-service-principal).
Public example reviewed: [midpcld/subvending](https://github.com/midpcld/subvending),
for MCA rather than EA. It was not copied: it generates new aliases and reports
success after POST without final verification. The adopted EA contract remains
[D2], with [D3] for the scoped role and [D6] for acceptance.

Documentation reviewed on **October 9, 2026**. Script comments and messages are in English.

## Declared Assurance Level

The outcome cannot be guaranteed without running the flow in your environment. This version was compared with official documentation and statically reviewed. During the initial v2 preparation, PowerShell and Azure credentials were unavailable: **PowerShell parsing, the Pester suite, and Azure execution were not performed at that stage**. The 24 original Pester cases were provided to run, not as already-passed results. The subsequent launcher checks and current execution blocker are recorded above.

Sources document commands, parameters, requests, and responses. They do not certify this custom script. Passing mocked tests establishes part of the local logic; live Azure testing establishes the behavior of the actual configuration used.

## Home Tenant, Guests, and the Adopted Flow

The [Create an Enterprise Agreement subscription][D1] page requires Enterprise Administrators and Account Owners to create from their home tenant; signing in as a guest in another tenant is unsupported even if the user holds roles there. The wording concerns the identity's home tenant: it does not assert that every EA enrollment necessarily has a single tenant for all identities.

The [EA API][D2] page continues to document cross-tenant creation: a source token from the service principal's home tenant, `subscriptionTenantId` in the body, and subsequent acceptance with a destination-tenant token. The two instructions describe different steps and are compatible.

Version 2 intentionally restricts support to **application-backed service principals in both contexts**. It rejects all user contexts, including guests; it does not claim Azure prohibits native users. It also uses Graph to verify that the source application's `appOwnerOrganizationId` matches `EATenantId`. Simply using `Connect-AzAccount -Tenant ...` would not establish that requirement.

`EATenantId` and billing IDs are operator inputs. The Graph check does not prove the service principal holds the EA role on the specified enrollment: the EA administrator must verify that assignment.

This version does not change the directory of an existing, populated subscription: it creates a new EA request targeting the other tenant and accepts ownership. The expected result is a subscription in the destination tenant, billed to the selected EA enrollment.

## Corrections Compared with v1

- The `GET Alias` response uses `properties.subscriptionOwnerId`, not `properties.additionalProperties.subscriptionOwnerId`. The latter belongs to the creation request. The destination tenant is checked through ownership status and the final subscription read.
- Source application registration tenant and actual destination principal Object ID are verified.
- `Validate` is v2's default mode. `WhatIf` does not contact Azure; `Validate` performs real read-only checks.
- HTTP 202 is not final success; completion state and a subsequent read of the actual subscription are required.
- Recovery never issues PUT or invents a new alias. Write transport failures are not automatically retried.
- HTTP 403 on an alias stops execution: it is not equivalent to 404. Only the final read permits waiting on 403 for new-access propagation.

## Prerequisites

1. PowerShell 7.2 or later; preferably a version supported by your organization. Windows PowerShell 5.1 is insufficient.
2. `Az.Accounts` supporting `Get-AzAccessToken -AsSecureString`.
3. Source application registered in `EATenantId`; certificate or federated authentication. The service principal must hold **EA `SubscriptionCreator`**, ID `a0bcee42-bf30-4d1b-926a-48d21664ef71`, on the specific enrollment account. This is an EA billing role, distinct from subscription Azure RBAC roles. Have the assignment verified according to [D3]; the script does not assign roles.
4. Destination-tenant service principal and its credentials. `TargetOwnerObjectId` is the Object ID of the **Enterprise application in the destination tenant**, not the Application/Client ID or app-registration Object ID.
5. Compatible creation/transfer policies, active enrollment, and available quota. For `DevTest`, the offer must be enabled. Administrators must check policies; the script does not modify them.

The Graph check reads only the service principal making the request. [D8] documents this case without additional application permissions: there is no need to preassign `Directory.Read.All` or `Application.Read.All` solely for this check. If the read fails, the script stops; investigate the error instead of skipping verification.

## 1. Local Testing Without Azure

Open a new `pwsh` session in the files' directory. Install modules from an approved source; downloading modules requires network access, but subsequent mocked tests do not use Azure.

```powershell
Install-Module Az.Accounts -Scope CurrentUser
Install-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.999.999 -Scope CurrentUser
Import-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.999.999

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

The suite replaces `Get-AzAccessToken`, `Invoke-WebRequest`, and `Start-Sleep`. Contexts and tokens are synthetic. The original v2 tests cover 24 cases, including rejected guest authentication, incorrect home tenant or owner, 403, duplicate aliases, recovery with the documented schema, expired requests, token separation, interrupted writes, 429/Retry-After, deadlines, and final-tenant verification. They do not verify real certificates, policies, the EA role, or actual service acceptance.

## 2. Authentication and Configuration

Example using two PFX certificates already registered on their respective applications. The script creates neither applications nor certificates. Replace all placeholders, use a stable test alias, and retain these parameters for recovery.

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

`Production` is the API offer type used here, not a statement that the test subscription will host production workloads. Do not select `DevTest` without verifying it is enabled.

## 3. Planning and Read-Only Checks

```powershell
# Offline plan: no token acquisition and no API calls by the script.
.\New-EASubscriptionCrossTenant.v2.ps1 @p -Mode CreateAndAccept -WhatIf

# Real identity checks and read-only API calls; no subscription creation.
.\New-EASubscriptionCrossTenant.v2.ps1 @p -Mode Validate
```

Expected: `ReadOnlyChecksPassed`, correct identities, and `CreationPermissionVerified = False`. This is not an Azure-validated PUT dry run: obtaining a token and reading an alias does not prove creation authorization. An alias 404 means the resource is absent, not that write permission is confirmed.

## 4. Controlled Integration Test

Once local tests pass and the EA administrator has verified the role, enrollment, and policies, perform one creation using a designated test enrollment account, if available. There is no API sandbox mode here: the following command creates a real subscription.

```powershell
$created = .\New-EASubscriptionCrossTenant.v2.ps1 @p -Mode CreateAndAccept
$created | Format-List
```

Expected: `Result = Succeeded`, `SubscriptionState = Enabled`, and correct tenant and subscription IDs. Then independently verify:

- In the destination tenant, the subscription is visible and the expected principal holds Owner; an authorized administrator can check IAM.
- In source EA Cost Management + Billing, the subscription appears under the expected enrollment account. The output's `RequestedBillingScope` is the requested scope, not independent verification of the billing backend. Portal visibility may require propagation.
- The script deployed no application resources. Any organizational automation triggered by the new subscription is external to the script.

The script also automatically verifies the actual tenant through `GET /subscriptions/{id}`, in addition to acceptance status. Observing HTTP 202 is insufficient.

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
| Guest/user context rejected | Use the service principals required by v2; do not elevate the guest user's roles to try to bypass the restriction. |
| Source application not registered in EATenantId | Correct the source tenant/application; changing the tenant in the context is insufficient. |
| HTTP 401/403 during checks | Check identity, audience, permissions, and policies. Do not treat it as partial success. |
| Interrupted PUT/POST or timeout | The operation may have been accepted. Retain alias and subscription ID; wait and use Verify/Resume on the same alias. |
| Resume: alias absent | Check tenant, identity, and portal state; do not immediately create a different alias. |
| Request expired | Inspect the request and agree on recovery with the administrator; the script does not automatically recreate it. |
| Verify: NotCompleted | State is readable but the process is incomplete; inspect the request and use Resume if appropriate. |
| Final state not Enabled | The subscription exists but fails the acceptance criterion; investigate its state. |

No rollback is implemented. Do not run concurrent processes on the same alias. After testing, the Account Owner can cancel the test subscription according to organizational procedures; the script does not cancel it. Timeouts are polling deadlines, not absolute limits on authentication or individual HTTP call duration.

## Documentary Evidence for Commands and APIs

| Actual command/API | Official source | Verified contract and limitation |
| --- | --- | --- |
| `Connect-AzAccount -ServicePrincipal -Tenant -ApplicationId -CertificatePath -CertificatePassword -ContextName -SkipContextPopulation -Scope` | [Connect-AzAccount][D13] | Authentication and separate contexts; selecting a tenant alone does not prove the application's home tenant. |
| `Disable-AzContextAutosave -Scope Process` | [Disable-AzContextAutosave][D14] | Prevents automatic saving of session contexts. |
| `Get-AzAccessToken -ResourceUrl -TenantId -DefaultProfile -AsSecureString` | [Get-AzAccessToken][D10] | Separate tokens per tenant and audience; tokens remain SecureString. |
| `Invoke-WebRequest -Authentication Bearer -Token -SkipHttpErrorCheck` | [Invoke-WebRequest][D11] | HTTPS transport and explicit status/header reads; does not validate the response's application-level meaning. |
| `GET /v1.0/servicePrincipals(appId='...')?$select=...` | [Get servicePrincipal][D8], [resource properties][D9] | Self-read of the principal and registration tenant through `appOwnerOrganizationId`. |
| `PUT /providers/Microsoft.Subscription/aliases/{alias}?api-version=2021-10-01` | [EA automation][D2], [Alias Create][D4] | `billingScope`, `displayName`, `workload`, `additionalProperties.subscriptionTenantId`, and `subscriptionOwnerId`. |
| `GET` of the same alias | [Alias Get][D5] | Flat response properties, including owner, billing scope, ID, and states. No `additionalProperties` in the response schema. |
| `POST /providers/Microsoft.Subscription/subscriptions/{id}/acceptOwnership?api-version=2021-10-01` | [Accept Ownership][D6] | Destination acceptance; body includes `properties.displayName`; HTTP 202 is asynchronous. |
| `GET .../acceptOwnershipStatus?api-version=2021-10-01` | [Accept Ownership Status][D7] | `acceptOwnershipState`, `provisioningState`, `subscriptionTenantId`, and `subscriptionId`. |
| `GET /subscriptions/{id}?api-version=2022-12-01` | [Subscriptions Get][D12] | Independent checks of `tenantId`, `subscriptionId`, and `state`. |
| `ConvertTo-Json` / `ConvertFrom-Json -AsHashtable` | [ConvertTo-Json][D15], [ConvertFrom-Json][D16] | Request serialization and response parsing. |
| `SupportsShouldProcess` / `ShouldProcess` / `-WhatIf` | [ShouldProcess][D17] | Action control; offline behavior is implemented by the script. |
| `Parser.ParseFile`, `Invoke-Pester`, `Mock`, `Should -Invoke` | [PowerShell Parser][D18], [Pester v5][D19], [Mock][D20] | Syntax and local tests; mocks do not exercise the Azure service. |

API `2021-10-01` is used by the consulted Microsoft EA creation guide: an old date in a version number does not automatically mean the API is obsolete. It is not replaced with an invented version or an unverified preview contract.

## Evidence to Retain After Acceptance Testing

Retain `pester-results.xml`, `$PSVersionTable`, the actual `Az.Accounts` version, script version/hash, alias, subscription ID, expected/actual tenant, and billing/IAM checks. Do not store tokens, PFX passwords, or private keys in reports. Do not publish a "tested" outcome before collecting real results.

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
