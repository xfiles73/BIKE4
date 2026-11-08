//INFO: This is a stub - contact me if you need the full implementation.

import 'package:shared_preferences/shared_preferences.dart';

final propPrefs = PropPrefs();

class PropPrefs {
  late SharedPreferences _prefs;

  void initialize(SharedPreferences prefs) {
    _prefs = prefs;
  }

  // NOTE: `keyPrefix` is accepted for API compatibility with the app call
  // sites (zwift_unlock.dart / unlock.dart pass it as a named argument).
  // The stub ignores it and keeps the original storage keys.
  DateTime? getZwiftClickV2LastUnlock(String deviceId, {String? keyPrefix}) {
    final key = 'clickV2_$deviceId';
    final timestamp = _prefs.getInt('${key}_unlock_date');
    if (timestamp == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(timestamp);
  }

  void setZwiftClickV2LastUnlock(String deviceId, DateTime dateTime, {String? keyPrefix}) {
    final key = 'clickV2_$deviceId';
    _prefs.setInt("${key}_unlock_date", dateTime.millisecondsSinceEpoch);
  }

  bool notSureIfUnlocked(String deviceId, {String? keyPrefix}) {
    return _prefs.getBool('clickV2_${deviceId}_notSure') ?? false;
  }

  void setNotSureIfUnlocked(String deviceId, bool value, {String? keyPrefix}) {
    _prefs.setBool('clickV2_${deviceId}_notSure', value);
  }
}
