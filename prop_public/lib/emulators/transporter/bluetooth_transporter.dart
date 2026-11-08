import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:prop/emulators/ble_definition.dart';
import 'package:prop/emulators/transporter/transporter.dart';
import 'package:universal_ble/universal_ble.dart';

/// Exposes a [BleDefinition] over native BLE peripheral mode.
///
/// Reimplemented for the public build from the universal_ble peripheral API
/// (GATT server: addService / startAdvertising / read-write handlers /
/// updateCharacteristicValue). This is what lets Zwift / Rouvy / MyWhoosh on
/// Windows actually *see* and connect to the BikeControl virtual trainer.
///
/// Threading/callback model notes:
/// - universal_ble installs ONE global read handler and ONE global write
///   handler per process ([setReadRequestHandlers]/[setWriteRequestHandlers]).
///   We keep them as static maps keyed by 128-bit characteristic UUID so that
///   several transporters (e.g. the DirCon emulator + a standalone sensor) can
///   coexist without clobbering each other; [dispose] unregisters our keys.
/// - The subscription stream is global too; we listen once per instance and
///   filter by the characteristics we own.

/// Normalize any UUID form (16-bit short like "2ACC", bare 32-hex, dashed
/// 128-bit) to a lowercase 128-bit string. Manual expansion for short forms
/// so we never throw on the definitions' mixed-case inputs.
String bleUuid(String uuid) {
  var t = uuid.trim();
  if (t.startsWith('0x') || t.startsWith('0X')) t = t.substring(2);
  if (!t.contains('-')) {
    if (t.length <= 8) {
      t = t.padLeft(8, '0');
      return "$t-0000-1000-8000-00805f9b34fb".toLowerCase();
    }
    if (t.length == 32) {
      return "${t.substring(0, 8)}-${t.substring(8, 12)}-${t.substring(12, 16)}"
          "-${t.substring(16, 20)}-${t.substring(20, 32)}".toLowerCase();
    }
  }
  return t.toLowerCase();
}

class BluetoothTransporter extends Transporter {
  BluetoothTransporter({
    required super.definition,
    this.advertisementName = 'BikeControl Virtual',
  });

  final String advertisementName;

  /// Global router: characteristic UUID (lowercase 128-bit) -> active
  /// transporter. Installed lazily on first [start].
  static final Map<String, BluetoothTransporter> _readRouter = {};
  static bool _routerInstalled = false;

  static String _norm(String uuid) => uuid.toLowerCase();

  static void _installRouterOnce() {
    if (_routerInstalled) return;
    _routerInstalled = true;
    UniversalBlePeripheral.setReadRequestHandlers((deviceId, characteristicId, offset, value) {
      final t = _readRouter[_norm(characteristicId)];
      if (t == null) return null; // let the platform answer with its cached value
      return t._handleRead(deviceId, characteristicId, offset, value);
    });
    UniversalBlePeripheral.setWriteRequestHandlers((deviceId, characteristicId, offset, value) {
      final t = _readRouter[_norm(characteristicId)];
      if (t == null) return null;
      return t._handleWrite(deviceId, characteristicId, offset, value);
    });
  }

  final ValueNotifier<bool> _hasSubscribersNotifier = ValueNotifier<bool>(false);

  /// Flips true once a central subscribes to a notifiable characteristic.
  ValueListenable<bool> get hasSubscribers => _hasSubscribersNotifier;

  final Set<String> _ownedCharacteristics = {};
  final Set<String> _subscribedClients = {};
  String? _connectedDeviceId;

  StreamSubscription<BlePeripheralConnectionStateChanged>? _connectionSub;
  StreamSubscription<BlePeripheralCharacteristicSubscriptionChanged>? _subscriptionSub;

  bool _servicesAdded = false;
  bool _advertising = false;

  bool get isAdvertising => _advertising;

  /// Aggregate the definition's services into GATT-server services.
  List<BlePeripheralService> _buildServices() {
    final out = <BlePeripheralService>[];
    for (final serviceUUID in definition.serviceUUIDs) {
      final chars = definition.getCharacteristics(serviceUUID);
      final perChars = <BlePeripheralCharacteristic>[];
      for (final ch in chars) {
        final props = ch.properties.isEmpty
            ? const [CharacteristicProperty.read]
            : ch.properties;
        final permissions = <PeripheralAttributePermission>[
          if (props.contains(CharacteristicProperty.read)) PeripheralAttributePermission.readable,
          if (props.any((p) => p == CharacteristicProperty.write || p == CharacteristicProperty.writeWithoutResponse))
            PeripheralAttributePermission.writeable,
        ];
        perChars.add(
          BlePeripheralCharacteristic(
            uuid: ch.uuid,
            properties: props,
            permissions: permissions.isEmpty
                ? const [PeripheralAttributePermission.readable]
                : permissions,
          ),
        );
        _ownedCharacteristics.add(_norm(bleUuid(ch.uuid)));
      }
      if (perChars.isNotEmpty) {
        out.add(BlePeripheralService(uuid: serviceUUID, characteristics: perChars));
      }
    }
    return out;
  }

  Future<void> start({bool advertise = true}) async {
    // Refuse to start an empty peripheral: Windows rejects an advertisement
    // with no service at startAdvertising, which surfaces later as a cryptic
    // platform error. Fail loudly here instead (see StandaloneSensorLifecycle).
    if (definition.serviceUUIDs.isEmpty) {
      throw StateError(
        'BluetoothTransporter.start: refusing to start an empty peripheral '
        '(no services attached to ${definition.runtimeType}). Attach the '
        'definition before starting the server.',
      );
    }

    _installRouterOnce();

    await stopAdvertising();
    await UniversalBlePeripheral.clearServices();

    for (final service in _buildServices()) {
      await UniversalBlePeripheral.addService(service);
    }
    _servicesAdded = true;

    // Register every owned characteristic in the global router.
    for (final uuid in _ownedCharacteristics) {
      _readRouter[uuid] = this;
    }

    _connectionSub ??= UniversalBlePeripheral.connectionStateStream.listen((e) {
      if (e.connected) {
        _connectedDeviceId = e.deviceId;
      } else {
        if (_connectedDeviceId == e.deviceId) _connectedDeviceId = null;
        _subscribedClients.remove(e.deviceId);
        _hasSubscribersNotifier.value = _subscribedClients.isNotEmpty;
      }
    });

    _subscriptionSub ??= UniversalBlePeripheral.characteristicSubscriptionStream.listen((e) {
      final key = _norm(e.characteristicId);
      if (!_ownedCharacteristics.contains(key)) return;
      if (e.isSubscribed) {
        _subscribedClients.add(e.deviceId);
        definition.onEnableNotificationRequest(e.characteristicId);
      } else {
        _subscribedClients.remove(e.deviceId);
      }
      _hasSubscribersNotifier.value = _subscribedClients.isNotEmpty;
    });

    if (advertise) await startAdvertising();
  }

  Future<void> startAdvertising() async {
    final services = definition.advertiseServiceUUIDs.isNotEmpty
        ? definition.advertiseServiceUUIDs
        : definition.serviceUUIDs;
    if (services.isEmpty) return;
    try {
      await UniversalBlePeripheral.startAdvertising(
        services: services,
        localName: advertisementName,
      );
      _advertising = true;
    } catch (e) {
      // Some stacks throw "advertising already started" - treat as success.
      if (e.toString().toLowerCase().contains('already')) {
        _advertising = true;
      } else {
        rethrow;
      }
    }
  }

  Future<void> stopAdvertising() async {
    try {
      await UniversalBlePeripheral.stopAdvertising();
    } catch (_) {
      // Not advertising / platform hiccup: idempotent stop.
    }
    _advertising = false;
  }

  Future<void> stop() async {
    await stopAdvertising();
    for (final uuid in _ownedCharacteristics) {
      if (_readRouter[uuid] == this) _readRouter.remove(uuid);
    }
    try {
      await UniversalBlePeripheral.clearServices();
    } catch (_) {}
    _servicesAdded = false;
    _subscribedClients.clear();
    _connectedDeviceId = null;
    _hasSubscribersNotifier.value = false;
  }

  PeripheralReadRequestResult? _handleRead(
    String deviceId,
    String characteristicId,
    int offset,
    Uint8List? value,
  ) {
    try {
      final result = definition.onReadRequest(characteristicId);
      if (result == null) return null; // answer from the platform-cached value
      // The definition returns a Future; bridge it by pushing the bytes into
      // the characteristic value when the future completes.
      result.then((bytes) {
        UniversalBlePeripheral.updateCharacteristicValue(
          characteristicId: characteristicId,
          value: bytes,
          deviceId: deviceId,
        ).catchError((_) {});
      });
      return null;
    } catch (e) {
      debugPrint('BluetoothTransporter read error ($characteristicId): $e');
      return null;
    }
  }

  PeripheralWriteRequestResult? _handleWrite(
    String deviceId,
    String characteristicId,
    int offset,
    Uint8List? value,
  ) {
    try {
      definition.onWriteRequest(characteristicId, value ?? Uint8List(0));
      return PeripheralWriteRequestResult(status: 0);
    } catch (e) {
      debugPrint('BluetoothTransporter write error ($characteristicId): $e');
      return PeripheralWriteRequestResult(status: 1);
    }
  }

  @override
  void sendCharacteristicNotification(String characteristicUUID, List<int> data, {int responseCode = 1}) {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final targets = _subscribedClients.toList();
    if (targets.isEmpty && _connectedDeviceId == null) return;
    if (targets.isEmpty) {
      UniversalBlePeripheral.updateCharacteristicValue(
        characteristicId: characteristicUUID,
        value: bytes,
        deviceId: _connectedDeviceId,
      ).catchError((_) {});
      return;
    }
    for (final deviceId in targets) {
      UniversalBlePeripheral.updateCharacteristicValue(
        characteristicId: characteristicUUID,
        value: bytes,
        deviceId: deviceId,
      ).catchError((_) {});
    }
  }

  @override
  void dispose() {
    _connectionSub?.cancel();
    _subscriptionSub?.cancel();
    _connectionSub = null;
    _subscriptionSub = null;
    for (final uuid in _ownedCharacteristics) {
      if (_readRouter[uuid] == this) _readRouter.remove(uuid);
    }
    _ownedCharacteristics.clear();
    _hasSubscribersNotifier.value = false;
  }
}
