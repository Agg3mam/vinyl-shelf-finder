-- Vinyl Shelf Finder: statistik over brugerne (kun for administratorer).
-- Køres én gang i Supabase › SQL Editor efter schema.sql. Kan køres igen uden at ødelægge noget.
--
-- Webappen må kun se den indloggede brugers egne poster (RLS). Statistikken samler derfor tallene i en
-- funktion, der kører med ejerens rettigheder (security definer), men kun svarer, når den, der spørger,
-- står i tabellen admin_users. Alle andre får en fejl. Ingen nøgler eller adgangskoder i appen.
--
-- Gør dig selv til administrator (skriv din egen e-mail):
--   insert into public.admin_users(user_id) select id from auth.users where email = 'din@email.dk';

create table if not exists public.admin_users (
    user_id uuid primary key references auth.users (id) on delete cascade
);
alter table public.admin_users enable row level security;
revoke all on public.admin_users from anon, authenticated;

-- Er den indloggede bruger administrator? (Webappen viser kun linket til statistikken, når svaret er ja.)
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
    select exists (select 1 from public.admin_users where user_id = auth.uid());
$$;

-- Statistikken: én række pr. konto og afspilninger pr. uge (de seneste 26 uger).
create or replace function public.admin_stats() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
    if not public.is_admin() then
        raise exception 'Kun for administratorer' using errcode = '42501';
    end if;
    return jsonb_build_object(
        'generated_at', now(),
        'users', (
            select coalesce(jsonb_agg(to_jsonb(u) order by u.last_active desc nulls last), '[]'::jsonb)
            from (
                select au.email,
                       au.created_at,
                       au.last_sign_in_at,
                       s.last_active,
                       coalesce(s.copies, 0)   as copies,
                       coalesce(s.sections, 0) as sections,
                       coalesce(s.plays, 0)    as plays,
                       coalesce(s.devices, '[]'::jsonb) as devices
                from auth.users au
                left join lateral (
                    select max(r.updated_at) as last_active,
                           count(*) filter (where r.kind = 'copy' and not r.deleted)     as copies,
                           count(*) filter (where r.kind = 'location' and not r.deleted) as sections,
                           count(*) filter (where r.kind = 'play' and not r.deleted)     as plays,
                           jsonb_agg(distinct r.device) filter (where r.device is not null) as devices
                    from public.sync_records r
                    where r.user_id = au.id
                ) s on true
            ) u
        ),
        'plays_by_week', (
            select coalesce(jsonb_agg(jsonb_build_object('week', w.week, 'plays', w.plays) order by w.week), '[]'::jsonb)
            from (
                select date_trunc('week', to_timestamp((r.data->>'at')::double precision))::date as week, count(*) as plays
                from public.sync_records r
                where r.kind = 'play' and not r.deleted and r.data ? 'at'
                  and to_timestamp((r.data->>'at')::double precision) > now() - interval '26 weeks'
                group by 1
            ) w
        )
    );
end;
$$;

revoke all on function public.is_admin() from public, anon;
revoke all on function public.admin_stats() from public, anon;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.admin_stats() to authenticated;
