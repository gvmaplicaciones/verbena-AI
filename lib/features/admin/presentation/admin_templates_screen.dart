import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_routes.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../data/models/admin_template.dart';
import '../../../data/repositories/admin_repository.dart';

final adminTemplatesProvider = FutureProvider.autoDispose<List<AdminTemplate>>((ref) {
  return ref.watch(adminRepositoryProvider).fetchAllTemplates();
});

final adminTemplateImageUrlProvider =
    FutureProvider.autoDispose.family<String, String>((ref, storagePath) {
  return ref.watch(adminRepositoryProvider).signedImageUrl(storagePath);
});

class AdminTemplatesScreen extends ConsumerStatefulWidget {
  const AdminTemplatesScreen({super.key});

  @override
  ConsumerState<AdminTemplatesScreen> createState() => _AdminTemplatesScreenState();
}

class _AdminTemplatesScreenState extends ConsumerState<AdminTemplatesScreen> {
  bool _busy = false;

  Future<void> _exit() async {
    setState(() => _busy = true);
    try {
      await ref.read(adminRepositoryProvider).exitAdminMode();
      if (!mounted) return;
      context.go(AppRoutes.home);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(AdminTemplate template) async {
    setState(() => _busy = true);
    try {
      await ref.read(adminRepositoryProvider).setActive(template.id, !template.isActive);
      ref.invalidate(adminTemplatesProvider);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(AdminTemplate template) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: VerbenaColors.card,
        title: Text('Borrar plantilla', style: VerbenaText.display(size: 17)),
        content: Text(
          'Se borrará "${template.name}" permanentemente.',
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
      await ref.read(adminRepositoryProvider).deleteTemplate(template.id, template.imageStoragePath);
      ref.invalidate(adminTemplatesProvider);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final templatesAsync = ref.watch(adminTemplatesProvider);
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
                    Expanded(child: Text('Plantillas (admin)', style: VerbenaText.display(size: 19))),
                    IconButton(
                      onPressed: () => context.push(AppRoutes.adminCategories),
                      icon: const Icon(Icons.category_outlined),
                      tooltip: 'Categorías',
                    ),
                    IconButton(
                      onPressed: () => context
                          .push(AppRoutes.adminNewTemplate)
                          .then((_) => ref.invalidate(adminTemplatesProvider)),
                      icon: const Icon(Icons.add),
                    ),
                    TextButton(
                      onPressed: _exit,
                      child: Text('Salir', style: VerbenaText.body(size: 13.5, weight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: templatesAsync.when(
                  loading: () => const Center(child: CircularProgressIndicator(color: VerbenaColors.teal)),
                  error: (err, st) => Center(
                    child: Text('No se pudieron cargar las plantillas.', style: VerbenaText.body()),
                  ),
                  data: (templates) => ListView.builder(
                    padding: const EdgeInsets.all(20),
                    itemCount: templates.length,
                    itemBuilder: (context, i) {
                      final t = templates[i];
                      final urlAsync = ref.watch(adminTemplateImageUrlProvider(t.imageStoragePath));
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: SizedBox(
                                width: 56,
                                height: 56,
                                child: urlAsync.when(
                                  loading: () => Container(color: VerbenaColors.card),
                                  error: (err, st) => Container(color: VerbenaColors.card),
                                  data: (url) => CachedNetworkImage(imageUrl: url, fit: BoxFit.cover),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(t.name, style: VerbenaText.body(size: 14, weight: FontWeight.w600)),
                                  Text(
                                    t.categoryId,
                                    style: VerbenaText.body(size: 12, color: VerbenaColors.textMuted),
                                  ),
                                ],
                              ),
                            ),
                            Switch(
                              value: t.isActive,
                              activeThumbColor: VerbenaColors.teal,
                              onChanged: (_) => _toggle(t),
                            ),
                            IconButton(onPressed: () => _delete(t), icon: const Icon(Icons.delete_outline)),
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
