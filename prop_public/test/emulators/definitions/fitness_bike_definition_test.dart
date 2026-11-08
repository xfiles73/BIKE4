import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prop/emulators/definitions/fitness_bike_definition.dart';
import 'package:prop/emulators/transporter/transporter.dart';
import 'package:prop/utils/ftms_control_point.dart';
import 'package:universal_ble/universal_ble.dart';

void main() {
  late FitnessBikeDefinition definition;
  late _NotificationCapture capture;

  setUp(() {
    definition = FitnessBikeDefinition(
      connectedDevice: BleDevice(deviceId: 'test', name: 'test'),
      connectedDeviceServices: const [],
      data: ValueNotifier(''),
    );
    capture = _NotificationCapture(definition: definition);
    definition.transporter = capture;
  });

  test('advertises the standard eight-byte FTMS feature value', () async {
    final feature = (await definition.onReadRequest(
      FitnessBikeDefinition.FITNESS_MACHINE_FEATURE_UUID,
    ))!;

    expect(feature.length, 8);
    final data = ByteData.sublistView(feature);
    expect(data.getUint32(0, Endian.little), (1 << 0) | (1 << 1) | (1 << 3) | (1 << 10) | (1 << 14));
    expect(data.getUint32(4, Endian.little), (1 << 2) | (1 << 3) | (1 << 13));
  });

  test('supported FTMS ranges use standard min, max, and increment fields', () async {
    final inclination = (await definition.onReadRequest(
      FitnessBikeDefinition.SUPPORTED_INCLINATION_RANGE_UUID,
    ))!;
    final resistance = (await definition.onReadRequest(
      FitnessBikeDefinition.SUPPORTED_RESISTANCE_LEVEL_RANGE_UUID,
    ))!;
    final power = (await definition.onReadRequest(
      FitnessBikeDefinition.SUPPORTED_POWER_RANGE_UUID,
    ))!;

    expect(inclination, hasLength(6));
    expect(resistance, hasLength(6));
    expect(power, hasLength(6));
    expect(ByteData.sublistView(inclination).getInt16(0, Endian.little), -100);
    expect(ByteData.sublistView(inclination).getInt16(2, Endian.little), 100);
    expect(ByteData.sublistView(resistance).getInt16(0, Endian.little), 1);
    expect(ByteData.sublistView(resistance).getInt16(2, Endian.little), 24);
    expect(ByteData.sublistView(power).getInt16(0, Endian.little), 0);
    expect(ByteData.sublistView(power).getInt16(2, Endian.little), 2000);
  });

  test('request control receives the standard Control Point response indication', () {
    definition.onWriteRequest(
      FitnessBikeDefinition.FITNESS_MACHINE_CONTROL_POINT_UUID,
      [FtmsOp.requestControl],
    );

    expect(capture.values, [
      [FtmsOp.responseCode, FtmsOp.requestControl, FtmsOp.failureSuccess],
    ]);
  });

  test('unknown Control Point operations are explicitly rejected', () {
    definition.onWriteRequest(
      FitnessBikeDefinition.FITNESS_MACHINE_CONTROL_POINT_UUID,
      [0xff],
    );

    expect(capture.values, [
      [FtmsOp.responseCode, 0xff, FtmsOp.failureOpcodeNotSupported],
    ]);
  });
}

class _NotificationCapture extends Transporter {
  _NotificationCapture({required super.definition});

  final List<List<int>> values = [];

  @override
  void sendCharacteristicNotification(
    String characteristicUUID,
    List<int> data, {
    int responseCode = 1,
  }) {
    values.add(List<int>.of(data));
  }
}
