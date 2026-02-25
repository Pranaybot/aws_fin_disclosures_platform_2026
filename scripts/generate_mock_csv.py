import csv, uuid, random
from datetime import datetime, timedelta, date
from faker import Faker

fake = Faker()

TX_TYPES = ["WIRE", "ACH", "CARD", "CASH", "CHECK"]
REGIONS = ["NE", "MW", "S", "W"]

def rand_date(start_days_ago=365):
    d = date.today() - timedelta(days=random.randint(0, start_days_ago))
    return d.isoformat()

def gen_row():
    return {
        "disclosure_id": str(uuid.uuid4()),
        "institution_name": fake.company(),
        "transaction_type": random.choice(TX_TYPES),
        "transaction_amount": round(random.uniform(10, 250000), 2),
        "transaction_date": rand_date(),
        "reporting_region": random.choice(REGIONS),
        "ssn": fake.ssn(),          # synthetic
        "email": fake.email(),      # synthetic
        "created_at": datetime.utcnow().isoformat(timespec="seconds")
    }

rows = [gen_row() for _ in range(1000)]

with open("financial_disclosures_raw.csv", "w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, fieldnames=rows[0].keys())
    w.writeheader()
    w.writerows(rows)

print("Wrote financial_disclosures_raw.csv with 1000 rows")