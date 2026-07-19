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

  Future<void> _pickVerificadas(bool isSubscribed) async {
    if (!isSubscribed) {
      context.push(AppRoutes.paywall, extra: 'photo_select');
      return;
    }
    final selected = await showModalBottomSheet<VerifiedPhotoSummary>(
      context: context,
      backgroundColor: VerbenaColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => const _VerifiedPhotosSheet(),
    );
    if (selected == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final repo = ref.read(photoRepositoryProvider);
      final bytes = await repo.downloadBytes(selected.storagePath);
      if (!mounted) return;
      _goToProcessing(bytes: bytes, contentType: repo.contentTypeForPath(selected.storagePath));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final creditsAsync = ref.watch(myCreditsProvider);
    final isSubscribed = creditsAsync.valueOrNull?.isSubscribed ?? false;
    final persistedAsync = ref.watch(persistedPhotosProvider);
    final persistedCount = persistedAsync.valueOrNull?.length;

    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: SafeArea(
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
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
                  children: [
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
                    _OptionRow(
                      iconBackground: isSubscribed
                          ? VerbenaColors.teal
                          : VerbenaColors.textDark.withValues(alpha: 0.3),
                      icon: const VerbenaLockIcon(size: 20),
                      title: 'Mis fotos verificadas',
                      // El handoff traía "4 fotos guardadas" fijo -- bug de
                      // contenido, el numero real depende de cuantas fotos
                      // persistidas tenga el usuario.
                      subtitle: isSubscribed
                          ? (persistedCount == null
                              ? 'Cargando...'
                              : persistedCount == 0
                                  ? 'Aún no tienes fotos guardadas'
                                  : '$persistedCount ${persistedCount == 1 ? "foto guardada" : "fotos guardadas"}')
                          : 'Disponible para socios',
                      trailing: !isSubscribed
                          ? Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: VerbenaColors.terracotta.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                'SOLO SOCIOS',
                                style: VerbenaText.body(
                                  size: 10.5,
                                  weight: FontWeight.w700,
                                  color: VerbenaColors.terracotta,
                                ),
                              ),
                            )
                          : null,
                      onTap: () => _pickVerificadas(isSubscribed),
                    ),
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

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.iconBackground,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
  });

  final Color iconBackground;
  final Widget icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;

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
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

class _VerifiedPhotosSheet extends ConsumerWidget {
  const _VerifiedPhotosSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photosAsync = ref.watch(persistedPhotosProvider);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Mis fotos verificadas', style: VerbenaText.display(size: 18)),
            const SizedBox(height: 16),
            photosAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (err, st) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text('No se pudieron cargar tus fotos.', style: VerbenaText.body()),
              ),
              data: (photos) {
                if (photos.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Text(
                      'Aún no tienes fotos verificadas guardadas. Se guardan automáticamente la próxima vez que verifiques una siendo socio.',
                      style: VerbenaText.body(size: 13.5, color: VerbenaColors.textMuted),
                    ),
                  );
                }
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1,
                  ),
                  itemCount: photos.length,
                  itemBuilder: (context, i) {
                    final photo = photos[i];
                    return GestureDetector(
                      onTap: () => Navigator.of(context).pop(photo),
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
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
