[CmdletBinding()]
param(
    [string]$Deploy = "",
    [int]$Jobs = 4
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if (-not $Deploy) { $Deploy = Join-Path $Root 'server' }
$Deploy = [IO.Path]::GetFullPath($Deploy)
$Patch = Join-Path $Root 'setup\vmangos\skatecraft.patch'
$Dockerfile = Join-Path $Deploy 'docker\server\Dockerfile'

if (-not (Test-Path (Join-Path $Deploy 'compose.yaml'))) { throw "No compose.yaml in $Deploy" }
if (-not (Test-Path $Patch)) { throw "Patch not found: $Patch" }
if (-not (Test-Path $Dockerfile)) { throw "VMaNGOS Dockerfile not found: $Dockerfile" }

$hash = (Get-FileHash -Algorithm SHA256 $Patch).Hash.Substring(0, 12).ToLowerInvariant()
$image = "world-of-skatecraft/vmangos-server:5875-$hash-win"
$revision = '0e3ff01e76d4758e8a7c3108b2717cc785ed56fa'

$existing = $null
try { $existing = docker image inspect $image 2>$null } catch { $existing = $null }
if (-not $existing) {
    Write-Host "Building $image (VMaNGOS $revision with the Skatecraft patch, $Jobs jobs)"
    $context = Join-Path ([IO.Path]::GetTempPath()) ("skatecraft-vmangos-" + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Force -Path $context | Out-Null
        Copy-Item -Recurse (Join-Path $Deploy 'docker') (Join-Path $context 'docker')
        New-Item -ItemType Directory -Force -Path (Join-Path $context 'docker\patches') | Out-Null
        Remove-Item -Force (Join-Path $context 'docker\patches\suppress-healthcheck-connection-logs.patch') -ErrorAction SilentlyContinue
        Get-ChildItem (Join-Path $context 'docker') -Recurse -File -Include '*.sh' | ForEach-Object {
            $text = [IO.File]::ReadAllText($_.FullName).Replace("`r`n", "`n")
            [IO.File]::WriteAllText($_.FullName, $text, [Text.UTF8Encoding]::new($false))
        }
        $patchText = [IO.File]::ReadAllText($Patch).Replace("`r`n", "`n")
        [IO.File]::WriteAllText((Join-Path $context 'docker\patches\zz-skatecraft.patch'), $patchText, [Text.UTF8Encoding]::new($false))
        $dockerfileText = Get-Content -Raw $Dockerfile
        $dockerfileText = $dockerfileText.Replace('make -j"$(nproc)"', "make -j$Jobs")
        Set-Content -NoNewline -Encoding utf8 (Join-Path $context 'Dockerfile.skatecraft') $dockerfileText
        docker build -t $image -f (Join-Path $context 'Dockerfile.skatecraft') `
            --build-arg VMANGOS_REVISION=$revision `
            --build-arg VMANGOS_CLIENT_VERSION=5875 `
            --build-arg VMANGOS_FAIL_ON_PATCH_ERROR=1 `
            $context
        if ($LASTEXITCODE -ne 0) { throw 'Patched VMaNGOS image build failed.' }
    }
    finally {
        if (Test-Path $context) { Remove-Item -Recurse -Force $context }
    }
}

$compose = Join-Path $Deploy 'compose.yaml'
$composeText = Get-Content -Raw $compose
$composeText = [regex]::Replace($composeText, 'image:\s+(?:ghcr\.io/mserajnik/vmangos-server:5875|world-of-skatecraft/vmangos-server:\S+)', "image: $image")
Set-Content -NoNewline -Encoding utf8 $compose $composeText
Write-Host "$compose now runs $image"
