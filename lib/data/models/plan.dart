class Plan {
  const Plan({required this.planId, required this.tierCredits, required this.priceDisplay});

  final String planId;
  final int tierCredits;
  final String priceDisplay;

  factory Plan.fromJson(Map<String, dynamic> json) => Plan(
        planId: json['plan_id'] as String,
        tierCredits: json['tier_credits'] as int,
        priceDisplay: json['price_display'] as String,
      );
}

class ExtraPack {
  const ExtraPack({required this.packId, required this.credits, required this.priceDisplay});

  final String packId;
  final int credits;
  final String priceDisplay;

  factory ExtraPack.fromJson(Map<String, dynamic> json) => ExtraPack(
        packId: json['pack_id'] as String,
        credits: json['credits'] as int,
        priceDisplay: json['price_display'] as String,
      );
}
