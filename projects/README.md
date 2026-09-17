# Productos en neko-supabase

Cada producto tiene su schema y su carpeta `projects/<slug>/`. Sus
migraciones y seeds se aplican solos en cada deploy de `neko-supabase`.

Estándares:

- Alta de producto: `neko-docs/docs/specs/neko-estandar-alta-producto.md`.
- Migraciones y seeds: [`docs/specs/neko-estandar-migraciones.md`](../docs/specs/neko-estandar-migraciones.md).

## Registro

| Slug | Schema | Buckets       | Dominio              | Estado |
|------|--------|---------------|----------------------|--------|
| food | `food` | `food-assets` | `food.nekomotsu.com` | activo |

Los schemas expuestos por la API se declaran en `docker-compose.yml`, en
`x-pgrst-db-schemas`, en el mismo orden de esta tabla:

```yaml
x-pgrst-db-schemas: &pgrst-db-schemas public,graphql_public,food
```

## Estructura

```
projects/
├─ run-tests.sh              # pruebas: ./run-tests.sh [slug]
├─ _shared/tests/            # sustitutos de Supabase y funciones de aserción
└─ <slug>/
   ├─ README.md
   ├─ migrations/NNN_<slug>_<descripción>.sql   # sin begin ni commit
   ├─ seeds/NNN_<descripción>.sql               # idempotente
   ├─ seeds/NNN_<descripción>.json              # opcional; llega como :'data'
   ├─ tools/                                    # apoyo local, no corre en el deploy
   └─ tests/*.test.sql
```

## Flujo de trabajo

No se ejecuta nada en la VM 200. Todo cambio pasa por el repositorio.

1. Escribir la migración o editar el seed.
2. Correr las pruebas en local (sección siguiente). Hoy no hay CI: esta es la
   única barrera antes de producción.
3. Commit y push.
4. En Dokploy, **Deploy** de `neko-supabase`.
5. Revisar el log del servicio `db-migrate`:

```
[migrate] base db:5432/postgres como postgres; productos: food; migraciones: 3; seeds: 3
[migrate] aplicada migración food/001_food_init.sql
[migrate] sin cambios seed food/100_el_corralito
[migrate] resumen: 1 migraciones y 0 seeds aplicados en esta ejecución
[migrate] listo
```

Si `db-migrate` falla, el deploy queda en error, la base de datos queda como
estaba antes del archivo que falló y `rest` no arranca hasta un deploy
correcto. Se corrige el archivo (o se agrega una migración nueva si la que
falló ya estaba aplicada) y se vuelve a desplegar.

Qué quedó aplicado, y cuándo:

```sql
select product, kind, name, applied_at
from neko_ops.applied
order by applied_at desc;
```

### Reglas cortas

- Una migración aplicada no se edita: el deploy falla con
  `MIGRATION_MODIFIED`. Los cambios van en una migración nueva.
- Una migración no lleva `begin`, `commit` ni `rollback`: la transacción la
  pone `migrate.sh`.
- Un seed se reaplica cada vez que cambia su `.sql` o su `.json`. Debe dar el
  mismo resultado si se aplica dos veces.
- Los datos que vienen de seeds se editan en el repositorio. Studio es sólo
  para urgencias, y lo que se corrija ahí se copia al JSON el mismo día; si
  no, el próximo cambio del seed lo sobrescribe.
- Borrar un seed no borra sus datos.

### Errores de `db-migrate`

| Error                          | Qué hacer |
|--------------------------------|-----------|
| `MIGRATION_MODIFIED`           | Revertir la edición y poner el cambio en una migración nueva. |
| `INVALID_FILE_NAME`            | Renombrar: `NNN_<slug>_<descripción>.sql` en migraciones, `NNN_<descripción>.sql` o `.json` en seeds; minúsculas, dígitos y `_`. |
| `INVALID_TRANSACTION_CONTROL`  | Quitar `begin`, `commit` o `rollback` de la migración. |
| `INVALID_PRODUCT_NAME`         | Carpetas de producto en minúsculas y dígitos. Las carpetas comunes empiezan con `_`. |
| `SEED_WITHOUT_SQL`             | Crear el `.sql` con el mismo nombre del `.json`. |
| Error de SQL o de un producto  | El log muestra el archivo y el mensaje; corregir y volver a desplegar. |

## Pruebas

Requieren Postgres 17 vacío (la versión de producción) y las variables `PG*`:

```bash
docker run --rm -d --name neko-pg -e POSTGRES_PASSWORD=test -p 55432:5432 postgres:17
export PGHOST=localhost PGPORT=55432 PGUSER=postgres PGPASSWORD=test

./projects/run-tests.sh food          # un producto
./projects/run-tests.sh               # todos
./migrate/tests/test-migrate.sh       # sólo si se tocó migrate.sh

docker stop neko-pg
```

`run-tests.sh` aplica las migraciones con el mismo `migrate.sh` del deploy,
corre las pruebas del producto, aplica los seeds y verifica que una segunda
ejecución no cambie nada.

## Dar de alta un producto

1. Crear `projects/<slug>/` con `migrations/001_<slug>_init.sql` según el
   estándar de alta (2.4) y sus pruebas.
2. Agregar el schema al final de `x-pgrst-db-schemas` en `docker-compose.yml`
   y una fila al registro de arriba.
3. Pruebas, push y deploy.

## Permisos del usuario que migra

`db-migrate` usa `postgres`. Si una migración necesita superusuario (por
ejemplo, crear políticas sobre `storage.objects`) y falla por permisos, se
agrega `MIGRATE_DB_USER=supabase_admin` al entorno de `neko-supabase` en
Dokploy y se vuelve a desplegar. La migración que falló no dejó cambios.
