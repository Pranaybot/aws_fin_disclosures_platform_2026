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

``` bash
aws iam create-user \
    --user-name terraform-admin
```

2.  Attach AdminstratorAccess policy (Demo Only):

``` bash
aws iam attach-user-policy \
    --user-name terraform-admin \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

3. Create Access Keys (IMPORTANT)

``` bash
aws iam create-access-key \
    --user-name terraform-admin
```
Once you do this, save the access key somewhere safe. Do this
step immediately because you only get to look at it once.

4. Configure locally:

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

``` bash
aws s3 ls s3://YOUR_BUCKET/raw/financial_disclosures/
aws s3 ls s3://YOUR_BUCKET/curated/financial_disclosures/
aws s3 ls s3://YOUR_BUCKET/quarantine/financial_disclosures/
```

### Lambda Function

You can look at the Lambda functions like this:

``` bash
aws lambda list-functions
```

or like this:

``` bash
aws lambda list-functions --query "Functions[].FunctionName"
```
The second option shows the output more clearly.

Then, you can look at the Lambda Function configuration:

``` bash
aws lambda get-function-configuration \
    --function-name reviews-processor
    --query "{Runtime:Runtime,Handler:Handler,Memory:MemorySize,Timeout:Timeout}"
```
Here, the --query part is optional.

You can also look at the code and configuration like this:

``` bash
aws lambda get-function \
    --function-name reviews-processor
```

From the cli, you can look at the Lambda logs which live in CloudWatch:
``` bash
aws logs describe-log-groups \
  --log-group-name-prefix /aws/lambda/
```

Finally, you can invoke or trigger the Lambda Function from the CLI
to make sure it responds to a trigger or event:

``` bash
aws lambda invoke \
  --function-name reviews-processor \
  --payload '{"test": "hello"}' \
  response.json
```
Once you invoke it, check the output in the output json file.

Note: In this code, --payload is optional.

### DynamoDB

Table:

    fin-disclosures-demo-financial_disclosures_masked

If you want to see data quickly, use this command:
``` bash
aws dynamodb scan --table-name fin-disclosures-demo-financial_disclosures_masked\
    --max-items 5
```

Yet, if you want to look at the DynamoDB table, using 'query', you have to define 
the create an attribute values json file first like below:

{
  ":id": { "S": "D-0001" }
}
This json file uses the disclosure id which is the partition key.

Now, run this command:

``` bash
aws dynamodb query \
  --table-name fin-disclosures-demo-financial_disclosures_masked \
  --key-condition-expression "disclosure_id = :id" \
  --expression-attribute-values file://values.json
```

If you have an index like the GSI below, create a json file for it like this:

{
  ":inst": { "S": "NorthStar Community Bank" },
  ":dt":   { "S": "2026-02-01" }
}

Now, run this command:

``` bash
aws dynamodb query \
  --table-name fin-disclosures-demo-financial_disclosures_masked \
  --index-name gsi_institution_date \
  --key-condition-expression "institution_name = :inst AND transaction_date = :dt" \
  --expression-attribute-values file://expr_values_institution_date.json
```

If you want to include the --key-condition-expression in the --expression-attribute-values, then you have to write the above command
as follows:

``` bash
aws dynamodb query \
  --table-name fin-disclosures-demo-financial_disclosures_masked \
  --index-name gsi_institution_date \
  --key-condition-expression "institution_name = :inst AND transaction_date = :dt" \
  --expression-attribute-values '{":inst":{"S":"NorthStar Community Bank"},":dt"{"S":"2026-02-01"}}'
```

If you intend to get only one record from the DynamoDB table, use
the GetItem command:

``` bash
aws dynamodb get-item \
  --table-name fin-disclosures-demo-financial_disclosures_masked \
  --key '{"disclosure_id":{"S":"D-0001"}}'
```

Also, you can include the --projection-expression option as such:

``` bash
aws dynamodb get-item \
  --table-name fin-disclosures-demo-financial_disclosures_masked \
  --key '{"disclosure_id":{"S":"D-0001"}}'
  --projection-expression "disclosure_id, ssn_masked, email_masked"
```

When you run each command, you should see these masked fields: - ssn_masked - email_masked - hashes
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
