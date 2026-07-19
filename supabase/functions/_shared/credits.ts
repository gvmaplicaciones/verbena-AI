import { supabaseAdmin } from "./supabase.ts";

export type CreditSource = "tier" | "extra" | "free";

export class InsufficientCreditsError extends Error {
  constructor() {
    super("insufficient_credits");
  }
}

/**
 * Descuenta 1 crédito de forma atómica (lock de fila en user_credits) y dejo
 * rastro en credit_transactions. p_allow_free solo debe ser true para modo
 * Catálogo -- Libertad nunca usa el crédito gratis (regla de negocio).
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
