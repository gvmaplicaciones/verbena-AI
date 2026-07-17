import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/theme/verbena_theme.dart';

class VerbenaApp extends ConsumerWidget {
  const VerbenaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'VerbenAI',
      debugShowCheckedModeBanner: false,
      theme: buildVerbenaTheme(),
      routerConfig: router,
    );
  }
}
