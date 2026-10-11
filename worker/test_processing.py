from processing import validate_record, process_batch

failures = []

def check(name, cond):
    print(("PASS" if cond else "FAIL"), "-", name)
    if not cond:
        failures.append(name)


ok, _, _ = validate_record(
    {"region": "West", "amount": 100, "sale_date": "2026-01-01", "order_id": "x"})
check("valid record accepted", ok)

ok, reason, _ = validate_record({"region": None, "amount": 100, "sale_date": "2026-01-01"})
check("missing region rejected", not ok and reason == "missing_region")

ok, reason, _ = validate_record({"region": "W", "amount": -5, "sale_date": "2026-01-01"})
check("negative amount rejected", not ok and reason == "non_positive_amount")

ok, reason, _ = validate_record({"region": "W", "amount": "abc", "sale_date": "2026-01-01"})
check("non-numeric amount rejected", not ok and reason == "non_numeric_amount")

ok, reason, _ = validate_record({"region": "W", "amount": 5, "sale_date": "not-a-date"})
check("bad date rejected", not ok and reason == "unparseable_date")

ok, reason, _ = validate_record({"region": "W", "amount": 5, "sale_date": None})
check("missing date rejected", not ok and reason == "missing_date")

ok, reason, _ = validate_record({"region": "W", "amount": float("nan"),
                                 "sale_date": "2026-01-01"})
check("NaN amount rejected", not ok and reason == "non_finite_amount")

ok, reason, _ = validate_record({"region": "W", "amount": float("inf"),
                                 "sale_date": "2026-01-01"})
check("Infinity amount rejected", not ok and reason == "non_finite_amount")


batch = [
    {"region": "West", "amount": 100, "sale_date": "2026-01-01", "order_id": "1"},
    {"region": "West", "amount": 50, "sale_date": "2026-01-02", "order_id": "2"},
    {"region": "East", "amount": 200, "sale_date": "2026-01-03", "order_id": "3"},
    {"region": "East", "amount": -5, "sale_date": "2026-01-04", "order_id": "4"},
    {"region": None, "amount": 10, "sale_date": "2026-01-05", "order_id": "5"},
    {"region": "West", "amount": 100, "sale_date": "2026-01-01", "order_id": "1"},
]
result = process_batch(batch)

check("3 rows processed", result["rows_processed"] == 3)
check("3 rows rejected", result["rows_rejected"] == 3)
check("West total = 150", result["region_totals"]["West"] == 150)
check("East total = 200", result["region_totals"]["East"] == 200)
check("rejection breakdown has non_positive_amount",
      result["rejection_breakdown"].get("non_positive_amount") == 1)
check("rejection breakdown has missing_region",
      result["rejection_breakdown"].get("missing_region") == 1)
check("rejection breakdown has duplicate_order_id",
      result["rejection_breakdown"].get("duplicate_order_id") == 1)

empty = process_batch([])
check("empty batch -> 0 processed", empty["rows_processed"] == 0)

mixed = process_batch(["a", 123, None, {"region": "W", "amount": 10,
                       "sale_date": "2026-01-01", "order_id": "z"}])
check("non-dict elements rejected, not crashed", mixed["rows_processed"] == 1)
check("non-dict elements counted as not_an_object",
      mixed["rejection_breakdown"].get("not_an_object") == 3)

total_garbage = process_batch(["x", 1, None, [1, 2]])
check("all-garbage batch does not throw, 0 processed",
      total_garbage["rows_processed"] == 0 and total_garbage["rows_rejected"] == 4)

adversarial = [
    None, [], "x", {}, 1, 3.14, True,
    {"region": 1},
    {"region": ["west"], "amount": 5, "sale_date": "2024-01-01"},
    {"order_id": {"a": 1}},
    {"order_id": [1, 2]},
    {"amount": []},
    {"amount": float("nan"), "region": "W", "sale_date": "2024-01-01"},
    {"region": "W", "amount": 10, "sale_date": "2024-01-01", "order_id": "ok"},
]
try:
    summary = process_batch(adversarial)
    raised = False
except Exception:
    raised = True
    summary = None
check("process_batch is total (never raises on JSON input)", raised is False)
check("totality test still processes the one valid record",
      summary is not None and summary["rows_processed"] == 1)
check("invalid_region_type rejection recorded",
      summary and summary["rejection_breakdown"].get("invalid_region_type", 0) >= 1)
check("invalid_order_id_type rejection recorded",
      summary and summary["rejection_breakdown"].get("invalid_order_id_type", 0) >= 1)

hostile = [None, [], "x", 42, {}, {"region": 1}, {"region": ["w"]},
           {"order_id": {}}, {"order_id": []}, {"amount": []},
           {"region": "w", "amount": "1e999", "sale_date": "2024-01-01"},
           {"region": "w", "amount": 5, "sale_date": 7}]
try:
    hsummary = process_batch(hostile)
    hraised = False
except Exception:
    hraised = True
    hsummary = None
check("all-hostile batch never raises", hraised is False)
check("all-hostile batch processes nothing",
      hsummary is not None and hsummary["rows_processed"] == 0)
check("all-hostile batch rejects every record",
      hsummary is not None and hsummary["rows_rejected"] == len(hostile))


print()
if failures:
    print(f"{len(failures)} FAILURE(S):", failures)
    raise SystemExit(1)
print("ALL UNIT TESTS PASSED")
