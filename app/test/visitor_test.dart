import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:countonce/data/api.dart';
import 'package:countonce/data/outbox.dart';
import 'package:countonce/logic.dart';
import 'package:countonce/ui/home_page.dart';
import 'package:countonce/ui/sign_in.dart';
import 'package:countonce/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A stand-in for the visitor part of the API. It records every request it receives, so a test
/// can check paths, headers and that nothing was sent, and it counts a request id once.
class FakeVisitorApi {
  final requests = <http.Request>[];
  final Map<String, int> stock = {};
  final seen = <String>{};
  bool down = false;

  List<Map<String, dynamic>> _items(String v) => [
    for (final e in stock.entries.where((e) => e.key.startsWith('DEMO-$v')))
      {
        'id': e.key,
        'name': e.key.endsWith('G') ? 'Work gloves, medium' : 'Practice item',
        'qty': e.value,
        'reorder_point': 6,
      },
  ];

  http.Response _state(String v) => http.Response(jsonEncode({'items': _items(v), 'movements': [], 'orders': []}), 200);

  http.Client get client => MockClient((req) async {
    requests.add(req);
    if (down) throw http.ClientException('network is down');
    switch (req.url.path) {
      case '/api/visitor':
        final v = (jsonDecode(req.body) as Map<String, dynamic>)['visitor'] as String;
        stock.putIfAbsent('DEMO-${v}G', () => 12);
        stock.putIfAbsent('DEMO-${v}P', () => 40);
        stock.putIfAbsent('DEMO-${v}T', () => 3);
        return _state(v);
      case '/api/state':
        return _state(req.url.queryParameters['visitor']!);
      case '/api/move':
        final b = jsonDecode(req.body) as Map<String, dynamic>;
        final id = b['request_id'] as String;
        final item = b['item_id'] as String;
        if (seen.add(id)) stock[item] = stock[item]! + (b['delta'] as int);
        return http.Response(jsonEncode({'outcome': 'applied', 'repeated': false, 'qty': stock[item]}), 200);
    }
    return http.Response('{}', 404);
  });
}

const visitorId = 'AB12CD34';

Future<StaffLogic> makeLogic(FakeVisitorApi api) async => StaffLogic(
  StockApi(Uri.parse('https://example.test'), api.client),
  await Outbox.open(),
  await SharedPreferences.getInstance(),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a new visitor id is 8 capital letters or digits', () {
    for (var i = 0; i < 50; i++) {
      expect(visitorIdPattern.hasMatch(StaffLogic.newVisitorId()), true);
    }
  });

  test('starting visitor mode asks POST /api/visitor, then reads /api/state?visitor=ID', () async {
    final api = FakeVisitorApi();
    final logic = await makeLogic(api);
    expect(logic.signedIn, false);

    await logic.startVisitor(visitorId);
    expect(logic.signedIn, true);
    expect(logic.staff, 'Visitor');
    expect(api.requests.single.method, 'POST');
    expect(api.requests.single.url.path, '/api/visitor');
    expect(jsonDecode(api.requests.single.body), {'visitor': visitorId});
    expect(logic.items.length, 3);

    await logic.refreshItems();
    expect(api.requests.last.method, 'GET');
    expect(api.requests.last.url.path, '/api/state');
    expect(api.requests.last.url.queryParameters, {'visitor': visitorId});

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('countonce.visitor'), visitorId, reason: 'kept for the next start');
  });

  test('a visitor id from the playground frame is not saved, so /app/ later starts as before', () async {
    final logic = await makeLogic(FakeVisitorApi());
    await logic.openFrom(Uri.parse('https://example.test/app/?visitor=$visitorId&embed=1'));
    expect(logic.embedded, true);
    expect(logic.visitor, visitorId);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('countonce.visitor'), isNull);
    final next = await makeLogic(FakeVisitorApi());
    expect(next.visitorMode, false);
  });

  test('a launch address without a valid visitor id stays in staff mode', () async {
    final logic = await makeLogic(FakeVisitorApi());
    await logic.openFrom(Uri.parse('https://example.test/app/?visitor=ab12&embed=1'));
    expect(logic.visitorMode, false);
    expect(logic.embedded, true);
  });

  test('a visitor whose items were cleared out gets them made again', () async {
    final api = FakeVisitorApi();
    final logic = await makeLogic(api);
    await logic.startVisitor(visitorId);
    api.stock.clear(); // the server removed them after a day
    await logic.refreshItems();
    expect(api.requests.map((r) => r.url.path).toList(), ['/api/visitor', '/api/state', '/api/visitor']);
    expect(logic.items.length, 3);
  });

  test('moves in visitor mode carry no staff key header, even with a key saved', () async {
    SharedPreferences.setMockInitialValues({'countonce.staff': 'Aisha', 'countonce.key': 'secret-key'});
    final api = FakeVisitorApi();
    final logic = await makeLogic(api);
    expect(logic.key, 'secret-key');
    await logic.startVisitor(visitorId);
    await logic.record(logic.itemFor('DEMO-${visitorId}G')!, -6);
    final move = api.requests.singleWhere((r) => r.url.path == '/api/move');
    expect(move.headers.containsKey('x-staff-key'), false);
    expect(api.stock['DEMO-${visitorId}G'], 6);
  });

  test('a real shelf label opens the visitor\'s practice copy of that item', () async {
    final api = FakeVisitorApi();
    final logic = await makeLogic(api);
    await logic.startVisitor(visitorId);
    expect(logic.itemFor('GLOVE-M')?.id, 'DEMO-${visitorId}G');
  });

  test('No signal on: scans stay in the outbox and nothing touches the network; off: sent once, same id', () async {
    final api = FakeVisitorApi();
    final logic = await makeLogic(api);
    await logic.startVisitor(visitorId);
    final gloves = logic.itemFor('GLOVE-M')!;

    await logic.setNoSignal(true);
    final before = api.requests.length;
    await logic.record(gloves, -2);
    await logic.record(gloves, -1);
    await logic.tick();
    expect(api.requests.length, before, reason: 'no request left the phone');
    expect(logic.waiting.length, 2);
    expect(logic.online, false);
    final ids = logic.waiting.map((m) => m.requestId).toList();

    await logic.setNoSignal(false);
    expect(logic.waiting, isEmpty);
    final moves = api.requests.where((r) => r.url.path == '/api/move').toList();
    expect(moves.map((r) => (jsonDecode(r.body) as Map)['request_id']).toList(), ids, reason: 'in order, same ids');
    expect(api.stock['DEMO-${visitorId}G'], 9, reason: '12 - 2 - 1, each counted once');
  });

  test('leaving visitor mode clears the visitor id and the visitor\'s waiting scans', () async {
    final api = FakeVisitorApi();
    final logic = await makeLogic(api);
    await logic.startVisitor(visitorId);
    await logic.setNoSignal(true);
    await logic.record(logic.itemFor('GLOVE-M')!, -1);
    expect(logic.waiting.length, 1);

    await logic.leaveVisitor();
    expect(logic.visitorMode, false);
    expect(logic.signedIn, false, reason: 'back to sign-in');
    expect(logic.noSignal, false);
    expect(logic.waiting, isEmpty);
    expect((await Outbox.open(Outbox.visitorKey(visitorId))).pending, isEmpty, reason: 'removed from storage too');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('countonce.visitor'), isNull);
  });

  group('screens at 360 x 740', () {
    Future<void> sized(WidgetTester tester, Widget home) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: Brand.theme(), home: home));
    }

    testWidgets('sign-in offers "Try it without a key", at least 44 px high', (tester) async {
      final logic = await makeLogic(FakeVisitorApi());
      await sized(tester, SignInPage(logic: logic));
      final button = find.text('Try it without a key');
      await tester.scrollUntilVisible(button, 200, scrollable: find.byType(Scrollable).first);
      expect(button, findsOneWidget);
      final box = find.ancestor(of: button, matching: find.byType(OutlinedButton));
      expect(tester.getSize(box).height, greaterThanOrEqualTo(44));
      expect(
        find.text('No staff key? Practise on three items of your own. The real stock is not affected.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the practice banner, the No signal switch and the guide fit with no overflow', (tester) async {
      final api = FakeVisitorApi();
      final logic = await makeLogic(api);
      await tester.runAsync(() => logic.startVisitor(visitorId));
      await sized(tester, HomePage(logic: logic));
      await tester.pump();

      expect(
        find.textContaining('Practice stock: your own copies of the three items. The real stock is not affected.'),
        findsOneWidget,
      );
      expect(find.text('No signal'), findsOneWidget);
      expect(find.text('Pretend the phone is offline'), findsOneWidget);
      expect(find.text('Leave practice'), findsOneWidget);
      expect(find.text('Try this'), findsOneWidget);
      expect(tester.getSize(find.byType(SwitchListTile)).height, greaterThanOrEqualTo(44));
      expect(
        tester.getSize(find.ancestor(of: find.text('Leave practice'), matching: find.byType(TextButton))).height,
        greaterThanOrEqualTo(44),
      );
      expect(tester.takeException(), isNull);

      final handle = tester.ensureSemantics();
      // The tile carries the label and the tap; the switch inside, merged into it, carries on or off.
      expect(
        tester.getSemantics(find.byType(SwitchListTile)),
        isSemantics(
          label: 'No signal\nPretend the phone is offline',
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
        ),
      );
      expect(tester.getSemantics(find.byType(Switch)), isSemantics(hasToggledState: true, isToggled: false));
      await tester.tap(find.text('No signal'));
      await tester.pump();
      expect(logic.noSignal, true);
      expect(tester.getSemantics(find.byType(Switch)), isSemantics(isToggled: true));
      handle.dispose();
    });

    testWidgets('No signal with one scan waiting: the screen says it once in each place, by you', (tester) async {
      final logic = await makeLogic(FakeVisitorApi());
      await tester.runAsync(() async {
        await logic.startVisitor(visitorId);
        await logic.dismissGuide();
        await logic.setNoSignal(true);
        await logic.record(logic.itemFor('GLOVE-M')!, -1);
      });
      await sized(tester, HomePage(logic: logic));
      await tester.pump();
      expect(find.text('1 scan saved on this phone'), findsOneWidget);
      expect(find.text('It will be sent when the signal returns.'), findsOneWidget);
      final tag = find.textContaining('includes 1 not sent yet');
      await tester.scrollUntilVisible(tag, 200, scrollable: find.byType(Scrollable).first);
      expect(tag, findsOneWidget);
      expect(find.text('11'), findsOneWidget, reason: 'the gloves row counts the waiting scan: 12 less 1');
      expect(find.text('No signal'), findsNWidgets(2), reason: 'the status pill and the switch');
      final line = find.text('Scanned by you, not sent yet');
      await tester.scrollUntilVisible(line, 200, scrollable: find.byType(Scrollable).first);
      expect(line, findsOneWidget);
      expect(find.textContaining('by itself'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('embedded in the playground, there is no Leave practice button and no second copy of the steps', (
      tester,
    ) async {
      final logic = await makeLogic(FakeVisitorApi())
        ..embedded = true;
      await tester.runAsync(() => logic.startVisitor(visitorId));
      await sized(tester, HomePage(logic: logic));
      expect(find.text('Leave practice'), findsNothing);
      expect(find.text('No signal'), findsOneWidget);
      expect(find.text('Try this'), findsNothing, reason: 'the Try it page prints the steps beside the phone');
      expect(find.textContaining('Practice stock'), findsOneWidget);
      expect(
        find.textContaining('The real stock is not affected'),
        findsNothing,
        reason: 'the dashboard beside the phone says it once',
      );
    });
  });

  test('the guide stays dismissed', () async {
    final logic = await makeLogic(FakeVisitorApi());
    await logic.startVisitor(visitorId);
    expect(logic.showGuide, true);
    await logic.dismissGuide();
    final again = await makeLogic(FakeVisitorApi());
    expect(again.visitorMode, true, reason: 'the saved visitor id brings visitor mode back');
    expect(again.showGuide, false);
  });
}
