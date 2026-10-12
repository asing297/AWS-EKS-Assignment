# Builds the image on ECS Fargate with Kaniko (no local Docker needed) and pushes to the
# stack's ECR repo. Use this for the FIRST image only - the CI/CD pipeline (CodeBuild) builds
# every image after that.
param([string]$Region = "us-east-1", [string]$StackName = "ecs-demo2")
$ErrorActionPreference = "Continue"  # PS 5.1 turns native stderr into terminating errors under "Stop"
$acct = aws sts get-caller-identity --query Account --output text
function Out($k) { aws cloudformation describe-stacks --stack-name $StackName --region $Region --query "Stacks[0].Outputs[?OutputKey=='$k'].OutputValue" --output text }
function Res($id) { aws cloudformation describe-stack-resource --stack-name $StackName --logical-resource-id $id --region $Region --query StackResourceDetail.PhysicalResourceId --output text }
$repo = Out EcrRepositoryUri; $cluster = Out ClusterName
$bucket = "$StackName-kaniko-build-$acct"; $role = "$StackName-kaniko-task-role"
$tmp = Join-Path $env:TEMP "kaniko-$StackName"; New-Item -ItemType Directory -Force $tmp | Out-Null
$root = Split-Path $PSScriptRoot -Parent

# 1. Build context (tar.gz with Dockerfile at root) -> S3
aws s3api head-bucket --bucket $bucket 2>$null
if ($LASTEXITCODE -ne 0) { aws s3 mb "s3://$bucket" --region $Region | Out-Null }
tar -czf "$tmp\context.tar.gz" -C (Join-Path $root "app") .
aws s3 cp "$tmp\context.tar.gz" "s3://$bucket/context.tar.gz" --region $Region | Out-Null

# 2. Task role: read context, push to ECR
Set-Content "$tmp\trust.json" '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
Set-Content "$tmp\pol.json" ('{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject","s3:ListBucket","s3:GetBucketLocation"],"Resource":["arn:aws:s3:::' + $bucket + '","arn:aws:s3:::' + $bucket + '/*"]},{"Effect":"Allow","Action":"ecr:GetAuthorizationToken","Resource":"*"},{"Effect":"Allow","Action":["ecr:BatchCheckLayerAvailability","ecr:InitiateLayerUpload","ecr:UploadLayerPart","ecr:CompleteLayerUpload","ecr:PutImage","ecr:BatchGetImage","ecr:GetDownloadUrlForLayer"],"Resource":"*"}]}')
aws iam get-role --role-name $role 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { aws iam create-role --role-name $role --assume-role-policy-document "file://$tmp/trust.json" | Out-Null; Start-Sleep 10 }
aws iam put-role-policy --role-name $role --policy-name kaniko --policy-document "file://$tmp/pol.json"
$roleArn = aws iam get-role --role-name $role --query Role.Arn --output text
$execArn = aws iam get-role --role-name (Res ExecutionRole) --query Role.Arn --output text

# 3. One-off Kaniko task definition
$td = @{
  family = "$StackName-kaniko"; requiresCompatibilities = @("FARGATE"); networkMode = "awsvpc"; cpu = "1024"; memory = "2048"
  taskRoleArn = $roleArn; executionRoleArn = $execArn
  containerDefinitions = @(@{
    name = "kaniko"; image = "gcr.io/kaniko-project/executor:latest"; essential = $true
    command = @("--context", "s3://$bucket/context.tar.gz", "--dockerfile", "Dockerfile", "--destination", "${repo}:latest")
    environment = @(@{ name = "AWS_REGION"; value = $Region })
    logConfiguration = @{ logDriver = "awslogs"; options = @{ "awslogs-group" = (Res LogGroup); "awslogs-region" = $Region; "awslogs-stream-prefix" = "kaniko" } }
  })
} | ConvertTo-Json -Depth 8
Set-Content "$tmp\td.json" $td
aws ecs register-task-definition --cli-input-json "file://$tmp/td.json" --region $Region | Out-Null

# 4. Run it in the stack's public subnets, wait for exit
$net = "awsvpcConfiguration={subnets=[$(Res PublicSubnetA),$(Res PublicSubnetB)],securityGroups=[$(Res EcsSg)],assignPublicIp=ENABLED}"
$arn = aws ecs run-task --cluster $cluster --task-definition "$StackName-kaniko" --launch-type FARGATE --network-configuration $net --region $Region --query "tasks[0].taskArn" --output text
if (-not $arn -or $arn -eq "None") { throw "run-task failed" }
Write-Host "Kaniko task: $arn"
aws ecs wait tasks-stopped --cluster $cluster --tasks $arn --region $Region
$code = aws ecs describe-tasks --cluster $cluster --tasks $arn --region $Region --query "tasks[0].containers[0].[exitCode,reason]" --output text
Write-Host "Kaniko exit: $code"
aws ecr describe-images --repository-name (Res Repository) --region $Region --query "imageDetails[].imageTags" --output text
