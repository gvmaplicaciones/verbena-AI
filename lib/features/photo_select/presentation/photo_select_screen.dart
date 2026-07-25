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
import '../../../core/widgets/confetti_background.dart';
import '../../../data/models/generation_source.dart';
import '../../../data/models/mask_painter_args.dart';
import '../../../data/models/processing_args.dart';
import '../../../data/models/verified_photo_summary.dart';
import '../../../data/repositories/credits_repository.dart';
import '../../../data/repositories/photo_repository.dart';

const _addElementPromptSuggestions = [
  'Añade una gorra',
  'Ponme un collar de oro',
  'Añade un reloj de lujo en la muñeca',
  'Ponme unas gafas de sol',
  'Añade un ramo de flores en la mano',
];

const _removeElementPromptSuggestions = [
  'Elimina a la persona del fondo',
  'Quita el cartel de la pared',
  'Borra el coche aparcado',
  'Elimina las marcas de agua',
];

const _changeBackgroundPromptSuggestions = [
  'El skyline de Nueva York visto desde un rascacielos',
  'El Coliseo de Roma visto desde dentro',
  'Las luces de Tokio vistas desde una azotea',
  'Una playa tropical al atardecer',
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

/// Una imagen dentro del mostrador de seleccionadas de los modos con prompt
/// libre ("Añadir algo", "Eliminar algo" por texto): o bien bytes recién
/// elegidos de cámara/galería (hace falta verify-photo en ProcessingScreen),
/// o bien una foto ya verificada de "Mis fotos verificadas" (sessionId ya
/// resuelto, se salta la verificación) -- [recentPhotoId] solo se rellena en
/// el segundo caso, para poder marcar la miniatura como seleccionada en la
/// rejilla de recientes.
class _SelectedImage {
  const _SelectedImage.bytes({required this.bytes, required this.contentType})
      : sessionId = null,
        storagePath = null,
        recentPhotoId = null;

  const _SelectedImage.recent({
    required this.sessionId,
    required this.storagePath,
    required this.recentPhotoId,
  })  : bytes = null,
        contentType = null;

  final Uint8List? bytes;
  final String? contentType;
  final String? sessionId;
  final String? storagePath;
  final String? recentPhotoId;
}

class PhotoSelectScreen extends ConsumerStatefulWidget {
  const PhotoSelectScreen({super.key, required this.source});

  final GenerationSource source;

  @override
  ConsumerState<PhotoSelectScreen> createState() => _PhotoSelectScreenState();
}

class _PhotoSelectScreenState extends ConsumerState<PhotoSelectScreen> {
  bool get _isPromptSource => switch (widget.source) {
        AddElementSource() => true,
        RemoveElementSource(mode: RemoveTargetMode.text) => true,
        ChangeBackgroundSource() => true,
        _ => false,
      };

  // gpt-image-2 admite hasta 2 imágenes de referencia en "Añadir algo" (una
  // opcional, para el caso "cambia esto por esto otro") -- no tiene sentido
  // combinar dos fotos para "eliminar algo de una foto", así que ese modo se
  // limita a 1. Ver runImageEdit en supabase/functions/_shared/replicate.ts.
  // "Cambiar fondo" también admite 2: la foto de la persona (obligatoria) y
  // una foto de referencia del lugar de destino (opcional, ver
  // ChangeBackgroundSource y runChangeBackground).
  int get _maxSelectedImages =>
      widget.source is AddElementSource || widget.source is ChangeBackgroundSource
          ? 2
          : 1;

  // "Cambiar fondo": el texto solo es obligatorio si no hay foto de
  // referencia del lugar (segunda foto) -- con foto de referencia el texto es
  // un matiz opcional. El resto de modos con prompt libre siempre lo exigen.
  bool get _canSubmitPrompt {
    if (_selectedImages.isEmpty) return false;
    if (widget.source is ChangeBackgroundSource && _selectedImages.length > 1) {
      return true;
    }
    return _promptController.text.trim().isNotEmpty;
  }

  bool _busy = false;
  final _promptController = TextEditingController();

  // Mostrador de imágenes seleccionadas de los modos con prompt libre: se
  // rellena según el usuario hace fotos, elige de galería o toca fotos
  // recientes, y viaja junto al prompt a ProcessingScreen al pulsar
  // "Generar".
  final List<_SelectedImage> _selectedImages = [];

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  String get _title => switch (widget.source) {
        AddElementSource() => 'Añade algo a tu foto',
        RemoveElementSource() => 'Elimina algo de tu foto',
        ChangeBackgroundSource() => 'Cambia el fondo de tu foto',
        _ => '¿Con qué foto lo hacemos?',
      };

  String get _subtitle => switch (widget.source) {
        CatalogSource(:final template) => 'Vamos a meterte en: ${template.name}',
        AddElementSource() =>
          'Elige hasta 2 fotos y cuéntanos qué quieres añadir',
        RemoveElementSource(mode: RemoveTargetMode.text) =>
          'Elige una foto y cuéntanos qué quieres eliminar',
        RemoveElementSource(mode: RemoveTargetMode.mask) =>
          'Elige la foto en la que quieres borrar algo',
        ChangeBackgroundSource() =>
          'Elige tu foto y describe el lugar, o añade también una foto de referencia',
        TryOnSource() => 'Elige una foto para probarte un look',
      };

  void _showMaxImagesSnackbar() {
    final noun = _maxSelectedImages == 1 ? 'foto' : 'fotos';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Puedes añadir hasta $_maxSelectedImages $noun')),
    );
  }

  void _removeSelectedImage(_SelectedImage image) {
    setState(() => _selectedImages.remove(image));
  }

  Future<void> _pickFrom(ImageSource imageSource) async {
    if (_busy) return;
    if (_isPromptSource && _selectedImages.length >= _maxSelectedImages) {
      _showMaxImagesSnackbar();
      return;
    }
    setState(() => _busy = true);
    try {
      final file =
          await ImagePicker().pickImage(source: imageSource, imageQuality: 90);
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  bool get _isMaskSource =>
      widget.source is RemoveElementSource &&
      (widget.source as RemoveElementSource).mode == RemoveTargetMode.mask;

  void _onPhotoChosen({required Uint8List bytes, required String contentType}) {
    if (_isPromptSource) {
      setState(() {
        _selectedImages
            .add(_SelectedImage.bytes(bytes: bytes, contentType: contentType));
      });
      return;
    }
    if (_isMaskSource) {
      context.push(
        AppRoutes.maskPainter,
        extra: MaskPainterArgs.fromPhoto(
          source: widget.source,
          photoBytes: bytes,
          contentType: contentType,
        ),
      );
      return;
    }
    _goToProcessing(bytes: bytes, contentType: contentType);
  }

  void _goToProcessing(
      {required Uint8List bytes, required String contentType}) {
    context.push(
      AppRoutes.processing,
      extra: ProcessingArgs.fromPhoto(
        source: widget.source,
        photoBytes: bytes,
        contentType: contentType,
      ),
    );
  }

  Future<void> _onRecentPhotoTap(VerifiedPhotoSummary photo) async {
    if (_busy) return;

    if (!_isPromptSource) {
      setState(() => _busy = true);
      try {
        final photoSessionId = await ref
            .read(photoRepositoryProvider)
            .ensurePhotoSession(photo.id);
        if (!mounted) return;
        if (_isMaskSource) {
          context.push(
            AppRoutes.maskPainter,
            extra: MaskPainterArgs.fromSession(
              source: widget.source,
              photoSessionId: photoSessionId,
              storagePath: photo.storagePath,
            ),
          );
        } else {
          context.push(
            AppRoutes.processing,
            extra: ProcessingArgs.fromSession(
                source: widget.source, photoSessionId: photoSessionId),
          );
        }
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }

    final alreadySelected =
        _selectedImages.indexWhere((img) => img.recentPhotoId == photo.id);
    if (alreadySelected != -1) {
      setState(() => _selectedImages.removeAt(alreadySelected));
      return;
    }
    if (_selectedImages.length >= _maxSelectedImages) {
      _showMaxImagesSnackbar();
      return;
    }

    setState(() => _busy = true);
    try {
      final photoSessionId = await ref
          .read(photoRepositoryProvider)
          .ensurePhotoSession(photo.id);
      if (!mounted) return;
      setState(() {
        _selectedImages.add(_SelectedImage.recent(
          sessionId: photoSessionId,
          storagePath: photo.storagePath,
          recentPhotoId: photo.id,
        ));
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _submitPrompt() {
    final prompt = _promptController.text.trim();
    if (!_canSubmitPrompt) return;
    final GenerationSource source = switch (widget.source) {
      AddElementSource() => AddElementSource(prompt),
      ChangeBackgroundSource() => ChangeBackgroundSource(placeText: prompt),
      _ => RemoveElementSource(mode: RemoveTargetMode.text, prompt: prompt),
    };
    final primary = _selectedImages.first;
    final second = _selectedImages.length > 1 ? _selectedImages[1] : null;

    final args = primary.sessionId != null
        ? ProcessingArgs.fromSession(
            source: source,
            photoSessionId: primary.sessionId!,
            secondPhotoBytes: second?.bytes,
            secondContentType: second?.contentType,
            secondPhotoSessionId: second?.sessionId,
          )
        : ProcessingArgs.fromPhoto(
            source: source,
            photoBytes: primary.bytes!,
            contentType: primary.contentType!,
            secondPhotoBytes: second?.bytes,
            secondContentType: second?.contentType,
            secondPhotoSessionId: second?.sessionId,
          );
    context.push(AppRoutes.processing, extra: args);
  }

  @override
  Widget build(BuildContext context) {
    final creditsAsync = ref.watch(myCreditsProvider);
    final credits = creditsAsync.valueOrNull;
    final isSubscribed = credits?.isSubscribed ?? false;
    // Cualquier modo puede tirar del único crédito gratis por usuario (regla
    // de negocio que ya vive en deduct_credit()) -- por eso allowFree es
    // siempre true aquí, no depende del source.
    const allowFree = true;
    // null mientras carga/si falla el fetch -> no bloqueamos (fail-open),
    // solo bloqueamos cuando sabemos con certeza que no hay créditos.
    final noCredits =
        credits != null && !credits.hasCreditsFor(allowFree: allowFree);
    final persistedAsync = ref.watch(persistedPhotosProvider);
    final recentPhotos = isSubscribed
        ? persistedAsync.valueOrNull ?? const []
        : const <VerifiedPhotoSummary>[];

    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: Stack(
        children: [
          const ConfettiBackground(),
          SafeArea(
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
                            _title,
                            style: VerbenaText.display(size: 20),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                    child: Text(_subtitle,
                        style: VerbenaText.body(
                            size: 14, color: VerbenaColors.textMuted)),
                  ),
                  Expanded(
                    child: noCredits
                        ? _NoCreditsState(
                            onUpgrade: () => context.push(AppRoutes.paywall,
                                extra: 'photo_select_no_credits'),
                          )
                        : _isPromptSource
                            ? _buildPromptBody(recentPhotos)
                            : ListView(
                                padding: const EdgeInsets.fromLTRB(
                                    20, 22, 20, 22),
                                children: [
                                  if (recentPhotos.isNotEmpty) ...[
                                    _RecentPhotosSection(
                                        photos: recentPhotos,
                                        onSelect: _onRecentPhotoTap),
                                    const SizedBox(height: 16),
                                  ],
                                  _OptionRow(
                                    iconBackground: VerbenaColors.teal,
                                    icon: const VerbenaCameraIcon(
                                        size: 22, withViewfinderBump: false),
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
        ],
      ),
    );
  }

  /// Pantalla única de los modos con prompt libre ("Añadir algo", "Eliminar
  /// algo" por texto, "Cambiar fondo"): recientes -> hacer foto -> galería ->
  /// prompt, con el mostrador de seleccionadas apareciendo en cuanto hay al
  /// menos una imagen.
  Widget _buildPromptBody(List<VerifiedPhotoSummary> recentPhotos) {
    final selectedIds = _selectedImages
        .map((img) => img.recentPhotoId)
        .whereType<String>()
        .toSet();
    final hasBackgroundReferenceImage =
        widget.source is ChangeBackgroundSource && _selectedImages.length > 1;
    final suggestions = switch (widget.source) {
      AddElementSource() => _addElementPromptSuggestions,
      ChangeBackgroundSource() => _changeBackgroundPromptSuggestions,
      _ => _removeElementPromptSuggestions,
    };
    final promptHint = switch (widget.source) {
      AddElementSource() => 'Describe qué quieres añadir... ej: ponme un collar de oro',
      ChangeBackgroundSource() => hasBackgroundReferenceImage
          ? 'Añade un matiz si quieres (opcional)... ej: que sea de noche'
          : 'Describe el lugar... ej: una playa al atardecer',
      _ => 'Describe qué quieres eliminar... ej: quita el cartel de la pared',
    };

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
      children: [
        if (recentPhotos.isNotEmpty) ...[
          _MultiSelectRecentPhotosSection(
            photos: recentPhotos,
            selectedIds: selectedIds,
            onToggle: _onRecentPhotoTap,
          ),
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
        if (_selectedImages.isNotEmpty) ...[
          const SizedBox(height: 16),
          _SelectedImagesTray(
            images: _selectedImages,
            maxImages: _maxSelectedImages,
            onRemove: _removeSelectedImage,
          ),
        ],
        const SizedBox(height: 20),
        SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: suggestions.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final suggestion = suggestions[i];
              return GestureDetector(
                onTap: () => _promptController.text = suggestion,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: VerbenaColors.card,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                        color: VerbenaColors.textDark.withValues(alpha: 0.15),
                        width: 1.5),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    suggestion,
                    style:
                        VerbenaText.body(size: 12.5, weight: FontWeight.w500),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _promptController,
          minLines: 5,
          maxLines: 8,
          style: VerbenaText.body(size: 15),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: promptHint,
            hintStyle:
                VerbenaText.body(size: 15, color: VerbenaColors.textMuted),
            filled: true,
            fillColor: VerbenaColors.card,
            contentPadding: const EdgeInsets.all(16),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                  color: VerbenaColors.textDark.withValues(alpha: 0.18),
                  width: 1.5),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                  color: VerbenaColors.textDark.withValues(alpha: 0.18),
                  width: 1.5),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: VerbenaColors.teal, width: 1.5),
            ),
          ),
        ),
        if (widget.source is ChangeBackgroundSource) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: VerbenaColors.teal.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '💡 Describe lo que quieres VER, no dónde quieres estar. '
              'Ej: "El skyline de Nueva York visto desde un rascacielos" '
              'en vez de "Estoy en el Empire State"',
              style: VerbenaText.body(size: 12.5, color: VerbenaColors.textMuted),
            ),
          ),
        ],
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _canSubmitPrompt ? _submitPrompt : null,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              textStyle: VerbenaText.display(
                  size: 15, color: VerbenaColors.background, letterSpacing: 0.4),
            ),
            child: const Text('GENERAR'),
          ),
        ),
      ],
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
              border: Border.all(
                  color: VerbenaColors.textDark.withValues(alpha: 0.12),
                  width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Te has quedado sin créditos',
                    style: VerbenaText.display(size: 17)),
                const SizedBox(height: 8),
                Text(
                  'Hazte socio o compra créditos extra para seguir generando fotos.',
                  style: VerbenaText.body(
                      size: 13.5, color: VerbenaColors.textMuted),
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
          const Icon(Icons.info_outline_rounded,
              size: 16, color: VerbenaColors.teal),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Para mejores resultados: cara despejada, sin gafas y con buena luz',
              style:
                  VerbenaText.body(size: 12.5, color: VerbenaColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mostrador de imágenes seleccionadas del modo "Añadir algo" -- aparece en
/// cuanto hay al menos una (recién elegida o de fotos recientes), y viaja
/// junto al prompt a ProcessingScreen. Tope según el modo (ver
/// _PhotoSelectScreenState._maxSelectedImages).
class _SelectedImagesTray extends StatelessWidget {
  const _SelectedImagesTray({
    required this.images,
    required this.onRemove,
    required this.maxImages,
  });

  final List<_SelectedImage> images;
  final ValueChanged<_SelectedImage> onRemove;
  final int maxImages;

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
            'Fotos seleccionadas (${images.length}/$maxImages)',
            style: VerbenaText.body(
                size: 12.5, weight: FontWeight.w600, color: VerbenaColors.textMuted),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final image in images) ...[
                _SelectedImageThumbnail(
                    image: image, onRemove: () => onRemove(image)),
                const SizedBox(width: 10),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _SelectedImageThumbnail extends StatelessWidget {
  const _SelectedImageThumbnail({required this.image, required this.onRemove});

  final _SelectedImage image;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    Widget thumbnail;
    if (image.bytes != null) {
      thumbnail = Image.memory(image.bytes!, fit: BoxFit.cover);
    } else {
      thumbnail = Consumer(
        builder: (context, ref, _) {
          final urlAsync = ref.watch(verifiedPhotoUrlProvider(image.storagePath!));
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
              child: const Icon(Icons.close_rounded,
                  size: 14, color: VerbenaColors.background),
            ),
          ),
        ),
      ],
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
          border: Border.all(
              color: VerbenaColors.textDark.withValues(alpha: 0.12),
              width: 1.5),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                  color: iconBackground,
                  borderRadius: BorderRadius.circular(12)),
              alignment: Alignment.center,
              child: icon,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: VerbenaText.body(
                          size: 15.5, weight: FontWeight.w700)),
                  Text(subtitle,
                      style: VerbenaText.body(
                          size: 12.5, color: VerbenaColors.textMuted)),
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
/// Usada en modos de una sola foto (todo menos los que usan prompt libre --
/// ver _MultiSelectRecentPhotosSection para el equivalente multi-selección).
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
        border: Border.all(
            color: VerbenaColors.teal.withValues(alpha: 0.3), width: 1.5),
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
                    color: VerbenaColors.teal,
                    borderRadius: BorderRadius.circular(12)),
                alignment: Alignment.center,
                child: const Icon(Icons.bolt_rounded,
                    size: 20, color: VerbenaColors.background),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Usa una foto reciente',
                        style: VerbenaText.display(size: 16)),
                    Text(
                      'Ya verificada, vamos directos a crear',
                      style: VerbenaText.body(
                          size: 12.5, color: VerbenaColors.textMuted),
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
                      final urlAsync = ref
                          .watch(verifiedPhotoUrlProvider(photo.storagePath));
                      return urlAsync.when(
                        loading: () => Container(color: VerbenaColors.card),
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
        ],
      ),
    );
  }
}

/// Equivalente a _RecentPhotosSection pero para modos con prompt libre
/// ("Añadir algo", "Eliminar algo" por texto): selección múltiple (hasta
/// _maxSelectedImages, junto con cámara/galería) con estado visual (borde +
/// check) en vez de navegar directo -- toca una vez para añadir al
/// mostrador, toca de nuevo para quitarla.
class _MultiSelectRecentPhotosSection extends StatelessWidget {
  const _MultiSelectRecentPhotosSection({
    required this.photos,
    required this.selectedIds,
    required this.onToggle,
  });

  static const _maxThumbnails = 8;

  final List<VerifiedPhotoSummary> photos;
  final Set<String> selectedIds;
  final ValueChanged<VerifiedPhotoSummary> onToggle;

  @override
  Widget build(BuildContext context) {
    final shown = photos.take(_maxThumbnails).toList();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: VerbenaColors.teal.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: VerbenaColors.teal.withValues(alpha: 0.3), width: 1.5),
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
                    color: VerbenaColors.teal,
                    borderRadius: BorderRadius.circular(12)),
                alignment: Alignment.center,
                child: const Icon(Icons.bolt_rounded,
                    size: 20, color: VerbenaColors.background),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Fotos recientes', style: VerbenaText.display(size: 16)),
                    Text(
                      'Ya verificadas, toca para seleccionar',
                      style: VerbenaText.body(
                          size: 12.5, color: VerbenaColors.textMuted),
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
              final selected = selectedIds.contains(photo.id);
              return GestureDetector(
                onTap: () => onToggle(photo),
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
                          final urlAsync = ref.watch(
                              verifiedPhotoUrlProvider(photo.storagePath));
                          return urlAsync.when(
                            loading: () => Container(color: VerbenaColors.card),
                            error: (err, st) =>
                                Container(color: VerbenaColors.card),
                            data: (url) => CachedNetworkImage(
                                imageUrl: url, fit: BoxFit.cover),
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
      ),
    );
  }
}
