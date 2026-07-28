import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/router/app_routes.dart';
import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../core/utils/image_orientation.dart';
import '../../../core/widgets/confetti_background.dart';
import '../../../data/models/garment.dart';
import '../../../data/models/garment_select_args.dart';
import '../../../data/models/processing_args.dart';
import '../../../data/repositories/credits_repository.dart';
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

/// Modo "Probar un look" (FASE 5): segunda pantalla del flujo, tras elegir la
/// foto de la persona en PhotoSelectScreen. Hasta 4 prendas, mezclando dos
/// orígenes -- nuevas (cámara/galería, sin verificar todavía, eso lo hace
/// ProcessingScreen) y del Armario (ya verificadas, solo socios con
/// suscripción activa). Mismo límite que valida generate-try-on server-side.
class GarmentSelectScreen extends ConsumerStatefulWidget {
  const GarmentSelectScreen({super.key, required this.args});

  final GarmentSelectArgs args;

  static const maxGarments = 4;

  @override
  ConsumerState<GarmentSelectScreen> createState() => _GarmentSelectScreenState();
}

class _GarmentSelectScreenState extends ConsumerState<GarmentSelectScreen> {
  final List<GarmentPick> _picks = [];
  bool _busy = false;

  void _showMaxSnackbar() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Puedes probar hasta ${GarmentSelectScreen.maxGarments} prendas a la vez')),
    );
  }

  void _removePick(GarmentPick pick) {
    setState(() => _picks.remove(pick));
  }

  void _toggleWardrobeGarment(Garment garment) {
    final index = _picks.indexWhere(
      (p) => p is GarmentPickWardrobe && p.garmentId == garment.id,
    );
    if (index != -1) {
      setState(() => _picks.removeAt(index));
      return;
    }
    if (_picks.length >= GarmentSelectScreen.maxGarments) {
      _showMaxSnackbar();
      return;
    }
    setState(() {
      _picks.add(GarmentPickWardrobe(
        garmentId: garment.id,
        storagePath: garment.storagePath,
      ));
    });
  }

  Future<void> _goToWardrobe() async {
    await context.push(AppRoutes.wardrobe);
    if (mounted) ref.invalidate(garmentsProvider);
  }

  Future<void> _pickFrom(ImageSource imageSource) async {
    if (_busy) return;
    if (_picks.length >= GarmentSelectScreen.maxGarments) {
      _showMaxSnackbar();
      return;
    }
    setState(() => _busy = true);
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
      setState(() {
        _picks.add(GarmentPickBytes(bytes: bytes, contentType: contentType));
      });
    } on PlatformException catch (e) {
      if (mounted) _showPickerError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showPickerError(PlatformException e) {
    final message = e.code == 'camera_access_denied'
        ? 'Activa el permiso de cámara para VerbenAI desde los ajustes del móvil.'
        : 'No hemos podido acceder a la foto. Inténtalo de nuevo.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _submit() {
    if (_picks.isEmpty) return;
    final args = widget.args;
    final processingArgs = args.photoSessionId != null
        ? ProcessingArgs.fromSession(
            source: args.source,
            photoSessionId: args.photoSessionId!,
            garmentPicks: _picks,
          )
        : ProcessingArgs.fromPhoto(
            source: args.source,
            photoBytes: args.photoBytes!,
            contentType: args.contentType!,
            garmentPicks: _picks,
          );
    context.push(AppRoutes.processing, extra: processingArgs);
  }

  @override
  Widget build(BuildContext context) {
    final creditsAsync = ref.watch(myCreditsProvider);
    final isSubscribed = creditsAsync.valueOrNull?.isSubscribed ?? false;
    final garmentsAsync = isSubscribed ? ref.watch(garmentsProvider) : null;
    final wardrobeGarments = (garmentsAsync?.valueOrNull ?? const <Garment>[])
        .where((g) => g.storagePath != null)
        .toList();
    final selectedWardrobeIds = _picks
        .whereType<GarmentPickWardrobe>()
        .map((p) => p.garmentId)
        .toSet();

    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: Stack(
        children: [
          const ConfettiBackground(),
          SafeArea(
            child: AbsorbPointer(
              absorbing: _busy,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: Row(
                      children: [
                        VerbenaRoundIconButton(
                          icon: const VerbenaBackChevronIcon(),
                          onTap: () => context.pop(),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text('Elige las prendas',
                              style: VerbenaText.display(size: 20)),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                    child: Text(
                      'Hasta ${GarmentSelectScreen.maxGarments} prendas -- sube fotos nuevas'
                      '${isSubscribed ? ' o elige del Armario' : ''}',
                      style: VerbenaText.body(size: 14, color: VerbenaColors.textMuted),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
                      children: [
                        if (_picks.isNotEmpty) ...[
                          _SelectedGarmentsTray(picks: _picks, onRemove: _removePick),
                          const SizedBox(height: 16),
                        ],
                        _OptionRow(
                          icon: const VerbenaCameraIcon(size: 22, withViewfinderBump: false),
                          title: 'Hacer una foto',
                          subtitle: 'Directa con la cámara',
                          onTap: () => _pickFrom(ImageSource.camera),
                        ),
                        const SizedBox(height: 12),
                        _OptionRow(
                          icon: const VerbenaGalleryIcon(size: 22),
                          title: 'Elegir de la galería',
                          subtitle: 'Busca la prenda que quieras',
                          onTap: () => _pickFrom(ImageSource.gallery),
                        ),
                        if (isSubscribed) ...[
                          const SizedBox(height: 16),
                          _WardrobeSection(
                            garments: wardrobeGarments,
                            selectedIds: selectedWardrobeIds,
                            onToggle: _toggleWardrobeGarment,
                            onGoToWardrobe: _goToWardrobe,
                          ),
                        ],
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _picks.isNotEmpty ? _submit : null,
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 15),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14)),
                              textStyle: VerbenaText.display(
                                  size: 15,
                                  color: VerbenaColors.background,
                                  letterSpacing: 0.4),
                            ),
                            child: const Text('PROBAR EL LOOK'),
                          ),
                        ),
                      ],
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

class _SelectedGarmentsTray extends StatelessWidget {
  const _SelectedGarmentsTray({required this.picks, required this.onRemove});

  final List<GarmentPick> picks;
  final ValueChanged<GarmentPick> onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: VerbenaColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: VerbenaColors.textDark.withValues(alpha: 0.12), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Prendas seleccionadas (${picks.length}/${GarmentSelectScreen.maxGarments})',
            style: VerbenaText.body(
                size: 12.5, weight: FontWeight.w600, color: VerbenaColors.textMuted),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final pick in picks)
                _SelectedGarmentThumbnail(pick: pick, onRemove: () => onRemove(pick)),
            ],
          ),
        ],
      ),
    );
  }
}

class _SelectedGarmentThumbnail extends StatelessWidget {
  const _SelectedGarmentThumbnail({required this.pick, required this.onRemove});

  final GarmentPick pick;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    Widget thumbnail;
    switch (pick) {
      case GarmentPickBytes(:final bytes):
        thumbnail = Image.memory(bytes, fit: BoxFit.cover);
      case GarmentPickWardrobe(:final storagePath):
        thumbnail = storagePath == null
            ? Container(color: VerbenaColors.background)
            : Consumer(
                builder: (context, ref, _) {
                  final urlAsync = ref.watch(garmentUrlProvider(storagePath));
                  return urlAsync.when(
                    loading: () => Container(color: VerbenaColors.background),
                    error: (err, st) => Container(color: VerbenaColors.background),
                    data: (url) => CachedNetworkImage(imageUrl: url, fit: BoxFit.cover),
                  );
                },
              );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(width: 64, height: 64, child: thumbnail),
        ),
        Positioned(
          top: -6,
          right: -6,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              width: 22,
              height: 22,
              decoration: const BoxDecoration(
                  color: VerbenaColors.terracotta, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: const Icon(Icons.close_rounded, size: 14, color: VerbenaColors.background),
            ),
          ),
        ),
      ],
    );
  }
}

class _WardrobeSection extends StatelessWidget {
  const _WardrobeSection({
    required this.garments,
    required this.selectedIds,
    required this.onToggle,
    required this.onGoToWardrobe,
  });

  final List<Garment> garments;
  final Set<String> selectedIds;
  final ValueChanged<Garment> onToggle;
  final VoidCallback onGoToWardrobe;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: VerbenaColors.teal.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VerbenaColors.teal.withValues(alpha: 0.3), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                    color: VerbenaColors.teal, borderRadius: BorderRadius.circular(12)),
                alignment: Alignment.center,
                child: const Icon(Icons.checkroom_rounded,
                    size: 20, color: VerbenaColors.background),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Desde el Armario', style: VerbenaText.display(size: 16)),
                    Text(
                      garments.isEmpty
                          ? 'Guarda prendas para usarlas aquí'
                          : 'Ya verificadas, toca para seleccionar',
                      style: VerbenaText.body(size: 12.5, color: VerbenaColors.textMuted),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: onGoToWardrobe,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'Gestionar',
                  style: VerbenaText.body(
                      size: 13, color: VerbenaColors.teal, weight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (garments.isEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Todavía no tienes prendas guardadas en el Armario.',
              style: VerbenaText.body(size: 13, color: VerbenaColors.textMuted),
            ),
          ] else ...[
            const SizedBox(height: 14),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1,
              ),
              itemCount: garments.length,
              itemBuilder: (context, i) {
                final garment = garments[i];
                final selected = selectedIds.contains(garment.id);
                return GestureDetector(
                  onTap: () => onToggle(garment),
                  child: Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: selected ? VerbenaColors.teal : Colors.transparent,
                        width: 3,
                      ),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Consumer(
                          builder: (context, ref, _) {
                            final urlAsync =
                                ref.watch(garmentUrlProvider(garment.storagePath!));
                            return urlAsync.when(
                              loading: () => Container(color: VerbenaColors.card),
                              error: (err, st) => Container(color: VerbenaColors.card),
                              data: (url) =>
                                  CachedNetworkImage(imageUrl: url, fit: BoxFit.cover),
                            );
                          },
                        ),
                        if (selected)
                          Container(
                            color: VerbenaColors.teal.withValues(alpha: 0.35),
                            alignment: Alignment.center,
                            child: const Icon(Icons.check_circle_rounded,
                                color: VerbenaColors.background, size: 22),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ],
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
