# AWS Financial Disclosures Data Platform (Terraform + Serverless)

This project builds a **small AWS-based data platform** that:

-   Ingests mock financial disclosure records
-   Applies **data validation and masking**
-   Stores masked data in **DynamoDB**
-   Writes curated datasets to **Amazon S3**
-   Uses **Terraform** for fully reproducible infrastructure
-   Can be safely destroyed so **no AWS costs remain**

------------------------------------------------------------------------

## Architecture Overview

    Local CSV (1000+ rows)
            ↓
    Amazon S3 (raw zone)
            ↓ (event trigger)
    AWS Lambda (validation + masking)
            ↓
     ┌─────────────────────────────┐
     │  DynamoDB (masked serving)  │
     │  S3 curated zone            │
     │  S3 quarantine (bad rows)   │
     └─────────────────────────────┘

All services are **serverless** --- nothing runs continuously.

------------------------------------------------------------------------

## Project Structure

    aws_fin_disclosures_platform/
    │
    ├── terraform/
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── outputs.tf
    │   ├── versions.tf
    │   └── terraform.tfvars
    │
    ├── lambda/
    │   └── ingest.py
    │
    └── scripts/
        └── generate_mock_csv.py

------------------------------------------------------------------------

## Prerequisites

Install the following locally:

### 1. Python (3.10+ recommended)

https://www.python.org/downloads/

Verify:

``` bash
python3 --version
```

### 2. Terraform

https://developer.hashicorp.com/terraform/downloads

Verify:

``` bash
terraform -version
```

### 3. AWS CLI

https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html

Verify:

``` bash
aws --version
```

------------------------------------------------------------------------

## Install Python Libraries

From project root:

``` bash
pip install faker boto3
```

These are used only for mock data generation.

------------------------------------------------------------------------

## Configure AWS Credentials (IMPORTANT)

Do **NOT** use the root user for automation.

1.  Create IAM user:

```{=html}
<!-- -->
```
    IAM → Users → Create user → terraform-admin

2.  Attach policy:

```{=html}
<!-- -->
```
    AdministratorAccess (demo only)

3.  Configure locally:

``` bash
aws configure
```

Enter:

    Region: us-east-2
    Output: json

Test:

``` bash
aws sts get-caller-identity
```

------------------------------------------------------------------------

## Configure Terraform Variables

Create:

    terraform/terraform.tfvars

Example:

``` hcl
region        = "us-east-2"
project       = "fin-disclosures-demo"

bucket_name   = "fin-disclosures-demo-UNIQUE-NAME-12345"

pii_hash_salt = "demo-random-salt"
```

⚠️ Bucket names must be globally unique.

------------------------------------------------------------------------

## Deploy Infrastructure

Navigate to Terraform directory:

``` bash
cd terraform
```

Initialize:

``` bash
terraform init
```

Preview:

``` bash
terraform plan
```

Deploy:

``` bash
terraform apply
```

Type:

    yes

Terraform will create:

-   S3 bucket
-   DynamoDB table
-   Lambda function
-   IAM role
-   S3 event trigger

------------------------------------------------------------------------

## Generate Mock Data (1000 Records)

From project root:

``` bash
cd scripts
python3 generate_mock_csv.py
```

This creates:

    financial_disclosures_raw.csv

------------------------------------------------------------------------

## Upload Data (Triggers Pipeline)

``` bash
aws s3 cp financial_disclosures_raw.csv s3://YOUR_BUCKET/raw/financial_disclosures/financial_disclosures_raw.csv
```

Lambda automatically:

-   validates rows
-   masks SSN/email
-   writes curated dataset
-   stores masked records in DynamoDB

------------------------------------------------------------------------

## Verify Outputs

### S3

Check:

    curated/financial_disclosures/
    quarantine/financial_disclosures/

### DynamoDB

Table:

    fin-disclosures-demo-financial_disclosures_masked

You should see masked fields: - ssn_masked - email_masked - hashes
instead of raw PII

------------------------------------------------------------------------

## Tear Down (Stop All Costs)

When finished:

``` bash
cd terraform
terraform destroy
```

Type:

    yes

This deletes:

-   Lambda
-   DynamoDB
-   IAM roles
-   S3 bucket (including data)

------------------------------------------------------------------------

## Extra Cleanup (Recommended)

In AWS Console:

1.  CloudWatch → Log groups
2.  Delete:

```{=html}
<!-- -->
```
    /aws/lambda/fin-disclosures-demo-financial_disclosures_ingest

This prevents leftover log storage charges.

------------------------------------------------------------------------

## Cost Safety Notes

This project uses only:

-   AWS Lambda
-   S3
-   DynamoDB (on-demand)

All are free-tier friendly.

After `terraform destroy`, **no running resources remain**.

------------------------------------------------------------------------

## Future Enhancements

You can later add:

-   API Gateway REST APIs
-   Athena queries over curated data
-   Glue Data Catalog
-   Scheduled batch ingestion

------------------------------------------------------------------------

## Author

Demo project for learning AWS serverless data platforms using Terraform.
