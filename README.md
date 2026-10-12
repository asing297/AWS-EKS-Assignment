# Scalable AWS App: ECS Fargate + Auto Scaling + CI/CD + Monitoring

> **Note on the title:** the assignment is titled "...EKS Application..." but every requirement in
> it (ECS Fargate, Task Definitions, ECS Service Auto Scaling, an ECS deploy action in
> CodePipeline) is **ECS**, not Kubernetes/EKS. This project implements the requirements as
> written, extending the ECS Fargate stack built for the first assignment (kept in the separate
> `aws-ecs-assignment` folder, untouched) rather than switching to a Kubernetes cluster.

## Architecture
```
GitHub repo --push--> CodePipeline (Source: CodeStarSourceConnection)
                           |
                           v
                      CodeBuild (buildspec.yml: docker build, push to ECR, imagedefinitions.json)
                           |
                           v
                      ECS deploy action --rolling update--> ECS Service (2 AZs, Fargate)
                                                                   ^
                                                     Service Auto Scaling (CPU + ALB req/target)
                                                                   |
Internet -> ALB (public subnets, :80) -> ECS Fargate tasks (SG: only from ALB, egress 443+5432 only)
                                              |  (SG: only ECS SG may reach :5432, no egress)
                                              v
                                   RDS PostgreSQL (private subnets, no public route, Multi-AZ if EnvType=prod)

Logs -> CloudWatch Logs (/ecs/<env>-web-app) + 3 saved Logs Insights queries
Metrics -> Container Insights (enhanced) + Dashboard (latency/errors/requests) + Alarms -> SNS email
```

## Repository layout
| Path | Purpose |
|---|---|
| `app/` | Flask app (version badge, DB visit counter, `/health`, `/version`), Dockerfile |
| `template.yaml` | The whole stack: VPC, RDS, ECR, ECS + Auto Scaling, ALB, CI/CD pipeline, logs, dashboards, alarms, SNS |
| `buildspec.yml` | CodeBuild: `docker build` -> push to ECR -> write `imagedefinitions.json` for the ECS deploy action |
| `scripts/deploy.ps1` | Phase 1-3 deploy: infra (change set, reviewed) -> first image -> scale up |
| `scripts/push-to-github.ps1` | One-time: push this folder to your GitHub repo |
| `scripts/release.ps1` | Bump the app version, commit, push - triggers the pipeline, demos a rolling deployment |
| `scripts/scale.ps1` | Manually change desired count (Auto Scaling may re-adjust afterwards) |
| `scripts/build-image-kaniko.ps1` | Builds the first image on Fargate if local Docker isn't available |
| `scripts/cleanup.ps1` | Empties the versioned artifact bucket, then deletes the stack |

## Prerequisites
- AWS CLI v2 configured (`aws configure`)
- A GitHub repo (empty, no README/.gitignore) - see "GitHub setup" below
- An email address for alarms
- Local Docker is optional - `deploy.ps1` falls back to building the first image on Fargate with Kaniko if Docker isn't running

## GitHub setup
1. Create an empty repo on github.com (no README/.gitignore).
2. Run `.\scripts\push-to-github.ps1 -RepoUrl https://github.com/<you>/<repo>.git` - this pushes
   `app/`, `template.yaml`, `buildspec.yml` and the scripts. (It does **not** need to run first -
   the pipeline's first execution will simply fail until both this push and the connection
   authorization below are done; re-running the pipeline afterwards picks it up.)

## Deploy
```powershell
.\scripts\deploy.ps1 -AlarmEmail you@example.com -GitHubRepo <you>/<repo> -Region us-east-1
```
This:
1. Deploys all infra with `DesiredCount=0` as a **reviewed change set** (`--no-execute-changeset`,
   prints the change set, asks before executing). The ECR repo and the pipeline are both managed
   by the same template, so they exist before anything tries to push to or trigger them.
2. Builds and pushes the first image (local Docker if running, else Kaniko on Fargate).
3. Scales the service up to `-DesiredCount` (default 2) across both AZs, another reviewed change set.
4. Prints the one manual step left: **authorize the GitHub connection** (console -> Developer
   Tools -> Settings -> Connections -> the `<env>-github` connection -> "Update pending connection"
   -> sign in to GitHub and approve). This is a GitHub OAuth handshake; it cannot be done through
   the CLI by anyone, not just me - AWS requires a logged-in browser click here.

Parameters (`template.yaml`): `DeployRegion`, `EnvName`, **`EnvType`** (`dev`/`prod` - drives RDS
Multi-AZ and log retention via the `EnvironmentConfig` mapping), `TaskCpu`, `TaskMemory`,
`MinCapacity`/`MaxCapacity` (Auto Scaling bounds), `DbInstanceClass`, `BackupRetentionDays`,
`GitHubRepo`, `GitHubBranch`, `AlarmEmail`.

Validate before deploying: `aws cloudformation validate-template --template-body file://template.yaml`

## Demos

**CI/CD trigger on a git commit:**
```powershell
.\scripts\release.ps1 -Version v2.0
```
Bumps the version badge in `app/app.py`, commits, and pushes. Watch it run:
`aws codepipeline get-pipeline-state --name demo2-pipeline --region us-east-1`, or the console
(Pipeline URL from `deploy.ps1`'s output). When it finishes, refresh the ALB URL - the badge reads v2.0.

**Rolling deployment:** the same `release.ps1` push is the demo. The ECS deploy action registers
a new task definition revision with the new image and updates the service; `DeploymentConfiguration`
(`MaximumPercent: 200`, `MinimumHealthyPercent: 100`, circuit breaker with auto-rollback) keeps the
old tasks serving traffic until the new ones pass health checks. Watch it with:
`aws ecs describe-services --cluster demo2-cluster --services demo2-web-service --region us-east-1 --query "services[0].deployments"`

**Auto Scaling:** load the ALB URL repeatedly (or `ab`/`hey`/a loop of `curl`) until ECS CPU or
ALB requests-per-target cross the target tracking thresholds (60% CPU / 100 req per target).
`aws application-autoscaling describe-scaling-activities --service-namespace ecs --region us-east-1`
shows the scale-out/scale-in events.

**Manual scale (still useful to show the mechanism directly):**
```powershell
.\scripts\scale.ps1 -Count 4
```

**Logs Insights:** console -> CloudWatch -> Logs -> Logs Insights -> pick the log group
`/ecs/demo2-web-app` and one of the three saved queries (`demo2-errors-and-5xx`,
`demo2-status-code-breakdown`, `demo2-requests-by-path`) from the "Saved queries" panel - these
were created by the template as `AWS::Logs::QueryDefinition` resources, not by hand.

## Notes from the actual deployment
- Carried over from the first assignment: the AWS account is on the free plan, which caps RDS
  `BackupRetentionPeriod` at 1 day and (at the time) CodeBuild's concurrent-build quota at 0.
  `deploy.ps1` defaults `BackupRetentionDays` to 1 for that reason; raise it on a paid account.
  If CodeBuild still reports a 0 quota the first time the pipeline runs, request a quota increase
  (Service Quotas console) - the pipeline will simply sit retrying the Build stage until it's granted.
- Docker Desktop could not run on this machine (virtualization disabled in BIOS/by IT policy), so
  the **first** image is built with Kaniko on Fargate (`scripts/build-image-kaniko.ps1`). Every
  image **after** that is built by CodeBuild in the pipeline, which doesn't depend on local Docker
  at all - this limitation only affects bootstrapping.
- **Once the pipeline has deployed at least once, don't change `ImageTag` and redeploy
  `deploy.ps1`.** CloudFormation only re-points the ECS service at a different task definition
  revision when the `TaskDefinition` resource's *rendered* properties change; since `ImageTag`
  stays `latest` by default, redeploying the stack for unrelated infra changes (e.g. bumping
  `MaxCapacity`) does **not** revert the service to an old image. But a deliberate `ImageTag`
  change would. After CI/CD is live, ship app changes through `release.ps1` / a git push, not
  through the stack's `ImageTag` parameter.
- Security groups: egress is explicit and minimal - ALB only to the ECS tasks on 8080, ECS tasks
  only to the DB on 5432 and to the internet on 443 (ECR/Secrets Manager/CloudWatch Logs API calls -
  there are no VPC endpoints in this stack, by design, to avoid their hourly cost), RDS has no
  egress at all. Two security-group rules (`AlbSg`<->`EcsSg`, `EcsSg`<->`DbSg`) are declared as
  separate `AWS::EC2::SecurityGroupEgress`/`Ingress` resources instead of inline, because the
  inline, mutually-referencing form creates a circular dependency CloudFormation rejects.

## Requirement mapping
| Requirement | Where |
|---|---|
| Least-privilege SGs between ALB/ECS/RDS | `AlbSg`/`EcsSg`/`DbSg` + explicit `...Egress` resources (see note above); RDS has no egress |
| RDS tier has no public route | `PrivateRouteTable` has only the local VPC route, no `0.0.0.0/0` -> IGW; `Database.PubliclyAccessible: false` |
| ECS across 2 AZs behind ALB | `PublicSubnetA/B` (different AZs), `Service.NetworkConfiguration.Subnets`, `LoadBalancer.Subnets` |
| Service Auto Scaling (CPU or request count) | `ScalableTarget`, `CpuScalingPolicy` (CPU 60%), `RequestCountScalingPolicy` (ALB req/target 100) |
| Update to a new image version + rolling deployment | `scripts/release.ps1`, `Service.DeploymentConfiguration` (circuit breaker + rollback) |
| ECR image scanning | `Repository.ImageScanningConfiguration.ScanOnPush: true` |
| CodePipeline + CodeBuild: source -> build -> push -> deploy | `Pipeline` (3 stages), `CodeBuildProject`, `buildspec.yml` |
| Automatic trigger on a git commit | `CodeStarSourceConnection` action, `DetectChanges: true` |
| S3 build artifacts with versioning | `ArtifactBucket.VersioningConfiguration: Enabled` |
| Dashboards: latency, error rate, request count | `Dashboard` widgets "ALB Latency", "Error Rate (%)", "Request Count" |
| Alarms -> SNS email | `EcsCpuAlarm`, `Alb5xxAlarm`, `AlbLatencyAlarm`, `RdsCpuAlarm` -> `AlarmTopic` |
| CloudWatch Logs Insights, query/filter ECS logs | `ErrorsQueryDefinition`, `StatusBreakdownQueryDefinition`, `SlowestRequestsQueryDefinition` |
| Container Insights, task/service metrics | `ClusterSettings: containerInsights=enhanced` |
| Extend the L1 template with pipeline + auto scaling | this `template.yaml` (plain L1 resources throughout, no CDK/L2 constructs) |
| Parameterize per environment | `EnvType` parameter + `EnvironmentConfig` mapping (RDS Multi-AZ, log retention); `TaskCpu`/`TaskMemory`/`DbInstanceClass`/`MinCapacity`/`MaxCapacity` also overridable per deploy |
| Review the change set before deploying | `deploy.ps1`'s `Deploy-Stack` function: `--no-execute-changeset`, prints it, asks y/N |

## Screenshot checklist (deliverable)
1. Security groups: `EcsSg` inbound (only from `AlbSg`) and outbound (only 443 + 5432); `DbSg`
   inbound (only from `EcsSg`) and outbound (the 127.0.0.1 deny-all placeholder).
2. RDS route table: no `0.0.0.0/0` route in the private route table.
3. ECS service: 2 running tasks in 2 different AZs (Tasks tab, Availability Zone column).
4. Auto Scaling: `ScalableTarget`/scaling policies in the console (ECS service -> Auto Scaling tab),
   plus a scale-out event in `describe-scaling-activities` or the Tasks tab after generating load.
5. A completed pipeline run: Source -> Build -> Deploy all green, after `release.ps1`.
6. The app in the browser showing the bumped version badge after that deployment.
7. ECR: image scanning findings (or "no findings") on a pushed image.
8. CodePipeline + CodeBuild + the S3 artifact bucket's Properties tab showing Versioning: Enabled.
9. CloudFormation: the reviewed change set (Changes tab) before execution, then `UPDATE_COMPLETE`.
10. CloudWatch dashboard: the Latency, Error Rate and Request Count widgets with data.
11. An alarm in ALARM state + the SNS email.
12. CloudWatch Logs Insights: one of the three saved queries run against `/ecs/demo2-web-app`.
13. Container Insights: task/service metrics for `demo2-cluster`.
14. After cleanup: stack `DELETE_COMPLETE` / cluster gone.

## Cost note
Adds roughly $0.10-0.30/day over the first assignment's stack (CodePipeline's $1/active-pipeline/
month, CodeBuild per-build-minute, negligible S3 artifact storage). No NAT gateway and no VPC
endpoints are used. Run `cleanup.ps1` when finished - it empties the versioned artifact bucket
first (CloudFormation can't delete a non-empty S3 bucket on its own) and then deletes the stack.
