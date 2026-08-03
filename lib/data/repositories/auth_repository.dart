import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers/supabase_provider.dart';

// TODO(debug bad_jwt): breadcrumb temporal para diagnosticar "invalid claim:
// missing sub claim" en linkIdentityWithIdToken/Google -- decodifica el
// payload real del idToken justo antes de mandarlo a Supabase y lo deja
// como breadcrumb, así queda adjunto en Sentry al AuthException(bad_jwt) que
// account_gate_screen.dart ya captura justo después. El iPhone de prueba no
// tiene consola visible, por eso Sentry y no solo debugPrint. Quitar este
// breadcrumb (y el import de sentry_flutter si deja de hacer falta aquí) en
// cuanto se confirme la causa real -- el payload decodificado puede incluir
// email/nombre del usuario.
Future<void> _debugLogIdTokenPayload(String source, String idToken) async {
  final parts = idToken.split('.');
  final data = <String, dynamic>{'parts': parts.length, 'length': idToken.length};
  if (parts.length != 3) {
    data['error'] = 'idToken no tiene forma de JWT (esperadas 3 partes)';
  } else {
    try {
      var payload = parts[1];
      payload += '=' * ((4 - payload.length % 4) % 4);
      data['payload'] = utf8.decode(base64Url.decode(payload));
    } catch (e) {
      data['error'] = 'no se pudo decodificar el payload: $e';
    }
  }
  debugPrint('[bad_jwt debug] $source idToken: $data');
  await Sentry.addBreadcrumb(
    Breadcrumb(
      category: 'auth.bad_jwt_debug',
      message: '$source idToken payload (debug temporal)',
      data: data,
      level: SentryLevel.info,
    ),
  );
}

class AuthRepository {
  AuthRepository(this._client);

  final SupabaseClient _client;

  bool get isAnonymous => _client.auth.currentUser?.isAnonymous ?? true;

  /// Dispara el selector nativo de cuentas de Google y devuelve el idToken +
  /// accessToken necesarios para linkIdentityWithIdToken/signInWithIdToken.
  /// El accessToken ya no viene junto al idToken desde google_sign_in v7 --
  /// hay que pedirlo aparte vía authorizationClient. Lanza
  /// GoogleSignInException si el usuario cancela o falla el selector.
  Future<({String idToken, String accessToken})> _googleTokens() async {
    final account = await GoogleSignIn.instance.authenticate();
    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw const AuthException('Google no devolvió un idToken.');
    }
    await _debugLogIdTokenPayload('Google', idToken);
    final authorization = await account.authorizationClient.authorizeScopes(['email']);
    return (idToken: idToken, accessToken: authorization.accessToken);
  }

  /// Igual que [linkEmailPassword] pero con Google: vincula la sesión
  /// anónima actual sin crear un usuario nuevo (mismo user_id).
  Future<void> linkGoogle() async {
    final tokens = await _googleTokens();
    await _client.auth.linkIdentityWithIdToken(
      provider: OAuthProvider.google,
      idToken: tokens.idToken,
      accessToken: tokens.accessToken,
    );
  }

  /// Igual que [signInExisting] pero con Google: sustituye la sesión anónima
  /// actual por la cuenta real ya vinculada a esta cuenta de Google (user_id
  /// distinto -- el caller debe reconfigurar RevenueCat después).
  Future<AuthResponse> signInWithGoogle() async {
    final tokens = await _googleTokens();
    return _client.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: tokens.idToken,
      accessToken: tokens.accessToken,
    );
  }

  /// Pide credenciales de Apple y devuelve el idToken + el nonce en claro
  /// necesarios para linkIdentityWithIdToken/signInWithIdToken. Apple exige
  /// mandarle el hash SHA-256 del nonce (mitiga replay); Supabase, en
  /// cambio, necesita el nonce en claro para compararlo contra el hash que
  /// viene embebido dentro del idToken firmado por Apple. Lanza
  /// SignInWithAppleAuthorizationException si el usuario cancela o falla.
  Future<({String idToken, String rawNonce})> _appleTokens() async {
    final rawNonce = generateNonce();
    final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
      nonce: hashedNonce,
    );
    final idToken = credential.identityToken;
    if (idToken == null) {
      throw const AuthException('Apple no devolvió un idToken.');
    }
    return (idToken: idToken, rawNonce: rawNonce);
  }

  /// Igual que [linkGoogle] pero con Apple: vincula la sesión anónima actual
  /// sin crear un usuario nuevo (mismo user_id).
  Future<void> linkApple() async {
    final tokens = await _appleTokens();
    await _client.auth.linkIdentityWithIdToken(
      provider: OAuthProvider.apple,
      idToken: tokens.idToken,
      nonce: tokens.rawNonce,
    );
  }

  /// Igual que [signInWithGoogle] pero con Apple: sustituye la sesión
  /// anónima actual por la cuenta real ya vinculada a este Apple ID
  /// (user_id distinto -- el caller debe reconfigurar RevenueCat después).
  Future<AuthResponse> signInWithApple() async {
    final tokens = await _appleTokens();
    return _client.auth.signInWithIdToken(
      provider: OAuthProvider.apple,
      idToken: tokens.idToken,
      nonce: tokens.rawNonce,
    );
  }

  /// Vincula la sesión anónima actual a un email+contraseña reales sin crear
  /// un usuario nuevo -- Supabase conserva el mismo user_id, así que
  /// fotos/créditos/historial siguen intactos y RevenueCat (appUserID =
  /// user_id, ver main.dart) no necesita reconfigurarse.
  Future<void> linkEmailPassword({required String email, required String password}) {
    return _client.auth.updateUser(UserAttributes(email: email, password: password));
  }

  /// Para un usuario que reinstaló y ya tenía cuenta: sustituye la sesión
  /// anónima actual (se descarta) por la cuenta real existente, con un
  /// user_id distinto. El caller debe reconfigurar RevenueCat
  /// (Purchases.logIn + restorePurchases) y refrescar créditos después.
  Future<AuthResponse> signInExisting({required String email, required String password}) {
    return _client.auth.signInWithPassword(email: email, password: password);
  }

  /// Cierra la sesión actual. Solo disponible para cuentas vinculadas
  /// (!isAnonymous) -- cerrar sesión en una cuenta anónima destruiría el
  /// acceso a los datos sin posibilidad de recuperarlos.
  Future<void> signOut() => _client.auth.signOut();

  /// Supabase manda el email de recuperación y gestiona el enlace -- de
  /// momento con su página web por defecto para fijar la contraseña nueva
  /// (sin deep link a la app, ver AccountGateScreen._forgotPassword).
  Future<void> resetPasswordForEmail(String email) =>
      _client.auth.resetPasswordForEmail(email);
}

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(ref.watch(supabaseClientProvider));
});
