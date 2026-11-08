/// Builders for the Bluetooth SIG FTMS FITNESS_MACHINE_CONTROL_POINT
/// (0x2AD9) write payloads, per Fitness Machine Service v1.0 §4.1.
///
/// Every message is: opcode (uint8) followed by little-endian parameters.
/// Control Point responses use opcode 0x80 on the Control Point itself.
library;

import 'dart:typed_data';

class FtmsOp {
  static const int requestControl = 0x00;
  static const int reset = 0x01;
  static const int setTargetInclination = 0x03;
  static const int setTargetResistanceLevel = 0x04;
  static const int setTargetPower = 0x05; // sint16 W, range from SUPPORTED_POWER_RANGE
  static const int setIndoorBikeSimulationParameters = 0x11;
  static const int start = 0x07;
  static const int stopOrPause = 0x08;
  static const int responseCode = 0x80;

  /// Result codes in a Control Point response (0x80, request opcode, result).
  static const int failureSuccess = 0x01;
  static const int failureOpcodeNotSupported = 0x02;
  static const int failureParameterOutOfRange = 0x03;
  static const int failureOperationFailed = 0x04;
  static const int failureControlNotPermitted = 0x05;
}

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

/// 0x03 — drive the trainer in ERG mode at [watts] (sint16, clamped ±2000 W).
Uint8List ftmsSetTargetPower(int watts) {
  final w = watts.clamp(-2000, 2000);
  final b = ByteData(3)..setUint8(0, FtmsOp.setTargetPower)..setInt16(1, w, Endian.little);
  return b.buffer.asUint8List();
}

/// 0x07 — fixed resistance level (uint16, unit-less; scale comes from the
/// trainer's SUPPORTED_RESISTANCE_LEVEL_RANGE characteristic).
Uint8List ftmsSetTargetResistanceLevel(int level) {
  final l = level.clamp(-0x8000, 0x7FFF);
  final b = ByteData(3)..setUint8(0, FtmsOp.setTargetResistanceLevel)..setInt16(1, l, Endian.little);
  return b.buffer.asUint8List();
}

/// 0x05 — SIM mode: the trainer computes load from wind + grade + Crr + mass.
///
/// Wire layout (all LE):
///   opcode u8 | windSpeed s16 (0.001 m/s) | grade s16 (0.01 %) |
///   crr u8 (0.005 N/kg) | totalMass u8 (kg, max 255)
Uint8List ftmsSetSimulationParameters({
  required double windSpeedMps,
  required double gradePercent,
  required double crrNPerKg,
  required int totalMassKg,
}) {
  final b = ByteData(8)
    ..setUint8(0, FtmsOp.setIndoorBikeSimulationParameters)
    ..setInt16(1, (windSpeedMps * 1000).round().clamp(-32768, 32767), Endian.little)
    ..setInt16(3, (gradePercent * 100).round().clamp(-32768, 32767), Endian.little)
    ..setUint8(5, (crrNPerKg / 0.005).round().clamp(0, 255))
    ..setUint8(6, totalMassKg.clamp(0, 255));
  return b.buffer.asUint8List();
}

/// A simple control opcode with no parameters.
Uint8List ftmsSimpleOp(int opcode) => _bytes([opcode]);

/// 0x08 — Stop or Pause: parameter 0 stops, 1 pauses.
Uint8List ftmsStopOrPause({required bool pause}) =>
    _bytes([FtmsOp.stopOrPause, pause ? 0x01 : 0x00]);

/// Parses a MACHINE_STATUS (0x2ADA) / TRAINING_STATUS indication into a
/// human-readable one-liner for diagnostics ('data' notifier).
String describeMachineStatus(Uint8List bytes) {
  if (bytes.isEmpty) return 'status: empty';
  final bd = ByteData.sublistView(bytes);
  final code = bd.getUint8(0);
  switch (code) {
    case 0x00:
      return 'status: Other';
    case 0x01:
      return 'status: Started';
    case 0x02:
      return 'status: Completed';
    case 0x03:
      return 'status: Stopped';
    case 0x04:
      return 'status: Paused';
    case 0xFF:
      if (bytes.length >= 3) {
        final req = bd.getUint8(1);
        final fail = bd.getUint8(2);
        final reqName = switch (req) {
          FtmsOp.setTargetPower => 'setTargetPower',
          FtmsOp.setTargetResistanceLevel => 'setResistance',
          FtmsOp.setIndoorBikeSimulationParameters => 'setSimulation',
          FtmsOp.start => 'start',
          FtmsOp.stopOrPause => 'stop/pause',
          _ => 'op0x${req.toRadixString(16)}',
        };
        final failName = switch (fail) {
          FtmsOp.failureSuccess => 'success',
          FtmsOp.failureOpcodeNotSupported => 'opcode not supported',
          FtmsOp.failureParameterOutOfRange => 'parameter out of range',
          FtmsOp.failureOperationFailed => 'operation failed',
          FtmsOp.failureControlNotPermitted => 'control not permitted',
          _ => 'code $fail',
        };
        return 'response: $reqName -> $failName';
      }
      return 'status: Response';
    default:
      return 'status: code $code';
  }
}
