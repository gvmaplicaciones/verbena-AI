import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/verbena_theme.dart';
import '../../../core/utils/navigation.dart';
import '../../../data/models/template.dart';
import '../../../data/repositories/admin_repository.dart';

final adminCategoriesProvider = FutureProvider.autoDispose<List<TemplateCategory>>((ref) {
  return ref.watch(adminRepositoryProvider).fetchAllCategories();
});

class AdminCategoriesScreen extends ConsumerStatefulWidget {
  const AdminCategoriesScreen({super.key});

  @override
  ConsumerState<AdminCategoriesScreen> createState() => _AdminCategoriesScreenState();
}

class _AdminCategoriesScreenState extends ConsumerState<AdminCategoriesScreen> {
  bool _busy = false;

  Future<void> _toggle(TemplateCategory category) async {
    setState(() => _busy = true);
    try {
      await ref.read(adminRepositoryProvider).setCategoryActive(category.id, !category.isActive);
      ref.invalidate(adminCategoriesProvider);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(TemplateCategory category) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: VerbenaColors.card,
        title: Text('Borrar categoría', style: VerbenaText.display(size: 17)),
        content: Text(
          'Se borrará "${category.label}" permanentemente.',
          style: VerbenaText.body(size: 13.5, color: VerbenaColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancelar', style: VerbenaText.body(size: 13.5, weight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Borrar',
              style: VerbenaText.body(size: 13.5, weight: FontWeight.w700, color: VerbenaColors.terracotta),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(adminRepositoryProvider).deleteCategory(category.id);
      ref.invalidate(adminCategoriesProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se puede borrar: hay plantillas usando esta categoría.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openAddDialog() async {
    final idController = TextEditingController();
    final labelController = TextEditingController();
    final badgeController = TextEditingController();
    final sortOrderController = TextEditingController(text: '0');
    String? error;

    final created = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: VerbenaColors.card,
          title: Text('Nueva categoría', style: VerbenaText.display(size: 17)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: idController,
                  decoration: const InputDecoration(labelText: 'Slug (id, sin espacios)'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: labelController,
                  decoration: const InputDecoration(labelText: 'Etiqueta visible'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: badgeController,
                  decoration: const InputDecoration(labelText: 'Badge (opcional, ej. Navidad)'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: sortOrderController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Orden'),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: VerbenaText.body(size: 13, color: VerbenaColors.terracotta)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancelar', style: VerbenaText.body(size: 13.5, weight: FontWeight.w600)),
            ),
            TextButton(
              onPressed: () async {
                final id = idController.text.trim();
                final label = labelController.text.trim();
                final sortOrder = int.tryParse(sortOrderController.text.trim()) ?? 0;
                if (id.isEmpty || label.isEmpty) {
                  setDialogState(() => error = 'Rellena slug y etiqueta.');
                  return;
                }
                try {
                  await ref.read(adminRepositoryProvider).createCategory(
                        id: id,
                        label: label,
                        badgeText: badgeController.text.trim().isEmpty ? null : badgeController.text.trim(),
                        sortOrder: sortOrder,
                      );
                  if (context.mounted) Navigator.of(context).pop(true);
                } catch (_) {
                  setDialogState(() => error = 'No se ha podido crear (¿slug repetido?).');
                }
              },
              child: Text(
                'Crear',
                style: VerbenaText.body(size: 13.5, weight: FontWeight.w700, color: VerbenaColors.teal),
              ),
            ),
          ],
        ),
      ),
    );

    if (created == true) {
      ref.invalidate(adminCategoriesProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(adminCategoriesProvider);
    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: _busy,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Row(
                  children: [
                    IconButton(onPressed: () => context.safePop(), icon: const Icon(Icons.arrow_back)),
                    Expanded(child: Text('Categorías (admin)', style: VerbenaText.display(size: 19))),
                    IconButton(onPressed: _openAddDialog, icon: const Icon(Icons.add)),
                  ],
                ),
              ),
              Expanded(
                child: categoriesAsync.when(
                  loading: () => const Center(child: CircularProgressIndicator(color: VerbenaColors.teal)),
                  error: (err, st) => Center(
                    child: Text('No se pudieron cargar las categorías.', style: VerbenaText.body()),
                  ),
                  data: (categories) => ListView.builder(
                    padding: const EdgeInsets.all(20),
                    itemCount: categories.length,
                    itemBuilder: (context, i) {
                      final c = categories[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(c.label, style: VerbenaText.body(size: 14, weight: FontWeight.w600)),
                                  Text(
                                    c.badgeText != null ? '${c.id} · ${c.badgeText}' : c.id,
                                    style: VerbenaText.body(size: 12, color: VerbenaColors.textMuted),
                                  ),
                                ],
                              ),
                            ),
                            Switch(
                              value: c.isActive,
                              activeThumbColor: VerbenaColors.teal,
                              onChanged: (_) => _toggle(c),
                            ),
                            IconButton(onPressed: () => _delete(c), icon: const Icon(Icons.delete_outline)),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
