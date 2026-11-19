import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';

/// Scans waiting to be sent, oldest first. Kept on the phone's storage,
/// so they survive the app being closed while the network is down.
///
/// Each mode has its own queue: [staffKey] for staff, [visitorKey] for each visitor, so a
/// visitor's queue never holds a real scan and the staff queue never holds a practice scan.
///
/// In a browser, two tabs of the same site share this storage. So every change re-reads the
/// stored queue and applies itself to that, instead of writing back this tab's copy: a scan
/// added in one tab is never wiped out by a write from another.
class Outbox {
  static const staffKey = 'countonce.outbox';
  static String visitorKey(String visitor) => 'countonce.outbox.$visitor';

  final SharedPreferences _prefs;
  final String key;
  List<Movement> _queue;
  Future<void> _last = Future.value();

  Outbox(this._prefs, [this.key = staffKey]) : _queue = _read(_prefs, key);

  static Future<Outbox> open([String key = staffKey]) async => Outbox(await SharedPreferences.getInstance(), key);

  static List<Movement> _read(SharedPreferences prefs, String key) => (prefs.getStringList(key) ?? const [])
      .map((s) => Movement.fromJson(jsonDecode(s) as Map<String, dynamic>))
      .toList();

  List<Movement> get pending => List.unmodifiable(_queue);
  bool get isEmpty => _queue.isEmpty;

  /// Reads the stored queue again, to see what another tab added or sent.
  Future<void> reload() => _serial(() async {
    await _prefs.reload();
    _queue = _read(_prefs, key);
  });

  Future<void> add(Movement m) => _change((q) {
    if (!q.any((x) => x.requestId == m.requestId)) q.add(m);
  });

  /// Called only after the API has answered for this movement.
  Future<void> remove(Movement m) => _change((q) => q.removeWhere((x) => x.requestId == m.requestId));

  /// Drops every waiting movement that matches [test].
  Future<void> removeWhere(bool Function(Movement m) test) => _change((q) => q.removeWhere(test));

  /// Forgets the whole queue, in storage too; used when a visitor leaves the demo.
  Future<void> clear() => _serial(() async {
    _queue = [];
    await _prefs.remove(key);
  });

  Future<void> _change(void Function(List<Movement> q) apply) => _serial(() async {
    await _prefs.reload();
    final q = _read(_prefs, key);
    apply(q);
    await _prefs.setStringList(key, q.map((m) => jsonEncode(m.toJson())).toList());
    _queue = q;
  });

  // One change at a time within this tab, so two changes never read the same stored queue.
  Future<void> _serial(Future<void> Function() step) {
    final next = _last.then((_) => step());
    _last = next.catchError((Object _) {});
    return next;
  }
}
