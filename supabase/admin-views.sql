-- Vinyl Shelf Finder: statistik over brugerne direkte i Supabase.
-- Køres én gang i Supabase › SQL Editor. Kan køres igen uden at ødelægge noget.
--
-- Laver tre oversigter i skemaet "statistik". Se dem under Table Editor › vælg skemaet "statistik" øverst til venstre.
-- Skemaet er ikke delt med appen (det står ikke under API › Exposed schemas), så kun du kan se det i Supabase.

create schema if not exists statistik;
revoke all on schema statistik from public, anon, authenticated;

-- Én linje pr. konto: hvornår den blev oprettet og sidst var aktiv, hvor meget den har, og hvilke enheder den bruger.
create or replace view statistik.brugere as
select au.email                                   as e_mail,
       au.created_at::date                        as oprettet,
       au.last_sign_in_at::date                   as sidst_logget_ind,
       max(r.updated_at)::date                    as sidst_aktiv,
       count(*) filter (where r.kind = 'copy' and not r.deleted)     as plader,
       count(*) filter (where r.kind = 'location' and not r.deleted) as sektioner,
       count(*) filter (where r.kind = 'play' and not r.deleted)     as spillet,
       string_agg(distinct r.device, ', ')        as enheder
from auth.users au
left join public.sync_records r on r.user_id = au.id
group by au.id
order by sidst_aktiv desc nulls last;

-- Tallene samlet: brugere i alt, aktive og nye.
create or replace view statistik.overblik as
select count(*)                                                        as brugere_i_alt,
       count(*) filter (where sidst_aktiv > now() - interval '7 days')  as aktive_7_dage,
       count(*) filter (where sidst_aktiv > now() - interval '30 days') as aktive_30_dage,
       count(*) filter (where date_trunc('month', oprettet) = date_trunc('month', now())) as nye_denne_maaned,
       count(*) filter (where plader = 0)                               as aldrig_brugt,
       sum(spillet)                                                     as spillet_i_alt
from statistik.brugere;

-- Afspilninger pr. uge for alle brugere (de seneste 26 uger). Kør "select * from statistik.spillet_pr_uge"
-- i SQL Editor og vælg "Chart" for at se det som søjler.
create or replace view statistik.spillet_pr_uge as
select date_trunc('week', to_timestamp((r.data->>'at')::double precision))::date as uge,
       count(*)                                                                  as spillet,
       count(distinct r.user_id)                                                 as brugere
from public.sync_records r
where r.kind = 'play' and not r.deleted and r.data ? 'at'
  and to_timestamp((r.data->>'at')::double precision) > now() - interval '26 weeks'
group by 1
order by 1;

revoke all on all tables in schema statistik from public, anon, authenticated;
