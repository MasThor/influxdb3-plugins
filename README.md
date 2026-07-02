# InfluxDB 3 Custom Image with Auto Plugin Registration

Custom Docker image berbasis `influxdb:3.10-core` dengan plugin Processing Engine ter-bake langsung ke dalam image, plus sidecar service untuk auto-register trigger saat startup.

---

## Struktur Folder

```
influxdb3-plugins/
├── Dockerfile                          ← Build custom image
├── docker-compose.yml                  ← Orkestrasi: InfluxDB + Init sidecar
├── .env.example                        ← Template environment variables
│
├── config/
│   └── admin-token.json               ← Static admin token (di-mount :ro)
│
├── init/
│   └── install_plugins.sh             ← Sidecar: auto-register plugin triggers
│
└── plugins/
    ├── downsampler_raw_to_minutes.py  ← Plugin: RAW (10s) → MINUTES (1m)
    └── downsampler_minutes_to_hourly.py ← Plugin: MINUTES (1m) → HOURLY (1h)
```

---

## Quick Start

### 1. Setup environment

```bash
cp .env.example .env
# Edit .env jika perlu mengubah port atau token
```

### 2. Build & jalankan

```bash
docker compose up -d --build
```

### 3. Cek log installer

```bash
# Lihat proses auto-register plugin
docker compose logs -f influxdb-init

# Lihat InfluxDB berjalan
docker compose logs -f influxdb
```

### 4. Verifikasi trigger terpasang

```bash
# Cek trigger di database energy_minutes
curl -s -H "Authorization: Bearer $(cat config/admin-token.json | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")" \
  http://localhost:8086/api/v3/configure/trigger?db=energy_minutes

# Atau via CLI di dalam container
docker exec influxdb3 influxdb3 query \
  --token $(cat config/admin-token.json | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])") \
  --database energy_minutes \
  "SELECT * FROM system.processing_engine_triggers"
```

---

## Cara Kerja

```
┌─────────────────────────────────────────────────────────────┐
│                     docker compose up                       │
│                                                             │
│  1. Build custom image (plugin di-bake ke /var/lib/...)     │
│  2. Start influxdb container                                │
│  3. InfluxDB boot & healthcheck pass                        │
│  4. influxdb-init sidecar mulai                             │
│     ├── Tunggu API ready (retry 5s, max 2 menit)            │
│     ├── Upsert trigger raw_to_minutes                       │
│     ├── Upsert trigger minutes_to_hourly                    │
│     ├── Verifikasi trigger aktif                            │
│     └── Exit 0 ✅                                           │
└─────────────────────────────────────────────────────────────┘
```

### Mengapa sidecar, bukan entrypoint wrapper?

- **Separation of Concerns** — InfluxDB container tetap "bersih"
- **Idempoten** — Installer bisa dijalankan ulang tanpa efek samping
- **Restart behavior** — `restart: on-failure` hanya restart jika error, tidak jika sudah sukses
- **Debugging mudah** — Log installer terpisah dari log InfluxDB

---

## Static Token

Token admin dikonfigurasi via file JSON (bukan env variable langsung) untuk keamanan:

```json
// config/admin-token.json
{
  "name": "static-admin-token",
  "token": "apiv3_xxxx...",
  "expiry": null
}
```

Didaftarkan ke InfluxDB via:
```yaml
environment:
  - INFLUXDB3_ADMIN_TOKEN_FILE=/etc/influxdb3/admin-token.json
```

**Keunggulan pendekatan file vs env variable:**
- Token tidak muncul di `docker inspect` atau process list
- Lebih mudah di-rotate (update file, restart container)
- Compatible dengan Docker Secrets di Swarm mode

---

## Data Persistence

Data **tidak akan hilang** saat image di-rebuild karena disimpan di Docker named volume:

```yaml
volumes:
  - influxdb_data:/var/lib/influxdb3  # ← data aman di sini
```

**Untuk backup:**
```bash
docker run --rm \
  -v influxdb3-plugins_influxdb_data:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/influxdb-backup-$(date +%Y%m%d).tar.gz /data
```

---

## Menambah Plugin Baru

1. Tambah file `.py` ke folder `plugins/`
2. Tambah baris `upsert_trigger` di `init/install_plugins.sh`
3. Rebuild image & restart:
   ```bash
   docker compose up -d --build
   ```

---

## Troubleshooting

| Masalah | Solusi |
|---------|--------|
| `influxdb-init` terus restart | Cek `docker compose logs influxdb-init` — kemungkinan token salah |
| Plugin tidak terpasang | Pastikan file `.py` ada di `plugins/` sebelum build |
| Data hilang | Jangan hapus volume `influxdb_data` |
| Port 8086 conflict | Ubah `INFLUXDB_PORT` di `.env` |
