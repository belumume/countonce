import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';

/// No answer from the API: the network is down, or the reply was lost.
/// The movement stays in the outbox and is sent again later, unchanged.
/// [server] is true when the API itself answered with an error (HTTP 500 or more), not the network.
class NoAnswer implements Exception {
  final String why;
  final bool server;
  NoAnswer(this.why, {this.server = false});
  @override
  String toString() => why;
}

/// The API wants the staff key (HTTP 401). Nothing was recorded: the movement stays in the
/// outbox and is sent again once the key is entered.
class NeedsKey implements Exception {}

/// A visitor id: exactly 8 capital letters or digits, made on the visitor's device.
final visitorIdPattern = RegExp(r'^[A-Z0-9]{8}$');

/// The only way the app talks to the stock API. The app never changes stock itself.
class StockApi {
  final Uri base;
  final http.Client _client;
  String key = ''; // the staff key, sent with every movement of a real item
  String? visitor; // set in visitor mode: the stock list is this visitor's practice items only
  bool noSignal = false; // visitor mode's "No signal" switch: every call fails without touching the network
  static const _timeout = Duration(seconds: 8);

  StockApi(this.base, [http.Client? client]) : _client = client ?? http.Client();

  void _checkSignal() {
    if (noSignal) throw NoAnswer('No signal (pretend)');
  }

  List<Item> _itemsFrom(http.Response r, String what) {
    if (r.statusCode != 200) throw NoAnswer('$what: HTTP ${r.statusCode}', server: r.statusCode >= 500);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return (body['items'] as List).map((j) => Item.fromJson(j as Map<String, dynamic>)).toList();
  }

  Future<List<Item>> items() async {
    _checkSignal();
    final v = visitor;
    final state = base.resolve('/api/state');
    final url = v == null ? state : state.replace(queryParameters: {'visitor': v});
    final http.Response r;
    try {
      r = await _client.get(url).timeout(_timeout);
    } catch (e) {
      throw NoAnswer('$e');
    }
    return _itemsFrom(r, 'stock list');
  }

  /// Makes the visitor's three practice items if they do not exist yet, and returns them.
  Future<List<Item>> startVisitor(String id) async {
    _checkSignal();
    final http.Response r;
    try {
      r = await _client
          .post(
            base.resolve('/api/visitor'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'visitor': id}),
          )
          .timeout(_timeout);
    } catch (e) {
      throw NoAnswer('$e');
    }
    return _itemsFrom(r, 'practice items');
  }

  /// Sends one movement. Throws [NoAnswer] when it is not known whether the API applied it,
  /// so the caller must keep it and send the same request again.
  /// Practice items (DEMO- ids) need no staff key, so none is sent with them.
  Future<Outcome> send(Movement m) async {
    _checkSignal();
    final http.Response r;
    try {
      r = await _client
          .post(
            base.resolve('/api/move'),
            headers: {'content-type': 'application/json', if (!m.itemId.startsWith('DEMO-')) 'x-staff-key': key},
            body: jsonEncode({'request_id': m.requestId, 'item_id': m.itemId, 'delta': m.delta, 'staff': m.staff}),
          )
          .timeout(_timeout);
    } catch (e) {
      throw NoAnswer('$e');
    }
    if (r.statusCode >= 500) throw NoAnswer('HTTP ${r.statusCode}', server: true);
    if (r.statusCode == 401) throw NeedsKey();
    Map<String, dynamic> body;
    try {
      body = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      throw NoAnswer('HTTP ${r.statusCode}, unreadable reply');
    }
    final outcome = body['outcome'] as String?;
    return Outcome(
      movement: m,
      // A 400 or 404 is an answer too: the request was wrong, so sending it again cannot help.
      result: outcome ?? 'rejected',
      repeated: body['repeated'] == true,
      qty: body['qty'] as int?,
      reason: (body['reason'] ?? body['error']) as String?,
      answeredAt: DateTime.now(),
    );
  }
}
