# =============================================================================
# Dockerfile — Custom InfluxDB 3 Core (Production-Ready)
# Base  : influxdb:3.10-core
# Role  : Bake plugin Python files ke dalam image agar image portable &
#         siap di-deploy tanpa perlu mount volume plugin dari host.
#
# Build : docker build -t influxdb3-custom:latest .
# =============================================================================

# ── Stage 1: Base Image ──────────────────────────────────────────────────────
FROM influxdb:3.10-core

# Label metadata image (best practice OCI)
LABEL maintainer="devops@company.com" \
      version="1.0.0" \
      description="InfluxDB 3 Core with baked-in processing engine plugins" \
      org.opencontainers.image.source="https://github.com/your-org/influxdb3-plugins"

# =============================================================================
# PLUGIN DIRECTORY
# Path standar InfluxDB 3 Processing Engine untuk plugin files.
# Semua file .py di sini akan otomatis tersedia untuk 'influxdb3 create trigger
# --plugin-filename <name>.py' tanpa perlu path absolut.
# =============================================================================
ENV PLUGIN_DIR=/var/lib/influxdb3/plugins

# Buat direktori plugin (mkdir -p agar idempoten)
RUN mkdir -p ${PLUGIN_DIR}

# Copy semua plugin Python ke dalam image
# Layer ini di-cache selama file plugin tidak berubah → build lebih cepat
COPY plugins/ ${PLUGIN_DIR}/

# =============================================================================
# INIT SCRIPTS
# Script untuk auto-register trigger setelah InfluxDB boot.
# Diletakkan di /docker-entrypoint-initdb.d/ agar mudah ditemukan,
# namun eksekusi sebenarnya dilakukan oleh service sidecar (influxdb-init).
# =============================================================================
COPY init/ /opt/influxdb-init/

# Berikan permission eksekusi pada semua script di init/
RUN chmod +x /opt/influxdb-init/*.sh

# =============================================================================
# PERMISSION & FILE OWNERSHIP
# InfluxDB 3 Core berjalan sebagai user 'influxdb' (uid 1000) di dalam image.
# Pastikan semua file plugin dan script dapat dibaca oleh user tersebut.
# =============================================================================
RUN chown -R influxdb:influxdb ${PLUGIN_DIR} /opt/influxdb-init/

# =============================================================================
# PORT & VOLUME
# Port 8181: HTTP API + gRPC InfluxDB 3
# Volume /var/lib/influxdb3: Data persistence (WAJIB di-mount dari host agar
# data tidak hilang saat image di-rebuild atau container di-restart)
# =============================================================================
EXPOSE 8181

VOLUME ["/var/lib/influxdb3"]

# =============================================================================
# USER
# Switch ke non-root user 'influxdb' yang sudah ada di base image.
# Ini penting untuk keamanan production — hindari menjalankan proses sebagai root.
# =============================================================================
USER influxdb

# Gunakan entrypoint default dari base image (influxdb3 serve)
# Tidak di-override agar tetap kompatibel dengan semua ENV variable standard InfluxDB 3
