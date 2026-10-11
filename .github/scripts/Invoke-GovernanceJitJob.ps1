#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

<#
.SYNOPSIS
    Runs JIT-backed GitHub jobs under fail-closed governance controls.
.DESCRIPTION
    Discovers the pull_request and push runs for one commit, verifies runner
    quiescence, refreshes job IDs immediately before use, invokes a repository-
    specific JIT provider, cleans matching runner resources in finally-style
    handling, and gates readiness only on governance-integrity in both runs.
.PARAMETER Repository
    GitHub repository in owner/name form.
.PARAMETER SeedRunId
    Either workflow run ID for the target commit.
.PARAMETER SourceJobName
    Job to execute through the repository-specific JIT provider.
.PARAMETER JitCommandPath
    PowerShell provider implementing the documented JIT command contract.
.PARAMETER SubscriptionId
    Azure subscription that owns the shared runner pool.
.PARAMETER RunnerResourceGroup
    Resource group that owns the ACI runner pool.
.PARAMETER ResourcePrefix
    Prefix used by ephemeral runner registrations and ACI containers.
.PARAMETER RequiredJobName
    Required governance job. Other check results do not affect readiness.
.EXAMPLE
    ./.github/scripts/Invoke-GovernanceJitJob.ps1 -Repository owner/repo -SeedRunId 1234 -SourceJobName build-and-test -JitCommandPath ./.github/scripts/Start-JitRunner.ps1
.NOTES
    Invoke this script as a lone command. PIM elevation is interactive and is
    never attempted by the script.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository = '',

    [Parameter(Mandatory = $false)]
    [long]$SeedRunId = 0,

    [Parameter(Mandatory = $false)]
    [string]$SourceJobName = '',

    [Parameter(Mandatory = $false)]
    [string]$JitCommandPath = '',

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId = 'e342fa55-088f-47c1-8fa1-1e2e97747137',

    [Parameter(Mandatory = $false)]
    [string]$RunnerResourceGroup = 'rg-GitHub-Runner-Pool',

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,31}$')]
    [string]$ResourcePrefix = 'pos-jit',

    [Parameter(Mandatory = $false)]
    [string]$RequiredJobName = 'governance-integrity'
)

$ErrorActionPreference = 'Stop'

#region Native command adapters

function Invoke-NativeJson {
    <#
    .SYNOPSIS
        Runs a native command without mixing stderr into JSON stdout.
    .OUTPUTS
        System.Object.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Arguments
    )

    $ErrorPath = [System.IO.Path]::GetTempFileName()
    $PreviousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
    $Output = $null
    $ExitCode = -1
    $InvocationFailure = $null
    $ErrorText = ''
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        try {
            $Output = & $FilePath @Arguments 2> $ErrorPath
            $ExitCode = $LASTEXITCODE
        }
        catch {
            $InvocationFailure = $_
        }
        if (Test-Path -LiteralPath $ErrorPath) {
            $ErrorText = Get-Content -LiteralPath $ErrorPath -Raw
        }
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $PreviousNativeErrorPreference
        Remove-Item -LiteralPath $ErrorPath -Force -ErrorAction SilentlyContinue
    }

    if ($null -ne $InvocationFailure) {
        throw "native-command-failed:${FilePath}:$($InvocationFailure.Exception.Message)"
    }
    if ($ExitCode -ne 0) {
        throw "native-command-failed:${FilePath}:exit-${ExitCode}:$($ErrorText.Trim())"
    }
    if (-not [string]::IsNullOrWhiteSpace($ErrorText)) {
        Write-Verbose $ErrorText.Trim()
    }

    $Text = (@($Output) | ForEach-Object { $_.ToString() }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try {
        return $Text | ConvertFrom-Json
    }
    catch {
        throw "native-json-invalid:${FilePath}:$($_.Exception.Message)"
    }
}

function Invoke-GhJson {
    <#
    .SYNOPSIS
        Runs GitHub CLI with argument-array invocation and parses JSON.
    .OUTPUTS
        System.Object.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Arguments
    )

    return Invoke-NativeJson -FilePath 'gh' -Arguments $Arguments
}

function Invoke-AzJson {
    <#
    .SYNOPSIS
        Runs Azure CLI with argument-array invocation and parses JSON.
    .OUTPUTS
        System.Object.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Arguments
    )

    return Invoke-NativeJson -FilePath 'az' -Arguments $Arguments
}

#endregion Native command adapters

#region Governance discovery and gates

function Get-GovernanceRunSet {
    <#
    .SYNOPSIS
        Resolves the latest pull_request and push runs for one commit.
    .OUTPUTS
        System.Object[].
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [long]::MaxValue)]
        [long]$SeedRunId
    )

    $Seed = Invoke-GhJson -Arguments @(
        'run', 'view', "$SeedRunId", '--repo', $Repository,
        '--json', 'databaseId,event,headSha,workflowName'
    )
    if ([string]::IsNullOrWhiteSpace($Seed.headSha) `
        -or [string]::IsNullOrWhiteSpace($Seed.workflowName)) {
        throw "invalid-seed-run:$SeedRunId"
    }

    $Candidates = @(Invoke-GhJson -Arguments @(
        'run', 'list', '--repo', $Repository, '--commit', $Seed.headSha,
        '--limit', '100',
        '--json', 'databaseId,event,headSha,workflowName,createdAt,status,conclusion'
    )) | Where-Object {
        $_.headSha -eq $Seed.headSha -and $_.workflowName -eq $Seed.workflowName
    }

    $Selected = foreach ($EventName in @('pull_request', 'push')) {
        $Run = $Candidates `
            | Where-Object { $_.event -eq $EventName } `
            | Sort-Object -Property createdAt -Descending `
            | Select-Object -First 1
        if ($null -eq $Run) {
            throw "dual-run-missing:${EventName}:$($Seed.headSha)"
        }
        $Run
    }
    return @($Selected)
}

function Get-RunJob {
    <#
    .SYNOPSIS
        Re-fetches one job from the current run attempt.
    .OUTPUTS
        System.Object.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [long]::MaxValue)]
        [long]$RunId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$JobName
    )

    $Run = Invoke-GhJson -Arguments @(
        'run', 'view', "$RunId", '--repo', $Repository,
        '--json', 'attempt,jobs'
    )
    $Matches = @($Run.jobs | Where-Object { $_.name -ceq $JobName })
    if ($Matches.Count -ne 1) {
        throw "source-job-denied:${RunId}:${JobName}:matches-$($Matches.Count)"
    }
    return $Matches[0]
}

function Assert-GovernanceGate {
    <#
    .SYNOPSIS
        Gates one event run on a freshly fetched required governance job.
    .OUTPUTS
        PSCustomObject.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [long]$RunId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('pull_request', 'push')]
        [string]$Event,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RequiredJobName
    )

    $Job = Get-RunJob -Repository $Repository -RunId $RunId -JobName $RequiredJobName
    if ($Job.status -cne 'completed' -or $Job.conclusion -cne 'success') {
        throw "governance-gate-failed:${Event}:${RequiredJobName}:$($Job.status):$($Job.conclusion)"
    }
    return [pscustomobject]@{
        Event = $Event
        RunId = $RunId
        JobId = $Job.databaseId
        Conclusion = $Job.conclusion
    }
}

#endregion Governance discovery and gates

#region Runner pool controls

function Get-RepositoryRunners {
    <#
    .SYNOPSIS
        Returns all repository runner registrations across every API page.
    .OUTPUTS
        System.Object[].
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
        [string]$Repository
    )

    $Pages = @(Invoke-GhJson -Arguments @(
        'api', "repos/$Repository/actions/runners?per_page=100",
        '--paginate', '--slurp'
    ))
    $Runners = [System.Collections.Generic.List[object]]::new()
    foreach ($Page in $Pages) {
        foreach ($Runner in @($Page.runners)) {
            if ($null -ne $Runner) { $Runners.Add($Runner) }
        }
    }
    return $Runners.ToArray()
}

function Get-ActiveWorkflowRuns {
    <#
    .SYNOPSIS
        Returns all repository workflow runs in one active status.
    .OUTPUTS
        System.Object[].
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [ValidateSet('queued', 'in_progress')]
        [string]$Status
    )

    $Pages = @(Invoke-GhJson -Arguments @(
        'api', "repos/$Repository/actions/runs?status=$Status&per_page=100",
        '--paginate', '--slurp'
    ))
    $Runs = [System.Collections.Generic.List[object]]::new()
    foreach ($Page in $Pages) {
        foreach ($Run in @($Page.workflow_runs)) {
            if ($null -ne $Run) { $Runs.Add($Run) }
        }
    }
    return $Runs.ToArray()
}

function Write-PimUnblockRunbook {
    <#
    .SYNOPSIS
        Prints the human-only PIM unblock sequence.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$RunnerResourceGroup
    )

    $Scope = "/subscriptions/$SubscriptionId/resourceGroups/$RunnerResourceGroup"
    Write-Host ''
    Write-Host 'PIM elevation is required and cannot be completed autonomously.' -ForegroundColor Yellow
    Write-Host '1. Open Azure PIM for Azure resource roles:' -ForegroundColor Yellow
    Write-Host '   https://portal.azure.com/#view/Microsoft_Azure_PIMCommon/ActivationMenuBlade/~/azurerbac'
    Write-Host "2. Activate the eligible role for scope: $Scope"
    Write-Host '3. Complete MFA and wait for activation confirmation.'
    Write-Host '4. Verify access, then rerun this wrapper as a lone command:'
    Write-Host "   az container list --subscription $SubscriptionId --resource-group $RunnerResourceGroup --output table"
    Write-Host ''
}

function Assert-RunnerPoolAccess {
    <#
    .SYNOPSIS
        Verifies read access to the ACI runner pool without elevating.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$RunnerResourceGroup,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,31}$')]
        [string]$ResourcePrefix
    )

    try {
        $null = Invoke-AzJson -Arguments @(
            'container', 'list', '--subscription', $SubscriptionId,
            '--resource-group', $RunnerResourceGroup,
            '--query', "[?starts_with(name, '$ResourcePrefix')].name",
            '--output', 'json'
        )
    }
    catch {
        $AccessError = $_.Exception.Message
        if ($AccessError -notmatch '(?i)(AuthorizationFailed|Forbidden|does not have authorization|permission|status.?403|\b403\b)') {
            throw "runner-pool-access-check-failed:${RunnerResourceGroup}:$AccessError"
        }
        Write-PimUnblockRunbook `
            -SubscriptionId $SubscriptionId `
            -RunnerResourceGroup $RunnerResourceGroup
        throw "pim-elevation-required:${RunnerResourceGroup}:$AccessError"
    }
}

function Assert-GovernanceQuiescence {
    <#
    .SYNOPSIS
        Requires zero matching runners, active runs, and ACI containers.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$RunnerResourceGroup,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,31}$')]
        [string]$ResourcePrefix
    )

    $Runners = @(Get-RepositoryRunners -Repository $Repository)
    $QueuedRuns = @(Get-ActiveWorkflowRuns -Repository $Repository -Status 'queued')
    $InProgressRuns = @(Get-ActiveWorkflowRuns -Repository $Repository -Status 'in_progress')
    $Containers = @(Invoke-AzJson -Arguments @(
        'container', 'list', '--subscription', $SubscriptionId,
        '--resource-group', $RunnerResourceGroup,
        '--query', "[?starts_with(name, '$ResourcePrefix')].name",
        '--output', 'json'
    ))

    if ($Runners.Count -ne 0 `
        -or $QueuedRuns.Count -ne 0 `
        -or $InProgressRuns.Count -ne 0 `
        -or $Containers.Count -ne 0) {
        throw "jit-not-quiescent:runners-$($Runners.Count):queued-$($QueuedRuns.Count):in-progress-$($InProgressRuns.Count):containers-$($Containers.Count)"
    }
}

function Invoke-JitCommand {
    <#
    .SYNOPSIS
        Invokes the repository-specific JIT provider with a fixed interface.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$JitCommandPath,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [long]$RunId,

        [Parameter(Mandatory = $true)]
        [long]$JobId,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$RunnerResourceGroup,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,31}$')]
        [string]$ResourcePrefix
    )

    $Provider = Get-Item -LiteralPath $JitCommandPath -ErrorAction Stop
    if ($Provider.Extension -cne '.ps1') {
        throw "invalid-jit-provider:$JitCommandPath"
    }
    & $Provider.FullName `
        -Repository $Repository `
        -RunId $RunId `
        -JobId $JobId `
        -SubscriptionId $SubscriptionId `
        -ResourceGroup $RunnerResourceGroup `
        -ResourcePrefix $ResourcePrefix
}

function Remove-JitResources {
    <#
    .SYNOPSIS
        Removes only ACI containers and runner registrations matching the prefix.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$RunnerResourceGroup,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,31}$')]
        [string]$ResourcePrefix
    )

    $CleanupErrors = [System.Collections.Generic.List[string]]::new()
    $Containers = @()
    try {
        $Containers = @(Invoke-AzJson -Arguments @(
            'container', 'list', '--subscription', $SubscriptionId,
            '--resource-group', $RunnerResourceGroup,
            '--query', "[?starts_with(name, '$ResourcePrefix')].name",
            '--output', 'json'
        ))
    }
    catch {
        $CleanupErrors.Add("container-list:$($_.Exception.Message)")
    }
    foreach ($ContainerName in $Containers) {
        try {
            $null = Invoke-AzJson -Arguments @(
                'container', 'delete', '--subscription', $SubscriptionId,
                '--resource-group', $RunnerResourceGroup,
                '--name', "$ContainerName", '--yes', '--output', 'json'
            )
        }
        catch {
            $CleanupErrors.Add("container-${ContainerName}:$($_.Exception.Message)")
        }
    }

    $MatchingRunners = @()
    try {
        $MatchingRunners = @(Get-RepositoryRunners -Repository $Repository | Where-Object {
            $_.name -like "$ResourcePrefix*" `
                -or @($_.labels | Where-Object { $_.name -eq $ResourcePrefix }).Count -gt 0
        })
    }
    catch {
        $CleanupErrors.Add("runner-list:$($_.Exception.Message)")
    }
    foreach ($Runner in $MatchingRunners) {
        try {
            $null = Invoke-GhJson -Arguments @(
                'api', '--method', 'DELETE', "repos/$Repository/actions/runners/$($Runner.id)"
            )
        }
        catch {
            $CleanupErrors.Add("runner-$($Runner.id):$($_.Exception.Message)")
        }
    }
    if ($CleanupErrors.Count -gt 0) {
        throw "jit-cleanup-failed:$($CleanupErrors -join ';')"
    }
}

#endregion Runner pool controls

#region Orchestration

function Invoke-GovernanceJitJob {
    <#
    .SYNOPSIS
        Executes both event runs and verifies dual-run governance readiness.
    .OUTPUTS
        PSCustomObject.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [long]::MaxValue)]
        [long]$SeedRunId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceJobName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$JitCommandPath,

        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId = 'e342fa55-088f-47c1-8fa1-1e2e97747137',

        [Parameter(Mandatory = $false)]
        [string]$RunnerResourceGroup = 'rg-GitHub-Runner-Pool',

        [Parameter(Mandatory = $false)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,31}$')]
        [string]$ResourcePrefix = 'pos-jit',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$RequiredJobName = 'governance-integrity'
    )

    $Runs = @(Get-GovernanceRunSet -Repository $Repository -SeedRunId $SeedRunId)
    foreach ($Run in $Runs) {
        Assert-RunnerPoolAccess `
            -SubscriptionId $SubscriptionId `
            -RunnerResourceGroup $RunnerResourceGroup `
            -ResourcePrefix $ResourcePrefix
        Assert-GovernanceQuiescence `
            -Repository $Repository `
            -SubscriptionId $SubscriptionId `
            -RunnerResourceGroup $RunnerResourceGroup `
            -ResourcePrefix $ResourcePrefix

        $SourceJob = Get-RunJob `
            -Repository $Repository `
            -RunId $Run.databaseId `
            -JobName $SourceJobName
        $ProviderFailure = $null
        try {
            Invoke-JitCommand `
                -JitCommandPath $JitCommandPath `
                -Repository $Repository `
                -RunId $Run.databaseId `
                -JobId $SourceJob.databaseId `
                -SubscriptionId $SubscriptionId `
                -RunnerResourceGroup $RunnerResourceGroup `
                -ResourcePrefix $ResourcePrefix
        }
        catch {
            $ProviderFailure = $_
        }

        $CleanupFailure = $null
        try {
            Remove-JitResources `
                -Repository $Repository `
                -SubscriptionId $SubscriptionId `
                -RunnerResourceGroup $RunnerResourceGroup `
                -ResourcePrefix $ResourcePrefix
        }
        catch {
            $CleanupFailure = $_
        }
        if ($null -ne $ProviderFailure -and $null -ne $CleanupFailure) {
            throw "jit-provider-and-cleanup-failed:provider-$($ProviderFailure.Exception.Message):cleanup-$($CleanupFailure.Exception.Message)"
        }
        if ($null -ne $CleanupFailure) { throw $CleanupFailure }
        if ($null -ne $ProviderFailure) { throw $ProviderFailure }
    }

    $Gates = foreach ($Run in $Runs) {
        Assert-GovernanceGate `
            -Repository $Repository `
            -RunId $Run.databaseId `
            -Event $Run.event `
            -RequiredJobName $RequiredJobName
    }
    return [pscustomobject]@{
        State = 'READY'
        HeadSha = $Runs[0].headSha
        RequiredCheck = $RequiredJobName
        Gates = @($Gates)
        NonRequiredChecks = 'ignored'
    }
}

#endregion Orchestration

#region Main Execution

if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ([string]::IsNullOrWhiteSpace($Repository) `
            -or $SeedRunId -lt 1 `
            -or [string]::IsNullOrWhiteSpace($SourceJobName) `
            -or [string]::IsNullOrWhiteSpace($JitCommandPath)) {
            throw 'Repository, SeedRunId, SourceJobName, and JitCommandPath are required.'
        }
        $Result = Invoke-GovernanceJitJob `
            -Repository $Repository `
            -SeedRunId $SeedRunId `
            -SourceJobName $SourceJobName `
            -JitCommandPath $JitCommandPath `
            -SubscriptionId $SubscriptionId `
            -RunnerResourceGroup $RunnerResourceGroup `
            -ResourcePrefix $ResourcePrefix `
            -RequiredJobName $RequiredJobName
        Write-Host 'Governance readiness: READY' -ForegroundColor Green
        $Result
        exit 0
    }
    catch {
        Write-Error -ErrorAction Continue "Governance JIT wrapper failed: $($_.Exception.Message)"
        exit 1
    }
}

#endregion Main Execution