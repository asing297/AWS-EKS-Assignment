# Demo script for "update the service with a new image version and watch the rolling
# deployment": bumps the version banner in app.py, commits, and pushes. That push triggers
# the pipeline (Source -> Build -> Deploy), which builds a new image and rolls it out.
#
# Usage: .\scripts\release.ps1 -Version v2.0
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$Branch = "main"
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$appFile = Join-Path $root "app\app.py"

(Get-Content $appFile) -replace 'APP_VERSION = os\.environ\.get\("APP_VERSION", ".*?"\)', `
    "APP_VERSION = os.environ.get(`"APP_VERSION`", `"$Version`")" | Set-Content $appFile

Set-Location $root
git add app/app.py
git commit -m "Release $Version"
git push origin $Branch

Write-Host "`nPushed $Version. Watch the rollout:" -ForegroundColor Green
Write-Host "  aws codepipeline get-pipeline-state --name <env>-pipeline --region us-east-1"
Write-Host "  aws ecs describe-services --cluster <env>-cluster --services <env>-web-service --region us-east-1 --query 'services[0].deployments'"
Write-Host "Once it finishes, refresh the ALB URL - the version badge should read $Version."
