/// Decoders for the Bluetooth SIG Fitness Machine Service (FTMS), Cycling
/// Power Service (CPS) and Heart Rate Measurement GATT payloads, written from
/// the public specifications (CSS v1.0 / CPS v1.3 / HRS v1.1).
///
/// All multi-byte fields are little-endian as mandated by ATT.
library;

import 'dart:typed_data';

/// A decoded FTMS INDOOR_BIKE_DATA (0x2AD2) notification.
class IndoorBikeData {
  final int? speed100xCmPerSec; // uint16, 0.01 m/s
  final double? speedKph;
  final int? cadenceRevPerMin; // sint16 (revolutions delta per minute)
  final int? powerWatts; // sint16
  final int? resistanceLevel; // uint16
  final int? incline100xCm; // sint16, 0.01 m elevation gain
  final double? gradePercent; // sint16, 0.01 %
  final int? energyKcalPerHour; // uint16
  final int? energyKcal; // uint16 total
  final int? rpmCadence; // uint8, revolutions per minute (extended field)
  final int? heartRateBpm; // uint8 (extended field)
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
class _IbdFlags {
  static const moreData = 0x0001;
  static const avgSpeed = 0x0002;
  static const instantaneousSpeed = 0x0004;
  static const avgCadence = 0x0008;
  static const instantaneousCadence = 0x0010;
  static const avgPower = 0x0020;
  static const instantaneousPower = 0x0040;
  static const resistanceLevel = 0x0080;
  static const powerOutputPercentage = 0x0100;
  static const heartRate = 0x0200;
  static const metabolicEquivalent = 0x0400;
  static const annotatedStatus = 0x0800;
  static const extendedAvgCadence = 0x1000;
  static const extendedInstantaneousCadence = 0x2000;
  static const elevationGain = 0x4000;
  static const inclination = 0x8000;
}

/// Decodes an INDOOR_BIKE_DATA characteristic value. Returns null on a
/// truncated/malformed payload instead of throwing, so a single corrupt
/// notification never kills the BLE callback chain.
IndoorBikeData? decodeIndoorBikeData(Uint8List bytes) {
  if (bytes.length < 6) return null;
  final bd = ByteData.sublistView(bytes);
  final flags = bd.getUint16(0, Endian.little);

  double? speedKph;
  int? instSpeed;
  int? cadence;
  int? extCadence;
  int? power;
  int? resistance;
  int? elevation;
  int? grade;
  int? kcalH;
  int? kcal;
  int? hr;

  var o = 4; // after flags + elapsed time uint16
  bool take(int len) => o + len <= bytes.length;

  if ((flags & _IbdFlags.moreData) != 0 && take(2)) {
    // FIT ID: sport type + time source — skip both.
    o += 2;
  }
  if ((flags & _IbdFlags.avgSpeed) != 0 && take(2)) o += 2; // average speed unused here
  if ((flags & _IbdFlags.instantaneousSpeed) != 0 && take(2)) {
    instSpeed = bd.getUint16(o, Endian.little);
    speedKph = instSpeed! * 0.036; // 0.01 m/s -> km/h
    o += 2;
  }
  if ((flags & _IbdFlags.avgCadence) != 0 && take(2)) o += 2;
  if ((flags & _IbdFlags.instantaneousCadence) != 0 && take(2)) {
    cadence = bd.getInt16(o, Endian.little);
    o += 2;
  }
  if ((flags & _IbdFlags.avgPower) != 0 && take(2)) o += 2;
  if ((flags & _IbdFlags.instantaneousPower) != 0 && take(2)) {
    power = bd.getInt16(o, Endian.little);
    o += 2;
  }
  if ((flags & _IbdFlags.resistanceLevel) != 0 && take(2)) {
    resistance = bd.getUint16(o, Endian.little);
    o += 2;
  }
  if ((flags & _IbdFlags.powerOutputPercentage) != 0 && take(1)) o += 1;
  if ((flags & _IbdFlags.heartRate) != 0 && take(1)) {
    hr = bd.getUint8(o);
    o += 1;
  }
  if ((flags & _IbdFlags.metabolicEquivalent) != 0 && take(1)) o += 1;
  if ((flags & _IbdFlags.annotatedStatus) != 0 && take(1)) o += 1;
  if ((flags & _IbdFlags.extendedAvgCadence) != 0 && take(2)) o += 2;
  if ((flags & _IbdFlags.extendedInstantaneousCadence) != 0 && take(2)) {
    extCadence = bd.getUint16(o, Endian.little);
    o += 2;
  }
  if ((flags & _IbdFlags.elevationGain) != 0 && take(2)) {
    elevation = bd.getUint16(o, Endian.little);
    o += 2;
  }
  if ((flags & _IbdFlags.inclination) != 0 && take(2)) {
    grade = bd.getInt16(o, Endian.little);
    o += 2;
  }
  // Remaining optional fields (energy counters) are position-dependent on the
  // flags above; read them only when enough bytes remain to be unambiguous.
  if (take(4)) {
    kcalH = bd.getUint16(o, Endian.little);
    kcal = bd.getUint16(o + 2, Endian.little);
    o += 4;
  }

  return IndoorBikeData(
    speed100xCmPerSec: instSpeed,
    speedKph: speedKph,
    cadenceRevPerMin: cadence,
    powerWatts: power,
    resistanceLevel: resistance,
    incline100xCm: elevation,
    gradePercent: grade == null ? null : grade / 100.0,
    energyKcalPerHour: kcalH,
    energyKcal: kcal,
    rpmCadence: extCadence ?? cadence,
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
  if (bytes.length < 2) return null;
  final bd = ByteData.sublistView(bytes);
  final flags = bd.getUint16(0, Endian.little);
  var o = 2;
  int? power;
  int? revs;
  int? evt;
  if ((flags & 0x0004) != 0 && o + 2 <= bytes.length) {
    // Pedal Power Balance present (uint8)
    o += 1;
  }
  if ((flags & 0x0008) != 0 && o + 4 <= bytes.length) {
    // Power Phase (2x uint8)
    o += 2;
  }
  if ((flags & 0x0010) != 0 && o + 2 <= bytes.length) {
    // Extended Angle Profile (2x uint8)
    o += 2;
  }
  if ((flags & 0x0020) != 0 && o + 2 <= bytes.length) {
    // Force Magnitude (2x sint16)
    o += 4;
  }
  if ((flags & 0x0040) != 0 && o + 2 <= bytes.length) {
    // Torque (sint16)
    o += 2;
  }
  if ((flags & 0x0001) != 0 && o + 4 <= bytes.length) {
    revs = bd.getUint16(o, Endian.little);
    evt = bd.getUint16(o + 2, Endian.little);
    o += 4;
  }
  if ((flags & 0x0002) != 0 && o + 2 <= bytes.length) {
    power = bd.getInt16(o, Endian.little);
    o += 2;
  }
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
