# S3 Upload Microservice

This Terraform workspace deploys an asynchronous upload pipeline:

`API Gateway POST /` -> S3 -> SQS -> Lambda

API Gateway's VTL request template writes valid JSON directly to a private, encrypted S3 bucket. It generates an object key in `YEAR/MONTH/DAY/TIMESTAMP_REQUEST-ID.json` format using the request time and API Gateway's unique extended request ID. S3 publishes object-created events to SQS, and Lambda consumes those messages. The sample handler logs each uploaded object; replace that logic with the service's processing work. Messages that fail processing are retried and then sent to a dead-letter queue.

## Deploy

Prerequisites: Terraform 1.10+, AWS credentials configured for the CLI, and permission to create the resources in this workspace.

## Remote State Setup

Create the backend bucket manually in the AWS Console before initializing Terraform:

1. Open **Amazon S3** in `eu-north-1` and create a globally unique bucket, for example `terraform-tfstate-<account-id>-<unique-suffix>`.
2. Keep **Block all public access** enabled and **Object Ownership: Bucket owner enforced**.
3. Enable bucket versioning.
4. Enable default server-side encryption with **SSE-S3**.

The bucket must remain available while Terraform uses it. Its state versions may contain sensitive values; do not make it public or commit backend state. S3 storage and requests may incur small charges.

The S3 backend settings are in `versions.tf`. Initialize it using your AWS CLI profile named `terraform`:

```bash
cd terraform
AWS_PROFILE=terraform terraform init
terraform workspace list
```

There are no existing state snapshots to migrate. Create the `dev` and `prod` workspaces if they are not listed after initialization.

Create each application workspace and deploy it independently:

```bash
AWS_PROFILE=terraform terraform workspace new dev
AWS_PROFILE=terraform terraform plan
AWS_PROFILE=terraform terraform apply
AWS_PROFILE=terraform terraform workspace new prod
AWS_PROFILE=terraform terraform plan
AWS_PROFILE=terraform terraform apply
```

If the workspaces already exist, select each one rather than creating it again. To work in an existing environment, select it before planning or applying:

```bash
AWS_PROFILE=terraform terraform workspace select dev
AWS_PROFILE=terraform terraform plan
```

Choose the application AWS region with `-var='aws_region=eu-west-1'` or a `terraform.tfvars` file. The default is `eu-north-1`. The S3 backend region above is the state bucket's region and is configured separately.

Each workspace has its own Terraform state and deploys a separate API Gateway API, S3 bucket, SQS queue, dead-letter queue, and Lambda consumer. The workspace name is used as the API stage name and as a resource-name suffix. Select an existing environment before planning or applying:

```sh
terraform workspace select dev
terraform plan
terraform apply
```

Repeat with `prod` to update only production. Avoid deploying from the `default` workspace. GitHub Actions must use the same backend bucket, key, workspace prefix, and workspace names.

## GitHub Actions AWS Access

The workflow authenticates to AWS with GitHub OIDC, so it does not need long-lived AWS access keys in GitHub. Configure it once as follows.

1. In the GitHub repository, open **Settings > Environments** and create an environment named `production`. The workflow already references this environment. Configure deployment branch restrictions and required reviewers according to your release process.
2. In the AWS Console, open **IAM > Identity providers** and choose **Add provider**. Select **OpenID Connect**, enter `https://token.actions.githubusercontent.com` as the provider URL, and add `sts.amazonaws.com` as the audience. If this provider already exists in the account, reuse it instead of creating a duplicate.
3. In **IAM > Roles**, create a role using **Custom trust policy**. Name it, for example, `GitHubActionsTerraformRole`, and use this trust policy to allow repositories owned by `mochkai` when their job uses the `production` environment. It supports GitHub's immutable subject format (used by this repository) and the legacy format:

     ```json
     {
         "Version": "2012-10-17",
         "Statement": [
             {
                 "Effect": "Allow",
                 "Principal": {
                     "Federated": "arn:aws:iam::731802381878:oidc-provider/token.actions.githubusercontent.com"
                 },
                 "Action": "sts:AssumeRoleWithWebIdentity",
                 "Condition": {
                     "StringEquals": {
                         "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
                     },
                     "StringLike": {
                         "token.actions.githubusercontent.com:sub": [
                             "repo:mochkai@6361190/*@*:environment:production",
                             "repo:mochkai/*:environment:production"
                         ]
                     }
                 }
             }
         ]
     }
     ```

	 If you already have a GitHub OIDC provider, use its ARN in `Principal.Federated`.
4. Create a customer-managed policy named, for example, `PocTerraformPermissions`, and attach it to the role. This policy grants the Terraform role access to the state bucket and the `poc-*` application resources:

     ```json
     {
         "Version": "2012-10-17",
         "Statement": [
             {
                 "Sid": "APIGatewayPolicies",
                 "Effect": "Allow",
                 "Action": "apigateway:*",
                 "Resource": [
                     "arn:aws:apigateway:eu-north-1::/restapis",
                     "arn:aws:apigateway:eu-north-1::/restapis/*"
                 ]
             },
             {
                 "Sid": "IAMRolePolicies",
                 "Effect": "Allow",
                 "Action": [
                     "iam:CreateRole",
                     "iam:DeleteRole",
                     "iam:GetRole",
                     "iam:UpdateAssumeRolePolicy",
                     "iam:ListInstanceProfilesForRole",
                     "iam:PutRolePolicy",
                     "iam:GetRolePolicy",
                     "iam:DeleteRolePolicy",
                     "iam:ListRolePolicies",
                     "iam:AttachRolePolicy",
                     "iam:DetachRolePolicy",
                     "iam:ListAttachedRolePolicies",
                     "iam:ListRoleTags",
                     "iam:TagRole",
                     "iam:UntagRole"
                 ],
                 "Resource": "arn:aws:iam::731802381878:role/poc-*"
             },
             {
                 "Sid": "ReadLambdaExecutionPolicy",
                 "Effect": "Allow",
                 "Action": [
                     "iam:GetPolicy",
                     "iam:GetPolicyVersion"
                 ],
                 "Resource": "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
             },
             {
                 "Sid": "PassRolesToServices",
                 "Effect": "Allow",
                 "Action": "iam:PassRole",
                 "Resource": "arn:aws:iam::731802381878:role/poc-*",
                 "Condition": {
                     "StringEquals": {
                         "iam:PassedToService": [
                             "lambda.amazonaws.com",
                             "apigateway.amazonaws.com"
                         ]
                     }
                 }
             },
             {
                 "Sid": "LambdaPolicies",
                 "Effect": "Allow",
                 "Action": "lambda:*",
                 "Resource": "*",
                 "Condition": {
                     "StringEquals": {
                         "aws:RequestedRegion": "eu-north-1"
                     }
                 }
             },
             {
                 "Sid": "TerraformStateBucketLocation",
                 "Effect": "Allow",
                 "Action": "s3:GetBucketLocation",
                 "Resource": "arn:aws:s3:::terraform-tfstate-731802381878-eu-north-1-an"
             },
             {
                 "Sid": "TerraformStateBucketList",
                 "Effect": "Allow",
                 "Action": "s3:ListBucket",
                 "Resource": "arn:aws:s3:::terraform-tfstate-731802381878-eu-north-1-an",
                 "Condition": {
                     "StringLike": {
                         "s3:prefix": [
                             "terraform-demo/",
                             "terraform-demo/*"
                         ]
                     }
                 }
             },
             {
                 "Sid": "TerraformStateObjectsAndLocks",
                 "Effect": "Allow",
                 "Action": [
                     "s3:GetObject",
                     "s3:PutObject",
                     "s3:DeleteObject"
                 ],
                 "Resource": [
                     "arn:aws:s3:::terraform-tfstate-731802381878-eu-north-1-an/terraform.tfstate",
                     "arn:aws:s3:::terraform-tfstate-731802381878-eu-north-1-an/terraform.tfstate.tflock",
                     "arn:aws:s3:::terraform-tfstate-731802381878-eu-north-1-an/terraform-demo/*"
                 ]
             },
             {
                 "Sid": "POCS3BucketPolicies",
                 "Effect": "Allow",
                 "Action": "s3:*",
                 "Resource": "arn:aws:s3:::poc-*"
             },
             {
                 "Sid": "POCS3ObjectPolicies",
                 "Effect": "Allow",
                 "Action": "s3:*",
                 "Resource": "arn:aws:s3:::poc-*/*"
             },
             {
                 "Sid": "POCSQSQueuePolicies",
                 "Effect": "Allow",
                 "Action": "sqs:*",
                 "Resource": "arn:aws:sqs:eu-north-1:731802381878:poc-*"
             },
             {
                 "Sid": "SQSListQueuePolicies",
                 "Effect": "Allow",
                 "Action": "sqs:ListQueues",
                 "Resource": "*"
             }
         ]
     }
     ```

     Review this policy before use. The S3 and SQS wildcards allow full control over `poc-*` resources, and the Lambda wildcard allows all Lambda actions in `eu-north-1`. IAM role actions are explicit, and `iam:PassRole` is limited to Lambda and API Gateway. The state bucket permissions are deliberately separate and do not allow deleting the bucket.
5. Copy the role ARN from IAM. In GitHub, open **Settings > Secrets and variables > Actions**, create a repository secret named `AWS_ROLE_ARN`, and set its value to the role ARN. The workflow already uses this secret and requests `id-token: write`.
6. Push a change or open a pull request and check the **Configure AWS credentials** step. If it reports `Not authorized to perform sts:AssumeRoleWithWebIdentity`, verify the provider URL, audience, owner name, environment name, and role trust policy.

The immutable pattern uses GitHub owner ID `6361190` and allows any repository under that owner to assume this role when using the `production` environment. The legacy pattern supports repositories that still emit name-only subjects. Those repositories share the role's AWS permissions and Terraform backend state. Use separate roles and state keys for projects that should be isolated; do not use these patterns for unrelated or untrusted repositories.

The current workflow assigns the `production` environment to the whole job, including pull-request plans. Required reviewers can therefore pause those plans, and branch restrictions may prevent them from running. The trust policy above intentionally accepts only jobs using that environment. For a smoother and safer release flow, separate pull-request planning from production apply so only the apply job uses the protected `production` environment.

## Upload

The API endpoint is intentionally unauthenticated for a quick demo. Upload only non-sensitive test data, and add authentication, throttling, and request limits before exposing it to real users.

```sh
UPLOAD_URL=$(terraform output -raw api_upload_url)
curl --fail-with-body -X POST -H 'Content-Type: application/json' --data-binary @./example.json "$UPLOAD_URL"
```

The key is generated by API Gateway from its request timestamp and extended request ID. The consumer Lambda's CloudWatch log shows the stored bucket and key. The bucket name and queue URLs are available through Terraform outputs.

## Cleanup

```sh
terraform destroy
```

The bucket is configured for force deletion so uploaded objects do not prevent cleanup. Do not use this setting for a bucket that must retain data.