import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../core/utils/navigation.dart';

class PrivacyPolicyScreen extends StatefulWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  State<PrivacyPolicyScreen> createState() => _PrivacyPolicyScreenState();
}

class _PrivacyPolicyScreenState extends State<PrivacyPolicyScreen> {
  late final TapGestureRecognizer _appleRecognizer;
  late final TapGestureRecognizer _googleRecognizer;

  @override
  void initState() {
    super.initState();
    _appleRecognizer = TapGestureRecognizer()
      ..onTap = () => _openLink('https://support.apple.com/es-es/HT202039');
    _googleRecognizer = TapGestureRecognizer()
      ..onTap = () => _openLink('https://support.google.com/googleplay/answer/7018481');
  }

  @override
  void dispose() {
    _appleRecognizer.dispose();
    _googleRecognizer.dispose();
    super.dispose();
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  TextStyle get _bodyStyle => VerbenaText.body(size: 14, color: VerbenaColors.textDark).copyWith(height: 1.5);

  TextStyle get _boldStyle => _bodyStyle.copyWith(fontWeight: FontWeight.w700);

  TextStyle get _linkStyle =>
      _bodyStyle.copyWith(color: VerbenaColors.teal, fontWeight: FontWeight.w600, decoration: TextDecoration.underline);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                children: [
                  VerbenaRoundIconButton(icon: const VerbenaBackChevronIcon(), onTap: () => context.safePop()),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Política de privacidad',
                      style: VerbenaText.display(size: 20),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Política de privacidad — VerbenAI', style: VerbenaText.display(size: 20)),
                    const SizedBox(height: 6),
                    Text(
                      'Última actualización: 17 de julio de 2026',
                      style: VerbenaText.body(size: 12.5, color: VerbenaColors.textMuted)
                          .copyWith(fontStyle: FontStyle.italic),
                    ),
                    const SizedBox(height: 20),

                    _SectionTitle('1. Responsable del tratamiento'),
                    _Paragraph(
                      'Gonzalo Velázquez Martínez, operando bajo el nombre comercial VerbenAI, con NIF '
                      '05955028Y, contacto a efectos de esta política: gvm.aplicaciones@gmail.com.',
                      style: _bodyStyle,
                    ),

                    _SectionTitle('2. Qué datos tratamos'),
                    _Bullet(spans: [
                      TextSpan(text: 'Foto que subes para generar imágenes', style: _boldStyle),
                      TextSpan(
                        text: ': incluye datos biométricos (tu cara), categoría especial de datos según el RGPD.',
                        style: _bodyStyle,
                      ),
                    ]),
                    _Bullet(spans: [
                      TextSpan(text: 'Datos de cuenta', style: _boldStyle),
                      TextSpan(
                        text: ': identificador anónimo de usuario, historial de generaciones, saldo de créditos.',
                        style: _bodyStyle,
                      ),
                    ]),
                    _Bullet(spans: [
                      TextSpan(text: 'Datos de suscripción', style: _boldStyle),
                      TextSpan(
                        text: ': gestionados por RevenueCat y la tienda de aplicaciones correspondiente '
                            '(Apple/Google) — nosotros no almacenamos datos de pago directamente.',
                        style: _bodyStyle,
                      ),
                    ]),

                    _SectionTitle('3. Para qué usamos tu foto'),
                    _Paragraph(
                      'Exclusivamente para generar las imágenes que solicitas dentro de la app. Antes de cualquier '
                      'generación, tu foto pasa por un proceso automático de verificación para impedir que se usen '
                      'imágenes de terceros o de figuras públicas sin su consentimiento.',
                      style: _bodyStyle,
                    ),

                    _SectionTitle('4. Cuánto tiempo se conserva tu foto'),
                    _Bullet(spans: [
                      TextSpan(text: 'Si tienes una suscripción activa', style: _boldStyle),
                      TextSpan(
                        text: ': tu foto se conserva cifrada mientras dure la suscripción, para que no tengas que '
                            'volver a subirla en cada generación.',
                        style: _bodyStyle,
                      ),
                    ]),
                    _Bullet(spans: [
                      TextSpan(text: 'Si no tienes suscripción activa (uso gratuito)', style: _boldStyle),
                      TextSpan(text: ': tu foto no se almacena; se procesa y se descarta.', style: _bodyStyle),
                    ]),
                    _Bullet(spans: [
                      TextSpan(
                        text: 'Al cancelar o expirar tu suscripción, tu foto se elimina automáticamente.',
                        style: _bodyStyle,
                      ),
                    ]),

                    _SectionTitle('5. Con quién compartimos tu foto'),
                    _Paragraph.rich([
                      TextSpan(text: 'Para generar las imágenes, tu foto se envía a ', style: _bodyStyle),
                      TextSpan(text: 'Replicate', style: _boldStyle),
                      TextSpan(
                        text: ' (proveedor de infraestructura de inteligencia artificial), que actúa como '
                            'encargado del tratamiento bajo nuestras instrucciones. No se comparte con nadie más, '
                            'y no se usa para entrenar modelos de terceros.',
                        style: _bodyStyle,
                      ),
                    ]),

                    _SectionTitle('6. Tus derechos'),
                    _Paragraph(
                      'Puedes ejercer en cualquier momento tus derechos de acceso, rectificación, supresión '
                      '("derecho al olvido"), oposición y portabilidad:',
                      style: _bodyStyle,
                    ),
                    _Bullet(spans: [
                      TextSpan(text: 'Desde la app', style: _boldStyle),
                      TextSpan(
                        text: ': perfil → "Borrar mis datos" (elimina tu cuenta, tu foto y tu historial de '
                            'generaciones de forma permanente e irreversible).',
                        style: _bodyStyle,
                      ),
                    ]),
                    _Bullet(spans: [
                      TextSpan(text: 'Por email', style: _boldStyle),
                      TextSpan(text: ': escribiendo a gvm.aplicaciones@gmail.com.', style: _bodyStyle),
                    ]),
                    const SizedBox(height: 8),
                    _Paragraph.rich([
                      TextSpan(text: 'Importante', style: _boldStyle),
                      TextSpan(
                        text: ': borrar tus datos desde la app no cancela automáticamente tu suscripción activa '
                            'en Apple/Google — para eso, cancela desde los ajustes de tu cuenta de ',
                        style: _bodyStyle,
                      ),
                      TextSpan(text: 'Apple', style: _linkStyle, recognizer: _appleRecognizer),
                      TextSpan(text: ' o ', style: _bodyStyle),
                      TextSpan(text: 'Google Play', style: _linkStyle, recognizer: _googleRecognizer),
                      TextSpan(text: '.', style: _bodyStyle),
                    ]),

                    _SectionTitle('7. Base legal del tratamiento'),
                    _Bullet(spans: [
                      TextSpan(
                        text: 'Ejecución del contrato/servicio que solicitas (generación de imágenes).',
                        style: _bodyStyle,
                      ),
                    ]),
                    _Bullet(spans: [
                      TextSpan(
                        text: 'Consentimiento explícito para el tratamiento del dato biométrico (foto), '
                            'solicitado de forma separada al aceptar estos términos, antes de cada subida de foto.',
                        style: _bodyStyle,
                      ),
                    ]),

                    _SectionTitle('8. Seguridad'),
                    _Paragraph(
                      'Tu foto se almacena cifrada en reposo, en un almacenamiento privado con acceso '
                      'restringido únicamente a tu propia cuenta.',
                      style: _bodyStyle,
                    ),

                    _SectionTitle('9. Contacto'),
                    _Paragraph(
                      'Para cualquier duda sobre esta política o el tratamiento de tus datos: '
                      'gvm.aplicaciones@gmail.com.',
                      style: _bodyStyle,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Text(text, style: VerbenaText.display(size: 15.5)),
    );
  }
}

class _Paragraph extends StatelessWidget {
  const _Paragraph(String text, {required TextStyle style})
      : _spans = const [],
        _text = text,
        _style = style;

  const _Paragraph.rich(List<InlineSpan> spans)
      : _spans = spans,
        _text = null,
        _style = null;

  final String? _text;
  final TextStyle? _style;
  final List<InlineSpan> _spans;

  @override
  Widget build(BuildContext context) {
    if (_text != null) return Text(_text, style: _style);
    return Text.rich(TextSpan(children: _spans));
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.spans});

  final List<InlineSpan> spans;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 10),
            child: Container(
              width: 5,
              height: 5,
              decoration: const BoxDecoration(color: VerbenaColors.textMuted, shape: BoxShape.circle),
            ),
          ),
          Expanded(child: Text.rich(TextSpan(children: spans))),
        ],
      ),
    );
  }
}
