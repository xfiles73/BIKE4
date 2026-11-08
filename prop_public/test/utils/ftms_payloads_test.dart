import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prop/utils/ftms_payloads.dart';

void main() {
  group('decodeIndoorBikeData (FTMS 0x2AD2)', () {
    test('decodes the standard speed/cadence/resistance/power/heart-rate frame', () {
      final flags = 0x0264; // cadence | resistance level | power | heart rate
      final b = ByteData(11)
        ..setUint16(0, flags, Endian.little)
        ..setUint16(2, 3000, Endian.little) // 30.00 km/h
        ..setUint16(4, 180, Endian.little) // 90.0 rpm
        ..setInt16(6, 15, Endian.little) // resistance level
        ..setInt16(8, 250, Endian.little) // watts
        ..setUint8(10, 140); // bpm

      final ibd = decodeIndoorBikeData(b.buffer.asUint8List())!;

      expect(ibd.speedKph, closeTo(30.0, 0.001));
      expect(ibd.cadenceRevPerMin, 90);
      expect(ibd.rpmCadence, 90);
      expect(ibd.resistanceLevel, 15);
      expect(ibd.powerWatts, 250);
      expect(ibd.heartRateBpm, 140);
    });

    test('skips optional fields in the order defined by the flags', () {
      // More Data (no instantaneous speed) + average speed + total distance +
      // expended energy + elapsed time.
      final flags = 0x0001 | 0x0002 | 0x0010 | 0x0100 | 0x0800;
      final b = ByteData(14)
        ..setUint16(0, flags, Endian.little)
        ..setUint16(2, 2500, Endian.little) // average speed 25.00 km/h
        ..setUint8(4, 0xD2) // total distance = 1234 m (uint24)
        ..setUint8(5, 0x04)
        ..setUint8(6, 0x00)
        ..setUint16(7, 100, Endian.little) // total energy kcal
        ..setUint16(9, 500, Endian.little) // energy per hour
        ..setUint8(11, 8) // energy per minute
        ..setUint16(12, 60, Endian.little); // elapsed seconds

      final ibd = decodeIndoorBikeData(b.buffer.asUint8List())!;

      expect(ibd.speedKph, isNull);
      expect(ibd.cadenceRevPerMin, isNull);
      expect(ibd.powerWatts, isNull);
      expect(ibd.energyKcal, 100);
      expect(ibd.energyKcalPerHour, 500);
    });

    test('returns null values instead of throwing on a truncated payload', () {
      final b = ByteData(6)
        ..setUint16(0, 0x0044, Endian.little) // cadence + power announced
        ..setUint16(2, 3000, Endian.little)
        ..setUint16(4, 180, Endian.little);

      final ibd = decodeIndoorBikeData(b.buffer.asUint8List())!;

      expect(ibd.cadenceRevPerMin, 90);
      expect(ibd.powerWatts, isNull);
    });
  });

  group('decodeCyclingPowerMeasurement (CPS 0x2A63)', () {
    test('reads mandatory power plus wheel and crank revolution data', () {
      const flags = 0x0030; // wheel revolution data | crank revolution data
      final b = ByteData(16)
        ..setUint16(0, flags, Endian.little)
        ..setInt16(2, 250, Endian.little) // watts
        ..setUint32(4, 1000, Endian.little) // cumulative wheel revs
        ..setUint16(8, 2048, Endian.little) // last wheel event time (1/2048 s)
        ..setUint16(10, 42, Endian.little) // cumulative crank revs
        ..setUint16(12, 4096, Endian.little); // last crank event time (1/1024 s)
      // Trailing byte: an optional field we do not need.

      final cp = decodeCyclingPowerMeasurement(b.buffer.asUint8List(0, 14))!;

      expect(cp.powerWatts, 250);
      expect(cp.crankRevolutions, 42);
      expect(cp.lastCrankEventTime1024ths, 4096);
    });

    test('skips pedal power balance and accumulated torque before crank data', () {
      const flags = 0x0001 | 0x0004 | 0x0020;
      final b = ByteData(11)
        ..setUint16(0, flags, Endian.little)
        ..setInt16(2, 200, Endian.little) // watts
        ..setUint8(4, 50) // pedal power balance
        ..setUint16(5, 320, Endian.little) // accumulated torque
        ..setUint16(7, 7, Endian.little) // cumulative crank revs
        ..setUint16(9, 512, Endian.little); // last crank event time

      final cp = decodeCyclingPowerMeasurement(b.buffer.asUint8List())!;

      expect(cp.powerWatts, 200);
      expect(cp.crankRevolutions, 7);
      expect(cp.lastCrankEventTime1024ths, 512);
    });

    test('power-only frames (flags 0) still decode', () {
      final b = ByteData(4)
        ..setUint16(0, 0, Endian.little)
        ..setInt16(2, 333, Endian.little);

      final cp = decodeCyclingPowerMeasurement(b.buffer.asUint8List())!;

      expect(cp.powerWatts, 333);
      expect(cp.crankRevolutions, isNull);
    });
  });
}
