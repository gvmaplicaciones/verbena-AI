import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../core/utils/image_orientation.dart';
import '../../../core/utils/navigation.dart';
import '../../../core/widgets/confetti_background.dart';
import '../../../data/models/garment.dart';
import '../../../data/repositories/garment_repository.dart';

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

/// Armario (FASE 5, solo socios) -- grid de prendas guardadas, accesible
/// desde ProfileScreen. Subir pasa por moderación server-side (upload-garment)
/// antes de aparecer aquí; el límite de 30 lo valida el backend, este cliente
/// solo refleja el conteo y el error 409 si se alcanza.
class WardrobeScreen extends ConsumerStatefulWidget {
  const WardrobeScreen({super.key});

  static const maxGarments = 30;

  @override
  ConsumerState<WardrobeScreen> createState() => _WardrobeScreenState();
}

class _WardrobeScreenState extends ConsumerState<WardrobeScreen> {
  bool _uploading = false;

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickFrom(ImageSource imageSource) async {
    if (_uploading) return;
    setState(() => _uploading = true);
    try {
      final file = await ImagePicker().pickImage(source: imageSource, imageQuality: 90);
      if (file == null || !mounted) return;
      final contentType = _mimeFromPath(file.path);
      Uint8List bytes = await file.readAsBytes();
      if (!mounted) return;
      if (contentType == 'image/jpeg') {
        bytes = await compute(normalizeJpegOrientation, bytes);
        if (!mounted) return;
      }
      await ref.read(garmentRepositoryProvider).uploadGarment(
            bytes: bytes,
            contentType: contentType,
          );
      if (!mounted) return;
      ref.invalidate(garmentsProvider);
    } on PlatformException catch (e) {
      final message = e.code == 'camera_access_denied'
          ? 'Activa el permiso de cámara para VerbenAI desde los ajustes del móvil.'
          : 'No hemos podido acceder a la foto. Inténtalo de nuevo.';
      _showSnack(message);
    } on GarmentRejectedException catch (e) {
      _showSnack(e.message);
    } on GarmentException catch (e) {
      _showSnack(e.message);
    } catch (_) {
      _showSnack('No hemos podido subir la prenda. Inténtalo otra vez.');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _deleteGarment(Garment garment) async {
    try {
      await ref.read(garmentRepositoryProvider).deleteGarment(garment.id);
      ref.invalidate(garmentsProvider);
    } catch (_) {
      _showSnack('No hemos podido borrar la prenda. Inténtalo otra vez.');
    }
  }

  Future<void> _openFullscreen(Garment garment) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _GarmentFullscreenView(
          garment: garment,
          onDelete: () => _deleteGarment(garment),
        ),
      ),
    );
  }

  void _showAddOptions() {
    if (_uploading) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: VerbenaColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Añadir prenda', style: VerbenaText.display(size: 18)),
              const SizedBox(height: 16),
              _OptionRow(
                icon: const VerbenaCameraIcon(size: 22, withViewfinderBump: false),
                title: 'Hacer una foto',
                subtitle: 'Directa con la cámara',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _pickFrom(ImageSource.camera);
                },
              ),
              const SizedBox(height: 12),
              _OptionRow(
                icon: const VerbenaGalleryIcon(size: 22),
                title: 'Elegir de la galería',
                subtitle: 'Busca la prenda que quieras',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _pickFrom(ImageSource.gallery);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final garmentsAsync = ref.watch(garmentsProvider);
    final garments = garmentsAsync.valueOrNull ?? const <Garment>[];
    final atMax = garments.length >= WardrobeScreen.maxGarments;

    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: Stack(
        children: [
          const ConfettiBackground(),
          SafeArea(
            child: AbsorbPointer(
              absorbing: _uploading,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: Row(
                      children: [
                        VerbenaRoundIconButton(
                          icon: const VerbenaBackChevronIcon(),
                          onTap: () => context.safePop(),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text('Armario', style: VerbenaText.display(size: 22)),
                        ),
                        if (_uploading)
                          const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.5, color: VerbenaColors.teal),
                          )
                        else
                          VerbenaRoundIconButton(
                            icon: Icon(Icons.add_rounded,
                                color: atMax
                                    ? VerbenaColors.textMuted
                                    : VerbenaColors.textDark),
                            onTap: atMax
                                ? () => _showSnack(
                                    'Has alcanzado el máximo de ${WardrobeScreen.maxGarments} prendas.')
                                : _showAddOptions,
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                    child: Text(
                      '${garments.length}/${WardrobeScreen.maxGarments} prendas guardadas',
                      style: VerbenaText.body(size: 14, color: VerbenaColors.textMuted),
                    ),
                  ),
                  Expanded(
                    child: garmentsAsync.when(
                      loading: () => const Center(
                          child: CircularProgressIndicator(color: VerbenaColors.teal)),
                      error: (err, st) => Center(
                        child: Text('No hemos podido cargar tu Armario.',
                            style: VerbenaText.body()),
                      ),
                      data: (_) => garments.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(32),
                              child: Center(
                                child: Text(
                                  'Aún no tienes prendas guardadas. Añade la primera con el botón +.',
                                  textAlign: TextAlign.center,
                                  style: VerbenaText.body(
                                      size: 14, color: VerbenaColors.textMuted),
                                ),
                              ),
                            )
                          : GridView.builder(
                              padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                mainAxisSpacing: 10,
                                crossAxisSpacing: 10,
                                childAspectRatio: 1,
                              ),
                              itemCount: garments.length,
                              itemBuilder: (context, i) {
                                final garment = garments[i];
                                return GestureDetector(
                                  onTap: () => _openFullscreen(garment),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: garment.storagePath == null
                                        ? Container(color: VerbenaColors.card)
                                        : Consumer(
                                            builder: (context, ref, _) {
                                              final urlAsync = ref.watch(
                                                  garmentUrlProvider(garment.storagePath!));
                                              return urlAsync.when(
                                                loading: () =>
                                                    Container(color: VerbenaColors.card),
                                                error: (err, st) =>
                                                    Container(color: VerbenaColors.card),
                                                data: (url) => CachedNetworkImage(
                                                    imageUrl: url, fit: BoxFit.cover),
                                              );
                                            },
                                          ),
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
        ],
      ),
    );
  }
}

class _GarmentFullscreenView extends ConsumerWidget {
  const _GarmentFullscreenView({required this.garment, required this.onDelete});

  final Garment garment;
  final VoidCallback onDelete;

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: VerbenaColors.card,
        title: Text('Borrar prenda', style: VerbenaText.display(size: 17)),
        content: Text(
          'Se eliminará esta prenda de tu Armario. Esta acción no se puede deshacer.',
          style: VerbenaText.body(size: 13.5, color: VerbenaColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancelar',
                style: VerbenaText.body(size: 13.5, weight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Borrar',
                style: VerbenaText.body(
                    size: 13.5, weight: FontWeight.w700, color: VerbenaColors.terracotta)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      onDelete();
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storagePath = garment.storagePath;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: storagePath == null
                  ? const SizedBox.shrink()
                  : Consumer(
                      builder: (context, ref, _) {
                        final urlAsync = ref.watch(garmentUrlProvider(storagePath));
                        return urlAsync.when(
                          loading: () =>
                              const CircularProgressIndicator(color: VerbenaColors.teal),
                          error: (err, st) => Text('No se pudo cargar la imagen.',
                              style: VerbenaText.body(color: Colors.white)),
                          data: (url) =>
                              CachedNetworkImage(imageUrl: url, fit: BoxFit.contain),
                        );
                      },
                    ),
            ),
            Positioned(
              top: 8,
              left: 8,
              child: VerbenaRoundIconButton(
                icon: const Icon(Icons.close_rounded, color: VerbenaColors.textDark),
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: VerbenaRoundIconButton(
                icon: const Icon(Icons.delete_outline_rounded,
                    color: VerbenaColors.terracotta),
                onTap: () => _confirmDelete(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final Widget icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: VerbenaColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: VerbenaColors.textDark.withValues(alpha: 0.12), width: 1.5),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                  color: VerbenaColors.teal, borderRadius: BorderRadius.circular(12)),
              alignment: Alignment.center,
              child: icon,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: VerbenaText.body(size: 15.5, weight: FontWeight.w700)),
                  Text(subtitle,
                      style: VerbenaText.body(size: 12.5, color: VerbenaColors.textMuted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
