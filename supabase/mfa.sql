-- Vinyl Shelf Finder: totrinslogin (en kode fra en kode-app) skal være nødvendig for at se og ændre posterne.
-- Køres i Supabase › SQL Editor, efter schema.sql. Kan køres igen uden at ødelægge noget.
--
-- Uden denne fil er totrinslogin kun pynt: et login med adgangskode eller mail-link ("aal1") kunne stadig læse
-- posterne. Med den gælder: har kontoen slået totrinslogin til, skal loginnet også have koden ("aal2").
-- Konti uden totrinslogin mærker ingen forskel.
--
-- En enhed, der mangler koden, ser bare ingen nye ændringer, og dens ændringer bliver afvist, indtil koden er skrevet.
-- Den sletter ikke noget.
--
-- 25. okt: den første udgave læste auth.mfa_factors direkte i reglen. Det må en almindelig bruger ikke, så al
-- synkronisering blev afvist med "permission denied". Nu sker opslaget i en funktion, der kører som ejeren
-- (security definer) og kun svarer for den bruger, der spørger.

create or replace function public.har_totrinslogin()
    returns boolean
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select exists (
        select 1 from auth.mfa_factors
        where user_id = (select auth.uid()) and status = 'verified'
    );
$$;

revoke all on function public.har_totrinslogin() from public, anon;
grant execute on function public.har_totrinslogin() to authenticated;

drop policy if exists "totrinslogin" on public.sync_records;

create policy "totrinslogin" on public.sync_records
    as restrictive
    to authenticated
    using ((select auth.jwt() ->> 'aal') = 'aal2' or not (select public.har_totrinslogin()))
    with check ((select auth.jwt() ->> 'aal') = 'aal2' or not (select public.har_totrinslogin()));
