import 'package:flutter/material.dart';

import '../../../core/theme/verbena_theme.dart';

// TODO(fase C): tarjeta de estado de suscripción, contadores de créditos,
// galería de fotos verificadas (socios) o CTA de suscripción, ajustes
// (privacidad / borrar datos vía delete-user-data), flujo de cancelación
// con confirmación.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: Center(
        child: Text('Tu perfil', style: VerbenaText.display()),
      ),
    );
  }
}
