variable "aws_region" {
  type    = string
  default = "us-west-2"
}

variable "s3_bucket_name" {
  type        = string
  description = "S3 bucket for input images"
}

variable "model_data_s3_uri" {
  type        = string
  description = "S3 URI of ResNet50 model tar.gz"
}
