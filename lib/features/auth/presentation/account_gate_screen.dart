import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/verbena_theme.dart';
import '../../../core/utils/navigation.dart';
import '../../../data/repositories/auth_repository.dart';
import '../../../data/repositories/credits_repository.dart';
import '../../../data/repositories/purchases_repository.dart';

/// Se muestra justo antes de completar una compra (o desde Perfil, para
/// recuperar una cuenta tras reinstalar). Dos modos:
///
/// - Crear cuenta: vincula la sesión anónima actual a email+contraseña
///   (mismo user_id, ver AuthRepository.linkEmailPassword) -- al éxito
///   devuelve `true`, señal para que el caller continúe con la compra
///   pendiente sobre la MISMA identidad.
/// - Iniciar sesión: para quien ya tenía cuenta en otro dispositivo o
///   reinstaló -- cambia a un user_id distinto, así que aquí mismo se
///   reconfigura RevenueCat (logIn + restorePurchases) y se refrescan
///   créditos. Devuelve `false`: el caller NO debe continuar la compra
///   pendiente a ciegas, porque puede que ya esté suscrito.
class AccountGateScreen extends ConsumerStatefulWidget {
  const AccountGateScreen({super.key, this.initialSignInMode = false});

  final bool initialSignInMode;

  @override
  ConsumerState<AccountGateScreen> createState() => _AccountGateScreenState();
}

class _AccountGateScreenState extends ConsumerState<AccountGateScreen> {
  late bool _signInMode = widget.initialSignInMode;
  final _emailController = TextEditingController();
  final _emailConfirmController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordConfirmController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _emailConfirmController.dispose();
    _passwordController.dispose();
    _passwordConfirmController.dispose();
    super.dispose();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _friendlyError(AuthException e) {
    final msg = e.message.toLowerCase();
    if (msg.contains('already registered') || msg.contains('already exists') || msg.contains('already been registered')) {
      return 'Ese email ya tiene una cuenta. Prueba a iniciar sesión.';
    }
    if (msg.contains('invalid login credentials')) {
      return 'Email o contraseña incorrectos.';
    }
    if (msg.contains('password') && (msg.contains('least') || msg.contains('short'))) {
      return 'La contraseña debe tener al menos 6 caracteres.';
    }
    if (msg.contains('identity is already linked')) {
      return 'Esa cuenta ya está vinculada a otro usuario.';
    }
    return 'Algo ha fallado. Inténtalo de nuevo.';
  }

  /// Tras un signIn/signInWithGoogle que trae un user_id distinto al de la
  /// sesión anónima previa: reengancha RevenueCat a la identidad real y
  /// refresca créditos, igual que hace _submitSignIn con email. Devuelve si
  /// la cuenta recuperada quedó con acceso de suscripción activo --
  /// úsalo para avisar si la compra real puede estar en otra cuenta de este
  /// mismo dispositivo (ver _confirmSignInIfActiveSubscription).
  Future<bool> _reconcileAfterSignIn() async {
    final newUserId = Supabase.instance.client.auth.currentUser?.id;
    if (newUserId != null) {
      await Purchases.logIn(newUserId);
      try {
        await Purchases.restorePurchases();
      } catch (_) {
        // Best-effort: si no hay nada que restaurar o la tienda no responde,
        // seguimos igualmente -- reconcile() de abajo ya deja user_credits al
        // día con lo que RevenueCat sepa.
      }
      try {
        await ref.read(purchasesRepositoryProvider).reconcile();
      } catch (_) {}
    }
    ref.invalidate(myCreditsProvider);
    try {
      final credits = await ref.read(myCreditsProvider.future);
      return credits.hasActiveAccess;
    } catch (_) {
      // No penalizar con el aviso de "sin suscripción" si ni siquiera hemos
      // podido comprobarlo -- mejor un falso negativo que alarmar sin base.
      return true;
    }
  }

  /// Una compra de Apple/Google (recibo de la tienda) solo puede pertenecer
  /// a un app_user_id de RevenueCat a la vez -- si la sesión actual ya tiene
  /// suscripción activa y el usuario va a "Iniciar sesión" (cambia a un
  /// user_id distinto, ver comentario de clase), esa suscripción se moverá a
  /// la cuenta nueva y esta la perderá. Confirmado en producción el
  /// 2026-08-05: un usuario probando con dos cuentas en el mismo dispositivo
  /// vio la suscripción rebotar de una a otra sin entender por qué.
  Future<bool> _confirmSignInIfActiveSubscription() async {
    final credits = ref.read(myCreditsProvider).valueOrNull;
    if (credits == null || !credits.hasActiveAccess) return true;
    if (!mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: VerbenaColors.card,
        title: Text('Tienes una suscripción activa aquí', style: VerbenaText.display(size: 17)),
        content: Text(
          'Si inicias sesión con otra cuenta, tu suscripción de este dispositivo pasará a esa cuenta y la perderás aquí. ¿Seguro que quieres continuar?',
          style: VerbenaText.body(size: 13.5, color: VerbenaColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancelar', style: VerbenaText.body(size: 13.5, weight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Continuar',
                style: VerbenaText.body(size: 13.5, weight: FontWeight.w700, color: VerbenaColors.terracotta)),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// Se muestra tras recuperar sesión si la cuenta resultante no tiene
  /// suscripción activa -- guía directa para el caso de "compré pero no me
  /// aparece" cuando la compra real está en otra cuenta usada en este mismo
  /// dispositivo (ver _confirmSignInIfActiveSubscription, mismo problema al
  /// revés).
  void _showNoActiveSubscriptionNotice() {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: VerbenaColors.card,
        title: Text('Sesión recuperada', style: VerbenaText.display(size: 17)),
        content: Text(
          'Esta cuenta no tiene ninguna suscripción activa. Si ya pagaste desde este dispositivo, es posible que la compra esté en otra cuenta que hayas usado aquí -- cierra sesión y prueba a iniciar sesión con esa cuenta.',
          style: VerbenaText.body(size: 13.5, color: VerbenaColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Entendido', style: VerbenaText.body(size: 13.5, weight: FontWeight.w700, color: VerbenaColors.teal)),
          ),
        ],
      ),
    );
  }

  Future<void> _continueWithGoogle() async {
    if (_signInMode && !await _confirmSignInIfActiveSubscription()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_signInMode) {
        await ref.read(authRepositoryProvider).signInWithGoogle();
        final hasSubscription = await _reconcileAfterSignIn();
        if (!mounted) return;
        if (hasSubscription) {
          _showSnack('Sesión recuperada.');
        } else {
          _showNoActiveSubscriptionNotice();
        }
        context.safePop(false);
      } else {
        await ref.read(authRepositoryProvider).linkGoogle();
        if (!mounted) return;
        context.safePop(true);
      }
    } on GoogleSignInException catch (e, st) {
      developer.log('googleSignIn failed: code=${e.code} description=${e.description} details=${e.details}',
          name: 'AccountGateScreen', error: e, stackTrace: st);
      if (e.code != GoogleSignInExceptionCode.canceled) {
        unawaited(Sentry.captureException(e,
            stackTrace: st, hint: Hint.withMap({'stage': 'googleSignIn'})));
        setState(() => _error = 'No hemos podido continuar con Google.');
      }
    } on AuthException catch (e, st) {
      developer.log('googleSignIn failed (AuthException): ${e.message} statusCode=${e.statusCode} code=${e.code}',
          name: 'AccountGateScreen', error: e, stackTrace: st);
      unawaited(Sentry.captureException(e,
          stackTrace: st, hint: Hint.withMap({'stage': 'googleSignIn'})));
      setState(() => _error = _friendlyError(e));
    } catch (e, st) {
      developer.log('googleSignIn failed (unexpected ${e.runtimeType}): $e',
          name: 'AccountGateScreen', error: e, stackTrace: st);
      unawaited(Sentry.captureException(e,
          stackTrace: st, hint: Hint.withMap({'stage': 'googleSignIn'})));
      setState(() => _error = 'No hemos podido continuar con Google.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Mismo patrón que [_continueWithGoogle]. Solo se llama desde el botón de
  /// Apple, que a su vez solo se muestra en iOS (ver build()) -- en Android,
  /// Apple no exige ofrecer este inicio de sesión.
  Future<void> _continueWithApple() async {
    if (_signInMode && !await _confirmSignInIfActiveSubscription()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_signInMode) {
        await ref.read(authRepositoryProvider).signInWithApple();
        final hasSubscription = await _reconcileAfterSignIn();
        if (!mounted) return;
        if (hasSubscription) {
          _showSnack('Sesión recuperada.');
        } else {
          _showNoActiveSubscriptionNotice();
        }
        context.safePop(false);
      } else {
        await ref.read(authRepositoryProvider).linkApple();
        if (!mounted) return;
        context.safePop(true);
      }
    } on SignInWithAppleAuthorizationException catch (e, st) {
      developer.log('appleSignIn failed: code=${e.code} message=${e.message}',
          name: 'AccountGateScreen', error: e, stackTrace: st);
      if (e.code != AuthorizationErrorCode.canceled) {
        unawaited(Sentry.captureException(e,
            stackTrace: st, hint: Hint.withMap({'stage': 'appleSignIn'})));
        setState(() => _error = 'No hemos podido continuar con Apple.');
      }
    } on AuthException catch (e, st) {
      developer.log('appleSignIn failed (AuthException): ${e.message} statusCode=${e.statusCode} code=${e.code}',
          name: 'AccountGateScreen', error: e, stackTrace: st);
      unawaited(Sentry.captureException(e,
          stackTrace: st, hint: Hint.withMap({'stage': 'appleSignIn'})));
      setState(() => _error = _friendlyError(e));
    } catch (e, st) {
      developer.log('appleSignIn failed (unexpected ${e.runtimeType}): $e',
          name: 'AccountGateScreen', error: e, stackTrace: st);
      unawaited(Sentry.captureException(e,
          stackTrace: st, hint: Hint.withMap({'stage': 'appleSignIn'})));
      setState(() => _error = 'No hemos podido continuar con Apple.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitCreate() async {
    final email = _emailController.text.trim();
    final emailConfirm = _emailConfirmController.text.trim();
    final password = _passwordController.text;
    final passwordConfirm = _passwordConfirmController.text;

    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Escribe un email válido.');
      return;
    }
    if (email != emailConfirm) {
      setState(() => _error = 'Los dos emails no coinciden.');
      return;
    }
    if (password.length < 6) {
      setState(() => _error = 'La contraseña debe tener al menos 6 caracteres.');
      return;
    }
    if (password != passwordConfirm) {
      setState(() => _error = 'Las dos contraseñas no coinciden.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).linkEmailPassword(email: email, password: password);
      if (!mounted) return;
      context.safePop(true);
    } on AuthException catch (e, st) {
      developer.log('createAccount failed (AuthException): ${e.message} statusCode=${e.statusCode} code=${e.code}',
          name: 'AccountGateScreen', error: e, stackTrace: st);
      unawaited(Sentry.captureException(e,
          stackTrace: st, hint: Hint.withMap({'stage': 'emailCreateAccount'})));
      setState(() => _error = _friendlyError(e));
    } catch (e, st) {
      developer.log('createAccount failed (unexpected ${e.runtimeType}): $e',
          name: 'AccountGateScreen', error: e, stackTrace: st);
      unawaited(Sentry.captureException(e,
          stackTrace: st, hint: Hint.withMap({'stage': 'emailCreateAccount'})));
      setState(() => _error = 'No hemos podido crear tu cuenta. Inténtalo de nuevo.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Pide el email (reutilizando el que ya haya en el campo, si lo hay) y
  /// dispara resetPasswordForEmail. Mensaje de confirmación siempre igual,
  /// exista o no esa cuenta -- no hay que filtrar esa información.
  Future<void> _forgotPassword() async {
    final controller = TextEditingController(text: _emailController.text.trim());
    final email = await showDialog<String>(
      context: context,
      builder: (context) => _ForgotPasswordDialog(controller: controller),
    );
    controller.dispose();
    if (email == null || !mounted) return;
    try {
      await ref.read(authRepositoryProvider).resetPasswordForEmail(email);
    } catch (_) {
      // Mismo mensaje pase lo que pase, ver comentario de arriba.
    }
    if (!mounted) return;
    _showSnack('Te hemos enviado un email para restablecer tu contraseña.');
  }

  Future<void> _submitSignIn() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Rellena email y contraseña.');
      return;
    }
    if (!await _confirmSignInIfActiveSubscription()) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).signInExisting(email: email, password: password);
      final hasSubscription = await _reconcileAfterSignIn();
      if (!mounted) return;
      if (hasSubscription) {
        _showSnack('Sesión recuperada.');
      } else {
        _showNoActiveSubscriptionNotice();
      }
      context.safePop(false);
    } on AuthException catch (e, st) {
      developer.log('signIn failed (AuthException): ${e.message} statusCode=${e.statusCode} code=${e.code}',
          name: 'AccountGateScreen', error: e, stackTrace: st);
      unawaited(Sentry.captureException(e,
          stackTrace: st, hint: Hint.withMap({'stage': 'emailSignIn'})));
      setState(() => _error = _friendlyError(e));
    } catch (e, st) {
      developer.log('signIn failed (unexpected ${e.runtimeType}): $e',
          name: 'AccountGateScreen', error: e, stackTrace: st);
      unawaited(Sentry.captureException(e,
          stackTrace: st, hint: Hint.withMap({'stage': 'emailSignIn'})));
      setState(() => _error = 'No hemos podido iniciar sesión. Revisa tus datos.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: _busy,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),
                Text(
                  _signInMode ? 'Recupera tu cuenta' : 'Protege tu compra',
                  style: VerbenaText.display(size: 22),
                ),
                const SizedBox(height: 8),
                Text(
                  _signInMode
                      ? 'Inicia sesión con la cuenta que ya creaste antes.'
                      : 'Crea una cuenta con email y contraseña para poder recuperar tu suscripción si reinstalas la app o cambias de móvil.',
                  style: VerbenaText.body(size: 13.5, color: VerbenaColors.textMuted),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                if (!_signInMode) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _emailConfirmController,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'Repite tu email'),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Contraseña'),
                  onSubmitted: (_) => _signInMode ? _submitSignIn() : _submitCreate(),
                ),
                if (!_signInMode) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passwordConfirmController,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Repite tu contraseña'),
                    onSubmitted: (_) => _submitCreate(),
                  ),
                ],
                if (_signInMode)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _busy ? null : _forgotPassword,
                      child: Text('¿Has olvidado tu contraseña?',
                          style: VerbenaText.body(size: 12.5, weight: FontWeight.w600, color: VerbenaColors.teal)),
                    ),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: VerbenaText.body(size: 13, color: VerbenaColors.terracotta)),
                ],
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _busy ? null : (_signInMode ? _submitSignIn : _submitCreate),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: VerbenaColors.teal,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Text(
                          (_signInMode ? 'iniciar sesión' : 'crear cuenta').toUpperCase(),
                          style: VerbenaText.display(size: 14, color: VerbenaColors.background, letterSpacing: 0.4),
                        ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(child: Divider(color: VerbenaColors.textMuted.withValues(alpha: 0.3))),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text('o', style: VerbenaText.body(size: 12, color: VerbenaColors.textMuted)),
                    ),
                    Expanded(child: Divider(color: VerbenaColors.textMuted.withValues(alpha: 0.3))),
                  ],
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: _busy ? null : _continueWithGoogle,
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: BorderSide(color: VerbenaColors.textMuted.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Image.asset('assets/icons/google_logo.png', width: 18, height: 18),
                      const SizedBox(width: 10),
                      Text(
                        'Continuar con Google',
                        style: VerbenaText.body(size: 14, weight: FontWeight.w600, color: VerbenaColors.textDark),
                      ),
                    ],
                  ),
                ),
                if (Platform.isIOS) ...[
                  const SizedBox(height: 12),
                  SignInWithAppleButton(
                    onPressed: _busy ? null : _continueWithApple,
                    text: 'Continuar con Apple',
                    height: 48,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ],
                const SizedBox(height: 16),
                Center(
                  child: TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                              _signInMode = !_signInMode;
                              _error = null;
                            }),
                    child: Text(
                      _signInMode ? '¿No tienes cuenta todavía? Crear cuenta' : '¿Ya tienes cuenta? Iniciar sesión',
                      style: VerbenaText.body(size: 13, weight: FontWeight.w600, color: VerbenaColors.teal),
                    ),
                  ),
                ),
                Center(
                  child: TextButton(
                    onPressed: _busy ? null : () => context.safePop(false),
                    child: Text('Ahora no', style: VerbenaText.body(size: 13, color: VerbenaColors.textMuted)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Diálogo mínimo para pedir el email antes de resetPasswordForEmail --
/// prerellenado con lo que el usuario ya hubiera escrito en la pantalla.
class _ForgotPasswordDialog extends StatefulWidget {
  const _ForgotPasswordDialog({required this.controller});

  final TextEditingController controller;

  @override
  State<_ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<_ForgotPasswordDialog> {
  String? _error;

  void _submit() {
    final email = widget.controller.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Escribe un email válido.');
      return;
    }
    Navigator.of(context).pop(email);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: VerbenaColors.card,
      title: Text('Recuperar contraseña', style: VerbenaText.display(size: 17)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Te mandamos un enlace para elegir una contraseña nueva.',
            style: VerbenaText.body(size: 13, color: VerbenaColors.textMuted),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: widget.controller,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Email'),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: VerbenaText.body(size: 12.5, color: VerbenaColors.terracotta)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancelar', style: VerbenaText.body(size: 13.5, weight: FontWeight.w600)),
        ),
        TextButton(
          onPressed: _submit,
          child: Text('Enviar',
              style: VerbenaText.body(size: 13.5, weight: FontWeight.w700, color: VerbenaColors.teal)),
        ),
      ],
    );
  }
}
