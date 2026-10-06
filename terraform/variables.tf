variable "aws_region" {
  description = "AWS region for the service."
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Lowercase prefix used to name the service resources."
  type        = string
  default     = "poc-d-coders"

  validation {
    condition     = can(regex("^poc-[a-z][a-z0-9-]{2,19}$", var.project_name))
    error_message = "project_name must be 3-20 characters, start with 'poc-', and contain only lowercase letters, numbers, or hyphens."
  }
}
