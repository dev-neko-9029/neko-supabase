# Estándar de migraciones y seeds en el deploy de neko-supabase

| Campo           | Valor                                                     |
|-----------------|-----------------------------------------------------------|
| Fecha           | 2026-09-16                                                |
| Estado          | aprobado                                                  |
| Versión         | 0.2                                                       |
| Repositorio     | `neko-supabase`                                           |
| Relacionado     | Estándar de alta de producto v0.2 (secciones 2.4 y E7)    |
| Fases cubiertas | 1. Requerimiento, 2. Spec, 3. Plan técnico (resumen)      |
| Primer consumidor | food (`projects/food/`)                                 |
| Guía de uso     | `projects/README.md`                                      |

## Historial

| Versión | Fecha      | Cambio |
|---------|------------|--------|
| 0.1     | 2026-09-16 | Borrador con tres alternativas. |
| 0.2     | 2026-09-16 | Aprobado. Decisiones D1 a D3 (sección 5). Ajustes al implementar: `PGRST_DB_SCHEMAS` con un ancla YAML compartida por `rest` y Studio, pruebas del propio `migrate.sh`, rangos de numeración de seeds por producto. |

---

## 1. Requerimiento

### 1.1 Problema

Hoy aplicar una migración o cargar datos exige entrar a la VM 200 y correr
`psql` a mano. Eso trae tres problemas:

- No queda registro de qué se aplicó, cuándo ni desde qué commit.
- Un paso olvidado deja la base de datos distinta del repositorio.
- El operador depende de acceso a la VM para cualquier cambio de datos.

### 1.2 Quién lo sufre

- **Operador (Nekomotsu)**: hoy aplica cada cambio a mano.
- **Agentes de IA**: generan migraciones y seeds sin un camino
  determinista para aplicarlos.

### 1.3 Criterios de aceptación

- **MA1.** Al hacer deploy de `neko-supabase` en Dokploy, se aplican solas
  las migraciones pendientes de todos los productos, sin comandos en la VM.
- **MA2.** Un deploy sin cambios no modifica la base de datos. El log dice
  que no había nada pendiente.
- **MA3.** Si una migración falla, la base de datos queda como estaba antes
  de esa migración, el deploy se marca como fallido en Dokploy y el log
  muestra el archivo y el error.
- **MA4.** Editar una migración ya aplicada hace fallar el deploy, sin tocar
  la base de datos.
- **MA5.** Un seed nuevo, o uno cuyo contenido cambió, se aplica en el
  siguiente deploy. Uno sin cambios no se vuelve a aplicar.
- **MA6.** La tabla de control permite saber qué archivo se aplicó, con qué
  contenido (checksum) y cuándo.
- **MA7.** Las pruebas locales (`run-tests.sh`) usan el mismo mecanismo que el
  deploy.

---

## 2. Spec

### 2.1 Límites duros que definen el diseño

| Límite | Consecuencia |
|--------|--------------|
| Los scripts de `/docker-entrypoint-initdb.d` sólo corren con el volumen de datos vacío. `supabase-db` ya tiene datos. | No sirven para migraciones nuevas. Hace falta un paso propio en cada deploy. |
| Dokploy clona el repositorio limpio en cada deploy. | Los archivos del repositorio se montan con bind mounts, igual que los scripts de init actuales. |
| Producción usa `supabase/postgres:17.6.1.136` y PostgREST v14.12. | Las pruebas deben correr sobre Postgres 17. Las de food se hicieron en 16: hay que repetirlas. |
| PostgREST carga el esquema al arrancar. | Después de migrar hay que pedirle que lo recargue. |

### 2.2 Estructura

```
neko-supabase/
├─ docker-compose.yml          # agrega el servicio db-migrate
├─ migrate/
│  ├─ migrate.sh               # aplica migraciones y seeds
│  └─ tests/test-migrate.sh    # pruebas del propio migrate.sh
├─ projects/
│  ├─ README.md                # registro de productos
│  ├─ run-tests.sh             # pruebas locales, usan migrate.sh
│  ├─ _shared/tests/
│  └─ <slug>/
│     ├─ migrations/NNN_<slug>_<descripción>.sql
│     ├─ seeds/NNN_<descripción>.sql
│     ├─ seeds/NNN_<descripción>.json      # opcional, datos del seed
│     ├─ seeds/README.md                   # se ignora en el deploy
│     ├─ tools/                            # scripts de apoyo, no se ejecutan en el deploy
│     └─ tests/*.test.sql
└─ docs/specs/neko-estandar-migraciones.md # este documento
```

### 2.3 Migraciones

- Una migración se aplica **una sola vez**.
- Orden: productos en orden alfabético y, dentro de cada uno, archivos en
  orden numérico. Los productos no dependen entre sí (estándar de alta 2.4),
  así que el orden entre productos no importa.
- Cada migración se aplica en su propia transacción, junto con su registro en
  la tabla de control. Por eso **el archivo no lleva `begin` ni `commit`**: el
  mecanismo los pone.
- Si el checksum de una migración aplicada cambió, el deploy falla con
  `MIGRATION_MODIFIED` antes de aplicar nada. Los cambios van en una
  migración nueva.
- Si una migración falla, se detiene todo. Las anteriores del mismo deploy
  quedan aplicadas; la que falló no deja rastro.

### 2.4 Seeds

- Un seed es un archivo `.sql` que puede tener al lado un `.json` con el
  mismo nombre. El mecanismo pasa el contenido del JSON al SQL en la
  variable `data`:

```sql
-- projects/food/seeds/010_el_corralito.sql
select food.import_restaurant(:'data'::jsonb);
```

- El seed se aplica cuando es nuevo o cuando cambia el checksum del `.sql` o
  del `.json`. Por eso **todo seed debe ser idempotente**: aplicarlo dos veces
  deja los mismos datos.
- Los seeds corren después de todas las migraciones, en orden alfabético de
  producto y numérico de archivo. Cada producto fija en su README qué rango
  de números usa para qué tipo de datos. Si un seed depende de otro, el número lo
  ordena (por ejemplo, activar estantes después de cargar el restaurante).
- Cada seed va en su propia transacción, con su registro en la tabla de
  control.
- Un seed que se borra del repositorio no deshace nada en la base de datos.
- Los archivos `.md` dentro de `seeds/` se ignoran. Cualquier otro archivo con
  nombre fuera del formato hace fallar el deploy.

**Regla de fuente de verdad (D2):** los datos que vienen de un seed se editan
en el repositorio. Studio queda sólo para urgencias. Si se edita en Studio, el
próximo cambio de ese seed lo sobrescribe, así que una corrección urgente se
copia al JSON el mismo día.

### 2.5 Tabla de control

```sql
create schema neko_ops;

create table neko_ops.applied (
  product    text        not null,
  kind       text        not null check (kind in ('migration', 'seed')),
  name       text        not null,
  checksum   text        not null,   -- sha256 del .sql, o del .sql y el .json
  applied_at timestamptz not null default now(),
  primary key (product, kind, name)
);
```

- `neko_ops` no se agrega a `PGRST_DB_SCHEMAS` y no tiene permisos para
  `anon` ni `authenticated`.
- Para un seed se guarda el último checksum aplicado y su fecha.

### 2.6 Ejecución en el deploy

Servicio nuevo en `docker-compose.yml`:

```yaml
  db-migrate:
    container_name: supabase-db-migrate
    image: supabase/postgres:17.6.1.136   # misma imagen que db: trae psql
    restart: "no"
    depends_on:
      db:
        condition: service_healthy
    volumes:
      - ./migrate:/migrate:ro,z
      - ./projects:/projects:ro,z
    environment:
      PGHOST: ${POSTGRES_HOST}
      PGPORT: ${POSTGRES_PORT}
      PGDATABASE: ${POSTGRES_DB}
      PGUSER: ${MIGRATE_DB_USER:-postgres}
      PGPASSWORD: ${POSTGRES_PASSWORD}
      PROJECTS_DIR: /projects
    entrypoint: ["bash", "/migrate/migrate.sh"]
```

Y en `rest`:

```yaml
    depends_on:
      db:
        condition: service_healthy
      db-migrate:
        condition: service_completed_successfully
```

Comportamiento de `migrate.sh`:

1. Toma un bloqueo (`pg_advisory_lock`) para que dos deploys no migren a la
   vez.
2. Crea `neko_ops` si no existe.
3. Verifica los checksums de las migraciones ya aplicadas. Si alguno cambió,
   termina con error.
4. Aplica las migraciones pendientes.
5. Aplica los seeds nuevos o cambiados.
6. Envía `NOTIFY pgrst, 'reload schema'`.
7. Escribe en el log una línea por archivo: `aplicado`, `sin cambios` o
   `error`, y un resumen final. Termina con código 0 sólo si todo salió bien.

`PGRST_DB_SCHEMAS` pasa de variable de entorno de Dokploy a un ancla YAML
(`x-pgrst-db-schemas`) en `docker-compose.yml`, que usan `rest` y Studio. Así
exponer un schema también queda en el historial del repositorio. No es un
secreto. La variable del mismo nombre en el entorno de Dokploy deja de usarse
y se borra para no confundir.

### 2.7 Pruebas locales

`projects/run-tests.sh [slug]`, sobre una base temporal:

1. Aplica los sustitutos de Supabase.
2. Ejecuta `migrate.sh` sólo con migraciones (`MIGRATE_SKIP_SEEDS=1`), para
   que las pruebas del producto trabajen sobre tablas vacías.
3. Corre las pruebas del producto, que terminan en `ROLLBACK`.
4. Ejecuta `migrate.sh` completo: aplica los seeds, con las mismas
   validaciones que en producción.
5. Ejecuta `migrate.sh` otra vez y falla si aplica algo (MA2).

`migrate/tests/test-migrate.sh` prueba el propio `migrate.sh` con un producto
de ejemplo: errores, migraciones editadas, nombres inválidos, transacciones
dentro del archivo, seeds con y sin JSON, seeds cambiados y fallidos, y dos
ejecuciones simultáneas.

`MIGRATE_SKIP_SEEDS` existe sólo para las pruebas. En el deploy los seeds
siempre corren.

### 2.8 Casos borde

| Caso | Resultado |
|------|-----------|
| Deploy sin cambios | Nada se aplica. `rest` arranca normal. |
| Migración con error de SQL | Rollback de esa migración, deploy fallido, log con archivo y error. |
| Migración aplicada editada | Deploy fallido con `MIGRATION_MODIFIED`. Nada se aplica. |
| Seed con JSON inválido o que viola una regla | Rollback de ese seed, deploy fallido. |
| Dos deploys a la vez | El segundo espera el bloqueo. |
| Base de datos caída | `db-migrate` no arranca hasta que `db` esté sano. |
| Migración aplicada a mano antes de este estándar | Hay que registrarla una vez en `neko_ops.applied` (sección 2.9); si no, se intenta aplicar de nuevo y falla. |
| Archivo con nombre fuera del formato | Deploy fallido con `INVALID_FILE_NAME`. |

### 2.9 Adopción

- food: sus migraciones **no** se han aplicado todavía, así que el primer
  deploy las aplica y no hace falta registrar nada a mano. **Si alguna se
  aplicó a mano, avisar antes del primer deploy.**
- Hecho en food:
  - Migraciones 001 a 003 sin `begin` ni `commit`.
  - `seed/` pasó a `seeds/` con rangos 100 (restaurantes), 200 (lotes de
    estantes) y 300 (estantes activos).
  - `generate-tags.mjs` y `words.txt` pasaron a `tools/`. `import.sh` se
    eliminó: su trabajo lo hace el deploy.
  - Pruebas repetidas en Postgres 17.9.

### 2.10 No-objetivos

- Deshacer migraciones. Las migraciones son de sólo avance.
- Ambiente de pruebas separado (estándar de alta, E7).
- Backup automático antes de migrar (sigue aplazado; ver sección 3).
- Cambios de datos desde el dashboard de un producto: esos no son seeds.

---

## 3. Riesgos y advertencias

| Riesgo | Tipo | Mitigación |
|--------|------|------------|
| Una migración fallida deja `rest` sin arrancar cuando Dokploy lo recrea, y eso afecta a todos los productos. | Controlable | La migración hace rollback, así que corregir y volver a desplegar lo resuelve. Se acepta porque la alternativa es que PostgREST arranque con un schema a medias. **Sin verificar**: si Dokploy detiene un `rest` que no cambió cuando `db-migrate` falla. |
| El usuario `postgres` no puede crear políticas sobre `storage.objects` en la imagen 17. | Sin medir | `MIGRATE_DB_USER` permite usar `supabase_admin`. Se verifica en el primer deploy; si falla, la migración 002 hace rollback sin daño. |
| Editar en Studio datos que vienen de un seed y perderlos en el siguiente cambio del seed. | Controlable | Regla de fuente de verdad (2.4). |
| Una migración peligrosa llega a producción sin revisión. | Controlable | Pruebas obligatorias en local antes de hacer push. Hoy nada lo impone: el deploy es con el botón de Dokploy y no hay CI (D3). No hay ambiente de pruebas (E7). |
| Sin backup fuera del nodo, una migración destructiva no tiene vuelta atrás. | Límite duro | Sigue aplazado por decisión (spec de food 2.16). Recomendado: `pg_dump` del schema afectado antes de un deploy con migraciones destructivas. |
| El script `migrate.sh` es propio y puede tener errores. | Controlable | Las pruebas locales lo usan en cada corrida (MA7). |

---

## 4. Verificación (2026-09-16)

Entorno: Postgres 17.9 local con cliente psql 16, sustitutos de Supabase.

| Punto | Resultado |
|-------|-----------|
| MA1, MA5 | `run-tests.sh food` aplica 3 migraciones y 3 seeds. |
| MA2 | La segunda ejecución aplica 0 migraciones y 0 seeds. |
| MA3 | Migración con error: el deploy falla, la anterior queda, la fallida no deja tablas ni registro. Seed con error: sin datos y con el checksum anterior. |
| MA4 | Migración aplicada editada: el deploy falla con `MIGRATION_MODIFIED` y no aplica la pendiente. |
| MA6 | `neko_ops.applied` registra nombre, checksum y fecha; `anon` no tiene acceso. |
| MA7 | `run-tests.sh` y el deploy usan el mismo `migrate.sh`. |
| Concurrencia | Dos ejecuciones simultáneas terminan bien y aplican una sola vez. |
| Pruebas de mutación | Sin bloqueo, o sin la verificación de checksum, las pruebas fallan. |
| Compose | Válido contra el esquema oficial de Compose. |
| **Sin probar** | Construcción y ejecución real en Dokploy; permisos del usuario `postgres` de la imagen 17.6.1.136 sobre `storage.objects`; qué hace Dokploy con un `rest` sin cambios cuando `db-migrate` falla; recarga de PostgREST v14 con `NOTIFY`. |

---

## 5. Decisiones registradas

- **D1.** Opción A: servicio `db-migrate` con `migrate.sh` propio (bash y
  psql), sin dependencias nuevas.
- **D2.** Los datos de seeds se editan sólo en el repositorio. Studio queda
  para urgencias.
- **D3.** El deploy de `neko-supabase` se dispara con el botón de Dokploy. No
  hay CI que corra las pruebas antes. Advertencia registrada: una migración
  sin probar puede llegar a producción; la única barrera es correr
  `run-tests.sh` antes de hacer push. Cuando exista el CI de la decisión D6 de
  `ARCHITECTURE.md`, debe correr `run-tests.sh` y `test-migrate.sh` antes de
  llamar al webhook.

---

## 6. Alternativas descartadas

| Alternativa | Motivo |
|-------------|--------|
| Scripts en `/docker-entrypoint-initdb.d` | Sólo corren con la base vacía (límite duro). |
| dbmate | No tiene seeds con reaplicación por checksum; habría que escribirlos igual. Agrega una imagen. |
| Flyway | Sí reaplica por checksum, pero no admite meta-comandos de `psql`, así que el JSON iría incrustado en SQL. Imagen Java de tamaño sin medir. |
| Supabase CLI (`db push`) | Un solo directorio de migraciones, sin varios productos, y los seeds sólo corren al reiniciar la base. |
| Que cada app migre al arrancar | Rompe la decisión E5 del estándar de alta y exige credenciales de administrador en cada app. |
