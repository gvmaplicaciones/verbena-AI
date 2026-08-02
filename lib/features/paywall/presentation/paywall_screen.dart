import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../../../core/constants/credits.dart';
import '../../../core/router/app_routes.dart';
import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../core/utils/navigation.dart';
import '../../../core/widgets/before_after_crossfade.dart';
import '../../../data/models/plan.dart';
import '../../../data/models/user_credits.dart';
import '../../../data/repositories/auth_repository.dart';
import '../../../data/repositories/credits_repository.dart';
import '../../../data/repositories/plans_repository.dart';
import '../../../data/repositories/purchases_repository.dart';
import '../../../services/analytics_service.dart';

/// Precio por foto del plan mensual redondeado hacia arriba a los 5 céntimos
/// más cercanos, para que el "menos de" del texto sea siempre estrictamente
/// cierto frente al precio real de la tienda (nunca un número inventado).
String? _pricePerPhotoLabel(
    double totalPrice, int credits, String currencyCode) {
  if (credits <= 0) return null;
  final exact = totalPrice / credits;
  final rounded = (exact * 20).ceilToDouble() / 20;
  final amount = rounded.toStringAsFixed(2).replaceAll('.', ',');
  final symbol = currencyCode == 'EUR' ? '€' : ' $currencyCode';
  return 'Menos de $amount$symbol por foto';
}

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
  String _selectedPlanId = PlanIds.mensual;

  @override
  void initState() {
    super.initState();
    AnalyticsService.paywallViewed(source: widget.source);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _buy(
    String productId,
    Future<void> Function() onSuccess, {
    bool requireEntitlement = false,
  }) async {
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
      final customerInfo = await repo.purchasePackage(package);
      // purchasePackage() puede resolver sin lanzar aunque la tienda haya
      // dejado el pago en estado pendiente (p.ej. un método de pago que tarda
      // en confirmarse) -- sin esta comprobación se navegaba a éxito con un
      // entitlement todavía inactivo, sin recibo de Google Play ni registro
      // en RevenueCat.
      if (requireEntitlement &&
          !customerInfo.entitlements.active
              .containsKey(RevenueCatEntitlements.pro)) {
        _showProcessingSnack();
        return;
      }
      await repo.reconcile();
      ref.invalidate(myCreditsProvider);
      await AnalyticsService.purchaseCompleted(
        planId: productId,
        transactionIdentifier: repo.lastTransactionIdentifier,
      );
      if (!mounted) return;
      await onSuccess();
    } on PlatformException catch (e) {
      final code = PurchasesErrorHelper.getErrorCode(e);
      if (code == PurchasesErrorCode.purchaseCancelledError) {
        return;
      }
      if (code == PurchasesErrorCode.paymentPendingError) {
        _showProcessingSnack();
        return;
      }
      _showSnack('No hemos podido completar la compra.');
    } catch (_) {
      _showSnack('No hemos podido completar la compra.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showProcessingSnack() {
    _showSnack('Tu pago se está procesando, te avisaremos en cuanto se confirme.');
  }

  Future<void> _subscribeSemanal() => _buy(
        PlanIds.semanal,
        () async {
          if (mounted) context.safePop();
        },
        requireEntitlement: true,
      );

  Future<void> _subscribeMensual() => _buy(
        PlanIds.mensual,
        () async {
          if (mounted) context.safePop();
        },
        requireEntitlement: true,
      );

  Future<void> _subscribeSelected() => _selectedPlanId == PlanIds.semanal
      ? _subscribeSemanal()
      : _subscribeMensual();

  Future<void> _buyExtra() => _buy(ExtraPackIds.extra7, () async {
        if (mounted) setState(() => _justBoughtPackId = ExtraPackIds.extra7);
      });

  /// Requisito de aprobación de tienda: toda pantalla de compra necesita una
  /// vía visible para recuperar compras ya hechas (p.ej. tras reinstalar).
  Future<void> _restorePurchases() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final repo = ref.read(purchasesRepositoryProvider);
      await repo.restorePurchases();
      await repo.reconcile();
      ref.invalidate(myCreditsProvider);
      _showSnack('Tus compras se han restaurado.');
    } catch (_) {
      _showSnack('No hemos podido restaurar tus compras.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final creditsAsync = ref.watch(myCreditsProvider);
    final plansAsync = ref.watch(plansProvider);

    return Scaffold(
      backgroundColor: VerbenaColors.background,
      // top: false -- el hero de arriba ya gestiona su propia SafeArea para
      // que la foto pueda sangrar bajo la barra de estado.
      body: SafeArea(
        top: false,
        child: creditsAsync.when(
          loading: () => const Center(
              child: CircularProgressIndicator(color: VerbenaColors.teal)),
          error: (err, st) => Center(
              child: Text('No hemos podido cargar tu cuenta.',
                  style: VerbenaText.body())),
          data: (credits) => plansAsync.when(
            loading: () => const Center(
                child: CircularProgressIndicator(color: VerbenaColors.teal)),
            error: (err, st) => Center(
                child: Text('No hemos podido cargar los planes.',
                    style: VerbenaText.body())),
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
    final semanalPackage =
        offerings == null ? null : repo.findPackage(offerings, PlanIds.semanal);
    final mensualPackage =
        offerings == null ? null : repo.findPackage(offerings, PlanIds.mensual);
    final semanalPrice =
        semanalPackage?.storeProduct.priceString ?? semanal.priceDisplay;
    final mensualPrice =
        mensualPackage?.storeProduct.priceString ?? mensual.priceDisplay;
    final pricePerPhoto = mensualPackage == null
        ? null
        : _pricePerPhotoLabel(mensualPackage.storeProduct.price,
            mensual.tierCredits, mensualPackage.storeProduct.currencyCode);
    final extraPacksAsync = ref.watch(extraPacksProvider);
    final extra = extraPacksAsync.valueOrNull
        ?.firstWhere((p) => p.packId == ExtraPackIds.extra7);
    final extraPrice = extra == null
        ? null
        : (offerings == null
            ? extra.priceDisplay
            : repo
                    .findPackage(offerings, ExtraPackIds.extra7)
                    ?.storeProduct
                    .priceString ??
                extra.priceDisplay);

    return AbsorbPointer(
      absorbing: _busy,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PaywallHero(
                onClose: () => context.safePop(),
                onRestore: _busy ? null : _restorePurchases),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('DESBLOQUEA TODO VERBENAI',
                      style: VerbenaText.display(size: 25)),
                  const SizedBox(height: 16),
                  _BenefitRow(
                      '${mensual.tierCredits} fotos al mes con el plan mensual'),
                  const _BenefitRow('Los 6 modos de edición sin límites'),
                  const _BenefitRow('Guarda tus favoritas para siempre'),
                  const _BenefitRow('Tu armario con hasta 30 prendas'),
                  const SizedBox(height: 6),
                  if (credits.canUseFreeGeneration) ...[
                    GestureDetector(
                      // Accionable: cierra el paywall y deja al usuario justo donde
                      // estaba para elegir foto/modo y generar con su gratis.
                      onTap: () => context.safePop(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: VerbenaColors.card,
                          border: Border.all(
                              color: VerbenaColors.terracotta, width: 1.5),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Tu primera foto va gratis',
                                    style: VerbenaText.body(
                                        size: 14.5,
                                        weight: FontWeight.w700,
                                        color: VerbenaColors.terracotta),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Sin trampa ni cartón. Toca para probarlo antes de suscribirte.',
                                    style: VerbenaText.body(
                                        size: 12.5,
                                        color: VerbenaColors.textMuted),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right_rounded,
                                color: VerbenaColors.terracotta),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  _PlanCard(
                    title: 'Semanal',
                    price: semanalPrice,
                    cadence: '/semana',
                    creditsLabel: '${semanal.tierCredits} fotos por semana',
                    accentColor: VerbenaColors.teal,
                    selected: _selectedPlanId == PlanIds.semanal,
                    onTap: () =>
                        setState(() => _selectedPlanId = PlanIds.semanal),
                  ),
                  const SizedBox(height: 14),
                  _PlanCard(
                    title: 'Mensual',
                    price: mensualPrice,
                    cadence: '/mes',
                    creditsLabel: '${mensual.tierCredits} fotos al mes',
                    accentColor: VerbenaColors.terracotta,
                    selected: _selectedPlanId == PlanIds.mensual,
                    onTap: () =>
                        setState(() => _selectedPlanId = PlanIds.mensual),
                    badgeLabel: 'MEJOR VALOR',
                    priceHighlight: pricePerPhoto,
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _subscribeSelected,
                      child: Text('EMPEZAR',
                          style: VerbenaText.display(
                              size: 16, color: VerbenaColors.background)),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Se renueva automáticamente hasta que la canceles. Cancela cuando quieras, sin líos ni permanencia.',
                      textAlign: TextAlign.center,
                      style: VerbenaText.body(
                          size: 12, color: VerbenaColors.textMuted),
                    ),
                  ),
                  Center(
                    child: TextButton(
                      onPressed: () => context.push(AppRoutes.privacyPolicy),
                      child: Text(
                        'Política de privacidad',
                        style: VerbenaText.body(
                                size: 12, color: VerbenaColors.textMuted)
                            .copyWith(decoration: TextDecoration.underline),
                      ),
                    ),
                  ),
                  if (credits.hasActiveAccess && extra != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color:
                                VerbenaColors.textDark.withValues(alpha: 0.3),
                            width: 1.5),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Recarga rápida — ${extra.credits} fotos',
                            style: VerbenaText.body(
                                size: 14.5, weight: FontWeight.w700),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Esto es una recarga puntual, no sustituye tu suscripción.',
                            style: VerbenaText.body(
                                size: 12.5, color: VerbenaColors.textMuted),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton(
                              onPressed: _buyExtra,
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(
                                    color: VerbenaColors.teal, width: 2),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                              ),
                              child: Text(
                                'Comprar por $extraPrice',
                                style: VerbenaText.display(
                                    size: 13,
                                    color: VerbenaColors.teal,
                                    letterSpacing: 0.3),
                              ),
                            ),
                          ),
                          if (_justBoughtPackId == ExtraPackIds.extra7) ...[
                            const SizedBox(height: 4),
                            Text(
                              '¡Recarga añadida a tu cuenta!',
                              textAlign: TextAlign.center,
                              style: VerbenaText.body(
                                  size: 12,
                                  weight: FontWeight.w700,
                                  color: VerbenaColors.teal),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tercio superior: par antes/después en crossfade (mismo componente que las
/// miniaturas de modo de Home) con degradado hacia el crema del fondo para
/// que el titular se lea bien. X y "Restaurar compras" siempre visibles y
/// accesibles encima de la foto -- nunca bloquean la salida.
class _PaywallHero extends StatelessWidget {
  const _PaywallHero({required this.onClose, required this.onRestore});

  final VoidCallback onClose;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 300,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const BeforeAfterCrossfade(
            beforeAsset: 'assets/modes/background-before.jpg',
            afterAsset: 'assets/modes/background-after.jpg',
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, VerbenaColors.background],
                stops: [0.45, 1],
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    VerbenaRoundIconButton(
                      icon:
                          const VerbenaCloseIcon(size: 14, color: Colors.white),
                      onTap: onClose,
                      background: const Color(0x73000000),
                    ),
                    GestureDetector(
                      onTap: onRestore,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          color: const Color(0x73000000),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'Restaurar compras',
                          style: VerbenaText.body(
                              size: 12.5,
                              weight: FontWeight.w600,
                              color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BenefitRow extends StatelessWidget {
  const _BenefitRow(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const VerbenaCheckmarkIcon(size: 19, color: VerbenaColors.teal),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: VerbenaText.body(size: 14.5, weight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

/// Tarjeta seleccionable (no cada una con su propio botón de compra) -- el
/// patrón "elige tarjeta + un único CTA" es el de mayor conversión en la
/// categoría. El estado seleccionado no dispara la compra, solo decide qué
/// plan compra el botón EMPEZAR.
class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.title,
    required this.price,
    required this.cadence,
    required this.creditsLabel,
    required this.accentColor,
    required this.selected,
    required this.onTap,
    this.badgeLabel,
    this.priceHighlight,
  });

  final String title;
  final String price;
  final String cadence;
  final String creditsLabel;
  final Color accentColor;
  final bool selected;
  final VoidCallback onTap;
  final String? badgeLabel;
  final String? priceHighlight;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: VerbenaColors.card,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected
                    ? accentColor
                    : VerbenaColors.textDark.withValues(alpha: 0.15),
                width: selected ? 2.5 : 1.5,
              ),
            ),
            child: Row(
              children: [
                _RadioDot(selected: selected, color: accentColor),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(title.toUpperCase(),
                              style: VerbenaText.display(size: 15)),
                          const SizedBox(width: 8),
                          Text(price,
                              style: VerbenaText.display(
                                  size: 20, color: accentColor)),
                          const SizedBox(width: 3),
                          Text(cadence,
                              style: VerbenaText.body(
                                  size: 12, color: VerbenaColors.textMuted)),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(creditsLabel,
                          style: VerbenaText.body(
                              size: 13, color: VerbenaColors.textMuted)),
                      if (priceHighlight != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: accentColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            priceHighlight!,
                            style: VerbenaText.body(
                                size: 12.5,
                                weight: FontWeight.w700,
                                color: accentColor),
                          ),
                        ),
                      ],
                    ],
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: VerbenaColors.terracotta,
                    borderRadius: BorderRadius.circular(999)),
                child: Text(
                  badgeLabel!,
                  style: VerbenaText.body(
                      size: 11,
                      weight: FontWeight.w700,
                      color: VerbenaColors.background),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RadioDot extends StatelessWidget {
  const _RadioDot({required this.selected, required this.color});

  final bool selected;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? color : Colors.transparent,
        border: Border.all(
            color: selected
                ? color
                : VerbenaColors.textDark.withValues(alpha: 0.25),
            width: 2),
      ),
      alignment: Alignment.center,
      child: selected
          ? Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                  shape: BoxShape.circle, color: VerbenaColors.card),
            )
          : null,
    );
  }
}
