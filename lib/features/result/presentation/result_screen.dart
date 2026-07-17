import 'package:flutter/material.dart';

import '../../../core/theme/verbena_theme.dart';

// TODO(fase C): imagen a sangre completa + botón cerrar superpuesto,
// caption + etiqueta de crédito consumido, botón WhatsApp (share_plus),
// y las 3 acciones secundarias (Guardar / Otra vez / Otra plantilla).
class ResultScreen extends StatelessWidget {
  const ResultScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: Center(
        child: Text('Resultado', style: VerbenaText.display()),
      ),
    );
  }
}
