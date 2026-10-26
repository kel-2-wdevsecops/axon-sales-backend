#!/bin/bash
# Dijalankan entrypoint image MariaDB sekali, saat volume data masih kosong,
# setelah 10-classicmodels.sql (disalin operator dari test/fixtures, lihat
# staging/README.md). User aplikasi hanya punya hak SELECT, sama dengan
# produksi. APP_DB_PASSWORD harus heksadesimal (openssl rand -hex 24), jadi
# aman disisipkan ke SQL tanpa escape.
set -euo pipefail

if [[ ! $APP_DB_PASSWORD =~ ^[0-9a-f]{16,}$ ]]; then
  echo "APP_DB_PASSWORD harus heksadesimal minimal 16 karakter (openssl rand -hex 24)." >&2
  exit 1
fi

mariadb --protocol=socket -uroot -p"$MARIADB_ROOT_PASSWORD" <<SQL
CREATE USER 'classicmodels_app'@'%' IDENTIFIED BY '${APP_DB_PASSWORD}';
GRANT SELECT ON classicmodels.* TO 'classicmodels_app'@'%';
SQL
