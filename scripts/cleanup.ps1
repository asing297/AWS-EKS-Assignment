# Deletes everything (pipeline, service, cluster, RDS, ALB, ECR repo incl. images) to stop charges.
param([string]$Region = "us-east-1", [string]$StackName = "ecs-demo2")
$ErrorActionPreference = "Continue"

function Empty-VersionedBucket([string]$Bucket) {
    if (-not $Bucket -or $Bucket -eq "None") { return }
    Write-Host "Emptying versioned bucket $Bucket ..."
    while ($true) {
        $versions = aws s3api list-object-versions --bucket $Bucket --max-items 1000 `
            --query "{Objects: Versions[].{Key:Key,VersionId:VersionId}, Markers: DeleteMarkers[].{Key:Key,VersionId:VersionId}}" `
            --output json | ConvertFrom-Json
        $toDelete = @()
        if ($versions.Objects) { $toDelete += $versions.Objects }
        if ($versions.Markers) { $toDelete += $versions.Markers }
        if (-not $toDelete -or $toDelete.Count -eq 0) { break }
        $payload = @{ Objects = $toDelete; Quiet = $true } | ConvertTo-Json -Depth 5 -Compress
        $payload | Out-File -Encoding utf8 "$env:TEMP\delete-batch.json"
        aws s3api delete-objects --bucket $Bucket --delete "file://$env:TEMP/delete-batch.json" --region $Region | Out-Null
    }
}

# 1. Pre-empty the versioned pipeline artifact bucket - CloudFormation cannot delete a
#    non-empty S3 bucket even with DeletionPolicy: Delete.
$artifactBucket = aws cloudformation describe-stack-resource --stack-name $StackName `
    --logical-resource-id ArtifactBucket --region $Region `
    --query "StackResourceDetail.PhysicalResourceId" --output text 2>$null
Empty-VersionedBucket $artifactBucket

# 2. Delete the stack (RDS, ECS, ALB, ECR, pipeline, VPC, alarms, dashboard, IAM roles, S3 bucket)
aws cloudformation delete-stack --stack-name $StackName --region $Region
aws cloudformation wait stack-delete-complete --stack-name $StackName --region $Region
Write-Host "Stack $StackName deleted."

# 3. Helper resources created by build-image-kaniko.ps1 (ignore errors if never created)
$acct = aws sts get-caller-identity --query Account --output text
$kanikoBucket = "$StackName-kaniko-build-$acct"
aws s3 rb "s3://$kanikoBucket" --force --region $Region
aws iam delete-role-policy --role-name "$StackName-kaniko-task-role" --policy-name kaniko 2>$null
aws iam delete-role --role-name "$StackName-kaniko-task-role" 2>$null
aws ecs deregister-task-definition --task-definition "$StackName-kaniko:1" --region $Region 2>$null | Out-Null

Write-Host "`nDone. Remember: the GitHub repo and the GitHub connection authorization are independent of" -ForegroundColor Cyan
Write-Host "this AWS stack - nothing on GitHub needs cleaning up." -ForegroundColor Cyan
