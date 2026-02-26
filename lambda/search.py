import os
import json
import boto3
from boto3.dynamodb.conditions import Key, Attr

ddb = boto3.resource("dynamodb")
TABLE_NAME = os.environ["TABLE_NAME"]
table = ddb.Table(TABLE_NAME)

def _resp(status, body):
  return {
    "statusCode": status,
    "headers": {"content-type": "application/json"},
    "body": json.dumps(body, default=str),
  }

def lambda_handler(event, context):
  qs = (event.get("queryStringParameters") or {})
  institution = qs.get("institution")
  tx_date = qs.get("date")
  contains = qs.get("contains")

  # If you have a GSI like (institution_name, transaction_date),
  # swap this to Query against your GSI (recommended).
  if institution and tx_date:
    # Example assumes primary key supports Query; otherwise use IndexName="your_gsi"
    # resp = table.query(
    #   IndexName=os.environ.get("GSI_NAME"),
    #   KeyConditionExpression=Key("institution_name").eq(institution) & Key("transaction_date").eq(tx_date),
    # )
    resp = table.scan(
      FilterExpression=Attr("institution_name").eq(institution) & Attr("transaction_date").eq(tx_date)
    )
    return _resp(200, {"count": resp.get("Count", 0), "items": resp.get("Items", [])})

  if contains:
    resp = table.scan(
      FilterExpression=Attr("institution_name").contains(contains) | Attr("description").contains(contains)
    )
    return _resp(200, {"count": resp.get("Count", 0), "items": resp.get("Items", [])})

  return _resp(400, {"error": "Provide query params like ?institution=...&date=... OR ?contains=..."})