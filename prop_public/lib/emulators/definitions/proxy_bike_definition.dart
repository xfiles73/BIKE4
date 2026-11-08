/// Reimplementation of the trainer *proxy* definition (public build).
///
/// Written from scratch against the Bluetooth SIG GATT specifications. In
/// proxy mode the emulator mirrors a physical trainer: every service/
/// characteristic discovered on the real device is re-exposed to the local
/// trainer app (Zwift/Rouvy/etc.), client writes are forwarded upstream and
/// trainer notifications are relayed back down — no protocol translation,
/// pure passthrough.
///
/// The previous public stub threw [UnimplementedError] from its UUID getters,
/// which made the DirCon server crash mid-handshake; this implementation
/// answers discovery/read/write/notify completely over the injected
/// [TrainerTransport].
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dartx/dartx.dart';
import 'package:flutter/foundation.dart';
import 'package:prop/emulators/ble_definition.dart';
import 'package:prop/transports/ble_trainer_transport.dart';
import 'package:prop/transports/trainer_transport.dart';
import 'package:prop/utils/ble_uuids.dart';
import 'package:prop/utils/ftms_payloads.dart';
import 'package:universal_ble/universal_ble.dart';

class ProxyBikeDefinition extends BleDefinition {
  final BleDevice device;
  final List<BleService> services;
  final ValueNotifier<String> data;

  /// Upstream I/O transport. Defaults to BLE via the device's id.
  final TrainerTransport transport;

  ProxyBikeDefinition({
    required this.services,
    required this.device,
    required this.data,
    TrainerTransport? transport,
  }) : transport = transport ?? BleTrainerTransport(device.deviceId);

  StreamSubscription<({String characteristic, Uint8List value})>? _upstreamSub;

  /// Characteristics the connected client enabled notifications for — we only
  /// subscribe upstream once at least one consumer asked for them.
  final Set<String> _enabledNotifications = {};

  // ── Decoded rider metrics (for the app's UI bindings) ────────────────────
  final ValueNotifier<int?> powerW = ValueNotifier<int?>(null);
  final ValueNotifier<int?> heartRateBpm = ValueNotifier<int?>(null);
  final ValueNotifier<int?> cadenceRpm = ValueNotifier<int?>(null);
  final ValueNotifier<double?> speedKph = ValueNotifier<double?>(null);

  void _updateMetric<T>(ValueNotifier<T> n, T value) {
    if (n.value != value) n.value = value;
  }

  @override
  List<String> get serviceUUIDs => services.map((s) => TrainerUuids.normalizeUuid(s.uuid)).toList();

  @override
  List<String> get advertiseServiceUUIDs => serviceUUIDs;

  @override
  List<BleCharacteristic> getCharacteristics(String serviceUUID) {
    final want = TrainerUuids.normalizeUuid(serviceUUID);
    for (final s in services) {
      if (TrainerUuids.normalizeUuid(s.uuid) == want) return s.characteristics;
    }
    return const [];
  }

  /// Called by the transporter after the client enables notifications for a
  /// characteristic: start relaying that characteristic from the real trainer.
  @override
  void onEnableNotificationRequest(String characteristicUUID) {
    final c = TrainerUuids.normalizeUuid(characteristicUUID);
    if (_enabledNotifications.add(c)) {
      unawaited(_subscribeUpstream(c));
    }
  }

  Future<void> _subscribeUpstream(String characteristic) async {
    final service = _serviceFor(characteristic);
    if (service == null) return;
    final bleChar = _characteristicIn(service, characteristic);
    final indicate =
        bleChar != null &&
        !bleChar.properties.contains(CharacteristicProperty.notify) &&
        bleChar.properties.contains(CharacteristicProperty.indicate);
    try {
      // [_serviceFor] returns the service UUID as a String — pass it directly.
      await transport.subscribe(service, characteristic, indicate: indicate);
      _ensureRelayListening();
    } catch (e) {
      debugPrint('ProxyBikeDefinition: upstream subscribe failed for $characteristic: $e');
    }
  }

  void _ensureRelayListening() {
    if (_upstreamSub != null) return;
    _upstreamSub = transport.notifications.listen((n) {
      _decodeMetrics(n.characteristic, n.value);
      // Relay every upstream notification down to the client; the transporter
      // drops it when nobody subscribed.
      sendCharacteristicNotification(n.characteristic, n.value);
    });
  }

  /// Best-effort metric extraction for the app's own UI bindings. Unknown or
  /// malformed payloads are ignored — decoding failures never break relaying.
  void _decodeMetrics(String characteristic, Uint8List bytes) {
    final short = TrainerUuids.shortForm(characteristic);
    switch (short) {
      case TrainerUuids.indoorBikeData:
        final ibd = decodeIndoorBikeData(bytes);
        if (ibd == null) return;
        if (ibd.powerWatts != null) _updateMetric(powerW, ibd.powerWatts);
        if (ibd.speedKph != null) _updateMetric(speedKph, double.parse(ibd.speedKph!.toStringAsFixed(2)));
        final rpm = ibd.rpmCadence ?? ibd.cadenceRevPerMin;
        if (rpm != null && rpm >= 0) _updateMetric(cadenceRpm, rpm);
        if (ibd.heartRateBpm != null) _updateMetric(heartRateBpm, ibd.heartRateBpm);
      case TrainerUuids.cyclingPowerMeasurement:
        final cp = decodeCyclingPowerMeasurement(bytes);
        if (cp?.powerWatts != null) _updateMetric(powerW, cp!.powerWatts);
      case TrainerUuids.heartRateMeasurement:
        final hr = decodeHeartRate(bytes);
        if (hr != null) _updateMetric(heartRateBpm, hr);
    }
  }

  String? _serviceFor(String characteristic) {
    final c = TrainerUuids.shortForm(characteristic);
    for (final s in services) {
      if (s.characteristics.any((ch) => TrainerUuids.shortForm(ch.uuid) == c)) return s.uuid;
    }
    return null;
  }

  BleCharacteristic? _characteristicIn(String serviceUuid, String characteristic) {
    final norm = TrainerUuids.normalizeUuid(serviceUuid);
    final c = TrainerUuids.shortForm(characteristic);
    for (final s in services) {
      if (TrainerUuids.normalizeUuid(s.uuid) == norm) {
        // Plain loop instead of firstWhereOrNull: this package must not
        // depend on dartx/collection extensions here.
        for (final ch in s.characteristics) {
          if (TrainerUuids.shortForm(ch.uuid) == c) return ch;
        }
        return null;
      }
    }
    return null;
  }

  @override
  Future<Uint8List>? onReadRequest(String characteristicUUID) async {
    final service = _serviceFor(characteristicUUID);
    if (service == null) return Uint8List(0);
    try {
      return await transport.read(service, characteristicUUID);
    } catch (e) {
      debugPrint('ProxyBikeDefinition: read failed $service/$characteristicUUID: $e');
      // The base contract is `Future<Uint8List>?` — a null *result* means
      // "read not supported". Returning a null Future would crash the GATT
      // server when it awaits it, so answer with an empty payload instead.
      return Uint8List(0);
    }
  }

  @override
  void onWriteRequest(String characteristicUUID, List<int> characteristicData) {
    final service = _serviceFor(characteristicUUID);
    if (service == null) return;
    unawaited(
      transport
          .write(service, characteristicUUID, Uint8List.fromList(characteristicData))
          .catchError((Object e) {
            debugPrint('ProxyBikeDefinition: write failed $service/$characteristicUUID: $e');
          }),
    );
  }

  @override
  void onNotification(String characteristic, Uint8List bytes) {
    // Upstream notifications arrive through [_upstreamSub]; this entry point
    // exists for transports that push directly into the definition.
    sendCharacteristicNotification(TrainerUuids.normalizeUuid(characteristic), bytes);
  }

  @override
  void dispose() {
    _upstreamSub?.cancel();
    _upstreamSub = null;
    powerW.dispose();
    heartRateBpm.dispose();
    cadenceRpm.dispose();
    speedKph.dispose();
    final t = transport;
    if (t is BleTrainerTransport) t.dispose();
    super.dispose();
  }
}
