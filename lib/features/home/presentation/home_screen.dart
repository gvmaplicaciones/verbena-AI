import 'package:flutter/material.dart';

import '../../../core/theme/verbena_theme.dart';

// TODO(fase C): recrear pixel-perfect la Home variante C (única variante a
// implementar): wordmark + avatar, tarjeta de créditos teal con badge
// terracota superpuesto "+N extra", tabs Catálogo/Libertad, grid de
// plantillas o textarea + chips de ejemplos según el tab activo.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: Center(
        child: Text('Home', style: VerbenaText.display()),
      ),
    );
  }
}
