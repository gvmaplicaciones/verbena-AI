class TemplateCategory {
  final String id;
  final String label;
  final String? badgeText;
  final int sortOrder;

  const TemplateCategory({
    required this.id,
    required this.label,
    required this.sortOrder,
    this.badgeText,
  });

  factory TemplateCategory.fromJson(Map<String, dynamic> json) => TemplateCategory(
        id: json['id'] as String,
        label: json['label'] as String,
        badgeText: json['badge_text'] as String?,
        sortOrder: json['sort_order'] as int,
      );
}

class Template {
  final String id;
  final String categoryId;
  final String name;
  final String imageStoragePath;
  final int sortOrder;

  const Template({
    required this.id,
    required this.categoryId,
    required this.name,
    required this.imageStoragePath,
    required this.sortOrder,
  });

  factory Template.fromJson(Map<String, dynamic> json) => Template(
        id: json['id'] as String,
        categoryId: json['category_id'] as String,
        name: json['name'] as String,
        imageStoragePath: json['image_storage_path'] as String,
        sortOrder: json['sort_order'] as int,
      );
}
