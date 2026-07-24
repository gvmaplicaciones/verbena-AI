/// Espejo de la fila `user_credits` — dos contadores independientes:
/// tier_credits se resetea en cada renovación, extra_credits no caduca
/// nunca. tier_total es solo para pintar "used/total" en la UI.
class UserCredits {
  final int tierCredits;
  final int tierTotal;
  final int extraCredits;
  final bool freeCreditUsed;
  final String? activePlanId;
  final String subscriptionStatus; // 'none' | 'active' | 'cancelled' | 'expired'

  const UserCredits({
    required this.tierCredits,
    required this.tierTotal,
    required this.extraCredits,
    required this.freeCreditUsed,
    required this.subscriptionStatus,
    this.activePlanId,
  });

  int get tierUsed => tierTotal - tierCredits;
  bool get isSubscribed => subscriptionStatus == 'active';
  bool get canUseFreeGeneration => !isSubscribed && !freeCreditUsed;

  /// Espeja el orden tier -> extra -> free de deduct_credit() en Supabase
  /// (`_shared/credits.ts`). `allowFree` es true en cualquier modo -- solo
  /// hay un crédito gratis por usuario en total (`freeCreditUsed` es global).
  bool hasCreditsFor({required bool allowFree}) =>
      tierCredits > 0 || extraCredits > 0 || (allowFree && canUseFreeGeneration);

  factory UserCredits.fromJson(Map<String, dynamic> json) => UserCredits(
        tierCredits: json['tier_credits'] as int,
        tierTotal: json['tier_total'] as int,
        extraCredits: json['extra_credits'] as int,
        freeCreditUsed: json['free_credit_used'] as bool,
        activePlanId: json['active_plan_id'] as String?,
        subscriptionStatus: json['subscription_status'] as String,
      );
}
