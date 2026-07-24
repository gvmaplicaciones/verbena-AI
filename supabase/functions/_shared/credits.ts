import { supabaseAdmin } from "./supabase.ts";

export type CreditSource = "tier" | "extra" | "free";

export class InsufficientCreditsError extends Error {
  constructor() {
    super("insufficient_credits");
  }
}

/**
 * Descuenta 1 crédito de forma atómica (lock de fila en user_credits) y dejo
 * rastro en credit_transactions. p_allow_free debe ser true en cualquier
 * modo -- solo hay un crédito gratis por usuario en total (free_credit_used
 * es un flag global, no por modo), así que da igual cuál lo consuma primero.
 */
export async function deductCredit(
  admin: ReturnType<typeof supabaseAdmin>,
  userId: string,
  generationId: string,
  allowFree: boolean,
): Promise<CreditSource> {
  const { data, error } = await admin.rpc("deduct_credit", {
    p_user_id: userId,
    p_generation_id: generationId,
    p_allow_free: allowFree,
  });
  if (error) {
    if (error.message?.includes("insufficient_credits")) {
      throw new InsufficientCreditsError();
    }
    throw error;
  }
  return data as CreditSource;
}

/** Revierte el descuento de una generación que falló después de haber cobrado el crédito. */
export async function refundCredit(
  admin: ReturnType<typeof supabaseAdmin>,
  generationId: string,
): Promise<void> {
  const { error } = await admin.rpc("refund_credit", { p_generation_id: generationId });
  if (error) throw error;
}
