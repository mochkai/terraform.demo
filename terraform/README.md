# S3 Upload Microservice

This Terraform workspace deploys an asynchronous upload pipeline:

`API Gateway PUT /{object}` -> S3 -> SQS -> Lambda

API Gateway writes the request body directly to a private, encrypted S3 bucket. S3 publishes object-created events to SQS, and Lambda consumes those messages. The sample handler logs each uploaded object; replace that logic with the service's processing work. Messages that fail processing are retried and then sent to a dead-letter queue.

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

## Upload

The API endpoint is intentionally unauthenticated for a quick demo. Upload only non-sensitive test data, and add authentication, throttling, and request limits before exposing it to real users.

```sh
UPLOAD_URL=$(terraform output -raw api_upload_url)
curl --fail-with-body -X PUT --data-binary @./example.json "${UPLOAD_URL/\{object\}/example.json}"
```

Check the Lambda function's CloudWatch log group for the uploaded bucket and object key. The bucket name and queue URLs are available through Terraform outputs.

## Cleanup

```sh
terraform destroy
```

The bucket is configured for force deletion so uploaded objects do not prevent cleanup. Do not use this setting for a bucket that must retain data.