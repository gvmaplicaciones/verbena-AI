import 'package:flutter/material.dart';

import '../../../core/theme/verbena_theme.dart';

// TODO(fase C): dos estados -- "Verificando tu foto" (spinner) y
// "Generando tu foto" (% + barra de progreso) -- pilotados por el estado
// real de verify-photo / generate-catalog / generate-libertad.
class ProcessingScreen extends StatelessWidget {
  const ProcessingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: Center(
        child: Text('Procesando…', style: VerbenaText.display()),
      ),
    );
  }
}
