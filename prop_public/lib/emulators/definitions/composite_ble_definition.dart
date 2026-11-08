import 'dart:typed_data';

import 'package:prop/emulators/ble_definition.dart';
import 'package:universal_ble/universal_ble.dart';

/// Aggregates several child [BleDefinition]s into a single virtual
/// peripheral: one GATT server (one transporter) exposes every child's
/// services, and incoming reads/writes/subscriptions are routed to the child
/// that owns the characteristic.
///
/// Reimplemented for the public build — routing is by service UUID for
/// characteristic lookup and by characteristic UUID for read/write dispatch.
class CompositeBleDefinition extends BleDefinition {
  CompositeBleDefinition({List<BleDefinition> initial = const []}) {
    _children.addAll(initial);
    for (final c in initial) {
      _bindChild(c);
    }
  }

  final List<BleDefinition> _children = [];

  /// The composite is a [BleDefinition], not a [Transporter] — assigning
  /// `def.transporter = this` would be a type error. Instead, children whose
  /// transporter slot is empty route their notifications up to us via
  /// [_routeNotification]; we forward them to whatever Transporter the app
  /// layer (DirconEmulator) bound to this composite.
  void _bindChild(BleDefinition def) {
    if (def.transporter == null) def.compositeRouter = _routeNotification;
  }

  void _unbindChild(BleDefinition def) {
    if (identical(def.compositeRouter, _routeNotification)) def.compositeRouter = null;
  }

  /// Called by routed children instead of pushing straight to a transporter.
  void _routeNotification(
    String characteristicUUID,
    List<int> data, {
    int responseCode = 1,
  }) {
    sendCharacteristicNotification(characteristicUUID, data, responseCode: responseCode);
  }

  /// Read-only view of the currently attached children, in attach-order.
  List<BleDefinition> get children => List.unmodifiable(_children);

  /// Attach [def] as a new child. Returns `true` if it was newly added.
  bool attach(BleDefinition def) {
    if (_children.contains(def)) return false;
    _children.add(def);
    _bindChild(def);
    return true;
  }

  /// Detach [def]. Returns `true` if [def] was a current child.
  bool detach(BleDefinition def) {
    final removed = _children.remove(def);
    if (removed) _unbindChild(def);
    return removed;
  }

  /// First child whose runtime type is [T], or `null` if none.
  T? firstOfType<T extends BleDefinition>() {
    for (final c in _children) {
      if (c is T) return c;
    }
    return null;
  }

  static String _norm(String uuid) => uuid.trim().toLowerCase();

  @override
  List<String> get serviceUUIDs {
    final out = <String>[];
    for (final c in _children) {
      for (final s in c.serviceUUIDs) {
        if (!out.any((e) => _norm(e) == _norm(s))) out.add(s);
      }
    }
    return out;
  }

  @override
  List<String> get advertiseServiceUUIDs {
    final out = <String>[];
    for (final c in _children) {
      for (final s in c.advertiseServiceUUIDs) {
        if (!out.any((e) => _norm(e) == _norm(s))) out.add(s);
      }
    }
    return out;
  }

  /// Merged advertisement: name from the first child that has one, union of
  /// service UUIDs, manufacturer data from the first provider.
  @override
  PeripheralAdvertisement? get advertisement {
    for (final c in _children) {
      if (c.advertisement != null) return c.advertisement;
    }
    return null;
  }

  /// The child owning [serviceUUID], or null.
  BleDefinition? _ownerOfService(String serviceUUID) {
    final s = _norm(serviceUUID);
    for (final c in _children) {
      if (c.serviceUUIDs.any((e) => _norm(e) == s)) return c;
    }
    return null;
  }

  /// The child owning [characteristicUUID] (searched across its services).
  BleDefinition? _ownerOfCharacteristic(String characteristicUUID) {
    final ch = _norm(characteristicUUID);
    for (final c in _children) {
      for (final s in c.serviceUUIDs) {
        if (c.getCharacteristics(s).any((e) => _norm(e.uuid) == ch)) return c;
      }
    }
    return null;
  }

  @override
  List<BleCharacteristic> getCharacteristics(String serviceUUID) {
    final owner = _ownerOfService(serviceUUID);
    if (owner == null || identical(owner, this)) return const [];
    return owner.getCharacteristics(serviceUUID);
  }

  @override
  void onWriteRequest(String characteristicUUID, List<int> characteristicData) {
    final owner = _ownerOfCharacteristic(characteristicUUID);
    if (owner == null || identical(owner, this)) return;
    owner.onWriteRequest(characteristicUUID, characteristicData);
  }

  @override
  Future<Uint8List>? onReadRequest(String characteristicUUID) {
    final owner = _ownerOfCharacteristic(characteristicUUID);
    if (owner == null || identical(owner, this)) return null;
    return owner.onReadRequest(characteristicUUID);
  }

  @override
  void onNotification(String characteristic, Uint8List bytes) {
    // Fan out to every child that wants it (e.g. multiple metric sinks).
    for (final c in List.of(_children)) {
      c.onNotification(characteristic, bytes);
    }
  }

  @override
  void onEnableNotificationRequest(String characteristicUUID) {
    final owner = _ownerOfCharacteristic(characteristicUUID);
    if (owner == null || identical(owner, this)) return;
    owner.onEnableNotificationRequest(characteristicUUID);
  }

  @override
  void sendCharacteristicNotification(
    String characteristicUUID,
    List<int> data, {
    int responseCode = 1,
  }) {
    // Route straight to the transporter (we ARE the definition bound to it);
    // do not re-enter children to avoid notification loops.
    transporter?.sendCharacteristicNotification(characteristicUUID, data, responseCode: responseCode);
  }

  @override
  void dispose() {
    for (final c in List.of(_children)) {
      c.dispose();
    }
    _children.clear();
  }

  @override
  void debug() {
    for (final c in _children) {
      c.debug();
    }
  }
}
