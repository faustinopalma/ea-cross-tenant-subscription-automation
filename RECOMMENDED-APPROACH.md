# Local Pilot Decisions

Use [New-EASubscriptionCrossTenant.OneTouch.ps1](New-EASubscriptionCrossTenant.OneTouch.ps1) for local evaluation. It authenticates both service principals and invokes the [v2 engine](New-EASubscriptionCrossTenant.v2.ps1). The [README](README.md) defines the target Automation architecture and implementation status.

## Design Choices

| Choice | Reason |
| --- | --- |
| Two application identities | Separate EA creation authority from destination ownership acceptance. |
| Certificate authentication | Supports unattended execution with private-key access controlled by the execution environment. |
| Destination tenant in the alias request | Creates the new subscription for its final directory while retaining EA billing. |
| Shared v2 engine | Keeps identity checks, polling, recovery, and final verification in one implementation. |
| Stable request alias | Supports inspection and recovery after an interrupted write. |

Administrators prepare the principals, EA billing role, certificates, and tenant policies. Operators retain the request parameters and enforce one process per alias. Plan destination group access and certificate renewal before operational use.

## Pilot Sequence

Follow [TESTING-AND-EVIDENCE.md](TESTING-AND-EVIDENCE.md) for prerequisites and commands:

1. Run the [mocked tests](New-EASubscriptionCrossTenant.v2.Tests.ps1) under approved execution policy.
2. Run offline `WhatIf`, then read-only `Validate`.
3. Approve one real `CreateAndAccept` run.
4. Verify destination IAM and source EA billing; test `Verify` and `Resume` with the same alias.

## Related Implementations

- [midpcld/subvending](https://github.com/midpcld/subvending): MCA example using two identities and ownership acceptance. It uses a fresh alias per run and reports success after POST; adopting it would require recovery and final-verification changes.
- [azcapman - Enterprise Agreement](https://microsoft.github.io/azcapman/billing/legacy/README.html): EA provisioning and billing-role guidance.

## References

- [Programmatic EA creation, including the cross-tenant flow](https://learn.microsoft.com/azure/cost-management-billing/manage/programmatically-create-subscription-enterprise-agreement).
- [EA roles for service principals and their scope](https://learn.microsoft.com/azure/cost-management-billing/manage/assign-roles-azure-service-principals).
- [EA creation for users, home directory, and destination owners](https://learn.microsoft.com/azure/cost-management-billing/manage/create-enterprise-subscription).
- [Alias - Create, API 2021-10-01](https://learn.microsoft.com/rest/api/subscription/alias/create?view=rest-subscription-2021-10-01).
- [Accept Ownership, asynchronous processing](https://learn.microsoft.com/rest/api/subscription/subscription/accept-ownership?view=rest-subscription-2021-10-01).
- [Noninteractive PowerShell certificate authentication](https://learn.microsoft.com/powershell/azure/authenticate-noninteractive#login-with-a-service-principal).
- [Changing the directory of an existing subscription](https://learn.microsoft.com/entra/fundamentals/how-subscriptions-associated-directory).
