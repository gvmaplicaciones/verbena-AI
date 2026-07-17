import 'package:flutter/material.dart';

import '../../../core/theme/verbena_theme.dart';

// TODO(fase C): recrear pixel-perfect las 3 opciones (Cámara, Galería,
// Fotos verificadas -- bloqueada con badge "SOLO SOCIOS" si no hay
// suscripción activa).
class PhotoSelectScreen extends StatelessWidget {
  const PhotoSelectScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: Center(
        child: Text('¿Con qué foto lo hacemos?', style: VerbenaText.display(size: 20)),
      ),
    );
  }
}
