-- VerbenAI — el ledger de cobros (credit_transactions) tiene que sobrevivir
-- al borrado de cuenta (delete-user-data llama a auth.admin.deleteUser, que
-- por defecto cascadearía y se llevaría el historial de cobros con él).
-- Se desvincula en vez de borrar: user_id pasa a null, la fila de ledger se
-- conserva para contabilidad/disputas de cobro con Apple/Google, sin poder
-- atribuirse ya a un usuario concreto tras el borrado.
alter table public.credit_transactions
  alter column user_id drop not null;

alter table public.credit_transactions
  drop constraint credit_transactions_user_id_fkey;

alter table public.credit_transactions
  add constraint credit_transactions_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete set null;
