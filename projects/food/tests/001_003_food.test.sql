-- Pruebas de las migraciones 001, 002 y 003 de food.
-- Se corren con: projects/run-tests.sh food
-- Todo corre en una transacción que termina en ROLLBACK.

\set ON_ERROR_STOP on
\pset tuples_only on
\o /dev/null

begin;

-- Datos de prueba ------------------------------------------------------------

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'operador@test'),
  ('00000000-0000-0000-0000-00000000000b', 'otra-app@test');
insert into food.members (user_id, role) values
  ('00000000-0000-0000-0000-00000000000a', 'operator');

insert into food.restaurants (id, name, slug, table_count, status, latitude, longitude, show_on_home) values
  ('10000000-0000-0000-0000-000000000001', 'Publicado', 'publicado', 10, 'published', 8.75, -75.88, true),
  ('10000000-0000-0000-0000-000000000002', 'Borrador', 'borrador', 5, 'draft', null, null, false);

insert into food.categories (id, restaurant_id, name, is_visible) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Entradas', true),
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'Oculta', false),
  ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000002', 'Del borrador', true);

insert into food.items (id, category_id, name, price_cop, is_visible) values
  ('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'Chorizo', 15000, true),
  ('30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001', 'Plato oculto', 12000, false),
  ('30000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', 'En categoría oculta', 10000, true),
  ('30000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000003', 'Del borrador', 10000, true);

insert into food.item_variants (item_id, name, price_cop) values
  ('30000000-0000-0000-0000-000000000001', 'Grande', 20000),
  ('30000000-0000-0000-0000-000000000002', 'Oculta', 20000);

insert into food.item_photos (item_id, storage_path, position) values
  ('30000000-0000-0000-0000-000000000001', 'a.jpg', 1),
  ('30000000-0000-0000-0000-000000000001', 'b.jpg', 2);

insert into food.tiktok_videos (restaurant_id, source_url, video_id, position) values
  ('10000000-0000-0000-0000-000000000001',
   'https://www.tiktok.com/@elcorralito/video/7527476667770522893', '7527476667770522893', 1);

insert into food.payment_settings (restaurant_id, breb_key) values
  ('10000000-0000-0000-0000-000000000001', '@corralito'),
  ('10000000-0000-0000-0000-000000000002', '@borrador');

insert into food.tags (code, status, restaurant_id, table_number) values
  ('red-heart-moon', 'active', '10000000-0000-0000-0000-000000000001', 4),
  ('old-tree-rain', 'retired', null, null),
  ('new-leaf-sun', 'stock', null, null),
  ('blue-moon-sky', 'active', '10000000-0000-0000-0000-000000000002', 1);

insert into storage.buckets (id, name) values ('otra-app', 'otra-app');

-- Visitante anónimo ----------------------------------------------------------
-- anon no tiene permisos de escritura: falla antes de llegar a RLS.

select test.as_anon();

select test.expect_rows('select * from food.restaurants', 2);
select test.expect_rows('select * from food.categories', 1);
select test.expect_rows('select * from food.items', 1);
select test.expect_rows('select * from food.item_variants', 1);
select test.expect_rows('select * from food.item_photos', 2);
select test.expect_rows('select * from food.tiktok_videos', 1);
select test.expect_rows('select * from food.payment_settings', 1);
select test.expect_rows('select * from food.tags', 0);
select test.expect_error('select * from food.members', 'permission denied');

select test.expect_value($$select status::text || ':' || restaurant_slug || ':' || table_number from food.resolve_tag(' RED-Heart-Moon ')$$, 'active:publicado:4');
select test.expect_value($$select status::text || ':' || restaurant_slug || ':' || table_number from food.resolve_tag('blue-moon-sky')$$, 'active:borrador:1');
select test.expect_value($$select status::text || ':' || coalesce(restaurant_slug, '-') from food.resolve_tag('new-leaf-sun')$$, 'stock:-');
select test.expect_rows($$select * from food.resolve_tag('old-tree-rain')$$, 0);
select test.expect_rows($$select * from food.resolve_tag('no-existe-nunca')$$, 0);
select test.expect_value($$select food.has_role('operator')::text$$, 'false');

select test.expect_error($$insert into food.restaurants (name, slug, table_count) values ('X', 'xxx', 1)$$, 'permission denied');
select test.expect_error($$update food.restaurants set name = 'Hack'$$, 'permission denied');
select test.expect_error($$update food.payment_settings set breb_key = '@ladron'$$, 'permission denied');
select test.expect_error($$delete from food.restaurants$$, 'permission denied');
select test.expect_error($$insert into storage.objects (bucket_id, name) values ('food-assets', 'x.jpg')$$, 'row-level security');
select test.expect_error($$select food.import_restaurant('{}'::jsonb)$$, 'permission denied');
select test.expect_error($$select food.import_tags('[]'::jsonb)$$, 'permission denied');

-- Usuario autenticado de otro producto ---------------------------------------

select test.as_user('00000000-0000-0000-0000-00000000000b');

select test.expect_value($$select food.has_role('operator')::text$$, 'false');
select test.expect_error($$insert into food.restaurants (name, slug, table_count) values ('X', 'xxx', 1)$$, 'row-level security');
select test.expect_affected($$update food.payment_settings set breb_key = '@ladron'$$, 0);
select test.expect_rows('select * from food.tags', 0);
select test.expect_rows('select * from food.items', 1);
select test.expect_rows('select * from food.members', 0);
select test.expect_error($$insert into food.members (user_id, role) values ('00000000-0000-0000-0000-00000000000b', 'operator')$$, 'permission denied');
select test.expect_error($$insert into storage.objects (bucket_id, name) values ('food-assets', 'x.jpg')$$, 'row-level security');
select test.expect_error($$select food.import_restaurant('{}'::jsonb)$$, 'permission denied');

-- Operador -------------------------------------------------------------------

select test.as_user('00000000-0000-0000-0000-00000000000a');

select test.expect_value($$select food.has_role('operator')::text$$, 'true');
select test.expect_rows('select * from food.members', 1);
select test.expect_rows('select * from food.tags', 4);
select test.expect_rows('select * from food.items', 4);
select test.expect_rows('select * from food.payment_settings', 2);

-- Slug
select test.expect_error($$update food.restaurants set slug = 'otro' where slug = 'publicado'$$, 'FOOD_SLUG_IMMUTABLE');
select test.expect_error($$insert into food.restaurants (name, slug, table_count) values ('X', 'dashboard', 1)$$, 'check constraint');
select test.expect_error($$insert into food.restaurants (name, slug, table_count) values ('X', 'Con-Mayus', 1)$$, 'check constraint');
select test.expect_error($$insert into food.restaurants (name, slug, table_count) values ('X', 'guion--doble', 1)$$, 'check constraint');
select test.expect_error($$insert into food.restaurants (name, slug, table_count) values ('X', 'ab', 1)$$, 'check constraint');
select test.expect_error($$insert into food.restaurants (name, slug, table_count) values ('X', 'publicado', 1)$$, 'duplicate key');

-- Coordenadas y contacto
select test.expect_error($$insert into food.restaurants (name, slug, table_count, latitude, longitude) values ('X', 'bogota', 1, 4.71, -74.07)$$, 'restaurants_coordinates_monteria');
select test.expect_error($$insert into food.restaurants (name, slug, table_count, latitude) values ('X', 'sin-lon', 1, 8.75)$$, 'restaurants_coordinates_pair');
select test.expect_error($$insert into food.restaurants (name, slug, table_count, whatsapp) values ('X', 'mal-tel', 1, '3001234567')$$, 'check constraint');

-- Etiquetas
select test.expect_error($$update food.restaurants set table_count = 3 where slug = 'publicado'$$, 'FOOD_TABLE_COUNT_BELOW_ACTIVE_TAG');
select test.expect_affected($$update food.restaurants set table_count = 5 where slug = 'publicado'$$, 1);
select test.expect_error($$update food.tags set status = 'stock' where code = 'old-tree-rain'$$, 'FOOD_TAG_RETIRED');
select test.expect_error($$update food.tags set code = 'red-heart-sun' where code = 'red-heart-moon'$$, 'FOOD_TAG_CODE_IMMUTABLE');
select test.expect_error($$update food.tags set status = 'active', restaurant_id = '10000000-0000-0000-0000-000000000001', table_number = 6 where code = 'new-leaf-sun'$$, 'FOOD_TABLE_NUMBER_OUT_OF_RANGE');
select test.expect_error($$update food.tags set status = 'active' where code = 'new-leaf-sun'$$, 'tags_destination');
select test.expect_error($$update food.tags set restaurant_id = '10000000-0000-0000-0000-000000000001', table_number = 2 where code = 'new-leaf-sun'$$, 'tags_destination');
select test.expect_error($$update food.tags set status = 'active', restaurant_id = '10000000-0000-0000-0000-000000000001' where code = 'new-leaf-sun'$$, 'tags_destination_pair');
select test.expect_error($$insert into food.tags (code) values ('dos-palabras')$$, 'check constraint');
select test.expect_error($$insert into food.tags (code) values ('Red-Tree-Moon')$$, 'check constraint');
select test.expect_error($$insert into food.tags (code) values ('old-tree-rain')$$, 'duplicate key');
select test.expect_affected($$update food.tags set status = 'active', restaurant_id = '10000000-0000-0000-0000-000000000001', table_number = 5 where code = 'new-leaf-sun'$$, 1);
select test.expect_value($$select (activated_at is not null)::text from food.tags where code = 'new-leaf-sun'$$, 'true');
select test.expect_affected($$update food.tags set status = 'retired', restaurant_id = null, table_number = null where code = 'red-heart-moon'$$, 1);
select test.expect_rows($$select * from food.resolve_tag('red-heart-moon')$$, 0);
select test.expect_value($$select table_number::text from food.resolve_tag('new-leaf-sun')$$, '5');
select test.expect_error($$delete from food.tags$$, 'permission denied');
select test.expect_error($$delete from food.restaurants$$, 'permission denied');

-- Fotos, videos, precios y pagos
select test.expect_error($$insert into food.item_photos (item_id, storage_path, position) values ('30000000-0000-0000-0000-000000000001', 'c.jpg', 3)$$, 'check constraint');
select test.expect_error($$insert into food.tiktok_videos (restaurant_id, source_url, video_id, position) values ('10000000-0000-0000-0000-000000000001', 'https://www.tiktok.com/@a/video/111', '111', 4)$$, 'check constraint');
select test.expect_error($$insert into food.tiktok_videos (restaurant_id, source_url, video_id, position) values ('10000000-0000-0000-0000-000000000001', 'https://www.tiktok.com/@a/video/111', '222', 2)$$, 'tiktok_videos_id_matches_url');
select test.expect_error($$insert into food.tiktok_videos (restaurant_id, source_url, video_id, position) values ('10000000-0000-0000-0000-000000000001', 'https://vm.tiktok.com/ZMabc/', '111', 2)$$, 'check constraint');
select test.expect_affected($$insert into food.tiktok_videos (restaurant_id, source_url, video_id, position) values ('10000000-0000-0000-0000-000000000001', 'https://www.tiktok.com/@a.b_c/video/111?lang=es', '111', 2)$$, 1);
select test.expect_error($$insert into food.items (category_id, name, price_cop) values ('20000000-0000-0000-0000-000000000001', 'Gratis', 0)$$, 'check constraint');
select test.expect_error($$insert into food.item_variants (item_id, name, price_cop) values ('30000000-0000-0000-0000-000000000001', 'Cero', 0)$$, 'check constraint');
select test.expect_error($$update food.payment_settings set breb_key = null where breb_key = '@corralito'$$, 'payment_settings_not_empty');
select test.expect_affected($$update food.payment_settings set breb_key = '@nueva' where breb_key = '@corralito'$$, 1);
select test.expect_affected($$delete from food.items where name = 'Plato oculto'$$, 1);

-- Storage
select test.expect_affected($$insert into storage.objects (bucket_id, name) values ('food-assets', 'restaurants/x/items/y/z.jpg')$$, 1);
select test.expect_error($$insert into storage.objects (bucket_id, name) values ('otra-app', 'x.jpg')$$, 'row-level security');

-- Importación (como el usuario que aplica migraciones) -----------------------

reset role;
select set_config('request.jwt.claims', '', true);

select test.expect_error($$select food.import_restaurant('{"restaurant": {"slug": "imp", "name": "I", "table_count": 3}, "otra": 1}')$$, 'FOOD_IMPORT_UNKNOWN_KEY');
select test.expect_error($$select food.import_restaurant('{"restaurant": {"slug": "imp", "name": "I", "table_count": 3, "tabel_count": 3}}')$$, 'FOOD_IMPORT_UNKNOWN_KEY');
select test.expect_error($$select food.import_restaurant('{"restaurant": {"slug": "imp", "name": "I", "table_count": 3}, "categories": [{"name": "C", "items": [{"name": "Sin precio"}]}]}')$$, 'FOOD_IMPORT_PRICE_OR_VARIANTS');
select test.expect_error($$select food.import_restaurant('{"restaurant": {"slug": "imp", "name": "I", "table_count": 3}, "categories": [{"name": "C", "items": [{"name": "Ambos", "price_cop": 1000, "variants": [{"name": "V", "price_cop": 2000}]}]}]}')$$, 'FOOD_IMPORT_PRICE_OR_VARIANTS');
select test.expect_error($$select food.import_restaurant('{"restaurant": {"slug": "imp", "name": "I", "table_count": 3}, "categories": [{"name": "C", "items": [{"name": "D", "price_cop": 1000, "is_featured": true}]}]}')$$, 'FOOD_IMPORT_FEATURED_WITHOUT_PHOTO');
select test.expect_error($$select food.import_restaurant('{"restaurant": {"slug": "imp", "name": "I", "table_count": 3}, "categories": [{"name": "C", "items": [{"name": "D", "price_cop": 1000, "photos": ["a", "b", "c"]}]}]}')$$, 'check constraint');
select test.expect_error($$select food.import_restaurant('{"restaurant": {"slug": "imp", "name": "I", "table_count": 3}, "tiktok_videos": [{"url": "https://vm.tiktok.com/x"}]}')$$, 'check constraint');
select test.expect_rows($$select * from food.restaurants where slug = 'imp'$$, 0);

\set menu '{"restaurant": {"slug": "importado", "name": "Importado", "table_count": 4, "status": "published", "show_on_home": true, "latitude": 8.75, "longitude": -75.88}, "payment": {"breb_key": "@imp"}, "tiktok_videos": [{"url": "https://www.tiktok.com/@imp/video/123"}], "categories": [{"name": "Uno", "items": [{"name": "A", "price_cop": 1000, "is_featured": true, "photos": ["p1.jpg", "p2.jpg"]}, {"name": "B", "variants": [{"name": "Grande", "price_cop": 3000}, {"name": "Vaso", "price_cop": 1000}]}]}, {"name": "Dos", "note": "Nota", "items": [{"name": "C", "price_cop": 500}]}]}'

select food.import_restaurant(:'menu'::jsonb);
select food.import_restaurant(:'menu'::jsonb);
select test.expect_rows($$select * from food.restaurants where slug = 'importado'$$, 1);
select test.expect_value($$select string_agg(c.name || c.position, ',' order by c.position) from food.categories c join food.restaurants r on r.id = c.restaurant_id where r.slug = 'importado'$$, 'Uno1,Dos2');
select test.expect_value($$select string_agg(i.name || i.position, ',' order by c.position, i.position) from food.items i join food.categories c on c.id = i.category_id join food.restaurants r on r.id = c.restaurant_id where r.slug = 'importado'$$, 'A1,B2,C1');
select test.expect_value($$select string_agg(v.name || v.price_cop, ',' order by v.position) from food.item_variants v join food.items i on i.id = v.item_id where i.name = 'B'$$, 'Grande3000,Vaso1000');
select test.expect_value($$select string_agg(p.storage_path, ',' order by p.position) from food.item_photos p join food.items i on i.id = p.item_id where i.name = 'A'$$, 'p1.jpg,p2.jpg');
select test.expect_value($$select v.video_id from food.tiktok_videos v join food.restaurants r on r.id = v.restaurant_id where r.slug = 'importado'$$, '123');
select test.expect_value($$select p.breb_key from food.payment_settings p join food.restaurants r on r.id = p.restaurant_id where r.slug = 'importado'$$, '@imp');

\set menu2 '{"restaurant": {"slug": "importado", "name": "Renombrado", "table_count": 4, "status": "published"}, "payment": {"breb_key": null, "qr_payload": null}, "categories": []}'
select food.import_restaurant(:'menu2'::jsonb);
select test.expect_value($$select name from food.restaurants where slug = 'importado'$$, 'Renombrado');
select test.expect_rows($$select * from food.categories c join food.restaurants r on r.id = c.restaurant_id where r.slug = 'importado'$$, 0);
select test.expect_rows($$select * from food.payment_settings p join food.restaurants r on r.id = p.restaurant_id where r.slug = 'importado'$$, 0);
select test.expect_rows($$select * from food.tiktok_videos v join food.restaurants r on r.id = v.restaurant_id where r.slug = 'importado'$$, 0);

\set tags '[{"code": "one-two-three"}, {"code": "four-five-six", "restaurant_slug": "importado", "table_number": 2}]'
select test.expect_value($$select food.import_tags('$$ || :'tags' || $$')::text$$, '2');
select test.expect_value($$select food.import_tags('$$ || :'tags' || $$')::text$$, '0');
select test.expect_value($$select status::text from food.tags where code = 'one-two-three'$$, 'stock');
select test.expect_value($$select status::text || table_number from food.tags where code = 'four-five-six'$$, 'active2');
select test.expect_error($$select food.import_tags('[{"code": "four-five-six", "restaurant_slug": "no-existe", "table_number": 1}]')$$, 'FOOD_IMPORT_UNKNOWN_RESTAURANT');
select test.expect_error($$select food.import_tags('[{"code": "four-five-six", "restaurant_slug": "importado", "table_number": 9}]')$$, 'FOOD_TABLE_NUMBER_OUT_OF_RANGE');
select test.expect_error($$select food.import_tags('[{"code": "four-five-six", "restaurant_slug": "importado"}]')$$, 'tags_destination_pair');
select test.expect_affected($$select food.import_tags('[{"code": "one-two-three", "status": "retired"}]')$$, 1);
select test.expect_value($$select food.import_tags('[{"code": "one-two-three", "status": "retired"}]')::text$$, '0');
select test.expect_error($$select food.import_tags('[{"code": "one-two-three"}]')$$, 'FOOD_TAG_RETIRED');
select test.expect_error($$select food.import_restaurant('{"restaurant": {"slug": "importado", "name": "X", "table_count": 1}}')$$, 'FOOD_TABLE_COUNT_BELOW_ACTIVE_TAG');

\o
select 'OK: todas las pruebas de food pasaron' as resultado;

rollback;
