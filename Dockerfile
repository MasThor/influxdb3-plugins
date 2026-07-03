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

# Temporarily switch to root user to perform administrative operations (mkdir, copy, chmod, chown)
USER root

# Label metadata image (best practice OCI)
LABEL maintainer="thaariqprs97@gmail.com" \
      version="1.0.0" \
      description="InfluxDB 3 Core with baked-in processing engine plugins" \
      org.opencontainers.image.source="https://github.com/MasThor/influxdb3-plugins"

# =============================================================================
# =============================================================================
# PLUGIN DIRECTORY
# Path standar InfluxDB 3 Processing Engine untuk plugin files.
# Menggunakan /plugins (di luar /var/lib/influxdb3) agar tidak ter-masking
# oleh volume data database.
# =============================================================================
ENV PLUGIN_DIR=/plugins
ENV INFLUXDB3_PLUGIN_DIR=/plugins

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
# InfluxDB 3 Core runs as user 'influxdb3' (uid 1500) inside the image.
# Ensure all plugin files and scripts are owned by this user.
# =============================================================================
RUN chown -R 1500:1500 ${PLUGIN_DIR} /opt/influxdb-init/

# =============================================================================
# PORT & VOLUME
# Port 8181: HTTP API + gRPC InfluxDB 3
# Volume /var/lib/influxdb3: Data persistence (REQUIRED to be mounted from host
# so data is persistent across image rebuilds or container restarts)
# =============================================================================
EXPOSE 8181

VOLUME ["/var/lib/influxdb3"]

# =============================================================================
# USER
# Switch back to the non-root user 'influxdb3' (uid 1500) from the base image.
# This is crucial for production security to avoid running processes as root.
# =============================================================================
USER 1500

# Gunakan entrypoint default dari base image (influxdb3 serve)
# Tidak di-override agar tetap kompatibel dengan semua ENV variable standard InfluxDB 3
