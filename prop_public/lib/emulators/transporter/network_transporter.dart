// DirCon-over-TCP transporter - reimplementation for the public build.
//
// Wire protocol (message-type constants live in `utils/constants.dart`, which
// Rouvy / MyWhoosh / OpenBikeControl parse). Every frame uses the DirCon
// six-byte header:
//
//   u8  protocolVersion
//   u8  messageType
//   u8  sequenceNumber
//   u8  responseCode
//   u16 dataLength        (big-endian)
//   u8[dataLength] payload
//
// Handled from the client (game app):
//   0x01 DISCOVER_SERVICES        -> list of 128-bit service UUIDs
//   0x02 DISCOVER_CHARACTERISTICS -> payload = service UUID (16 bytes),
//                                    reply service UUID + per-char UUID/property pairs
//   0x03 READ_CHARACTERISTIC      -> payload = characteristic UUID,
//                                    forwarded to definition.onReadRequest
//   0x04 WRITE_CHARACTERISTIC     -> payload = char UUID + raw value,
//                                    forwarded to definition.onWriteRequest
//   0x05 ENABLE_NOTIFICATIONS     -> payload = char UUID (+ flag byte),
//                                    registers a subscription
//   0x07 ECHO                     -> echoed back unchanged
//
// Replies carry the response code in header byte 3; notifications ride on 0x06.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:prop/emulators/ble_definition.dart';
import 'package:prop/emulators/transporter/transporter.dart';
import 'package:prop/utils/constants.dart';
import 'package:universal_ble/universal_ble.dart';

/// Exposes a [BleDefinition] over a TCP socket speaking the DirCon wire
/// protocol. One instance per connected client socket (created by the
/// emulator server `onClientConnected` callback).
class NetworkTransporter extends Transporter {
  static const int _protocolVersion = 1;
  static const int _headerSize = 6;

  Socket? socket;

  /// Characteristic UUIDs (normalized lowercase 128-bit) this client enabled
  /// notifications for. Only those receive 0x06 frames; an empty set means
  /// "not subscribed yet" and suppresses all pushes.
  final Set<String> _subscribed = {};

  /// Reassembly buffer for incoming frames (TCP is a stream, not messages).
  final BytesBuilder _rx = BytesBuilder(copy: false);

  NetworkTransporter({this.socket, required super.definition}) {
    definition.transporter = this;
    // When the caller did not wire the socket listener itself (the OBC
    // emulator routes bytes in via handleIncomingData), listen here. The
    // two paths are mutually exclusive in practice; double-delivery would
    // only duplicate idempotent discovery frames.
    if (socket != null && !NetworkTransporter._externalListen.contains(socket)) {
      socket!.listen(
        _onBytes,
        onError: (Object e) => debugPrint('NetworkTransporter socket error: $e'),
        cancelOnError: false,
      );
    }
  }

  static final Set<Socket> _externalListen = {};

  /// Mark [s] as already listened-to by the owning server, so the
  /// constructor does not attach a second listener.
  static void markExternalListen(Socket s) => _externalListen.add(s);

  static String norm(String uuid) {
    var t = uuid.trim().toLowerCase();
    if (t.startsWith('0x')) t = t.substring(2);
    if (!t.contains('-')) {
      if (t.length <= 8) return "${t.padLeft(8, '0')}-0000-1000-8000-00805f9b34fb";
      if (t.length == 32) {
        return "${t.substring(0, 8)}-${t.substring(8, 12)}-${t.substring(12, 16)}"
            "-${t.substring(16, 20)}-${t.substring(20, 32)}";
      }
    }
    return t;
  }

  /// Expand a possibly-short advertised UUID into full 16 raw bytes.
  static Uint8List uuidBytes(String uuid) {
    final hex = norm(uuid).replaceAll('-', '');
    final out = Uint8List(16);
    for (var i = 0; i < 16 && i * 2 + 1 < hex.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String uuidFrom(List<int> b, [int offset = 0]) {
    final sb = StringBuffer();
    for (var i = 0; i < 16; i++) {
      sb.write(b[offset + i].toRadixString(16).padLeft(2, '0'));
    }
    final h = sb.toString();
    return "${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}"
        "-${h.substring(16, 20)}-${h.substring(20, 32)}";
  }

  // -- outgoing frames -----------------------------------------------------

  void _writeFrame(int type, List<int> payload, {int sequenceNumber = 0, int responseCode = 0}) {
    final s = socket;
    if (s == null) return;
    final len = payload.length;
    if (len > 0xffff) throw RangeError.range(len, 0, 0xffff, 'payload.length');
    final header = Uint8List(_headerSize)
      ..[0] = _protocolVersion
      ..[1] = type & 0xff
      ..[2] = sequenceNumber & 0xff
      ..[3] = responseCode & 0xff
      ..[4] = (len >> 8) & 0xff
      ..[5] = len & 0xff;
    try {
      s.add(header);
      if (len > 0) s.add(payload);
    } catch (_) {
      // Client vanished mid-write; the server disconnect handler cleans up.
    }
  }

  @override
  void sendCharacteristicNotification(
    String characteristicUUID,
    List<int> data, {
    int responseCode = 1,
  }) {
    final key = norm(characteristicUUID);
    if (!_subscribed.contains(key)) return;
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final payload = Uint8List(16 + bytes.length)
      ..setRange(0, 16, uuidBytes(key))
      ..setRange(16, 16 + bytes.length, bytes);
    _writeFrame(FtmsMdnsConstants.DC_MESSAGE_CHARACTERISTIC_NOTIFICATION, payload);
  }

  // -- incoming frames -----------------------------------------------------

  void _onBytes(List<int> chunk) {
    _rx.add(chunk);
    var bytes = _rx.takeBytes();
    while (true) {
      if (bytes.length < _headerSize) {
        _rx.add(bytes);
        return;
      }
      final version = bytes[0];
      final type = bytes[1];
      final sequenceNumber = bytes[2];
      final len = (bytes[4] << 8) | bytes[5];
      if (bytes.length < _headerSize + len) {
        _rx.add(bytes);
        return;
      }
      final payload = bytes.sublist(_headerSize, _headerSize + len);
      bytes = bytes.sublist(_headerSize + len);
      try {
        if (version != _protocolVersion) {
          _writeFrame(
            type,
            const [],
            sequenceNumber: sequenceNumber,
            responseCode: FtmsMdnsConstants.DC_RC_UNKNOWN_PROTOCOL_VERSION,
          );
        } else {
          _handleFrame(type, sequenceNumber, payload);
        }
      } catch (e, s) {
        debugPrint('NetworkTransporter frame error (type $type): $e\n$s');
      }
    }
  }

  void _handleFrame(int type, int sequenceNumber, Uint8List p) {
    switch (type) {
      case FtmsMdnsConstants.DC_MESSAGE_DISCOVER_SERVICES:
        final services = definition.serviceUUIDs;
        final out = BytesBuilder();
        for (final s in services) {
          out.add(uuidBytes(s));
        }
        _writeFrame(type, out.toBytes(), sequenceNumber: sequenceNumber);

      case FtmsMdnsConstants.DC_MESSAGE_DISCOVER_CHARACTERISTICS:
        if (p.length < 16) {
          _writeFrame(type, const [], sequenceNumber: sequenceNumber,
              responseCode: FtmsMdnsConstants.DC_RC_SERVICE_NOT_FOUND);
          return;
        }
        final serviceUuid = uuidFrom(p);
        final chars = _characteristicsFor(serviceUuid);
        if (!definition.serviceUUIDs.any((service) => norm(service) == serviceUuid)) {
          _writeFrame(type, const [], sequenceNumber: sequenceNumber,
              responseCode: FtmsMdnsConstants.DC_RC_SERVICE_NOT_FOUND);
          return;
        }
        final out = BytesBuilder();
        out.add(uuidBytes(serviceUuid));
        for (final ch in chars) {
          out.add(uuidBytes(ch.uuid));
          out.addByte(_propertyFlags(ch));
        }
        _writeFrame(type, out.toBytes(), sequenceNumber: sequenceNumber);

      case FtmsMdnsConstants.DC_MESSAGE_READ_CHARACTERISTIC:
        if (p.length < 16) {
          _writeFrame(type, const [], sequenceNumber: sequenceNumber,
              responseCode: FtmsMdnsConstants.DC_RC_CHARACTERISTIC_NOT_FOUND);
          return;
        }
        final uuid = uuidFrom(p);
        final result = definition.onReadRequest(uuid);
        if (result == null) {
          _writeFrame(type, const [], sequenceNumber: sequenceNumber,
              responseCode: FtmsMdnsConstants.DC_RC_CHARACTERISTIC_OPERATION_NOT_SUPPORTED);
          return;
        }
        result.then((bytes) {
          _writeFrame(type, bytes, sequenceNumber: sequenceNumber);
        }).catchError((Object e) {
          debugPrint('NetworkTransporter read failed ($uuid): $e');
          _writeFrame(type, const [], sequenceNumber: sequenceNumber,
              responseCode: FtmsMdnsConstants.DC_RC_UNEXPECTED_ERROR);
        });

      case FtmsMdnsConstants.DC_MESSAGE_WRITE_CHARACTERISTIC:
        if (p.length < 16) {
          _writeFrame(type, const [], sequenceNumber: sequenceNumber,
              responseCode: FtmsMdnsConstants.DC_RC_CHARACTERISTIC_NOT_FOUND);
          return;
        }
        final uuid = uuidFrom(p);
        final value = p.sublist(16);
        definition.onWriteRequest(uuid, value);
        _writeFrame(type, const [], sequenceNumber: sequenceNumber);

      case FtmsMdnsConstants.DC_MESSAGE_ENABLE_CHARACTERISTIC_NOTIFICATIONS:
        if (p.length < 16) {
          _writeFrame(type, const [], sequenceNumber: sequenceNumber,
              responseCode: FtmsMdnsConstants.DC_RC_CHARACTERISTIC_NOT_FOUND);
          return;
        }
        final uuid = uuidFrom(p);
        final enable = p.length < 17 ? true : p[16] != 0;
        if (enable) {
          _subscribed.add(uuid);
          definition.onEnableNotificationRequest(uuid);
        } else {
          _subscribed.remove(uuid);
        }
        _writeFrame(type, const [], sequenceNumber: sequenceNumber);

      case FtmsMdnsConstants.DC_MESSAGE_ECHO:
        _writeFrame(type, p, sequenceNumber: sequenceNumber);

      default:
        _writeFrame(type, const [], sequenceNumber: sequenceNumber,
            responseCode: FtmsMdnsConstants.DC_RC_UNKNOWN_MESSAGE_TYPE);
    }
  }

  /// Resolve characteristics for [serviceUuid] (composite definitions route
  /// through their own getCharacteristics override).
  List<BleCharacteristic> _characteristicsFor(String serviceUuid) {
    for (final s in definition.serviceUUIDs) {
      if (norm(s) == serviceUuid) return definition.getCharacteristics(s);
    }
    return const [];
  }

  static int _propertyFlags(BleCharacteristic ch) {
    var flags = 0;
    bool has(CharacteristicProperty p) => ch.properties.contains(p);
    if (has(CharacteristicProperty.read)) flags |= 0x01;
    if (has(CharacteristicProperty.write) || has(CharacteristicProperty.writeWithoutResponse)) flags |= 0x02;
    if (has(CharacteristicProperty.notify)) flags |= 0x04;
    if (has(CharacteristicProperty.indicate)) flags |= 0x08;
    return flags;
  }

  /// Entry point used by the emulator/server when raw bytes arrive on the
  /// socket (kept for API compatibility with callers that route data in).
  void handleIncomingData(List<int> data) => _onBytes(data);

  @override
  void dispose() {
    _subscribed.clear();
    if (definition.transporter == this) definition.transporter = null;
  }
}
