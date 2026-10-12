# Manually change desired count and watch new tasks start.
# Note: Service Auto Scaling (CPU + ALB request count target tracking) is also active on this
# service, so it may adjust the count again a minute or two after this script finishes if the
# triggering metric isn't actually at target - that's expected, not a bug.
param([int]$Count = 4, [string]$Region = "us-east-1", [string]$Cluster = "demo2-cluster", [string]$Service = "demo2-web-service")
aws ecs update-service --cluster $Cluster --service $Service --desired-count $Count --region $Region | Out-Null
1..12 | ForEach-Object {
    aws ecs describe-services --cluster $Cluster --services $Service --region $Region `
        --query "services[0].{desired:desiredCount,running:runningCount,pending:pendingCount}" --output text
    Start-Sleep 10
}
