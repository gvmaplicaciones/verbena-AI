enum GenerationCreditSource { free, tier, extra }

GenerationCreditSource? _creditSourceFromString(String? value) => switch (value) {
      'free' => GenerationCreditSource.free,
      'tier' => GenerationCreditSource.tier,
      'extra' => GenerationCreditSource.extra,
      _ => null,
    };

/// Resultado de generate-catalog/generate-add-element. `status: 'rejected'`
/// solo puede darse en modos con prompt libre (el filtro de contenido corre
/// sobre el resultado); Catálogo nunca rechaza porque la plantilla ya está
/// pre-aprobada.
class GenerationOutcome {
  final String status; // 'completed' | 'rejected'
  final String generationId;
  final String? resultUrl;
  final String? reason;
  final GenerationCreditSource? creditSource;

  const GenerationOutcome({
    required this.status,
    required this.generationId,
    this.resultUrl,
    this.reason,
    this.creditSource,
  });

  bool get isCompleted => status == 'completed';

  factory GenerationOutcome.fromJson(Map<String, dynamic> json, {String? creditSource}) =>
      GenerationOutcome(
        status: json['status'] as String,
        generationId: json['generationId'] as String,
        resultUrl: json['resultUrl'] as String?,
        reason: json['reason'] as String?,
        creditSource: _creditSourceFromString(creditSource),
      );
}
