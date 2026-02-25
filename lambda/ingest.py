import os
import csv
import io
import json
import re
import uuid
import hashlib
from datetime import datetime, date
from typing import Dict, Any, List, Tuple

import boto3

s3 = boto3.client("s3")
ddb = boto3.client("dynamodb")

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
SSN_RE = re.compile(r"^\d{3}-\d{2}-\d{4}$")

ALLOWED_TX_TYPES = {"WIRE", "ACH", "CARD", "CASH", "CHECK"}
ALLOWED_REGIONS = {"NE", "MW", "S", "W"}

BUCKET_NAME = os.environ["BUCKET_NAME"]
CURATED_PREFIX = os.environ["CURATED_PREFIX"]
QUARANTINE_PREFIX = os.environ["QUARANTINE_PREFIX"]
DDB_TABLE_NAME = os.environ["DDB_TABLE_NAME"]
PII_HASH_SALT = os.environ["PII_HASH_SALT"]


def sha256_hex(value: str) -> str:
    h = hashlib.sha256()
    h.update((value + PII_HASH_SALT).encode("utf-8"))
    return h.hexdigest()


def mask_ssn(ssn: str) -> str:
    # ***-**-1234
    return "***-**-" + ssn[-4:]


def mask_email(email: str) -> str:
    # j***@domain.com
    try:
        user, domain = email.split("@", 1)
        if not user:
            return "***@" + domain
        return user[0] + "***@" + domain
    except Exception:
        return "***"


def parse_date(d: str) -> str:
    # accept YYYY-MM-DD
    dt = datetime.strptime(d, "%Y-%m-%d").date()
    return dt.isoformat()


def parse_amount(a: str) -> str:
    # store as string in DynamoDB N type safely
    val = float(a)
    if val < 0:
        raise ValueError("transaction_amount must be >= 0")
    # keep 2 decimals
    return f"{val:.2f}"


def validate_row(r: Dict[str, str]) -> Tuple[bool, str]:
    required = [
        "disclosure_id",
        "institution_name",
        "transaction_type",
        "transaction_amount",
        "transaction_date",
        "reporting_region",
        "ssn",
        "email",
        "created_at",
    ]
    for k in required:
        if k not in r or r[k] is None or str(r[k]).strip() == "":
            return False, f"missing_required_field:{k}"

    # UUID
    try:
        uuid.UUID(r["disclosure_id"])
    except Exception:
        return False, "invalid_disclosure_id_uuid"

    # tx type / region
    if r["transaction_type"] not in ALLOWED_TX_TYPES:
        return False, "invalid_transaction_type"
    if r["reporting_region"] not in ALLOWED_REGIONS:
        return False, "invalid_reporting_region"

    # amount/date
    try:
        _ = parse_amount(r["transaction_amount"])
    except Exception:
        return False, "invalid_transaction_amount"

    try:
        _ = parse_date(r["transaction_date"])
    except Exception:
        return False, "invalid_transaction_date"

    # ssn/email formats
    if not SSN_RE.match(r["ssn"]):
        return False, "invalid_ssn_format"
    if not EMAIL_RE.match(r["email"]):
        return False, "invalid_email_format"

    # created_at parse (ISO-ish)
    try:
        # tolerate "2026-02-25T10:00:00" etc.
        datetime.fromisoformat(r["created_at"].replace("Z", ""))
    except Exception:
        return False, "invalid_created_at"

    return True, ""


def to_ddb_item(masked: Dict[str, Any]) -> Dict[str, Any]:
    # DynamoDB expects typed attributes
    return {
        "disclosure_id": {"S": masked["disclosure_id"]},
        "institution_name": {"S": masked["institution_name"]},
        "transaction_type": {"S": masked["transaction_type"]},
        "transaction_amount": {"N": masked["transaction_amount"]},  # string like "123.45"
        "transaction_date": {"S": masked["transaction_date"]},      # "YYYY-MM-DD"
        "reporting_region": {"S": masked["reporting_region"]},
        "ssn_masked": {"S": masked["ssn_masked"]},
        "email_masked": {"S": masked["email_masked"]},
        "ssn_hash": {"S": masked["ssn_hash"]},
        "email_hash": {"S": masked["email_hash"]},
        "created_at": {"S": masked["created_at"]},
    }


def batch_write(items: List[Dict[str, Any]]) -> None:
    # BatchWriteItem max 25 items per request
    for i in range(0, len(items), 25):
        chunk = items[i:i+25]
        req = {DDB_TABLE_NAME: [{"PutRequest": {"Item": it}} for it in chunk]}
        resp = ddb.batch_write_item(RequestItems=req)
        # Retry unprocessed a few times (simple)
        retries = 0
        while resp.get("UnprocessedItems") and retries < 5:
            retries += 1
            resp = ddb.batch_write_item(RequestItems=resp["UnprocessedItems"])


def lambda_handler(event, context):
    # S3 put event
    records = event.get("Records", [])
    for rec in records:
        bucket = rec["s3"]["bucket"]["name"]
        key = rec["s3"]["object"]["key"]

        obj = s3.get_object(Bucket=bucket, Key=key)
        body = obj["Body"].read()

        # Assume CSV with header row
        text = body.decode("utf-8")
        reader = csv.DictReader(io.StringIO(text))

        valid_masked = []
        invalid_rows = []

        for row in reader:
            ok, reason = validate_row(row)
            if not ok:
                invalid_rows.append({"row": row, "error": reason})
                continue

            masked = {
                "disclosure_id": row["disclosure_id"],
                "institution_name": row["institution_name"].strip(),
                "transaction_type": row["transaction_type"].strip(),
                "transaction_amount": parse_amount(row["transaction_amount"]),
                "transaction_date": parse_date(row["transaction_date"]),
                "reporting_region": row["reporting_region"].strip(),
                "ssn_masked": mask_ssn(row["ssn"].strip()),
                "email_masked": mask_email(row["email"].strip()),
                "ssn_hash": sha256_hex(row["ssn"].strip()),
                "email_hash": sha256_hex(row["email"].strip()),
                "created_at": row["created_at"].strip(),
            }
            valid_masked.append(masked)

        # Write valid to DynamoDB
        if valid_masked:
            ddb_items = [to_ddb_item(x) for x in valid_masked]
            batch_write(ddb_items)

        # Write curated masked JSONL to S3
        if valid_masked:
            out_key = f"{CURATED_PREFIX}masked_{key.split('/')[-1].replace('.csv','')}.jsonl"
            jsonl = "\n".join(json.dumps(x, ensure_ascii=False) for x in valid_masked) + "\n"
            s3.put_object(Bucket=BUCKET_NAME, Key=out_key, Body=jsonl.encode("utf-8"))

        # Write invalid rows to quarantine
        if invalid_rows:
            q_key = f"{QUARANTINE_PREFIX}quarantine_{key.split('/')[-1].replace('.csv','')}.jsonl"
            q_jsonl = "\n".join(json.dumps(x, ensure_ascii=False) for x in invalid_rows) + "\n"
            s3.put_object(Bucket=BUCKET_NAME, Key=q_key, Body=q_jsonl.encode("utf-8"))

    return {"ok": True, "processed_files": len(records)}