-- Vinyl Shelf Finder: synkronisering mellem Mac, Windows og iPhone.
-- Køres én gang i Supabase › SQL Editor. Kan køres igen uden at ødelægge noget.
--
-- Én tabel med poster. Hver post er én ting fra appens lokale database, gemt som JSON:
--   kind = 'release' | 'copy' | 'location' | 'section' | 'play' | 'history' | 'setting'
--   key  = fælles ID, ens på alle enheder (fx Discogs-kopinummer, eller et UUID for egne ting)
-- 'section' er hele rækkefølgen i én sektion, så en flytning aldrig kan blive halvt synkroniseret.
-- Slettede ting bliver stående med deleted = true, så de andre enheder også sletter dem.
-- updated_at sættes af serveren (ikke enhedens ur), og den nyeste ændring vinder.

create table if not exists public.sync_records (
    user_id     uuid        not null default auth.uid() references auth.users (id) on delete cascade,
    kind        text        not null check (kind in ('release', 'copy', 'location', 'section', 'play', 'history', 'setting')),
    key         text        not null check (length(key) between 1 and 200),
    data        jsonb,
    deleted     boolean     not null default false,
    device      text,
    updated_at  timestamptz not null default now(),
    primary key (user_id, kind, key)
);

create index if not exists sync_records_changes on public.sync_records (user_id, updated_at);

-- Serverens ur bestemmer rækkefølgen af ændringer.
create or replace function public.sync_records_touch() returns trigger
language plpgsql set search_path = '' as $$
begin
    new.updated_at := now();
    new.user_id := auth.uid();
    return new;
end;
$$;

drop trigger if exists sync_records_touch on public.sync_records;
create trigger sync_records_touch
    before insert or update on public.sync_records
    for each row execute function public.sync_records_touch();

-- Kun ejeren kan se og ændre sine poster.
alter table public.sync_records enable row level security;

drop policy if exists "egne poster: læs" on public.sync_records;
drop policy if exists "egne poster: opret" on public.sync_records;
drop policy if exists "egne poster: ændr" on public.sync_records;
drop policy if exists "egne poster: slet" on public.sync_records;

create policy "egne poster: læs"  on public.sync_records for select to authenticated using ((select auth.uid()) = user_id);
create policy "egne poster: opret" on public.sync_records for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "egne poster: ændr" on public.sync_records for update to authenticated
    using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "egne poster: slet" on public.sync_records for delete to authenticated using ((select auth.uid()) = user_id);

-- Ingen adgang uden login.
revoke all on public.sync_records from anon;
grant select, insert, update, delete on public.sync_records to authenticated;
