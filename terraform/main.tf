provider "aws" {
  region = var.region
}

locals {
  raw_prefix        = "raw/financial_disclosures/"
  curated_prefix    = "curated/financial_disclosures/"
  quarantine_prefix = "quarantine/financial_disclosures/"
}

# -------------------------
# S3 Bucket (force_destroy so terraform destroy removes objects too)
# -------------------------
resource "aws_s3_bucket" "data" {
  bucket        = var.bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# -------------------------
# DynamoDB (serving store)
# -------------------------
resource "aws_dynamodb_table" "disclosures" {
  name         = "${var.project}-financial_disclosures_masked"
  billing_mode = "PAY_PER_REQUEST"

  # ✅ Table primary key stays as hash_key (top-level key_schema is NOT supported here)
  hash_key = "disclosure_id"

  attribute {
    name = "disclosure_id"
    type = "S"
  }

  attribute {
    name = "institution_name"
    type = "S"
  }

  attribute {
    name = "reporting_region"
    type = "S"
  }

  attribute {
    name = "transaction_date"
    type = "S"
  }

  global_secondary_index {
    name            = "gsi_institution_date"
    projection_type = "ALL"

    # ✅ Use key_schema blocks here (inside the GSI)
    key_schema {
      attribute_name = "institution_name"
      key_type       = "HASH"
    }
    key_schema {
      attribute_name = "transaction_date"
      key_type       = "RANGE"
    }
  }

  global_secondary_index {
    name            = "gsi_region_date"
    projection_type = "ALL"

    key_schema {
      attribute_name = "reporting_region"
      key_type       = "HASH"
    }
    key_schema {
      attribute_name = "transaction_date"
      key_type       = "RANGE"
    }
  }
}

# -------------------------
# IAM role/policy for Lambda
# -------------------------
resource "aws_iam_role" "lambda_role" {
  name = "${var.project}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.project}-lambda-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Read raw + write curated/quarantine
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.data.arn,
          "${aws_s3_bucket.data.arn}/*"
        ]
      },
      # Write to DynamoDB
      {
        Effect = "Allow"
        Action = [
          "dynamodb:BatchWriteItem",
          "dynamodb:PutItem"
        ]
        Resource = [
          aws_dynamodb_table.disclosures.arn
        ]
      },
      # Read from DyanmoDB (search)
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = [
          aws_dynamodb_table.disclosures.arn,
          "${aws_dynamodb_table.disclosures.arn}/index/*"
        ]
      },
      # CloudWatch Logs
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

# -------------------------
# Package Lambda from lambda/ingest.py
# -------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file  = "${path.module}/../lambda/ingest.py"
  output_path = "${path.module}/build/ingest.zip"
}

resource "aws_lambda_function" "ingest" {
  function_name = "${var.project}-financial_disclosures_ingest"
  role          = aws_iam_role.lambda_role.arn
  handler       = "ingest.lambda_handler"
  runtime       = "python3.12"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  timeout     = 60
  memory_size = 256

  environment {
    variables = {
      BUCKET_NAME       = aws_s3_bucket.data.bucket
      CURATED_PREFIX    = local.curated_prefix
      QUARANTINE_PREFIX = local.quarantine_prefix
      DDB_TABLE_NAME    = aws_dynamodb_table.disclosures.name
      PII_HASH_SALT     = var.pii_hash_salt
    }
  }
}

# Allow S3 to invoke Lambda
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.data.arn
}

# S3 -> Lambda notification (only for raw prefix)
resource "aws_s3_bucket_notification" "notif" {
  bucket = aws_s3_bucket.data.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.ingest.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = local.raw_prefix
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

# -------------------------
# Package the search Lambda from lambda/search.py
# -------------------------
data "archive_file" "search_lambda_zip" {
  type = "zip"
  source_file = "${path.module}/../lambda/search.py"
  output_path = "${path.module}/build/search.zip"
}

# -------------------------
# Search Lambda (invoked by API Gateway)
# -------------------------
resource "aws_lambda_function" "search" {
  function_name = "${var.project}-financial_disclosures_search"
  role = aws_iam_role.lambda_role.arn
  handler = "search.lambda_handler"
  runtime = "python3.12"

  filename = data.archive_file.search_lambda_zip.output_path
  source_code_hash = data.archive_file.search_lambda_zip.output_base64sha256

  timeout = 30
  memory_size = 256

  environment {
    variables = {
      DDB_TABLE_NAME = aws_dynamodb_table.disclosures.name

      # Your code can choose index based on query params
      GSI_INSTITUTION_DATE = "gsi_institution_date"
      GSI_REGION_DATE = "gsi_region_date"
    }
  }
}

# -------------------------
# API Gateway HTTP API (REST-ish) for search
# -------------------------
resource "aws_apigatewayv2_api" "search_api" {
  name = "${var.project}-search-api"
  protocol_type = "HTTP"

  cors_configurations {
    allow_origins = ["*"]
    allow_methods = ["GET", "OPTIONS"]
    allow_headers = ["content-type", "authorization"]
  }
}

resource "aws_apigatewayv2_stage" "search_prod" {
  api_id = aws_apigatewayv2_api.search_api.id
  name = "prod"
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "search_lambda" {
  api_id                 = aws_apigatewayv2_api.search_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.search.invoke_arn
  payload_format_version = "2.0"
}

# Route: GET /search
resource "aws_apigatewayv2_route" "search_route" {
  api_id = aws_apigatewayv2_api.search_api.id
  route_key = "GET /search"
  target = "integrations/${aws_apigatewayv2_integration.search_lambda.id}"
}

# Optional: simple health route GET /
resource "aws_apigatewayv2_route" "root_route" {
  api_id    = aws_apigatewayv2_api.search_api.id
  route_key = "GET /"
  target    = "integrations/${aws_apigatewayv2_integration.search_lambda.id}"
}

# Allow API Gateway to invoke search Lambda
resource "aws_lambda_permission" "allow_apigw_invoke_search" {
  statement_id = "AllowExecutionFromAPIGatewaySearch"
  action = "lambda:InvokeFunction"
  function_name = aws_lambda_function.search.function_name
  principal = "apigateway.amazonaws.com"
  source_arn = "${aws_apigatewayv2_api.search_api.execution_arn}/*/*"
}