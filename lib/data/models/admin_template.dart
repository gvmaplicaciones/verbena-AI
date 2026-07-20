class AdminTemplate {
  final String id;
  final String categoryId;
  final String name;
  final String imageStoragePath;
  final bool isActive;
  final int sortOrder;

  const AdminTemplate({
    required this.id,
    required this.categoryId,
    required this.name,
    required this.imageStoragePath,
    required this.isActive,
    required this.sortOrder,
  });

  factory AdminTemplate.fromJson(Map<String, dynamic> json) => AdminTemplate(
        id: json['id'] as String,
        categoryId: json['category_id'] as String,
        name: json['name'] as String,
        imageStoragePath: json['image_storage_path'] as String,
        isActive: json['is_active'] as bool,
        sortOrder: json['sort_order'] as int,
      );
}
