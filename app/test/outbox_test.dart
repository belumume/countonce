import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:countonce/data/api.dart';
import 'package:countonce/data/outbox.dart';
import 'package:countonce/models.dart';
import 'package:countonce/logic.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A stand-in for the stock API that keeps rule 2 the same way: a request id it has seen
/// gets the first answer back. `down` makes every request fail; `loseNextReply` applies the
/// next movement and then fails before the reply arrives, like a dropped connection.
class FakeApi {
  int qty;
  final seen = <String, int>{};
  final arrivals = <String>[];
  bool down = false;
  bool loseNextReply = false;
  bool serverFails = false; // movements get HTTP 500, as from a bug on the server
  bool listFails = false; // the stock list gets HTTP 500
  String? key; // when set, movements need this staff key
  FakeApi(this.qty);

  http.Client get client => MockClient((req) async {
        if (down) throw http.ClientException('network is down');
        if (req.url.path == '/api/state') {
          if (listFails) return http.Response(jsonEncode({'error': 'server error'}), 500);
          return http.Response(
              jsonEncode({
                'items': [
                  {'id': 'TONER-K', 'name': 'Black toner cartridge', 'qty': qty, 'reorder_point': 2}
                ]
              }),
              200);
        }
        if (key != null && req.headers['x-staff-key'] != key) {
          return http.Response(jsonEncode({'error': 'staff key needed'}), 401);
        }
        if (serverFails) return http.Response(jsonEncode({'error': 'server error'}), 500);
        final b = jsonDecode(req.body) as Map<String, dynamic>;
        final id = b['request_id'] as String;
        arrivals.add(id);
        if (seen.containsKey(id)) {
          return http.Response(jsonEncode({'outcome': 'applied', 'repeated': true, 'qty': qty}), 200);
        }
        final delta = b['delta'] as int;
        if (qty + delta < 0) {
          seen[id] = 0;
          return http.Response(jsonEncode({'outcome': 'refused', 'repeated': false, 'reason': 'not enough stock'}), 409);
        }
        qty += delta;
        seen[id] = delta;
        if (loseNextReply) {
          loseNextReply = false;
          throw http.ClientException('connection dropped before the reply');
        }
        return http.Response(jsonEncode({'outcome': 'applied', 'repeated': false, 'qty': qty}), 200);
      });
}

const toner = Item(id: 'TONER-K', name: 'Black toner cartridge', qty: 5, reorderPoint: 2);

Future<StaffLogic> makeLogic(FakeApi api) async {
  final prefs = await SharedPreferences.getInstance();
  return StaffLogic(StockApi(Uri.parse('https://example.test'), api.client), await Outbox.open(), prefs);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('offline: scans wait on the phone, then go in the order they were made', () async {
    final api = FakeApi(5)..down = true;
    final logic = await makeLogic(api);
    await logic.record(toner, -1);
    await logic.record(toner, -2);
    expect(logic.waiting.length, 2);
    expect(logic.online, false);
    expect(api.qty, 5);

    final firstId = logic.waiting.first.requestId;
    api.down = false;
    await logic.drain();
    expect(logic.waiting, isEmpty);
    expect(api.qty, 2);
    expect(api.arrivals.first, firstId);
  });

  test('a lost reply: the same request is sent again and counted once', () async {
    final api = FakeApi(5)..loseNextReply = true;
    final logic = await makeLogic(api);
    await logic.record(toner, -1);
    expect(logic.waiting.length, 1, reason: 'no reply, so it is kept');
    expect(api.qty, 4, reason: 'but the API did apply it');

    await logic.drain();
    expect(logic.waiting, isEmpty);
    expect(api.qty, 4, reason: 'the repeat was not counted again');
    expect(api.arrivals.toSet().length, 1, reason: 'both attempts carried the same request id');
    expect(logic.recent.first.repeated, true);
  });

  test('a refused movement is answered, so it leaves the outbox and is not retried', () async {
    final api = FakeApi(0);
    final logic = await makeLogic(api);
    await logic.record(toner, -1);
    expect(logic.waiting, isEmpty);
    expect(logic.recent.first.result, 'refused');
    expect(api.arrivals.length, 1);
  });

  test('the outbox survives the app being closed', () async {
    final api = FakeApi(5)..down = true;
    final logic = await makeLogic(api);
    await logic.record(toner, -1);
    final reopened = await Outbox.open();
    expect(reopened.pending.single.requestId, logic.waiting.single.requestId);
  });

  test('a wrong staff key: the scan is kept, then sent once the right key is entered', () async {
    final api = FakeApi(5)..key = 'right-key';
    final logic = await makeLogic(api);
    await logic.record(toner, -1);
    expect(logic.needsKey, true);
    expect(logic.waiting.length, 1, reason: 'a refused key is not an answer about the stock');
    expect(api.qty, 5);

    await logic.setKey('right-key');
    expect(logic.needsKey, false);
    expect(logic.waiting, isEmpty);
    expect(api.qty, 4);
  });

  test('a server error: the scan is kept and the app says so, then it is sent once the server works', () async {
    final api = FakeApi(5)..serverFails = true;
    final logic = await makeLogic(api);
    await logic.record(toner, -1);
    expect(logic.waiting.length, 1);
    expect(logic.serverError, true);
    expect(api.qty, 5);

    api.serverFails = false;
    await logic.drain();
    expect(logic.waiting, isEmpty);
    expect(logic.serverError, false);
    expect(api.qty, 4);
  });

  test('a server error on the stock list clears once the list loads again', () async {
    final api = FakeApi(5)..listFails = true;
    final logic = await makeLogic(api);
    await logic.refreshItems();
    expect(logic.serverError, true);
    api.listFails = false;
    await logic.refreshItems();
    expect(logic.serverError, false);
    expect(logic.items.length, 1);
  });
}
