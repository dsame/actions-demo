param (
    [Parameter(Mandatory)][string] $ManifestUrl,
    [string] $AccessToken
)

$authorizationHeaderValue = "Basic $AccessToken"
$webRequestHeaders = @{}
if ($AccessToken) {
    $webRequestHeaders.Add("Authorization", $authorizationHeaderValue)
}

function Publish-Error {
    param(
        [string] $ErrorDescription,
        [object] $Exception
    )
    Write-Host "##vso[task.logissue type=error]ERROR: $ErrorDescription."
    Write-Host "##vso[task.logissue type=error]    $Exception"
    Write-Host "##vso[task.complete result=Failed;]"
}

function Test-DownloadUrl {
    param([string] $DownloadUrl)
    $request = [System.Net.WebRequest]::Create($DownloadUrl)
    if ($AccessToken) {
        $request.Headers.Add("Authorization", $authorizationHeaderValue)
    }
    try {
        $response = $request.GetResponse()
        return ([int]$response.StatusCode -eq 200)
    } catch {
        return $false
    }
}

Write-Host "Downloading manifest json from '$ManifestUrl'..."
try {
    $manifestResponse = Invoke-WebRequest -Method Get -Uri $ManifestUrl -Headers $webRequestHeaders
} catch {
    Publish-Error "Unable to download manifest json from '$ManifestUrl'" $_
    exit 1
}

Write-Host "Parsing manifest json content from '$ManifestUrl'..."
try {
    $manifestJson = $manifestResponse.Content | ConvertFrom-Json
} catch {
    Publish-Error "Unable to parse manifest json content '$ManifestUrl'" $_
    exit 1
}

$versionsList = $manifestJson.version
Write-Host "Found versions: $($versionsList -join ', ')"

$manifestJson | ForEach-Object {
    Write-Host "Validating version '$($_.version)'..."
    $_.files | ForEach-Object {
        Write-Host "    Validating '$($_.download_url)'..."
        if (-not (Test-DownloadUrl $_.download_url)) {
            Publish-Error "Url '$($_.download_url)' is invalid"
        }
    }
}
