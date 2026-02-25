output "bucket_name" {
  value = aws_s3_bucket.data.bucket
}

output "dynamodb_table" {
  value = aws_dynamodb_table.disclosures.name
}

output "lambda_name" {
  value = aws_lambda_function.ingest.function_name
}

output "raw_prefix" {
  value = "raw/financial_disclosures/"
}

output "curated_prefix" {
  value = "curated/financial_disclosures/"
}

output "quarantine_prefix" {
  value = "quarantine/financial_disclosures/"
}