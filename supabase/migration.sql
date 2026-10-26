create extension if not exists pgcrypto;

create table if not exists public.mystery_rooms (
  id uuid primary key default gen_random_uuid(),
  room_code text not null unique check (room_code ~ '^[A-Z0-9]{5}$'),
  status text not null default 'waiting' check (status in ('waiting','playing','finished')),
  question_index int not null default 0 check (question_index between 0 and 20),
  questions jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.mystery_players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.mystery_rooms(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 24),
  character_id text not null check (character_id in ('conan','ai','mitsuhiko','genta')),
  score int not null default 0 check (score >= 0),
  current_question int not null default 0 check (current_question between 0 and 20),
  last_answer_correct boolean,
  connected boolean not null default true,
  joined_at timestamptz not null default now(),
  unique(room_id, character_id),
  unique(room_id, display_name)
);

create table if not exists public.mystery_answers (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.mystery_rooms(id) on delete cascade,
  player_id uuid not null references public.mystery_players(id) on delete cascade,
  question_index int not null check (question_index between 0 and 19),
  answer int not null check (answer between 0 and 10),
  is_correct boolean not null,
  answered_at timestamptz not null default now(),
  unique(player_id, question_index)
);

create index if not exists mystery_players_room_idx on public.mystery_players(room_id);
create index if not exists mystery_answers_room_idx on public.mystery_answers(room_id);

alter table public.mystery_rooms enable row level security;
alter table public.mystery_players enable row level security;
alter table public.mystery_answers enable row level security;

drop policy if exists "room read for participants" on public.mystery_rooms;
create policy "room read for participants" on public.mystery_rooms for select to anon, authenticated using (true);
drop policy if exists "players read roster" on public.mystery_players;
create policy "players read roster" on public.mystery_players for select to anon, authenticated using (true);
drop policy if exists "answers teacher or participants read" on public.mystery_answers;
create policy "answers teacher or participants read" on public.mystery_answers for select to authenticated using (
  (select coalesce(auth.jwt()->'app_metadata'->>'role','')) = 'teacher'
);

revoke insert, update, delete on public.mystery_rooms from anon, authenticated;
revoke insert, update, delete on public.mystery_players from anon, authenticated;
revoke insert, update, delete on public.mystery_answers from anon, authenticated;

create or replace function public.make_mystery_questions()
returns jsonb language plpgsql volatile as $$
declare
  outq jsonb := '[]'::jsonb;
  i int; a int; b int; ans int; op text;
  choices jsonb;
begin
  for i in 0..19 loop
    if i % 2 = 0 then
      a := floor(random()*6)::int;
      b := floor(random()*(11-a))::int;
      op := '+';
      ans := a+b;
    else
      a := 1+floor(random()*10)::int;
      b := floor(random()*(a+1))::int;
      op := '-';
      ans := a-b;
    end if;
    choices := jsonb_build_array(ans, (ans+1) % 11, (ans+4) % 11);
    outq := outq || jsonb_build_array(jsonb_build_object('a',a,'b',b,'op',op,'answer',ans,'choices',choices));
  end loop;
  return outq;
end $$;

create or replace function public.create_mystery_room()
returns table(room_id uuid, room_code text)
language plpgsql security definer set search_path = public as $$
declare code text;
begin
  loop
    code := upper(substr(encode(gen_random_bytes(4),'hex'),1,5));
    exit when not exists(select 1 from public.mystery_rooms r where r.room_code=code);
  end loop;
  insert into public.mystery_rooms(room_code,questions) values(code,public.make_mystery_questions())
  returning id, mystery_rooms.room_code into room_id, room_code;
  return next;
end $$;

create or replace function public.join_mystery_room(p_room_code text,p_display_name text,p_character_id text)
returns public.mystery_players
language plpgsql security definer set search_path = public as $$
declare r public.mystery_rooms; p public.mystery_players; cnt int;
begin
  select * into r from public.mystery_rooms where room_code=upper(trim(p_room_code)) for update;
  if not found then raise exception 'Room not found. Check the room code.'; end if;
  if r.status <> 'waiting' then raise exception 'This mission has already started.'; end if;
  if (select count(*) from public.mystery_players where room_id=r.id) >= 4 then
    raise exception 'This room is full. Only four students can join.';
  end if;
  if p_character_id not in ('conan','ai','mitsuhiko','genta') then raise exception 'Choose a valid character.'; end if;
  if exists(select 1 from public.mystery_players where room_id=r.id and character_id=p_character_id) then
    raise exception 'This character has already been selected. Please choose another character.';
  end if;
  if char_length(trim(p_display_name)) not between 1 and 24 then raise exception 'Name must be 1–24 characters.'; end if;
  insert into public.mystery_players(room_id,display_name,character_id)
    values(r.id,trim(p_display_name),p_character_id) returning * into p;
  select count(*) into cnt from public.mystery_players where room_id=r.id;
  if cnt=4 then update public.mystery_rooms set status='playing',updated_at=now() where id=r.id; end if;
  return p;
end $$;

create or replace function public.submit_mystery_answer(p_player_id uuid,p_question_index int,p_answer int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p public.mystery_players; r public.mystery_rooms; q jsonb; correct boolean; answer_count int;
begin
  select * into p from public.mystery_players where id=p_player_id for update;
  if not found then raise exception 'Player not found.'; end if;
  select * into r from public.mystery_rooms where id=p.room_id for update;
  if r.status <> 'playing' then raise exception 'The mission is not active.'; end if;
  if p_question_index <> p.current_question or p_question_index <> r.question_index then
    raise exception 'This question is not the current question.';
  end if;
  if exists(select 1 from public.mystery_answers where player_id=p.id and question_index=p_question_index) then
    raise exception 'You already answered this question.';
  end if;
  q := r.questions->p_question_index;
  correct := (q->>'answer')::int = p_answer;
  insert into public.mystery_answers(room_id,player_id,question_index,answer,is_correct)
    values(r.id,p.id,p_question_index,p_answer,correct);
  update public.mystery_players set score=score + case when correct then 1 else 0 end,
    current_question=current_question+1,last_answer_correct=correct where id=p.id;
  select count(*) into answer_count from public.mystery_answers
    where room_id=r.id and question_index=p_question_index;
  if answer_count >= 4 then
    if p_question_index=19 then
      update public.mystery_rooms set status='finished',question_index=20,updated_at=now() where id=r.id;
    else
      update public.mystery_rooms set question_index=p_question_index+1,updated_at=now() where id=r.id;
    end if;
  end if;
  return jsonb_build_object('correct',correct,'correct_answer',(q->>'answer')::int,
    'answers_received',answer_count,'answers_needed',4);
end $$;

grant execute on function public.create_mystery_room() to anon, authenticated;
grant execute on function public.join_mystery_room(text,text,text) to anon, authenticated;
grant execute on function public.submit_mystery_answer(uuid,int,int) to anon, authenticated;

alter publication supabase_realtime add table public.mystery_rooms;
alter publication supabase_realtime add table public.mystery_players;
