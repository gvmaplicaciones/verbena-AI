import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show consolidateHttpClientResponseBytes;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/credits.dart';
import '../../../core/router/app_routes.dart';
import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../core/widgets/confetti_background.dart';
import '../../../data/models/generation_summary.dart';
import '../../../data/models/user_credits.dart';
import '../../../data/models/verified_photo_summary.dart';
import '../../../data/repositories/account_repository.dart';
import '../../../data/repositories/auth_repository.dart';
import '../../../data/repositories/credits_repository.dart';
import '../../../data/repositories/generations_repository.dart';
import '../../../data/repositories/photo_repository.dart';
import '../../../data/repositories/purchases_repository.dart';
import '../../result/presentation/generation_actions.dart';

/// El handoff deja "Cancelar suscripción" como un confirm dialog puramente
/// en la app (setState local) -- no existe ninguna llamada real que cancele
/// un cobro recurrente desde el cliente (ni en purchases_flutter ni en
/// nuestras Edge Functions, ver _shared/revenuecat.ts). Apple/Google exigen
/// que la cancelación real pase por la pantalla nativa de gestión de
/// suscripción de la tienda, así que tanto "Gestionar" como "Cancelar
/// suscripción" abren esa pantalla (CustomerInfo.managementURL) en vez de
/// fingir cancelar en la app.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _busy = false;

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _statusLabel(UserCredits credits) {
    if (credits.isSubscribed) {
      return credits.activePlanId == PlanIds.semanal
          ? 'Plan Semanal activo'
          : 'Plan Mensual activo';
    }
    return credits.freeCreditUsed
        ? 'Sin suscripción — gratis ya usada'
        : 'Sin suscripción — te queda 1 foto gratis';
  }

  Future<void> _openManageSubscription(bool isSubscribed) async {
    if (!isSubscribed) {
      context.push(AppRoutes.paywall, extra: 'profile');
      return;
    }
    setState(() => _busy = true);
    try {
      final info =
          await ref.read(purchasesRepositoryProvider).getCustomerInfo();
      final uri =
          info.managementURL == null ? null : Uri.tryParse(info.managementURL!);
      if (uri == null ||
          !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        _showSnack('No hemos podido abrir la gestión de tu suscripción.');
      }
    } catch (_) {
      _showSnack('No hemos podido abrir la gestión de tu suscripción.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmDeleteData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: VerbenaColors.card,
        title: Text('Borrar mis datos', style: VerbenaText.display(size: 17)),
        content: Text(
          'Se eliminará tu cuenta y todo tu contenido (fotos, creaciones, créditos). Esta acción no se puede deshacer.',
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
            child: Text(
              'Borrar',
              style: VerbenaText.body(
                  size: 13.5,
                  weight: FontWeight.w700,
                  color: VerbenaColors.terracotta),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref.read(accountRepositoryProvider).deleteMyDataAndRestart();
      if (!mounted) return;
      context.go(AppRoutes.onboarding);
    } catch (_) {
      _showSnack('No hemos podido borrar tus datos. Inténtalo otra vez.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final creditsAsync = ref.watch(myCreditsProvider);
    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: Stack(
        children: [
          const ConfettiBackground(),
          SafeArea(
            child: creditsAsync.when(
              loading: () => const Center(
                  child: CircularProgressIndicator(color: VerbenaColors.teal)),
              error: (err, st) => Center(
                child: Text('No hemos podido cargar tu perfil.',
                    style: VerbenaText.body()),
              ),
              data: _buildContent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(UserCredits credits) {
    final persistedAsync = ref.watch(persistedPhotosProvider);
    final generationsAsync =
        credits.isSubscribed ? ref.watch(myGenerationsProvider) : null;

    return AbsorbPointer(
      absorbing: _busy,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                children: [
                  VerbenaRoundIconButton(
                      icon: const VerbenaBackChevronIcon(),
                      onTap: () => context.pop()),
                  const SizedBox(width: 12),
                  Text('Tu perfil', style: VerbenaText.display(size: 22)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                        color: VerbenaColors.teal,
                        borderRadius: BorderRadius.circular(16)),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'SUSCRIPCIÓN',
                                style: VerbenaText.body(
                                  size: 11,
                                  weight: FontWeight.w600,
                                  color: VerbenaColors.background
                                      .withValues(alpha: 0.75),
                                ).copyWith(letterSpacing: 0.4),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _statusLabel(credits),
                                style: VerbenaText.display(
                                    size: 17, color: VerbenaColors.background),
                              ),
                            ],
                          ),
                        ),
                        ElevatedButton(
                          onPressed: () =>
                              _openManageSubscription(credits.isSubscribed),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: VerbenaColors.background,
                            foregroundColor: VerbenaColors.teal,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 9),
                          ),
                          child: Text('GESTIONAR',
                              style: VerbenaText.display(
                                  size: 11.5, color: VerbenaColors.teal)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _CreditBox(
                          value: '${credits.tierUsed}/${credits.tierTotal}',
                          label: 'créditos del plan',
                          color: VerbenaColors.teal,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _CreditBox(
                          value: '+${credits.extraCredits}',
                          label: 'créditos extra',
                          color: VerbenaColors.terracotta,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'FOTOS VERIFICADAS',
                    style: VerbenaText.body(
                            size: 12,
                            weight: FontWeight.w600,
                            color: VerbenaColors.textMuted)
                        .copyWith(letterSpacing: 0.4),
                  ),
                  const SizedBox(height: 8),
                  if (credits.isSubscribed)
                    _VerifiedPhotosGrid(persistedAsync: persistedAsync)
                  else
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color:
                                VerbenaColors.textDark.withValues(alpha: 0.25),
                            width: 1.5),
                      ),
                      child: Column(
                        children: [
                          Text(
                            'Suscríbete para guardar tus fotos verificadas y generar más rápido.',
                            textAlign: TextAlign.center,
                            style: VerbenaText.body(
                                size: 13, color: VerbenaColors.textMuted),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: () => context.push(AppRoutes.paywall,
                                extra: 'profile'),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(
                                  color: VerbenaColors.teal, width: 2),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 9),
                            ),
                            child: Text('VER PLANES',
                                style: VerbenaText.display(
                                    size: 12, color: VerbenaColors.teal)),
                          ),
                        ],
                      ),
                    ),
                  if (credits.isSubscribed && generationsAsync != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      'MIS CREACIONES',
                      style: VerbenaText.body(
                              size: 12,
                              weight: FontWeight.w600,
                              color: VerbenaColors.textMuted)
                          .copyWith(letterSpacing: 0.4),
                    ),
                    const SizedBox(height: 8),
                    generationsAsync.when(
                      loading: () => const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                      error: (err, st) => Text(
                        'No se pudieron cargar tus creaciones.',
                        style: VerbenaText.body(
                            size: 13, color: VerbenaColors.textMuted),
                      ),
                      data: (generations) =>
                          _MyCreationsGrid(generations: generations),
                    ),
                  ],
                  if (credits.isSubscribed) ...[
                    const SizedBox(height: 16),
                    Text(
                      'ARMARIO',
                      style: VerbenaText.body(
                              size: 12,
                              weight: FontWeight.w600,
                              color: VerbenaColors.textMuted)
                          .copyWith(letterSpacing: 0.4),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color:
                                VerbenaColors.textDark.withValues(alpha: 0.12)),
                      ),
                      child: _SettingsRow(
                        label: 'Tus prendas guardadas',
                        onTap: () => context.push(AppRoutes.wardrobe),
                        showDivider: false,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color:
                              VerbenaColors.textDark.withValues(alpha: 0.12)),
                    ),
                    child: Column(
                      children: [
                        _SettingsRow(
                          label: 'Política de privacidad',
                          onTap: () => context.push(AppRoutes.privacyPolicy),
                          showDivider: true,
                        ),
                        _SettingsRow(
                            label: 'Borrar mis datos',
                            onTap: _confirmDeleteData,
                            showDivider: false),
                      ],
                    ),
                  ),
                  if (credits.isSubscribed) ...[
                    const SizedBox(height: 16),
                    Center(
                      child: GestureDetector(
                        onTap: () => _openManageSubscription(true),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Text(
                            'Cancelar suscripción',
                            style: VerbenaText.body(
                                size: 13.5,
                                weight: FontWeight.w600,
                                color: VerbenaColors.terracotta),
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (!credits.isSubscribed &&
                      ref.watch(authRepositoryProvider).isAnonymous) ...[
                    const SizedBox(height: 16),
                    Center(
                      child: GestureDetector(
                        onTap: () =>
                            context.push(AppRoutes.accountGate, extra: true),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Text(
                            '¿Ya tenías cuenta? Recuperarla',
                            style: VerbenaText.body(
                                size: 13.5,
                                weight: FontWeight.w600,
                                color: VerbenaColors.teal),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreditBox extends StatelessWidget {
  const _CreditBox(
      {required this.value, required this.label, required this.color});

  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: VerbenaColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: VerbenaColors.textDark.withValues(alpha: 0.15), width: 1.5),
      ),
      child: Column(
        children: [
          Text(value, style: VerbenaText.display(size: 20, color: color)),
          const SizedBox(height: 2),
          Text(label,
              style:
                  VerbenaText.body(size: 11, color: VerbenaColors.textMuted)),
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow(
      {required this.label, required this.onTap, required this.showDivider});

  final String label;
  final VoidCallback onTap;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: showDivider
            ? BoxDecoration(
                border: Border(
                    bottom: BorderSide(
                        color: VerbenaColors.textDark.withValues(alpha: 0.1))),
              )
            : null,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: VerbenaText.body(size: 14.5)),
            const VerbenaChevronRightIcon(),
          ],
        ),
      ),
    );
  }
}

class _VerifiedPhotosGrid extends ConsumerWidget {
  const _VerifiedPhotosGrid({required this.persistedAsync});

  final AsyncValue<List<VerifiedPhotoSummary>> persistedAsync;

  void _showDetail(BuildContext context, VerifiedPhotoSummary photo) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: VerbenaColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _VerifiedPhotoDetailSheet(photo: photo),
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
      data: (photos) {
        if (photos.isEmpty) {
          return Text(
            'Aún no tienes fotos verificadas guardadas.',
            style: VerbenaText.body(size: 13, color: VerbenaColors.textMuted),
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

class _MyCreationsGrid extends ConsumerWidget {
  const _MyCreationsGrid({required this.generations});

  final List<GenerationSummary> generations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (generations.isEmpty) {
      return Text(
        'Aún no tienes creaciones. ¡Genera tu primera foto!',
        style: VerbenaText.body(size: 13, color: VerbenaColors.textMuted),
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
      itemCount: generations.length,
      itemBuilder: (context, i) {
        final gen = generations[i];
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
      builder: (_) => _CreationDetailSheet(generation: gen),
    );
  }
}

class _CreationDetailSheet extends ConsumerStatefulWidget {
  const _CreationDetailSheet({required this.generation});

  final GenerationSummary generation;

  @override
  ConsumerState<_CreationDetailSheet> createState() => _CreationDetailSheetState();
}

class _CreationDetailSheetState extends ConsumerState<_CreationDetailSheet> {
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

class _VerifiedPhotoDetailSheet extends ConsumerWidget {
  const _VerifiedPhotoDetailSheet({required this.photo});

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
