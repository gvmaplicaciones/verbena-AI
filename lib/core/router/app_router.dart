import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/home/presentation/home_screen.dart';
import '../../features/onboarding/presentation/onboarding_screen.dart';
import '../../features/paywall/presentation/paywall_screen.dart';
import '../../features/photo_select/presentation/photo_select_screen.dart';
import '../../features/processing/presentation/processing_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/result/presentation/result_screen.dart';
import 'app_routes.dart';

// TODO(fase C): añadir redirect basado en si ya se completó el onboarding
// (SharedPreferences/local flag) — auth ya no es la puerta de entrada porque
// arrancamos con Supabase Auth anónimo, no con login.
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: AppRoutes.onboarding,
    routes: [
      GoRoute(
        path: AppRoutes.onboarding,
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: AppRoutes.home,
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: AppRoutes.photoSelect,
        builder: (context, state) => const PhotoSelectScreen(),
      ),
      GoRoute(
        path: AppRoutes.processing,
        builder: (context, state) => const ProcessingScreen(),
      ),
      GoRoute(
        path: AppRoutes.result,
        builder: (context, state) => const ResultScreen(),
      ),
      GoRoute(
        path: AppRoutes.paywall,
        builder: (context, state) => const PaywallScreen(),
      ),
      GoRoute(
        path: AppRoutes.profile,
        builder: (context, state) => const ProfileScreen(),
      ),
    ],
  );
});
