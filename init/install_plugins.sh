#!/usr/bin/env bash
# =============================================================================
# install_plugins.sh
# =============================================================================
# Skrip sidecar untuk UPSERT (insert/update) InfluxDB 3 Processing Engine
# triggers secara otomatis setelah InfluxDB container sehat (healthy).
#
# Cara kerja:
#   1. Tunggu hingga InfluxDB API benar-benar siap (retry dengan backoff)
#   2. Jalankan upsert setiap trigger yang terdefinisi
#      - Upsert = delete (ignore error) → create → verify
#   3. Exit 0 jika semua sukses, exit 1 jika ada yang gagal
#
# Dijalankan oleh service 'influxdb-init' di docker-compose.
# Bukan dijalankan langsung oleh InfluxDB container itu sendiri.
# =============================================================================

# Hentikan script jika ada perintah yang gagal tanpa penanganan eksplisit.
# Catatan: set -e diaktifkan di sini tapi upsert_trigger() menangani error
# internal sendiri agar satu trigger gagal tidak menghentikan installer.
set -euo pipefail

# =============================================================================
# KONFIGURASI — Semua value bisa di-override via environment variable
# =============================================================================
INFLUX_HOST="${INFLUX_HOST:-http://influxdb:8181}"
TOKEN="${INFLUX_TOKEN:-}"
PLUGIN_DIR="${PLUGIN_DIR:-/var/lib/influxdb3/plugins}"

# Retry configuration untuk menunggu InfluxDB ready
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-120}"   # Maksimal tunggu 2 menit
RETRY_INTERVAL="${RETRY_INTERVAL:-5}"          # Cek setiap 5 detik

# =============================================================================
# WARNA & LOGGING
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $(date '+%H:%M:%S') $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*" >&2; }

# =============================================================================
# STEP 1: Validasi konfigurasi
# =============================================================================
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "   InfluxDB 3 Plugin Installer — Sidecar Init Service"
echo "═══════════════════════════════════════════════════════════"
echo ""

if [ -z "${TOKEN}" ]; then
  log_error "INFLUX_TOKEN tidak di-set! Export env variable sebelum menjalankan script ini."
  log_error "Contoh: export INFLUX_TOKEN=apiv3_xxxx..."
  exit 1
fi

log_info "Host  : ${INFLUX_HOST}"
log_info "Token : $(echo "${TOKEN}" | cut -c1-20)..."
log_info "Plugin: ${PLUGIN_DIR}"
echo ""

# =============================================================================
# STEP 2: Tunggu InfluxDB API siap (health check dengan retry + backoff)
# =============================================================================
wait_for_influxdb() {
  local elapsed=0
  log_info "Menunggu InfluxDB API siap di ${INFLUX_HOST}/health ..."

  while true; do
    # Coba hit /health endpoint dengan timeout 3 detik
    local http_code
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
      --max-time 3 \
      "${INFLUX_HOST}/health" 2>/dev/null || echo "000")

    if [ "${http_code}" = "200" ]; then
      log_success "InfluxDB API siap! (${elapsed}s)"
      return 0
    fi

    if [ "${elapsed}" -ge "${MAX_WAIT_SECONDS}" ]; then
      log_error "InfluxDB tidak siap setelah ${MAX_WAIT_SECONDS} detik (HTTP ${http_code}). Abort."
      exit 1
    fi

    log_warn "  API belum siap (HTTP ${http_code}), retry dalam ${RETRY_INTERVAL}s... (${elapsed}/${MAX_WAIT_SECONDS}s)"
    sleep "${RETRY_INTERVAL}"
    elapsed=$((elapsed + RETRY_INTERVAL))
  done
}

wait_for_influxdb

# =============================================================================
# STEP 3: Fungsi upsert_trigger (delete → create → verify)
#
# Parameter:
#   $1  TRIG_NAME    : nama trigger (unik dalam 1 database)
#   $2  TRIG_DB      : database tempat trigger dipasang (bukan source db!)
#   $3  TRIG_SPEC    : jadwal trigger, contoh: "every:1m"
#   $4  PLUGIN_FILE  : nama file .py di PLUGIN_DIR
#   $5  TRIG_ARGS    : (opsional) trigger-arguments string
#
# Return: 0 jika sukses, 1 jika gagal
# =============================================================================
INSTALL_ERRORS=0  # counter untuk tracking error keseluruhan

upsert_trigger() {
  local trig_name="$1"
  local trig_db="$2"
  local trig_spec="$3"
  local plugin_file="$4"
  local trig_args="${5:-}"  # opsional

  echo ""
  echo "───────────────────────────────────────────────────────────"
  log_info "Upsert trigger: ${trig_name}"
  log_info "  Database   : ${trig_db}"
  log_info "  Schedule   : ${trig_spec}"
  log_info "  Plugin     : ${plugin_file}"
  [ -n "${trig_args}" ] && log_info "  Arguments  : ${trig_args}"

  # ── Step 3a: Delete trigger lama (idempoten — error diabaikan) ─────────
  local del_out
  del_out=$(influxdb3 delete trigger \
    --host "${INFLUX_HOST}" \
    --token "${TOKEN}" \
    --database "${trig_db}" \
    "${trig_name}" 2>&1 || true)

  if echo "${del_out}" | grep -qi "success\|deleted\|removed"; then
    log_success "  [delete] Trigger '${trig_name}' dihapus (update mode)"
  else
    log_info    "  [delete] Trigger '${trig_name}' belum ada (fresh install mode)"
  fi

  # ── Step 3b: Create trigger baru ─────────────────────────────────────
  local create_cmd=(
    influxdb3 create trigger
    --host "${INFLUX_HOST}"
    --token "${TOKEN}"
    --trigger-spec "${trig_spec}"
    --plugin-filename "${plugin_file}"
    --database "${trig_db}"
  )

  # Tambah trigger-arguments jika ada
  if [ -n "${trig_args}" ]; then
    create_cmd+=(--trigger-arguments "${trig_args}")
  fi

  create_cmd+=("${trig_name}")

  local create_out create_code
  create_out=$("${create_cmd[@]}" 2>&1)
  create_code=$?

  if [ "${create_code}" -eq 0 ]; then
    log_success "  [create] ✓ Trigger '${trig_name}' berhasil dipasang"
  else
    log_error   "  [create] ✗ GAGAL memasang '${trig_name}': ${create_out}"
    INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
    return 1
  fi

  return 0
}

# =============================================================================
# STEP 4: Daftar plugin yang akan di-install
# Tambah atau hapus baris upsert_trigger di bawah sesuai kebutuhan.
#
# FORMAT:
#   upsert_trigger \
#     "<nama_trigger>" \
#     "<database_target>" \
#     "<schedule>" \
#     "<nama_file.py>" \
#     "<trigger_args_opsional>"
# =============================================================================

log_info "Mulai instalasi plugin triggers..."

# ── Plugin 1: RAW (10s) → MINUTES (1m) ─────────────────────────────────────
# Trigger dipasang di energy_minutes (database TARGET), bukan energy_monitoring.
# Karena write() hanya bisa menulis ke database tempat trigger berjalan.
upsert_trigger \
  "raw_to_minutes" \
  "energy_minutes" \
  "every:1m" \
  "downsampler_raw_to_minutes.py" \
  "source_db=energy_monitoring,source_measurement=energy_raw,target_measurement=energy_minute,lookback_minutes=2"

# ── Plugin 2: MINUTES (1m) → HOURLY (1h) ───────────────────────────────────
upsert_trigger \
  "minutes_to_hourly" \
  "energy_hour" \
  "every:1m" \
  "downsampler_minutes_to_hourly.py" \
  "source_db=energy_minutes,source_measurement=energy_minute,target_measurement=energy_hour,lookback_minutes=5"

# =============================================================================
# STEP 5: Verifikasi via HTTP API
# Tampilkan daftar trigger yang aktif untuk konfirmasi visual
# =============================================================================
echo ""
echo "───────────────────────────────────────────────────────────"
log_info "Verifikasi trigger yang terpasang..."

for db in energy_minutes energy_hour; do
  log_info "  Database: ${db}"
  curl -sf \
    -H "Authorization: Bearer ${TOKEN}" \
    "${INFLUX_HOST}/api/v3/configure/trigger?db=${db}" \
    2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    triggers = data if isinstance(data, list) else data.get('triggers', [])
    for t in triggers:
        print(f'    ✓ {t.get(\"trigger_name\", \"?\")} [{t.get(\"trigger_specification\", \"?\")}]')
    if not triggers:
        print('    (belum ada trigger)')
except Exception as e:
    print(f'    (tidak bisa parse response: {e})')
" || log_warn "  Endpoint verifikasi tidak tersedia (${db})"
done

# =============================================================================
# STEP 6: Summary & Exit Code
# =============================================================================
echo ""
echo "═══════════════════════════════════════════════════════════"
if [ "${INSTALL_ERRORS}" -eq 0 ]; then
  log_success "Semua plugin berhasil dipasang! 🎉"
  echo "═══════════════════════════════════════════════════════════"
  exit 0
else
  log_error "${INSTALL_ERRORS} plugin gagal dipasang. Cek log di atas."
  echo "═══════════════════════════════════════════════════════════"
  exit 1
fi
