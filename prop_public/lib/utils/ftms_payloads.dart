/// Decoders for the Bluetooth SIG Fitness Machine Service (FTMS), Cycling
/// Power Service (CPS) and Heart Rate Measurement GATT payloads, written from
/// the public specifications (CSS v1.0 / CPS v1.3 / HRS v1.1).
///
/// All multi-byte fields are little-endian as mandated by ATT.
library;

import 'dart:typed_data';

/// A decoded FTMS INDOOR_BIKE_DATA (0x2AD2) notification.
class IndoorBikeData {
  /// Raw Instantaneous Speed field: uint16 in 0.01 km/h.
  final int? speed100xCmPerSec;
  final double? speedKph;
  final int? cadenceRevPerMin; // whole revolutions per minute (field is 0.5 rpm)
  final int? powerWatts; // sint16
  final int? resistanceLevel; // sint16
  final int? incline100xCm; // not part of FTMS Indoor Bike Data (always null)
  final double? gradePercent; // not part of FTMS Indoor Bike Data (always null)
  final int? energyKcalPerHour; // uint16
  final int? energyKcal; // uint16 total
  final int? rpmCadence; // same as cadenceRevPerMin (kept for API compatibility)
  final int? heartRateBpm; // uint8
  final DateTime timestamp;

  const IndoorBikeData({
    this.speed100xCmPerSec,
    this.speedKph,
    this.cadenceRevPerMin,
    this.powerWatts,
    this.resistanceLevel,
    this.incline100xCm,
    this.gradePercent,
    this.energyKcalPerHour,
    this.energyKcal,
    this.rpmCadence,
    this.heartRateBpm,
    required this.timestamp,
  });

  @override
  String toString() =>
      'IndoorBikeData(speed=${speedKph?.toStringAsFixed(1)}kph, cad=$cadenceRevPerMin, '
      'rpm=$rpmCadence, pow=${powerWatts}W, grade=${gradePercent == null ? null : '${gradePercent! ~/ 100}%'}, '
      'hr=$heartRateBpm)';
}

/// Bit flags of the 16-bit data-field format in INDOOR_BIKE_DATA.
///
/// Fitness Machine Service 1.0, §4.9.1 (org.bluetooth.characteristic.
/// indoor_bike_data). Note that Instantaneous Speed has no flag of its own:
/// it is present whenever the `More Data` bit is *clear*.
class _IbdFlags {
  static const moreData = 0x0001;
  static const avgSpeed = 0x0002;
  static const instCadence = 0x0004;
  static const avgCadence = 0x0008;
  static const totalDistance = 0x0010;
  static const resistanceLevel = 0x0020;
  static const instPower = 0x0040;
  static const avgPower = 0x0080;
  static const expendedEnergy = 0x0100;
  static const heartRate = 0x0200;
  static const metabolicEquivalent = 0x0400;
  static const elapsedTime = 0x0800;
  static const remainingTime = 0x1000;
}

/// Decodes an INDOOR_BIKE_DATA characteristic value. Returns null on a
/// truncated payload instead of throwing, so a single corrupt notification
/// never kills the BLE callback chain.
///
/// Field order (only the fields whose flag is set are transmitted):
///   Instantaneous Speed (uint16, 0.01 km/h)  — present when !More Data
///   Average Speed        (uint16, 0.01 km/h)
///   Instantaneous Cadence(uint16, 0.5 rpm)
///   Average Cadence      (uint16, 0.5 rpm)
///   Total Distance       (uint24, m)
///   Resistance Level     (sint16)
///   Instantaneous Power  (sint16, W)
///   Average Power        (sint16, W)
///   Expended Energy      (uint16 total kcal, uint16 kcal/h, uint8 kcal/min)
///   Heart Rate           (uint8, bpm)
///   Metabolic Equivalent (uint8, 0.1 MET)
///   Elapsed Time         (uint16, s)
///   Remaining Time       (uint16, s)
IndoorBikeData? decodeIndoorBikeData(Uint8List bytes) {
  if (bytes.length < 2) return null;
  final bd = ByteData.sublistView(bytes);
  final flags = bd.getUint16(0, Endian.little);

  var o = 2;
  // Each helper returns null when the payload ends early and leaves the
  // offset untouched, so later fields simply come out null instead of being
  // read from a misaligned position.
  int? u8() {
    if (o + 1 > bytes.length) return null;
    final v = bd.getUint8(o);
    o += 1;
    return v;
  }

  int? u16() {
    if (o + 2 > bytes.length) return null;
    final v = bd.getUint16(o, Endian.little);
    o += 2;
    return v;
  }

  int? s16() {
    if (o + 2 > bytes.length) return null;
    final v = bd.getInt16(o, Endian.little);
    o += 2;
    return v;
  }

  int? u24() {
    if (o + 3 > bytes.length) return null;
    final v = bd.getUint8(o) | (bd.getUint8(o + 1) << 8) | (bd.getUint8(o + 2) << 16);
    o += 3;
    return v;
  }

  int? speedRaw;
  if ((flags & _IbdFlags.moreData) == 0) speedRaw = u16();
  if ((flags & _IbdFlags.avgSpeed) != 0) u16();
  final cadenceRaw = (flags & _IbdFlags.instCadence) != 0 ? u16() : null;
  if ((flags & _IbdFlags.avgCadence) != 0) u16();
  if ((flags & _IbdFlags.totalDistance) != 0) u24();
  final resistance = (flags & _IbdFlags.resistanceLevel) != 0 ? s16() : null;
  final power = (flags & _IbdFlags.instPower) != 0 ? s16() : null;
  if ((flags & _IbdFlags.avgPower) != 0) s16();
  int? kcal;
  int? kcalH;
  if ((flags & _IbdFlags.expendedEnergy) != 0) {
    kcal = u16();
    kcalH = u16();
    u8();
  }
  final hr = (flags & _IbdFlags.heartRate) != 0 ? u8() : null;
  if ((flags & _IbdFlags.metabolicEquivalent) != 0) u8();
  if ((flags & _IbdFlags.elapsedTime) != 0) u16();
  if ((flags & _IbdFlags.remainingTime) != 0) u16();

  // Instantaneous Speed: uint16, resolution 0.01 km/h.
  final speedKph = speedRaw == null ? null : speedRaw / 100.0;
  // Instantaneous Cadence: uint16, resolution 0.5 rpm.
  final cadence = cadenceRaw == null ? null : (cadenceRaw * 0.5).round();

  return IndoorBikeData(
    speed100xCmPerSec: speedRaw,
    speedKph: speedKph,
    cadenceRevPerMin: cadence,
    powerWatts: power,
    resistanceLevel: resistance,
    incline100xCm: null,
    gradePercent: null,
    energyKcalPerHour: kcalH,
    energyKcal: kcal,
    rpmCadence: cadence,
    heartRateBpm: hr,
    timestamp: DateTime.now(),
  );
}

/// The FTMS Fitness Machine Feature (0x2ACC) capability bitmap.
class FtmsFeature {
  final bool manualResistanceMode;
  final bool machineStandMode;
  final bool resistanceControlModeAvailable;
  final bool heartRateMeasurementSupported;
  final bool powerMeasurementSupported;
  final bool speedDistanceSupported;
  final bool simulatedModeSupported;
  final bool inclineControlModeSupported;
  final bool rampRateSettingSupported;
  final bool strideFrequencyAndEccentricityTrainingEffectSupported;
  final bool physicalActivityEnabledForIndoorBike;
  final bool virtualRealityActivityEnabledForIndoorBike;
  final int distanceResolutionMm; // uint24
  final int maxInclinePercent; // sint16, 0.01 %
  final int minInclinePercent; // sint16, 0.01 %
  final int ascentSpeedResolutionRopeMmPerS;
  final int descentSpeedResolutionRopeMmPerS;
  final int maxAscentSpeedRopeMmPerS;
  final int minAscentSpeedRopeMmPerS;
  final int maxDescentSpeedRopeMmPerS;
  final int minDescentSpeedRopeMmPerS;

  const FtmsFeature({
    required this.manualResistanceMode,
    required this.machineStandMode,
    required this.resistanceControlModeAvailable,
    required this.heartRateMeasurementSupported,
    required this.powerMeasurementSupported,
    required this.speedDistanceSupported,
    required this.simulatedModeSupported,
    required this.inclineControlModeSupported,
    required this.rampRateSettingSupported,
    required this.strideFrequencyAndEccentricityTrainingEffectSupported,
    required this.physicalActivityEnabledForIndoorBike,
    required this.virtualRealityActivityEnabledForIndoorBike,
    required this.distanceResolutionMm,
    required this.maxInclinePercent,
    required this.minInclinePercent,
    required this.ascentSpeedResolutionRopeMmPerS,
    required this.descentSpeedResolutionRopeMmPerS,
    required this.maxAscentSpeedRopeMmPerS,
    required this.minAscentSpeedRopeMmPerS,
    required this.maxDescentSpeedRopeMmPerS,
    required this.minDescentSpeedRopeMmPerS,
  });

  /// Human-readable capability line for diagnostics/support bundles.
  List<String> get flagNames => [
    if (manualResistanceMode) 'Manual Resistance Mode',
    if (machineStandMode) 'Machine Stand Mode',
    if (resistanceControlModeAvailable) 'Resistance Control Mode',
    if (heartRateMeasurementSupported) 'Heart Rate Measurement',
    if (powerMeasurementSupported) 'Power Measurement',
    if (speedDistanceSupported) 'Speed and Distance Measurement',
    if (simulatedModeSupported) 'Simulated Mode',
    if (inclineControlModeSupported) 'Inclination Control Mode',
    if (rampRateSettingSupported) 'Ramp Rate Setting',
    if (strideFrequencyAndEccentricityTrainingEffectSupported) 'Stride/Eccentricity TE',
    if (physicalActivityEnabledForIndoorBike) 'Physical Activity (IB)',
    if (virtualRealityActivityEnabledForIndoorBike) 'VR Activity (IB)',
  ];
}

FtmsFeature? decodeFtmsFeature(Uint8List bytes) {
  if (bytes.length < 8) return null;
  final bd = ByteData.sublistView(bytes);
  final f = bd.getUint32(0, Endian.little);
  final ibd = bd.getUint32(4, Endian.little);
  final hasIncline = (ibd & 0x40) != 0; // Inclination Support bit
  final ropeBlock = hasIncline && bytes.length >= 8 + 1 + 5 * 3;
  int u24(int off) => bd.getUint8(off) | (bd.getUint8(off + 1) << 8) | (bd.getUint8(off + 2) << 16);
  return FtmsFeature(
    manualResistanceMode: (f & 0x01) != 0,
    machineStandMode: (f & 0x02) != 0,
    resistanceControlModeAvailable: (f & 0x04) != 0,
    heartRateMeasurementSupported: (f & 0x08) != 0,
    powerMeasurementSupported: (f & 0x10) != 0,
    speedDistanceSupported: (f & 0x20) != 0,
    simulatedModeSupported: (f & 0x40) != 0,
    inclineControlModeSupported: (f & 0x80) != 0,
    rampRateSettingSupported: (f & 0x100) != 0,
    strideFrequencyAndEccentricityTrainingEffectSupported: (f & 0x200) != 0,
    physicalActivityEnabledForIndoorBike: (f & 0x400) != 0,
    virtualRealityActivityEnabledForIndoorBike: (f & 0x800) != 0,
    distanceResolutionMm: u24(8),
    maxInclinePercent: ropeBlock ? bd.getInt16(11, Endian.little) : 0,
    minInclinePercent: ropeBlock ? bd.getInt16(13, Endian.little) : 0,
    ascentSpeedResolutionRopeMmPerS: ropeBlock ? u24(15) : 0,
    descentSpeedResolutionRopeMmPerS: ropeBlock ? u24(18) : 0,
    maxAscentSpeedRopeMmPerS: ropeBlock ? u24(21) : 0,
    minAscentSpeedRopeMmPerS: ropeBlock ? u24(24) : 0,
    maxDescentSpeedRopeMmPerS: ropeBlock ? u24(27) : 0,
    minDescentSpeedRopeMmPerS: ropeBlock ? u24(30) : 0,
  );
}

/// An FTMS MACHINE_STATUS (0x2ADA) or TRAINING_STATUS (0x2AD3) indication.
class FtmsStatusReport {
  /// 0 = Other, 1 = Started, 2 = Completed, 3 = Stopped, 4 = Paused.
  final int opCode;
  final int? requestOpCode; // present on Response (0xFF) messages
  final int? failureCode;
  const FtmsStatusReport({required this.opCode, this.requestOpCode, this.failureCode});

  bool get isResponse => opCode == 0xFF;
  static const started = 1;
  static const completed = 2;
  static const stopped = 3;
  static const paused = 4;
}

FtmsStatusReport? decodeMachineStatus(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  final bd = ByteData.sublistView(bytes);
  final code = bd.getUint8(0);
  if (code == 0xFF && bytes.length >= 3) {
    return FtmsStatusReport(opCode: code, requestOpCode: bd.getUint8(1), failureCode: bd.getUint8(2));
  }
  return FtmsStatusReport(opCode: code);
}

/// A Cycling Power Measurement (0x2A63) notification (instantaneous fields only).
class CyclingPowerData {
  final int? powerWatts; // sint16
  final int? crankRevolutions; // uint16 cumulative
  final int? lastCrankEventTime1024ths; // uint16
  final double? cadenceRpm; // derived from crank deltas at decode-caller level
  const CyclingPowerData({this.powerWatts, this.crankRevolutions, this.lastCrankEventTime1024ths, this.cadenceRpm});
}

CyclingPowerData? decodeCyclingPowerMeasurement(Uint8List bytes) {
  // Flags (uint16) + Instantaneous Power (sint16) are mandatory.
  if (bytes.length < 4) return null;
  final bd = ByteData.sublistView(bytes);
  final flags = bd.getUint16(0, Endian.little);
  var o = 2;

  // Cycling Power Measurement §4.3: the optional fields follow in bit order
  // after the mandatory power value.
  final power = bd.getInt16(o, Endian.little);
  o += 2;

  if ((flags & 0x0001) != 0) o += 1; // Pedal Power Balance (uint8, 0.5 %)
  if ((flags & 0x0004) != 0) o += 2; // Accumulated Torque (uint16, 1/32 Nm)
  if ((flags & 0x0010) != 0) o += 6; // Wheel Revolution Data (uint32 + uint16)

  int? revs;
  int? evt;
  if ((flags & 0x0020) != 0 && o + 4 <= bytes.length) {
    revs = bd.getUint16(o, Endian.little);
    evt = bd.getUint16(o + 2, Endian.little);
    o += 4;
  }
  // Extreme force/torque/angle fields that may follow are not needed here.
  return CyclingPowerData(powerWatts: power, crankRevolutions: revs, lastCrankEventTime1024ths: evt);
}

/// A Heart Rate Measurement (0x2A37) notification.
int? decodeHeartRate(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  final flags = bytes[0];
  final is16Bit = (flags & 0x01) != 0;
  if (!is16Bit && bytes.length >= 2) return bytes[1];
  if (is16Bit && bytes.length >= 3) return bytes[1] | (bytes[2] << 8);
  return null;
}
