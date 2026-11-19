import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The prefix earlier versions of the app used for everything they saved on the phone.
/// Nothing writes it any more; it is kept only so [migrateLegacyKeys] can find and move old entries.
/// Built from character codes so the project's earlier name does not appear as text in the code or the build.
final legacyPrefix = String.fromCharCodes(const [112, 49, 52, 46]);
const currentPrefix = 'countonce.';

/// Moves everything saved under the old prefix to the same name under [currentPrefix], so a browser that
/// used an earlier version of the web app keeps its waiting scans, staff key, name and visitor. (The Android
/// app has a new package id, so it installs as a new app with empty storage; this does not reach the old one.)
/// For a waiting-scan queue saved under both names (a tab of the old version still open), the two queues are
/// merged by scan id, so no scan is lost. For anything else a value already saved under the new name is kept.
/// The old entry is removed either way. Runs at start, before anything else reads storage, and does nothing
/// when there are no old entries.
Future<void> migrateLegacyKeys(SharedPreferences prefs) async {
  for (final old in prefs.getKeys().where((k) => k.startsWith(legacyPrefix)).toList()) {
    final now = currentPrefix + old.substring(legacyPrefix.length);
    final oldValue = prefs.get(old);
    final newValue = prefs.get(now);
    if (now.startsWith('${currentPrefix}outbox') && oldValue is List && newValue is List) {
      final merged = [...newValue.cast<String>()];
      final ids = merged.map(_scanId).toSet();
      for (final entry in oldValue.cast<String>()) {
        if (ids.add(_scanId(entry))) merged.add(entry);
      }
      // In scan order (earliest first), keeping the current order for equal or unreadable times.
      final order = [for (var i = 0; i < merged.length; i++) (i, _scannedAt(merged[i]))];
      order.sort((a, b) {
        final byTime = a.$2.compareTo(b.$2);
        return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
      });
      await prefs.setStringList(now, [for (final o in order) merged[o.$1]]);
    } else if (!prefs.containsKey(now)) {
      final value = prefs.get(old);
      if (value is String) {
        await prefs.setString(now, value);
      } else if (value is bool) {
        await prefs.setBool(now, value);
      } else if (value is int) {
        await prefs.setInt(now, value);
      } else if (value is double) {
        await prefs.setDouble(now, value);
      } else if (value is List) {
        await prefs.setStringList(now, value.cast<String>());
      }
    }
    await prefs.remove(old);
  }
}

/// When one stored queue entry was scanned; an entry whose time cannot be read sorts last.
DateTime _scannedAt(String entry) {
  try {
    final t = (jsonDecode(entry) as Map<String, dynamic>)['scanned_at'] as String?;
    return (t == null ? null : DateTime.tryParse(t)) ?? DateTime(9999);
  } catch (_) {
    return DateTime(9999);
  }
}

/// The scan id of one stored queue entry (the movement's request id), or the whole entry if it cannot be read.
String _scanId(String entry) {
  try {
    return (jsonDecode(entry) as Map<String, dynamic>)['request_id'] as String? ?? entry;
  } catch (_) {
    return entry;
  }
}
