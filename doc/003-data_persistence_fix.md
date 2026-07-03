# 003 - Perbaikan Persistensi Data InfluxDB 3 & Instalasi Plugin

## Masalah Sebelumnya
1. **Data Hilang saat Rebuild**: Secara default, InfluxDB 3 core (`influxdb:3.10-core`) menyimpan data di *memory* atau folder *home directory* bawaan *user* (`~/.influxdb`), bukan di `/var/lib/influxdb3`. Volume Docker yang kita *mount* ke `/var/lib/influxdb3` menjadi kosong (tidak terpakai). Saat container di-*rebuild*, data musnah.
2. **Plugin Gagal Terpasang**: Blok kode pembuatan *Database* (`check_and_create_database`) sempat terhapus. InfluxDB 3 menolak memasang *trigger plugin* jika database target (`energy_minutes` dan `energy_hour`) belum ada.

## Solusi & Perubahan yang Dilakukan

### 1. Memaksa InfluxDB Menggunakan File Storage
Mengubah `docker-compose.yml` untuk menambahkan argumen `command` secara eksplisit saat container start, untuk memaksa penggunaan `--object-store=file` dan `--data-dir=/var/lib/influxdb3`.

```yaml
    command:
      - influxdb3
      - serve
      - --object-store=file
      - --data-dir=/var/lib/influxdb3
```
Dengan ini, seluruh tabel dan data *time-series* InfluxDB akan diarahkan ke folder `/var/lib/influxdb3` yang sudah dilindungi oleh volume `influxdb_data`. Jika Docker Compose di-*rebuild* (`docker compose up -d --build`), InfluxDB akan memuat kembali data dari volume tersebut dan **tidak akan hilang**.

### 2. Mengembalikan Logika Pembuatan Database
Mengubah skrip `init/install_plugins.sh` untuk mengecek dan membuat *database* (jika belum ada) secara otomatis sebelum mendaftarkan *plugin triggers*.

```bash
check_and_create_database "energy_monitoring"
check_and_create_database "energy_minutes"
check_and_create_database "energy_hour"
```
Fungsi ini bersifat *idempotent*. Artinya, jika database sudah terbuat di hari sebelumnya (yang mana datanya kini tidak hilang), ia hanya akan memberi log `sudah ada` dan lanjut menginstal trigger.

## Cara Menggunakan
Cukup jalankan Docker Compose seperti biasa:
```bash
docker compose down
docker compose up -d --build
```
Log instalasi bisa dipantau via:
```bash
docker compose logs -f influxdb-init
```
