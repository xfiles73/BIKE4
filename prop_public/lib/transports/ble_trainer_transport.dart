/// Reimplementation of the BLE trainer transport (public build).
///
/// Written from scratch against the public universal_ble API and the Bluetooth
/// SIG FTMS/Cycling Power/Heart Rate GATT specifications — no proprietary
/// source was used or reverse-engineered.
///
/// Responsibilities:
/// - connect / MTU negotiation / service discovery for a physical trainer;
/// - subscribe to every notify/indicate characteristic discovered, which is
///   what makes trainer telemetry (INDOOR_BIKE_DATA, CYCLING_POWER_MEASUREMENT,
///   HEART_RATE_MEASUREMENT, ...) flow into [notifications];
/// - fan-out of notifications and connection state through the plugin's
///   PUBLIC per-device streams (connectionStream / characteristicValueStream),
///   which never touch the app's global onValueChange/onConnectionChange
///   handlers — both consumers receive every event independently;
/// - expose read/write with UUID normalisation so short-form vs full-form
///   representations never cause a silent mismatch.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:prop/transports/trainer_transport.dart';
import 'package:prop/utils/ble_uuids.dart';
import 'package:universal_ble/universal_ble.dart';

class BleTrainerTransport implements TrainerTransport {
  BleTrainerTransport(this.deviceId);

  @override
  final String deviceId;

  /// Upstream identity — same value as [deviceId] for a BLE transport.
  @override
  String get id => deviceId;

  /// Invoked when the transport drops unexpectedly (wired to the per-device
  /// connection stream in [_installListeners]).
  @override
  void Function()? onDisconnected;

  /// Desired MTU for the data channel (FTMS INDOOR_BIKE_DATA + CP payloads fit
  /// comfortably; 517 matches what the app requests for its own connections).
  static const int _requestedMtu = 517;

  final StreamController<({String characteristic, Uint8List value})> _notifications =
      StreamController<({String characteristic, Uint8List value})>.broadcast();

  final List<BleService> _discoveredServices = [];
  bool _subscribed = false;
  bool _disposed = false;

  // NOTE: il plugin universal_ble espone i callback globali SOLO come setter
  // (static set onValueChange / onConnectionChange, senza getter), quindi non
  // e' possibile leggere-catene-ripristinare l'handler dell'app senza
  // calpestarlo. Usiamo invece gli stream pubblici per-device del plugin —
  // connectionStream(deviceId) e characteristicValueStream(...) — che sono
  // broadcast e indipendenti dai callback globali: l'handler di Connection
  // continua a ricevere tutto, e questo trasporto ottiene la sua copia.
  StreamSubscription<bool>? _connSub;
  final Map<String, StreamSubscription<Uint8List>> _valueSubs = {};

  @override
  Future<void> connect() async {
    if (_disposed) throw StateError('BleTrainerTransport already disposed');
    _installListeners();
    await UniversalBle.connect(deviceId);
    try {
      await UniversalBle.requestMtu(deviceId, _requestedMtu);
    } catch (e) {
      // MTU negotiation is best-effort: some stacks reject requests above
      // their negotiated maximum. Default 23-byte ATT still carries FTMS
      // control writes and notifications fine.
      debugPrint('BleTrainerTransport: MTU request failed ($e), continuing with default MTU');
    }
  }

  void _installListeners() {
    if (_disposed) return;
    _connSub ??= UniversalBle.connectionStream(deviceId).listen((isConnected) {
      if (!isConnected && !_disposed) {
        _subscribed = false;
        onDisconnected?.call();
      }
    });
  }

  /// Fan-out of one characteristic's values into [notifications], using the
  /// plugin's public per-characteristic broadcast stream. Idempotent.
  void _relayCharacteristic(String characteristic) {
    final c = TrainerUuids.normalizeUuid(characteristic);
    _valueSubs.putIfAbsent(
      c,
      () => UniversalBle.characteristicValueStream(deviceId, c).listen((bytes) {
        if (!_disposed) _notifications.add((characteristic: c, value: bytes));
      }),
    );
  }

  @override
  Future<List<BleService>> discoverServices() async {
    final services = await UniversalBle.discoverServices(deviceId);
    _discoveredServices
      ..clear()
      ..addAll(services);
    return services;
  }

  @override
  Future<Uint8List> read(String service, String characteristic) =>
      UniversalBle.read(deviceId, TrainerUuids.normalizeUuid(service), TrainerUuids.normalizeUuid(characteristic));

  @override
  Future<void> write(
    String service,
    String characteristic,
    Uint8List bytes, {
    bool withoutResponse = false,
  }) async {
    await UniversalBle.write(
      deviceId,
      TrainerUuids.normalizeUuid(service),
      TrainerUuids.normalizeUuid(characteristic),
      bytes,
      withoutResponse: withoutResponse,
    );
  }

  @override
  Future<void> subscribe(String service, String characteristic, {required bool indicate}) async {
    final s = TrainerUuids.normalizeUuid(service);
    final c = TrainerUuids.normalizeUuid(characteristic);
    _relayCharacteristic(c);
    if (indicate) {
      await UniversalBle.subscribeIndications(deviceId, s, c);
    } else {
      await UniversalBle.subscribeNotifications(deviceId, s, c);
    }
  }

  /// Subscribes to every notifiable/indicatable characteristic of the given
  /// (or, when null, last-discovered) services. This is the call that turns a
  /// freshly-connected trainer into a live telemetry source: a trainer only
  /// sends INDOOR_BIKE_DATA / CP measurements once the corresponding CCCD has
  /// been enabled. Safe to call repeatedly — re-subscription attempts on an
  /// already-enabled descriptor are harmless, and failures on individual
  /// characteristics are logged and skipped rather than aborting the batch.
  Future<void> subscribeToAllDiscovered([List<BleService>? services]) async {
    final list = services ?? _discoveredServices;
    for (final service in list) {
      for (final characteristic in service.characteristics) {
        final props = characteristic.properties;
        final canNotify = props.contains(CharacteristicProperty.notify);
        final canIndicate = props.contains(CharacteristicProperty.indicate);
        if (!canNotify && !canIndicate) continue;
        try {
          await subscribe(service.uuid, characteristic.uuid, indicate: canIndicate && !canNotify);
        } catch (e) {
          debugPrint('BleTrainerTransport: subscribe failed ${service.uuid}/${characteristic.uuid}: $e');
        }
      }
    }
    _subscribed = true;
  }

  @override
  Stream<({String characteristic, Uint8List value})> get notifications => _notifications.stream;

  @override
  Future<void> disconnect() async {
    try {
      await UniversalBle.disconnect(deviceId);
    } catch (_) {
      // Already disconnected on some stacks — nothing useful left to do.
    }
  }

  /// Cancels the per-device listeners and closes the notification stream.
  /// Called by definitions on teardown; idempotent. Does NOT touch the
  /// plugin's global callbacks, which belong to the app layer.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _connSub?.cancel();
    _connSub = null;
    for (final sub in _valueSubs.values) {
      sub.cancel();
    }
    _valueSubs.clear();
    unawaited(_notifications.close());
  }
}
