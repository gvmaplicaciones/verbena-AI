import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show consolidateHttpClientResponseBytes;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';

import '../../../core/theme/verbena_theme.dart';
import '../../../data/models/generation_summary.dart';
import '../../../data/models/verified_photo_summary.dart';
import '../../../data/repositories/generations_repository.dart';
import '../../../data/repositories/photo_repository.dart';
import '../../result/presentation/generation_actions.dart';

/// Grid de fotos verificadas guardadas. [limit] recorta la vista previa
/// (perfil, últimas 5) -- sin límite se usa en la pantalla completa
/// (VerifiedPhotosScreen), ambas reutilizan este mismo widget.
class VerifiedPhotosGrid extends ConsumerWidget {
  const VerifiedPhotosGrid({super.key, required this.persistedAsync, this.limit});

  final AsyncValue<List<VerifiedPhotoSummary>> persistedAsync;
  final int? limit;

  void _showDetail(BuildContext context, VerifiedPhotoSummary photo) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: VerbenaColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => VerifiedPhotoDetailSheet(photo: photo),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return persistedAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (err, st) => Text(
        'No se pudieron cargar tus fotos.',
        style: VerbenaText.body(size: 13, color: VerbenaColors.textMuted),
      ),
      data: (allPhotos) {
        if (allPhotos.isEmpty) {
          return Text(
            'Aún no tienes fotos verificadas guardadas.',
            style: VerbenaText.body(size: 13, color: VerbenaColors.textMuted),
          );
        }
        final photos =
            limit == null ? allPhotos : allPhotos.take(limit!).toList();
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
              onTap: () => _showDetail(context, photo),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Consumer(
                  builder: (context, ref, _) {
                    final urlAsync =
                        ref.watch(verifiedPhotoUrlProvider(photo.storagePath));
                    return urlAsync.when(
                      loading: () => Container(color: VerbenaColors.card),
                      error: (err, st) => Container(color: VerbenaColors.card),
                      data: (url) =>
                          CachedNetworkImage(imageUrl: url, fit: BoxFit.cover),
                    );
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Grid de creaciones. [limit] recorta la vista previa (perfil, últimas 5);
/// sin límite se usa en la pantalla completa (MyCreationsScreen) y en
/// FavoritesScreen (con la lista ya filtrada por isFavorite).
class MyCreationsGrid extends ConsumerWidget {
  const MyCreationsGrid({super.key, required this.generations, this.limit});

  final List<GenerationSummary> generations;
  final int? limit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (generations.isEmpty) {
      return Text(
        'Aún no tienes creaciones. ¡Genera tu primera foto!',
        style: VerbenaText.body(size: 13, color: VerbenaColors.textMuted),
      );
    }
    final shown =
        limit == null ? generations : generations.take(limit!).toList();
    return GridView.builder(
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
        final gen = shown[i];
        return GestureDetector(
          onTap: () => _showDetail(context, gen),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Consumer(
                  builder: (context, ref, _) {
                    final urlAsync =
                        ref.watch(generationResultUrlProvider(gen.storagePath));
                    return urlAsync.when(
                      loading: () => Container(color: VerbenaColors.card),
                      error: (_, __) => Container(color: VerbenaColors.card),
                      data: (url) =>
                          CachedNetworkImage(imageUrl: url, fit: BoxFit.cover),
                    );
                  },
                ),
              ),
              if (gen.isFavorite)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.star, size: 12, color: Colors.amber),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  void _showDetail(BuildContext context, GenerationSummary gen) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: VerbenaColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => CreationDetailSheet(generation: gen),
    );
  }
}

class CreationDetailSheet extends ConsumerStatefulWidget {
  const CreationDetailSheet({super.key, required this.generation});

  final GenerationSummary generation;

  @override
  ConsumerState<CreationDetailSheet> createState() => _CreationDetailSheetState();
}

class _CreationDetailSheetState extends ConsumerState<CreationDetailSheet> {
  late bool _isFavorite;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _isFavorite = widget.generation.isFavorite;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _toggleFavorite() async {
    if (_busy) return;
    final repo = ref.read(generationsRepositoryProvider);

    if (!_isFavorite) {
      setState(() => _busy = true);
      try {
        await repo.toggleFavorite(widget.generation.id, true);
        if (mounted) {
          setState(() => _isFavorite = true);
          ref.invalidate(myGenerationsProvider);
        }
      } on FavoriteLimitException {
        _showSnack('Ya tienes 10 favoritas — quita alguna antes de marcar otra');
      } catch (_) {
        _showSnack('No hemos podido marcar la favorita. Inténtalo otra vez.');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    } else {
      setState(() => _busy = true);
      bool willBeDeleted;
      try {
        willBeDeleted = await repo.hasThirtyOrMoreNonFavoritesNewerThan(
          widget.generation.id,
          widget.generation.createdAt,
        );
      } catch (_) {
        if (mounted) setState(() => _busy = false);
        _showSnack('No hemos podido verificar el estado. Inténtalo otra vez.');
        return;
      }
      if (!mounted) return;
      setState(() => _busy = false);

      if (willBeDeleted) {
        final download = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: VerbenaColors.card,
            title: Text('Esta imagen se eliminará', style: VerbenaText.display(size: 17)),
            content: Text(
              'Ya no entra en tus 30 creaciones más recientes y será eliminada. '
              '¿Quieres descargarla antes?',
              style: VerbenaText.body(size: 13.5, color: VerbenaColors.textMuted),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text('Cancelar',
                    style: VerbenaText.body(size: 13.5, weight: FontWeight.w600)),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(
                  'Descargar',
                  style: VerbenaText.body(
                      size: 13.5, weight: FontWeight.w700, color: VerbenaColors.teal),
                ),
              ),
            ],
          ),
        );
        if (download == null || !mounted) return;

        if (download) {
          setState(() => _busy = true);
          try {
            final url = ref
                .read(generationResultUrlProvider(widget.generation.storagePath))
                .valueOrNull;
            if (url != null) {
              final hasAccess = await Gal.hasAccess() || await Gal.requestAccess();
              if (hasAccess) {
                final request = await HttpClient().getUrl(Uri.parse(url));
                final response = await request.close();
                final bytes = await consolidateHttpClientResponseBytes(response);
                await Gal.putImageBytes(
                  bytes,
                  name: 'verbenai_${widget.generation.id}',
                  album: 'VerbenAI',
                );
              }
            }
            await repo.toggleFavorite(widget.generation.id, false);
            if (mounted) {
              ref.invalidate(myGenerationsProvider);
              Navigator.of(context).pop();
            }
          } catch (_) {
            _showSnack('No se pudo completar la operación. Inténtalo otra vez.');
          } finally {
            if (mounted) setState(() => _busy = false);
          }
        }
        // Si download==false el usuario canceló — no se hace nada.
      } else {
        setState(() => _busy = true);
        try {
          await repo.toggleFavorite(widget.generation.id, false);
          if (mounted) {
            setState(() => _isFavorite = false);
            ref.invalidate(myGenerationsProvider);
          }
        } catch (_) {
          _showSnack('No hemos podido quitar la favorita. Inténtalo otra vez.');
        } finally {
          if (mounted) setState(() => _busy = false);
        }
      }
    }
  }

  Future<void> _deleteGeneration() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VerbenaColors.card,
        title: Text('Eliminar creación', style: VerbenaText.display(size: 17)),
        content: Text(
          'Se eliminará esta imagen permanentemente.',
          style: VerbenaText.body(size: 13.5, color: VerbenaColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancelar',
                style: VerbenaText.body(size: 13.5, weight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'Eliminar',
              style: VerbenaText.body(
                  size: 13.5, weight: FontWeight.w700, color: VerbenaColors.terracotta),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref.read(generationsRepositoryProvider).deleteGeneration(widget.generation.id);
      if (mounted) {
        ref.invalidate(myGenerationsProvider);
        Navigator.of(context).pop();
      }
    } catch (_) {
      _showSnack('No hemos podido eliminar la creación. Inténtalo otra vez.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final urlAsync =
        ref.watch(generationResultUrlProvider(widget.generation.storagePath));

    return SafeArea(
      child: AbsorbPointer(
        absorbing: _busy,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: VerbenaColors.textDark.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.45,
                  ),
                  child: urlAsync.when(
                    loading: () => const AspectRatio(
                      aspectRatio: 1,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    error: (_, __) => const AspectRatio(
                      aspectRatio: 1,
                      child: SizedBox.shrink(),
                    ),
                    data: (url) => CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.generation.modeLabel,
                          style: VerbenaText.body(size: 14.5, weight: FontWeight.w700),
                        ),
                        Text(
                          widget.generation.formattedDate,
                          style: VerbenaText.body(size: 13, color: VerbenaColors.textMuted),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _isFavorite ? Icons.star : Icons.star_border,
                      color: _isFavorite ? Colors.amber : VerbenaColors.textMuted,
                    ),
                    onPressed: _toggleFavorite,
                    tooltip: _isFavorite ? 'Quitar de favoritas' : 'Añadir a favoritas',
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: VerbenaColors.terracotta),
                    onPressed: _deleteGeneration,
                    tooltip: 'Eliminar',
                  ),
                ],
              ),
              const SizedBox(height: 4),
              urlAsync.when(
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const SizedBox.shrink(),
                data: (url) => GenerationShareActions(
                  resultUrl: url,
                  generationId: widget.generation.id,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class VerifiedPhotoDetailSheet extends ConsumerWidget {
  const VerifiedPhotoDetailSheet({super.key, required this.photo});

  final VerifiedPhotoSummary photo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final urlAsync = ref.watch(verifiedPhotoUrlProvider(photo.storagePath));
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: VerbenaColors.textDark.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.55,
                ),
                child: urlAsync.when(
                  loading: () => const AspectRatio(
                    aspectRatio: 1,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (_, __) => const AspectRatio(
                    aspectRatio: 1,
                    child: SizedBox.shrink(),
                  ),
                  data: (url) => CachedNetworkImage(
                    imageUrl: url,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              photo.formattedDate,
              style: VerbenaText.body(size: 13, color: VerbenaColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
