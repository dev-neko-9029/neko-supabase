#!/usr/bin/env bash
# Pruebas de migrate.sh con un producto de ejemplo en una carpeta temporal.
# Uso: migrate/tests/test-migrate.sh   (requiere Postgres vacío y variables PG*)
set -uo pipefail
cd "$(dirname "$0")"
migrate="$(cd .. && pwd)/migrate.sh"

db="neko_migrate_test_$$"
work="$(mktemp -d)"
createdb "$db" || exit 1
trap 'dropdb --if-exists "$db"; rm -rf "$work"' EXIT
export PGDATABASE="$db" PROJECTS_DIR="$work"

failures=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FALLA %s\n' "$1"; failures=$((failures + 1)); }
q() { psql -XAtc "$1"; }
run_migrate() { bash "$migrate" > "$work.out" 2>&1; }
expect_success() { if run_migrate; then pass "$1"; else fail "$1"; cat "$work.out"; fi; }
expect_failure() {
  if run_migrate; then fail "$1 (terminó bien)"; cat "$work.out";
  elif grep -q "$2" "$work.out"; then pass "$1";
  else fail "$1 (sin $2)"; cat "$work.out"; fi
}
expect_value() { local got; got="$(q "$2")"; if [[ "$got" == "$3" ]]; then pass "$1"; else fail "$1: esperado '$3', hubo '$got'"; fi; }

psql -Xqc "do \$\$ begin if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if; end \$\$;"

mkdir -p "$work/demo/migrations" "$work/demo/seeds" "$work/_shared"
cat > "$work/demo/migrations/001_demo_init.sql" <<'SQL'
create schema demo;
create table demo.items (id int primary key, name text not null);
SQL
cat > "$work/demo/migrations/002_demo_bad.sql" <<'SQL'
create table demo.half_done (id int);
select 1 / 0;
SQL

expect_failure "migración con error detiene el deploy" "la ejecución se detuvo"
expect_value "la migración anterior al error queda aplicada" "select count(*) from neko_ops.applied where name = '001_demo_init.sql'" "1"
expect_value "la migración que falló no deja tablas" "select to_regclass('demo.half_done') is null" "t"
expect_value "la migración que falló no queda registrada" "select count(*) from neko_ops.applied where name = '002_demo_bad.sql'" "0"

printf 'create table demo.half_done (id int);\n' > "$work/demo/migrations/002_demo_bad.sql"
expect_success "migración corregida se aplica"
expect_value "tabla de la migración corregida existe" "select to_regclass('demo.half_done') is not null" "t"
expect_success "deploy sin cambios termina bien"
grep -q "resumen: 0 migraciones y 0 seeds" "$work.out" && pass "deploy sin cambios no aplica nada" || fail "deploy sin cambios no aplica nada"

printf 'create table demo.later (id int);\n' > "$work/demo/migrations/003_demo_later.sql"
printf '\n-- editada\n' >> "$work/demo/migrations/001_demo_init.sql"
expect_failure "migración aplicada editada detiene el deploy" "MIGRATION_MODIFIED: demo/001_demo_init.sql"
expect_value "con una migración editada no se aplica ninguna pendiente" "select to_regclass('demo.later') is null" "t"
printf 'create schema demo;\ncreate table demo.items (id int primary key, name text not null);\n' > "$work/demo/migrations/001_demo_init.sql"
expect_success "al revertir la edición el deploy sigue"
expect_value "la migración pendiente se aplica después" "select to_regclass('demo.later') is not null" "t"

printf 'select 1;\n' > "$work/demo/migrations/4_demo_bad_name.sql"
expect_failure "nombre de migración inválido" "INVALID_FILE_NAME"
rm "$work/demo/migrations/4_demo_bad_name.sql"
printf 'select 1;\n' > "$work/demo/migrations/004_other_prefix.sql"
expect_failure "migración sin el slug del producto" "INVALID_FILE_NAME"
rm "$work/demo/migrations/004_other_prefix.sql"
printf 'begin;\ncreate table demo.x (id int);\ncommit;\n' > "$work/demo/migrations/004_demo_tx.sql"
expect_failure "migración con begin y commit" "INVALID_TRANSACTION_CONTROL"
rm "$work/demo/migrations/004_demo_tx.sql"
mkdir "$work/Demo2"
expect_failure "nombre de producto inválido" "INVALID_PRODUCT_NAME"
rmdir "$work/Demo2"

cat > "$work/demo/seeds/100_items.sql" <<'SQL'
insert into demo.items (id, name)
select (e ->> 'id')::int, e ->> 'name' from jsonb_array_elements(:'data'::jsonb) e
on conflict (id) do update set name = excluded.name;
SQL
printf '[{"id": 1, "name": "Uno"}]\n' > "$work/demo/seeds/100_items.json"
printf 'insert into demo.items values (99, $$sin json$$) on conflict do nothing;\n' > "$work/demo/seeds/200_plain.sql"
expect_success "seeds nuevos se aplican"
expect_value "seed con JSON cargó datos" "select name from demo.items where id = 1" "Uno"
expect_value "seed sin JSON cargó datos" "select name from demo.items where id = 99" "sin json"
checksum_before="$(q "select checksum from neko_ops.applied where name = '100_items'")"
expect_success "seeds sin cambios"
grep -q "sin cambios seed demo/100_items" "$work.out" && pass "seed sin cambios no se reaplica" || fail "seed sin cambios no se reaplica"

printf '[{"id": 1, "name": "Uno editado"}, {"id": 2, "name": "Dos"}]\n' > "$work/demo/seeds/100_items.json"
expect_success "seed con JSON cambiado"
expect_value "seed cambiado se reaplica" "select string_agg(name, ',' order by id) from demo.items where id < 10" "Uno editado,Dos"
expect_value "checksum del seed se actualiza" "select checksum <> '$checksum_before' from neko_ops.applied where name = '100_items'" "t"

checksum_good="$(q "select checksum from neko_ops.applied where name = '100_items'")"
printf '[{"id": 3, "name": null}]\n' > "$work/demo/seeds/100_items.json"
expect_failure "seed que viola una restricción detiene el deploy" "la ejecución se detuvo"
expect_value "seed fallido no deja datos" "select count(*) from demo.items where id = 3" "0"
expect_value "seed fallido conserva el checksum anterior" "select checksum = '$checksum_good' from neko_ops.applied where name = '100_items'" "t"
printf '[{"id": 1, "name": "Uno editado"}, {"id": 2, "name": "Dos"}]\n' > "$work/demo/seeds/100_items.json"

printf '[]\n' > "$work/demo/seeds/300_orphan.json"
expect_failure "JSON sin su SQL" "SEED_WITHOUT_SQL"
rm "$work/demo/seeds/300_orphan.json"
printf '# notas\n' > "$work/demo/seeds/README.md"
expect_success "README dentro de seeds se ignora"

MIGRATE_SKIP_SEEDS=1 run_migrate
grep -q "seeds: omitidos" "$work.out" && pass "MIGRATE_SKIP_SEEDS omite seeds" || fail "MIGRATE_SKIP_SEEDS omite seeds"

printf 'select pg_sleep(1);\ncreate table demo.concurrent (id int);\n' > "$work/demo/migrations/005_demo_concurrent.sql"
bash "$migrate" > "$work.a" 2>&1 & pid_a=$!
bash "$migrate" > "$work.b" 2>&1 & pid_b=$!
wait "$pid_a"; status_a=$?
wait "$pid_b"; status_b=$?
if [[ $status_a -eq 0 && $status_b -eq 0 ]]; then pass "dos ejecuciones simultáneas terminan bien"; else fail "dos ejecuciones simultáneas terminan bien"; cat "$work.a" "$work.b"; fi
expect_value "la migración concurrente se aplicó una sola vez" "select count(*) from neko_ops.applied where name = '005_demo_concurrent.sql'" "1"

expect_value "anon no puede usar neko_ops" "select has_schema_privilege('anon', 'neko_ops', 'usage')" "f"

rm -f "$work.out" "$work.a" "$work.b"
if [[ $failures -gt 0 ]]; then
  echo "$failures pruebas de migrate.sh fallaron"
  exit 1
fi
echo "OK: pruebas de migrate.sh"
