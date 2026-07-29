import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/router/app_routes.dart';
import '../../../core/theme/verbena_icons.dart';
import '../../../core/theme/verbena_theme.dart';
import '../../../core/widgets/confetti_background.dart';

class _Slide {
  const _Slide({
    required this.iconBg,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final Color iconBg;
  final Widget icon;
  final String title;
  final String subtitle;
}

final _slides = [
  _Slide(
    iconBg: VerbenaColors.teal,
    icon: const VerbenaCameraIcon(),
    title: 'Sube tu careto',
    subtitle:
        'Una foto de frente, buena luz y listo. Nada de estudios de fotografía.',
  ),
  _Slide(
    iconBg: VerbenaColors.terracotta,
    icon: const VerbenaFanIcon(),
    title: 'Elige la escena',
    subtitle:
        'Un cartel de feria, un torero, o lo que se te ocurra escribiendo. Tú mandas.',
  ),
  _Slide(
    iconBg: VerbenaColors.teal,
    icon: const VerbenaCheckmarkIcon(),
    title: 'Presume por WhatsApp',
    subtitle:
        'En un par de minutos tienes tu foto lista pa\'l grupo. Así, sin más.',
  ),
];

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _step = 0;

  Future<void> _finish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(onboardingCompletedPrefsKey, true);
    if (!mounted) return;
    context.go(AppRoutes.home);
  }

  Future<void> _next() async {
    if (_step == _slides.length - 1) {
      await _finish();
      return;
    }
    setState(() => _step++);
  }

  @override
  Widget build(BuildContext context) {
    final slide = _slides[_step];
    return Scaffold(
      backgroundColor: VerbenaColors.background,
      body: Stack(
        children: [
          const ConfettiBackground(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 12, 28, 32),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Opacity(
                        opacity: _step == _slides.length - 1 ? 0 : 1,
                        child: IgnorePointer(
                          ignoring: _step == _slides.length - 1,
                          child: TextButton(
                            onPressed: _finish,
                            child: Text(
                              'Saltar',
                              style: VerbenaText.body(
                                  size: 14, color: VerbenaColors.textMuted),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 96,
                            height: 96,
                            decoration: BoxDecoration(
                                color: slide.iconBg, shape: BoxShape.circle),
                            alignment: Alignment.center,
                            child: slide.icon,
                          ),
                          const SizedBox(height: 32),
                          Text(
                            slide.title,
                            textAlign: TextAlign.center,
                            style: VerbenaText.display(size: 30),
                          ),
                          const SizedBox(height: 12),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 280),
                            child: Text(
                              slide.subtitle,
                              textAlign: TextAlign.center,
                              style: VerbenaText.body(
                                      size: 16, color: VerbenaColors.textMuted)
                                  .copyWith(height: 1.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(_slides.length, (i) {
                      final active = i == _step;
                      return Padding(
                        padding: EdgeInsets.only(
                            right: i == _slides.length - 1 ? 0 : 8),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: active ? 22 : 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: active
                                ? VerbenaColors.teal
                                : VerbenaColors.textDark.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _next,
                      child: Text(_step == _slides.length - 1
                          ? 'Empezar'
                          : 'Siguiente'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
