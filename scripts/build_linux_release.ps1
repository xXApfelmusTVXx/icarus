param(
    [ValidateSet("stable", "prerelease")]
    [string]$Channel = "stable",
    [string]$PostHogProjectToken = $env:POSTHOG_PROJECT_TOKEN,
    [string]$PostHogHost = $(if ($env:POSTHOG_HOST) { $env:POSTHOG_HOST } else { "https://us.i.posthog.com" }),
    [string]$ProductionConvexDeploymentUrl = $env:ICARUS_PRODUCTION_CONVEX_DEPLOYMENT_URL,
    [string]$ProductionConvexClientId = $env:ICARUS_PRODUCTION_CONVEX_CLIENT_ID,
    [switch]$SkipPubGet
)

# The Linux half of a desktop release: the Flutter bundle, built with the same
# cloud configuration as the Windows build, packed into the AppImage that
# publish_installer_release.ps1 attaches to the GitHub Release. Runs on Linux
# with PowerShell 7, which GitHub's Ubuntu runners have.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common_release.ps1")

if ($PSVersionTable.PSEdition -ne "Core" -or -not $IsLinux) {
    throw "Linux release builds run on Linux, with PowerShell 7."
}

$repoRoot = Get-RepoRoot -ScriptDirectory $PSScriptRoot
$releaseTarget = if ($Channel -eq "stable") { "stable-desktop" } else { "prerelease-desktop" }
Assert-ReleaseBranch -RepoRoot $repoRoot -ReleaseTarget $releaseTarget | Out-Null
$cloudBuildConfiguration = Resolve-CloudBuildConfiguration `
    -ReleaseTarget $Channel `
    -ProductionConvexDeploymentUrl $ProductionConvexDeploymentUrl `
    -ProductionConvexClientId $ProductionConvexClientId

if (-not $SkipPubGet) {
    Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "fvm" -Arguments @("flutter", "pub", "get")
}

# The same defines as build_desktop_release.ps1, through a temporary file that
# is deleted after the build.
$dartDefinesPath = $null
try {
    $dartDefines = [ordered]@{
        ICARUS_CLOUD_ENVIRONMENT = $cloudBuildConfiguration.Environment
        ICARUS_UPDATE_CHANNEL = $Channel
    }
    if ($cloudBuildConfiguration.Environment -eq "production") {
        $dartDefines.ICARUS_CONVEX_DEPLOYMENT_URL = $cloudBuildConfiguration.DeploymentUrl
        $dartDefines.ICARUS_CONVEX_CLIENT_ID = $cloudBuildConfiguration.ClientId
    }
    if (-not [string]::IsNullOrWhiteSpace($PostHogProjectToken)) {
        $dartDefines.POSTHOG_PROJECT_TOKEN = $PostHogProjectToken
        $dartDefines.POSTHOG_HOST = $PostHogHost
    }

    $dartDefinesPath = Join-Path ([System.IO.Path]::GetTempPath()) ("icarus-dart-defines-{0}.json" -f [guid]::NewGuid())
    Write-JsonFileUtf8 -Path $dartDefinesPath -Value $dartDefines
    Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "fvm" -Arguments @(
        "flutter", "build", "linux", "--release", "--no-tree-shake-icons",
        "--dart-define-from-file=$dartDefinesPath"
    )
}
finally {
    if ($null -ne $dartDefinesPath -and (Test-Path -LiteralPath $dartDefinesPath)) {
        Remove-Item -LiteralPath $dartDefinesPath -Force
    }
}

Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "bash" -Arguments @("scripts/package_linux_appimage.sh")

# One name for every release, like icarus-setup.exe, so
# releases/latest/download/icarus-x86_64.AppImage always points at the newest.
$versionInfo = Get-VersionInfo -RepoRoot $repoRoot
$packedAppImage = Join-Path $repoRoot "build/appimage/Icarus-$($versionInfo.VersionName)-x86_64.AppImage"
if (-not (Test-Path -LiteralPath $packedAppImage)) {
    throw "The AppImage was not packed at $packedAppImage"
}
$releaseDirectory = Join-Path $repoRoot "release/out/linux/$($versionInfo.FullVersion)"
New-Item -ItemType Directory -Path $releaseDirectory -Force | Out-Null
$releaseAppImage = Join-Path $releaseDirectory "icarus-x86_64.AppImage"
Copy-Item -LiteralPath $packedAppImage -Destination $releaseAppImage -Force
Write-Host "Linux release ($($cloudBuildConfiguration.Environment)) is ready at $releaseAppImage" -ForegroundColor Green
