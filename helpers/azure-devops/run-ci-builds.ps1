param (
    [Parameter(Mandatory)] [string] $TeamFoundationCollectionUri,
    [Parameter(Mandatory)] [string] $AzureDevOpsProjectName,
    [Parameter(Mandatory)] [string] $AzureDevOpsAccessToken,
    [Parameter(Mandatory)] [string] $SourceBranch,
    [Parameter(Mandatory)] [UInt32] $DefinitionId,
    [Parameter(Mandatory)] [string] $SourceVersion,
    [Parameter(Mandatory)] [string] $ManifestLink,
    [Parameter(Mandatory)] [bool] $WaitForBuilds,
    [string] $ToolVersions,
    [UInt32] $RetryIntervalSec = 60,
    [UInt32] $RetryCount = 3
)

Import-Module (Join-Path $PSScriptRoot "azure-devops-api.ps1")
Import-Module (Join-Path $PSScriptRoot "build-info.ps1")

function Get-ToolVersions {
    param (
        [Parameter(Mandatory)] [string] $ManifestLink,
        [Parameter(Mandatory)] [UInt32] $RetryIntervalSec,
        [Parameter(Mandatory)] [UInt32] $Retries,
        [string] $ToolVersions
    )
    
    [string[]] $versionsList = @()
    if ($ToolVersions) {
        $versionsList = $ToolVersions.Split(',')
    } else {
        Write-Host "Get the list of releases from $ManifestLink"
        $releases = Invoke-RestMethod $ManifestLink -MaximumRetryCount $Retries -RetryIntervalSec $RetryIntervalSec
        $versionsList = $releases.version
    }

    Write-Host "Versions to build: $versionsList"
    return $versionsList
}

function Queue-Builds {
    param (
        [Parameter(Mandatory)] [AzureDevOpsApi] $AzureDevOpsApi,
        [Parameter(Mandatory)] [string[]] $ToolVersions,
        [Parameter(Mandatory)] [string] $SourceBranch,
        [Parameter(Mandatory)] [string] $SourceVersion,
        [Parameter(Mandatory)] [UInt32] $DefinitionId
    )

    [BuildInfo[]]$queuedBuilds = @()

    $ToolVersions | ForEach-Object { 
        $version = $_.Trim()
        Write-Host "Queue build for $version..."
        $queuedBuild = $AzureDevOpsApi.QueueBuild($version, $SourceBranch, $SourceVersion, $DefinitionId)
        $buildInfo = Get-BuildInfo -AzureDevOpsApi $AzureDevOpsApi -Build $queuedBuild
        Write-Host "Queued build: $($buildInfo.Link)"
        $queuedBuilds += $buildInfo
    }

    return $queuedBuilds
}

function Wait-Builds {
    param (
        [Parameter(Mandatory)] [BuildInfo[]] $Builds,
        [Parameter(Mandatory)] [UInt32] $RetryIntervalSec
    )
    
    do {
        # If build is still running - refresh its status
        foreach($build in $builds) {
            if (!$build.IsFinished()) {
                $build.UpdateBuildInfo()
                
                if ($build.IsFinished()) {
                   Write-Host "The $($build.Name) build was completed: $($build.Link)"
                }
            }
        }
    
        $runningBuildsCount = ($builds | Where-Object { !$_.IsFinished() }).Length

        Start-Sleep -Seconds $RetryIntervalSec
    } while($runningBuildsCount -gt 0)
}

function Make-BuildsOutput {
    param (
        [Parameter(Mandatory)] [BuildInfo[]] $Builds
    )

    Write-Host "`nBuilds info:"
    $builds | Format-Table -AutoSize -Property Name,Id,Status,Result,Link | Out-String -Width 10000

    # Return exit code based on status of builds
    $failedBuilds = ($builds | Where-Object { !$_.IsSuccess() })
    if ($failedBuilds.Length -ne 0) {
        Write-Host "##vso[task.logissue type=error;]Builds failed"
        $failedBuilds | ForEach-Object -Process { Write-Host "##vso[task.logissue type=error;]Name: $($_.Name); Link: $($_.Link)" }
        Write-Host "##vso[task.complete result=Failed]"
    } else {
        Write-host "##[section]All builds have been passed successfully"
    }
}

$azureDevOpsApi = Get-AzureDevOpsApi -TeamFoundationCollectionUri $TeamFoundationCollectionUri `
                                     -ProjectName $AzureDevOpsProjectName `
                                     -AccessToken $AzureDevOpsAccessToken `
                                     -RetryCount $RetryCount `
                                     -RetryIntervalSec $RetryIntervalSec

$toolVersionsList = Get-ToolVersions -ManifestLink $ManifestLink `
                                     -RetryIntervalSec $RetryIntervalSec `
                                     -Retries $RetryCount `
                                     -ToolVersions $ToolVersions

$queuedBuilds = Queue-Builds -AzureDevOpsApi $azureDevOpsApi `
                             -ToolVersions $toolVersionsList `
                             -SourceBranch $SourceBranch `
                             -SourceVersion $SourceVersion `
                             -DefinitionId $DefinitionId

if ($WaitForBuilds) {
    Write-Host "`nWaiting results of builds ..."
    Wait-Builds -Builds $queuedBuilds -RetryIntervalSec $RetryIntervalSec
    
    Make-BuildsOutput -Builds $queuedBuilds
}
