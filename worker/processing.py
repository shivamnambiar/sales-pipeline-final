import math
from datetime import datetime


def validate_record(rec: dict) -> tuple[bool, str | None, float | None]:
    region = rec.get("region")
    if region is None:
        return False, "missing_region", None
    if not isinstance(region, str):
        return False, "invalid_region_type", None
    if rec.get("amount") is None:
        return False, "missing_amount", None
    try:
        amount = float(rec["amount"])
    except (TypeError, ValueError):
        return False, "non_numeric_amount", None
    if not math.isfinite(amount):
        return False, "non_finite_amount", None
    if amount <= 0:
        return False, "non_positive_amount", None
    sale_date = rec.get("sale_date")
    if sale_date is None:
        return False, "missing_date", None
    try:
        datetime.fromisoformat(sale_date)
    except (TypeError, ValueError):
        return False, "unparseable_date", None
    return True, None, amount


def process_batch(records: list[dict]) -> dict:
    region_totals: dict[str, float] = {}
    rejected: dict[str, int] = {}
    seen_order_ids: set[str] = set()
    processed = 0
    rejected_count = 0

    for rec in records:
        if not isinstance(rec, dict):
            rejected_count += 1
            rejected["not_an_object"] = rejected.get("not_an_object", 0) + 1
            continue

        oid = rec.get("order_id")
        if oid is not None and not isinstance(oid, str):
            rejected_count += 1
            rejected["invalid_order_id_type"] = rejected.get("invalid_order_id_type", 0) + 1
            continue
        if oid is not None and oid in seen_order_ids:
            rejected_count += 1
            rejected["duplicate_order_id"] = rejected.get("duplicate_order_id", 0) + 1
            continue

        valid, reason, amount = validate_record(rec)
        if not valid:
            rejected_count += 1
            rejected[reason] = rejected.get(reason, 0) + 1
            continue

        if oid is not None:
            seen_order_ids.add(oid)
        region = rec["region"]
        region_totals[region] = region_totals.get(region, 0.0) + amount
        processed += 1

    return {
        "region_totals": region_totals,
        "rows_processed": processed,
        "rows_rejected": rejected_count,
        "rejection_breakdown": rejected,
    }
