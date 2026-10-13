#requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $OutputPath = (Join-Path $PSScriptRoot 'build/New-EASubscription.ps1'),
    [switch] $Publish,
    [string] $RunbookResourceId
)
$ErrorActionPreference = 'Stop'
$template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'automation/Runbook.template.ps1'))
$engine = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'New-EASubscription.ps1'))
$engineTokens = $null
$engineErrors = $null
$engineAst = [Management.Automation.Language.Parser]::ParseInput($engine, [ref]$engineTokens, [ref]$engineErrors)
if ($engineErrors.Count -or $null -eq $engineAst.ParamBlock) { throw 'Engine source is invalid.' }
$engineStart = $engineAst.ParamBlock.Extent.StartOffset
foreach ($attribute in $engineAst.ParamBlock.Attributes) {
    $engineStart = [math]::Min($engineStart, $attribute.Extent.StartOffset)
}
$engine = $engine.Substring($engineStart)
if ([regex]::Matches($template, '__EA_ENGINE__').Count -ne 1) { throw 'Template must have exactly one engine marker.' }
$artifact = $template.Replace('__EA_ENGINE__', $engine)
$parseTokens = $null
$parseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseInput($artifact, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
if ($Publish -and $RunbookResourceId -notmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Automation/automationAccounts/[^/]+/runbooks/[A-Za-z][A-Za-z0-9_-]*$') {
    throw 'Publish requires the exact runbook resource ID returned by Bicep.'
}
if (-not $PSCmdlet.ShouldProcess($OutputPath, 'Build standalone Automation runbook')) { return }
$fullPath = [IO.Path]::GetFullPath($OutputPath)
$null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath))
[IO.File]::WriteAllText($fullPath, $artifact, [Text.UTF8Encoding]::new($false))
$artifactHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
Write-Information "Built runbook: $fullPath; SHA256: $artifactHash" -InformationAction Continue
function Read-RunbookText {
    param($Response)
    $text = if ($Response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($Response.Content) } else { [string]$Response.Content }
    if ([string]$Response.Headers['Content-Type'] -match 'application/json') {
        $text = ConvertFrom-Json $text
        if ($text -isnot [string]) { throw 'Runbook content response must contain text.' }
    }
    return ($text -replace "`r`n", "`n")
}
if ($Publish) {
    Import-Module Az.Accounts -MinimumVersion 5.3.1
    $publishingContext = Get-AzContext
    if ($null -eq $publishingContext -or $publishingContext.Environment.Name -ne 'AzureCloud' -or
        $RunbookResourceId.Split('/')[2] -ine $publishingContext.Subscription.Id) {
        throw 'Sign in to the management subscription before publishing.'
    }
    if (-not $PSCmdlet.ShouldProcess($RunbookResourceId, 'Replace draft and publish the built runbook')) { return }
    $publishingToken = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/' `
        -DefaultProfile $publishingContext -AsSecureString
    if ($publishingToken.Token -isnot [securestring]) { throw 'Publishing token must be SecureString.' }
    $upload = Invoke-WebRequest -Uri "https://management.azure.com$RunbookResourceId/draft/content?api-version=2024-10-23" `
        -Method PUT -Authentication Bearer -Token $publishingToken.Token -ContentType 'text/plain; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($artifact)) -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 60
    if ([int]$upload.StatusCode -notin @(200, 201, 202)) { throw "Draft upload returned HTTP $($upload.StatusCode)." }
    $draftReady = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $draft = Invoke-WebRequest -Uri "https://management.azure.com$RunbookResourceId/draft/content?api-version=2024-10-23" `
            -Headers @{ Accept = 'text/plain' } -Authentication Bearer -Token $publishingToken.Token `
            -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 60
        if ([int]$draft.StatusCode -eq 200 -and (Read-RunbookText $draft) -ceq ($artifact -replace "`r`n", "`n")) {
            $draftReady = $true
            break
        }
        if ([int]$draft.StatusCode -notin @(200, 404, 409)) { throw "Draft verification returned HTTP $($draft.StatusCode)." }
        Start-Sleep -Seconds 2
    }
    if (-not $draftReady) { throw 'Draft content is not verified. Inspect the upload before publishing.' }
    $publication = Invoke-WebRequest -Uri "https://management.azure.com$RunbookResourceId/publish?api-version=2024-10-23" `
        -Method POST -Authentication Bearer -Token $publishingToken.Token -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 60
    if ([int]$publication.StatusCode -notin @(200, 202)) { throw "Publish returned HTTP $($publication.StatusCode)." }
    $published = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $read = Invoke-WebRequest -Uri "https://management.azure.com${RunbookResourceId}?api-version=2024-10-23" `
            -Authentication Bearer -Token $publishingToken.Token -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 60
        if ([int]$read.StatusCode -ne 200) { throw "Runbook verification returned HTTP $($read.StatusCode)." }
        $metadata = ConvertFrom-Json $read.Content
        if ($metadata.properties.state -eq 'Published') { $published = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $published) { throw 'Publication still pending. Inspect the runbook before invoking it.' }
    $content = Invoke-WebRequest -Uri "https://management.azure.com$RunbookResourceId/content?api-version=2024-10-23" `
        -Headers @{ Accept = 'text/plain' } -Authentication Bearer -Token $publishingToken.Token -MaximumRedirection 0 -TimeoutSec 60
    if ((Read-RunbookText $content) -cne ($artifact -replace "`r`n", "`n")) {
        throw 'Published content does not match the local artifact.'
    }
}
[pscustomobject]@{ ArtifactPath = $fullPath; SHA256 = $artifactHash; Published = [bool]$Publish }