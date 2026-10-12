# One-time: initializes this folder as a git repo (if needed) and pushes it to GitHub.
# This first push is also what the pipeline's Source stage will pick up once the
# CodeStar connection is authorized (see deploy.ps1's final instructions).
#
# Usage: .\scripts\push-to-github.ps1 -RepoUrl https://github.com/you/aws-eks-assignment.git
param(
    [Parameter(Mandatory)][string]$RepoUrl,
    [string]$Branch = "main",
    [string]$Message = "Initial commit: ECS Fargate app, CloudFormation stack, CI/CD pipeline"
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

if (-not (Test-Path ".git")) {
    git init -b $Branch
}
if (-not (Test-Path ".gitignore")) {
    @("__pycache__/", "*.pyc", ".env", "Thumbs.db") | Set-Content ".gitignore"
}

git add -A
git commit -m $Message
try { git branch -M $Branch } catch {}

$hasOrigin = git remote | Select-String -Quiet "^origin$"
if ($hasOrigin) { git remote set-url origin $RepoUrl } else { git remote add origin $RepoUrl }

git push -u origin $Branch
Write-Host "`nPushed to $RepoUrl ($Branch)." -ForegroundColor Green
Write-Host "If the GitHub connection is already authorized, the pipeline should start now - check the Pipeline URL from deploy.ps1's output."
