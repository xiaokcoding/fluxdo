import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme_provider.dart';

class AppPreferences {
  final bool autoPanguSpacing;
  final bool anonymousShare;
  final bool longPressPreview;

  const AppPreferences({
    required this.autoPanguSpacing,
    required this.anonymousShare,
    required this.longPressPreview,
  });

  AppPreferences copyWith({
    bool? autoPanguSpacing,
    bool? anonymousShare,
    bool? longPressPreview,
  }) {
    return AppPreferences(
      autoPanguSpacing: autoPanguSpacing ?? this.autoPanguSpacing,
      anonymousShare: anonymousShare ?? this.anonymousShare,
      longPressPreview: longPressPreview ?? this.longPressPreview,
    );
  }
}

class PreferencesNotifier extends StateNotifier<AppPreferences> {
  static const String _autoPanguSpacingKey = 'pref_auto_pangu_spacing';
  static const String _anonymousShareKey = 'pref_anonymous_share';
  static const String _longPressPreviewKey = 'pref_long_press_preview';

  PreferencesNotifier(this._prefs)
      : super(
          AppPreferences(
            autoPanguSpacing: _prefs.getBool(_autoPanguSpacingKey) ?? false,
            anonymousShare: _prefs.getBool(_anonymousShareKey) ?? false,
            longPressPreview: _prefs.getBool(_longPressPreviewKey) ?? true,
          ),
        );

  final SharedPreferences _prefs;

  Future<void> setAutoPanguSpacing(bool enabled) async {
    state = state.copyWith(autoPanguSpacing: enabled);
    await _prefs.setBool(_autoPanguSpacingKey, enabled);
  }

  Future<void> setAnonymousShare(bool enabled) async {
    state = state.copyWith(anonymousShare: enabled);
    await _prefs.setBool(_anonymousShareKey, enabled);
  }

  Future<void> setLongPressPreview(bool enabled) async {
    state = state.copyWith(longPressPreview: enabled);
    await _prefs.setBool(_longPressPreviewKey, enabled);
  }
}

final preferencesProvider =
    StateNotifierProvider<PreferencesNotifier, AppPreferences>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return PreferencesNotifier(prefs);
});
