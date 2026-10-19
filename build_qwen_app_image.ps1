param(
    [Parameter(Mandatory = $true)]
    [string]$RuntimeImage,

    [Parameter(Mandatory = $true)]
    [string]$AppImage
)

$ErrorActionPreference = 'Stop'

if ($RuntimeImage -notmatch '@sha256:[0-9a-fA-F]{64}$') {
    throw 'RuntimeImage must be an immutable registry reference ending in @sha256:<64 hex characters>.'
}
if ($AppImage -match '\s' -or $AppImage -notmatch '^[^:]+/.+:.+$') {
    throw 'AppImage must be a registry/repository:tag reference.'
}

$workerRoot = $PSScriptRoot
$dockerExe = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerExe) {
    throw 'Docker CLI is missing. Install Docker Desktop and start its Linux container engine.'
}

Write-Output 'Checking that the pinned runtime image is accessible to this Docker login...'
$runtimeInspection = & $dockerExe.Source buildx imagetools inspect $RuntimeImage 2>&1
$runtimeInspectExitCode = $LASTEXITCODE
$runtimeInspection | Out-Host
if ($runtimeInspectExitCode -ne 0) {
    throw 'Pinned runtime image is missing or inaccessible with the current Docker registry login. No build was started.'
}

$metadataPath = Join-Path ([System.IO.Path]::GetTempPath()) ("qwen-app-build-" + [guid]::NewGuid().ToString('N') + '.json')
Push-Location $workerRoot
try {
    & $dockerExe.Source buildx build `
        --file Dockerfile.app `
        --build-arg "QWEN_RUNTIME_IMAGE=$RuntimeImage" `
        --metadata-file $metadataPath `
        --tag $AppImage `
        --push `
        .
    if ($LASTEXITCODE -ne 0) {
        throw "Qwen app image build/push failed with exit code $LASTEXITCODE. The live endpoint was not changed."
    }
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw 'Buildx completed but did not write image metadata; endpoint was not changed.'
    }
    try {
        $buildMetadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    } catch {
        throw 'Buildx image metadata could not be read; endpoint was not changed.'
    }
    $digest = [string]$buildMetadata.'containerimage.digest'
    if ($digest -notmatch '^sha256:[0-9a-fA-F]{64}$') {
        throw 'Buildx did not return a valid immutable image digest; endpoint was not changed.'
    }
} finally {
    Pop-Location
    Remove-Item -LiteralPath $metadataPath -Force -ErrorAction SilentlyContinue
}

Write-Output "APP_IMAGE_PUBLISHED=$AppImage"
Write-Output "APP_IMAGE_DIGEST=$AppImage@$digest"
Write-Output 'NEXT: configure a staging Runpod Serverless endpoint to use this image and verify image-count workflows before production.'
