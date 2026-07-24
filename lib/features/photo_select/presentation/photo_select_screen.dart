import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
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

const _libertadPromptSuggestions = [
  'Ponle la camiseta de España a mi perro',
  'Conviértete en superhéroe volando',
  'Añade un dragón detrás de ti',
  'Hazte gigante en Times Square',
  'Ponte un traje de luces',
];

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

enum _Stage { pickPhoto, enterPrompt }

class PhotoSelectScreen extends ConsumerStatefulWidget {
  const PhotoSelectScreen({super.key, required this.source});

  final GenerationSource source;

  @override
  ConsumerState<PhotoSelectScreen> createState() => _PhotoSelectScreenState();
}

class _PhotoSelectScreenState extends ConsumerState<PhotoSelectScreen> {
  bool _busy = false;
  _Stage _stage = _Stage.pickPhoto;
  final _promptController = TextEditingController();

  // Foto ya elegida en modo Libertad, en espera de que el usuario escriba el
  // prompt y pulse "Generar" -- solo entonces se navega a Processing (que es
  // quien dispara verify-photo), para no gastar la verificación con solo
  // elegir foto.
  Uint8List? _pendingBytes;
  String? _pendingContentType;
  String? _pendingSessionId;
  // Solo se rellena cuando la foto principal viene de "Mis fotos
  // verificadas" (sin bytes locales) -- permite previsualizarla en el paso
  // del prompt vía verifiedPhotoUrlProvider, igual que en _RecentPhotosSection.
  String? _pendingStoragePath;

  // Segunda foto opcional de modo Libertad ("cambia esto por esto otro") --
  // siempre bytes recién elegidos, nunca una sesión ya verificada (a
  // diferencia de la principal, que puede venir de "Mis fotos verificadas").
  Uint8List? _pendingSecondBytes;
  String? _pendingSecondContentType;

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  String get _title => _stage == _Stage.enterPrompt ? '¿Qué quieres hacer?' : '¿Con qué foto lo hacemos?';

  String get _subtitle {
    final source = widget.source;
    if (_stage == _Stage.enterPrompt) return 'Escribe qué quieres que hagamos con esta foto';
    return switch (source) {
      CatalogSource() => 'Vamos a meterte en: ${source.template.name}',
      LibertadSource() => 'Elige una foto para empezar',
      AddElementSource() => 'Elige una foto para añadir algo',
      RemoveElementSource() => 'Elige una foto para eliminar algo',
      ChangeBackgroundSource() => 'Elige una foto para cambiar el fondo',
      TryOnSource() => 'Elige una foto para probarte un look',
    };
  }

  void _handleBack() {
    if (_stage == _Stage.enterPrompt) {
      setState(() {
        _stage = _Stage.pickPhoto;
        _pendingBytes = null;
        _pendingContentType = null;
        _pendingSessionId = null;
        _pendingStoragePath = null;
        _pendingSecondBytes = null;
        _pendingSecondContentType = null;
      });
    } else {
      context.pop();
    }
  }

  Future<void> _pickSecondFrom(ImageSource imageSource) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final file = await ImagePicker().pickImage(source: imageSource, imageQuality: 90);
      if (file == null || !mounted) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() {
        _pendingSecondBytes = bytes;
        _pendingSecondContentType = _mimeFromPath(file.path);
      });
    } on PlatformException catch (e) {
      if (mounted) _showPickerError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _removeSecondPhoto() {
    setState(() {
      _pendingSecondBytes = null;
      _pendingSecondContentType = null;
    });
  }

  Future<void> _pickFrom(ImageSource imageSource) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final file = await ImagePicker().pickImage(source: imageSource, imageQuality: 90);
      if (file == null || !mounted) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      _onPhotoChosen(bytes: bytes, contentType: _mimeFromPath(file.path));
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

  void _onPhotoChosen({required Uint8List bytes, required String contentType}) {
    if (widget.source is LibertadSource) {
      setState(() {
        _pendingBytes = bytes;
        _pendingContentType = contentType;
        _pendingSessionId = null;
        _pendingStoragePath = null;
        _stage = _Stage.enterPrompt;
      });
      return;
    }
    _goToProcessing(bytes: bytes, contentType: contentType);
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
      if (widget.source is LibertadSource) {
        setState(() {
          _pendingSessionId = photoSessionId;
          _pendingBytes = null;
          _pendingContentType = null;
          _pendingStoragePath = photo.storagePath;
          _stage = _Stage.enterPrompt;
        });
        return;
      }
      context.push(
        AppRoutes.processing,
        extra: ProcessingArgs.fromSession(source: widget.source, photoSessionId: photoSessionId),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _submitLibertadPrompt() {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) return;
    final source = LibertadSource(prompt);
    if (_pendingSessionId != null) {
      context.push(
        AppRoutes.processing,
        extra: ProcessingArgs.fromSession(
          source: source,
          photoSessionId: _pendingSessionId!,
          secondPhotoBytes: _pendingSecondBytes,
          secondContentType: _pendingSecondContentType,
        ),
      );
    } else {
      context.push(
        AppRoutes.processing,
        extra: ProcessingArgs.fromPhoto(
          source: source,
          photoBytes: _pendingBytes!,
          contentType: _pendingContentType!,
          secondPhotoBytes: _pendingSecondBytes,
          secondContentType: _pendingSecondContentType,
        ),
      );
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
                      onTap: _handleBack,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _title,
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
                child: _stage == _Stage.enterPrompt
                    ? _LibertadPromptStep(
                        controller: _promptController,
                        onSubmit: _submitLibertadPrompt,
                        primaryPhotoBytes: _pendingBytes,
                        primaryPhotoStoragePath: _pendingStoragePath,
                        secondPhotoBytes: _pendingSecondBytes,
                        onPickSecondPhoto: _pickSecondFrom,
                        onRemoveSecondPhoto: _removeSecondPhoto,
                      )
                    : noCredits
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

/// Paso 2 del modo Libertad: se muestra solo tras elegir foto, para no
/// disparar verify-photo (que corre en ProcessingScreen) hasta que el
/// usuario confirme también el prompt con "Generar".
class _LibertadPromptStep extends StatelessWidget {
  const _LibertadPromptStep({
    required this.controller,
    required this.onSubmit,
    required this.primaryPhotoBytes,
    required this.primaryPhotoStoragePath,
    required this.secondPhotoBytes,
    required this.onPickSecondPhoto,
    required this.onRemoveSecondPhoto,
  });

  final TextEditingController controller;
  final VoidCallback onSubmit;
  // Uno de los dos, nunca ambos: bytes si se acaba de elegir de cámara/
  // galería, storagePath si viene de "Mis fotos verificadas" (ver
  // _pickRecentPhoto/_onPhotoChosen en PhotoSelectScreen).
  final Uint8List? primaryPhotoBytes;
  final String? primaryPhotoStoragePath;
  final Uint8List? secondPhotoBytes;
  final ValueChanged<ImageSource> onPickSecondPhoto;
  final VoidCallback onRemoveSecondPhoto;

  Future<void> _chooseSecondPhotoSource(BuildContext context) async {
    final source = await showDialog<ImageSource>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: VerbenaColors.card,
        title: Text('Añadir otra foto', style: VerbenaText.display(size: 17)),
        content: Text(
          '¿De dónde sacamos la segunda foto?',
          style: VerbenaText.body(size: 13.5, color: VerbenaColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(ImageSource.camera),
            child: Text('Cámara', style: VerbenaText.body(size: 13.5, weight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(ImageSource.gallery),
            child: Text(
              'Galería',
              style: VerbenaText.body(size: 13.5, weight: FontWeight.w700, color: VerbenaColors.teal),
            ),
          ),
        ],
      ),
    );
    if (source != null) onPickSecondPhoto(source);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 22),
      children: [
        SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _libertadPromptSuggestions.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final suggestion = _libertadPromptSuggestions[i];
              return GestureDetector(
                onTap: () => controller.text = suggestion,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: VerbenaColors.card,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: VerbenaColors.textDark.withValues(alpha: 0.15), width: 1.5),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    suggestion,
                    style: VerbenaText.body(size: 12.5, weight: FontWeight.w500),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        _SelectedPhotoPreview(bytes: primaryPhotoBytes, storagePath: primaryPhotoStoragePath),
        const SizedBox(height: 14),
        TextField(
          controller: controller,
          minLines: 5,
          maxLines: 8,
          style: VerbenaText.body(size: 15),
          decoration: InputDecoration(
            hintText: 'Describe lo que quieres... ej: ponme a lomos de un toro de cartón piedra',
            hintStyle: VerbenaText.body(size: 15, color: VerbenaColors.textMuted),
            filled: true,
            fillColor: VerbenaColors.card,
            contentPadding: const EdgeInsets.all(16),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: VerbenaColors.textDark.withValues(alpha: 0.18), width: 1.5),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: VerbenaColors.textDark.withValues(alpha: 0.18), width: 1.5),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: VerbenaColors.teal, width: 1.5),
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (secondPhotoBytes == null)
          Builder(
            builder: (context) => GestureDetector(
              onTap: () => _chooseSecondPhotoSource(context),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: VerbenaColors.textDark.withValues(alpha: 0.18), width: 1.5),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.add_photo_alternate_outlined, size: 18, color: VerbenaColors.textMuted),
                    const SizedBox(width: 8),
                    Text(
                      'Añadir otra foto (opcional)',
                      style: VerbenaText.body(size: 13.5, weight: FontWeight.w600, color: VerbenaColors.textMuted),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: VerbenaColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: VerbenaColors.textDark.withValues(alpha: 0.15), width: 1.5),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.memory(secondPhotoBytes!, width: 44, height: 44, fit: BoxFit.cover),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Segunda foto añadida',
                    style: VerbenaText.body(size: 13.5, weight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  onPressed: onRemoveSecondPhoto,
                  icon: const Icon(Icons.close_rounded, size: 20, color: VerbenaColors.textMuted),
                ),
              ],
            ),
          ),
        const SizedBox(height: 14),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            final prompt = value.text.trim();
            return SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: prompt.isEmpty ? null : onSubmit,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  textStyle: VerbenaText.display(size: 15, color: VerbenaColors.background, letterSpacing: 0.4),
                ),
                child: const Text('GENERAR'),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Previsualiza la foto principal ya elegida, encima del prompt -- bytes
/// locales si viene de cámara/galería, o `verifiedPhotoUrlProvider` (misma
/// fuente que _RecentPhotosSection) si viene de "Mis fotos verificadas".
class _SelectedPhotoPreview extends StatelessWidget {
  const _SelectedPhotoPreview({required this.bytes, required this.storagePath});

  final Uint8List? bytes;
  final String? storagePath;

  @override
  Widget build(BuildContext context) {
    Widget thumbnail;
    if (bytes != null) {
      thumbnail = Image.memory(bytes!, fit: BoxFit.cover);
    } else if (storagePath != null) {
      thumbnail = Consumer(
        builder: (context, ref, _) {
          final urlAsync = ref.watch(verifiedPhotoUrlProvider(storagePath!));
          return urlAsync.when(
            loading: () => Container(color: VerbenaColors.card),
            error: (err, st) => Container(color: VerbenaColors.card),
            data: (url) => CachedNetworkImage(imageUrl: url, fit: BoxFit.cover),
          );
        },
      );
    } else {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: VerbenaColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: VerbenaColors.textDark.withValues(alpha: 0.15), width: 1.5),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(width: 44, height: 44, child: thumbnail),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text('Foto seleccionada', style: VerbenaText.body(size: 13.5, weight: FontWeight.w600)),
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
