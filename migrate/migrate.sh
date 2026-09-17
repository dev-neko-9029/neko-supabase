#!/usr/bin/env bash
# Aplica las migraciones y los seeds pendientes de todos los productos.
# Estándar: docs/specs/neko-estandar-migraciones.md
#
# Lo ejecuta el servicio db-migrate en cada deploy y run-tests.sh en local.
# Conexión por variables PG* (PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD).
#
# Variables propias:
#   PROJECTS_DIR        carpeta de productos (por defecto /projects)
#   MIGRATE_SKIP_SEEDS  1 para aplicar sólo migraciones (sólo pruebas)
set -euo pipefail

PROJECTS_DIR="${PROJECTS_DIR:-/projects}"
SKIP_SEEDS="${MIGRATE_SKIP_SEEDS:-0}"

# Clave fija del bloqueo que impide dos ejecuciones simultáneas.
LOCK_KEY=727170

PRODUCT_RE='^[a-z][a-z0-9]*$'
MIGRATION_RE='^[0-9]{3}_[a-z0-9_]+\.sql$'
SEED_RE='^[0-9]{3}_[a-z0-9_]+\.(sql|json)$'

log() { printf '[migrate] %s\n' "$*"; }
fail() {
  log "ERROR $*"
  exit 1
}

sha() { cat "$@" | sha256sum | cut -d' ' -f1; }

sql_literal() { printf "'%s'" "${1//\'/\'\'}"; }

[[ -d "$PROJECTS_DIR" ]] || fail "no existe $PROJECTS_DIR"

products=()
while IFS= read -r dir; do
  name="$(basename "$dir")"
  # Carpetas con prefijo "_" son comunes (pruebas), no productos.
  [[ "$name" == _* ]] && continue
  [[ "$name" =~ $PRODUCT_RE ]] || fail "INVALID_PRODUCT_NAME: $name"
  products+=("$name")
done < <(find "$PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)

script="$(mktemp)"
trap 'rm -f "$script"' EXIT

migration_count=0
seed_count=0

{
  cat <<'SQL'
\set ON_ERROR_STOP on
-- Los resultados de consultas no van al log; los mensajes usan \echo.
\o /dev/null
set client_min_messages = warning;
SQL
  echo "select pg_advisory_lock($LOCK_KEY) \\gset"
  cat <<'SQL'
select clock_timestamp() as run_started \gset

create schema if not exists neko_ops;
create table if not exists neko_ops.applied (
  product    text        not null,
  kind       text        not null check (kind in ('migration', 'seed')),
  name       text        not null,
  checksum   text        not null,
  applied_at timestamptz not null default now(),
  primary key (product, kind, name)
);
revoke all on schema neko_ops from public;
revoke all on all tables in schema neko_ops from public;

create temp table migration_files (product text, name text, checksum text);
SQL
} > "$script"

# --- Validación de nombres y lista de migraciones con su checksum ----------
migration_blocks=""
for product in "${products[@]}"; do
  dir="$PROJECTS_DIR/$product/migrations"
  [[ -d "$dir" ]] || continue
  while IFS= read -r file; do
    name="$(basename "$file")"
    [[ "$name" =~ $MIGRATION_RE ]] || fail "INVALID_FILE_NAME: $product/migrations/$name"
    [[ "$name" == [0-9][0-9][0-9]_"${product}"_* ]] \
      || fail "INVALID_FILE_NAME: $product/migrations/$name debe empezar por NNN_${product}_"
    # La transacción la pone este script; una migración con su propio
    # commit rompería el registro atómico en neko_ops.applied.
    if grep -Eiq '^[[:space:]]*(begin|commit|rollback|start[[:space:]]+transaction)[[:space:]]*;' "$file"; then
      fail "INVALID_TRANSACTION_CONTROL: $product/migrations/$name no debe llevar begin, commit ni rollback"
    fi
    sum="$(sha "$file")"
    echo "insert into migration_files values ($(sql_literal "$product"), $(sql_literal "$name"), '$sum');" >> "$script"
    migration_count=$((migration_count + 1))
    migration_blocks+="$(cat <<SQL
select not exists (
  select 1 from neko_ops.applied
  where product = $(sql_literal "$product") and kind = 'migration' and name = $(sql_literal "$name")
) as pending \gset
\if :pending
begin;
\i $file
insert into neko_ops.applied (product, kind, name, checksum)
values ($(sql_literal "$product"), 'migration', $(sql_literal "$name"), '$sum');
commit;
\echo [migrate] aplicada migración $product/$name
\else
\echo [migrate] sin cambios migración $product/$name
\endif
SQL
)"$'\n'
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f | LC_ALL=C sort)
done

# --- Una migración aplicada no se edita ------------------------------------
cat >> "$script" <<'SQL'
do $$
declare
  v_modified text;
begin
  select string_agg(a.product || '/' || a.name, ', ' order by a.product, a.name)
  into v_modified
  from neko_ops.applied a
  join migration_files f using (product, name)
  where a.kind = 'migration' and a.checksum <> f.checksum;

  if v_modified is not null then
    raise exception 'MIGRATION_MODIFIED: %. Los cambios van en una migración nueva.', v_modified;
  end if;
end;
$$;
SQL

printf '%s' "$migration_blocks" >> "$script"

# --- Seeds -----------------------------------------------------------------
if [[ "$SKIP_SEEDS" != "1" ]]; then
  for product in "${products[@]}"; do
    dir="$PROJECTS_DIR/$product/seeds"
    [[ -d "$dir" ]] || continue
    while IFS= read -r file; do
      name="$(basename "$file")"
      [[ "$name" == *.md ]] && continue
      [[ "$name" =~ $SEED_RE ]] || fail "INVALID_FILE_NAME: $product/seeds/$name"
      base="${name%.*}"
      if [[ "$name" == *.json ]]; then
        [[ -f "$dir/$base.sql" ]] || fail "SEED_WITHOUT_SQL: $product/seeds/$name no tiene $base.sql"
        continue
      fi
      json="$dir/$base.json"
      if [[ -f "$json" ]]; then
        sum="$(sha "$file" "$json")"
        # psql lee el archivo con cat; las rutas ya pasaron la validación de nombre.
        load_data="\\set data \`cat $json\`"
      else
        sum="$(sha "$file")"
        load_data="\\unset data"
      fi
      seed_count=$((seed_count + 1))
      cat >> "$script" <<SQL
select not exists (
  select 1 from neko_ops.applied
  where product = $(sql_literal "$product") and kind = 'seed'
    and name = $(sql_literal "$base") and checksum = '$sum'
) as pending \gset
\if :pending
$load_data
begin;
\i $file
insert into neko_ops.applied (product, kind, name, checksum)
values ($(sql_literal "$product"), 'seed', $(sql_literal "$base"), '$sum')
on conflict (product, kind, name)
do update set checksum = excluded.checksum, applied_at = now();
commit;
\echo [migrate] aplicado seed $product/$base
\else
\echo [migrate] sin cambios seed $product/$base
\endif
SQL
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f | LC_ALL=C sort)
  done
fi

# --- Cierre ----------------------------------------------------------------
cat >> "$script" <<'SQL'
-- PostgREST recarga el esquema sin reiniciarse.
notify pgrst, 'reload schema';

select
  count(*) filter (where kind = 'migration') as applied_migrations,
  count(*) filter (where kind = 'seed') as applied_seeds
from neko_ops.applied
where applied_at >= :'run_started'::timestamptz
\gset
\echo [migrate] resumen: :applied_migrations migraciones y :applied_seeds seeds aplicados en esta ejecución
SQL

seed_note="$seed_count"
[[ "$SKIP_SEEDS" == "1" ]] && seed_note="omitidos"
log "base ${PGHOST:-local}:${PGPORT:-5432}/${PGDATABASE:-} como ${PGUSER:-}; productos: ${products[*]:-ninguno}; migraciones: $migration_count; seeds: $seed_note"

if ! psql -X --no-psqlrc -q -f "$script"; then
  fail "la ejecución se detuvo. Lo aplicado antes del error quedó registrado; el archivo que falló no dejó cambios."
fi
log "listo"
