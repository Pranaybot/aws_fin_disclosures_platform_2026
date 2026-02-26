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
-   API Gateway
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

Note: In this code, --payload is optional

---

# 📦 DynamoDB Table

```
fin-disclosures-demo-financial_disclosures_masked
```


This is the **serving-layer DynamoDB table** that contains **masked disclosure records** only.

- Raw PII is never stored in this table.
- Masked / derived fields are safe to return via the API.

Typical returned fields include:
- `ssn_masked`
- `email_masked`
- hashed identifiers (ex: `hash_id`)

---

## 🧭 Indexes (GSIs) Used by the API

Your API is designed around these DynamoDB GSIs:

### 1) Institution + Date
**GSI name:** `gsi_institution_date`  
- **Partition key (HASH):** `institution_name`
- **Sort key (RANGE):** `transaction_date`

### 2) Region + Date
**GSI name:** `gsi_region_date`  
- **Partition key (HASH):** `reporting_region`
- **Sort key (RANGE):** `transaction_date`

---

## 🌐 Get API Base URL

After Terraform deployment, run:

```bash
terraform output search_api_base_url
```

Example:

```
https://abc123xyz.execute-api.us-east-2.amazonaws.com/prod
```

Save it:

```bash
BASE_URL=<your-api-url>
```

---

✅ GET / (Ordered “First N” Results)

Your updated search.py makes GET / return N results in a consistent order using the institution GSI, sorted by transaction_date.

Required query parameter

institution (mapped to DynamoDB institution_name)


Optional query parameter

date (mapped to DynamoDB transaction_date)

limit (how many items to return)


Return the first 10 items (sorted by date) for an institution:

```bash
curl "$BASE_URL/?institution=NorthStar%20Community%20Bank&limit=10"
```

Return up to 25 items for that institution on an exact date:

```bash
curl "$BASE_URL/?institution=NorthStar%20Community%20Bank&date=2026-02-01&limit=25"
```

Note: Limit defaults to 25 in the Lambda if not provided.


🔎 Search Endpoint Behavior (Query via GSIs)

## 🔎 Search by Institution + Date

Uses DynamoDB GSI:

```
gsi_institution_date
```

Institution only:
```bash
curl "$BASE_URL/search?institution=NorthStar%20Community%20Bank"
```

Institution + date:
```bash
curl "$BASE_URL/search?institution=NorthStar%20Community%20Bank&date=2026-02-01"
```

---

## 🌎 Search by Region + Date

Uses DynamoDB index:

```
gsi_region_date
```

Region only:
```bash
curl "$BASE_URL/search?region=9TH"
```

Region + date:
```bash
curl "$BASE_URL/search?region=9TH&date=2026-02-01"
```

---

🔤 Keyword Search (Scan using contains)

```bash
curl "$BASE_URL/search?contains=fraud"
```

---

## 🧪 Health Check

```bash
curl "$BASE_URL/"
```

Confirms API Gateway and Lambda connectivity.

---

## ✅ Example API Response

```json
{
  "count": 1,
  "items": [
    {
      "disclosure_id": "D-0001",
      "institution_name": "NorthStar Community Bank",
      "transaction_date": "2026-02-01",
      "ssn_masked": "***-**-4321",
      "email_masked": "j***@example.com",
      "hash_id": "9f21ab..."
    }
  ]
}
```

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

-   Athena queries over curated data
-   Glue Data Catalog
-   Scheduled batch ingestion

------------------------------------------------------------------------

## Author

Demo project for learning AWS serverless data platforms using Terraform.
