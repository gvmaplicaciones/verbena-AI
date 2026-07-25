/// Fila de `generations` con status='completed' y result_storage_path no nulo
/// — las que alimentan "Mis creaciones" en Perfil (solo socios).
class GenerationSummary {
  const GenerationSummary({
    required this.id,
    required this.mode,
    this.promptText,
    required this.storagePath,
    required this.createdAt,
  });

  final String id;
  final String mode;
  final String? promptText;
  final String storagePath;
  final DateTime createdAt;

  factory GenerationSummary.fromJson(Map<String, dynamic> json) =>
      GenerationSummary(
        id: json['id'] as String,
        mode: json['mode'] as String,
        promptText: json['prompt_text'] as String?,
        storagePath: json['result_storage_path'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  String get modeLabel => switch (mode) {
        'catalog' => 'Catálogo',
        'add_element' => 'Añadir algo',
        'remove_element' => 'Eliminar algo',
        'change_background' => 'Cambiar fondo',
        _ => 'Generación',
      };

  String get formattedDate {
    final dt = createdAt.toLocal();
    return '${dt.day.toString().padLeft(2, '0')}/'
        '${dt.month.toString().padLeft(2, '0')}/'
        '${dt.year}';
  }
}
