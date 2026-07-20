import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/router/app_routes.dart';
import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../data/models/generation_source.dart';
import '../../../data/models/processing_args.dart';
import '../../../data/models/verified_photo_summary.dart';
import '../../../data/repositories/credits_repository.dart';
import '../../../data/repositories/photo_repository.dart';

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

class PhotoSelectScreen extends ConsumerStatefulWidget {
  const PhotoSelectScreen({super.key, required this.source});

  final GenerationSource source;

  @override
  ConsumerState<PhotoSelectScreen> createState() => _PhotoSelectScreenState();
}

class _PhotoSelectScreenState extends ConsumerState<PhotoSelectScreen> {
  bool _busy = false;

  String get _subtitle {
    final source = widget.source;
    return switch (source) {
      CatalogSource() => 'Vamos a meterte en: ${source.template.name}',
      LibertadSource() => 'Vamos a hacer: “${source.prompt}”',
    };
  }

  Future<void> _pickFrom(ImageSource imageSource) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final file = await ImagePicker().pickImage(source: imageSource, imageQuality: 90);
      if (file == null || !mounted) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      _goToProcessing(bytes: bytes, contentType: _mimeFromPath(file.path));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _goToProcessing({required Uint8List bytes, required String contentType}) {
    context.push(
      AppRoutes.processing,
      extra: ProcessingArgs.fromPhoto(
        source: widget.source,
        photoBytes: bytes,
        contentType: contentType,
      ),
    );
  }

  Future<void> _pickRecentPhoto(VerifiedPhotoSummary photo) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final photoSessionId = await ref.read(photoRepositoryProvider).ensurePhotoSession(photo.id);
      if (!mounted) return;
      context.push(
        AppRoutes.processing,
        extra: ProcessingArgs.fromSession(source: widget.source, photoSessionId: photoSessionId),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final creditsAsync = ref.watch(myCreditsProvider);
    final credits = creditsAsync.valueOrNull;
    final isSubscribed = credits?.isSubscribed ?? false;
    // Catálogo puede tirar del crédito gratis, Libertad no (regla de negocio
    // que ya vive en deduct_credit()) -- si no calzamos allowFree aquí
    // podríamos bloquear a alguien con crédito gratis disponible en modo
    // Catálogo, o dejar pasar a alguien sin crédito real en modo Libertad.
    final allowFree = widget.source is CatalogSource;
    // null mientras carga/si falla el fetch -> no bloqueamos (fail-open),
    // solo bloqueamos cuando sabemos con certeza que no hay créditos.
    final noCredits = credits != null && !credits.hasCreditsFor(allowFree: allowFree);
    final persistedAsync = ref.watch(persistedPhotosProvider);
    final recentPhotos = isSubscribed ? persistedAsync.valueOrNull ?? const [] : const <VerifiedPhotoSummary>[];

    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: _busy || creditsAsync.isLoading,
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
                      child: Text(
                        '¿Con qué foto lo hacemos?',
                        style: VerbenaText.display(size: 20),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text(_subtitle, style: VerbenaText.body(size: 14, color: VerbenaColors.textMuted)),
              ),
              Expanded(
                child: noCredits
                    ? _NoCreditsState(
                        onUpgrade: () => context.push(AppRoutes.paywall, extra: 'photo_select_no_credits'),
                      )
                    : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
                  children: [
                    if (recentPhotos.isNotEmpty) ...[
                      _RecentPhotosSection(photos: recentPhotos, onSelect: _pickRecentPhoto),
                      const SizedBox(height: 16),
                    ],
                    _OptionRow(
                      iconBackground: VerbenaColors.teal,
                      icon: const VerbenaCameraIcon(size: 22, withViewfinderBump: false),
                      title: 'Hacer una foto',
                      subtitle: 'Directa con la cámara',
                      onTap: () => _pickFrom(ImageSource.camera),
                    ),
                    const SizedBox(height: 12),
                    _OptionRow(
                      iconBackground: VerbenaColors.teal,
                      icon: const VerbenaGalleryIcon(size: 22),
                      title: 'Elegir de la galería',
                      subtitle: 'Busca una que te guste',
                      onTap: () => _pickFrom(ImageSource.gallery),
                    ),
                    const SizedBox(height: 12),
                    const _PhotoTipBanner(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Se muestra en vez de las opciones de foto cuando `myCreditsProvider`
/// confirma que no quedan créditos -- evita gastar en el filtro de
/// contenido de Replicate para una generación que el servidor va a
/// rechazar igualmente con 402, y aprovecha el momento para convertir.
class _NoCreditsState extends StatelessWidget {
  const _NoCreditsState({required this.onUpgrade});

  final VoidCallback onUpgrade;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: VerbenaColors.card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: VerbenaColors.textDark.withValues(alpha: 0.12), width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Te has quedado sin créditos', style: VerbenaText.display(size: 17)),
                const SizedBox(height: 8),
                Text(
                  'Hazte socio o compra créditos extra para seguir generando fotos.',
                  style: VerbenaText.body(size: 13.5, color: VerbenaColors.textMuted),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: onUpgrade,
                    child: const Text('VER PLANES'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Aviso pasivo: el face swap (cdingram/face-swap) da peores resultados
/// cuando la foto del usuario lleva gafas y la plantilla no -- no bloquea
/// nada, solo orienta antes de elegir foto.
class _PhotoTipBanner extends StatelessWidget {
  const _PhotoTipBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: VerbenaColors.teal.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, size: 16, color: VerbenaColors.teal),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Para mejores resultados: cara despejada, sin gafas y con buena luz',
              style: VerbenaText.body(size: 12.5, color: VerbenaColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.iconBackground,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final Color iconBackground;
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
          border: Border.all(color: VerbenaColors.textDark.withValues(alpha: 0.12), width: 1.5),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: iconBackground, borderRadius: BorderRadius.circular(12)),
              alignment: Alignment.center,
              child: icon,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: VerbenaText.body(size: 15.5, weight: FontWeight.w700)),
                  Text(subtitle, style: VerbenaText.body(size: 12.5, color: VerbenaColors.textMuted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opción más destacada de PhotoSelect para socios con fotos verificadas
/// guardadas: reutiliza la galería de "Mis fotos verificadas" pero inline y
/// arriba del todo, para saltarse cámara/galería y la verificación entera.
/// Se limita a las últimas [_maxThumbnails] para no desbordar la pantalla.
class _RecentPhotosSection extends StatelessWidget {
  const _RecentPhotosSection({required this.photos, required this.onSelect});

  static const _maxThumbnails = 8;

  final List<VerifiedPhotoSummary> photos;
  final ValueChanged<VerifiedPhotoSummary> onSelect;

  @override
  Widget build(BuildContext context) {
    final shown = photos.take(_maxThumbnails).toList();
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
                decoration: BoxDecoration(color: VerbenaColors.teal, borderRadius: BorderRadius.circular(12)),
                alignment: Alignment.center,
                child: const Icon(Icons.bolt_rounded, size: 20, color: VerbenaColors.background),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Usa una foto reciente', style: VerbenaText.display(size: 16)),
                    Text(
                      'Ya verificada, vamos directos a crear',
                      style: VerbenaText.body(size: 12.5, color: VerbenaColors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
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
            itemCount: shown.length,
            itemBuilder: (context, i) {
              final photo = shown[i];
              return GestureDetector(
                onTap: () => onSelect(photo),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Consumer(
                    builder: (context, ref, _) {
                      final urlAsync = ref.watch(verifiedPhotoUrlProvider(photo.storagePath));
                      return urlAsync.when(
                        loading: () => Container(color: VerbenaColors.card),
                        error: (err, st) => Container(color: VerbenaColors.card),
                        data: (url) => CachedNetworkImage(imageUrl: url, fit: BoxFit.cover),
                      );
                    },
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
