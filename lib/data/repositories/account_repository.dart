import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers/supabase_provider.dart';

class AccountRepository {
  AccountRepository(this._client);
  final SupabaseClient _client;

  /// Borra la cuenta y todo su contenido (derecho al olvido, ver
  /// delete-user-data). No cancela la suscripción activa en Apple/Google --
  /// eso es responsabilidad de la tienda, fuera del alcance de este borrado.
  /// Tras borrar, se cierra la sesión y se abre una nueva sesión anónima para
  /// que la app quede en el mismo estado que un usuario nuevo.
  Future<void> deleteMyDataAndRestart() async {
    final response = await _client.functions.invoke('delete-user-data');
    if (response.status != 200) {
      final data = response.data;
      final message = data is Map ? data['error']?.toString() : null;
      throw AccountDeletionException(message ?? 'delete-user-data failed (${response.status})');
    }
    await _client.auth.signOut();
    await _client.auth.signInAnonymously();
  }
}

class AccountDeletionException implements Exception {
  AccountDeletionException(this.message);
  final String message;
  @override
  String toString() => message;
}

final accountRepositoryProvider = Provider<AccountRepository>((ref) {
  return AccountRepository(ref.watch(supabaseClientProvider));
});
