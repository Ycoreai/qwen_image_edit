param(
    [Parameter(Mandatory = $true)]
    [string]$RuntimeBaseImage,

    [Parameter(Mandatory = $true)]
    [string]$RuntimeImage
)

$ErrorActionPreference = 'Stop'

if ($RuntimeBaseImage -notmatch '@sha256:[0-9a-fA-F]{64}$') {
    throw 'RuntimeBaseImage must be an immutable registry reference ending in @sha256:<64 hex characters>.'
}
if ($RuntimeImage -match '\s' -or $RuntimeImage -notmatch '^[^:]+/.+:.+$') {
    throw 'RuntimeImage must be a registry/repository:tag reference.'
}

$workerRoot = $PSScriptRoot
$dockerExe = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerExe) {
    throw 'Docker CLI is missing. Install Docker Desktop and start its Linux container engine.'
}

Write-Output 'Checking that the pinned base image is accessible to this Docker login...'
$baseInspection = & $dockerExe.Source buildx imagetools inspect $RuntimeBaseImage 2>&1
$baseInspectExitCode = $LASTEXITCODE
$baseInspection | Out-Host
if ($baseInspectExitCode -ne 0) {
    throw 'Pinned base image is missing or inaccessible with the current Docker registry login. No build was started.'
}

$metadataPath = Join-Path ([System.IO.Path]::GetTempPath()) ("qwen-runtime-build-" + [guid]::NewGuid().ToString('N') + '.json')
Push-Location $workerRoot
try {
    & $dockerExe.Source buildx build `
        --platform linux/amd64 `
        --file Dockerfile.runtime `
        --build-arg "QWEN_RUNTIME_BASE_IMAGE=$RuntimeBaseImage" `
        --metadata-file $metadataPath `
        --tag $RuntimeImage `
        --push `
        .
    if ($LASTEXITCODE -ne 0) {
        throw "Qwen runtime image build/push failed with exit code $LASTEXITCODE. No RunPod endpoint was changed."
    }
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw 'Buildx completed but did not write image metadata; no endpoint was changed.'
    }
    try {
        $buildMetadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    } catch {
        throw 'Buildx image metadata could not be read; no endpoint was changed.'
    }
    $digest = [string]$buildMetadata.'containerimage.digest'
    if ($digest -notmatch '^sha256:[0-9a-fA-F]{64}$') {
        throw 'Buildx did not return a valid immutable image digest; no endpoint was changed.'
    }
} finally {
    Pop-Location
    Remove-Item -LiteralPath $metadataPath -Force -ErrorAction SilentlyContinue
}

Write-Output "RUNTIME_IMAGE_PUBLISHED=$RuntimeImage"
Write-Output "RUNTIME_IMAGE_DIGEST=$RuntimeImage@$digest"
Write-Output 'NEXT: build the small app image against this digest, then validate it on a staging endpoint before any production change.'
