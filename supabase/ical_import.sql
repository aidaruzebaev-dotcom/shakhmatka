-- Импорт броней с площадок по их iCal-ссылкам. Всё работает внутри базы:
-- pg_net скачивает календари, pg_cron запускает по расписанию.
create extension if not exists pg_net;
create extension if not exists pg_cron;

create table if not exists public.ical_requests(
  request_id bigint primary key,
  apartment_id text not null references public.apartments(id) on delete cascade,
  source text not null,
  created timestamptz not null default now()
);
alter table public.ical_requests enable row level security;
revoke all on public.ical_requests from anon, authenticated;

-- 1) отправить запросы за календарями площадок
create or replace function public.ical_request(p_owner uuid default null)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare r record; n int := 0; rid bigint;
begin
  for r in
    select a.id, e.key as source, regexp_replace(trim(e.value #>> '{}'), '^webcal://', 'https://', 'i') as url
    from public.apartments a, jsonb_each(a.ical_import_urls) e
    where (p_owner is null or a.owner_id = p_owner)
      and jsonb_typeof(e.value) = 'string'
      and (e.value #>> '{}') ~* '^\s*(https?|webcal)://'
  loop
    select net.http_get(url := r.url, timeout_milliseconds := 20000) into rid;
    insert into public.ical_requests(request_id, apartment_id, source) values (rid, r.id, r.source);
    n := n + 1;
  end loop;
  return n;
end $$;

-- 2) разобрать ответы и обновить брони
create or replace function public.ical_process()
returns int language plpgsql security definer set search_path = public, extensions as $$
declare q record; resp record; ev text[]; body text; v_uid text; ds text; de text;
        cin date; cout date; ext text; n int := 0; seen text[];
begin
  for q in select * from public.ical_requests order by created loop
    select status_code, content into resp from net._http_response where id = q.request_id;
    if not found then
      if q.created < now() - interval '10 minutes' then
        delete from public.ical_requests where request_id = q.request_id;
      end if;
      continue;
    end if;
    delete from public.ical_requests where request_id = q.request_id;
    if resp.status_code is distinct from 200 or resp.content is null
       or position('BEGIN:VCALENDAR' in upper(resp.content)) = 0 then
      continue;  -- площадка не ответила: ничего не трогаем
    end if;
    body := regexp_replace(resp.content, E'\r?\n[ \t]', '', 'g');
    seen := '{}';
    for ev in select regexp_matches(body, 'BEGIN:VEVENT(.*?)END:VEVENT', 'g') loop
      v_uid := trim(substring(ev[1] from E'\nUID[^:\r\n]*:([^\r\n]+)'));
      ds := substring(ev[1] from E'\nDTSTART[^:\r\n]*:(\\d{8})');
      de := substring(ev[1] from E'\nDTEND[^:\r\n]*:(\\d{8})');
      continue when ds is null;
      if v_uid is null or v_uid = '' then v_uid := ds || '-' || coalesce(de, ''); end if;
      continue when v_uid like '%@shakhmatka';          -- наш же календарь, вернувшийся обратно
      cin := to_date(ds, 'YYYYMMDD');
      cout := coalesce(to_date(de, 'YYYYMMDD'), cin + 1);
      if cout <= cin then cout := cin + 1; end if;
      continue when cout < current_date;
      ext := q.source || ':' || v_uid;
      -- если эти даты уже заняты другой бронью, второй раз не добавляем
      continue when exists (
        select 1 from public.bookings b
        where b.apartment_id = q.apartment_id and b.external_id is distinct from ext
          and b.check_in < cout and cin < b.check_out);
      seen := seen || ext;
      insert into public.bookings(id, owner_id, apartment_id, guest_name, check_in, check_out, source, external_id)
      select 'imp_' || md5(q.apartment_id || ext), a.owner_id, q.apartment_id, 'Бронь с площадки', cin, cout, q.source, ext
      from public.apartments a where a.id = q.apartment_id
      on conflict (id) do update set check_in = excluded.check_in, check_out = excluded.check_out;
      n := n + 1;
    end loop;
    -- брони, которых больше нет в календаре площадки (отменены), убираем
    delete from public.bookings b
    where b.apartment_id = q.apartment_id
      and b.external_id like q.source || ':%'
      and b.check_out >= current_date
      and not (b.external_id = any(seen));
  end loop;
  return n;
end $$;

-- 3) кнопка «Обновить сейчас» в приложении: только свои квартиры
create or replace function public.ical_refresh_mine()
returns int language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return 0; end if;
  return public.ical_request(auth.uid());
end $$;

-- календарь для выгрузки: без броней, пришедших с той же площадки (чтобы не было петли)
create or replace function public.ical_busy(p_token text, p_source text)
returns table(id text, check_in date, check_out date, created timestamptz)
language sql stable security definer set search_path = public as $f$
  select b.id, b.check_in, b.check_out, b.created
  from public.bookings b join public.apartments a on a.id = b.apartment_id
  where length(p_token) >= 20 and a.ical_token = p_token and b.check_out >= current_date - 30
    and (coalesce(p_source, '') = '' or b.external_id is null or b.external_id not like p_source || ':%')
$f$;

revoke all on function public.ical_request(uuid) from public, anon, authenticated;
revoke all on function public.ical_process() from public, anon, authenticated;
revoke all on function public.ical_refresh_mine() from public, anon;
grant execute on function public.ical_refresh_mine() to authenticated;
revoke all on function public.ical_busy(text, text) from public;
grant execute on function public.ical_busy(text, text) to anon, authenticated;

select cron.schedule('ical-request', '*/15 * * * *', $c$select public.ical_request()$c$);
select cron.schedule('ical-process', '* * * * *', $c$select public.ical_process()$c$);
