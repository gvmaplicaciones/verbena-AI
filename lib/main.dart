import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config/env.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: Env.supabaseUrl,
    anonKey: Env.supabaseAnonKey,
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
  await Purchases.configure(PurchasesConfiguration(Env.revenueCatApiKey));

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
