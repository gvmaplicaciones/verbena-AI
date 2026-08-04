import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/garment_select_args.dart';
import '../../data/models/generation_source.dart';
import '../../data/models/processing_args.dart';
import '../../data/models/result_args.dart';
import '../../features/admin/presentation/admin_categories_screen.dart';
import '../../features/admin/presentation/admin_login_screen.dart';
import '../../features/admin/presentation/admin_new_template_screen.dart';
import '../../features/admin/presentation/admin_templates_screen.dart';
import '../../features/auth/presentation/account_gate_screen.dart';
import '../../features/garment_select/presentation/garment_select_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/onboarding/presentation/onboarding_screen.dart';
import '../../features/paywall/presentation/paywall_screen.dart';
import '../../features/photo_select/presentation/photo_select_screen.dart';
import '../../features/processing/presentation/processing_screen.dart';
import '../../features/profile/presentation/favorites_screen.dart';
import '../../features/profile/presentation/my_creations_screen.dart';
import '../../features/profile/presentation/privacy_policy_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/profile/presentation/verified_photos_screen.dart';
import '../../features/profile/presentation/wardrobe_screen.dart';
import '../../features/result/presentation/result_screen.dart';
import 'app_routes.dart';

// Sobreescrito en main.dart con el valor real de onboardingCompletedPrefsKey
// leído de SharedPreferences antes de runApp -- por defecto arranca en
// onboarding si nadie lo overridea (tests, etc.).
final initialLocationProvider = Provider<String>((ref) => AppRoutes.onboarding);

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: ref.watch(initialLocationProvider),
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
        builder: (context, state) => PhotoSelectScreen(source: state.extra! as GenerationSource),
      ),
      GoRoute(
        path: AppRoutes.garmentSelect,
        builder: (context, state) =>
            GarmentSelectScreen(args: state.extra! as GarmentSelectArgs),
      ),
      GoRoute(
        path: AppRoutes.wardrobe,
        builder: (context, state) => const WardrobeScreen(),
      ),
      GoRoute(
        path: AppRoutes.verifiedPhotos,
        builder: (context, state) => const VerifiedPhotosScreen(),
      ),
      GoRoute(
        path: AppRoutes.myCreations,
        builder: (context, state) => const MyCreationsScreen(),
      ),
      GoRoute(
        path: AppRoutes.favorites,
        builder: (context, state) => const FavoritesScreen(),
      ),
      GoRoute(
        path: AppRoutes.processing,
        builder: (context, state) => ProcessingScreen(args: state.extra! as ProcessingArgs),
      ),
      GoRoute(
        path: AppRoutes.result,
        builder: (context, state) => ResultScreen(args: state.extra! as ResultArgs),
      ),
      GoRoute(
        path: AppRoutes.paywall,
        builder: (context, state) => PaywallScreen(source: state.extra! as String),
      ),
      GoRoute(
        path: AppRoutes.accountGate,
        builder: (context, state) => AccountGateScreen(initialSignInMode: state.extra == true),
      ),
      GoRoute(
        path: AppRoutes.profile,
        builder: (context, state) => const ProfileScreen(),
      ),
      GoRoute(
        path: AppRoutes.privacyPolicy,
        builder: (context, state) => const PrivacyPolicyScreen(),
      ),
      GoRoute(
        path: AppRoutes.adminLogin,
        builder: (context, state) => const AdminLoginScreen(),
      ),
      GoRoute(
        path: AppRoutes.adminTemplates,
        builder: (context, state) => const AdminTemplatesScreen(),
      ),
      GoRoute(
        path: AppRoutes.adminNewTemplate,
        builder: (context, state) => const AdminNewTemplateScreen(),
      ),
      GoRoute(
        path: AppRoutes.adminCategories,
        builder: (context, state) => const AdminCategoriesScreen(),
      ),
    ],
  );
});
