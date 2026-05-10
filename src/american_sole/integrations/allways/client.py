"""Async OOP client for the All-Ways USA Shipments API.

Docs: https://allwaysusa.com/api-docs
"""

from __future__ import annotations

import asyncio
import os
from datetime import date
from typing import Any, Literal, Self

import httpx
from dotenv import load_dotenv
from pydantic import BaseModel, Field

ShipmentStatus = Literal[
    "booking",
    "sailed",
    "arriving",
    "vessel_arrived",
    "pending_departure",
]

DEFAULT_STATUSES: tuple[ShipmentStatus, ...] = (
    "booking",
    "sailed",
    "arriving",
    "vessel_arrived",
    "pending_departure",
)


class Shipment(BaseModel):
    """Partial shipment model — unknown fields from the API are preserved."""

    model_config = {"extra": "allow"}

    id: int | str | None = None
    mbl: str | None = None
    status: str | None = None
    eta: date | None = None
    etd: date | None = None
    po_numbers: list[str] = Field(default_factory=list)
    container_number: str | None = None


class AllwaysClient:
    """Async client for the All-Ways USA API.

    Usage:
        async with AllwaysClient() as client:
            shipments = await client.get_by_status(["sailed", "arriving"])
    """

    BASE_URL = "https://allwaysusa.com/api/v1"

    def __init__(
        self,
        api_key: str | None = None,
        base_url: str | None = None,
        timeout: float = 30.0,
    ) -> None:
        load_dotenv()
        self._api_key = api_key or os.getenv("api_allways")
        if not self._api_key:
            raise RuntimeError(
                "api_allways not set — pass api_key=... or set it in .env"
            )
        self._base_url = base_url or self.BASE_URL
        self._client = httpx.AsyncClient(
            base_url=self._base_url,
            headers={
                "Authorization": f"Bearer {self._api_key}",
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
            timeout=timeout,
        )

    async def __aenter__(self) -> Self:
        return self

    async def __aexit__(self, *exc_info: Any) -> None:
        await self.close()

    async def close(self) -> None:
        await self._client.aclose()

    # ---------- low-level job API ----------

    async def _submit_job(
        self,
        statuses: list[str],
        date_from: date,
        date_to: date,
        date_type: str = "eta",
        include: list[str] | None = None,
    ) -> str:
        payload = {
            "statuses": statuses,
            "dateRange": {
                "dateType": date_type,
                "from": date_from.isoformat(),
                "to": date_to.isoformat(),
            },
            "include": include or ["documents"],
        }
        r = await self._client.post("/shipments/job", json=payload)
        r.raise_for_status()
        body = r.json()
        job_id = body.get("job_id")
        if not job_id:
            raise RuntimeError(f"submit_job: no job_id in response: {body}")
        return job_id

    async def _fetch_job_page(
        self,
        job_id: str,
        page: int = 1,
        per_page: int = 100,
    ) -> list[dict] | dict:
        r = await self._client.get(
            f"/shipments/{job_id}",
            params={"page": page, "per_page": per_page},
        )
        r.raise_for_status()
        return r.json()

    async def _fetch_job_all(
        self,
        job_id: str,
        per_page: int = 100,
        poll_interval: float = 2.0,
        timeout: float = 120.0,
    ) -> list[Shipment]:
        elapsed = 0.0
        data: list[dict] | dict = {}
        while elapsed < timeout:
            data = await self._fetch_job_page(job_id, page=1, per_page=per_page)
            if isinstance(data, list):
                break
            await asyncio.sleep(poll_interval)
            elapsed += poll_interval
        else:
            raise TimeoutError(f"job {job_id} not ready after {timeout}s")

        results: list[dict] = list(data)
        page = 2
        while True:
            more = await self._fetch_job_page(job_id, page=page, per_page=per_page)
            if not isinstance(more, list) or not more:
                break
            results.extend(more)
            page += 1

        return [Shipment.model_validate(s) for s in results]

    # ---------- high-level API ----------

    async def get_by_status(
        self,
        statuses: list[ShipmentStatus] | None = None,
        date_from: date | None = None,
        date_to: date | None = None,
        date_type: str = "eta",
        include: list[str] | None = None,
        poll_timeout: float = 120.0,
    ) -> list[Shipment]:
        """Find shipments matching the given statuses within a date window.

        Submits an async job and polls until results are ready.
        Defaults to the full tracked status set and the current calendar year.
        """
        statuses_resolved = list(statuses) if statuses else list(DEFAULT_STATUSES)
        today = date.today()
        date_from = date_from or today.replace(month=1, day=1)
        date_to = date_to or today.replace(month=12, day=31)

        job_id = await self._submit_job(
            statuses=statuses_resolved,
            date_from=date_from,
            date_to=date_to,
            date_type=date_type,
            include=include,
        )
        return await self._fetch_job_all(job_id, timeout=poll_timeout)

    async def get_by_po(self, po_number: str) -> list[Shipment]:
        """Look up shipments associated with a PO number."""
        r = await self._client.get(
            f"/purchase-order/{po_number}",
            params={"include[]": "documents"},
        )
        r.raise_for_status()
        return self._as_shipments(r.json())

    async def get_by_container(self, container_number: str) -> list[Shipment]:
        """Look up a shipment by container number."""
        r = await self._client.get(
            f"/container/{container_number}",
            params={"include[]": "documents"},
        )
        r.raise_for_status()
        return self._as_shipments(r.json())

    async def get_latest(
        self, page: int = 1, per_page: int = 50
    ) -> list[Shipment]:
        """Fetch shipments from the most recent completed job."""
        r = await self._client.get(
            "/shipments/latest",
            params={"page": page, "per_page": per_page},
        )
        r.raise_for_status()
        data = r.json()
        return self._as_shipments(data) if isinstance(data, list) else []

    @staticmethod
    def _as_shipments(data: Any) -> list[Shipment]:
        if isinstance(data, list):
            return [Shipment.model_validate(s) for s in data]
        if isinstance(data, dict):
            return [Shipment.model_validate(data)]
        return []


if __name__ == "__main__":

    async def main() -> None:
        async with AllwaysClient() as client:
            by_po = await client.get_by_po("340055-00")
            print(f"by PO 340055-00: {len(by_po)} shipment(s)")
            for s in by_po[:3]:
                print(f"  id={s.id}  mbl={s.mbl}  status={s.status}  eta={s.eta}")

            by_status = await client.get_by_status(
                statuses=["sailed", "arriving"],
                date_from=date(2026, 1, 1),
                date_to=date(2026, 7, 31),
            )
            print(f"\nby status [sailed, arriving]: {len(by_status)} shipment(s)")
            for s in by_status[:3]:
                print(f"  id={s.id}  mbl={s.mbl}  status={s.status}  eta={s.eta}")

    asyncio.run(main())
