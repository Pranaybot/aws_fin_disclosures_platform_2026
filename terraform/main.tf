provider "aws" {
    region = var.region
}

locals {
    raw_prefix = "raw/financial_disclosures/"
    curated_prefix = "curated/financial_disclosures/"
    quarantine_prefix = "quarantine/financial_disclosures/"
}

# -------------------------
# S3 Bucket (force_destroy so terraform destroy removes objects too)
# -------------------------
resource "aws_s3_bucket" "data" {
    bucket = var.bucket_name
    force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "data" {
    bucket = aws_s3_bucket.data.id
    block_public_acls = true
    block_public_policy = true
    ignore_public_acls = true
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
resource "aws_dynamodbtable" "disclosures" {
    name = "${var.project}-financial_disclosures_masked"
    billing_mode = "PAY_PER_REQUEST"
    hash_key = "disclosure_id"

    attribute {
        name = "disclosure_id
        tyepe = "S
    }

    # For search patterns (even without API today, it's useful for later)
    attribute {
        name="institution_name"
        type="S"
    }

    attribute {
        name = "reporting_region"
        type = "S"
    }

    attribute {
        name = "transaction_date
        type = "S" # store YYYY-MM-DD string for GSI sort
    }

    global_secondary_index {
        name = "gsi_institution_date"
        hash_key = "institution_name"
        range_key = "transaction_date"
        projectiom_type = "ALL"
    }

    global_secondary_index {
        name = "gsi_region_date"
        hash_key = "reporting_region"
        range_key = "transaction_date"
        projection_type = "ALL"
    }
}

# -------------------------
# IAM role/policy for Lambda
# -------------------------
resource "aws_iam_role" "lambda_role" {
    name = "${var.project}-lambda-role"
    assume_role_policy = jsonecode({
        Version = "2012-10-17",
        Statement = [{
            Effect = "Allow",
            Principal = { Service = "lambda.amazonaws.com" },
            Action = "sts.AssumeRole"
        }]
    })
}

resource "aws_iam_role_policy" "lambda_policy" {
    name = "${var.project}-lambda-policy"
    role = aws_iam_role.lambda_role.id

    policy = jsonecode({
        Version = "2012-10-17",
        Statement = [
          # Read raw + write to curated/quarantine
          {
            Effect = "Allow",
            Action = [
                "s3:GetObject",
                "s3:PutObject",
                "s3:ListBucket"
            ],
            Resource = [
                aws_s3_bucket.data.arn,
                "${aws_s3_bucket.data.arn}/*"
            ]
          },
          # Write to DynamoDB
          {
            Effect = "Allow",
            Action = [
                "dynamodb:BatchWriteItem",
                dynamoDB:PutItem"
            ],
            Resource = [aws_dynamodbtable.disclosures.arn]
          },
          # CloudWatch Logs
          {
            Effect = "Allow",
            Action = [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            Resource = "*
          }
        ]
    })
}

# -------------------------
# Package Lambda from lambda/ingest.py
# -------------------------
data "archive_file" "lambda_zip" {
    type ="zip"
    source_dir = "${path.module}/../lambda"
    output_path = "${path.module}/build/ingest.zip"
}

resource "aws_lambda_function" "ingest" {
    function_name = "${var.project}-financial-disclosures_ingest"
    role = aws_iam_role.lambda_role.arn
    handler = "ingest.lambda_handler"
    runtime = "python3.12"

    filename = data.archive_file.lambda_zip.output_path
    source_code_hash = data.archive_file.lambda_zip.output_base64sha256

    timeout = 60
    memory_size  = 256

    environment {
        variables = {
        BUCKET_NAME        = aws_s3_bucket.data.bucket
        CURATED_PREFIX     = local.curated_prefix
        QUARANTINE_PREFIX  = local.quarantine_prefix
        DDB_TABLE_NAME     = aws_dynamodb_table.disclosures.name
        PII_HASH_SALT      = var.pii_hash_salt
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