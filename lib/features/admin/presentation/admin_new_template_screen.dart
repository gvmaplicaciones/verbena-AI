import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/verbena_theme.dart';
import '../../../data/repositories/admin_repository.dart';
import '../../../data/repositories/templates_repository.dart';

class AdminNewTemplateScreen extends ConsumerStatefulWidget {
  const AdminNewTemplateScreen({super.key});

  @override
  ConsumerState<AdminNewTemplateScreen> createState() => _AdminNewTemplateScreenState();
}

class _AdminNewTemplateScreenState extends ConsumerState<AdminNewTemplateScreen> {
  final _nameController = TextEditingController();
  final _promptController = TextEditingController();
  String? _categoryId;
  bool _busy = false;
  String? _error;
  GeneratedTemplatePreview? _preview;

  @override
  void dispose() {
    _nameController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final categoryId = _categoryId;
    if (categoryId == null || _nameController.text.trim().isEmpty || _promptController.text.trim().isEmpty) {
      setState(() => _error = 'Rellena categoría, nombre y prompt.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final preview = await ref.read(adminRepositoryProvider).generateTemplate(
            categoryId: categoryId,
            name: _nameController.text.trim(),
            prompt: _promptController.text.trim(),
          );
      if (mounted) setState(() => _preview = preview);
    } catch (_) {
      if (mounted) setState(() => _error = 'No se ha podido generar la plantilla.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approve() async {
    final preview = _preview;
    if (preview == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(adminRepositoryProvider).setActive(preview.templateId, true);
      if (mounted) context.pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _discard() async {
    final preview = _preview;
    if (preview == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(adminRepositoryProvider).deleteTemplate(preview.templateId, preview.imageStoragePath);
      if (mounted) setState(() => _preview = null);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(templateCategoriesProvider);
    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: _busy,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconButton(onPressed: () => context.pop(), icon: const Icon(Icons.arrow_back)),
                    const SizedBox(width: 4),
                    Text('Nueva plantilla', style: VerbenaText.display(size: 19)),
                  ],
                ),
                const SizedBox(height: 16),
                if (_preview == null) ...[
                  categoriesAsync.when(
                    loading: () => const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: CircularProgressIndicator(color: VerbenaColors.teal),
                    ),
                    error: (err, st) => Text(
                      'No se pudieron cargar las categorías.',
                      style: VerbenaText.body(size: 13, color: VerbenaColors.textMuted),
                    ),
                    data: (categories) => DropdownButtonFormField<String>(
                      initialValue: _categoryId,
                      decoration: const InputDecoration(labelText: 'Categoría'),
                      items: categories
                          .map((c) => DropdownMenuItem(value: c.id, child: Text(c.label)))
                          .toList(),
                      onChanged: (v) => setState(() => _categoryId = v),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: 'Nombre'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _promptController,
                    minLines: 3,
                    maxLines: 6,
                    decoration: const InputDecoration(labelText: 'Prompt'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: VerbenaText.body(size: 13, color: VerbenaColors.terracotta)),
                  ],
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _busy ? null : _generate,
                    child: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('GENERAR PREVIEW'),
                  ),
                ] else ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: CachedNetworkImage(imageUrl: _preview!.previewUrl, fit: BoxFit.cover),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _busy ? null : _discard,
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: VerbenaColors.terracotta, width: 2),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            padding: const EdgeInsets.symmetric(vertical: 15),
                          ),
                          child: Text('DESCARTAR', style: VerbenaText.display(size: 14, color: VerbenaColors.terracotta)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _busy ? null : _approve,
                          child: const Text('APROBAR Y ACTIVAR'),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
