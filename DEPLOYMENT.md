# Deploy and Operate

Deploy into an existing management resource group in the source tenant. The solution uses the native Azure Automation Start form, one Storage account, and two certificate assets.

## Prepare

- Use PowerShell 7.4+, Bicep CLI 0.42.1+, Az.Accounts 5.3.1+, and Az.Resources. Follow organizational signing policy.
- Register the source application in its home tenant and the destination application in the final tenant. Have the EA administrator assign source billing `SubscriptionCreator`, role ID `a0bcee42-bf30-4d1b-926a-48d21664ef71`, on the selected enrollment account using [EA role guidance](https://learn.microsoft.com/azure/cost-management-billing/manage/assign-roles-azure-service-principals).
- Use the destination Enterprise application's Object ID as `targetOwnerObjectId`. Register the corresponding public certificates on both applications; verify enrollment status, creation limits, and both tenants' policies. `DevTest` requires the enabled EA offer.
- Use a deployer authorized to create resources and role assignments in the management resource group. The management subscription's tenant must match `eaTenantId`.
- Check regional availability of Automation PowerShell 7.4 runtime environments and the Storage SKU. Azure Policy must allow the authenticated public Storage endpoint used by the cloud sandbox. Mandatory private networking requires a Hybrid Worker design.
- Budget for Automation execution minutes and Storage capacity, transactions, and retained versions. This deployment creates no billable EA subscription; that operation starts when an operator selects `CreateAndAccept`.

## Deploy Infrastructure

Create a local parameter file from [infra/main.bicepparam](infra/main.bicepparam) and replace every synthetic identity and billing ID. Local parameter files and build output are excluded from Git.

```powershell
Copy-Item ./infra/main.bicepparam ./infra/main.local.bicepparam
New-Item -ItemType Directory -Path build -Force | Out-Null
bicep build infra/main.bicep --outfile build/main.json
bicep build-params infra/main.local.bicepparam --outfile build/main.local.parameters.json

Connect-AzAccount -Tenant '<SOURCE-TENANT-ID>' -Subscription '<MANAGEMENT-SUBSCRIPTION-ID>'

$deploymentParameters = @{
    ResourceGroupName = '<EXISTING-MANAGEMENT-RESOURCE-GROUP>'
    TemplateFile = './build/main.json'
    TemplateParameterFile = './build/main.local.parameters.json'
}
Get-AzResourceGroupDeploymentWhatIfResult @deploymentParameters
$deployment = New-AzResourceGroupDeployment @deploymentParameters -Name 'ea-automation' -Mode Incremental
$deployment.Outputs
```

Review the what-if result before deployment. Bicep creates the Automation Account with system-assigned identity, a PowerShell 7.4 runtime and Az.Accounts 5.3.1 package, the `EA-Configuration` variable, a draft runbook, and a private Blob container. The identity receives Storage Blob Data Contributor at container scope. HTTPS, TLS 1.2, infrastructure encryption, versioning, and 30-day soft deletion are enabled. Shared keys and anonymous access are disabled.

The Automation Account uses the pinned Azure Verified Module. Storage is declared directly so deployment outputs contain only resource identifiers and asset names.

## Configure Certificates and Access

1. In **Automation Account → Certificates**, upload the source and destination private-key PFX certificates using the asset names returned by Bicep. Mark them exportable for the runbook's certificate-path sign-in. Keep passwords in the approved credential-handling process.
2. Verify certificate validity, matching public registrations, and the provider requirements in [Automation certificate guidance](https://learn.microsoft.com/azure/automation/shared-resources/certificates). Assign renewal and expiry-monitoring owners.
3. Confirm the runtime's Az.Accounts package provisioning is `Succeeded` and allow RBAC propagation.
4. Grant operators **Automation Job Operator** on the dedicated account and **Automation Runbook Operator** on this runbook, following [Automation RBAC guidance](https://learn.microsoft.com/azure/automation/automation-role-based-access-control). Verify effective permissions; maintain code and credential administration separately.

The runbook retrieves protected assets, exports a short-lived password-encrypted PFX for sign-in, and removes it in `finally`. An abrupt worker termination may leave that encrypted temporary file until sandbox cleanup. Keep privileged access to Automation tightly controlled.

## Publish the Runbook

```powershell
# Build locally with no Azure calls.
./Publish-EAAutomationRunbook.ps1

# Upload and publish the exact built artifact in the signed-in management subscription.
./Publish-EAAutomationRunbook.ps1 -Publish `
    -RunbookResourceId $deployment.Outputs.runbookResourceId.Value
```

The publisher embeds [New-EASubscription.ps1](New-EASubscription.ps1) in `build/New-EASubscription.ps1`, verifies draft content, publishes it, and compares the published content with the local artifact. Retain its SHA256. Publish through an approved change process after offline tests pass. Importing the template directly leaves the engine marker unresolved; use the generated artifact.

## Start a Request

Open **Automation Account → Runbooks → New-EASubscription → Start**. Enter `SubscriptionName`, a stable `AliasName`, `Workload`, and `Mode`. The default mode is `Validate`.

1. Run `Validate` to check credentials, identities, and read access to request storage.
2. Approve a real creation and run `CreateAndAccept` with the same inputs.
3. Review the job result, verify destination IAM, and confirm the enrollment account in source EA Cost Management + Billing.

Keep administrator-controlled tenant, application, billing, and certificate settings in `EA-Configuration`. Each request stores their fingerprint; changing these settings can block recovery of an older request. Retain the original configuration through its completion.

## Recover a Request

| Condition | Action |
| --- | --- |
| Timeout or interrupted write | Run `Verify` with the original inputs. Inspect Azure state before an approved `Resume`. |
| `NeedsReview` | Creation replay is blocked. Resolve the uncertain remote operation before resuming. |
| Lease conflict (`409`) | Check for an active job on the same alias. Wait for it to finish. |
| Worker stopped with a held lease | Run read-only `Verify`; stop every job for the alias. A storage administrator can select **Break lease** on `requests/<lowercase-alias>.json`. Inspect Azure state before `Resume`. |
| Stored inputs differ | Restore the original configuration and request parameters. |
| Alias absent after an uncertain write | Diagnose with the EA administrator before any new creation. |

Infinite-duration leases prevent another writer from taking over a paused or stopped worker. Read-only `Verify` can inspect Azure while the lease is held. Recovery is an explicit operator action through the native form; release a lease only after all earlier jobs are terminal and remote writes have been reviewed.

## Validation

The [Validate workflow](.github/workflows/validate.yml) compiles Bicep and parameters and runs the mocked suite on Windows. It requires a passing result and nonzero executed tests. Local test discovery is currently blocked by unsigned-script policy; use approved signing to run the suite on this machine. Checkov is unavailable locally; compiled-template tests check key authentication, anonymous access, HTTPS/TLS, encryption, role scope, and runbook linkage. Customer Azure Policy and live acceptance remain deployment gates.

## API References

- [Runbook draft content upload](https://learn.microsoft.com/rest/api/automation/runbook-draft/replace-content?view=rest-automation-2024-10-23)
- [Runbook publication](https://learn.microsoft.com/rest/api/automation/runbook/publish?view=rest-automation-2024-10-23)
- [Runtime environments](https://learn.microsoft.com/azure/templates/microsoft.automation/2024-10-23/automationaccounts/runtimeenvironments)
- [Blob leases](https://learn.microsoft.com/rest/api/storageservices/lease-blob)
