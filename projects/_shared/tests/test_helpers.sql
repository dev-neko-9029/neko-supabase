-- Funciones de aserción para las pruebas SQL de los productos.
-- Se aplican después de las migraciones, en la base temporal de pruebas.

create schema test;
grant usage on schema test to anon, authenticated;

create function test.expect_error(p_sql text, p_pattern text)
returns void
language plpgsql
as $$
begin
  execute p_sql;
  raise exception 'NO_ERROR_RAISED';
exception when others then
  if sqlerrm = 'NO_ERROR_RAISED' then
    raise exception 'Se esperaba un error y no ocurrió: %', p_sql;
  end if;
  if sqlerrm !~* p_pattern then
    raise exception 'Error distinto al esperado en "%": %', p_sql, sqlerrm;
  end if;
end;
$$;

create function test.expect_rows(p_sql text, p_expected bigint)
returns void
language plpgsql
as $$
declare
  n bigint;
begin
  execute 'select count(*) from (' || p_sql || ') q' into n;
  if n <> p_expected then
    raise exception 'Se esperaban % filas y hubo % en "%"', p_expected, n, p_sql;
  end if;
end;
$$;

create function test.expect_affected(p_sql text, p_expected bigint)
returns void
language plpgsql
as $$
declare
  n bigint;
begin
  execute p_sql;
  get diagnostics n = row_count;
  if n <> p_expected then
    raise exception 'Se esperaban % filas afectadas y hubo % en "%"', p_expected, n, p_sql;
  end if;
end;
$$;

-- Compara el primer valor devuelto; null si la consulta no devuelve filas.
create function test.expect_value(p_sql text, p_expected text)
returns void
language plpgsql
as $$
declare
  v text;
begin
  execute p_sql into v;
  if v is distinct from p_expected then
    raise exception 'Se esperaba % y hubo % en "%"', p_expected, v, p_sql;
  end if;
end;
$$;

create function test.as_anon()
returns void
language sql
as $$
  select set_config('request.jwt.claims', '', true);
  select set_config('role', 'anon', true);
$$;

create function test.as_user(p_id uuid)
returns void
language sql
as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_id)::text, true);
  select set_config('role', 'authenticated', true);
$$;

grant execute on all functions in schema test to anon, authenticated;
