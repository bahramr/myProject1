#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

<#
.SYNOPSIS
    Verifies canonical and mirror files from clean staged Git blobs.
.DESCRIPTION
    Reads a versioned mirror-pair manifest, rejects unstaged changes, and
    compares the Git index blob OIDs for every canonical and mirror path.
.PARAMETER RepositoryRoot
    Root of the Git repository to inspect.
.PARAMETER ManifestPath
    Absolute path or repository-relative path to the mirror-pair manifest.
.EXAMPLE
    ./.github/scripts/Test-StagedMirrorParity.ps1
.NOTES
    Run after staging both sides of every Document Manager mirror update.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$RepositoryRoot = '.',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ManifestPath = '.github/governance-mirror-pairs.json'
)

$ErrorActionPreference = 'Stop'

#region Functions

function Assert-RepositoryRelativePath {
    <#
    .SYNOPSIS
        Rejects absolute and repository-escaping manifest paths.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $NormalizedPath = $Path.Replace('\', '/')
    $Segments = $NormalizedPath.Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)
    if ([System.IO.Path]::IsPathRooted($Path) `
        -or $NormalizedPath.StartsWith('/', [System.StringComparison]::Ordinal) `
        -or $Segments.Count -eq 0 `
        -or $Segments -contains '..') {
        throw "invalid-mirror-path:$Path"
    }
}

function Invoke-GitText {
    <#
    .SYNOPSIS
        Runs Git with argument-array invocation and returns trimmed text.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryRoot,

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
            $Output = & git -C $RepositoryRoot @Arguments 2> $ErrorPath
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
        throw "git-command-failed:$($Arguments[0]):$($InvocationFailure.Exception.Message)"
    }
    if ($ExitCode -ne 0) {
        throw "git-command-failed:$($Arguments[0]):$($ErrorText.Trim())"
    }
    return (@($Output) | ForEach-Object { $_.ToString() }) -join "`n"
}

function Assert-WorkingTreePathClean {
    <#
    .SYNOPSIS
        Fails when a path differs between the working tree and Git index.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    try {
        $null = Invoke-GitText `
            -RepositoryRoot $RepositoryRoot `
            -Arguments @('ls-files', '--error-unmatch', '--', $Path)
    }
    catch {
        throw "unstaged-path:$Path"
    }
    try {
        $null = Invoke-GitText `
            -RepositoryRoot $RepositoryRoot `
            -Arguments @('diff', '--quiet', '--', $Path)
    }
    catch {
        throw "unstaged-change:$Path"
    }
}

function Get-StagedBlobOid {
    <#
    .SYNOPSIS
        Gets a path's blob OID from the Git index.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    return Invoke-GitText `
        -RepositoryRoot $RepositoryRoot `
        -Arguments @('rev-parse', '--verify', ":$Path")
}

function Get-StagedManifestText {
    <#
    .SYNOPSIS
        Reads the mirror-pair manifest from the Git index.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    return Invoke-GitText `
        -RepositoryRoot $RepositoryRoot `
        -Arguments @('show', ":$Path")
}

function Read-MirrorPairManifest {
    <#
    .SYNOPSIS
        Reads and validates the versioned mirror-pair manifest.
    .OUTPUTS
        System.Object[].
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ManifestPath
    )

    $RepositoryFullPath = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $ResolvedManifestPath = if ([System.IO.Path]::IsPathRooted($ManifestPath)) {
        [System.IO.Path]::GetFullPath($ManifestPath)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $RepositoryFullPath $ManifestPath))
    }
    $RepositoryPrefix = $RepositoryFullPath.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar
    $PathComparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    if (-not $ResolvedManifestPath.StartsWith($RepositoryPrefix, $PathComparison)) {
        throw "invalid-manifest-path:$ManifestPath"
    }
    $RelativeManifestPath = [System.IO.Path]::GetRelativePath(
        $RepositoryFullPath,
        $ResolvedManifestPath
    ).Replace('\', '/')
    Assert-RepositoryRelativePath -Path $RelativeManifestPath
    Assert-WorkingTreePathClean `
        -RepositoryRoot $RepositoryFullPath `
        -Path $RelativeManifestPath
    $ManifestText = Get-StagedManifestText `
        -RepositoryRoot $RepositoryFullPath `
        -Path $RelativeManifestPath
    try {
        $Manifest = $ManifestText | ConvertFrom-Json
    }
    catch {
        throw "invalid-mirror-manifest:json:$($_.Exception.Message)"
    }
    if ($Manifest.schemaVersion -ne 1 -or $null -eq $Manifest.pairs) {
        throw 'invalid-mirror-manifest:schemaVersion-or-pairs'
    }

    $Pairs = @($Manifest.pairs)
    foreach ($Pair in $Pairs) {
        if ($Pair.canonical -isnot [string] `
            -or [string]::IsNullOrWhiteSpace($Pair.canonical) `
            -or $Pair.mirror -isnot [string] `
            -or [string]::IsNullOrWhiteSpace($Pair.mirror)) {
            throw 'invalid-mirror-manifest:pair-shape'
        }
        Assert-RepositoryRelativePath -Path $Pair.canonical
        Assert-RepositoryRelativePath -Path $Pair.mirror
    }
    return $Pairs
}

function Test-StagedMirrorParity {
    <#
    .SYNOPSIS
        Verifies all configured canonical and mirror staged blobs.
    .OUTPUTS
        PSCustomObject.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ManifestPath
    )

    $RepositoryFullPath = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $Pairs = @(Read-MirrorPairManifest `
        -RepositoryRoot $RepositoryFullPath `
        -ManifestPath $ManifestPath)

    foreach ($Pair in $Pairs) {
        Assert-WorkingTreePathClean -RepositoryRoot $RepositoryFullPath -Path $Pair.canonical
        Assert-WorkingTreePathClean -RepositoryRoot $RepositoryFullPath -Path $Pair.mirror
    }

    foreach ($Pair in $Pairs) {
        $CanonicalOid = Get-StagedBlobOid -RepositoryRoot $RepositoryFullPath -Path $Pair.canonical
        $MirrorOid = Get-StagedBlobOid -RepositoryRoot $RepositoryFullPath -Path $Pair.mirror
        if ($CanonicalOid -cne $MirrorOid) {
            throw "mirror-parity-failed:$($Pair.canonical):$($Pair.mirror)"
        }
    }

    return [pscustomobject]@{
        Status = 'Pass'
        PairCount = $Pairs.Count
    }
}

#endregion Functions

#region Main Execution

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $Result = Test-StagedMirrorParity `
            -RepositoryRoot $RepositoryRoot `
            -ManifestPath $ManifestPath
        Write-Host "Mirror parity passed for $($Result.PairCount) pair(s)." -ForegroundColor Green
        $Result
        exit 0
    }
    catch {
        Write-Error -ErrorAction Continue "Mirror parity failed: $($_.Exception.Message)"
        exit 1
    }
}

#endregion Main Execution