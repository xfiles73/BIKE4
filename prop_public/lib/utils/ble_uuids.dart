/// Canonical Bluetooth SIG UUIDs used by the trainer transport layer, in the
/// 16-bit short form ("1826") and full 128-bit form ("00001826-...").
///
/// universal_ble normalises characteristic/service UUIDs to lowercase full
/// form on most platforms, but some stacks (notably Windows) deliver short
/// forms or mixed case depending on where the value came from (advertisement
/// vs discovery vs callback). Everything that matches a UUID coming FROM the
/// platform should go through [normalizeUuid] first, and comparisons should
/// use these constants.
class TrainerUuids {
  // Services
  static const String ftmsService = '1826';
  static const String cyclingPowerService = '1818';
  static const String heartRateService = '180d';
  static const String deviceInformationService = '180a';
  static const String fecService = '6f4b120b-1579-43ac-9c23-eb85ff5e2755'; // FE-C over BLE (Tacx/Ampler)

  // FTMS characteristics
  static const String ftmsFeature = '2acc';
  static const String indoorBikeData = '2ad2';
  static const String supportedInclinationRange = '2ad5';
  static const String supportedResistanceLevelRange = '2ad6';
  static const String supportedPowerRange = '2ad8';
  static const String ftmsControlPoint = '2ad9';
  static const String ftmsStatus = '2ada';
  static const String trainingStatus = '2ad3';

  // Cycling Power
  static const String cyclingPowerMeasurement = '2a63';
  static const String cyclingPowerFeature = '2a64';

  // Heart rate
  static const String heartRateMeasurement = '2a37';

  /// Lowercases and expands a 16-bit short UUID ("1826") to the full
  /// Bluetooth base-UUID form ("00001826-0000-1000-8000-00805f9b34fb"),
  /// so two UUIDs that refer to the same entity always compare equal after
  /// normalisation regardless of which form the platform delivered.
  static String normalizeUuid(String uuid) {
    final u = uuid.toLowerCase();
    if (u.length == 4) return '0000$u-0000-1000-8000-00805f9b34fb';
    if (u.length == 8) return '$u-0000-1000-8000-00805f9b34fb';
    return u;
  }

  /// Extracts the 16-bit short form from any representation, or returns the
  /// input unchanged when it is not a short/base-form UUID (e.g. vendor
  /// 128-bit UUIDs).
  static String shortForm(String uuid) {
    final u = uuid.toLowerCase();
    final m = RegExp(r'^0000([0-9a-f]{4})-0000-1000-8000-00805f9b34fb$').firstMatch(u);
    if (m != null) return m.group(1)!;
    if (u.length == 4) return u;
    return u;
  }

  /// True when [uuid] refers to [short16Bit] (accepts short or full form).
  static bool matches(String uuid, String short16Bit) => shortForm(uuid) == short16Bit;
}
