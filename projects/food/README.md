# food

Schema `food` de `neko-food-web` (`food.nekomotsu.com`). Todo se aplica en el
deploy de `neko-supabase` (ver `../README.md`).

| Carpeta o archivo                 | Contenido                                                   |
|-----------------------------------|-------------------------------------------------------------|
| `migrations/001_food_init.sql`    | Schema, miembros, restaurantes, menú, estantes, pagos, RLS. |
| `migrations/002_food_storage.sql` | Bucket `food-assets` y sus políticas.                        |
| `migrations/003_food_import.sql`  | Funciones de importación que usan los seeds.                |
| `seeds/`                          | Restaurantes, lotes de estantes y estantes activos, en JSON. Ver `seeds/README.md`. |
| `tools/generate-tags.mjs`         | Genera un lote de estantes nuevo.                           |
| `tests/001_003_food.test.sql`     | Pruebas de las tres migraciones.                            |

## Primer deploy

1. Confirmar que ninguna migración de food se aplicó a mano antes. Si alguna
   se aplicó, avisar antes de desplegar (estándar de migraciones 2.9).
2. `./projects/run-tests.sh food` en local.
3. Push y **Deploy** de `neko-supabase` en Dokploy.
4. En el log de `db-migrate`: 3 migraciones y 3 seeds aplicados.
5. Borrar la variable `PGRST_DB_SCHEMAS` del entorno de Dokploy: ya no se usa.
6. Verificar desde cualquier equipo, con la llave pública en `ANON`:

```bash
curl -s "https://neko-supabase-prod.nekomotsu.com/rest/v1/restaurants?select=slug" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H "Accept-Profile: food"
# Esperado: [{"slug":"el-corralito"}]
```

Sin verificar: si `postgres` puede crear las políticas de 002 en la imagen
actual. Si falla por permisos, ver "Permisos del usuario que migra" en
`../README.md`.

## Operador (cuando exista el dashboard)

Se agrega con una migración o un seed, no a mano:

```sql
insert into food.members (user_id, role)
select id, 'operator' from auth.users where email = 'CORREO_DEL_OPERADOR'
on conflict do nothing;
```

## Urgencias en Studio

Las restricciones y triggers aplican igual que desde la API. Lo que se
corrija en Studio se copia al JSON del seed el mismo día. Errores que Studio
puede mostrar:

| Error                                | Significado                                                        |
|--------------------------------------|--------------------------------------------------------------------|
| `FOOD_SLUG_IMMUTABLE`                | El slug de un restaurante no se cambia nunca.                      |
| `FOOD_TABLE_COUNT_BELOW_ACTIVE_TAG`  | Hay un estante activo en una mesa mayor a la nueva cantidad.       |
| `FOOD_TAG_RETIRED`                   | Un estante retirado no se reactiva ni se edita.                    |
| `FOOD_TAG_CODE_IMMUTABLE`            | El código de un estante está impreso y grabado; no se cambia.      |
| `FOOD_TABLE_NUMBER_OUT_OF_RANGE`     | La mesa supera la cantidad de mesas del restaurante.               |
| `tags_destination`                   | Un estante activo necesita restaurante y mesa; uno en stock o retirado no lleva ninguno. |
| `item_photos_position_unique`        | Ya hay una foto en esa posición (1 o 2) para ese plato.            |

Studio no valida que un plato tenga precio o variantes (nunca ambos) ni que
una foto no pase de 16,8 megapíxeles. Los seeds sí validan lo primero.
