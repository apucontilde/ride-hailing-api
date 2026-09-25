#!/bin/sh
set -e

# Creates PostGIS + pgRouting extensions. Runs from docker-entrypoint-initdb.d
# on FIRST boot of an empty volume, but is written to be idempotent so it can
# also be re-run by hand against a live DB (it needs the container's
# POSTGRES_USER/POSTGRES_DB env, so run it as a SCRIPT, not via psql -f):
#
#   docker exec -i ride-hailing-db sh -s < scripts/init-pgrouting.sh
#
# (the bind-mounted path is read-only, so re-runs pipe the file through sh;
# inside the container it lives at /docker-entrypoint-initdb.d/init-pgrouting.sh)
#
# Every extension is guarded: if the image does not package the extension's
# control file (e.g. fuzzystrmatch comes from postgresql-contrib on Debian),
# we skip it instead of aborting init. Order matters: postgis before
# pgrouting (pgrouting depends on it).

# The Debian image keeps a stray postgresql.conf.sample.dpkg file next to the
# numbered PG version dir, so filter to numeric dir names only.
PG_VER=$(ls /usr/share/postgresql/ | grep -E '^[0-9]+$' | sort -V | tail -n1)
EXT_DIR="/usr/share/postgresql/${PG_VER}/extension"

for ext in postgis postgis_raster postgis_topology fuzzystrmatch pgrouting; do
  if [ -f "${EXT_DIR}/${ext}.control" ]; then
    echo "==> creating extension: ${ext}"
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
      -c "CREATE EXTENSION IF NOT EXISTS ${ext};"
  else
    echo "==> skip extension (no ${ext}.control in ${EXT_DIR}): ${ext}"
  fi
done