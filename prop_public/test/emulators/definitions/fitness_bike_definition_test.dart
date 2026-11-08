import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prop/emulators/definitions/fitness_bike_definition.dart';
import 'package:prop/emulators/transporter/transporter.dart';
import 'package:prop/transports/trainer_transport.dart';
import 'package:prop/utils/ftms_control_point.dart';
import 'package:prop/utils/ftms_payloads.dart';
import 'package:universal_ble/universal_ble.dart';

void main() {
  late FitnessBikeDefinition definition;
  late _NotificationCapture capture;
  late _FakeUpstream upstream;

  setUp(() {
    upstream = _FakeUpstream();
    definition = FitnessBikeDefinition(
      connectedDevice: BleDevice(deviceId: 'test', name: 'test'),
      connectedDeviceServices: const [],
      data: ValueNotifier(''),
      transport: upstream,
    );
    capture = _NotificationCapture(definition: definition);
    definition.transporter = capture;
  });

  tearDown(() async {
    definition.dispose();
    await upstream.close();
  });

  test('advertises the standard eight-byte FTMS feature value', () async {
    final feature = (await definition.onReadRequest(
      FitnessBikeDefinition.FITNESS_MACHINE_FEATURE_UUID,
    ))!;

    expect(feature.length, 8);
    final data = ByteData.sublistView(feature);
    // Cadence, Inclination, Resistance Level, Heart Rate and Power are all
    // present in the Indoor Bike Data frames we push to the game.
    expect(
      data.getUint32(0, Endian.little),
      (1 << 0) | (1 << 1) | (1 << 3) | (1 << 7) | (1 << 10) | (1 << 14),
    );
    expect(data.getUint32(4, Endian.little), (1 << 2) | (1 << 3) | (1 << 13));
    expect(await definition.onReadRequest(FitnessBikeDefinition.CYCLING_POWER_FEATURE_UUID), [0x08, 0, 0, 0]);
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

  test('telemetry pushed to the game follows FTMS 0x2AD2 and CPS 0x2A63 layouts', () async {
    definition.subscribeToTrainer();
    upstream.emit(
      FitnessBikeDefinition.INDOOR_BIKE_DATA_UUID,
      _indoorBikeData(cadenceRpm: 90, powerW: 250, speedKph100: 3000),
    );
    await pumpEventQueue();

    expect(definition.powerW.value, 250);
    expect(definition.cadenceRpm.value, 90);
    expect(definition.speedKph.value, closeTo(30.0, 0.01));

    definition.pushTelemetryForTesting();

    final ibd = capture.frameFor(FitnessBikeDefinition.INDOOR_BIKE_DATA_UUID);
    // Flags: cadence (0x0004) + resistance level (0x0020) + power (0x0040) +
    // heart rate (0x0200); instantaneous speed is present because the
    // "More Data" bit is clear.
    expect(ibd.length, 11);
    final ibdData = ByteData.sublistView(ibd);
    expect(ibdData.getUint16(0, Endian.little), 0x0264);
    expect(ibdData.getUint16(2, Endian.little), 3000); // 0.01 km/h
    expect(ibdData.getUint16(4, Endian.little), 180); // 0.5 rpm
    expect(ibdData.getInt16(6, Endian.little), 0); // resistance level
    expect(ibdData.getInt16(8, Endian.little), 250); // watts
    expect(ibdData.getUint8(10), 0); // heart rate

    // The same frame must decode back to the values the app received.
    final decoded = decodeIndoorBikeData(ibd)!;
    expect(decoded.speedKph, closeTo(30.0, 0.01));
    expect(decoded.cadenceRevPerMin, 90);
    expect(decoded.powerWatts, 250);

    final cp = capture.frameFor(FitnessBikeDefinition.CYCLING_POWER_MEASUREMENT_UUID);
    expect(cp.length, 8);
    final cpData = ByteData.sublistView(cp);
    expect(cpData.getUint16(0, Endian.little), 0x0020); // crank revolution data
    expect(cpData.getInt16(2, Endian.little), 250); // power is mandatory
    expect(cpData.getUint16(4, Endian.little), 1); // 90 rpm * 1 s = 1.5 revs -> 1 whole
    expect(cpData.getUint16(6, Endian.little), closeTo(683, 1)); // one rev at 90 rpm (1/1024 s)
  });
}

/// A standard FTMS Indoor Bike Data frame: instantaneous speed (implicit),
/// instantaneous cadence and instantaneous power.
List<int> _indoorBikeData({required int cadenceRpm, required int powerW, required int speedKph100}) {
  const flags = 0x0044; // cadence present | power present
  final b = ByteData(8)
    ..setUint16(0, flags, Endian.little)
    ..setUint16(2, speedKph100, Endian.little)
    ..setUint16(4, cadenceRpm * 2, Endian.little)
    ..setInt16(6, powerW, Endian.little);
  return b.buffer.asUint8List();
}

class _NotificationCapture extends Transporter {
  _NotificationCapture({required super.definition});

  final List<List<int>> values = [];
  final List<({String uuid, Uint8List data})> frames = [];

  @override
  void sendCharacteristicNotification(
    String characteristicUUID,
    List<int> data, {
    int responseCode = 1,
  }) {
    values.add(List<int>.of(data));
    frames.add((uuid: characteristicUUID, data: Uint8List.fromList(data)));
  }

  Uint8List frameFor(String uuid) => frames.lastWhere((f) => f.uuid == uuid).data;
}

class _FakeUpstream extends TrainerTransport {
  final _controller = StreamController<({String characteristic, Uint8List value})>.broadcast();

  @override
  String get id => 'fake-upstream';

  @override
  void Function()? onDisconnected;

  @override
  Future<void> connect() async {}

  @override
  Future<List<BleService>> discoverServices() async => const [];

  @override
  Future<Uint8List> read(String service, String characteristic) async => Uint8List(0);

  @override
  Future<void> write(
    String service,
    String characteristic,
    Uint8List bytes, {
    bool withoutResponse = false,
  }) async {}

  @override
  Future<void> subscribe(String service, String characteristic, {required bool indicate}) async {}

  @override
  Stream<({String characteristic, Uint8List value})> get notifications => _controller.stream;

  @override
  Future<void> disconnect() async => close();

  void emit(String characteristic, List<int> bytes) =>
      _controller.add((characteristic: characteristic, value: Uint8List.fromList(bytes)));

  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
  }
}
