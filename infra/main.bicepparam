using './main.bicep'

param location = 'westeurope'
param automationAccountName = 'ea-subscription-automation'

param configuration = {
  eaTenantId: '11111111-1111-4111-8111-111111111111'
  targetTenantId: '22222222-2222-4222-8222-222222222222'
  sourceApplicationId: '33333333-3333-4333-8333-333333333333'
  targetApplicationId: '44444444-4444-4444-8444-444444444444'
  targetOwnerObjectId: '66666666-6666-4666-8666-666666666666'
  billingAccountId: '1234567'
  enrollmentAccountId: '7654321'
}
