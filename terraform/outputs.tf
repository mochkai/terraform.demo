output "upload_bucket_name" {
  description = "S3 bucket receiving API uploads."
  value       = aws_s3_bucket.payloads.bucket
}

output "events_queue_url" {
  description = "SQS queue receiving S3 object-created notifications."
  value       = aws_sqs_queue.events.url
}

output "dead_letter_queue_url" {
  description = "Queue holding events that fail repeated processing attempts."
  value       = aws_sqs_queue.dead_letter.url
}

output "api_upload_url" {
  description = "Public POST endpoint for this workspace; send a JSON body to create a dated S3 object."
  value       = aws_api_gateway_stage.environment.invoke_url
}