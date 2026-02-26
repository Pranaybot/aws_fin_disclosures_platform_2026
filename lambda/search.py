import os
import json
import boto3
from boto3.dynamodb.conditions import Key, Attr

ddb = boto3.resource("dynamodb")
TABLE_NAME = os.environ["DDB_TABLE_NAME"]
GSI_INSTITUTION_DATE = os.environ["GSI_INSTITUTION_DATE"]
GSI_REGION_DATE = os.environ["GSI_REGION_DATE"]

table = ddb.Table(TABLE_NAME)

def _resp(status, body):
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body, default=str),
    }


def _int(value, default):
    try:
        return int(value)
    except Exception:
        return default


def lambda_handler(event, context):

    raw_path = event.get("rawPath") or ""
    method = (event.get("requestContext", {})
                    .get("http", {})
                    .get("method", ""))

    qs = event.get("queryStringParameters") or {}

    institution = qs.get("institution")
    region = qs.get("region")
    tx_date = qs.get("date")
    contains = qs.get("contains")
    limit = _int(qs.get("limit"), 25)

    # ------------------------------------------------------------
    # GET /
    # Consistent ordered results using institution GSI
    # ------------------------------------------------------------
    if method == "GET" and raw_path == "/":

        if not institution:
            return _resp(400, {
                "error": "GET / requires ?institution=... for ordered results"
            })

        key_expr = Key("institution_name").eq(institution)

        if tx_date:
            key_expr = key_expr & Key("transaction_date").eq(tx_date)

        resp = table.query(
            IndexName=GSI_INSTITUTION_DATE,
            KeyConditionExpression=key_expr,
            Limit=limit,
            ScanIndexForward=True
        )

        return _resp(200, {
            "count": resp.get("Count", 0),
            "items": resp.get("Items", [])
        })

    # ------------------------------------------------------------
    # Query by institution (+ optional date)
    # ------------------------------------------------------------
    if institution:

        key_expr = Key("institution_name").eq(institution)

        if tx_date:
            key_expr = key_expr & Key("transaction_date").eq(tx_date)

        resp = table.query(
            IndexName=GSI_INSTITUTION_DATE,
            KeyConditionExpression=key_expr,
            ScanIndexForward=True
        )

        return _resp(200, {
            "count": resp.get("Count", 0),
            "items": resp.get("Items", [])
        })

    # ------------------------------------------------------------
    # Query by region (+ optional date)
    # ------------------------------------------------------------
    if region:

        key_expr = Key("reporting_region").eq(region)

        if tx_date:
            key_expr = key_expr & Key("transaction_date").eq(tx_date)

        resp = table.query(
            IndexName=GSI_REGION_DATE,
            KeyConditionExpression=key_expr,
            ScanIndexForward=True
        )

        return _resp(200, {
            "count": resp.get("Count", 0),
            "items": resp.get("Items", [])
        })

    # ------------------------------------------------------------
    # Keyword search fallback (scan)
    # ------------------------------------------------------------
    if contains:

        resp = table.scan(
            FilterExpression=
                Attr("institution_name").contains(contains) |
                Attr("description").contains(contains)
        )

        return _resp(200, {
            "count": resp.get("Count", 0),
            "items": resp.get("Items", [])
        })

    return _resp(400, {
        "error": "Provide ?institution=..., ?region=..., or ?contains=..."
    })