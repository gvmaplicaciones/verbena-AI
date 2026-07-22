import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../../../core/constants/credits.dart';
import '../../../core/router/app_routes.dart';
import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../data/models/plan.dart';
import '../../../data/models/user_credits.dart';
import '../../../data/repositories/auth_repository.dart';
import '../../../data/repositories/credits_repository.dart';
import '../../../data/repositories/plans_repository.dart';
import '../../../data/repositories/purchases_repository.dart';
import '../../../services/analytics_service.dart';

/// Los precios que se enseñan aquí son los reales de la tienda (RevenueCat
/// `StoreProduct.priceString`, respeta moneda/región), no un texto fijo --
/// solo se cae al `price_display` de la tabla `plans`/`extra_packs` mientras
/// la oferta de RevenueCat todavía no ha cargado o no está disponible.
class PaywallScreen extends ConsumerStatefulWidget {
  const PaywallScreen({super.key, required this.source});

  final String source;

  @override
  ConsumerState<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends ConsumerState<PaywallScreen> {
  bool _busy = false;
  String? _justBoughtPackId;

  @override
  void initState() {
    super.initState();
    AnalyticsService.paywallViewed(source: widget.source);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _buy(String productId, Future<void> Function() onSuccess) async {
    if (_busy) return;
    // Registro solo obligatorio en el momento de pagar (no para la foto
    // gratis) -- así se puede recuperar la suscripción si se reinstala la
    // app o se cambia de móvil (ver account_gate_screen.dart).
    if (ref.read(authRepositoryProvider).isAnonymous) {
      final canProceed = await context.push<bool>(AppRoutes.accountGate);
      if (canProceed != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final repo = ref.read(purchasesRepositoryProvider);
      final offerings = await repo.fetchOfferings();
      final package = repo.findPackage(offerings, productId);
      if (package == null) {
        _showSnack('Ese plan no está disponible ahora mismo.');
        return;
      }
      await AnalyticsService.purchaseAttempted(planId: productId);
      await repo.purchasePackage(package);
      await repo.reconcile();
      ref.invalidate(myCreditsProvider);
      await AnalyticsService.purchaseCompleted(
        planId: productId,
        transactionIdentifier: repo.lastTransactionIdentifier,
      );
      if (!mounted) return;
      await onSuccess();
    } on PlatformException catch (e) {
      if (PurchasesErrorHelper.getErrorCode(e) == PurchasesErrorCode.purchaseCancelledError) return;
      _showSnack('No hemos podido completar la compra.');
    } catch (_) {
      _showSnack('No hemos podido completar la compra.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _subscribeSemanal() => _buy(PlanIds.semanal, () async {
        if (mounted) context.pop();
      });

  Future<void> _subscribeMensual() => _buy(PlanIds.mensual, () async {
        if (mounted) context.pop();
      });

  Future<void> _buyExtra() => _buy(ExtraPackIds.extra7, () async {
        if (mounted) setState(() => _justBoughtPackId = ExtraPackIds.extra7);
      });

  @override
  Widget build(BuildContext context) {
    final creditsAsync = ref.watch(myCreditsProvider);
    final plansAsync = ref.watch(plansProvider);

    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: SafeArea(
        child: creditsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator(color: VerbenaColors.teal)),
          error: (err, st) => Center(
            child: Text('No hemos podido cargar tu cuenta.', style: VerbenaText.body()),
          ),
          data: (credits) => plansAsync.when(
            loading: () => const Center(child: CircularProgressIndicator(color: VerbenaColors.teal)),
            error: (err, st) => Center(
              child: Text('No hemos podido cargar los planes.', style: VerbenaText.body()),
            ),
            data: (plans) => _buildContent(credits, plans),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(UserCredits credits, List<Plan> plans) {
    final semanal = plans.firstWhere((p) => p.planId == PlanIds.semanal);
    final mensual = plans.firstWhere((p) => p.planId == PlanIds.mensual);
    final offerings = ref.watch(offeringsProvider).valueOrNull;
    final repo = ref.read(purchasesRepositoryProvider);
    final semanalPrice = offerings == null
        ? semanal.priceDisplay
        : repo.findPackage(offerings, PlanIds.semanal)?.storeProduct.priceString ?? semanal.priceDisplay;
    final mensualPrice = offerings == null
        ? mensual.priceDisplay
        : repo.findPackage(offerings, PlanIds.mensual)?.storeProduct.priceString ?? mensual.priceDisplay;
    final extraPacksAsync = ref.watch(extraPacksProvider);
    final extra = extraPacksAsync.valueOrNull?.firstWhere((p) => p.packId == ExtraPackIds.extra7);
    final extraPrice = extra == null
        ? null
        : (offerings == null
            ? extra.priceDisplay
            : repo.findPackage(offerings, ExtraPackIds.extra7)?.storeProduct.priceString ?? extra.priceDisplay);

    return AbsorbPointer(
      absorbing: _busy,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: Text('Hazte de la peña', style: VerbenaText.display(size: 22))),
                VerbenaRoundIconButton(icon: const VerbenaCloseIcon(size: 14), onTap: () => context.pop()),
              ],
            ),
            const SizedBox(height: 18),
            if (credits.canUseFreeGeneration) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: VerbenaColors.card,
                  border: Border.all(color: VerbenaColors.terracotta, width: 1.5),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Tu primera foto va gratis',
                      style: VerbenaText.body(size: 14.5, weight: FontWeight.w700, color: VerbenaColors.terracotta),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Sin trampa ni cartón. Pruébalo antes de suscribirte.',
                      style: VerbenaText.body(size: 12.5, color: VerbenaColors.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
            ],
            _PlanCard(
              title: 'Semanal',
              price: semanalPrice,
              cadence: '/semana',
              creditsLabel: '${semanal.tierCredits} créditos cada semana',
              priceColor: VerbenaColors.teal,
              buttonColor: VerbenaColors.teal,
              buttonLabel: 'Elegir semanal',
              onTap: _subscribeSemanal,
            ),
            const SizedBox(height: 14),
            _PlanCard(
              title: 'Mensual',
              price: mensualPrice,
              cadence: '/mes',
              creditsLabel: '${mensual.tierCredits} créditos cada mes',
              priceColor: VerbenaColors.terracotta,
              buttonColor: VerbenaColors.terracotta,
              buttonLabel: 'Elegir mensual',
              onTap: _subscribeMensual,
              highlighted: true,
              badgeLabel: 'MEJOR VALOR',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Cancela cuando quieras, sin líos ni permanencia.',
                textAlign: TextAlign.center,
                style: VerbenaText.body(size: 12, color: VerbenaColors.textMuted),
              ),
            ),
            if (credits.isSubscribed && extra != null) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: VerbenaColors.textDark.withValues(alpha: 0.3), width: 1.5),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Recarga rápida — ${extra.credits} créditos',
                      style: VerbenaText.body(size: 14.5, weight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Esto es una recarga puntual, no sustituye tu suscripción.',
                      style: VerbenaText.body(size: 12.5, color: VerbenaColors.textMuted),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: _buyExtra,
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: VerbenaColors.teal, width: 2),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: Text(
                          'Comprar por $extraPrice',
                          style: VerbenaText.display(size: 13, color: VerbenaColors.teal, letterSpacing: 0.3),
                        ),
                      ),
                    ),
                    if (_justBoughtPackId == ExtraPackIds.extra7) ...[
                      const SizedBox(height: 4),
                      Text(
                        '¡Recarga añadida a tu cuenta!',
                        textAlign: TextAlign.center,
                        style: VerbenaText.body(size: 12, weight: FontWeight.w700, color: VerbenaColors.teal),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.title,
    required this.price,
    required this.cadence,
    required this.creditsLabel,
    required this.priceColor,
    required this.buttonColor,
    required this.buttonLabel,
    required this.onTap,
    this.highlighted = false,
    this.badgeLabel,
  });

  final String title;
  final String price;
  final String cadence;
  final String creditsLabel;
  final Color priceColor;
  final Color buttonColor;
  final String buttonLabel;
  final VoidCallback onTap;
  final bool highlighted;
  final String? badgeLabel;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: VerbenaColors.card,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: highlighted ? VerbenaColors.terracotta : VerbenaColors.textDark.withValues(alpha: 0.15),
              width: highlighted ? 2 : 1.5,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (badgeLabel != null) const SizedBox(height: 4),
              Text(title, style: VerbenaText.display(size: 18)),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(price, style: VerbenaText.display(size: 26, color: priceColor)),
                  const SizedBox(width: 6),
                  Text(cadence, style: VerbenaText.body(size: 13, color: VerbenaColors.textMuted)),
                ],
              ),
              const SizedBox(height: 10),
              Text(creditsLabel, style: VerbenaText.body(size: 13.5, color: VerbenaColors.textMuted)),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: onTap,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: buttonColor,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  child: Text(
                    buttonLabel.toUpperCase(),
                    style: VerbenaText.display(size: 14, color: VerbenaColors.background, letterSpacing: 0.4),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (badgeLabel != null)
          Positioned(
            top: -11,
            left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: VerbenaColors.terracotta, borderRadius: BorderRadius.circular(999)),
              child: Text(
                badgeLabel!,
                style: VerbenaText.body(
                  size: 11,
                  weight: FontWeight.w700,
                  color: VerbenaColors.background,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
