-- Run this in Supabase SQL editor.
-- Safe to re-run.

-- 1) Exact duplicate protection at DB level
-- Uses UTC minute bucket to keep expression immutable.
drop index if exists gigs_exact_dedupe_idx;
create unique index if not exists gigs_exact_dedupe_idx
on public.gigs (
  venue_id,
  lower(trim(title)),
  date_trunc('minute', start_at at time zone 'UTC')
);

-- 2) Notification table for cross-alerts between venues and artists
create table if not exists public.gig_notifications (
  id uuid primary key default gen_random_uuid(),
  target_user_id uuid not null references auth.users(id) on delete cascade,
  source_user_id uuid not null references auth.users(id) on delete cascade,
  source_role text not null check (source_role in ('artist','venue')),
  kind text not null check (kind in ('gig_uploaded_for_artist','gig_uploaded_for_venue')),
  gig_id uuid references public.gigs(id) on delete set null,
  message text,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists gig_notifications_target_created_idx
on public.gig_notifications (target_user_id, created_at desc);

alter table public.gig_notifications enable row level security;

drop policy if exists gig_notifications_select_own on public.gig_notifications;
create policy gig_notifications_select_own
on public.gig_notifications
for select
to authenticated
using (auth.uid() = target_user_id);

drop policy if exists gig_notifications_insert_source on public.gig_notifications;
create policy gig_notifications_insert_source
on public.gig_notifications
for insert
to authenticated
with check (auth.uid() = source_user_id);

drop policy if exists gig_notifications_update_target on public.gig_notifications;
create policy gig_notifications_update_target
on public.gig_notifications
for update
to authenticated
using (auth.uid() = target_user_id)
with check (auth.uid() = target_user_id);

-- 3) Minimum gigs policies needed for artist/venue upload + duplicate checks
alter table public.gigs enable row level security;

drop policy if exists gigs_select_authenticated on public.gigs;
create policy gigs_select_authenticated
on public.gigs
for select
to authenticated
using (true);

drop policy if exists gigs_insert_own on public.gigs;
create policy gigs_insert_own
on public.gigs
for insert
to authenticated
with check (auth.uid() = created_by);

drop policy if exists gigs_update_own on public.gigs;
create policy gigs_update_own
on public.gigs
for update
to authenticated
using (auth.uid() = created_by)
with check (auth.uid() = created_by);

-- 4) Unified comments for venue/artist posts with role badge support
-- post_type + post_id lets one table support multiple post sources.
create table if not exists public.post_comments (
  id uuid primary key default gen_random_uuid(),
  post_type text not null check (post_type in ('venue','artist')),
  post_id text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  author_role text not null check (author_role in ('fan','artist','venue')),
  author_label text,
  body text not null check (char_length(trim(body)) > 0 and char_length(body) <= 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists post_comments_post_lookup_idx
on public.post_comments (post_type, post_id, created_at asc);

create index if not exists post_comments_user_idx
on public.post_comments (user_id, created_at desc);

create or replace function public.current_user_role()
returns text
language sql
stable
as $$
  select
    case
      when exists (select 1 from public.artist_profiles ap where ap.user_id = auth.uid()) then 'artist'
      when exists (select 1 from public.venue_profiles vp where vp.user_id = auth.uid()) then 'venue'
      else 'fan'
    end
$$;

create or replace function public.set_post_comment_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_post_comments_set_updated_at on public.post_comments;
create trigger trg_post_comments_set_updated_at
before update on public.post_comments
for each row
execute function public.set_post_comment_updated_at();

alter table public.post_comments enable row level security;

drop policy if exists post_comments_select_all on public.post_comments;
create policy post_comments_select_all
on public.post_comments
for select
to anon, authenticated
using (true);

drop policy if exists post_comments_insert_own on public.post_comments;
create policy post_comments_insert_own
on public.post_comments
for insert
to authenticated
with check (
  auth.uid() = user_id
  and author_role = public.current_user_role()
);

drop policy if exists post_comments_update_own on public.post_comments;
create policy post_comments_update_own
on public.post_comments
for update
to authenticated
using (auth.uid() = user_id)
with check (
  auth.uid() = user_id
  and author_role = public.current_user_role()
);

drop policy if exists post_comments_delete_own on public.post_comments;
create policy post_comments_delete_own
on public.post_comments
for delete
to authenticated
using (auth.uid() = user_id);

-- 5) Fan dashboard features: saved venues + followed artists
create table if not exists public.fan_saved_venues (
  id uuid primary key default gen_random_uuid(),
  fan_user_id uuid not null references auth.users(id) on delete cascade,
  venue_id text not null,
  venue_name text not null,
  town text,
  created_at timestamptz not null default now(),
  unique (fan_user_id, venue_id)
);

create index if not exists fan_saved_venues_user_created_idx
on public.fan_saved_venues (fan_user_id, created_at desc);

alter table public.fan_saved_venues enable row level security;

drop policy if exists fan_saved_venues_select_own on public.fan_saved_venues;
create policy fan_saved_venues_select_own
on public.fan_saved_venues
for select
to authenticated
using (auth.uid() = fan_user_id);

drop policy if exists fan_saved_venues_insert_own on public.fan_saved_venues;
create policy fan_saved_venues_insert_own
on public.fan_saved_venues
for insert
to authenticated
with check (auth.uid() = fan_user_id);

drop policy if exists fan_saved_venues_delete_own on public.fan_saved_venues;
create policy fan_saved_venues_delete_own
on public.fan_saved_venues
for delete
to authenticated
using (auth.uid() = fan_user_id);

create table if not exists public.fan_followed_artists (
  id uuid primary key default gen_random_uuid(),
  fan_user_id uuid not null references auth.users(id) on delete cascade,
  artist_user_id uuid not null references auth.users(id) on delete cascade,
  stage_name text not null,
  genre text,
  created_at timestamptz not null default now(),
  unique (fan_user_id, artist_user_id)
);

create index if not exists fan_followed_artists_user_created_idx
on public.fan_followed_artists (fan_user_id, created_at desc);

alter table public.fan_followed_artists enable row level security;

drop policy if exists fan_followed_artists_select_own on public.fan_followed_artists;
create policy fan_followed_artists_select_own
on public.fan_followed_artists
for select
to authenticated
using (auth.uid() = fan_user_id);

drop policy if exists fan_followed_artists_insert_own on public.fan_followed_artists;
create policy fan_followed_artists_insert_own
on public.fan_followed_artists
for insert
to authenticated
with check (auth.uid() = fan_user_id);

drop policy if exists fan_followed_artists_delete_own on public.fan_followed_artists;
create policy fan_followed_artists_delete_own
on public.fan_followed_artists
for delete
to authenticated
using (auth.uid() = fan_user_id);
