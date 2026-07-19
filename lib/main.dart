import 'dart:io' show HttpClient, HttpOverrides, Platform, SecurityContext, X509Certificate;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config/env.dart';

// A diferencia de las llamadas nativas (Sentry, RevenueCat), que sí respetan
// network_security_config.xml, el HttpClient de dart:io usa su propio store
// de CAs (BoringSSL) e ignora las CAs de usuario/sistema de Android. Por eso
// Norton Web/Mail Shield rompe las llamadas de gotrue (signInAnonymously) en
// desarrollo aunque el certificado ya esté confiado a nivel de SO. Solo
// activo en kDebugMode, así que nunca aplica a un build de release.
class _DebugHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
    return client;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (kDebugMode) {
    HttpOverrides.global = _DebugHttpOverrides();
  }

  await Supabase.initialize(
    url: Env.supabaseUrl,
    publishableKey: Env.supabaseAnonKey,
  );

  // Auth anónima desde el primer uso, sin registro obligatorio. Se vincula a
  // una cuenta real (email/Apple/Google) solo si el usuario decide
  // restaurar en otro dispositivo -- RevenueCat asocia la compra al mismo
  // app_user_id anónimo, así que la restauración funciona sin login previo.
  final auth = Supabase.instance.client.auth;
  if (auth.currentSession == null) {
    await auth.signInAnonymously();
  }

  await Purchases.setLogLevel(LogLevel.info);
  // appUserID = uid anónimo de Supabase: así event.app_user_id en el webhook
  // de RevenueCat coincide siempre 1:1 con user_credits.user_id, sin tabla
  // de mapeo intermedia.
  final revenueCatApiKey = Platform.isIOS ? Env.revenueCatIosKey : Env.revenueCatAndroidKey;
  final purchasesConfig = PurchasesConfiguration(revenueCatApiKey)..appUserID = auth.currentUser!.id;
  await Purchases.configure(purchasesConfig);

  final posthogConfig = PostHogConfig(Env.posthogApiKey)
    ..host = Env.posthogHost
    ..captureApplicationLifecycleEvents = true;
  await Posthog().setup(posthogConfig);

  await SentryFlutter.init(
    (options) {
      options.dsn = Env.sentryDsn;
      options.tracesSampleRate = 1.0;
    },
    appRunner: () => runApp(const ProviderScope(child: VerbenaApp())),
  );
}
