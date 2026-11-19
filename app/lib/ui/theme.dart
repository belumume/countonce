import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';

/// One set of colours and type for the staff app and the dashboard (public/index.html uses the
/// same values). The look comes from the shelf labels: black ink on paper, with safety amber for
/// the things a worker acts on. Colour is never the only signal: low stock also says "LOW", a
/// change also carries its sign, and a phone without signal also says "No signal".
abstract final class Brand {
  static const paper = Color(0xFFF5F3EE); // page background
  static const surface = Color(0xFFFFFFFF); // rows and sheets
  static const ink = Color(0xFF1A1D21); // text, app bar, selected controls
  static const ink2 = Color(0xFF2C3036); // offline banner, a step lighter than the app bar
  static const muted = Color(0xFF4F5660); // secondary text, 6.7:1 on paper (7.4:1 on white): AA, not AAA
  static const line = Color(0xFFDDD8CE); // dividers
  static const amber = Color(0xFFF2B21B); // the Scan button, the main button, LOW
  static const ok = Color(0xFF1B7A46); // stock went up, or a movement was recorded
  static const bad = Color(0xFFB3261E); // stock went down, or a movement was refused
  static const disabled = Color(0xFFEAE6DF);

  static const sans = 'IBMPlexSans';
  static const mono = 'IBMPlexMono';

  static ThemeData theme() {
    final scheme = ColorScheme.fromSeed(seedColor: amber).copyWith(
      primary: ink,
      onPrimary: paper,
      secondary: amber,
      onSecondary: ink,
      surface: surface,
      onSurface: ink,
      error: bad,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: sans,
      scaffoldBackgroundColor: paper,
      dividerColor: line,
      appBarTheme: const AppBarTheme(
        backgroundColor: ink,
        foregroundColor: paper,
        elevation: 0,
        titleTextStyle: TextStyle(fontFamily: sans, fontWeight: FontWeight.w700, fontSize: 20, color: paper),
      ),
      bottomSheetTheme: const BottomSheetThemeData(backgroundColor: surface, showDragHandle: true),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, backgroundColor: ink),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(borderSide: BorderSide(color: line)),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: line)),
        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: ink, width: 2)),
      ),
    );
  }
}

/// A coloured, signed quantity: "+5" in green, "−1" in red (a real minus sign).
String signed(int d) => d > 0 ? '+$d' : '−${-d}';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "just now", "4 min ago", "2 h ago", or the date ("3 Nov 2026") for anything older than a day.
String ago(DateTime t, DateTime now) {
  final s = now.difference(t).inSeconds;
  if (s < 60) return 'just now';
  if (s < 3600) return '${s ~/ 60} min ago';
  if (s < 86400) return '${s ~/ 3600} h ago';
  return '${t.day} ${_months[t.month - 1]} ${t.year}';
}

/// The toolkit's English words with one change: a bottom sheet's route gets no name of its own
/// (Android would read the generic "Dialog"), so each sheet names itself with SheetName.
class BrandLocalizations extends DefaultMaterialLocalizations {
  const BrandLocalizations();

  @override
  String get dialogLabel => '';

  static const LocalizationsDelegate<MaterialLocalizations> delegate = _BrandLocalizationsDelegate();
}

class _BrandLocalizationsDelegate extends LocalizationsDelegate<MaterialLocalizations> {
  const _BrandLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => locale.languageCode == 'en';

  @override
  Future<MaterialLocalizations> load(Locale locale) => SynchronousFuture(const BrandLocalizations());

  @override
  bool shouldReload(_BrandLocalizationsDelegate old) => false;
}
