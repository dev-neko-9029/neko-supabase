-- Migración 001: schema food, tablas del MVP1, reglas de integridad y RLS.
-- Estándar: neko-docs/docs/specs/neko-estandar-alta-producto.md, sección 2.4
-- Spec: neko-food-web/docs/specs/food-mvp1-menu-publico.md
--
-- La aplica migrate/migrate.sh en el deploy, dentro de una transacción
-- (estándar de migraciones): este archivo no lleva begin ni commit.

create schema food;

grant usage on schema food to anon, authenticated, service_role;

create type food.member_role as enum ('operator');
create type food.restaurant_status as enum ('draft', 'published', 'suspended');
create type food.tag_status as enum ('stock', 'active', 'retired');

-- ---------------------------------------------------------------------------
-- Tablas
-- ---------------------------------------------------------------------------

-- auth.users es compartido con otros productos de la instancia: estar
-- autenticado no da permisos en food (estándar 2.5).
create table food.members (
  user_id    uuid not null references auth.users (id) on delete cascade,
  role       food.member_role not null,
  created_at timestamptz not null default now(),
  primary key (user_id, role)
);

create table food.restaurants (
  id             uuid primary key default gen_random_uuid(),
  name           text not null check (char_length(btrim(name)) between 1 and 80),
  -- Más estricto que la spec a propósito: sin guion al inicio, al final ni
  -- repetido, para que las URLs compartidas sean legibles.
  slug           text not null unique
                 check (char_length(slug) between 3 and 60)
                 check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$')
                 check (slug not in ('dashboard', 'health', 'api', 'assets',
                                     'login', 'admin', 's', 'static')),
  tagline        text check (char_length(tagline) <= 80),
  menu_name      text check (char_length(menu_name) <= 60),
  logo_path      text,
  table_count    integer not null check (table_count between 1 and 200),
  latitude       double precision,
  longitude      double precision,
  show_on_home   boolean not null default false,
  whatsapp       text check (whatsapp ~ '^\+[1-9][0-9]{7,14}$'),
  tiktok_profile text,
  status         food.restaurant_status not null default 'draft',
  created_at     timestamptz not null default now(),
  constraint restaurants_coordinates_pair
    check ((latitude is null) = (longitude is null)),
  -- Casco urbano de Montería con margen. Se ajusta con una migración cuando
  -- haya coordenadas reales de clientes.
  constraint restaurants_coordinates_monteria
    check (latitude is null
           or (latitude between 8.65 and 8.85
               and longitude between -75.98 and -75.78))
);

-- Etiquetas físicas con código global (estándar 2.9). Se fabrican en stock y
-- se activan después hacia un restaurante y una mesa. No se borran: así un
-- código retirado nunca se reutiliza.
create table food.tags (
  code          text primary key
                check (code ~ '^[a-z]{3,12}-[a-z]{3,12}-[a-z]{3,12}$'),
  status        food.tag_status not null default 'stock',
  restaurant_id uuid references food.restaurants (id) on delete restrict,
  table_number  integer check (table_number >= 1),
  created_at    timestamptz not null default now(),
  activated_at  timestamptz,
  constraint tags_destination
    check ((status = 'active') = (restaurant_id is not null)),
  constraint tags_destination_pair
    check ((restaurant_id is null) = (table_number is null))
);

create table food.categories (
  id            uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references food.restaurants (id) on delete cascade,
  name          text not null check (char_length(btrim(name)) >= 1),
  note          text,
  position      integer not null default 0,
  is_visible    boolean not null default true,
  created_at    timestamptz not null default now()
);

-- "Precio único o variantes, nunca ambos" cruza dos tablas. La página pública
-- prioriza las variantes y oculta el plato que no tiene ninguna de las dos.
-- Un destacado sin foto se muestra como plato normal.
create table food.items (
  id          uuid primary key default gen_random_uuid(),
  category_id uuid not null references food.categories (id) on delete cascade,
  name        text not null check (char_length(btrim(name)) >= 1),
  description text,
  price_cop   integer check (price_cop > 0),
  is_new      boolean not null default false,
  is_featured boolean not null default false,
  position    integer not null default 0,
  is_visible  boolean not null default true,
  created_at  timestamptz not null default now()
);

create table food.item_variants (
  id        uuid primary key default gen_random_uuid(),
  item_id   uuid not null references food.items (id) on delete cascade,
  name      text not null check (char_length(btrim(name)) between 1 and 40),
  price_cop integer not null check (price_cop > 0),
  position  integer not null default 0
);

-- Unicidad diferible para poder intercambiar el orden de dos fotos en una
-- sola sentencia.
create table food.item_photos (
  id           uuid primary key default gen_random_uuid(),
  item_id      uuid not null references food.items (id) on delete cascade,
  storage_path text not null,
  position     smallint not null check (position in (1, 2)),
  constraint item_photos_position_unique
    unique (item_id, position) deferrable initially deferred
);

create table food.tiktok_videos (
  id            uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references food.restaurants (id) on delete cascade,
  source_url    text not null
                check (source_url ~ '^https://(www\.)?tiktok\.com/@[A-Za-z0-9._]+/video/[0-9]+([/?#].*)?$'),
  video_id      text not null check (video_id ~ '^[0-9]+$'),
  position      smallint not null check (position in (1, 2, 3)),
  is_visible    boolean not null default true,
  constraint tiktok_videos_id_matches_url
    check (source_url ~ ('/video/' || video_id || '([/?#]|$)')),
  constraint tiktok_videos_position_unique
    unique (restaurant_id, position) deferrable initially deferred
);

create table food.payment_settings (
  restaurant_id     uuid primary key references food.restaurants (id) on delete cascade,
  breb_key          text,
  verification_text text,
  -- Contenido entregado por la entidad financiera, sin modificar (spec D4).
  qr_payload        text,
  constraint payment_settings_not_empty
    check (breb_key is not null or qr_payload is not null)
);

create index on food.tags (restaurant_id, status);
create index on food.categories (restaurant_id, position);
create index on food.items (category_id, position);
create index on food.item_variants (item_id, position);
create index on food.tiktok_videos (restaurant_id, position);

-- ---------------------------------------------------------------------------
-- Reglas de integridad con trigger
-- ---------------------------------------------------------------------------

-- CONTEXTO: trigger BEFORE UPDATE de food.restaurants. Lo dispara cualquier
--   edición, desde Studio o desde la importación.
-- LÓGICA DE NEGOCIO: el slug no cambia nunca después del alta, porque se
--   comparte en enlaces (spec 2.7.2). La cantidad de mesas no puede bajar de
--   la mesa más alta con una etiqueta activa.
-- INPUT: fila anterior y fila nueva de food.restaurants.
-- OUTPUT: la fila nueva, o error FOOD_SLUG_IMMUTABLE o
--   FOOD_TABLE_COUNT_BELOW_ACTIVE_TAG.
-- EFECTOS: lectura de food.tags.
-- IDEMPOTENCIA: sí; no modifica datos.
create function food.guard_restaurant_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.slug is distinct from old.slug then
    raise exception 'FOOD_SLUG_IMMUTABLE';
  end if;

  if new.table_count < old.table_count and exists (
    select 1
    from food.tags t
    where t.restaurant_id = new.id
      and t.status = 'active'
      and t.table_number > new.table_count
  ) then
    raise exception 'FOOD_TABLE_COUNT_BELOW_ACTIVE_TAG';
  end if;

  return new;
end;
$$;

create trigger restaurants_guard_update
before update on food.restaurants
for each row execute function food.guard_restaurant_update();

-- CONTEXTO: trigger BEFORE INSERT OR UPDATE de food.tags. Lo disparan la
--   carga de lotes, la activación y el retiro de etiquetas.
-- LÓGICA DE NEGOCIO: el código está impreso y grabado, así que no cambia. Una
--   etiqueta retirada queda congelada. Una etiqueta activa apunta a una mesa
--   dentro de la cantidad de mesas del restaurante. Al activarse se registra
--   la fecha.
-- INPUT: fila anterior (sólo en UPDATE) y fila nueva de food.tags.
-- OUTPUT: la fila nueva, o error FOOD_TAG_RETIRED, FOOD_TAG_CODE_IMMUTABLE o
--   FOOD_TABLE_NUMBER_OUT_OF_RANGE.
-- EFECTOS: lectura de food.restaurants; asigna activated_at.
-- IDEMPOTENCIA: sí; el resultado depende sólo de las filas recibidas.
create function food.guard_tag()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if old.status = 'retired' then
      raise exception 'FOOD_TAG_RETIRED';
    end if;
    if new.code is distinct from old.code then
      raise exception 'FOOD_TAG_CODE_IMMUTABLE';
    end if;
  end if;

  if new.status = 'active' then
    if new.table_number > (
      select r.table_count from food.restaurants r where r.id = new.restaurant_id
    ) then
      raise exception 'FOOD_TABLE_NUMBER_OUT_OF_RANGE';
    end if;
    if tg_op = 'INSERT' or old.status <> 'active' then
      new.activated_at := now();
    end if;
  end if;

  return new;
end;
$$;

create trigger tags_guard
before insert or update on food.tags
for each row execute function food.guard_tag();

-- ---------------------------------------------------------------------------
-- Funciones expuestas
-- ---------------------------------------------------------------------------

-- CONTEXTO: usada por las políticas RLS de food y por las apps del producto.
-- LÓGICA DE NEGOCIO: un usuario tiene un rol en food sólo si está en
--   food.members con ese rol (estándar 2.4).
-- INPUT: objeto { p_role: food.member_role }.
-- OUTPUT: boolean.
-- EFECTOS: lectura de food.members.
-- IDEMPOTENCIA: sí; sólo lectura.
create function food.has_role(p_role food.member_role)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from food.members m
    where m.user_id = auth.uid() and m.role = p_role
  );
$$;

-- CONTEXTO: la llaman /s/<código> y la página del restaurante, en el
--   servidor. Vía PostgREST: POST /rpc/resolve_tag.
-- LÓGICA DE NEGOCIO: devuelve lo mínimo para decidir la respuesta: estado,
--   slug del restaurante y mesa. Una etiqueta retirada o inexistente no
--   devuelve filas. Corre con permisos del dueño para que anon no pueda
--   listar las etiquetas (estándar 2.9).
-- INPUT: objeto { p_code: text }. Se compara en minúsculas.
-- OUTPUT: cero o una fila (status, restaurant_slug, table_number).
-- EFECTOS: lectura de food.tags y food.restaurants.
-- IDEMPOTENCIA: sí; sólo lectura.
create function food.resolve_tag(p_code text)
returns table (status food.tag_status, restaurant_slug text, table_number integer)
language sql
stable
security definer
set search_path = ''
as $$
  select t.status, r.slug, t.table_number
  from food.tags t
  left join food.restaurants r on r.id = t.restaurant_id
  where t.code = lower(btrim(p_code))
    and t.status <> 'retired';
$$;

revoke execute on function food.has_role(food.member_role) from public;
revoke execute on function food.resolve_tag(text) from public;
grant execute on function food.has_role(food.member_role) to anon, authenticated;
grant execute on function food.resolve_tag(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Permisos y RLS
-- ---------------------------------------------------------------------------
-- En las políticas, `(select food.has_role(...))` se evalúa una vez por
-- consulta y no una vez por fila.

grant select on all tables in schema food to anon, authenticated;
grant insert, update, delete on all tables in schema food to authenticated;
-- Restaurantes y etiquetas no se borran desde la API: un restaurante se
-- suspende y una etiqueta se retira.
revoke delete on food.restaurants, food.tags from authenticated;
revoke all on food.members from anon;
revoke insert, update, delete on food.members from authenticated;

alter table food.members          enable row level security;
alter table food.restaurants      enable row level security;
alter table food.tags             enable row level security;
alter table food.categories       enable row level security;
alter table food.items            enable row level security;
alter table food.item_variants    enable row level security;
alter table food.item_photos      enable row level security;
alter table food.tiktok_videos    enable row level security;
alter table food.payment_settings enable row level security;

create policy members_select_own on food.members
  for select to authenticated
  using (user_id = auth.uid());

-- Todos los restaurantes son legibles: la página "Menú no disponible" muestra
-- el nombre de restaurantes en borrador o suspendidos (spec 2.6). Sus menús no.
create policy restaurants_select on food.restaurants
  for select to anon, authenticated
  using (true);
create policy restaurants_insert on food.restaurants
  for insert to authenticated
  with check ((select food.has_role('operator')));
create policy restaurants_update on food.restaurants
  for update to authenticated
  using ((select food.has_role('operator')))
  with check ((select food.has_role('operator')));

create policy tags_select on food.tags
  for select to authenticated
  using ((select food.has_role('operator')));
create policy tags_insert on food.tags
  for insert to authenticated
  with check ((select food.has_role('operator')));
create policy tags_update on food.tags
  for update to authenticated
  using ((select food.has_role('operator')))
  with check ((select food.has_role('operator')));

create policy categories_select on food.categories
  for select to anon, authenticated
  using (
    (select food.has_role('operator'))
    or (is_visible and exists (
      select 1 from food.restaurants r
      where r.id = restaurant_id and r.status = 'published'))
  );
create policy categories_write on food.categories
  for all to authenticated
  using ((select food.has_role('operator')))
  with check ((select food.has_role('operator')));

create policy items_select on food.items
  for select to anon, authenticated
  using (
    (select food.has_role('operator'))
    or (is_visible and exists (
      select 1
      from food.categories c
      join food.restaurants r on r.id = c.restaurant_id
      where c.id = category_id and c.is_visible and r.status = 'published'))
  );
create policy items_write on food.items
  for all to authenticated
  using ((select food.has_role('operator')))
  with check ((select food.has_role('operator')));

-- Variantes y fotos heredan la visibilidad de su plato por la política de
-- food.items.
create policy item_variants_select on food.item_variants
  for select to anon, authenticated
  using ((select food.has_role('operator'))
         or exists (select 1 from food.items i where i.id = item_id));
create policy item_variants_write on food.item_variants
  for all to authenticated
  using ((select food.has_role('operator')))
  with check ((select food.has_role('operator')));

create policy item_photos_select on food.item_photos
  for select to anon, authenticated
  using ((select food.has_role('operator'))
         or exists (select 1 from food.items i where i.id = item_id));
create policy item_photos_write on food.item_photos
  for all to authenticated
  using ((select food.has_role('operator')))
  with check ((select food.has_role('operator')));

create policy tiktok_videos_select on food.tiktok_videos
  for select to anon, authenticated
  using (
    (select food.has_role('operator'))
    or (is_visible and exists (
      select 1 from food.restaurants r
      where r.id = restaurant_id and r.status = 'published'))
  );
create policy tiktok_videos_write on food.tiktok_videos
  for all to authenticated
  using ((select food.has_role('operator')))
  with check ((select food.has_role('operator')));

create policy payment_settings_select on food.payment_settings
  for select to anon, authenticated
  using (
    (select food.has_role('operator'))
    or exists (
      select 1 from food.restaurants r
      where r.id = restaurant_id and r.status = 'published')
  );
create policy payment_settings_write on food.payment_settings
  for all to authenticated
  using ((select food.has_role('operator')))
  with check ((select food.has_role('operator')));

