import 'package:flutter/material.dart';

import '../../../core/theme/verbena_theme.dart';

// TODO(fase C): recrear pixel-perfect las 3 slides del handoff (icono +
// título Anton + subtítulo + dots + botón Siguiente/Empezar).
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: Center(
        child: Text('Onboarding', style: VerbenaText.display()),
      ),
    );
  }
}
