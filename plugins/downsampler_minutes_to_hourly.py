# -*- coding: utf-8 -*-
"""
downsampler_minutes_to_hourly.py
─────────────────────────────────────────────────────────────────────────────
InfluxDB 3 Processing Engine Plugin
Role   : Aggregate energy_minute (1m data) → energy_hour (1h aggregate)
Source : database 'energy_minutes'  (CROSS-DATABASE READ via query())
Target : database 'energy_hour'     (database tempat trigger dipasang)
Trigger: Scheduled — berjalan setiap 1 menit (cek jam baru)

PENTING — Cara install trigger (CLI):
  influxdb3 create trigger \\
    --trigger-spec "every:1m" \\
    --plugin-filename "downsampler_minutes_to_hourly.py" \\
    --database energy_hour \\
    --trigger-arguments "source_db=energy_minutes,source_measurement=energy_minute,target_measurement=energy_hour,lookback_hours=2" \\
    minutes_to_hourly

CATATAN TEKNIS:
  - SUM(sum_energy_kwh) → total energi DIJUMLAHKAN (bukan dirata-rata)
  - AVG(avg_power_kw)   → power dirata-rata (durasi tiap bucket menit sama)
  - query() cross-database hanya tersedia di InfluxDB 3.10+
  - Trigger WAJIB dipasang di database TARGET (energy_hour)
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
    source_db          = args.get("source_db", "energy_minutes")
    source_measurement = args.get("source_measurement", "energy_minute")
    target_measurement = args.get("target_measurement", "energy_hour")
    lookback_hours     = int(args.get("lookback_hours", 2))

    # ── 2. Hitung jendela waktu (window) ─────────────────────────────────
    now     = datetime.now(timezone.utc)
    to_dt   = now.replace(minute=0, second=0, microsecond=0)   # floor ke jam sekarang
    from_dt = to_dt - timedelta(hours=lookback_hours)           # lookback N jam ke belakang

    from_str = from_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    to_str   = to_dt.strftime("%Y-%m-%dT%H:%M:%SZ")

    influxdb3_local.info(
        f"[min→hour] Window: [{from_str}, {to_str}) "
        f"| source: '{source_db}'.'{source_measurement}'"
    )

    # ── 3. SQL: Agregasi data menit ke bucket 1 jam ───────────────────────
    # PENTING: SUM(sum_energy_kwh) karena energi harus dijumlahkan,
    # AVG untuk power/voltage/current (durasi tiap bucket menit sama panjang)
    sql = f"""
        SELECT
            DATE_BIN(INTERVAL '1 hour', time, TIMESTAMP '1970-01-01') AS bucket,
            machine_id,
            location,
            AVG(avg_power_kw)       AS avg_power_kw,
            SUM(sum_energy_kwh)     AS sum_energy_kwh,
            AVG(avg_voltage_v)      AS avg_voltage_v,
            AVG(avg_current_a)      AS avg_current_a,
            AVG(avg_power_factor)   AS avg_power_factor,
            MIN(min_power_kw)       AS min_power_kw,
            MAX(max_power_kw)       AS max_power_kw,
            SUM(sample_count)       AS sample_count
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
        influxdb3_local.error(f"[min→hour] Query ke '{source_db}' gagal: {exc}")
        return

    if not rows:
        influxdb3_local.info(
            f"[min→hour] Tidak ada data di '{source_db}'.'{source_measurement}' "
            f"pada window [{from_str}, {to_str}], skip."
        )
        return

    influxdb3_local.info(f"[min→hour] {len(rows)} baris ditemukan, mulai downsample...")

    # ── 5. Tulis hasil agregasi ke target database ────────────────────────
    rows_written = 0
    rows_skipped = 0

    for row in rows:
        bucket   = row.get("bucket")
        machine  = str(row.get("machine_id") or "unknown")
        location = str(row.get("location") or "unknown")

        if bucket is None:
            rows_skipped += 1
            influxdb3_local.warn(f"[min→hour] Skip baris: bucket=None (row={row})")
            continue

        ts_ns = _to_ns(bucket)
        if ts_ns is None:
            rows_skipped += 1
            influxdb3_local.warn(f"[min→hour] Skip baris: bucket tidak valid ({bucket!r})")
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
            influxdb3_local.error(f"[min→hour] Write gagal {machine}@{bucket}: {exc}")

    influxdb3_local.info(
        f"[min→hour] Selesai — ditulis: {rows_written}, dilewati: {rows_skipped} "
        f"→ target: '{target_measurement}' di database ini (energy_hour)"
    )


# ── Helpers ───────────────────────────────────────────────────────────────────

def _safe_float(value) -> float:
    """Kembalikan float, atau 0.0 untuk None/NaN/error."""
    try:
        v = float(value)
        return 0.0 if v != v else v  # NaN guard
    except (TypeError, ValueError):
        return 0.0


def _to_ns(bucket) -> "int | None":
    """Konversi nilai kolom bucket (berbagai format) menjadi epoch nanosecond."""
    try:
        if isinstance(bucket, (int, float)):
            return int(bucket)

        if hasattr(bucket, "timestamp"):
            return int(bucket.timestamp() * 1_000_000_000)

        if isinstance(bucket, str) and bucket.isdigit():
            return int(bucket)

        if isinstance(bucket, str):
            clean = bucket.replace("Z", "+00:00") if bucket.endswith("Z") else bucket
            return int(datetime.fromisoformat(clean).timestamp() * 1_000_000_000)

        return int(datetime.fromisoformat(str(bucket)).timestamp() * 1_000_000_000)

    except Exception:
        try:
            return int(float(str(bucket)))
        except Exception:
            return None
