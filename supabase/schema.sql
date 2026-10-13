-- ============================================================
-- ACERTO: banco de dados seguro para o Supabase (Postgres)
-- Cole no "SQL Editor" do Supabase e execute UMA vez.
-- Cada comerciante (auth.uid()) só enxerga e altera o que é dele.
-- ============================================================

-- ---------- Funções auxiliares ----------
-- Limpa texto: tira caracteres de controle, espaços repetidos e corta no tamanho máximo.
create or replace function public.clean_text(t text, max_len int)
returns text language sql immutable as $$
  select left(btrim(regexp_replace(regexp_replace(coalesce(t, ''), '[\x00-\x1F\x7F]', ' ', 'g'), '\s+', ' ', 'g')), max_len)
$$;

-- Limite de abuso: no máximo N inserções por minuto por usuário em cada tabela.
create or replace function public.limit_inserts() returns trigger
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  execute format('select count(*) from public.%I where owner_id = $1 and created_at > now() - interval ''1 minute''', tg_table_name)
    into n using new.owner_id;
  if n >= 60 then
    raise exception 'Muitas operações em pouco tempo. Tente novamente em instantes.' using errcode = 'P0001';
  end if;
  return new;
end $$;

-- ---------- Tabelas ----------
create table if not exists public.clientes (
  id         bigint generated always as identity primary key,
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  nome       text not null,
  whatsapp   text not null,               -- só dígitos, com DDD
  cpf        text,                        -- opcional (LGPD: só peça se for necessário)
  idade      smallint,
  rua        text,
  created_at timestamptz not null default now(),
  unique (id, owner_id),                  -- permite a chave composta abaixo (anti-IDOR)
  constraint clientes_nome_ck     check (char_length(nome) between 2 and 80),
  constraint clientes_whatsapp_ck check (whatsapp ~ '^\d{10,11}$'),
  constraint clientes_cpf_ck      check (cpf is null or cpf ~ '^\d{11}$'),
  constraint clientes_idade_ck    check (idade is null or idade between 0 and 120),
  constraint clientes_rua_ck      check (rua is null or char_length(rua) <= 120)
);

create table if not exists public.fiados (
  id          bigint generated always as identity primary key,
  owner_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  cliente_id  bigint not null,
  descricao   text not null,
  valor_cent  bigint not null,            -- dinheiro em centavos (evita erro de arredondamento)
  data_compra date not null,
  vencimento  date,
  obs         text,
  created_at  timestamptz not null default now(),
  unique (id, owner_id),
  -- o fiado só pode apontar para um cliente DO MESMO dono (impede referência a dados de outra conta)
  foreign key (cliente_id, owner_id) references public.clientes (id, owner_id) on delete restrict,
  constraint fiados_desc_ck  check (char_length(descricao) between 2 and 120),
  constraint fiados_valor_ck check (valor_cent > 0 and valor_cent <= 1000000000),
  constraint fiados_datas_ck check (vencimento is null or vencimento >= data_compra),
  constraint fiados_obs_ck   check (obs is null or char_length(obs) <= 300)
);

create table if not exists public.pagamentos (
  id         bigint generated always as identity primary key,
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  fiado_id   bigint not null,
  valor_cent bigint not null,
  pago_em    date not null default current_date,
  created_at timestamptz not null default now(),
  foreign key (fiado_id, owner_id) references public.fiados (id, owner_id) on delete cascade,
  constraint pagamentos_valor_ck check (valor_cent > 0 and valor_cent <= 1000000000)
);

create index if not exists clientes_owner_idx   on public.clientes (owner_id);
create index if not exists fiados_owner_idx     on public.fiados (owner_id, vencimento);
create index if not exists pagamentos_fiado_idx on public.pagamentos (fiado_id);

-- ---------- Sanitização no servidor (não confia no navegador) ----------
create or replace function public.sanitize_cliente() returns trigger language plpgsql as $$
begin
  new.nome     := public.clean_text(new.nome, 80);
  new.whatsapp := regexp_replace(coalesce(new.whatsapp, ''), '\D', '', 'g');
  new.cpf      := nullif(regexp_replace(coalesce(new.cpf, ''), '\D', '', 'g'), '');
  new.rua      := nullif(public.clean_text(new.rua, 120), '');
  return new;
end $$;

create or replace function public.sanitize_fiado() returns trigger language plpgsql as $$
begin
  new.descricao := public.clean_text(new.descricao, 120);
  new.obs       := nullif(public.clean_text(new.obs, 300), '');
  return new;
end $$;

drop trigger if exists t_sanitize_cliente on public.clientes;
create trigger t_sanitize_cliente before insert or update on public.clientes
  for each row execute function public.sanitize_cliente();
drop trigger if exists t_sanitize_fiado on public.fiados;
create trigger t_sanitize_fiado before insert or update on public.fiados
  for each row execute function public.sanitize_fiado();

drop trigger if exists t_limit_clientes on public.clientes;
create trigger t_limit_clientes before insert on public.clientes for each row execute function public.limit_inserts();
drop trigger if exists t_limit_fiados on public.fiados;
create trigger t_limit_fiados before insert on public.fiados for each row execute function public.limit_inserts();
drop trigger if exists t_limit_pagamentos on public.pagamentos;
create trigger t_limit_pagamentos before insert on public.pagamentos for each row execute function public.limit_inserts();

-- Um pagamento nunca pode passar do que falta no fiado.
create or replace function public.check_pagamento() returns trigger
language plpgsql security definer set search_path = public as $$
declare total bigint; pago bigint;
begin
  select valor_cent into total from public.fiados where id = new.fiado_id and owner_id = new.owner_id;
  select coalesce(sum(valor_cent), 0) into pago from public.pagamentos where fiado_id = new.fiado_id;
  if pago + new.valor_cent > total then
    raise exception 'O pagamento passa do valor que falta.' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists t_check_pagamento on public.pagamentos;
create trigger t_check_pagamento before insert on public.pagamentos for each row execute function public.check_pagamento();

-- ---------- RLS: cada conta só acessa os próprios dados ----------
alter table public.clientes   enable row level security;
alter table public.fiados     enable row level security;
alter table public.pagamentos enable row level security;
alter table public.clientes   force row level security;
alter table public.fiados     force row level security;
alter table public.pagamentos force row level security;

-- Sem acesso para quem não está logado (anon) e sem privilégios sobrando.
revoke all on public.clientes, public.fiados, public.pagamentos from anon, public;
grant select, insert, update, delete on public.clientes, public.fiados to authenticated;
grant select, insert, delete on public.pagamentos to authenticated;  -- pagamento não se edita: estorna-se e refaz

do $$
declare t text;
begin
  foreach t in array array['clientes', 'fiados', 'pagamentos'] loop
    execute format('drop policy if exists %I on public.%I', t || '_sel', t);
    execute format('drop policy if exists %I on public.%I', t || '_ins', t);
    execute format('drop policy if exists %I on public.%I', t || '_upd', t);
    execute format('drop policy if exists %I on public.%I', t || '_del', t);
    execute format('create policy %I on public.%I for select to authenticated using (owner_id = (select auth.uid()))', t || '_sel', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (owner_id = (select auth.uid()))', t || '_ins', t);
    execute format('create policy %I on public.%I for delete to authenticated using (owner_id = (select auth.uid()))', t || '_del', t);
    if t <> 'pagamentos' then
      execute format('create policy %I on public.%I for update to authenticated using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()))', t || '_upd', t);
    end if;
  end loop;
end $$;

-- O dono nunca pode ser trocado depois de criado.
create or replace function public.lock_owner() returns trigger language plpgsql as $$
begin
  if new.owner_id is distinct from old.owner_id then
    raise exception 'Operação não permitida.' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists t_lock_owner_c on public.clientes;
create trigger t_lock_owner_c before update on public.clientes for each row execute function public.lock_owner();
drop trigger if exists t_lock_owner_f on public.fiados;
create trigger t_lock_owner_f before update on public.fiados for each row execute function public.lock_owner();
