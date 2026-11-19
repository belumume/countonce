import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'data/api.dart';
import 'data/outbox.dart';
import 'models.dart';

/// The logic layer (chapter 4's layered architecture: UI layer, logic layer, data layer).
/// Data flows one way: the screens show its state and call its methods, it asks the data
/// layer (the API and the outbox), and the new state flows back to the screens.
class StaffLogic extends ChangeNotifier {
  final StockApi api;
  final Outbox staffOutbox; // the staff queue, countonce.outbox
  Outbox outbox; // the queue of the current mode: the staff queue, or the visitor's own
  final SharedPreferences prefs;
  static const _itemsKey = 'countonce.items';
  static const _oldVisitorItemsKey = 'countonce.visitor.items'; // where earlier versions kept the saved visitor's items
  static const _staffKey = 'countonce.staff';
  static const _keyKey = 'countonce.key';
  static const _visitorKey = 'countonce.visitor';
  static const _guideKey = 'countonce.visitor.guideSeen';
  static const visitorName = 'Visitor';

  // A visitor's own storage: its items, its No signal switch and (for a visitor from the address)
  // its guide. Nothing of one visitor is kept under a key another mode or visitor reads.
  static String _visitorItemsKey(String v) => 'countonce.items.$v';
  static String _noSignalKey(String v) => 'countonce.noSignal.$v';
  static String _visitorGuideKey(String v) => 'countonce.guideSeen.$v';

  List<Item> items = [];
  final List<Outcome> recent = [];
  bool? online; // null until the first answer or failure
  bool needsKey = false; // the API refused the staff key; scans wait until a new one is entered
  bool serverError = false; // the API answered with an error, so the network is fine but scans wait
  bool embedded = false; // the app is shown inside the playground page (embed=1)
  String staff;
  bool _draining = false;
  bool _remembered = false; // the current visitor is the one saved on this phone as countonce.visitor
  bool _guideSeenHere = false;
  Timer? _timer;

  StaffLogic(this.api, Outbox outbox, this.prefs)
    : staffOutbox = outbox,
      outbox = outbox,
      staff = prefs.getString(_staffKey) ?? '' {
    api.key = prefs.getString(_keyKey) ?? '';
    final v = prefs.getString(_visitorKey);
    if (v != null && visitorIdPattern.hasMatch(v)) {
      api.visitor = v;
      _remembered = true;
      staff = visitorName;
      this.outbox = Outbox(prefs, Outbox.visitorKey(v));
      api.noSignal = prefs.getBool(_noSignalKey(v)) ?? false;
    }
    items = _cachedItems();
  }

  /// A scan this mode may send: in visitor mode only the visitor's own practice items,
  /// in staff mode never a practice item.
  bool _mine(Movement m) {
    final v = api.visitor;
    return v == null ? !m.itemId.startsWith('DEMO-') : m.itemId.startsWith('DEMO-$v');
  }

  List<Movement> get waiting => outbox.pending.where(_mine).toList();

  /// Starts the work that runs by itself: every 5 seconds, send what is waiting and refresh the stock.
  void start() {
    tick();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => tick());
  }

  Future<void> tick() async {
    await drain();
    await refreshItems();
  }

  Future<void> setStaff(String name) async {
    final n = name.trim();
    await prefs.setString(_staffKey, n);
    // In visitor mode scans stay "Visitor"; the saved name is for when staff mode comes back.
    if (!visitorMode) staff = n;
    notifyListeners();
  }

  String get key => api.key;

  /// The staff name saved on this phone, whatever the mode.
  String get savedStaff => prefs.getString(_staffKey) ?? '';

  /// Signed in once both the name and the staff key are saved on the phone, or in visitor mode.
  bool get signedIn => visitorMode || (staff.isNotEmpty && api.key.isNotEmpty);

  Future<void> setKey(String key) async {
    api.key = key.trim();
    await prefs.setString(_keyKey, api.key);
    needsKey = false;
    notifyListeners();
    await drain();
  }

  // ---- Visitor mode: a public visitor practises on three items of their own. ----

  String? get visitor => api.visitor;
  bool get visitorMode => api.visitor != null;
  bool get noSignal => api.noSignal;

  /// The first-run guide, shown once ever on this device when visitor mode starts.
  bool get showGuide =>
      visitorMode &&
      !_guideSeenHere &&
      !(prefs.getBool(_guideKey) ?? false) &&
      !(prefs.getBool(_visitorGuideKey(api.visitor!)) ?? false);

  Future<void> dismissGuide() async {
    _guideSeenHere = true;
    // A visitor from the address (the playground's frame) keeps this to itself, so /app/ still shows the guide.
    await prefs.setBool(_remembered ? _guideKey : _visitorGuideKey(api.visitor!), true);
    notifyListeners();
  }

  /// A new visitor id: 8 capital letters or digits from a secure random source.
  static String newVisitorId([Random? random]) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final r = random ?? Random.secure();
    return List.generate(8, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// Reads the launch address. The playground page embeds /app/?visitor=ID&embed=1 beside a
  /// dashboard of the same id. A visitor id from the address is not saved as this browser's
  /// visitor, so /app/ opened later starts as before.
  Future<void> openFrom(Uri uri) async {
    final query = uri.queryParameters;
    embedded = query['embed'] == '1';
    final v = query['visitor'];
    if (v != null && visitorIdPattern.hasMatch(v)) await startVisitor(v, false);
  }

  /// Enters visitor mode with [id] (a new one if none is given) and asks the API to make the
  /// practice items. Without a network the mode still starts; the items are asked for again on
  /// the next refresh. With [remember] the id replaces the visitor saved on this phone, and that
  /// visitor's scans and items are forgotten. Without it (an id from the address) only the new
  /// visitor's own keys are written: the saved visitor, its waiting scans and its items stay as they are.
  Future<void> startVisitor([String? id, bool remember = true]) async {
    final v = id ?? newVisitorId();
    if (!visitorIdPattern.hasMatch(v)) throw ArgumentError.value(v, 'id', 'not 8 capital letters or digits');
    final old = api.visitor;
    final saved = prefs.getString(_visitorKey);
    // The mode switches before anything is awaited, so the first screen drawn is already the demo.
    api.visitor = v;
    _remembered = remember || saved == v;
    outbox = Outbox(prefs, Outbox.visitorKey(v));
    api.noSignal = prefs.getBool(_noSignalKey(v)) ?? false;
    staff = visitorName;
    needsKey = false;
    serverError = false;
    if (old != v) {
      items = _cachedItems();
      recent.clear();
      _guideSeenHere = false;
    }
    notifyListeners();
    if (remember) {
      if (saved != null && saved != v && visitorIdPattern.hasMatch(saved)) await _forgetVisitor(saved);
      await prefs.setString(_visitorKey, v);
    }
    try {
      final fresh = await api.startVisitor(v);
      if (api.visitor != v) return; // the visitor left or changed while the items were being made
      items = fresh;
      online = true;
      await _cacheItems();
    } on NoAnswer catch (e) {
      if (api.visitor != v) return;
      online = false;
      serverError = e.server;
    }
    notifyListeners();
  }

  /// Turns the pretend "No signal" on or off. Turning it off sends what waited at once.
  /// It is saved with the visitor, so a reload, or a second tab of the same visitor, keeps it.
  Future<void> setNoSignal(bool on) async {
    final v = api.visitor;
    if (v == null) return;
    api.noSignal = on;
    await prefs.setBool(_noSignalKey(v), on);
    notifyListeners();
    await tick();
  }

  /// Leaves visitor mode: forgets the visitor id and the visitor's waiting scans, and goes back
  /// to sign-in (or to the real stock, if a name and staff key were already saved).
  Future<void> leaveVisitor() async {
    final v = api.visitor;
    if (v == null) return;
    await _forgetVisitor(v);
    if (prefs.getString(_visitorKey) == v) {
      await prefs.remove(_visitorKey);
      await prefs.remove(_oldVisitorItemsKey);
    }
    api.visitor = null;
    api.noSignal = false;
    _remembered = false;
    outbox = staffOutbox;
    staff = prefs.getString(_staffKey) ?? '';
    recent.clear();
    online = null;
    serverError = false;
    needsKey = false;
    items = _cachedItems();
    notifyListeners();
  }

  /// Removes everything kept for visitor [v]: its waiting scans, its items and its No signal switch.
  Future<void> _forgetVisitor(String v) async {
    await Outbox(prefs, Outbox.visitorKey(v)).clear();
    await prefs.remove(_visitorItemsKey(v));
    await prefs.remove(_noSignalKey(v));
  }

  // The practice item ids are DEMO-<visitor id><letter>, one letter per real item, so a real
  // shelf label scanned in visitor mode opens the visitor's copy of that item.
  static const _practiceLetter = {'BOX-A4': 'P', 'GLOVE-M': 'G', 'TONER-K': 'T'};

  Item? itemFor(String code) {
    var c = code.trim().toUpperCase();
    final letter = _practiceLetter[c];
    if (visitorMode && letter != null) c = 'DEMO-${api.visitor}$letter';
    for (final i in items) {
      if (i.id == c) return i;
    }
    return null;
  }

  String get _itemsCacheKey {
    final v = api.visitor;
    return v == null ? _itemsKey : _visitorItemsKey(v);
  }

  List<Item> _cachedItems() {
    final cached = prefs.getString(_itemsCacheKey);
    if (cached == null) return [];
    return (jsonDecode(cached) as List).map((j) => Item.fromJson(j as Map<String, dynamic>)).toList();
  }

  Future<void> _cacheItems() => prefs.setString(_itemsCacheKey, jsonEncode(items.map((i) => i.toJson()).toList()));

  /// A scan: it goes into the outbox first, with its request id made now, then is sent.
  /// If the network is down it simply waits there.
  Future<void> record(Item item, int delta) async {
    await outbox.add(
      Movement(
        requestId: const Uuid().v4(),
        itemId: item.id,
        delta: delta,
        staff: staff.isEmpty ? 'Staff app' : staff,
        scannedAt: DateTime.now(),
      ),
    );
    notifyListeners();
    await drain();
    await refreshItems();
  }

  /// Sends waiting movements one at a time, oldest first, and stops at the first one with
  /// no answer, so they reach the API in the order they were scanned. Only this mode's own
  /// scans are sent (see [_mine]).
  Future<void> drain() async {
    if (_draining) return;
    _draining = true;
    try {
      final box = outbox;
      final v = api.visitor;
      // Another tab may have added or sent scans, or turned this visitor's No signal on or off.
      await box.reload();
      if (v != null && api.visitor == v) api.noSignal = prefs.getBool(_noSignalKey(v)) ?? false;
      while (identical(box, outbox) && api.visitor == v) {
        final next = waiting;
        if (next.isEmpty) break;
        final m = next.first;
        try {
          final o = await api.send(m);
          await box.remove(m);
          if (api.visitor != v) break; // the mode changed while it was sent; its recent list is gone
          recent.insert(0, o);
          if (recent.length > 20) recent.removeLast();
          online = true;
          serverError = false;
        } on NoAnswer catch (e) {
          if (api.visitor != v) break;
          online = false;
          serverError = e.server;
          break;
        } on NeedsKey {
          // Practice items need no key, so only a staff scan gets here; a visitor is never asked for a key.
          online = true;
          needsKey = v == null;
          break;
        }
        needsKey = false;
        notifyListeners();
      }
    } finally {
      _draining = false;
      notifyListeners();
    }
  }

  Future<void> refreshItems() async {
    final v = api.visitor;
    try {
      var fresh = await api.items();
      // A visitor's items are cleared out after a day; make them again.
      if (v != null && fresh.isEmpty) fresh = await api.startVisitor(v);
      if (api.visitor != v) return; // the visitor left or changed while the list was loading
      items = fresh;
      online = true;
      if (waiting.isEmpty) serverError = false; // with scans waiting, the next send decides
      await _cacheItems();
    } on NoAnswer catch (e) {
      if (api.visitor != v) return;
      online = false;
      if (e.server) serverError = true;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
