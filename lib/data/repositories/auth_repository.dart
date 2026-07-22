import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers/supabase_provider.dart';

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
}

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(ref.watch(supabaseClientProvider));
});
