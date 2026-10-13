#requires -Version 7.4
#requires -Modules @{ ModuleName = 'Az.Accounts'; ModuleVersion = '5.3.1' }
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SubscriptionName,
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?$')] [string] $AliasName,
    [ValidateSet('Production', 'DevTest')] [string] $Workload = 'Production',
    [ValidateSet('Validate', 'CreateAndAccept', 'Verify', 'Resume')] [string] $Mode = 'Validate',
    [ValidateRange(1, 120)] [int] $TimeoutMinutes = 20
)
$ErrorActionPreference = 'Stop'
$VerbosePreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'
$cloudSettings = Get-AutomationVariable -Name 'EA-Configuration'
if ($cloudSettings -is [string]) { $cloudSettings = ConvertFrom-Json $cloudSettings -AsHashtable }
foreach ($key in @('eaTenantId', 'targetTenantId', 'sourceApplicationId', 'targetApplicationId', 'targetOwnerObjectId')) {
    if ([guid]$cloudSettings[$key] -eq [guid]::Empty) { throw "Invalid configuration field: $key" }
}
if ([guid]$cloudSettings.eaTenantId -eq [guid]$cloudSettings.targetTenantId) { throw 'Source and destination tenants must differ.' }
foreach ($key in @('billingAccountId', 'enrollmentAccountId')) {
    if ([string]$cloudSettings[$key] -notmatch '^[0-9]+$') { throw "Invalid configuration field: $key" }
}
$containerEndpoint = [uri]$cloudSettings.requestContainerUri
if ($containerEndpoint.Scheme -ne 'https' -or $containerEndpoint.Port -ne 443 -or $containerEndpoint.UserInfo -or
    $containerEndpoint.Host -notmatch '^[a-z0-9]{3,24}\.blob\.core\.windows\.net$' -or
    $containerEndpoint.AbsolutePath -ne '/requests' -or $containerEndpoint.Query -or $containerEndpoint.Fragment) {
    throw 'Invalid request storage endpoint.'
}
if ([string]::IsNullOrWhiteSpace($SubscriptionName)) { throw 'SubscriptionName must not be blank.' }
Disable-AzContextAutosave -Scope Process | Out-Null
$cloudContextSuffix = [guid]::NewGuid().ToString('N')
$storageLogin = (Connect-AzAccount -Identity -Tenant $cloudSettings.eaTenantId `
    -ContextName "ea-storage-$cloudContextSuffix" -SkipContextPopulation -Scope Process).Context
$cloudLeaseId = $null
$cloudLeaseOwned = $false
$cloudTempRoot = Join-Path ([IO.Path]::GetTempPath()) ('ea-' + [guid]::NewGuid().ToString('N'))
$cloudBlobUri = $cloudSettings.requestContainerUri.TrimEnd('/') + '/' + $AliasName.ToLowerInvariant() + '.json'

function Invoke-RequestStorage {
    param([string]$Method, [string]$Query = '', [hashtable]$Headers = @{}, [string]$Body,
          [int[]]$ExpectedStatus = @(200))
    $storageToken = Get-AzAccessToken -ResourceUrl 'https://storage.azure.com/' `
        -TenantId $cloudSettings.eaTenantId -DefaultProfile $storageLogin -AsSecureString
    if ($storageToken.Token -isnot [securestring]) { throw 'Storage token must be SecureString.' }
    $storageHeaders = @{
        'x-ms-version' = '2023-11-03'
        'x-ms-date' = [datetime]::UtcNow.ToString('R', [cultureinfo]::InvariantCulture)
    }
    foreach ($key in $Headers.Keys) { $storageHeaders[$key] = $Headers[$key] }
    $storageRequest = @{
        Uri = $cloudBlobUri + $Query; Method = $Method; Headers = $storageHeaders
        Authentication = 'Bearer'; Token = $storageToken.Token; SkipHttpErrorCheck = $true
        MaximumRedirection = 0; TimeoutSec = 60; Verbose = $false; Debug = $false
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $storageRequest.Body = [Text.Encoding]::UTF8.GetBytes($Body)
        $storageRequest.ContentType = 'application/json; charset=utf-8'
    }
    $storageResponse = Invoke-WebRequest @storageRequest
    if ([int]$storageResponse.StatusCode -notin $ExpectedStatus) {
        throw "Request storage returned HTTP $($storageResponse.StatusCode). Inspect alias '$AliasName' and its lease."
    }
    return $storageResponse
}

function Save-RequestRecord {
    param([hashtable]$Record)
    $Record.updatedAt = [datetime]::UtcNow.ToString('o')
    $null = Invoke-RequestStorage -Method PUT -Headers @{
        'x-ms-blob-type' = 'BlockBlob'; 'x-ms-lease-id' = $cloudLeaseId
    } -Body (ConvertTo-Json $Record -Depth 20 -Compress) -ExpectedStatus @(201)
}

function Connect-CertificatePrincipal {
    param([object]$Certificate, [string]$TenantId, [string]$ApplicationId, [string]$Label)
    $ephemeralPassword = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    $protectedPassword = ConvertTo-SecureString $ephemeralPassword -AsPlainText -Force
    $encryptedPfx = $Certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12, $ephemeralPassword)
    $ephemeralPath = Join-Path $cloudTempRoot ($Label + '.pfx')
    try {
        [IO.File]::WriteAllBytes($ephemeralPath, $encryptedPfx)
        return (Connect-AzAccount -ServicePrincipal -Tenant $TenantId -ApplicationId $ApplicationId `
            -CertificatePath $ephemeralPath -CertificatePassword $protectedPassword `
            -ContextName "ea-$Label-$cloudContextSuffix" -SkipContextPopulation -Scope Process).Context
    } finally {
        if (Test-Path -LiteralPath $ephemeralPath) { Remove-Item -LiteralPath $ephemeralPath -Force }
        [Array]::Clear($encryptedPfx, 0, $encryptedPfx.Length)
        $protectedPassword.Dispose()
        $ephemeralPassword = $null
    }
}

try {
    $sourceCertificate = Get-AutomationCertificate -Name $cloudSettings.sourceCertificateAssetName
    $targetCertificate = Get-AutomationCertificate -Name $cloudSettings.targetCertificateAssetName
    foreach ($certificate in @($sourceCertificate, $targetCertificate)) {
        if ($null -eq $certificate -or -not $certificate.HasPrivateKey -or
            $certificate.NotBefore.ToUniversalTime() -gt [datetime]::UtcNow -or
            $certificate.NotAfter.ToUniversalTime() -le [datetime]::UtcNow) {
            throw 'Both certificate assets must have private keys and be currently valid.'
        }
    }
    $null = [IO.Directory]::CreateDirectory($cloudTempRoot)
    $sourceLogin = Connect-CertificatePrincipal $sourceCertificate $cloudSettings.eaTenantId $cloudSettings.sourceApplicationId 'source'
    $targetLogin = Connect-CertificatePrincipal $targetCertificate $cloudSettings.targetTenantId $cloudSettings.targetApplicationId 'target'
    $requestFields = [ordered]@{
        aliasName = $AliasName.ToLowerInvariant(); subscriptionName = $SubscriptionName; workload = $Workload
        eaTenantId = ([guid]$cloudSettings.eaTenantId).ToString()
        targetTenantId = ([guid]$cloudSettings.targetTenantId).ToString()
        sourceApplicationId = ([guid]$cloudSettings.sourceApplicationId).ToString()
        targetApplicationId = ([guid]$cloudSettings.targetApplicationId).ToString()
        targetOwnerObjectId = ([guid]$cloudSettings.targetOwnerObjectId).ToString()
        billingAccountId = [string]$cloudSettings.billingAccountId
        enrollmentAccountId = [string]$cloudSettings.enrollmentAccountId
    }
    $requestJson = ConvertTo-Json $requestFields -Compress
    $requestHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($requestJson)))
    $stored = Invoke-RequestStorage -Method GET -ExpectedStatus @(200, 404)
    $requestRecord = $null
    if ([int]$stored.StatusCode -eq 200) {
        $requestRecord = ConvertFrom-Json $stored.Content -AsHashtable
        if ($requestRecord.requestHash -isnot [string] -or $requestRecord.requestHash -cne $requestHash) {
            throw 'Stored request does not match these inputs. Keep the original configuration and alias.'
        }
    }
    if ($Mode -in @('CreateAndAccept', 'Resume')) {
        if ($Mode -eq 'Resume' -and $null -eq $requestRecord) { throw 'Resume requires a stored request.' }
        if ($null -eq $requestRecord) {
            $initialRecord = @{
                schemaVersion = 1; requestHash = $requestHash; request = $requestFields
                state = 'Prepared'; createdAt = [datetime]::UtcNow.ToString('o')
            }
            $null = Invoke-RequestStorage -Method PUT -Headers @{
                'If-None-Match' = '*'; 'x-ms-blob-type' = 'BlockBlob'
            } -Body (ConvertTo-Json $initialRecord -Depth 20 -Compress) -ExpectedStatus @(201, 412)
        }
        $candidateLeaseId = [guid]::NewGuid().ToString()
        $null = Invoke-RequestStorage -Method PUT -Query '?comp=lease' -Headers @{
            'x-ms-lease-action' = 'acquire'; 'x-ms-lease-duration' = '-1'; 'x-ms-proposed-lease-id' = $candidateLeaseId
        } -Body '' -ExpectedStatus @(201)
        $cloudLeaseId = $candidateLeaseId
        $cloudLeaseOwned = $true
        $stored = Invoke-RequestStorage -Method GET
        $requestRecord = ConvertFrom-Json $stored.Content -AsHashtable
        if ($requestRecord.requestHash -cne $requestHash) { throw 'Request inputs changed while acquiring the lock.' }
        if ($Mode -eq 'CreateAndAccept' -and $requestRecord.state -ne 'Prepared') {
            throw 'Creation has already been attempted. Inspect with Verify, then use Resume when approved.'
        }
        $requestRecord.state = 'Running'
        $requestRecord.mode = $Mode
        Save-RequestRecord $requestRecord
    }
    $engineParameters = @{
        SourceContext = $sourceLogin; TargetContext = $targetLogin
        EATenantId = $cloudSettings.eaTenantId; TargetTenantId = $cloudSettings.targetTenantId
        TargetOwnerObjectId = $cloudSettings.targetOwnerObjectId
        BillingAccountId = $cloudSettings.billingAccountId; EnrollmentAccountId = $cloudSettings.enrollmentAccountId
        SubscriptionName = $SubscriptionName; AliasName = $AliasName; Workload = $Workload
        Mode = $Mode; TimeoutMinutes = $TimeoutMinutes
    }
    $engineResult = & {
        __EA_ENGINE__
    } @engineParameters -Confirm:$false
    if ($cloudLeaseOwned) {
        $requestRecord.state = [string]$engineResult.Result
        $requestRecord.result = $engineResult
        Save-RequestRecord $requestRecord
    }
    $engineResult
} catch {
    if ($cloudLeaseOwned -and $null -ne $requestRecord) {
        $requestRecord.state = 'NeedsReview'
        try { Save-RequestRecord $requestRecord } catch { Write-Warning 'Could not persist recovery status; inspect the stored record and Azure alias.' }
    }
    throw
} finally {
    if ($cloudLeaseOwned) {
        try {
            $null = Invoke-RequestStorage -Method PUT -Query '?comp=lease' -Headers @{
                'x-ms-lease-action' = 'release'; 'x-ms-lease-id' = $cloudLeaseId
            } -Body '' -ExpectedStatus @(200)
        } catch { Write-Warning 'Request lease remains held. Stop all jobs for this alias before administrative lease recovery.' }
    }
    if (Test-Path -LiteralPath $cloudTempRoot) { Remove-Item -LiteralPath $cloudTempRoot -Recurse -Force }
}