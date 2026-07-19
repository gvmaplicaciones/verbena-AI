-- VerbenAI — funciones de crédito atómicas para generate-catalog/generate-libertad.
-- El check-and-decrement tiene que ser una sola transacción con lock de fila
-- (SELECT ... FOR UPDATE) para que dos generaciones concurrentes del mismo
-- usuario no puedan gastar el mismo crédito dos veces. Solo service_role
-- puede ejecutarlas: reciben p_user_id de confianza (ya resuelto server-side
-- vía JWT), nunca hay que exponerlas a un p_user_id arbitrario del cliente.

create or replace function public.deduct_credit(
  p_user_id uuid,
  p_generation_id uuid,
  p_allow_free boolean
) returns text
language plpgsql
security definer set search_path = public
as $$
declare
  v_credits record;
  v_source text;
begin
  select * into v_credits from public.user_credits where user_id = p_user_id for update;
  if not found then
    raise exception 'user_credits not found for %', p_user_id;
  end if;

  -- Orden de consumo: gratis (solo Catálogo, solo si nunca suscrito y no
  -- usado) -> tier -> extra. Ver CLAUDE.md para el razonamiento de negocio.
  if p_allow_free and not v_credits.free_credit_used and v_credits.subscription_status <> 'active' then
    v_source := 'free';
    update public.user_credits
      set free_credit_used = true, updated_at = now()
      where user_id = p_user_id;
    insert into public.credit_transactions
      (user_id, type, amount, generation_id, balance_tier_after, balance_extra_after)
      values (p_user_id, 'free_debit', -1, p_generation_id, v_credits.tier_credits, v_credits.extra_credits);
  elsif v_credits.tier_credits > 0 then
    v_source := 'tier';
    update public.user_credits
      set tier_credits = tier_credits - 1, updated_at = now()
      where user_id = p_user_id;
    insert into public.credit_transactions
      (user_id, type, amount, generation_id, balance_tier_after, balance_extra_after)
      values (p_user_id, 'tier_debit', -1, p_generation_id, v_credits.tier_credits - 1, v_credits.extra_credits);
  elsif v_credits.extra_credits > 0 then
    v_source := 'extra';
    update public.user_credits
      set extra_credits = extra_credits - 1, updated_at = now()
      where user_id = p_user_id;
    insert into public.credit_transactions
      (user_id, type, amount, generation_id, balance_tier_after, balance_extra_after)
      values (p_user_id, 'extra_debit', -1, p_generation_id, v_credits.tier_credits, v_credits.extra_credits - 1);
  else
    raise exception 'insufficient_credits';
  end if;

  update public.generations set credit_source = v_source where id = p_generation_id;

  return v_source;
end;
$$;

-- Reembolsa el crédito de una generación que falló tras haber descontado
-- (p.ej. Replicate caído). Idempotente: pone credit_source a null tras
-- reembolsar, así que una segunda llamada para la misma generación no hace
-- nada.
create or replace function public.refund_credit(p_generation_id uuid)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  v_gen record;
  v_credits record;
begin
  select user_id, credit_source into v_gen from public.generations where id = p_generation_id for update;
  if not found or v_gen.credit_source is null then
    return;
  end if;

  perform 1 from public.user_credits where user_id = v_gen.user_id for update;

  if v_gen.credit_source = 'free' then
    update public.user_credits set free_credit_used = false, updated_at = now() where user_id = v_gen.user_id;
  elsif v_gen.credit_source = 'tier' then
    update public.user_credits set tier_credits = tier_credits + 1, updated_at = now() where user_id = v_gen.user_id;
  elsif v_gen.credit_source = 'extra' then
    update public.user_credits set extra_credits = extra_credits + 1, updated_at = now() where user_id = v_gen.user_id;
  end if;

  select * into v_credits from public.user_credits where user_id = v_gen.user_id;

  insert into public.credit_transactions
    (user_id, type, amount, generation_id, balance_tier_after, balance_extra_after)
    values (v_gen.user_id, 'refund', 1, p_generation_id, v_credits.tier_credits, v_credits.extra_credits);

  update public.generations set credit_source = null where id = p_generation_id;
end;
$$;

revoke all on function public.deduct_credit(uuid, uuid, boolean) from public, anon, authenticated;
revoke all on function public.refund_credit(uuid) from public, anon, authenticated;
grant execute on function public.deduct_credit(uuid, uuid, boolean) to service_role;
grant execute on function public.refund_credit(uuid) to service_role;
