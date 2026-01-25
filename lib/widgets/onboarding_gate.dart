import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../pages/onboarding_page.dart';
import '../providers/theme_provider.dart';

class OnboardingGate extends ConsumerStatefulWidget {
  final Widget child;

  const OnboardingGate({super.key, required this.child});

  @override
  ConsumerState<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends ConsumerState<OnboardingGate> {
  bool _hasCompletedOnboarding = false;

  @override
  void initState() {
    super.initState();
    final prefs = ref.read(sharedPreferencesProvider);
    _hasCompletedOnboarding = prefs.getBool('onboarding_completed') ?? false;
  }

  Future<void> _completeOnboarding() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setBool('onboarding_completed', true);
    setState(() => _hasCompletedOnboarding = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasCompletedOnboarding) {
      return OnboardingPage(onComplete: _completeOnboarding);
    }

    return widget.child;
  }
}
