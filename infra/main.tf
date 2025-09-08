terraform {
  required_version = ">=1.6.0"

  backend "s3" {
    bucket         = "kk-terraform-state-apne1"         # your bucket
    key            = "toy-aws-terraform-gha/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

}

provider "aws" {
  	region = var.aws_region
}

resource "aws_s3_bucket" "site" {
	bucket = var.site_bucket_name
	# destroys the bucket even when it has content
	force_destroy = true
}

#This resource manages S3’s Block Public Access settings, which are account- or bucket-level security controls to prevent accidental public exposure.
resource "aws_s3_bucket_public_access_block" "site" {
  	bucket = aws_s3_bucket.site.id
	#Prevents new public ACLs (Access Control Lists) from being set on the bucket or its objects.
	block_public_acls = true
	#Blocks bucket policies that grant public access.
	block_public_policy = true
	#If any objects or the bucket already have public ACLs, this setting makes S3 ignore those ACLs so they don’t take effect.
	ignore_public_acls = true
	#Restricts access to the bucket to only AWS services and authorized users, even if a public policy somehow exists.
	restrict_public_buckets = true
}
#An OAI is a special CloudFront user identity that you use to restrict access to an S3 bucket only through CloudFront, not directly via S3’s public URL.
resource "aws_cloudfront_origin_access_identity" "oai" {
	comment = "${var.project} oai"
}

#This policy lets your CloudFront OAI read any object in the S3 bucket, so users can fetch content only via CloudFront while the bucket itself stays private.
#Difference between resource and data

# resource: creates, updates, or deletes infrastructure.

# data: only reads or generates information; it never creates or changes infrastructure.
data "aws_iam_policy_document" "site_oai_policy" {
  statement {
	sid = "AllowCloudFrontRead"
	effect = "Allow"
	#Sets the Principal that’s allowed: your CloudFront Origin Access Identity (OAI).
	# type = "AWS" with the OAI’s IAM ARN is the recommended way to reference the OAI in an S3 bucket policy. Terraform exposes this as ...oai.iam_arn. 
	# Terraform Registry
	# AWS Documentation

	# (FYI: Another valid pattern is type = "CanonicalUser" with ...oai.s3_canonical_user_id, but AWS may translate that to an ARN under the hood and cause noisy diffs—using iam_arn avoids that.) 
	# Terraform Registry
	principals {
		type = "AWS"
		identifiers = [aws_cloudfront_origin_access_identity.oai.iam_arn]
	}
	#Grants CloudFront permission to read objects from the bucket (the only action CloudFront typically needs to fetch content).
	actions = ["s3:GetObject"]
	#Grants cloudfront permission to read objects from the bucket
	resources = ["${aws_s3_bucket.site.arn}/*"]
	
  }
}

resource "aws_s3_bucket_policy" "site" {
	bucket = aws_s3_bucket.site.id
	policy = data.aws_iam_policy_document.site_oai_policy.json
}
#Declares an AWS CloudFront distribution resource (your CDN).
# "spa" is the Terraform name so you can reference it elsewhere.
# This distribution will serve your single-page app (SPA) from S3.
resource "aws_cloudfront_distribution" "spa" {
	#Ensures the distribution is active after creation (can be false if you want it disabled initially).
	enabled = true
	#if a user requests / cloudfront serves index.html from origin
	default_root_object = "index.html"
	#limits cloudfronts edge location to the cheapest tier north america and europe only
	price_class = "PriceClass_100"

	# defines where cloudfront pulls files from
	origin {
		# the regional endpoint of the s3 bucket
		domain_name = aws_s3_bucket.site.bucket_regional_domain_name
		# origin id: internal id you'll reference in behaviours
		origin_id  = "s3-spa"
		# tells cloudfront that its an s3 origin
		s3_origin_config {
			# uses my OAI so only cloudfront can fetch objects from the bucket
			origin_access_identity = aws_cloudfront_origin_access_identity.oai.cloudfront_access_identity_path
		}
	}
	default_cache_behavior {
	  #which origin this behaviour applies to 
	  target_origin_id = "s3-spa"
	  # if someone uses HTTP, redirect them to HTTPS
	  viewer_protocol_policy = "redirect-to-https"
	  # what methods cloudfront forward,(GET, HEAD only = read only)
	  allowed_methods = ["GET", "HEAD"]
	  # what gets cached at edge locations
	  cached_methods = ["GET", "HEAD"]
	  # compress for faster downloads
	  compress = true
	  # AWS's managed cachingoptimized policy UUID, which controls cache keys(headers, cookies, query params)
	  cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
	}
	# for single page applications(SPAs) like react, unknown routes should still serve index.html
	# there rules re-write 403 and 404 errors from S3 to index.html with HTTP 200
	# without this direct navigation to SPA routes would break
	custom_error_response {
	  error_code  = 404
	  response_code = 200
	  response_page_path = "/index.html"
	}
	custom_error_response {
	  error_code = 403
	  response_code = 200
	  response_page_path = "/index.html"
	}
	# global availability
	restrictions {
		geo_restriction {
		  restriction_type = "none"
		}
	  
	}
	# uses cloudfront's default certificate
	viewer_certificate {
		cloudfront_default_certificate = true
		minimum_protocol_version = "TLSv1.2_2021"
	  
	}
	depends_on = [aws_s3_bucket_policy.site]
}

# ---------- Backend packaging (zip) ----------

data "archive_file" "backend_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../backend"
  output_path = "${path.module}/build/backend.zip"

}

# ---------- IAM for Lambda ----------
#creates an IAM role for Lambda functions, named after your project, with a trust policy that allows the Lambda service (lambda.amazonaws.com) to assume it.
resource "aws_iam_role" "lambda_role" {
	#sets the role's name in AWS
	name = "${var.project}-lambda-role"
	assume_role_policy = jsonencode({
		Version = "2012-10-17"
		Statement = [{
			Effect = "Allow"
			Principal = {
				Service = "lambda.amazonaws.com"
			}
			Action = "sts:AssumeRole"
		}]
	})
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
	role = aws_iam_role.lambda_role.name
	# specifies which managed policy to attach
	# arn points to AWS's predefined policy
	policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Terraform uploads backend.zip to AWS Lambda.

# AWS Lambda stores that ZIP and runs your function from it.

# At runtime, Lambda executes app.lambda_handler, and all the vendored dependencies are already there in the ZIP.
resource "aws_lambda_function" "api" {
	function_name = "${var.project}-api"
	# specifies IAM role that lambda will assume when it runs
	role = aws_iam_role.lambda_role.arn
	# defines entry point to lambda
	# app  -> python file called app.py
	# lambda_handler -> function inside that file that lambda executes
	handler = "app.lambda_handler"
	runtime = "python3.13"
	# points to deployment package that terraform will upload to AWS lambda
	filename = data.archive_file.backend_zip.output_path
	# provides checksum of the ZIP file
	# terraform uses this to detect change to code 
	source_code_hash = data.archive_file.backend_zip.output_base64sha256
	timeout = 10
}

resource "aws_apigatewayv2_api" "http" {
	name          = "${var.project}-http-api"
	protocol_type = "HTTP"
	cors_configuration {
	  allow_origins = ["*"]
	  allow_methods = ["GET", "POST", "OPTIONS"]
	  allow_headers = ["*"]
	}
}

# connects API gateway to lambda function
resource "aws_apigatewayv2_integration" "lambda" {
	# connects integration to gateway
	api_id = aws_apigatewayv2_api.http.id
	# means API gateway forwards the entire HTTP request, lambda formats the full response
	integration_type = "AWS_PROXY"
	#HTTP method API gateway uses when invoking the backend,for lambda proxy integration this is always POST
	integration_method = "POST"
	#target backend endpoint. invoke arn of the lambda function
	integration_uri = aws_lambda_function.api.invoke_arn
	# specifies event format that API gateway sends to lambda
	payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "hello" {
	api_id = aws_apigatewayv2_api.http.id
	route_key = "GET /hello"
	# specifies where this route should send the traffic. 
	# target must be an integration
	# request -> lambda integration -> lambda function
	target = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "prod" {
	api_id = aws_apigatewayv2_api.http.id
	# in api gateway v2 default is a special stage that is always deployed at the root of your API endpoint 
	name = "$default"
	# with HTTP APIs, you must deploy changes to routes/integrations before they take effect.
	# setting auto_deploy = true means any new or updated routes/integrations are automatically deployed without needing to run a separate aws_apigatewayv2_deployment
	auto_deploy = true
}

# modifies the resource based policy on lambda function
resource "aws_lambda_permission" "allow_invoke" {
	# unique identifier for this permission statement inside lambda's policy
	statement_id = "AllowAPIGatewayInvoke"
	# specific action being granted, allows the principal API gateway to invoke the lambda function
	action = "lambda:InvokeFunction"
	# lambda function this permission applies to 
	function_name = aws_lambda_function.api.function_name
	# AWS service principal being granted permission\
	#Allow the API Gateway service to invoke this Lambda function.
	principal = "apigateway.amazonaws.com"
	# restricts the permission to invocations that come from your specific API gateway
	#The /*/* suffix means:
		#* → all stages ($default, prod, etc.)

		#* → all routes (/hello, /api/*, etc.)
	source_arn = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
	
}