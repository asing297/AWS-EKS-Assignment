# End-to-end deploy. Usage:
#   .\scripts\deploy.ps1 -AlarmEmail you@example.com -GitHubRepo yourname/aws-eks-assignment [-Region us-east-1]
#
# Does three things, each as a reviewed CloudFormation change set:
#   1. Deploys all infra (VPC, RDS, ECR, ECS, ALB, pipeline, alarms, dashboard) with DesiredCount=0 -
#      the ECR repo and pipeline, both managed by the same template, must exist before anything can push to them.
#   2. Builds + pushes the first image (via Kaniko on Fargate - no local Docker needed; uses local
#      Docker instead if it's running) so the service has something to run.
#   3. Scales the service up to -DesiredCount (default 2) across both AZs.
param(
    [Parameter(Mandatory)][string]$AlarmEmail,
    [Parameter(Mandatory)][string]$GitHubRepo,
    [string]$GitHubBranch = "main",
    [string]$Region = "us-east-1",
    [string]$StackName = "ecs-demo2",
    [string]$EnvType = "dev",
    [int]$DesiredCount = 2,
    [int]$MinCapacity = 1,
    [int]$MaxCapacity = 4,
    [string]$TaskCpu = "256",
    [string]$TaskMemory = "512",
    [string]$DbInstanceClass = "db.t3.micro",
    [int]$BackupRetentionDays = 1   # the AWS free plan caps this at 1; raise it on a paid account
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$tpl  = Join-Path $root "template.yaml"

function Get-Out($key) {
    aws cloudformation describe-stacks --stack-name $StackName --region $Region `
        --query "Stacks[0].Outputs[?OutputKey=='$key'].OutputValue" --output text
}

function Deploy-Stack([int]$count) {
    $params = @("DeployRegion=$Region", "AlarmEmail=$AlarmEmail", "DesiredCount=$count",
                "GitHubRepo=$GitHubRepo", "GitHubBranch=$GitHubBranch", "EnvType=$EnvType",
                "MinCapacity=$MinCapacity", "MaxCapacity=$MaxCapacity",
                "TaskCpu=$TaskCpu", "TaskMemory=$TaskMemory", "DbInstanceClass=$DbInstanceClass",
                "BackupRetentionDays=$BackupRetentionDays")
    # 1. Create the change set but DO NOT execute it
    aws cloudformation deploy --stack-name $StackName --template-file $tpl --region $Region `
        --capabilities CAPABILITY_IAM --parameter-overrides $params --no-execute-changeset
    if ($LASTEXITCODE -ne 0) { Write-Host "No changes / change set failed."; return }

    # 2. Review the change set
    $cs = aws cloudformation list-change-sets --stack-name $StackName --region $Region `
        --query "sort_by(Summaries,&CreationTime)[-1].ChangeSetName" --output text
    Write-Host "`n=== Change set: $cs ===" -ForegroundColor Cyan
    aws cloudformation describe-change-set --stack-name $StackName --change-set-name $cs --region $Region `
        --query "Changes[].ResourceChange.{Action:Action,Type:ResourceType,Id:LogicalResourceId,Replace:Replacement}" --output table
    if ((Read-Host "Execute this change set? (y/N)") -ne "y") { Write-Host "Aborted."; exit 1 }

    # 3. Execute
    aws cloudformation execute-change-set --stack-name $StackName --change-set-name $cs --region $Region
    aws cloudformation wait stack-create-complete --stack-name $StackName --region $Region 2>$null
    aws cloudformation wait stack-update-complete --stack-name $StackName --region $Region 2>$null
}

# Phase 1: infra with 0 tasks (ECR repo + pipeline must exist before anything can be pushed/built)
Deploy-Stack 0

# Phase 2: build + push the first image
$repo = Get-Out "EcrRepositoryUri"
docker info 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    $registry = $repo.Split("/")[0]
    aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin $registry
    docker build -t "${repo}:latest" (Join-Path $root "app")
    docker push "${repo}:latest"
} else {
    Write-Host "Local Docker not available - building on Fargate with Kaniko instead." -ForegroundColor Yellow
    & "$PSScriptRoot\build-image-kaniko.ps1" -Region $Region -StackName $StackName
}

# Phase 3: start the tasks (Auto Scaling then takes over desired count based on load)
Deploy-Stack $DesiredCount

Write-Host "`nApp URL: $(Get-Out 'AlbUrl')" -ForegroundColor Green
Write-Host "Dashboard: $(Get-Out 'DashboardUrl')"
Write-Host "Pipeline: $(Get-Out 'PipelineUrl')"
Write-Host "`nONE MANUAL STEP LEFT: authorize the GitHub connection." -ForegroundColor Yellow
Write-Host "  1. Open: $(Get-Out 'GitHubConnectionConsoleUrl')"
Write-Host "  2. Click the '$StackName-github' connection -> Update pending connection -> authorize with GitHub."
Write-Host "  3. Push to '$GitHubBranch' on $GitHubRepo (scripts\push-to-github.ps1) to trigger the pipeline."
Write-Host "`nConfirm the SNS subscription email, or alarms will not notify you."
