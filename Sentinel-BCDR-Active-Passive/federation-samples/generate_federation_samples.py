#!/usr/bin/env python3
"""Generate Delta-format sample tables for Sentinel data lake ADLS Gen2 federation testing.

The Microsoft Sentinel data lake ADLS Gen2 federation connector only reads tables in
**Delta Parquet** format. A Delta table is a folder containing a ``_delta_log/`` transaction
log plus the ``.snappy.parquet`` data files that the log references. Plain Parquet files with
no ``_delta_log/`` are NOT recognized (the connector reports "No data available"), and any
Parquet file in the folder that is not listed in the log is ignored by the Delta reader.

This script produces three sample Delta tables under ``./out/``. Each one is a top-level
"table" folder to upload to the ADLS Gen2 container:

  fedsample1/  decoy plain parquet (10 rows, NOT in the Delta log) + Delta-committed 5 rows  -> connector shows 5
  fedsample2/  decoy plain parquet (10 rows, NOT in the Delta log) + Delta-committed 0 rows  -> connector shows 0
  fedsample3/  decoy plain parquet (0 rows, empty, NOT in the Delta log) + Delta-committed 10 rows  -> connector shows 10

If fedsample3 shows 10 rows while fedsample1 shows 5 (not 15), it confirms the connector reads
only Delta-committed rows and ignores stray plain Parquet -- i.e. the Delta format is mandatory.

Each table folder contains:
  _delta_log/00000000000000000000.json   the Delta transaction log (required)
  part-00000-<guid>.snappy.parquet       the data file referenced by the log
  extra_plain_data.parquet               a plain parquet NOT referenced by the log (ignored by the reader)
The decoy extra_plain_data.parquet has 10 rows in fedsample1 / fedsample2 and 0 rows (empty) in
fedsample3, to show the reader ignores it regardless of its contents.

Table schema:
  TimeGenerated   timestamp (UTC)
  Hostname        string
  SourceIP        string
  SourcePort      int32
  DestinationIP   string
  DestinationPort int32
  Action          string  (allow / deny)

Usage:
  pip install pyarrow
  python generate_federation_samples.py

Then upload each fedsampleN/ folder (keeping the _delta_log/ subfolder) to the
ADLS Gen2 container, and create a federation connector instance pointing at the
account endpoint, e.g. https://<account>.dfs.core.windows.net/.

The TimeGenerated values are in a fixed window starting 2026-06-08T00:00:00Z, so query with an
explicit time range rather than ago(), e.g.:

  fedsample3_<instance>
  | where TimeGenerated between (datetime(2026-06-08) .. datetime(2026-06-09))
"""

from __future__ import annotations

import json
import os
import random
import shutil
import uuid
from datetime import datetime, timedelta, timezone

import pyarrow as pa
import pyarrow.parquet as pq

# Arrow schema written into every Parquet file. TimeGenerated is a microsecond UTC
# timestamp; the two port columns are 32-bit integers.
ARROW_SCHEMA = pa.schema(
    [
        ("TimeGenerated", pa.timestamp("us", tz="UTC")),
        ("Hostname", pa.string()),
        ("SourceIP", pa.string()),
        ("SourcePort", pa.int32()),
        ("DestinationIP", pa.string()),
        ("DestinationPort", pa.int32()),
        ("Action", pa.string()),
    ]
)

# Matching Delta schema. Delta type names: timestamp, string, integer (int32), long (int64).
DELTA_FIELDS = [
    ("TimeGenerated", "timestamp"),
    ("Hostname", "string"),
    ("SourceIP", "string"),
    ("SourcePort", "integer"),
    ("DestinationIP", "string"),
    ("DestinationPort", "integer"),
    ("Action", "string"),
]

BASE_TIME = datetime(2026, 6, 8, 0, 0, 0, tzinfo=timezone.utc)
HOSTNAMES = ["web01", "web02", "db01", "app01", "dc01", "fw01", "proxy01", "mail01"]
COMMON_PORTS = [22, 80, 443, 3389, 8080, 53]
ACTIONS = ["allow", "deny"]


def _iso(dt: datetime) -> str:
    """Format a datetime as Delta stats expect, e.g. 2026-06-08T00:00:00.000Z."""
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def generate_rows(n: int, seed: int) -> list[dict]:
    """Return n deterministic pseudo-random event rows."""
    rng = random.Random(seed)
    rows: list[dict] = []
    for i in range(n):
        rows.append(
            {
                "TimeGenerated": BASE_TIME + timedelta(minutes=15 * i),
                "Hostname": rng.choice(HOSTNAMES),
                "SourceIP": ".".join(str(rng.randint(1, 254)) for _ in range(4)),
                "SourcePort": rng.randint(1024, 65535),
                "DestinationIP": ".".join(str(rng.randint(1, 254)) for _ in range(4)),
                "DestinationPort": rng.choice(COMMON_PORTS),
                "Action": rng.choice(ACTIONS),
            }
        )
    return rows


def write_parquet(path: str, rows: list[dict]):
    """Write rows to a Snappy Parquet file. Returns (size_bytes, min_tg_iso, max_tg_iso)."""
    columns = {name: [r[name] for r in rows] for name, _ in DELTA_FIELDS}
    table = pa.table(columns, schema=ARROW_SCHEMA)
    pq.write_table(table, path, compression="snappy", use_deprecated_int96_timestamps=False)
    size = os.path.getsize(path)
    if rows:
        times = [r["TimeGenerated"] for r in rows]
        return size, _iso(min(times)), _iso(max(times))
    return size, None, None


def schema_string() -> str:
    """Build the escaped JSON schema string embedded in the Delta metaData action."""
    fields = [
        {"name": name, "type": dtype, "nullable": True, "metadata": {}}
        for name, dtype in DELTA_FIELDS
    ]
    return json.dumps({"type": "struct", "fields": fields}, separators=(",", ":"))


def write_delta_log(table_dir, parquet_name, size, num_records, min_tg, max_tg) -> None:
    """Write _delta_log/00000000000000000000.json describing a single committed Parquet file."""
    log_dir = os.path.join(table_dir, "_delta_log")
    os.makedirs(log_dir, exist_ok=True)
    now_ms = int(datetime.now(timezone.utc).timestamp() * 1000)

    if num_records > 0:
        stats = {
            "numRecords": num_records,
            "minValues": {"TimeGenerated": min_tg},
            "maxValues": {"TimeGenerated": max_tg},
        }
    else:
        stats = {"numRecords": 0, "minValues": {}, "maxValues": {}}

    actions = [
        {"protocol": {"minReaderVersion": 1, "minWriterVersion": 2}},
        {
            "metaData": {
                "id": str(uuid.uuid4()),
                "format": {"provider": "parquet", "options": {}},
                "schemaString": schema_string(),
                "partitionColumns": [],
                "configuration": {},
                "createdTime": now_ms,
            }
        },
        {
            "add": {
                "path": parquet_name,
                "partitionValues": {},
                "size": size,
                "modificationTime": now_ms,
                "dataChange": True,
                "stats": json.dumps(stats, separators=(",", ":")),
            }
        },
        {
            "commitInfo": {
                "timestamp": now_ms,
                "operation": "WRITE",
                "operationParameters": {"mode": "Overwrite", "partitionBy": "[]"},
                "isolationLevel": "Serializable",
                "isBlindAppend": True,
                "operationMetrics": {
                    "numFiles": "1",
                    "numOutputRows": str(num_records),
                    "numOutputBytes": str(size),
                },
            }
        },
    ]

    log_path = os.path.join(log_dir, "00000000000000000000.json")
    with open(log_path, "w", encoding="utf-8") as handle:
        for action in actions:
            handle.write(json.dumps(action, separators=(",", ":")) + "\n")


def build_sample(out_root, name, delta_rows, decoy_rows, seed, include_decoy=True) -> None:
    """Create one sample table folder with a committed Delta file and an optional decoy.

    When include_decoy is True a plain ``extra_plain_data.parquet`` is written next to the Delta
    data file but is NOT referenced by the transaction log, so the Delta reader ignores it. It is
    written even when decoy_rows is 0, producing a valid but empty plain Parquet file.
    """
    table_dir = os.path.join(out_root, name)
    if os.path.exists(table_dir):
        shutil.rmtree(table_dir)
    os.makedirs(table_dir, exist_ok=True)

    # Delta-managed data file, referenced by the transaction log.
    parquet_name = f"part-00000-{uuid.uuid4()}.snappy.parquet"
    size, min_tg, max_tg = write_parquet(
        os.path.join(table_dir, parquet_name), generate_rows(delta_rows, seed)
    )
    write_delta_log(table_dir, parquet_name, size, delta_rows, min_tg, max_tg)

    # Decoy plain Parquet, NOT referenced by the log, so the reader ignores it. Written even at
    # 0 rows so the folder still contains a (valid but empty) plain Parquet file.
    if include_decoy:
        write_parquet(
            os.path.join(table_dir, "extra_plain_data.parquet"),
            generate_rows(decoy_rows, seed + 1000),
        )

    print(f"  {name}/  delta-committed={delta_rows} row(s), decoy-plain={decoy_rows} row(s)")


def main() -> None:
    out_root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
    os.makedirs(out_root, exist_ok=True)
    print(f"Generating Delta federation samples into: {out_root}")
    build_sample(out_root, "fedsample1", delta_rows=5, decoy_rows=10, seed=1)   # connector -> 5
    build_sample(out_root, "fedsample2", delta_rows=0, decoy_rows=10, seed=2)   # connector -> 0
    build_sample(out_root, "fedsample3", delta_rows=10, decoy_rows=0, seed=3)   # connector -> 10 (decoy is empty)
    print("Done. Upload each fedsampleN/ folder (including its _delta_log/ subfolder) to the container.")


if __name__ == "__main__":
    main()
