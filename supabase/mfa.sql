-- Vinyl Shelf Finder: totrinslogin (en kode fra en kode-app) skal være nødvendig for at se og ændre posterne.
-- Køres én gang i Supabase › SQL Editor, efter schema.sql. Kan køres igen uden at ødelægge noget.
--
-- Uden denne fil er totrinslogin kun pynt: et login med adgangskode eller mail-link ("aal1") kunne stadig læse
-- posterne. Med den gælder: har kontoen slået totrinslogin til, skal loginnet også have koden ("aal2").
-- Konti uden totrinslogin mærker ingen forskel. Supabases egen opskrift (Auth › MFA › "Enforce MFA").
--
-- En enhed, der mangler koden, ser bare ingen nye ændringer, og dens ændringer bliver afvist, indtil koden er skrevet.
-- Den sletter ikke noget.

drop policy if exists "totrinslogin" on public.sync_records;

create policy "totrinslogin" on public.sync_records
    as restrictive
    to authenticated
    using (
        array[(select auth.jwt() ->> 'aal')] <@ (
            select case when count(id) > 0 then array['aal2'] else array['aal1', 'aal2'] end
            from auth.mfa_factors
            where user_id = (select auth.uid()) and status = 'verified'
        )
    )
    with check (
        array[(select auth.jwt() ->> 'aal')] <@ (
            select case when count(id) > 0 then array['aal2'] else array['aal1', 'aal2'] end
            from auth.mfa_factors
            where user_id = (select auth.uid()) and status = 'verified'
        )
    );
