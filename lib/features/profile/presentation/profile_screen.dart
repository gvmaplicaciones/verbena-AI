import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/credits.dart';
import '../../../core/router/app_routes.dart';
import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../data/models/user_credits.dart';
import '../../../data/models/verified_photo_summary.dart';
import '../../../data/repositories/account_repository.dart';
import '../../../data/repositories/auth_repository.dart';
import '../../../data/repositories/credits_repository.dart';
import '../../../data/repositories/photo_repository.dart';
import '../../../data/repositories/purchases_repository.dart';

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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _statusLabel(UserCredits credits) {
    if (credits.isSubscribed) {
      return credits.activePlanId == PlanIds.semanal ? 'Plan Semanal activo' : 'Plan Mensual activo';
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
      final info = await ref.read(purchasesRepositoryProvider).getCustomerInfo();
      final uri = info.managementURL == null ? null : Uri.tryParse(info.managementURL!);
      if (uri == null || !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
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
            child: Text('Cancelar', style: VerbenaText.body(size: 13.5, weight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Borrar',
              style: VerbenaText.body(size: 13.5, weight: FontWeight.w700, color: VerbenaColors.terracotta),
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
      body: SafeArea(
        child: creditsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator(color: VerbenaColors.teal)),
          error: (err, st) => Center(
            child: Text('No hemos podido cargar tu perfil.', style: VerbenaText.body()),
          ),
          data: _buildContent,
        ),
      ),
    );
  }

  Widget _buildContent(UserCredits credits) {
    final persistedAsync = ref.watch(persistedPhotosProvider);

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
                  VerbenaRoundIconButton(icon: const VerbenaBackChevronIcon(), onTap: () => context.pop()),
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
                    decoration: BoxDecoration(color: VerbenaColors.teal, borderRadius: BorderRadius.circular(16)),
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
                                  color: VerbenaColors.background.withValues(alpha: 0.75),
                                ).copyWith(letterSpacing: 0.4),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _statusLabel(credits),
                                style: VerbenaText.display(size: 17, color: VerbenaColors.background),
                              ),
                            ],
                          ),
                        ),
                        ElevatedButton(
                          onPressed: () => _openManageSubscription(credits.isSubscribed),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: VerbenaColors.background,
                            foregroundColor: VerbenaColors.teal,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                          ),
                          child: Text('GESTIONAR', style: VerbenaText.display(size: 11.5, color: VerbenaColors.teal)),
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
                    style: VerbenaText.body(size: 12, weight: FontWeight.w600, color: VerbenaColors.textMuted)
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
                        border: Border.all(color: VerbenaColors.textDark.withValues(alpha: 0.25), width: 1.5),
                      ),
                      child: Column(
                        children: [
                          Text(
                            'Suscríbete para guardar tus fotos verificadas y generar más rápido.',
                            textAlign: TextAlign.center,
                            style: VerbenaText.body(size: 13, color: VerbenaColors.textMuted),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: () => context.push(AppRoutes.paywall, extra: 'profile'),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: VerbenaColors.teal, width: 2),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                            ),
                            child: Text('VER PLANES', style: VerbenaText.display(size: 12, color: VerbenaColors.teal)),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: VerbenaColors.textDark.withValues(alpha: 0.12)),
                    ),
                    child: Column(
                      children: [
                        _SettingsRow(
                          label: 'Política de privacidad',
                          onTap: () => context.push(AppRoutes.privacyPolicy),
                          showDivider: true,
                        ),
                        _SettingsRow(label: 'Borrar mis datos', onTap: _confirmDeleteData, showDivider: false),
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
                            style: VerbenaText.body(size: 13.5, weight: FontWeight.w600, color: VerbenaColors.terracotta),
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (!credits.isSubscribed && ref.watch(authRepositoryProvider).isAnonymous) ...[
                    const SizedBox(height: 16),
                    Center(
                      child: GestureDetector(
                        onTap: () => context.push(AppRoutes.accountGate, extra: true),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Text(
                            '¿Ya tenías cuenta? Recuperarla',
                            style: VerbenaText.body(size: 13.5, weight: FontWeight.w600, color: VerbenaColors.teal),
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
  const _CreditBox({required this.value, required this.label, required this.color});

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
        border: Border.all(color: VerbenaColors.textDark.withValues(alpha: 0.15), width: 1.5),
      ),
      child: Column(
        children: [
          Text(value, style: VerbenaText.display(size: 20, color: color)),
          const SizedBox(height: 2),
          Text(label, style: VerbenaText.body(size: 11, color: VerbenaColors.textMuted)),
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.label, required this.onTap, required this.showDivider});

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
                border: Border(bottom: BorderSide(color: VerbenaColors.textDark.withValues(alpha: 0.1))),
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
            return ClipRRect(
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
            );
          },
        );
      },
    );
  }
}
