<#
.SYNOPSIS
    Bootstraps the Azure SRE Agent Onboarding Lab by creating a lab-creator agent that then
    deploys the lab for you.

.DESCRIPTION
    Run this once from Azure Cloud Shell (PowerShell). It:

      1. Registers the Microsoft.App resource provider.
      2. Creates the lab-creator resource group and the lab resource group.
      3. Creates the `labcreator-sreagent` SRE Agent.
      4. Adds the egress hosts the agent needs in order to deploy the lab.
      5. Grants that agent's managed identity Owner on the lab resource group.
      6. Pauses while you connect your fork of the sre-agent repo as a code repository.
      7. Starts an agent thread pointing at labs/onboardinglab/agent-deploy-runbook.md.

    The script is re-entrant. Progress is recorded in a state file, so if Cloud Shell times out
    or the browser crashes you can simply run it again and it resumes from the first incomplete
    step. Use -Reset to start over.

    You must run this from a clone of the sre-agent repository: the script deploys
    sreagent-templates/bicep/agent-core.bicep from the repo.

.PARAMETER LabResourceGroup
    Resource group the lab workload is deployed into. Prompted for if not supplied.

.PARAMETER Location
    Region for the agent and the lab. Must support both Azure SRE Agent and PostgreSQL Flexible
    Server. Defaults to swedencentral.

.PARAMETER Reset
    Discard saved progress and run every step again.

.EXAMPLE
    ./bootstrap-labcreator.ps1

.EXAMPLE
    ./bootstrap-labcreator.ps1 -LabResourceGroup MyLabRG -Location uksouth
#>
[CmdletBinding()]
param(
    [string] $Subscription,

    [string] $LabResourceGroup,

    [string] $Location = 'swedencentral',

    [string] $LabCreatorResourceGroup = 'SreAgentLabCreatorRG',

    [string] $LabCreatorAgentName = 'labcreator-sreagent',

    [string] $StateFile = (Join-Path $HOME '.onboardinglab-bootstrap.json'),

    [switch] $Reset
)

$ErrorActionPreference = 'Stop'

# PS 7.3+ mangles native arguments containing '='; Legacy passing keeps az parameters intact.
if ($PSVersionTable.PSVersion.Major -ge 7 -and $PSVersionTable.PSVersion.Minor -ge 3) {
    $PSNativeCommandArgumentPassing = 'Legacy'
}

# Hosts the lab-creator agent must reach to deploy the lab.
#   *.bicep.azure.com     - download the Bicep compiler for --template-file *.bicep
#   *.azurewebsites.net   - smoke-test the deployed checkout app
#   *.azuresre.ai         - push skills/knowledge to the new lab agent's data plane
$RequiredEgressHosts = @(
    '*.bicep.azure.com'
    '*.azurewebsites.net'
    '*.azuresre.ai'
)

$RunbookPath = 'labs/onboardinglab/agent-deploy-runbook.md'

# ── Paths ───────────────────────────────────────────────────────────────────

$labRoot = Split-Path $PSScriptRoot -Parent
$repoRoot = Split-Path (Split-Path $labRoot -Parent) -Parent
$agentCoreBicep = Join-Path $repoRoot 'sreagent-templates/bicep/agent-core.bicep'

# ── Output helpers ──────────────────────────────────────────────────────────

function Write-Step { param([string] $Message) Write-Host "`n== $Message ==" -ForegroundColor Cyan }
function Write-Ok { param([string] $Message) Write-Host "   $Message" -ForegroundColor Green }
function Write-Note { param([string] $Message) Write-Host "   $Message" }

# ── State (re-entrancy) ─────────────────────────────────────────────────────

function Get-State {
    if ($Reset -or -not (Test-Path $StateFile)) { return [ordered]@{} }
    try {
        $raw = Get-Content -Path $StateFile -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return [ordered]@{} }
        $obj = $raw | ConvertFrom-Json
        $table = [ordered]@{}
        foreach ($p in $obj.PSObject.Properties) { $table[$p.Name] = $p.Value }
        return $table
    }
    catch {
        Write-Warning "State file $StateFile is unreadable, starting fresh."
        return [ordered]@{}
    }
}

function Save-State {
    param([Parameter(Mandatory)] $State)
    $State | ConvertTo-Json -Depth 8 | Set-Content -Path $StateFile -NoNewline
}

function Test-StepDone {
    param([Parameter(Mandatory)] $State, [Parameter(Mandatory)][string] $Name)
    return ($State.Contains($Name) -and $State[$Name] -eq $true)
}

function Set-StepDone {
    param([Parameter(Mandatory)] $State, [Parameter(Mandatory)][string] $Name)
    $State[$Name] = $true
    Save-State -State $State
}

# ── az helper ───────────────────────────────────────────────────────────────

function Invoke-Az {
    <#
        Runs az and returns parsed JSON. Throws with az's own stderr on failure so the
        caller sees the real Azure error rather than a generic message.
    #>
    param([Parameter(Mandatory)][string[]] $Arguments, [switch] $AllowEmpty)

    $stdErrFile = [System.IO.Path]::GetTempFileName()
    try {
        $output = & az @Arguments 2> $stdErrFile
        $exit = $LASTEXITCODE
        if ($exit -ne 0) {
            $err = (Get-Content -Path $stdErrFile -Raw)
            throw "az $($Arguments -join ' ') failed (exit $exit).`n$err"
        }
        $joined = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($joined)) {
            if ($AllowEmpty) { return $null }
            throw "az $($Arguments -join ' ') returned no output."
        }
        return $joined | ConvertFrom-Json
    }
    finally {
        Remove-Item -Path $stdErrFile -ErrorAction SilentlyContinue
    }
}

# ════════════════════════════════════════════════════════════════════════════

Write-Host 'Azure SRE Agent - Onboarding Lab bootstrap' -ForegroundColor White
Write-Host "State file: $StateFile"
if ($Reset) { Write-Warning 'Reset requested - previous progress is being discarded.' }

$state = Get-State

# ── Step 0: preflight ───────────────────────────────────────────────────────

Write-Step 'Preflight'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'The Azure CLI (az) was not found. Run this from Azure Cloud Shell (PowerShell).'
}
if (-not (Test-Path $agentCoreBicep)) {
    throw "Could not find $agentCoreBicep. Run this script from a clone of the sre-agent repository."
}

$account = Invoke-Az @('account', 'show', '-o', 'json')

if ($Subscription) {
    if ($account.id -ne $Subscription) {
        Write-Note "Switching to subscription $Subscription"
        $null = Invoke-Az @('account', 'set', '--subscription', $Subscription) -AllowEmpty
        $account = Invoke-Az @('account', 'show', '-o', 'json')
    }
}
elseif ($state.Contains('subscriptionId') -and $account.id -ne $state['subscriptionId']) {
    Write-Note "Restoring subscription $($state['subscriptionId']) from saved state"
    $null = Invoke-Az @('account', 'set', '--subscription', $state['subscriptionId']) -AllowEmpty
    $account = Invoke-Az @('account', 'show', '-o', 'json')
}

$subId = $account.id
$state['subscriptionId'] = $subId
Save-State -State $state

Write-Ok "Subscription: $($account.name) ($subId)"
Write-Ok "Signed in as: $($account.user.name)"

# Resolve the lab resource group name up front. The agent is created with both resource
# groups in scope, so the name has to be known before the agent is deployed.
if (-not $LabResourceGroup) {
    if ($state.Contains('labResourceGroup')) {
        $LabResourceGroup = $state['labResourceGroup']
        Write-Note "Using saved lab resource group: $LabResourceGroup"
    }
    else {
        $answer = Read-Host 'Resource group for the lab [SreAgentOnboardingLabRG]'
        $LabResourceGroup = if ([string]::IsNullOrWhiteSpace($answer)) { 'SreAgentOnboardingLabRG' } else { $answer.Trim() }
    }
}
$state['labResourceGroup'] = $LabResourceGroup
$state['location'] = $Location
Save-State -State $state

Write-Ok "Lab resource group: $LabResourceGroup"
Write-Ok "Location: $Location"

# ── Step 1: register the resource provider ──────────────────────────────────

Write-Step 'Step 1 - Register Microsoft.App'

if (Test-StepDone -State $state -Name 'rpRegistered') {
    Write-Ok 'Already registered (from saved state).'
}
else {
    $provider = Invoke-Az @('provider', 'show', '-n', 'Microsoft.App', '--query', '{state:registrationState}', '-o', 'json')
    if ($provider.state -ne 'Registered') {
        Write-Note "Current state: $($provider.state). Registering..."
        $null = Invoke-Az @('provider', 'register', '-n', 'Microsoft.App') -AllowEmpty

        $deadline = (Get-Date).AddMinutes(10)
        do {
            Start-Sleep -Seconds 10
            $provider = Invoke-Az @('provider', 'show', '-n', 'Microsoft.App', '--query', '{state:registrationState}', '-o', 'json')
            Write-Note "  ... $($provider.state)"
        } while ($provider.state -ne 'Registered' -and (Get-Date) -lt $deadline)

        if ($provider.state -ne 'Registered') {
            throw "Microsoft.App did not reach Registered within 10 minutes (last state: $($provider.state))."
        }
    }
    Write-Ok 'Microsoft.App is registered.'
    Set-StepDone -State $state -Name 'rpRegistered'
}

# ── Step 2: resource groups ─────────────────────────────────────────────────

Write-Step 'Step 2 - Resource groups'

foreach ($rg in @($LabCreatorResourceGroup, $LabResourceGroup)) {
    $existing = $null
    try { $existing = Invoke-Az @('group', 'show', '-n', $rg, '-o', 'json') } catch { $existing = $null }

    if ($existing) {
        Write-Ok "$rg already exists in $($existing.location)."
    }
    else {
        $created = Invoke-Az @('group', 'create', '-n', $rg, '-l', $Location, '-o', 'json')
        Write-Ok "Created $rg in $($created.location)."
    }
}

# ── Step 3: create the lab-creator agent ────────────────────────────────────

Write-Step 'Step 3 - Create the lab-creator agent'

$agentExists = $null
try {
    $agentExists = Invoke-Az @(
        'resource', 'show', '-g', $LabCreatorResourceGroup, '-n', $LabCreatorAgentName,
        '--resource-type', 'Microsoft.App/agents', '--api-version', '2025-05-01-preview', '-o', 'json'
    )
}
catch { $agentExists = $null }

if ($agentExists -and $agentExists.properties.provisioningState -eq 'Succeeded') {
    Write-Ok "Agent $LabCreatorAgentName already exists."
}
else {
    # Deterministic suffix so re-runs address the same Log Analytics / App Insights resources.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$subId|$LabCreatorResourceGroup|$LabCreatorAgentName"))
        $suffix = (([System.BitConverter]::ToString($bytes)) -replace '-', '').ToLowerInvariant().Substring(0, 10)
    }
    finally { $sha.Dispose() }

    $paramsObject = [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = [ordered]@{
            agentName            = @{ value = $LabCreatorAgentName }
            location             = @{ value = $Location }
            suffix               = @{ value = $suffix }
            # High so the agent can deploy the lab; Review so you approve each action.
            accessLevel          = @{ value = 'High' }
            actionMode           = @{ value = 'Review' }
            subscriptionId       = @{ value = $subId }
            targetResourceGroups = @{ value = @($LabCreatorResourceGroup, $LabResourceGroup) }
            defaultModelProvider = @{ value = 'MicrosoftFoundry' }
            tags                 = @{ value = @{ workload = 'onboardinglab-labcreator' } }
        }
    }

    $paramsFile = Join-Path ([System.IO.Path]::GetTempPath()) 'labcreator.parameters.json'
    $paramsObject | ConvertTo-Json -Depth 10 | Set-Content -Path $paramsFile -NoNewline

    Write-Note "Deploying $LabCreatorAgentName (this takes a few minutes)..."
    try {
        $deployment = Invoke-Az @(
            'deployment', 'group', 'create',
            '--subscription', $subId,
            '-g', $LabCreatorResourceGroup,
            '--name', 'labcreator-agent',
            '--template-file', $agentCoreBicep,
            '--parameters', "@$paramsFile",
            '-o', 'json'
        )
    }
    finally {
        Remove-Item -Path $paramsFile -ErrorAction SilentlyContinue
    }

    if ($deployment.properties.provisioningState -ne 'Succeeded') {
        throw "Agent deployment finished with state $($deployment.properties.provisioningState)."
    }
    Write-Ok "Agent $LabCreatorAgentName created."
}

# Always read the agent back: the data-plane hostname contains service-assigned segments and
# cannot be composed from the agent name and region.
$agent = Invoke-Az @(
    'resource', 'show', '-g', $LabCreatorResourceGroup, '-n', $LabCreatorAgentName,
    '--resource-type', 'Microsoft.App/agents', '--api-version', '2025-05-01-preview', '-o', 'json'
)

$agentEndpoint = $agent.properties.agentEndpoint
if ([string]::IsNullOrWhiteSpace($agentEndpoint)) {
    throw 'The agent has no agentEndpoint yet. Wait a moment and re-run this script.'
}

$agentUamiPrincipalId = $null
foreach ($uami in $agent.identity.userAssignedIdentities.PSObject.Properties) {
    $agentUamiPrincipalId = $uami.Value.principalId
    break
}
if (-not $agentUamiPrincipalId) {
    throw 'Could not determine the user-assigned managed identity of the agent.'
}

$state['agentEndpoint'] = $agentEndpoint
$state['agentUamiPrincipalId'] = $agentUamiPrincipalId
Save-State -State $state

Write-Ok "Endpoint: $agentEndpoint"
Write-Ok "Agent identity: $agentUamiPrincipalId"

# ── Step 4: egress allowlist ────────────────────────────────────────────────

Write-Step 'Step 4 - Allow the egress hosts the agent needs'

# Read the current egress block and append. Do NOT write a fresh list: the platform seeds
# roughly thirty defaults (management.azure.com, api.github.com, the package registries, ...)
# and replacing them would leave the agent unable to reach Azure at all.
$egress = $agent.properties.sandboxConfiguration.egress

$currentHosts = @()
if ($egress -and $egress.allowedHosts) { $currentHosts = @($egress.allowedHosts) }

$missing = @($RequiredEgressHosts | Where-Object { $_ -notin $currentHosts })

if ($missing.Count -eq 0) {
    Write-Ok 'All required hosts are already allowed.'
}
else {
    Write-Note "Adding: $($missing -join ', ')"

    $mode = if ($egress -and $egress.mode) { $egress.mode } else { 'Limited' }
    $egressBody = [ordered]@{
        mode         = $mode
        allowedHosts = @($currentHosts + $missing)
    }
    # Preserve the other egress settings verbatim.
    if ($egress) {
        if ($null -ne $egress.allowedRegistries) { $egressBody['allowedRegistries'] = @($egress.allowedRegistries) }
        if ($null -ne $egress.allowedCodeRepositories) { $egressBody['allowedCodeRepositories'] = @($egress.allowedCodeRepositories) }
        if ($null -ne $egress.allowHttpMcpServerNetworkAccess) { $egressBody['allowHttpMcpServerNetworkAccess'] = $egress.allowHttpMcpServerNetworkAccess }
    }

    $patch = @{ properties = @{ sandboxConfiguration = @{ egress = $egressBody } } }
    $patchFile = Join-Path ([System.IO.Path]::GetTempPath()) 'labcreator-egress.json'
    $patch | ConvertTo-Json -Depth 10 | Set-Content -Path $patchFile -NoNewline

    $armUrl = "https://management.azure.com/subscriptions/$subId/resourceGroups/$LabCreatorResourceGroup/providers/Microsoft.App/agents/$LabCreatorAgentName" + '?api-version=2025-05-01-preview'
    try {
        $null = Invoke-Az @(
            'rest', '--method', 'patch', '--url', $armUrl,
            '--headers', 'Content-Type=application/json',
            '--body', "@$patchFile"
        ) -AllowEmpty
    }
    finally {
        Remove-Item -Path $patchFile -ErrorAction SilentlyContinue
    }

    # The PATCH briefly moves the agent to InProgress; wait for it to settle.
    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 10
        $check = Invoke-Az @(
            'resource', 'show', '-g', $LabCreatorResourceGroup, '-n', $LabCreatorAgentName,
            '--resource-type', 'Microsoft.App/agents', '--api-version', '2025-05-01-preview',
            '--query', '{state:properties.provisioningState,hosts:properties.sandboxConfiguration.egress.allowedHosts}', '-o', 'json'
        )
    } while ($check.state -eq 'InProgress' -and (Get-Date) -lt $deadline)

    $stillMissing = @($RequiredEgressHosts | Where-Object { $_ -notin @($check.hosts) })
    if ($stillMissing.Count -gt 0) {
        throw "Egress update did not take effect. Still missing: $($stillMissing -join ', ')"
    }
    Write-Ok 'Egress hosts allowed.'
}

# ── Step 5: grant Owner on the lab resource group ───────────────────────────

Write-Step 'Step 5 - Grant the agent Owner on the lab resource group'

$labScope = "/subscriptions/$subId/resourceGroups/$LabResourceGroup"

# Owner is required because deploying the lab agent creates role assignments
# (Reader, Monitoring Reader, Log Analytics Reader), which Contributor cannot do.
$existingAssignments = Invoke-Az @(
    'role', 'assignment', 'list',
    '--assignee', $agentUamiPrincipalId,
    '--scope', $labScope,
    '--query', "[?roleDefinitionName=='Owner']",
    '-o', 'json'
) -AllowEmpty

if ($existingAssignments -and @($existingAssignments).Count -gt 0) {
    Write-Ok 'Owner already assigned.'
}
else {
    $null = Invoke-Az @(
        'role', 'assignment', 'create',
        '--assignee-object-id', $agentUamiPrincipalId,
        '--assignee-principal-type', 'ServicePrincipal',
        '--role', 'Owner',
        '--scope', $labScope,
        '-o', 'json'
    ) -AllowEmpty
    Write-Ok "Owner granted on $LabResourceGroup."
}

# ── Step 6: connect the code repository ─────────────────────────────────────

Write-Step 'Step 6 - Connect your fork as a code repository'

if (Test-StepDone -State $state -Name 'codeAccessConfirmed') {
    Write-Ok 'Already confirmed (from saved state). Use -Reset to redo this step.'
}
else {
    $portalUrl = "https://sre.azure.com/#/agent/$subId/$LabCreatorResourceGroup/$LabCreatorAgentName"

    Write-Host ''
    Write-Host '   The agent needs read access to your fork of the sre-agent repository so it can' -ForegroundColor Yellow
    Write-Host "   read $RunbookPath and the lab templates." -ForegroundColor Yellow
    Write-Host ''
    Write-Host '   1. Open the agent in the portal:'
    Write-Host "      $portalUrl"
    Write-Host '   2. Go to Manage - Sources (code repositories).'
    Write-Host '   3. Choose Add / Connect, pick GitHub, and complete the sign-in and consent.'
    Write-Host '   4. Select your fork of sre-agent and grant read access.'
    Write-Host '   5. Wait until the repository shows as connected.'
    Write-Host ''
    Write-Host '   This step is manual: it needs an interactive OAuth consent that cannot be' -ForegroundColor DarkGray
    Write-Host '   scripted. If this session dies, re-run the script and it resumes here.' -ForegroundColor DarkGray
    Write-Host ''

    $null = Read-Host '   Press Enter once the repository is connected'
    Set-StepDone -State $state -Name 'codeAccessConfirmed'
    Write-Ok 'Code access confirmed.'
}

# ── Step 7: start the deployment thread ─────────────────────────────────────

Write-Step 'Step 7 - Ask the agent to deploy the lab'

$dpToken = (& az account get-access-token --resource 'https://azuresre.dev' --query accessToken -o tsv 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($dpToken -join ''))) {
    throw 'Could not get a data-plane token for https://azuresre.dev. Run: az login --scope "https://azuresre.dev/.default" and re-run this script.'
}
$dpToken = ($dpToken -join '').Trim()

$startMessage = @"
Deploy the Azure SRE Agent Onboarding Lab.

Follow the runbook at $RunbookPath in the connected sre-agent repository. Work through every
step in order and run its verification before moving on.

Inputs:
- SUBSCRIPTION: $subId
- LAB_RG: $LabResourceGroup
- LOCATION: $Location
- NAME_PREFIX: flu-lab01
- AGENT_NAME: onboardinglab-agent

The resource group already exists and you have Owner on it. Leave the database fault off.
Do not modify anything outside $LabResourceGroup. Report what you created when you are done.
"@

$body = @{ StartMessage = $startMessage } | ConvertTo-Json -Depth 5

try {
    $thread = Invoke-RestMethod -Uri "$agentEndpoint/api/v1/threads" -Method Post `
        -Headers @{ Authorization = "Bearer $dpToken" } `
        -ContentType 'application/json' -Body $body -TimeoutSec 60
}
catch {
    throw "Could not start the agent thread: $($_.Exception.Message)"
}
finally {
    $dpToken = $null
}

$threadId = if ($thread.id) { $thread.id } elseif ($thread.threadId) { $thread.threadId } else { $null }
$state['threadId'] = $threadId
Save-State -State $state

Write-Ok 'Thread started.'

# ── Done ────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host 'Bootstrap complete.' -ForegroundColor Green
Write-Host ''
Write-Host "  Lab-creator agent : $LabCreatorAgentName (in $LabCreatorResourceGroup)"
Write-Host "  Lab resource group: $LabResourceGroup"
Write-Host "  Region            : $Location"
if ($threadId) { Write-Host "  Thread            : $threadId" }
Write-Host ''
Write-Host '  Watch progress at:'
Write-Host "  https://sre.azure.com/#/agent/$subId/$LabCreatorResourceGroup/$LabCreatorAgentName"
Write-Host ''
Write-Host '  The agent runs in Review mode, so approve each action as it is proposed.' -ForegroundColor Yellow
Write-Host ''
