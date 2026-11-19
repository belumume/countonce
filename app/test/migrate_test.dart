import 'dart:convert';

import 'package:countonce/data/api.dart';
import 'package:countonce/data/migrate.dart';
import 'package:countonce/data/outbox.dart';
import 'package:countonce/logic.dart';
import 'package:countonce/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

String enc(String item) => jsonEncode(
  Movement(requestId: 'r-$item', itemId: item, delta: -1, staff: 'Aisha', scannedAt: DateTime(2026)).toJson(),
);

void main() {
  test('entries saved by an earlier version move to the new names, and the old ones are removed', () async {
    const v = 'AB12CD34';
    SharedPreferences.setMockInitialValues({
      '${legacyPrefix}staff': 'Aisha',
      '${legacyPrefix}key': 'secret-key',
      '${legacyPrefix}outbox': [enc('GLOVE-M'), enc('TONER-K')],
      '${legacyPrefix}noSignal.$v': true,
      '${legacyPrefix}guideSeen.$v': true,
      '${legacyPrefix}visitor.items': '[]',
      'unrelated': 'left alone',
    });
    final prefs = await SharedPreferences.getInstance();

    await migrateLegacyKeys(prefs);

    expect(prefs.getString('${currentPrefix}staff'), 'Aisha');
    expect(prefs.getString('${currentPrefix}key'), 'secret-key');
    expect(prefs.getStringList('${currentPrefix}outbox'), [enc('GLOVE-M'), enc('TONER-K')]);
    expect(prefs.getBool('${currentPrefix}noSignal.$v'), true);
    expect(prefs.getBool('${currentPrefix}guideSeen.$v'), true);
    expect(prefs.getString('${currentPrefix}visitor.items'), '[]');
    expect(prefs.getString('unrelated'), 'left alone');
    expect(prefs.getKeys().where((k) => k.startsWith(legacyPrefix)), isEmpty);

    // The app started on the migrated storage keeps the waiting scans and the staff key.
    final logic = StaffLogic(StockApi(Uri.parse('https://x.test')), Outbox(prefs), prefs);
    expect(logic.key, 'secret-key');
    expect(logic.staff, 'Aisha');
    expect(logic.waiting.map((m) => m.itemId), ['GLOVE-M', 'TONER-K']);
  });

  test('a value already saved under the new name is kept, and the old one is still removed', () async {
    SharedPreferences.setMockInitialValues({'${legacyPrefix}key': 'old-key', '${currentPrefix}key': 'new-key'});
    final prefs = await SharedPreferences.getInstance();

    await migrateLegacyKeys(prefs);

    expect(prefs.getString('${currentPrefix}key'), 'new-key');
    expect(prefs.containsKey('${legacyPrefix}key'), false);
  });

  test('the old prefix is the one earlier versions used, and the new one is what the app reads', () {
    expect(legacyPrefix, 'p' '14.');
    expect(Outbox.staffKey, '${currentPrefix}outbox');
  });

  test('running again on migrated storage changes nothing', () async {
    SharedPreferences.setMockInitialValues({'${currentPrefix}staff': 'Aisha'});
    final prefs = await SharedPreferences.getInstance();

    await migrateLegacyKeys(prefs);

    expect(prefs.getKeys(), {'${currentPrefix}staff'});
  });

  test('a queue saved under both names is merged by scan id, so no waiting scan is lost', () async {
    SharedPreferences.setMockInitialValues({
      '${legacyPrefix}outbox': [enc('GLOVE-M'), enc('TONER-K')],
      '${currentPrefix}outbox': [enc('BOX-A4'), enc('GLOVE-M')],
    });
    final prefs = await SharedPreferences.getInstance();

    await migrateLegacyKeys(prefs);

    expect(prefs.getStringList('${currentPrefix}outbox'), [enc('BOX-A4'), enc('GLOVE-M'), enc('TONER-K')]);
    expect(prefs.getKeys(), {'${currentPrefix}outbox'});
  });

  test('a merged queue is in scan order, whichever name each scan was saved under', () async {
    String at(String item, int minute) => jsonEncode(
      Movement(requestId: 'r-$item', itemId: item, delta: -1, staff: 'Aisha', scannedAt: DateTime(2026, 1, 1, 9, minute)).toJson(),
    );
    SharedPreferences.setMockInitialValues({
      '${legacyPrefix}outbox.AB12CD34': [at('GLOVE-M', 1), at('TONER-K', 3)],
      '${currentPrefix}outbox.AB12CD34': [at('BOX-A4', 2)],
    });
    final prefs = await SharedPreferences.getInstance();

    await migrateLegacyKeys(prefs);

    expect(prefs.getStringList('${currentPrefix}outbox.AB12CD34'), [at('GLOVE-M', 1), at('BOX-A4', 2), at('TONER-K', 3)]);
  });
}

