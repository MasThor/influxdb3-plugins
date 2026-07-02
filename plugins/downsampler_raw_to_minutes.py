# -*- coding: utf-8 -*-
"""
downsampler_raw_to_minutes.py
─────────────────────────────────────────────────────────────────────────────
InfluxDB 3 Processing Engine Plugin
Role   : Aggregate energy_raw (10s data) → energy_minute (1m aggregate)
Source : database 'energy_monitoring'  (CROSS-DATABASE READ via query())
Target : database 'energy_minutes'     (database tempat trigger dipasang)
Trigger: Scheduled — berjalan setiap 1 menit

PENTING — Cara install trigger (CLI):
  influxdb3 create trigger \\
    --trigger-spec "every:1m" \\
    --plugin-filename "downsampler_raw_to_minutes.py" \\
    --database energy_minutes \\
    --trigger-arguments "source_db=energy_monitoring,source_measurement=energy_raw,target_measurement=energy_minute,lookback_minutes=2" \\
    raw_to_minutes

CATATAN TEKNIS (InfluxDB 3.10+ Core/Enterprise):
  - query()  mendukung cross-database read via keyword `database=`
  - write()  SELALU menulis ke database tempat trigger berjalan
  - Trigger WAJIB dipasang di database TARGET (energy_minutes), bukan source
  - query() mengembalikan List[Dict[str, Any]] langsung (bukan PyArrow reader)
  - Gunakan influxdb3_local.info/warn/error untuk logging ke system table
─────────────────────────────────────────────────────────────────────────────
"""

from datetime import datetime, timezone, timedelta


def process_scheduled_call(influxdb3_local, call_time, args=None):
    """
    Entry point yang dipanggil InfluxDB 3 Processing Engine untuk scheduled trigger.

    Args:
        influxdb3_local : Objek shared API InfluxDB (query, write, cache, info/warn/error)
        call_time       : Waktu eksekusi terjadwal (datetime UTC)
        args            : Dict opsional dari --trigger-arguments
    """

    # ── 1. Konfigurasi ────────────────────────────────────────────────────
    args = args or {}
    source_db          = args.get("source_db", "energy_monitoring")
    source_measurement = args.get("source_measurement", "energy_raw")
    target_measurement = args.get("target_measurement", "energy_minute")
    lookback_minutes   = int(args.get("lookback_minutes", 2))

    # ── 2. Hitung jendela waktu (window) ─────────────────────────────────
    now     = datetime.now(timezone.utc)
    to_dt   = now.replace(second=0, microsecond=0)           # floor ke menit sekarang
    from_dt = to_dt - timedelta(minutes=lookback_minutes)     # lookback N menit ke belakang

    from_str = from_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    to_str   = to_dt.strftime("%Y-%m-%dT%H:%M:%SZ")

    influxdb3_local.info(
        f"[raw→min] Window: [{from_str}, {to_str}) "
        f"| source: '{source_db}'.'{source_measurement}'"
    )

    # ── 3. SQL: Agregasi data raw ke bucket 1 menit ───────────────────────
    sql = f"""
        SELECT
            DATE_BIN(INTERVAL '1 minute', time, TIMESTAMP '1970-01-01') AS bucket,
            machine_id,
            location,
            AVG(power_kw)       AS avg_power_kw,
            SUM(energy_kwh)     AS sum_energy_kwh,
            AVG(voltage_v)      AS avg_voltage_v,
            AVG(current_a)      AS avg_current_a,
            AVG(power_factor)   AS avg_power_factor,
            MIN(power_kw)       AS min_power_kw,
            MAX(power_kw)       AS max_power_kw,
            COUNT(*)            AS sample_count
        FROM {source_measurement}
        WHERE time >= TIMESTAMP '{from_str}'
          AND time <  TIMESTAMP '{to_str}'
        GROUP BY bucket, machine_id, location
        ORDER BY bucket ASC
    """

    # ── 4. Eksekusi query cross-database ─────────────────────────────────
    try:
        rows = influxdb3_local.query(sql, database=source_db)
    except Exception as exc:
        influxdb3_local.error(f"[raw→min] Query ke '{source_db}' gagal: {exc}")
        return

    if not rows:
        influxdb3_local.info(
            f"[raw→min] Tidak ada data di '{source_db}'.'{source_measurement}' "
            f"pada window [{from_str}, {to_str}], skip."
        )
        return

    influxdb3_local.info(f"[raw→min] {len(rows)} baris ditemukan, mulai downsample...")

    # ── 5. Tulis hasil agregasi ke target database ────────────────────────
    rows_written = 0
    rows_skipped = 0

    for row in rows:
        bucket   = row.get("bucket")
        machine  = str(row.get("machine_id") or "unknown")
        location = str(row.get("location") or "unknown")

        if bucket is None:
            rows_skipped += 1
            influxdb3_local.warn(f"[raw→min] Skip baris: bucket=None (row={row})")
            continue

        ts_ns = _to_ns(bucket)
        if ts_ns is None:
            rows_skipped += 1
            influxdb3_local.warn(f"[raw→min] Skip baris: bucket tidak valid ({bucket!r})")
            continue

        line = LineBuilder(target_measurement)
        line.tag("machine_id", machine)
        line.tag("location", location)
        line.float64_field("avg_power_kw",    _safe_float(row.get("avg_power_kw")))
        line.float64_field("sum_energy_kwh",  _safe_float(row.get("sum_energy_kwh")))
        line.float64_field("avg_voltage_v",   _safe_float(row.get("avg_voltage_v")))
        line.float64_field("avg_current_a",   _safe_float(row.get("avg_current_a")))
        line.float64_field("avg_power_factor",_safe_float(row.get("avg_power_factor")))
        line.float64_field("min_power_kw",    _safe_float(row.get("min_power_kw")))
        line.float64_field("max_power_kw",    _safe_float(row.get("max_power_kw")))
        line.int64_field("sample_count",      int(row.get("sample_count", 0)))
        line.time_ns(ts_ns)

        try:
            influxdb3_local.write(line)
            rows_written += 1
        except Exception as exc:
            rows_skipped += 1
            influxdb3_local.error(f"[raw→min] Write gagal {machine}@{bucket}: {exc}")

    influxdb3_local.info(
        f"[raw→min] Selesai — ditulis: {rows_written}, dilewati: {rows_skipped} "
        f"→ target: '{target_measurement}' di database ini (energy_minutes)"
    )


# ── Helpers ───────────────────────────────────────────────────────────────────

def _safe_float(value) -> float:
    """Kembalikan float, atau 0.0 untuk None/NaN/error."""
    try:
        v = float(value)
        return 0.0 if v != v else v  # NaN guard: NaN != NaN selalu True
    except (TypeError, ValueError):
        return 0.0


def _to_ns(bucket) -> "int | None":
    """Konversi nilai kolom bucket (berbagai format) menjadi epoch nanosecond."""
    try:
        # Case 1: sudah int/float (epoch nanosecond)
        if isinstance(bucket, (int, float)):
            return int(bucket)

        # Case 2: objek datetime dengan .timestamp()
        if hasattr(bucket, "timestamp"):
            return int(bucket.timestamp() * 1_000_000_000)

        # Case 3: string angka bulat ("1782890160000000000")
        if isinstance(bucket, str) and bucket.isdigit():
            return int(bucket)

        # Case 4: string ISO 8601 ("2026-07-01T14:04:00Z" atau "+00:00")
        if isinstance(bucket, str):
            clean = bucket.replace("Z", "+00:00") if bucket.endswith("Z") else bucket
            return int(datetime.fromisoformat(clean).timestamp() * 1_000_000_000)

        # Case 5: fallback ke str conversion
        return int(datetime.fromisoformat(str(bucket)).timestamp() * 1_000_000_000)

    except Exception:
        try:
            return int(float(str(bucket)))  # string desimal ("1782890160000000000.0")
        except Exception:
            return None
