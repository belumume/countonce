import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/api.dart';
import 'data/migrate.dart';
import 'data/outbox.dart';
import 'ui/home_page.dart';
import 'ui/sign_in.dart';
import 'ui/theme.dart';
import 'logic.dart';

// The stock API. In a browser the app is served by the same site as the API, so it uses
// that site's address. On a phone it uses the live site, unless built with --dart-define=API=...
const _api = String.fromEnvironment('API', defaultValue: 'https://countonce.pages.dev');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // In a browser, build the accessibility tree from the start, so screen readers and keyboard users
  // do not first have to find Flutter's "Enable accessibility" button.
  if (kIsWeb) SemanticsBinding.instance.ensureSemantics();
  final base = kIsWeb && const String.fromEnvironment('API').isEmpty ? Uri.base : Uri.parse(_api);
  final prefs = await SharedPreferences.getInstance();
  await migrateLegacyKeys(prefs); // before the outbox and the logic read storage
  final logic = StaffLogic(StockApi(base), Outbox(prefs), prefs);
  // The playground page embeds /app/?visitor=ID&embed=1 beside a dashboard showing the same id.
  if (kIsWeb) unawaited(logic.openFrom(Uri.base));
  logic.start();
  runApp(
    MaterialApp(
      title: 'CountOnce',
      debugShowCheckedModeBanner: false,
      theme: Brand.theme(),
      localizationsDelegates: const [BrandLocalizations.delegate],
      // Name and staff key are asked once; after that the stock list opens straight away.
      home: ListenableBuilder(
        listenable: logic,
        builder: (context, _) => logic.signedIn ? HomePage(logic: logic) : SignInPage(logic: logic),
      ),
    ),
  );
}
