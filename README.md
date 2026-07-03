# InfluxDB 3 Custom Image with Auto Plugin Registration

Custom Docker image based on `influxdb:3.10-core` with Processing Engine plugins baked directly into the image, plus a sidecar service to auto-register triggers upon startup.

---

## Folder Structure

```
influxdb3-plugins/
├── Dockerfile                          ← Build custom image
├── docker-compose.yml                  ← Orchestration: InfluxDB + Init sidecar + UI Explorer
├── .env.example                        ← Environment variables template
│
├── config/
│   └── admin-token.json               ← Static admin token (mounted :ro)
│
├── influx-ui/
│   └── config/
│       └── config.json                ← InfluxDB 3 UI connection configuration
│
├── init/
│   └── install_plugins.sh             ← Sidecar: auto-register plugin triggers
│
└── plugins/
    ├── downsampler_raw_to_minutes.py  ← Plugin: RAW (10s) → MINUTES (1m)
    └── downsampler_minutes_to_hourly.py ← Plugin: MINUTES (1m) → HOURLY (1h)
```

---

## services

The following ports are exposed:
- **InfluxDB 3 Core**: `http://localhost:8086`
- **InfluxDB 3 Explorer UI**: `http://localhost:8888`

---

## Quick Start

### 1. Setup Environment

```bash
cp .env.example .env
# Edit .env if you need to change ports or the token
```

### 2. Build & Run

```bash
docker compose up -d --build
```

### 3. Check Installer Logs

```bash
# Check the auto-registration process
docker compose logs -f influxdb-init

# Verify InfluxDB status
docker compose logs -f influxdb
```

### 4. Verify Triggers are Registered

```bash
# Check triggers in the energy_minutes database
curl -s -H "Authorization: Bearer $(cat config/admin-token.json | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")" \
  http://localhost:8086/api/v3/configure/trigger?db=energy_minutes

# Or via CLI inside the container
docker exec influxdb3 influxdb3 query \
  --token $(cat config/admin-token.json | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])") \
  --database energy_minutes \
  "SELECT * FROM system.processing_engine_triggers"
```

---

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                     docker compose up                       │
│                                                             │
│  1. Build custom image (bake plugins to /var/lib/...)       │
│  2. Start influxdb container                                │
│  3. InfluxDB boot & healthcheck passes                      │
│  4. influxdb-init sidecar starts                            │
│     ├── Wait for API to be ready (retry 5s, max 2 mins)     │
│     ├── Upsert trigger raw_to_minutes                       │
│     ├── Upsert trigger minutes_to_hourly                    │
│     ├── Verify active triggers                              │
│     └── Exit 0 ✅                                           │
└─────────────────────────────────────────────────────────────┘
```

### Why use a sidecar instead of an entrypoint wrapper?

- **Separation of Concerns** — Keeps the InfluxDB container "clean"
- **Idempotency** — The installer can be run multiple times without side effects
- **Restart behavior** — `restart: on-failure` only restarts if there is an error, not upon success
- **Easy debugging** — Installer logs are separated from InfluxDB database logs

---

## Static Token

The admin token is configured using a JSON file (rather than directly via environment variables) for security:

```json
// config/admin-token.json
{
  "name": "static-admin-token",
  "token": "apiv3_Z71qWXoxUl-xXBxD4RHHrn2GNn9dH_l0bel5G7Vqmm6Z-JupQskVsMeGKPeehc_sQpTJwGTgtpFZRF6E3hNrqA",
  "expiry": null
}
```

Registered to InfluxDB via:
```yaml
environment:
  - INFLUXDB3_ADMIN_TOKEN_FILE=/etc/influxdb3/admin-token.json
```

**Benefits of the file approach vs environment variables:**
- Token does not appear in `docker inspect` or process list commands
- Easier to rotate (update the file and restart the container)
- Compatible with Docker Secrets in Swarm mode

---

## Data Persistence

Data **will not be lost** when the image is rebuilt since it is stored in a Docker named volume:

```yaml
volumes:
  - influxdb_data:/var/lib/influxdb3  # ← data is secure here
```

**To create a backup:**
```bash
docker run --rm \
  -v influxdb3-plugins_influxdb_data:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/influxdb-backup-$(date +%Y%m%d).tar.gz /data
```

---

## Adding a New Plugin

1. Add the `.py` file to the `plugins/` folder
2. Add an `upsert_trigger` line in `init/install_plugins.sh`
3. Rebuild the image & restart:
   ```bash
   docker compose up -d --build
   ```

---

## Publishing to a Docker Registry

Jika Anda ingin mengunggah (upload) custom image ini ke registry seperti **Docker Hub**, **GitHub Container Registry (GHCR)**, atau **AWS ECR** agar bisa digunakan di server production tanpa perlu membawa file `.py` dan `Dockerfile` lagi, ikuti langkah ini:

### 1. Build & Tag Image
Ganti `username` dengan nama akun Docker Hub/Registry Anda:
```bash
docker build -t username/influxdb3-custom:1.0.0 .
```

### 2. Login ke Registry & Push
```bash
docker login
docker push username/influxdb3-custom:1.0.0
```

### 3. Update docker-compose.yml di Server Production
Di server production, Anda tidak perlu lagi melakukan `build`. Cukup ubah `docker-compose.yml` menjadi:
```yaml
  influxdb:
    image: username/influxdb3-custom:1.0.0
    container_name: influxdb3
    # Hapus bagian 'build:'
    ...

  influxdb-init:
    image: username/influxdb3-custom:1.0.0
    container_name: influxdb3-init
    # Hapus bagian 'build:'
    ...
```
Dengan begitu, Docker Compose hanya akan melakukan *pull* dari registry dan tidak memerlukan file `Dockerfile` maupun source code plugin saat di-deploy.

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `influxdb-init` keeps restarting | Check `docker compose logs influxdb-init` — the token is likely incorrect |
| Plugins are not installed | Ensure the `.py` file is present in `plugins/` before building |
| Data is missing | Do not delete the `influxdb_data` volume |
| Port 8086 conflict | Change the `INFLUXDB_PORT` in your `.env` file |

