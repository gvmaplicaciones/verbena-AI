import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/verbena_theme.dart';
import '../../../core/utils/navigation.dart';
import '../../../data/repositories/admin_repository.dart';
import 'admin_categories_screen.dart';

const _mimeByExtension = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'webp': 'image/webp',
};

String _mimeFromPath(String path) {
  final ext = path.split('.').last.toLowerCase();
  return _mimeByExtension[ext] ?? 'image/jpeg';
}

enum _CreateMode { generate, upload }

class AdminNewTemplateScreen extends ConsumerStatefulWidget {
  const AdminNewTemplateScreen({super.key});

  @override
  ConsumerState<AdminNewTemplateScreen> createState() => _AdminNewTemplateScreenState();
}

const _templateTypeLabels = {
  TemplateType.aditiva: 'Aditiva (añade algo a la foto)',
  TemplateType.escenaCompleta: 'Escena completa (selfie en otro sitio)',
  TemplateType.composicionGrafica: 'Composición gráfica (cartel/portada)',
};

class _AdminNewTemplateScreenState extends ConsumerState<AdminNewTemplateScreen> {
  final _nameController = TextEditingController();
  final _promptController = TextEditingController();
  final _scenePromptController = TextEditingController();
  String? _categoryId;
  TemplateType _templateType = TemplateType.escenaCompleta;
  _CreateMode _mode = _CreateMode.generate;
  Uint8List? _pickedBytes;
  String? _pickedContentType;
  Uint8List? _objectRefBytes;
  String? _objectRefContentType;
  bool _busy = false;
  String? _error;
  GeneratedTemplatePreview? _preview;

  @override
  void dispose() {
    _nameController.dispose();
    _promptController.dispose();
    _scenePromptController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    setState(() {
      _pickedBytes = bytes;
      _pickedContentType = _mimeFromPath(file.path);
    });
  }

  Future<void> _pickObjectReferenceImage() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    setState(() {
      _objectRefBytes = bytes;
      _objectRefContentType = _mimeFromPath(file.path);
    });
  }

  Future<String?> _uploadObjectReferenceIfNeeded(String categoryId) async {
    final bytes = _objectRefBytes;
    final contentType = _objectRefContentType;
    if (bytes == null || contentType == null) return null;
    return ref.read(adminRepositoryProvider).uploadObjectReferenceImage(
          categoryId: categoryId,
          bytes: bytes,
          contentType: contentType,
        );
  }

  Future<void> _generate() async {
    final categoryId = _categoryId;
    if (categoryId == null ||
        _nameController.text.trim().isEmpty ||
        _promptController.text.trim().isEmpty ||
        _scenePromptController.text.trim().isEmpty) {
      setState(() => _error = 'Rellena categoría, nombre, prompt de miniatura y scene prompt.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final objectReferenceImagePath = await _uploadObjectReferenceIfNeeded(categoryId);
      final preview = await ref.read(adminRepositoryProvider).generateTemplate(
            categoryId: categoryId,
            name: _nameController.text.trim(),
            prompt: _promptController.text.trim(),
            scenePrompt: _scenePromptController.text.trim(),
            templateType: _templateType,
            objectReferenceImagePath: objectReferenceImagePath,
          );
      if (mounted) setState(() => _preview = preview);
    } catch (_) {
      if (mounted) setState(() => _error = 'No se ha podido generar la plantilla.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _upload() async {
    final categoryId = _categoryId;
    final bytes = _pickedBytes;
    final contentType = _pickedContentType;
    if (categoryId == null || _nameController.text.trim().isEmpty || _scenePromptController.text.trim().isEmpty) {
      setState(() => _error = 'Rellena categoría, nombre y scene prompt.');
      return;
    }
    if (bytes == null || contentType == null) {
      setState(() => _error = 'Elige una imagen.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final objectReferenceImagePath = await _uploadObjectReferenceIfNeeded(categoryId);
      final preview = await ref.read(adminRepositoryProvider).uploadTemplateImage(
            categoryId: categoryId,
            name: _nameController.text.trim(),
            scenePrompt: _scenePromptController.text.trim(),
            templateType: _templateType,
            objectReferenceImagePath: objectReferenceImagePath,
            bytes: bytes,
            contentType: contentType,
          );
      if (mounted) setState(() => _preview = preview);
    } catch (_) {
      if (mounted) setState(() => _error = 'No se ha podido subir la imagen.');
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
      if (mounted) context.safePop();
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
    final categoriesAsync = ref.watch(adminCategoriesProvider);
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
                    IconButton(onPressed: () => context.safePop(), icon: const Icon(Icons.arrow_back)),
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
                  DropdownButtonFormField<TemplateType>(
                    initialValue: _templateType,
                    decoration: const InputDecoration(labelText: 'Tipo de plantilla'),
                    items: _templateTypeLabels.entries
                        .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                        .toList(),
                    onChanged: (v) => setState(() => _templateType = v ?? _templateType),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _scenePromptController,
                    minLines: 3,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: 'Scene prompt (instrucción de generación completa)',
                      helperText: 'No hace falta añadir formato ni fidelidad facial, eso lo añade el backend.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _pickObjectReferenceImage,
                    icon: const Icon(Icons.diamond_outlined),
                    label: Text(
                      _objectRefBytes == null
                          ? 'Imagen de referencia de objeto (opcional)'
                          : 'Cambiar imagen de referencia de objeto',
                    ),
                  ),
                  if (_objectRefBytes != null) ...[
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: SizedBox(
                        height: 100,
                        child: Image.memory(_objectRefBytes!, fit: BoxFit.cover),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  SegmentedButton<_CreateMode>(
                    segments: const [
                      ButtonSegment(value: _CreateMode.generate, label: Text('Generar con IA'), icon: Icon(Icons.auto_awesome)),
                      ButtonSegment(value: _CreateMode.upload, label: Text('Subir imagen'), icon: Icon(Icons.upload)),
                    ],
                    selected: {_mode},
                    onSelectionChanged: _busy
                        ? null
                        : (selection) => setState(() {
                              _mode = selection.first;
                              _error = null;
                            }),
                  ),
                  const SizedBox(height: 16),
                  if (_mode == _CreateMode.generate) ...[
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
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _pickImage,
                      icon: const Icon(Icons.image_outlined),
                      label: Text(_pickedBytes == null ? 'Elegir imagen' : 'Cambiar imagen'),
                    ),
                    if (_pickedBytes != null) ...[
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: Image.memory(_pickedBytes!, fit: BoxFit.cover),
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: VerbenaText.body(size: 13, color: VerbenaColors.terracotta)),
                    ],
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _busy ? null : _upload,
                      child: _busy
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('SUBIR Y CREAR PREVIEW'),
                    ),
                  ],
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
