#!/usr/bin/env bash
# Importa un restaurante o un lote de etiquetas en neko-supabase.
# Uso:
#   ./import.sh restaurant el-corralito.json
#   ./import.sh tags tags/lote-001.json
# Por defecto usa psql dentro del contenedor supabase-db. Para otra conexión:
#   PSQL="psql -d mi_base" ./import.sh ...
set -euo pipefail

usage() {
  echo "Uso: ./import.sh restaurant|tags <archivo.json>" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage
kind="$1"
file="$2"

case "$kind" in
  restaurant) fn="import_restaurant" ;;
  tags) fn="import_tags" ;;
  *) usage ;;
esac

if [[ ! -f "$file" ]]; then
  echo "No existe el archivo $file" >&2
  exit 1
fi

read -r -a psql_cmd <<< "${PSQL:-docker exec -i ${SUPABASE_DB_CONTAINER:-supabase-db} psql -U postgres -d postgres}"

# psql sólo interpola variables en scripts leídos por stdin, no en -c.
printf "select food.%s(:'data'::jsonb);\n" "$fn" \
  | "${psql_cmd[@]}" -X -q -t -v ON_ERROR_STOP=1 -v data="$(cat "$file")"
