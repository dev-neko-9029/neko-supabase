-- Estantes activos: código, restaurante y mesa. También retiros.
-- Quitar una entrada no desactiva el estante: se cambia su destino o su estado.
select food.import_tags(:'data'::jsonb);
