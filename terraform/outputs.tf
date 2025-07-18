output "api_endpoint" {
  description = "API Gateway invoke URL"
  value       = aws_apigatewayv2_api.api.api_endpoint
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.userpool.id
}
output "cognito_app_client_id" {
  value = aws_cognito_user_pool_client.app_client.id
}
output "sagemaker_endpoint_name" {
  value = aws_sagemaker_endpoint.resnet50_ep.name
}
