param(
    [string]$Python = "python",
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$spec = Join-Path $root "packaging\AutoPlaylistBuilder.spec"

if (-not (Test-Path $spec)) {
    throw "Spec file not found at $spec"
}

$env:KIVY_NO_ARGS = "1"

$arguments = @($spec)
if ($Clean.IsPresent) {
    $arguments = @("--clean") + $arguments
}

& $Python -m PyInstaller @arguments
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host "\nPyInstaller build completed. Check the 'dist\\AutoPlaylistBuilder' directory." -ForegroundColor Green
