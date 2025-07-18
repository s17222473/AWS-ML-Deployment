# AWS-ML-Deployment
AWS Architecture for machine learning application 

# ResNet50 Inference API on AWS

## 📦 Overview
Secure, scalable image classification API using AWS SageMaker + API Gateway + Cognito + Lambda + VPC.

## ✅ Prerequisites
- AWS CLI configured
- Terraform v1.2+
- JWT‑aware HTTP client (curl, Postman)
- Existing ResNet50 `.tar.gz` in S3

## ⚙️ Deployment Steps
```bash
cd terraform
terraform init
terraform apply -var="s3_bucket_name=your-bucket-name" \
                -var="model_data_s3_uri=s3://your-bucket/resnet50.tar.gz"

