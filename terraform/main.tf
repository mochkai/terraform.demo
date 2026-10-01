data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  environment  = terraform.workspace
  service_name = "${var.project_name}-${local.environment}"
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "payloads" {
  bucket        = "${local.service_name}-${random_id.bucket_suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "payloads" {
  bucket                  = aws_s3_bucket.payloads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "payloads" {
  bucket = aws_s3_bucket.payloads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_sqs_queue" "dead_letter" {
  name                      = "${local.service_name}-dead-letter"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "events" {
  name                       = "${local.service_name}-events"
  visibility_timeout_seconds = 180
  message_retention_seconds  = 345600
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead_letter.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_policy" "events" {
  queue_url = aws_sqs_queue.events.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowS3BucketNotifications"
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.events.arn
      Condition = {
        ArnEquals      = { "aws:SourceArn" = aws_s3_bucket.payloads.arn }
        StringEquals   = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_s3_bucket_notification" "payloads" {
  bucket = aws_s3_bucket.payloads.id

  queue {
    queue_arn = aws_sqs_queue.events.arn
    events    = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_sqs_queue_policy.events]
}

resource "aws_iam_role" "lambda" {
  name = "${local.service_name}-lambda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_sqs" {
  name = "${local.service_name}-read-events"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:ChangeMessageVisibility"
      ]
      Resource = aws_sqs_queue.events.arn
    }]
  })
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../lambda/handler.py"
  output_path = "${path.module}/.terraform/lambda.zip"
}

resource "aws_lambda_function" "consumer" {
  function_name    = "${local.service_name}-consumer"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      UPLOAD_BUCKET = aws_s3_bucket.payloads.bucket
    }
  }
}

resource "aws_lambda_event_source_mapping" "events" {
  event_source_arn = aws_sqs_queue.events.arn
  function_name    = aws_lambda_function.consumer.arn
  batch_size       = 10
  enabled          = true

  depends_on = [aws_iam_role_policy.lambda_sqs]
}

resource "aws_iam_role" "api_gateway" {
  name = "${local.service_name}-api-gateway"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "api_gateway_s3" {
  name = "${local.service_name}-put-payloads"
  role = aws_iam_role.api_gateway.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "s3:PutObject"
      Resource = "${aws_s3_bucket.payloads.arn}/*"
    }]
  })
}

resource "aws_api_gateway_rest_api" "payloads" {
  name        = "${local.service_name}-payloads"
  description = "Upload objects for asynchronous processing."
}

resource "aws_api_gateway_resource" "object" {
  rest_api_id = aws_api_gateway_rest_api.payloads.id
  parent_id   = aws_api_gateway_rest_api.payloads.root_resource_id
  path_part   = "{object}"
}

resource "aws_api_gateway_method" "put_object" {
  rest_api_id   = aws_api_gateway_rest_api.payloads.id
  resource_id   = aws_api_gateway_resource.object.id
  http_method   = "PUT"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.object" = true
  }
}

resource "aws_api_gateway_integration" "s3_put_object" {
  rest_api_id             = aws_api_gateway_rest_api.payloads.id
  resource_id             = aws_api_gateway_resource.object.id
  http_method             = aws_api_gateway_method.put_object.http_method
  integration_http_method = "PUT"
  type                    = "AWS"
  credentials             = aws_iam_role.api_gateway.arn
  uri                     = "arn:aws:apigateway:${data.aws_region.current.name}:s3:path/${aws_s3_bucket.payloads.bucket}/{object}"
  request_parameters = {
    "integration.request.path.object" = "method.request.path.object"
  }
}

resource "aws_api_gateway_deployment" "environment" {
  rest_api_id = aws_api_gateway_rest_api.payloads.id
  triggers = {
    redeployment = sha1(jsonencode({
      method = {
        http_method   = aws_api_gateway_method.put_object.http_method
        authorization = aws_api_gateway_method.put_object.authorization
      }
      integration = {
        type                    = aws_api_gateway_integration.s3_put_object.type
        integration_http_method = aws_api_gateway_integration.s3_put_object.integration_http_method
        uri                     = aws_api_gateway_integration.s3_put_object.uri
        credentials             = aws_api_gateway_integration.s3_put_object.credentials
        request_parameters      = aws_api_gateway_integration.s3_put_object.request_parameters
      }
    }))
  }

  depends_on = [aws_api_gateway_integration.s3_put_object]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "environment" {
  rest_api_id   = aws_api_gateway_rest_api.payloads.id
  deployment_id = aws_api_gateway_deployment.environment.id
  stage_name    = local.environment
}