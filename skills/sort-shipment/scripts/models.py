"""
Data models for the Shipment Agent.
Field names follow the SKILL.md output schema.
"""

from datetime import date
from pydantic import BaseModel


class Shipment(BaseModel):
    model_config = {"populate_by_name": True}

    po_number: str
    shipment_idx: int
    brand: str
    style: str
    pairs: int
    lh_xf: date | None = None
    etd_port: date | None = None
    eta_sa: date | None = None
    eta_fac: date | None = None
    customer_requested_xf: date | None = None
    container_type: str
    container_number: str | None = None
    remark: str | None = None
