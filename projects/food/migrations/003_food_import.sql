-- Migración 003: importación de restaurantes y etiquetas desde JSON.
-- Sin dashboard en el MVP1, los datos viven en JSON dentro del repositorio y
-- los aplican los seeds de projects/food/seeds/ en cada deploy (spec 2.17).
-- Requiere 001.
--
-- Estas funciones no se exponen por la API: sólo las ejecuta migrate.sh.

-- CONTEXTO: validación interna de las funciones de importación.
-- LÓGICA DE NEGOCIO: una clave desconocida en el JSON es casi siempre un error
--   de digitación; se rechaza en vez de ignorarla en silencio.
-- INPUT: objeto { p_object: jsonb, p_allowed: text[], p_where: text }.
-- OUTPUT: nada, o error FOOD_IMPORT_UNKNOWN_KEY.
-- EFECTOS: ninguno.
-- IDEMPOTENCIA: sí.
create function food.import_assert_keys(p_object jsonb, p_allowed text[], p_where text)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_key text;
begin
  if p_object is null or jsonb_typeof(p_object) <> 'object' then
    raise exception 'FOOD_IMPORT_NOT_AN_OBJECT: %', p_where;
  end if;
  for v_key in select k from jsonb_object_keys(p_object) k loop
    if not v_key = any (p_allowed) then
      raise exception 'FOOD_IMPORT_UNKNOWN_KEY: "%" en %', v_key, p_where;
    end if;
  end loop;
end;
$$;

-- CONTEXTO: carga inicial o recarga completa del menú de un restaurante.
--   La llaman los seeds de projects/food/seeds/ (migrate.sh).
-- LÓGICA DE NEGOCIO:
--   - El restaurante se identifica por su slug. Si existe, se actualizan sus
--     datos; el slug nunca cambia.
--   - Categorías, platos, variantes, fotos y videos se reemplazan completos.
--     El orden sale del orden de los arreglos.
--   - Cada plato tiene precio único o variantes, nunca ambos ni ninguno.
--   - Un plato destacado necesita al menos una foto.
--   - Los datos de pago se reemplazan; si no hay llave ni QR, se borran.
--   - Recargar cambia los identificadores de los platos: las listas "Mi
--     lista" abiertas en ese momento muestran esos platos como no
--     disponibles (trade-off aceptado frente a mantener claves estables).
-- INPUT: objeto JSON con restaurant, payment, tiktok_videos y categories
--   (formato en projects/food/seeds/README.md).
-- OUTPUT: uuid del restaurante, o error FOOD_IMPORT_* o de restricciones.
-- EFECTOS: escribe en restaurants, categories, items, item_variants,
--   item_photos, tiktok_videos y payment_settings, en una sola transacción.
-- IDEMPOTENCIA: sí en contenido; importar dos veces el mismo JSON deja los
--   mismos datos, con identificadores nuevos en categorías y platos.
create function food.import_restaurant(p_data jsonb)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_restaurant jsonb := p_data -> 'restaurant';
  v_payment    jsonb := p_data -> 'payment';
  v_id         uuid;
  v_category   jsonb;
  v_category_id uuid;
  v_item       jsonb;
  v_item_id    uuid;
  v_variant    jsonb;
  v_video      jsonb;
  v_photo      jsonb;
  v_has_price  boolean;
  v_has_variants boolean;
  v_pos        integer;
  v_item_pos   integer;
  v_sub_pos    integer;
begin
  perform food.import_assert_keys(p_data,
    array['restaurant', 'payment', 'tiktok_videos', 'categories'], 'raíz');
  perform food.import_assert_keys(v_restaurant,
    array['slug', 'name', 'tagline', 'menu_name', 'logo_path', 'table_count',
          'latitude', 'longitude', 'show_on_home', 'whatsapp',
          'tiktok_profile', 'status'], 'restaurant');

  insert into food.restaurants as t
    (slug, name, tagline, menu_name, logo_path, table_count, latitude,
     longitude, show_on_home, whatsapp, tiktok_profile, status)
  values (
    v_restaurant ->> 'slug',
    v_restaurant ->> 'name',
    v_restaurant ->> 'tagline',
    v_restaurant ->> 'menu_name',
    v_restaurant ->> 'logo_path',
    (v_restaurant ->> 'table_count')::integer,
    (v_restaurant ->> 'latitude')::double precision,
    (v_restaurant ->> 'longitude')::double precision,
    coalesce((v_restaurant ->> 'show_on_home')::boolean, false),
    v_restaurant ->> 'whatsapp',
    v_restaurant ->> 'tiktok_profile',
    coalesce(v_restaurant ->> 'status', 'draft')::food.restaurant_status
  )
  on conflict (slug) do update set
    name           = excluded.name,
    tagline        = excluded.tagline,
    menu_name      = excluded.menu_name,
    logo_path      = excluded.logo_path,
    table_count    = excluded.table_count,
    latitude       = excluded.latitude,
    longitude      = excluded.longitude,
    show_on_home   = excluded.show_on_home,
    whatsapp       = excluded.whatsapp,
    tiktok_profile = excluded.tiktok_profile,
    status         = excluded.status
  returning t.id into v_id;

  delete from food.categories where restaurant_id = v_id;

  v_pos := 0;
  for v_category in
    select value from jsonb_array_elements(coalesce(p_data -> 'categories', '[]'::jsonb))
  loop
    v_pos := v_pos + 1;
    perform food.import_assert_keys(v_category,
      array['name', 'note', 'is_visible', 'items'], format('categories[%s]', v_pos));

    insert into food.categories (restaurant_id, name, note, position, is_visible)
    values (v_id, v_category ->> 'name', v_category ->> 'note', v_pos,
            coalesce((v_category ->> 'is_visible')::boolean, true))
    returning id into v_category_id;

    v_item_pos := 0;
    for v_item in
      select value from jsonb_array_elements(coalesce(v_category -> 'items', '[]'::jsonb))
    loop
      v_item_pos := v_item_pos + 1;
      perform food.import_assert_keys(v_item,
        array['name', 'description', 'price_cop', 'is_new', 'is_featured',
              'is_visible', 'variants', 'photos'],
        format('%s > items[%s]', v_category ->> 'name', v_item_pos));

      v_has_price := (v_item ->> 'price_cop') is not null;
      v_has_variants := jsonb_array_length(coalesce(v_item -> 'variants', '[]'::jsonb)) > 0;
      if v_has_price = v_has_variants then
        raise exception 'FOOD_IMPORT_PRICE_OR_VARIANTS: "%" debe tener precio o variantes, no ambos ni ninguno',
          v_item ->> 'name';
      end if;
      if coalesce((v_item ->> 'is_featured')::boolean, false)
         and jsonb_array_length(coalesce(v_item -> 'photos', '[]'::jsonb)) = 0 then
        raise exception 'FOOD_IMPORT_FEATURED_WITHOUT_PHOTO: "%"', v_item ->> 'name';
      end if;

      insert into food.items
        (category_id, name, description, price_cop, is_new, is_featured, position, is_visible)
      values (
        v_category_id,
        v_item ->> 'name',
        v_item ->> 'description',
        (v_item ->> 'price_cop')::integer,
        coalesce((v_item ->> 'is_new')::boolean, false),
        coalesce((v_item ->> 'is_featured')::boolean, false),
        v_item_pos,
        coalesce((v_item ->> 'is_visible')::boolean, true)
      )
      returning id into v_item_id;

      v_sub_pos := 0;
      for v_variant in
        select value from jsonb_array_elements(coalesce(v_item -> 'variants', '[]'::jsonb))
      loop
        v_sub_pos := v_sub_pos + 1;
        perform food.import_assert_keys(v_variant, array['name', 'price_cop'],
          format('%s > variants[%s]', v_item ->> 'name', v_sub_pos));
        insert into food.item_variants (item_id, name, price_cop, position)
        values (v_item_id, v_variant ->> 'name',
                (v_variant ->> 'price_cop')::integer, v_sub_pos);
      end loop;

      v_sub_pos := 0;
      for v_photo in
        select value from jsonb_array_elements(coalesce(v_item -> 'photos', '[]'::jsonb))
      loop
        v_sub_pos := v_sub_pos + 1;
        insert into food.item_photos (item_id, storage_path, position)
        values (v_item_id, v_photo #>> '{}', v_sub_pos);
      end loop;
    end loop;
  end loop;

  delete from food.tiktok_videos where restaurant_id = v_id;

  v_pos := 0;
  for v_video in
    select value from jsonb_array_elements(coalesce(p_data -> 'tiktok_videos', '[]'::jsonb))
  loop
    v_pos := v_pos + 1;
    perform food.import_assert_keys(v_video, array['url', 'is_visible'],
      format('tiktok_videos[%s]', v_pos));
    insert into food.tiktok_videos (restaurant_id, source_url, video_id, position, is_visible)
    values (
      v_id,
      v_video ->> 'url',
      coalesce(substring(v_video ->> 'url' from '/video/([0-9]+)'), ''),
      v_pos,
      coalesce((v_video ->> 'is_visible')::boolean, true)
    );
  end loop;

  delete from food.payment_settings where restaurant_id = v_id;

  if v_payment is not null and jsonb_typeof(v_payment) <> 'null' then
    perform food.import_assert_keys(v_payment,
      array['breb_key', 'verification_text', 'qr_payload'], 'payment');
    if (v_payment ->> 'breb_key') is not null or (v_payment ->> 'qr_payload') is not null then
      insert into food.payment_settings (restaurant_id, breb_key, verification_text, qr_payload)
      values (v_id, v_payment ->> 'breb_key', v_payment ->> 'verification_text',
              v_payment ->> 'qr_payload');
    end if;
  end if;

  return v_id;
end;
$$;

-- CONTEXTO: carga de lotes de estantes y cambios de destino sin dashboard.
--   La llaman los seeds de projects/food/seeds/ (migrate.sh).
-- LÓGICA DE NEGOCIO:
--   - Una etiqueta con restaurant_slug y table_number queda activa.
--   - Sin destino queda en stock, salvo que el JSON diga "retired".
--   - Las etiquetas existentes se actualizan sólo si algo cambió; las reglas
--     de food.guard_tag siguen aplicando (una retirada no se reactiva).
-- INPUT: arreglo JSON de { code, restaurant_slug?, table_number?, status? }.
-- OUTPUT: cantidad de etiquetas insertadas o modificadas.
-- EFECTOS: escribe en food.tags.
-- IDEMPOTENCIA: sí; importar dos veces el mismo arreglo no cambia nada.
create function food.import_tags(p_data jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tag         jsonb;
  v_pos         integer := 0;
  v_count       integer := 0;
  v_rows        integer;
  v_restaurant  uuid;
  v_status      food.tag_status;
begin
  if jsonb_typeof(p_data) <> 'array' then
    raise exception 'FOOD_IMPORT_NOT_AN_ARRAY: etiquetas';
  end if;

  for v_tag in select value from jsonb_array_elements(p_data) loop
    v_pos := v_pos + 1;
    perform food.import_assert_keys(v_tag,
      array['code', 'restaurant_slug', 'table_number', 'status'], format('tags[%s]', v_pos));

    v_restaurant := null;
    if (v_tag ->> 'restaurant_slug') is not null then
      select r.id into v_restaurant
      from food.restaurants r
      where r.slug = v_tag ->> 'restaurant_slug';
      if v_restaurant is null then
        raise exception 'FOOD_IMPORT_UNKNOWN_RESTAURANT: "%" en tags[%]',
          v_tag ->> 'restaurant_slug', v_pos;
      end if;
    end if;

    v_status := case
      when v_restaurant is not null then 'active'
      else coalesce(v_tag ->> 'status', 'stock')
    end::food.tag_status;

    insert into food.tags as t (code, status, restaurant_id, table_number)
    values (v_tag ->> 'code', v_status, v_restaurant, (v_tag ->> 'table_number')::integer)
    on conflict (code) do update set
      status        = excluded.status,
      restaurant_id = excluded.restaurant_id,
      table_number  = excluded.table_number
    where (t.status, t.restaurant_id, t.table_number)
          is distinct from (excluded.status, excluded.restaurant_id, excluded.table_number);

    get diagnostics v_rows = row_count;
    v_count := v_count + v_rows;
  end loop;

  return v_count;
end;
$$;

-- Se revoca también a los roles de la API por si la instancia tiene permisos
-- por defecto que los otorguen.
revoke execute on function food.import_assert_keys(jsonb, text[], text)
  from public, anon, authenticated;
revoke execute on function food.import_restaurant(jsonb)
  from public, anon, authenticated;
revoke execute on function food.import_tags(jsonb)
  from public, anon, authenticated;

