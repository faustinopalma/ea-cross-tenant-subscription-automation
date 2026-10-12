# Automated EA Subscription Creation in the Destination Tenant

Technical proposal for CNH | October 10, 2026

**Historical scope:** this document describes the local launcher proposal. The [README](README.md) now defines Azure Automation as the target hosting architecture and distinguishes implemented components from the cloud work still required.

## Recommendation

Adopt a process started with a single command that requests a new subscription under the selected Enterprise Agreement (EA), specifies the destination tenant during creation, and automatically accepts ownership using an identity in the destination tenant.

The recommended solution uses two service principals, one in each tenant, with noninteractive certificate-based authentication. Administrators prepare identities, permissions, and credentials once. The operator then starts the process without manual sign-ins or portal-based acceptance.

**The requested outcome remains unchanged:** a new subscription in the destination tenant, billed to the selected EA enrollment account. The authentication method changes: application identities perform the operation instead of the user's interactive sign-in.

## Why This Approach

The business requirement concerns the final outcome, not a temporary association of the subscription with the source tenant. Microsoft APIs allow the final tenant to be specified in the creation request. There is therefore no need to finish creating a subscription in the source tenant and subsequently change its directory.

This approach avoids a separate migration and its effects on role assignments and resource identities. It does not require private portal endpoints or browser automation.

EA documentation describes the cross-tenant flow using a token obtained from the source service principal's home tenant and a destination-tenant token for acceptance. These are two separately authorized operations orchestrated within a single execution.

For the original requirement, the same user in the source tenant and a guest in the destination tenant, no fully automated, supported route was identified in the public references consulted. Creation-flow documentation excludes guests from destination-owner selection. Changing the directory of an existing subscription, however, allows a user present in both tenants, but the consulted procedure is documented through the portal.

The justification is therefore: **to achieve the outcome without manual intervention, we adopt the documented cross-tenant flow using application identities**. This does not claim that Azure always requires two separate applications or that no other route could exist.

## Operational Flow

1. The process checks both certificates and authenticates both service principals before attempting creation.
2. Using the source identity, it checks the context and request alias, then submits the EA request specifying the destination `subscriptionTenantId` and `subscriptionOwnerId`.
3. It waits for the request to expose the subscription ID and for ownership status to become readable in the destination tenant.
4. Using the destination identity, it accepts ownership if acceptance is still required.
5. It waits for completion and reads the actual subscription in the destination tenant, checking its ID, tenant, and `Enabled` state.

An HTTP `202 Accepted` response means only that acceptance is being processed: it does not establish final success. A single command does not mean instant execution; authorization and state propagation may take time.

Billing remains associated with the request's EA enrollment account. The process does not transfer billing ownership to a new agreement.

## Minimum Requirements

| Requirement | Rationale and boundary |
| --- | --- |
| Source service principal | Application registered in its home tenant; EA billing role `SubscriptionCreator` on the selected enrollment account only. Owner or Contributor on an existing subscription is insufficient. |
| Destination service principal | Identity that can authenticate in the final tenant, whose local Object ID is specified as the new owner. Owner on the new subscription is the outcome, not a role to grant beforehand at the tenant root. |
| Noninteractive credentials | In the current launcher: two valid certificates registered on the applications, with private keys available to the execution identity in the Windows certificate store. Having the principals alone is insufficient. |
| Nonsecret configuration | Tenant IDs, Client IDs, destination Object ID, certificate thumbprints, billing account, and enrollment account. Name and alias identify each request. |
| Service conditions | Active enrollment, creation limits respected, and compatible policies in both tenants or appropriate exemptions. `DevTest` requires the EA offer to be enabled. |
| Execution environment | For the implemented launcher: Windows, PowerShell 7.2 or later, Az.Accounts 5.3.1 or later, and scripts executable under organizational policy. |

An authorized administrator assigns the EA `SubscriptionCreator` role, ID `a0bcee42-bf30-4d1b-926a-48d21664ef71`, once at the correct billing scope. The assignment must be verified through the documented billing APIs; inspecting subscription IAM alone is insufficient.

`TargetOwnerObjectId` must be the Object ID of the Enterprise application in the destination tenant. It is neither the Client ID nor the Object ID of the app registration.

The minimum flow does not add requirements for Global Administrator during execution, Owner at the destination tenant root, or broad Graph permissions to read the entire directory. Administrators performing preparation still need the permissions required for their specific setup operations.

## Security Choices

Two separate applications keep the authority to create subscriptions under the EA separate from the authority to accept ownership in the final tenant. This is a straightforward configuration and verification choice, not a universal platform constraint: a multitenant application with a principal in each tenant is an alternative, but introduces consent management unnecessary for the baseline scenario.

Certificates avoid passwords requested on each execution and client secrets embedded in configuration files. Private-key access must be limited to authorized operators; expiration and renewal must have an accountable owner. Thumbprints and IDs are not credentials.

Anyone who can use both keys and start the process can exercise both principals' permissions. Operator controls therefore also depend on access to the execution system and keys, not on the guest user's previous roles.

The destination principal becomes the subscription Owner. The user starting the command does not automatically receive access. If a team must receive the subscription, agree on a group in the final tenant and the required role; that assignment is an explicit extension, not included in the current launcher.

## Simplicity and Reliability

The operational interface should be short; checks that prevent duplicates or false success must remain in the execution engine.

The recommendation therefore uses [New-EASubscriptionCrossTenant.OneTouch.ps1](New-EASubscriptionCrossTenant.OneTouch.ps1), which handles sign-ins and calls [New-EASubscriptionCrossTenant.v2.ps1](New-EASubscriptionCrossTenant.v2.ps1). Version 2 retains identity checks, existing-request verification, state polling, and the final read. There is no need to duplicate this logic in the launcher.

The official `Az.Subscription` module provides creation and acceptance commands and could reduce transport code in a future version. Replacing the engine is not necessary to achieve a single invocation: a rewrite would require new tests for polling, errors, and context separation. Those cmdlets also document `DefaultProfile` as nonfunctional; two contexts cannot simply be supplied with the assumption that they will be used correctly.

A new web application, Azure service, pipeline, or Terraform is not required to satisfy the current requirement. A pipeline can be introduced later for operator controls and retained results if this becomes a business requirement.

## Errors and Recovery

Each request must have a stable alias retained with its parameters. The subscription display name does not guarantee uniqueness. Run only one process per alias: the launcher does not implement distributed coordination between operators.

If a write has an uncertain outcome or local polling times out, do not generate a new alias or automatically repeat creation. Azure may already have accepted the request. First inspect the state with `Verify`, then use `Resume` to continue an existing request. `Resume` does not create a new subscription.

A `403` error is not interpreted as an absent request. If the alias remains absent or unreadable after an uncertain error, diagnose before acting. There is no single transaction spanning creation and acceptance, and no automatic rollback through cancellation.

The v2 timeout applies to the flow after sign-in, not to the launcher's entire execution time. A local timeout does not cancel an operation already started in the service.

## Acceptance Criteria

Before operational use, the following criteria must be met:

1. Offline Pester tests verify the launcher and engine without real sign-ins or Azure calls, with more than zero tests executed and no discovery errors.
2. An authorized acceptance test creates one real subscription and confirms the expected tenant and `Enabled` state through a final read.
3. IAM confirms the expected destination Owner; any team access is verified separately.
4. Cost Management + Billing confirms association with the specific EA enrollment account. The script's `RequestedBillingScope` output is the requested scope, not independent verification of the billing backend.
5. Reading and resuming the same request does not generate a second subscription.

**Current status:** launcher implemented, tests prepared, parser and static checks passed. Pester execution was blocked by the local policy for unsigned files; that policy was not bypassed and no runtime test is claimed to have passed. No Azure sign-ins or live acceptance tests were performed. The solution is not yet certified for the CNH environment.

Operational details and results are collected in [TESTING-AND-EVIDENCE.md](TESTING-AND-EVIDENCE.md); the suite is in [New-EASubscriptionCrossTenant.v2.Tests.ps1](New-EASubscriptionCrossTenant.v2.Tests.ps1).

## Public Precedents

[midpcld/subvending](https://github.com/midpcld/subvending) publishes a script and pipeline using two identities, alias creation, and acceptance in the final tenant. The project targets MCA, not EA: it demonstrates an implementation of the pattern, not a certified EA solution. The consulted code generates new aliases on each execution and reports success after the POST without the final verification adopted here.

Microsoft's [azcapman - Enterprise Agreement](https://microsoft.github.io/azcapman/billing/legacy/README.html) guide discusses cross-tenant provisioning and the dedicated EA role. Precedents are useful comparisons; service documentation remains authoritative for requests and permissions.

## Microsoft Sources

- [Programmatic EA creation, including the cross-tenant flow](https://learn.microsoft.com/azure/cost-management-billing/manage/programmatically-create-subscription-enterprise-agreement).
- [EA roles for service principals and their scope](https://learn.microsoft.com/azure/cost-management-billing/manage/assign-roles-azure-service-principals).
- [EA creation for users, home directory, and destination owners](https://learn.microsoft.com/azure/cost-management-billing/manage/create-enterprise-subscription).
- [Alias - Create, API 2021-10-01](https://learn.microsoft.com/rest/api/subscription/alias/create?view=rest-subscription-2021-10-01).
- [Accept Ownership, asynchronous processing](https://learn.microsoft.com/rest/api/subscription/subscription/accept-ownership?view=rest-subscription-2021-10-01).
- [Noninteractive PowerShell certificate authentication](https://learn.microsoft.com/powershell/azure/authenticate-noninteractive#login-with-a-service-principal).
- [Changing the directory of an existing subscription](https://learn.microsoft.com/entra/fundamentals/how-subscriptions-associated-directory).

## Proposed Decision

Approve two application identities and noninteractive credentials as one-time prerequisites; retain direct creation in the final tenant and original EA billing. First authorize offline testing under organizational policy, then one controlled live creation. Operational adoption follows only after the acceptance criteria have been met.
