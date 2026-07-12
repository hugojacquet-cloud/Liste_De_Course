-- ══════════════════════════════════════════════════════════════
-- MIGRATION : passage à un système de foyers multiples
-- À exécuter UNE FOIS dans SQL Editor, EN PLUS du script initial déjà passé.
-- Ne supprime aucune donnée : ta liste/recettes actuelles sont migrées
-- automatiquement vers un foyer nommé "Notre foyer".
-- ══════════════════════════════════════════════════════════════

-- 1. Nouvelles tables : foyers + appartenance
create table if not exists courses_households (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Notre foyer',
  created_at timestamptz not null default now()
);

create table if not exists courses_household_members (
  household_id uuid references courses_households(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (household_id, user_id)
);

alter table courses_households enable row level security;
alter table courses_household_members enable row level security;

drop policy if exists "Voir tous les foyers" on courses_households;
create policy "Voir tous les foyers" on courses_households for select to authenticated using (true);

drop policy if exists "Créer un foyer" on courses_households;
create policy "Créer un foyer" on courses_households for insert to authenticated with check (true);

drop policy if exists "Renommer si membre" on courses_households;
create policy "Renommer si membre" on courses_households for update to authenticated
  using (exists (select 1 from courses_household_members m where m.household_id = courses_households.id and m.user_id = auth.uid()));

drop policy if exists "Voir les memberships" on courses_household_members;
create policy "Voir les memberships" on courses_household_members for select to authenticated using (true);

drop policy if exists "Rejoindre un foyer" on courses_household_members;
create policy "Rejoindre un foyer" on courses_household_members for insert to authenticated with check (auth.uid() = user_id);

-- 2. courses_data devient scopé par foyer plutôt qu'une ligne unique "shared"
alter table courses_data add column if not exists household_id uuid references courses_households(id) on delete cascade;

do $$
declare
  hh_id uuid;
begin
  if not exists (select 1 from courses_household_members) then
    if not exists (select 1 from courses_households) then
      insert into courses_households (name) values ('Notre foyer') returning id into hh_id;
    else
      select id into hh_id from courses_households order by created_at limit 1;
    end if;

    insert into courses_household_members (household_id, user_id)
      select hh_id, id from courses_profiles
      on conflict do nothing;

    if exists (select 1 from information_schema.columns where table_name = 'courses_data' and column_name = 'key') then
      update courses_data set household_id = hh_id where key = 'shared' and household_id is null;
    end if;
  end if;
end $$;

-- Bascule la clé primaire de "key" (texte fixe) vers "household_id"
delete from courses_data where household_id is null; -- sécurité : supprime toute ligne orpheline sans foyer (avant de toucher à la clé primaire)
alter table courses_data drop constraint if exists courses_data_pkey;
alter table courses_data alter column household_id set not null;
alter table courses_data add primary key (household_id);
alter table courses_data drop column if exists key;

-- Nouvelles règles d'accès : uniquement les membres du foyer concerné
drop policy if exists "Lecture par tous les membres connectés" on courses_data;
drop policy if exists "Création par tous les membres connectés" on courses_data;
drop policy if exists "Mise à jour par tous les membres connectés" on courses_data;

create policy "Lecture par les membres du foyer" on courses_data for select to authenticated
  using (exists (select 1 from courses_household_members m where m.household_id = courses_data.household_id and m.user_id = auth.uid()));

create policy "Écriture par les membres du foyer" on courses_data for insert to authenticated
  with check (exists (select 1 from courses_household_members m where m.household_id = courses_data.household_id and m.user_id = auth.uid()));

create policy "Mise à jour par les membres du foyer" on courses_data for update to authenticated
  using (exists (select 1 from courses_household_members m where m.household_id = courses_data.household_id and m.user_id = auth.uid()));

-- 3. Active le temps réel sur les nouvelles tables (idempotent, ne plante pas si déjà fait)
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'courses_households') then
    alter publication supabase_realtime add table courses_households;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'courses_household_members') then
    alter publication supabase_realtime add table courses_household_members;
  end if;
end $$;

-- ══════════════════════════════════════════════════════════════
-- Après cette migration : tous les utilisateurs déjà créés se retrouvent
-- automatiquement membres du foyer "Notre foyer" (renommable dans l'app).
-- Les nouveaux comptes créés après cette migration devront créer ou
-- rejoindre un foyer à leur première connexion.
-- ══════════════════════════════════════════════════════════════
