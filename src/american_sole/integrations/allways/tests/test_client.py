"""
Test script for All-Ways USA Shipments API.
Docs: https://allwaysusa.com/api-docs
"""

import os
import pprint
import requests
from dotenv import load_dotenv

load_dotenv()

BASE_URL = "https://allwaysusa.com/api/v1"
API_KEY = os.getenv("api_allways")

if not API_KEY:
    raise RuntimeError("api_allways not found in .env")

HEADERS = {
    "Authorization": f"Bearer {API_KEY}",
    "Accept": "application/json",
    "Content-Type": "application/json",
}


def test_shipments_job():
    """POST /shipments/job — request shipments asynchronously."""
    payload = {
        "statuses": ["booking", "sailed", "arriving", "vessel_arrived", "pending_departure", "archived"],
        "dateRange": {
            "dateType": "eta",
            "from": "2026-01-01",
            "to": "2026-07-31",
        },
        "include": ["documents"],
    }
    resp = requests.post(f"{BASE_URL}/shipments/job", headers=HEADERS, json=payload)
    print(f"[POST /shipments/job]  status={resp.status_code}")
    data = resp.json()
    print(f"  response: {data}")
    return data.get("job_id")


def test_get_job_results(job_id):
    """GET /shipments/<job_id> — fetch job results (paginated)."""
    resp = requests.get(
        f"{BASE_URL}/shipments/{job_id}",
        headers=HEADERS,
        params={"page": 1, "per_page": 5},
    )
    print(f"\n[GET /shipments/{job_id}]  status={resp.status_code}")
    data = resp.json()
    if isinstance(data, list):
        print(f"  returned {len(data)} shipment(s)")
        for s in data[:2]:
            print(f"    - id={s.get('id')}  mbl={s.get('mbl')}  eta={s.get('eta')}")
    else:
        print(f"  response: {data}")


def test_latest_shipments():
    """GET /shipments/latest — fetch latest job results."""
    resp = requests.get(
        f"{BASE_URL}/shipments/latest",
        headers=HEADERS,
        params={"page": 1, "per_page": 5},
    )
    print(f"\n[GET /shipments/latest]  status={resp.status_code}")
    data = resp.json()
    if isinstance(data, list):
        print(f"  returned {len(data)} shipment(s)")
        for s in data[:3]:
            print(f"    - id={s.get('id')}  mbl={s.get('mbl')}  eta={s.get('eta')}")
    else:
        pprint.pprint(f"  response: {data}")


def test_lookup_by_container(container_number: str):
    """GET /container/<number> — look up by container number."""
    resp = requests.get(
        f"{BASE_URL}/container/{container_number}",
        headers=HEADERS,
        params={"include[]": "documents"},
    )
    print(f"\n[GET /container/{container_number}]  status={resp.status_code}")
    pprint.pprint(f"  response: {resp.json()}")


def test_lookup_by_po(po_number: str):
    """GET /purchase-order/<po> — look up by PO number."""
    resp = requests.get(
        f"{BASE_URL}/purchase-order/{po_number}",
        headers=HEADERS,
        params={"include[]": "documents"},
    )
    print(f"\n[GET /purchase-order/{po_number}]  status={resp.status_code}")
    pprint.pprint(f"  response: {resp.json()}")


if __name__ == "__main__":
    print("=" * 60)
    print("All-Ways USA API — Test Script")
    print("=" * 60)

    # 1. Submit a shipments job
    job_id = test_shipments_job()

    # 2. Fetch job results (if we got a job_id)
    if job_id:
        test_get_job_results(job_id)

    # # 3. Fetch latest shipments
    # test_latest_shipments()

    # 4. Look up by known shipment ID and PO
    test_lookup_by_po("PO1126")

    print("\n" + "=" * 60)
    print("Done.")
