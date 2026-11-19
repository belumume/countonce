import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:countonce/data/api.dart';
import 'package:countonce/data/outbox.dart';
import 'package:countonce/logic.dart';
import 'package:countonce/models.dart';
import 'package:countonce/ui/home_page.dart';
import 'package:countonce/ui/sign_in.dart';
import 'package:countonce/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Visitor mode and staff mode share one browser's storage (the playground frame and /app/, or
/// two tabs). These tests put both in one store and check that neither touches the other.

/// A stand-in API for real and practice items. It records every request. [holdVisitor] keeps
/// POST /api/visitor waiting until completed; [failVisitor] makes it answer HTTP 500 instead.
class Fake {
  final requests = <http.Request>[];
  Completer<void>? holdVisitor;
  bool failVisitor = false;
  String? key; // when set, real movements need this staff key

  List<http.Request> get moves => requests.where((r) => r.url.path == '/api/move').toList();
  List<String> get movedIds => [for (final r in moves) (jsonDecode(r.body) as Map)['item_id'] as String];

  static http.Response _items(String id) => http.Response(
    jsonEncode({
      'items': [
        {'id': id, 'name': 'Work gloves', 'qty': 12, 'reorder_point': 6},
      ],
    }),
    200,
  );

  http.Client get client => MockClient((req) async {
    requests.add(req);
    switch (req.url.path) {
      case '/api/visitor':
        if (holdVisitor != null) await holdVisitor!.future;
        if (failVisitor) return http.Response('{"error":"server"}', 500);
        return _items('DEMO-${(jsonDecode(req.body) as Map)['visitor']}G');
      case '/api/state':
        final v = req.url.queryParameters['visitor'];
        return _items(v == null ? 'GLOVE-M' : 'DEMO-${v}G');
      case '/api/move':
        final item = (jsonDecode(req.body) as Map)['item_id'] as String;
        if (!item.startsWith('DEMO-') && key != null && req.headers['x-staff-key'] != key) {
          return http.Response('{"error":"staff key needed"}', 401);
        }
        return http.Response(jsonEncode({'outcome': 'applied', 'repeated': false, 'qty': 11}), 200);
    }
    return http.Response('{}', 404);
  });
}

const v = 'AB12CD34';
const saved = 'ZZZZ9999';
final frame = Uri.parse('https://x.test/app/?visitor=$v&embed=1');

Movement mv(String item, [String id = '']) =>
    Movement(requestId: 'r-$item$id', itemId: item, delta: -1, staff: 'Aisha', scannedAt: DateTime(2026));
String enc(Movement m) => jsonEncode(m.toJson());

Future<StaffLogic> make(Fake f) async => StaffLogic(
  StockApi(Uri.parse('https://x.test'), f.client),
  await Outbox.open(),
  await SharedPreferences.getInstance(),
);

Future<List<String>> stored(String key) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return [for (final s in prefs.getStringList(key) ?? const <String>[]) (jsonDecode(s) as Map)['item_id'] as String];
}

void main() {
  group('finding 3: each mode has its own queue and sends only its own scans', () {
    test('the frame never sends a real scan waiting in the staff queue, nor its key', () async {
      SharedPreferences.setMockInitialValues({
        'countonce.staff': 'Aisha',
        'countonce.key': 'secret-key',
        'countonce.outbox': [enc(mv('GLOVE-M'))],
      });
      final f = Fake();
      final logic = await make(f);
      await logic.openFrom(frame);
      await logic.setNoSignal(true);
      await logic.record(logic.items.single, -1);
      expect(await stored('countonce.outbox'), ['GLOVE-M'], reason: 'the visitor scan waits in its own queue');
      expect(await stored('countonce.outbox.$v'), ['DEMO-${v}G']);
      await logic.setNoSignal(false);
      await logic.tick();
      expect(f.movedIds, ['DEMO-${v}G'], reason: 'only the visitor\'s own scan left the browser');
      expect(f.moves.any((r) => r.headers.containsKey('x-staff-key')), false);
      expect(logic.waiting, isEmpty);
      expect(await stored('countonce.outbox'), ['GLOVE-M'], reason: 'the staff scan still waits for staff mode');
    });

    test('a refused staff key in storage neither blocks the visitor nor shows the key banner', () async {
      SharedPreferences.setMockInitialValues({
        'countonce.key': 'old-key',
        'countonce.outbox': [enc(mv('GLOVE-M'))],
      });
      final f = Fake()..key = 'new-key';
      final logic = await make(f);
      await logic.openFrom(frame);
      await logic.record(logic.items.single, -1);
      expect(logic.needsKey, false);
      expect(logic.waiting, isEmpty, reason: 'the visitor scan was sent, not stuck behind the real one');
    });

    test('a practice scan in a visitor queue is never sent in staff mode, and a real one never in visitor mode', () async {
      SharedPreferences.setMockInitialValues({
        'countonce.staff': 'Aisha',
        'countonce.key': 'k',
        'countonce.outbox': [enc(mv('DEMO-${v}G'))], // left by an earlier version that had one queue
        'countonce.outbox.$v': [enc(mv('TONER-K'))], // should never be there, but must not be sent if it is
      });
      final f = Fake();
      final logic = await make(f);
      await logic.tick();
      expect(f.moves, isEmpty, reason: 'staff mode skips DEMO- scans');
      expect(logic.waiting, isEmpty);
      await logic.openFrom(frame);
      await logic.tick();
      expect(f.moves, isEmpty, reason: 'visitor mode skips anything not DEMO-$v');
    });

    testWidgets('in visitor mode the "Staff key not accepted" banner never shows', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final logic = await make(Fake());
      await tester.runAsync(() => logic.startVisitor(v));
      logic.needsKey = true;
      await tester.pumpWidget(MaterialApp(theme: Brand.theme(), home: HomePage(logic: logic)));
      expect(find.text('Staff key not accepted'), findsNothing);
      expect(find.text('Enter key'), findsNothing);
    });

    testWidgets('the sign-in form never fills in or saves "Visitor" as the staff name', (tester) async {
      SharedPreferences.setMockInitialValues({'countonce.staff': 'Aisha', 'countonce.key': 'k'});
      final logic = await make(Fake());
      await tester.runAsync(() => logic.startVisitor(v));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SignInForm(logic: logic))));
      final name = tester.widget<TextField>(find.byType(TextField).first);
      expect(name.controller!.text, 'Aisha');
      await tester.tap(find.text('Start'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('countonce.staff'), isNot('Visitor'));
      expect(logic.staff, 'Visitor', reason: 'the visitor\'s scans still say Visitor');
    });
  });

  group('finding 4: two tabs of one site', () {
    test('a scan added in one tab is not wiped out by a write from the other', () async {
      SharedPreferences.setMockInitialValues({});
      final tabA = await Outbox.open();
      final tabB = await Outbox.open();
      await tabA.add(mv('GLOVE-M'));
      await tabB.add(mv('TONER-K'));
      expect(await stored('countonce.outbox'), ['GLOVE-M', 'TONER-K']);
      await tabB.remove(tabB.pending.first);
      await tabA.add(mv('BOX-A4'));
      expect(await stored('countonce.outbox'), ['TONER-K', 'BOX-A4'], reason: 'a scan sent by tab B is not brought back');
    });

    test('No signal in one tab holds that tab\'s scans: the other tab of the same visitor sends nothing', () async {
      SharedPreferences.setMockInitialValues({});
      final f = Fake();
      final tabA = await make(f);
      await tabA.openFrom(frame);
      final tabB = await make(f);
      await tabB.openFrom(frame);
      await tabA.setNoSignal(true);
      await tabA.record(tabA.items.single, -1);
      await tabA.record(tabA.items.single, -1);
      await tabB.tick();
      expect(f.moves, isEmpty);
      expect(await stored('countonce.outbox.$v'), hasLength(2));
      await tabA.setNoSignal(false);
      expect(f.moves, hasLength(2));
      expect(await stored('countonce.outbox.$v'), isEmpty);
    });
  });

  group('finding 5: leaving the demo while it is still starting', () {
    test('the practice items do not become the real stock or its saved copy', () async {
      SharedPreferences.setMockInitialValues({'countonce.staff': 'Aisha', 'countonce.key': 'k'});
      final f = Fake()..holdVisitor = Completer();
      final logic = await make(f);
      final starting = logic.startVisitor(v);
      await Future<void>.delayed(Duration.zero);
      await logic.leaveVisitor();
      f.holdVisitor!.complete();
      await starting;
      expect(logic.visitorMode, false);
      expect(logic.items.where((i) => i.id.startsWith('DEMO-')), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('countonce.items') ?? '', isNot(contains('DEMO-')));
    });

    test('a late server error does not mark the staff screen as having a server problem', () async {
      SharedPreferences.setMockInitialValues({'countonce.staff': 'Aisha', 'countonce.key': 'k'});
      final f = Fake()
        ..holdVisitor = Completer()
        ..failVisitor = true;
      final logic = await make(f);
      final starting = logic.startVisitor(v);
      await Future<void>.delayed(Duration.zero);
      await logic.leaveVisitor();
      f.holdVisitor!.complete();
      await starting;
      expect(logic.serverError, false);
      expect(logic.online, isNull);
    });
  });

  group('finding 6: the frame leaves the saved visitor alone', () {
    test('its waiting scans, its items and the saved id are untouched', () async {
      final savedItems = jsonEncode([
        {'id': 'DEMO-${saved}G', 'name': 'Work gloves', 'qty': 7, 'reorder_point': 6},
      ]);
      SharedPreferences.setMockInitialValues({
        'countonce.visitor': saved,
        'countonce.outbox.$saved': [enc(mv('DEMO-${saved}G'))],
        'countonce.items.$saved': savedItems,
        'countonce.visitor.items': savedItems,
      });
      final f = Fake();
      final logic = await make(f);
      await logic.openFrom(frame);
      await logic.tick();
      expect(logic.visitor, v);
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getString('countonce.visitor'), saved);
      expect(await stored('countonce.outbox.$saved'), ['DEMO-${saved}G']);
      expect(prefs.getString('countonce.items.$saved'), savedItems);
      expect(prefs.getString('countonce.visitor.items'), savedItems);
      expect(f.movedIds, isNot(contains('DEMO-${saved}G')));
    });
  });

  group('finding 15: No signal survives a reload', () {
    test('a reload with No signal on keeps holding the scans and shows the last stock', () async {
      SharedPreferences.setMockInitialValues({});
      final f = Fake();
      final first = await make(f);
      await first.openFrom(frame);
      await first.setNoSignal(true);
      await first.record(first.items.single, -1);

      final f2 = Fake();
      final reloaded = await make(f2);
      await reloaded.openFrom(frame);
      await reloaded.tick();
      expect(reloaded.noSignal, true);
      expect(f2.requests, isEmpty, reason: 'nothing left the phone, as with no network');
      expect(reloaded.waiting, hasLength(1));
      expect(reloaded.items.single.id, 'DEMO-${v}G', reason: 'the stock from the last time it was online');
    });

    test('the saved visitor in /app/ keeps No signal too', () async {
      SharedPreferences.setMockInitialValues({});
      final first = await make(Fake());
      await first.startVisitor(v);
      await first.setNoSignal(true);
      final f2 = Fake();
      final reloaded = await make(f2);
      expect(reloaded.noSignal, true);
      await reloaded.tick();
      expect(f2.requests, isEmpty);
    });
  });
}
