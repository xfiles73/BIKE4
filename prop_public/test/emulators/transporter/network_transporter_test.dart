import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prop/emulators/ble_definition.dart';
import 'package:prop/emulators/transporter/network_transporter.dart';
import 'package:prop/utils/constants.dart';
import 'package:universal_ble/universal_ble.dart';

void main() {
  late _TransportHarness harness;

  setUp(() async {
    harness = await _TransportHarness.connect();
  });

  tearDown(() async {
    await harness.dispose();
  });

  test('service discovery returns raw UUIDs in a versioned DirCon frame', () async {
    final response = await harness.exchange([
      1,
      FtmsMdnsConstants.DC_MESSAGE_DISCOVER_SERVICES,
      0x2a,
      0,
      0,
      0,
    ], splitAfter: 3);

    final service = NetworkTransporter.uuidBytes(_TestDefinition.serviceUuid);
    expect(
      response,
      [
        1,
        FtmsMdnsConstants.DC_MESSAGE_DISCOVER_SERVICES,
        0x2a,
        FtmsMdnsConstants.DC_RC_REQUEST_COMPLETED_SUCCESSFULLY,
        0,
        16,
        ...service,
      ],
    );
  });

  test('characteristic discovery prefixes service UUID and maps INDICATE to DirCon NOTIFY', () async {
    final service = NetworkTransporter.uuidBytes(_TestDefinition.serviceUuid);
    final characteristic = NetworkTransporter.uuidBytes(_TestDefinition.characteristicUuid);
    final response = await harness.exchange([
      1,
      FtmsMdnsConstants.DC_MESSAGE_DISCOVER_CHARACTERISTICS,
      0x2b,
      0,
      0,
      16,
      ...service,
    ]);

    expect(
      response,
      [
        1,
        FtmsMdnsConstants.DC_MESSAGE_DISCOVER_CHARACTERISTICS,
        0x2b,
        FtmsMdnsConstants.DC_RC_REQUEST_COMPLETED_SUCCESSFULLY,
        0,
        33,
        ...service,
        ...characteristic,
        // DirCon properties are only READ 0x01, WRITE 0x02 and NOTIFY 0x04:
        // there is no INDICATE property/message type. A write+indicate
        // characteristic (the FTMS Control Point) must therefore advertise
        // WRITE|NOTIFY = 0x06, or clients never subscribe to its responses.
        0x06,
      ],
    );
  });
  test('read echoes the characteristic UUID before the value', () async {
    final characteristic = NetworkTransporter.uuidBytes(_TestDefinition.characteristicUuid);
    final response = await harness.exchange([
      1,
      FtmsMdnsConstants.DC_MESSAGE_READ_CHARACTERISTIC,
      0x2c,
      0,
      0,
      16,
      ...characteristic,
    ]);

    expect(
      response,
      [
        1,
        FtmsMdnsConstants.DC_MESSAGE_READ_CHARACTERISTIC,
        0x2c,
        FtmsMdnsConstants.DC_RC_REQUEST_COMPLETED_SUCCESSFULLY,
        0,
        18, // UUID (16) + value (2)
        ...characteristic,
        ..._TestDefinition.readValue,
      ],
    );
  });

  test('write echoes the characteristic UUID', () async {
    final characteristic = NetworkTransporter.uuidBytes(_TestDefinition.characteristicUuid);
    final response = await harness.exchange([
      1,
      FtmsMdnsConstants.DC_MESSAGE_WRITE_CHARACTERISTIC,
      0x2d,
      0,
      0,
      17,
      ...characteristic,
      0x01,
    ]);

    expect(
      response,
      [
        1,
        FtmsMdnsConstants.DC_MESSAGE_WRITE_CHARACTERISTIC,
        0x2d,
        FtmsMdnsConstants.DC_RC_REQUEST_COMPLETED_SUCCESSFULLY,
        0,
        16,
        ...characteristic,
      ],
    );
  });

  test('enable notifications echoes the characteristic UUID', () async {
    final characteristic = NetworkTransporter.uuidBytes(_TestDefinition.characteristicUuid);
    final response = await harness.exchange([
      1,
      FtmsMdnsConstants.DC_MESSAGE_ENABLE_CHARACTERISTIC_NOTIFICATIONS,
      0x2e,
      0,
      0,
      17,
      ...characteristic,
      0x01,
    ]);

    expect(
      response,
      [
        1,
        FtmsMdnsConstants.DC_MESSAGE_ENABLE_CHARACTERISTIC_NOTIFICATIONS,
        0x2e,
        FtmsMdnsConstants.DC_RC_REQUEST_COMPLETED_SUCCESSFULLY,
        0,
        16,
        ...characteristic,
      ],
    );
  });
}

class _TestDefinition extends BleDefinition {
  static const serviceUuid = '00001826-0000-1000-8000-00805f9b34fb';
  static const characteristicUuid = '00002ad9-0000-1000-8000-00805f9b34fb';
  static const readValue = [0xaa, 0xbb];

  @override
  List<String> get serviceUUIDs => const [serviceUuid];

  @override
  List<String> get advertiseServiceUUIDs => serviceUUIDs;

  @override
  List<BleCharacteristic> getCharacteristics(String serviceUUID) => [
        BleCharacteristic(characteristicUuid, [
          CharacteristicProperty.write,
          CharacteristicProperty.indicate,
        ], const []),
      ];

  @override
  void onWriteRequest(String characteristicUUID, List<int> characteristicData) {}

  @override
  Future<Uint8List>? onReadRequest(String characteristicUUID) =>
      Future.value(Uint8List.fromList(readValue));

  @override
  void onNotification(String characteristic, Uint8List bytes) {}
}

class _TransportHarness {
  final ServerSocket server;
  final Socket client;
  final Socket accepted;
  late final NetworkTransporter transporter;
  final BytesBuilder _received = BytesBuilder(copy: false);
  Completer<List<int>>? _pendingResponse;
  late final StreamSubscription<List<int>> _subscription;

  _TransportHarness._(this.server, this.client, this.accepted) {
    transporter = NetworkTransporter(
      socket: accepted,
      definition: _TestDefinition(),
    );
    _subscription = client.listen(_handleClientData);
  }

  static Future<_TransportHarness> connect() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final acceptedSocketFuture = server.first;
    final client = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    final acceptedSocket = await acceptedSocketFuture;
    return _TransportHarness._(server, client, acceptedSocket);
  }

  Future<List<int>> exchange(List<int> request, {int? splitAfter}) async {
    final response = Completer<List<int>>();
    _pendingResponse = response;
    if (splitAfter == null) {
      client.add(request);
    } else {
      client.add(request.sublist(0, splitAfter));
      await client.flush();
      client.add(request.sublist(splitAfter));
    }
    await client.flush();
    return response.future.timeout(const Duration(seconds: 2));
  }

  void _handleClientData(List<int> chunk) {
    _received.add(chunk);
    final bytes = _received.takeBytes();
    if (bytes.length < 6) {
      _received.add(bytes);
      return;
    }
    final length = (bytes[4] << 8) | bytes[5];
    final frameLength = 6 + length;
    if (bytes.length < frameLength) {
      _received.add(bytes);
      return;
    }
    final pending = _pendingResponse;
    _pendingResponse = null;
    pending?.complete(bytes.sublist(0, frameLength));
    if (bytes.length > frameLength) {
      _received.add(bytes.sublist(frameLength));
    }
  }

  Future<void> dispose() async {
    await _subscription.cancel();
    transporter.dispose();
    accepted.destroy();
    client.destroy();
    await server.close();
  }
}
