-- Esquema do app de despesas (já aplicado no projeto Supabase xraygbmishqxyrtiwyxy,
-- migration "despesas_app_schema"). Guardado aqui só como referência.
-- Tabelas com prefixo desp_ para não conflitar com as tabelas do sistema da barbearia.
-- Só usuários cadastrados em desp_membros (Renan e Jhennifer) enxergam os dados.

create table public.desp_membros (
  user_id uuid primary key references auth.users(id) on delete cascade,
  nome text not null
);

create or replace function public.desp_is_member()
returns boolean language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.desp_membros where user_id = (select auth.uid())) $$;
revoke execute on function public.desp_is_member() from public, anon;
grant execute on function public.desp_is_member() to authenticated;

create table public.desp_blocos (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (char_length(nome) between 1 and 40),
  icone text not null default 'wallet',
  criado_por uuid default auth.uid() references auth.users(id) on delete set null,
  criado_em timestamptz not null default now()
);

create table public.desp_fixas (
  id uuid primary key default gen_random_uuid(),
  bloco_id uuid not null references public.desp_blocos(id) on delete cascade,
  nome text not null check (char_length(nome) between 1 and 60),
  valor numeric(12,2) not null check (valor >= 0),
  dia_venc smallint not null check (dia_venc between 1 and 31),
  inicio date not null,             -- primeiro mês (dia 1)
  fim date,                          -- último mês gerado quando encerrada
  gerado_ate date,                   -- último mês já lançado
  criado_por uuid default auth.uid() references auth.users(id) on delete set null,
  criado_em timestamptz not null default now()
);

create table public.desp_despesas (
  id uuid primary key default gen_random_uuid(),
  bloco_id uuid not null references public.desp_blocos(id) on delete cascade,
  nome text not null check (char_length(nome) between 1 and 60),
  valor numeric(12,2) not null check (valor >= 0),
  vencimento date not null,
  pago boolean not null default false,
  data_pagamento date,
  tipo text not null default 'avulsa' check (tipo in ('avulsa','fixa','parcelada')),
  grupo_id uuid,
  parcela_num smallint,
  parcela_total smallint,
  fixa_id uuid references public.desp_fixas(id) on delete set null,
  mes_ref date,
  criado_por uuid default auth.uid() references auth.users(id) on delete set null,
  criado_em timestamptz not null default now(),
  unique (fixa_id, mes_ref)
);

create index desp_blocos_criado_por_idx on public.desp_blocos(criado_por);
create index desp_fixas_bloco_idx on public.desp_fixas(bloco_id);
create index desp_fixas_criado_por_idx on public.desp_fixas(criado_por);
create index desp_despesas_bloco_idx on public.desp_despesas(bloco_id);
create index desp_despesas_grupo_idx on public.desp_despesas(grupo_id);
create index desp_despesas_criado_por_idx on public.desp_despesas(criado_por);

alter table public.desp_membros enable row level security;
alter table public.desp_blocos enable row level security;
alter table public.desp_fixas enable row level security;
alter table public.desp_despesas enable row level security;

revoke all on public.desp_membros, public.desp_blocos, public.desp_fixas, public.desp_despesas from anon;

create policy desp_membros_select on public.desp_membros for select to authenticated using ((select public.desp_is_member()));
create policy desp_blocos_all on public.desp_blocos for all to authenticated using ((select public.desp_is_member())) with check ((select public.desp_is_member()));
create policy desp_fixas_all on public.desp_fixas for all to authenticated using ((select public.desp_is_member())) with check ((select public.desp_is_member()));
create policy desp_despesas_all on public.desp_despesas for all to authenticated using ((select public.desp_is_member())) with check ((select public.desp_is_member()));

-- Lança as ocorrências mensais das contas fixas até o mês atual (horário de Brasília).
-- Usa gerado_ate para não recriar meses já lançados (mesmo que tenham sido excluídos).
create or replace function public.desp_gerar_fixas()
returns integer language plpgsql security invoker set search_path = ''
as $$
declare
  mes_atual date := date_trunc('month', now() at time zone 'America/Sao_Paulo')::date;
  n integer;
begin
  if not public.desp_is_member() then
    raise exception 'acesso negado';
  end if;

  with alvo as (
    select f.*, m::date as mes
    from public.desp_fixas f
    cross join lateral generate_series(
      coalesce((f.gerado_ate + interval '1 month')::date, f.inicio),
      least(mes_atual, coalesce(f.fim, mes_atual)),
      interval '1 month') m
  ), ins as (
    insert into public.desp_despesas (bloco_id, nome, valor, vencimento, tipo, fixa_id, mes_ref, criado_por)
    select bloco_id, nome, valor,
           mes + (least(dia_venc, extract(day from (mes + interval '1 month - 1 day'))::int) - 1),
           'fixa', id, mes, criado_por
    from alvo
    on conflict (fixa_id, mes_ref) do nothing
    returning 1
  )
  select count(*) into n from ins;

  update public.desp_fixas f
     set gerado_ate = least(mes_atual, coalesce(f.fim, mes_atual))
   where (f.gerado_ate is null or f.gerado_ate < least(mes_atual, coalesce(f.fim, mes_atual)))
     and f.inicio <= least(mes_atual, coalesce(f.fim, mes_atual));

  return n;
end $$;
revoke execute on function public.desp_gerar_fixas() from public, anon;
grant execute on function public.desp_gerar_fixas() to authenticated;

-- Os logins (renan@despesas.app / jhennifer@despesas.app) foram criados em auth.users
-- e cadastrados em desp_membros. Para adicionar alguém: crie o usuário no painel
-- (Authentication > Users) e depois:
--   insert into public.desp_membros (user_id, nome) values ('<uuid do usuário>', 'Nome');
