import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/credits.dart';
import '../../../core/router/app_routes.dart';
import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../core/utils/date_format.dart';
import '../../../core/utils/navigation.dart';
import '../../../core/widgets/confetti_background.dart';
import '../../../data/models/user_credits.dart';
import '../../../data/providers/supabase_provider.dart';
import '../../../data/repositories/account_repository.dart';
import '../../../data/repositories/auth_repository.dart';
import '../../../data/repositories/credits_repository.dart';
import '../../../data/repositories/garment_repository.dart';
import '../../../data/repositories/generations_repository.dart';
import '../../../data/repositories/photo_repository.dart';
import '../../../data/repositories/plans_repository.dart';
import '../../../data/repositories/purchases_repository.dart';
import '../../../services/analytics_service.dart';
import 'gallery_grids.dart';

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
  bool _justBoughtExtra = false;

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
    if (credits.subscriptionStatus == 'cancelled') {
      return credits.expiresAt != null
          ? 'Cancelada — activa hasta ${formatShortDate(credits.expiresAt!)}'
          : 'Cancelada — activa hasta fin de periodo';
    }
    return credits.freeCreditUsed
        ? 'Sin suscripción — gratis ya usada'
        : 'Sin suscripción — te queda 1 foto gratis';
  }

  Future<void> _openManageSubscription(bool hasActiveAccess) async {
    if (!hasActiveAccess) {
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

  /// Compra directa del pack extra desde Perfil -- sin pasar por Paywall
  /// como paso intermedio (reportado: era un rodeo innecesario para algo
  /// que ya se decide aquí mismo). Mismo flujo que paywall_screen._buy,
  /// simplificado porque el pack extra no requiere comprobar entitlement.
  Future<void> _buyExtraPack() async {
    if (_busy) return;
    if (ref.read(authRepositoryProvider).isAnonymous) {
      final canProceed = await context.push<bool>(AppRoutes.accountGate);
      if (canProceed != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final repo = ref.read(purchasesRepositoryProvider);
      final offerings = await repo.fetchOfferings();
      final package = repo.findPackage(offerings, ExtraPackIds.extra7);
      if (package == null) {
        _showSnack('Ese pack no está disponible ahora mismo.');
        return;
      }
      await AnalyticsService.purchaseAttempted(planId: ExtraPackIds.extra7);
      await repo.purchasePackage(package);
      await repo.reconcile();
      ref.invalidate(myCreditsProvider);
      await AnalyticsService.purchaseCompleted(
        planId: ExtraPackIds.extra7,
        transactionIdentifier: repo.lastTransactionIdentifier,
      );
      if (!mounted) return;
      setState(() => _justBoughtExtra = true);
      _showSnack('¡Recarga añadida a tu cuenta!');
    } on PlatformException catch (e) {
      final code = PurchasesErrorHelper.getErrorCode(e);
      if (code == PurchasesErrorCode.purchaseCancelledError) return;
      if (code == PurchasesErrorCode.paymentPendingError) {
        _showSnack(
            'Tu pago se está procesando, te avisaremos en cuanto se confirme.');
        return;
      }
      _showSnack('No hemos podido completar la compra.');
    } catch (_) {
      _showSnack('No hemos podido completar la compra.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Botón explícito para comprar el pack extra, con la cantidad y el
  /// precio real de la tienda (RevenueCat) siempre visibles -- el tap sobre
  /// las cajas de créditos de arriba es una vía adicional, pero no debe ser
  /// la única forma de encontrar esto (reportado: usuarios suscritos no
  /// veían ningún sitio claro para comprar fotos extra).
  Widget _extraPackButton() {
    final extraPacksAsync = ref.watch(extraPacksProvider);
    final extra = extraPacksAsync.valueOrNull
        ?.firstWhere((p) => p.packId == ExtraPackIds.extra7);
    if (extra == null) return const SizedBox.shrink();
    final offerings = ref.watch(offeringsProvider).valueOrNull;
    final repo = ref.read(purchasesRepositoryProvider);
    final extraPrice = offerings == null
        ? extra.priceDisplay
        : repo
                .findPackage(offerings, ExtraPackIds.extra7)
                ?.storeProduct
                .priceString ??
            extra.priceDisplay;

    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _buyExtraPack,
            style: ElevatedButton.styleFrom(
              backgroundColor: VerbenaColors.terracotta,
              foregroundColor: VerbenaColors.background,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            child: Text(
              'COMPRAR ${extra.credits} FOTOS EXTRA · $extraPrice',
              style: VerbenaText.display(
                  size: 14, color: VerbenaColors.background),
            ),
          ),
        ),
        if (_justBoughtExtra) ...[
          const SizedBox(height: 6),
          Text(
            '¡Recarga añadida a tu cuenta!',
            textAlign: TextAlign.center,
            style: VerbenaText.body(
                size: 12.5, weight: FontWeight.w700, color: VerbenaColors.teal),
          ),
        ],
      ],
    );
  }

  /// Abre el cliente de correo con contexto técnico pre-rellenado (versión,
  /// plataforma, UID) para poder cruzarlo con Sentry sin que el usuario
  /// tenga que saber nada técnico. El UID es exactamente el mismo que
  /// Sentry.setUser() (ver _bindSentryUserToAuthSession en main.dart) --
  /// mismo Supabase.instance.client.auth.currentUser, vía supabaseClientProvider.
  Future<void> _contactSupport() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final platform =
        '${Platform.isIOS ? 'iOS' : 'Android'} ${Platform.operatingSystemVersion}';
    final userId =
        ref.read(supabaseClientProvider).auth.currentUser?.id ?? 'desconocido';

    final body = '''
Describe aquí el problema que has encontrado:


---
No borres lo siguiente, nos ayuda a solucionarlo más rápido:
Versión: ${packageInfo.version} (${packageInfo.buildNumber})
Plataforma: $platform
ID de usuario: $userId''';

    final uri = Uri(
      scheme: 'mailto',
      path: 'gvm.aplicaciones@gmail.com',
      queryParameters: {
        'subject': 'VerbenAI - Reporte de problema',
        'body': body,
      },
    );
    if (!await launchUrl(uri)) {
      _showSnack('No hemos podido abrir tu cliente de correo.');
    }
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: VerbenaColors.card,
        title: Text('Cerrar sesión', style: VerbenaText.display(size: 17)),
        content: Text(
          'Se cerrará tu sesión en este dispositivo. Podrás volver a entrar con tu cuenta cuando quieras.',
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
              'Cerrar sesión',
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
      await ref.read(authRepositoryProvider).signOut();
      if (!mounted) return;
      context.go(AppRoutes.onboarding);
    } catch (_) {
      _showSnack('No hemos podido cerrar la sesión. Inténtalo otra vez.');
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
      // La cuenta anterior se borró y la sesión anónima nueva ya está activa,
      // pero estos FutureProvider no son .autoDispose -- sin invalidar,
      // siguen sirviendo desde caché los datos de la cuenta borrada (mismo
      // patrón de invalidación que compras/favoritos/prendas en el resto de
      // la app, ver paywall_screen._buy y gallery_grids.dart).
      ref.invalidate(myGenerationsProvider);
      ref.invalidate(persistedPhotosProvider);
      ref.invalidate(myCreditsProvider);
      ref.invalidate(garmentsProvider);
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
    final generationsAsync = (credits.hasActiveAccess || credits.freeCreditUsed)
        ? ref.watch(myGenerationsProvider)
        : null;

    return AbsorbPointer(
      absorbing: _busy,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      VerbenaRoundIconButton(
                          icon: const VerbenaBackChevronIcon(),
                          onTap: () => context.safePop()),
                      const SizedBox(width: 12),
                      Text('Tu perfil', style: VerbenaText.display(size: 22)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Visible siempre -- pensado para que el usuario pueda
                  // comprobar de un vistazo con qué cuenta ha iniciado
                  // sesión en este dispositivo (confusión real detectada el
                  // 2026-08-05 al probar con dos cuentas distintas, ver
                  // account_gate_screen.dart).
                  Text(
                    ref.watch(supabaseClientProvider).auth.currentUser?.email ??
                        'Sesión sin vincular a ningún email',
                    style: VerbenaText.body(
                        size: 12.5, color: VerbenaColors.textMuted),
                  ),
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
                              _openManageSubscription(credits.hasActiveAccess),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: VerbenaColors.background,
                            foregroundColor: VerbenaColors.teal,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 9),
                          ),
                          child: Text(
                              credits.hasActiveAccess
                                  ? 'GESTIONAR'
                                  : 'SUSCRIBIRSE',
                              style: VerbenaText.display(
                                  size: 11.5, color: VerbenaColors.teal)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (credits.hasActiveAccess) ...[
                    // hasActiveAccess cubre 'active' Y 'cancelled' -- un
                    // suscriptor cancelado sigue con acceso hasta fin de
                    // periodo y debe poder comprar el pack extra igual.
                    InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => context.push(AppRoutes.paywall,
                          extra: 'profile_credits'),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: _CreditBox(
                                        value:
                                            '${credits.tierUsed}/${credits.tierTotal}',
                                        label: 'fotos del plan',
                                        color: VerbenaColors.teal,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: _CreditBox(
                                        value: '+${credits.extraCredits}',
                                        label: 'fotos extra',
                                        color: VerbenaColors.terracotta,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 6),
                              const VerbenaChevronRightIcon(),
                            ],
                          ),
                          if (credits.subscriptionStatus == 'cancelled') ...[
                            const SizedBox(height: 10),
                            Text(
                              credits.expiresAt != null
                                  ? 'Cancelada — activa hasta ${formatShortDate(credits.expiresAt!)}'
                                  : 'Cancelada — activa hasta fin de periodo',
                              textAlign: TextAlign.center,
                              style: VerbenaText.body(
                                  size: 12.5, color: VerbenaColors.textMuted),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    _extraPackButton(),
                  ] else
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: VerbenaColors.card,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color:
                                VerbenaColors.textDark.withValues(alpha: 0.15),
                            width: 1.5),
                      ),
                      child: Column(
                        children: [
                          Text(
                            credits.freeCreditUsed
                                ? 'Foto gratis usada'
                                : '1 foto gratis disponible',
                            style: VerbenaText.display(size: 17),
                          ),
                          if (credits.freeCreditUsed) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Suscríbete para ver planes y seguir generando fotos.',
                              textAlign: TextAlign.center,
                              style: VerbenaText.body(
                                  size: 12.5, color: VerbenaColors.textMuted),
                            ),
                          ],
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  _SectionHeader(
                    title: 'FOTOS VERIFICADAS',
                    onSeeAll: (persistedAsync.valueOrNull?.length ?? 0) > 5
                        ? () => context.push(AppRoutes.verifiedPhotos)
                        : null,
                  ),
                  const SizedBox(height: 8),
                  if (credits.hasActiveAccess)
                    VerifiedPhotosGrid(persistedAsync: persistedAsync, limit: 5)
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
                  if (generationsAsync != null) ...[
                    const SizedBox(height: 16),
                    _SectionHeader(
                      title: 'MIS CREACIONES',
                      onSeeAll: (generationsAsync.valueOrNull?.length ?? 0) > 5
                          ? () => context.push(AppRoutes.myCreations)
                          : null,
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
                          MyCreationsGrid(generations: generations, limit: 5),
                    ),
                    if ((generationsAsync.valueOrNull ?? [])
                        .any((g) => g.isFavorite)) ...[
                      const SizedBox(height: 16),
                      Builder(builder: (context) {
                        final favorites = generationsAsync.valueOrNull!
                            .where((g) => g.isFavorite)
                            .toList();
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _SectionHeader(
                              title: 'MIS FAVORITAS',
                              onSeeAll: favorites.length > 5
                                  ? () => context.push(AppRoutes.favorites)
                                  : null,
                            ),
                            const SizedBox(height: 8),
                            MyCreationsGrid(generations: favorites, limit: 5),
                          ],
                        );
                      }),
                    ],
                  ],
                  if (credits.hasActiveAccess) ...[
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
                          label: 'Contacto / Reportar un problema',
                          onTap: _contactSupport,
                          showDivider: true,
                        ),
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
                  if (!ref.watch(authRepositoryProvider).isAnonymous) ...[
                    const SizedBox(height: 16),
                    Center(
                      child: GestureDetector(
                        onTap: () => _confirmSignOut(),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Text(
                            'Cerrar sesión',
                            style: VerbenaText.body(
                                size: 13.5,
                                weight: FontWeight.w600,
                                color: VerbenaColors.textMuted),
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

/// Cabecera de sección con enlace opcional "Ver todas" -- se muestra solo
/// cuando la sección tiene más de 5 elementos (ver ProfileScreen._buildContent).
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.onSeeAll});

  final String title;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: VerbenaText.body(
                  size: 12,
                  weight: FontWeight.w600,
                  color: VerbenaColors.textMuted)
              .copyWith(letterSpacing: 0.4),
        ),
        if (onSeeAll != null)
          GestureDetector(
            onTap: onSeeAll,
            child: Text(
              'VER TODAS',
              style: VerbenaText.body(
                      size: 11.5,
                      weight: FontWeight.w700,
                      color: VerbenaColors.teal)
                  .copyWith(letterSpacing: 0.3),
            ),
          ),
      ],
    );
  }
}
