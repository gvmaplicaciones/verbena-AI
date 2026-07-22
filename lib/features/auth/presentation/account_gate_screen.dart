import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/verbena_theme.dart';
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
      return 'Esa cuenta de Google ya está vinculada a otro usuario.';
    }
    return 'Algo ha fallado. Inténtalo de nuevo.';
  }

  /// Tras un signIn/signInWithGoogle que trae un user_id distinto al de la
  /// sesión anónima previa: reengancha RevenueCat a la identidad real y
  /// refresca créditos, igual que hace _submitSignIn con email.
  Future<void> _reconcileAfterSignIn() async {
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
  }

  Future<void> _continueWithGoogle() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_signInMode) {
        await ref.read(authRepositoryProvider).signInWithGoogle();
        await _reconcileAfterSignIn();
        if (!mounted) return;
        _showSnack('Sesión recuperada.');
        context.pop(false);
      } else {
        await ref.read(authRepositoryProvider).linkGoogle();
        if (!mounted) return;
        context.pop(true);
      }
    } on GoogleSignInException catch (e) {
      if (e.code != GoogleSignInExceptionCode.canceled) {
        setState(() => _error = 'No hemos podido continuar con Google.');
      }
    } on AuthException catch (e) {
      setState(() => _error = _friendlyError(e));
    } catch (_) {
      setState(() => _error = 'No hemos podido continuar con Google.');
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
      context.pop(true);
    } on AuthException catch (e) {
      setState(() => _error = _friendlyError(e));
    } catch (_) {
      setState(() => _error = 'No hemos podido crear tu cuenta. Inténtalo de nuevo.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitSignIn() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Rellena email y contraseña.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).signInExisting(email: email, password: password);
      await _reconcileAfterSignIn();
      if (!mounted) return;
      _showSnack('Sesión recuperada.');
      context.pop(false);
    } on AuthException catch (e) {
      setState(() => _error = _friendlyError(e));
    } catch (_) {
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
                    onPressed: _busy ? null : () => context.pop(false),
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
