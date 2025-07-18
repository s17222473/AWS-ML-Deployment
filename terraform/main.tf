terraform {
  required_version = ">= 1.2"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# VPC
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.1"
  name = "inference-vpc"
  cidr = "10.0.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = ["10.0.1.0/24","10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24","10.0.102.0/24"]
  enable_nat_gateway = true
  single_nat_gateway = true
}

data "aws_availability_zones" "available" {}

# S3 bucket
resource "aws_s3_bucket" "images" {
  bucket = var.s3_bucket_name
  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
  tags = { Name = "inference-input-bucket" }
}

# Cognito User Pool
resource "aws_cognito_user_pool" "userpool" {
  name = "inference-userpool"
  auto_verified_attributes = ["email"]
}
resource "aws_cognito_user_pool_client" "app_client" {
  name         = "frontend-client"
  user_pool_id = aws_cognito_user_pool.userpool.id
  generate_secret = false
  explicit_auth_flows = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
}

# IAM roles
resource "aws_iam_role" "lambda_role" {
  name = "inference-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}
resource "aws_iam_role_policy" "lambda_policy" {
  name = "lambda-invoke-sagemaker"
  role = aws_iam_role.lambda_role.id
  policy = data.aws_iam_policy_document.lambda.json
}
data "aws_iam_policy_document" "lambda" {
  statement {
    actions   = ["sagemaker:InvokeEndpoint", "s3:PutObject"]
    resources = ["*"]
  }
  statement {
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "sagemaker_role" {
  name = "inference-sagemaker-role"
  assume_role_policy = data.aws_iam_policy_document.sagemaker_assume.json
}
data "aws_iam_policy_document" "sagemaker_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}
resource "aws_iam_role_policy" "sagemaker_policy" {
  name = "sagemaker-s3-access"
  role = aws_iam_role.sagemaker_role.id
  policy = data.aws_iam_policy_document.sagemaker.json
}
data "aws_iam_policy_document" "sagemaker" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.images.arn}/*"]
  }
  statement {
    actions   = ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"]
    resources = ["*"]
  }
}

# SageMaker model & endpoint
resource "aws_sagemaker_model" "resnet50" {
  name                 = "resnet50-model"
  execution_role_arn   = aws_iam_role.sagemaker_role.arn
  primary_container {
    image = "763104351884.dkr.ecr.${var.aws_region}.amazonaws.com/pytorch-inference:latest-gpu-py38-cpu"
    model_data_url = var.model_data_s3_uri
  }
}

resource "aws_sagemaker_endpoint_configuration" "resnet50_config" {
  name = "resnet50-endpoint-config"
  production_variants {
    variant_name = "AllTraffic"
    model_name   = aws_sagemaker_model.resnet50.name
    instance_type   = "ml.m5.large"
    initial_instance_count = 1
  }
}

resource "aws_sagemaker_endpoint" "resnet50_ep" {
  name = "resnet50-endpoint"
  endpoint_config_name = aws_sagemaker_endpoint_configuration.resnet50_config.name
}

# API Gateway + Lambda
resource "aws_lambda_function" "predict" {
  filename         = "${path.module}/../lambda/predict.zip"
  function_name    = "inference-predict"
  handler          = "handler.handler"
  runtime          = "python3.9"
  role             = aws_iam_role.lambda_role.arn
  timeout          = 10
  environment {
    variables = {
      ENDPOINT_NAME = aws_sagemaker_endpoint.resnet50_ep.name
      BUCKET_NAME   = aws_s3_bucket.images.bucket
    }
  }
}

resource "aws_apigatewayv2_api" "api" {
  name          = "inference-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_int" {
  api_id = aws_apigatewayv2_api.api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.predict.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "predict_route" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /predict"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_int.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}

# Cognito Authorizer
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id             = aws_apigatewayv2_api.api.id
  name               = "cognito-authorizer"
  authorizer_type    = "JWT"
  identity_sources   = ["$request.header.Authorization"]
  jwt_configuration {
    audience = [aws_cognito_user_pool_client.app_client.id]
    issuer   = aws_cognito_user_pool.userpool.endpoint
  }
}

resource "aws_apigatewayv2_route" "secure_route" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /predict"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_int.id}"
  authorization_type = "JWT"
  authorizer_id       = aws_apigatewayv2_authorizer.cognito.id
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "high_latency" {
  alarm_name          = "HighInferenceLatency"
  metric_name         = "Latency"
  namespace           = "AWS/SageMaker"
  statistic           = "p95"
  threshold           = 1000
  period              = 60
  evaluation_periods  = 2
  dimensions = { EndpointName = aws_sagemaker_endpoint.resnet50_ep.name }
}

# Outputs
output "api_url" {
  value = aws_apigatewayv2_api.api.api_endpoint
}
