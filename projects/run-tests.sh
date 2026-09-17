#!/usr/bin/env bash
# Pruebas de base de datos de los productos.
# Estándares: alta de producto 2.4 y migraciones 2.7.
#
# Uso: ./run-tests.sh [slug]   (sin slug, prueba todos los productos)
# Requiere un Postgres 17 vacío y las variables PG* (ver README.md).
#
# Pasos, sobre una base temporal que se borra al final:
#   1. Sustitutos de Supabase.
#   2. migrate.sh sólo con migraciones de todos los productos.
#   3. Pruebas del producto (terminan en ROLLBACK).
#   4. migrate.sh completo: aplica los seeds.
#   5. migrate.sh otra vez: no debe aplicar nada.
set -euo pipefail
cd "$(dirname "$0")"
projects_dir="$(pwd)"
migrate="$projects_dir/../migrate/migrate.sh"
slug="${1:-}"

if [[ -n "$slug" && ! -d "$slug/migrations" ]]; then
  echo "No existe projects/$slug/migrations" >&2
  exit 1
fi

db="neko_test_$$"
createdb "$db"
trap 'dropdb --if-exists "$db"' EXIT
export PGDATABASE="$db"

server_version="$(psql -XAtc 'show server_version_num')"
if [[ "${server_version:0:2}" != "17" ]]; then
  echo "AVISO: el servidor es la versión ${server_version:0:2}; producción usa 17." >&2
fi

run() { psql -X -q -v ON_ERROR_STOP=1 -f "$1"; }

echo "== Sustitutos de Supabase"
run _shared/tests/supabase_stubs.sql

echo "== Migraciones"
PROJECTS_DIR="$projects_dir" MIGRATE_SKIP_SEEDS=1 bash "$migrate"

run _shared/tests/test_helpers.sql
for product_dir in */; do
  product="${product_dir%/}"
  [[ "$product" == _* ]] && continue
  [[ -n "$slug" && "$product" != "$slug" ]] && continue
  for test_file in "$product"/tests/*.test.sql; do
    [[ -f "$test_file" ]] || continue
    echo "== Pruebas $test_file"
    run "$test_file"
  done
done

echo "== Seeds"
PROJECTS_DIR="$projects_dir" bash "$migrate"

echo "== Segunda ejecución: no debe aplicar nada"
second="$(PROJECTS_DIR="$projects_dir" bash "$migrate")"
echo "$second"
if ! grep -q "resumen: 0 migraciones y 0 seeds" <<< "$second"; then
  echo "ERROR: la segunda ejecución aplicó cambios; algún seed o migración no es estable." >&2
  exit 1
fi

echo "OK: pruebas completas"
