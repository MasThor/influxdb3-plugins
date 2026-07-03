# 001 — Implementation Plan: InfluxDB 3 Database Auto-Provisioning & Plugin Triggers Upsert

This document details the configuration and scripts designed to initialize InfluxDB 3 databases and automatically insert or update (upsert) the downsampling triggers needed for OEE aggregation.

---

## 📋 Objectives & Constraints

1. **Idempotence & Safety**:
   - **Database Checks**: Before creating a database, the system checks if it already exists. If yes, it skips creation to avoid errors or data modification.
   - **Trigger Upserts**: If a trigger already exists, the initialization script will delete the old trigger first, and then create the new trigger (upsert pattern). If it does not exist, it will cleanly install the new one.
   - **Data Retention**: Under no circumstances will existing data in the database be deleted or overwritten. The database named volume `influxdb_data` remains independent of container build/recreate cycles.

2. **Required Databases**:
   - `energy_monitoring` (stores raw 10-second data)
   - `energy_minutes` (target for 1-minute aggregations)
   - `energy_hour` (target for hourly aggregations)

3. **OEE Aggregation Scope**:
   - `raw_to_minutes` trigger: aggregates `energy_raw` fields (power, energy, voltage, current) into 1-minute buckets in `energy_minutes`.
   - `minutes_to_hourly` trigger: aggregates 1-minute fields into hourly buckets in `energy_hour`.

---

## 🛠️ Proposed Configurations & Code

### 1. docker-compose.yml
Updates the orchestration files to:
- Build a custom InfluxDB 3 image locally (copying plugin files).
- Expose ports `8086` for InfluxDB and `8888` for the Explorer UI.
- Execute the `influxdb-init` sidecar only after the database engine becomes healthy.
- Securely mount configuration directories.

### 2. init/install_plugins.sh
Introduces database verification and creation logic alongside robust trigger upserts:

#### Database Creation Check logic:
```bash
check_and_create_database() {
  local db_name="$1"
  # Fetch all databases and grep for exact match
  if influxdb3 show databases --host "$INFLUX_HOST" --token "$TOKEN" | grep -qx "$db_name"; then
    echo "Database '$db_name' already exists. Skipping creation."
  else
    echo "Database '$db_name' does not exist. Creating..."
    influxdb3 create database "$db_name" --host "$INFLUX_HOST" --token "$TOKEN"
  fi
}
```

#### Trigger Upsert logic:
```bash
upsert_trigger() {
  local name="$1"
  local db="$2"
  # Delete if exists (ignore error if it doesn't)
  influxdb3 delete trigger --host "$INFLUX_HOST" --token "$TOKEN" --database "$db" "$name" 2>/dev/null || true
  # Create new trigger
  influxdb3 create trigger --host "$INFLUX_HOST" --token "$TOKEN" ... "$name"
}
```

---

## 🏁 Verification Steps

1. Launch Docker Compose:
   ```bash
   docker compose up -d --build
   ```
2. Verify the sidecar initialization logs:
   ```bash
   docker compose logs -f influxdb-init
   ```
3. Run the container CLI query to ensure triggers and databases are active:
   ```bash
   docker exec influxdb3 influxdb3 show databases --token apiv3_Z71qWXoxUl-xXBxD4RHHrn2GNn9dH_l0bel5G7Vqmm6Z-JupQskVsMeGKPeehc_sQpTJwGTgtpFZRF6E3hNrqA
   ```
