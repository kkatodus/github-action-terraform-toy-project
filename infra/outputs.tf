output "cdn_domain" {
  value = aws_cloudfront_distribution.spa.domain_name
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.spa.id
}

output "api_url" {
  value = aws_apigatewayv2_api.http.api_endpoint
}