-- Migración 002: bucket de fotos y logos de food.
-- Estándar: sección 2.6. Requiere 001.

-- Storage aplica el límite de tamaño y los tipos permitidos en el servidor
-- (spec 2.7.2): HEIC y archivos de más de 10 MB se rechazan también cuando
-- se suben desde Studio.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('food-assets', 'food-assets', true, 10485760,
        array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

-- La lectura pública no necesita política: el bucket es público.
-- La política de lectura del operador es necesaria para que Storage permita
-- borrar objetos desde la API.
create policy food_assets_operator_select on storage.objects
  for select to authenticated
  using (bucket_id = 'food-assets' and (select food.has_role('operator')));

create policy food_assets_operator_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'food-assets' and (select food.has_role('operator')));

create policy food_assets_operator_update on storage.objects
  for update to authenticated
  using (bucket_id = 'food-assets' and (select food.has_role('operator')))
  with check (bucket_id = 'food-assets' and (select food.has_role('operator')));

create policy food_assets_operator_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'food-assets' and (select food.has_role('operator')));

