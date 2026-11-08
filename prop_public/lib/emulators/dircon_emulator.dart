// Reimplementation for the public build: drives the DirCon-over-TCP server,
// binds it to the composite definition via NetworkTransporter and publishes
// the `_wahoo-fitness-tnp._tcp` mDNS record so Rouvy / MyWhoosh / Zwift-side
// companion apps can discover BikeControl on the LAN.
//
// BLE-peripheral advertising is intentionally not attempted: universal_ble
// has no Windows GATT-server backend (see BluetoothTransporter). The WiFi
// (DirCon) path is the supported route on desktop; RetrofitMode.bluetooth
// falls back to the TCP server with a warning.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:prop/emulators/ble_definition.dart';
import 'package:prop/emulators/definitions/composite_ble_definition.dart';
import 'package:prop/emulators/definitions/fitness_bike_definition.dart';
import 'package:prop/emulators/definitions/sensor_definition.dart';
import 'package:prop/emulators/definitions/zwift_click_definition.dart';
import 'package:prop/emulators/definitions/zwift_emulator_definition.dart';
import 'package:prop/emulators/transporter/network_transporter.dart';
import 'package:prop/mdns/service_advertiser.dart';
import 'package:prop/utils/resilient_tcp_server.dart';
import 'package:prop/utils/self_advertisement_registry.dart';
import 'package:prop/utils/shared.dart';

enum RetrofitMode {
  proxy,
  wifi,
  bluetooth;

  String get label => switch (this) {
    RetrofitMode.proxy => 'Proxy',
    RetrofitMode.wifi => 'Virtual Shifting (WiFi)',
    RetrofitMode.bluetooth => 'Virtual Shifting (Bluetooth)',
  };
}

/// Standard DirCon port advertised by most trainer vendors.
const int kStandardDirconPort = 36867;

int _portNumberIterator = 36868;

/// Test seam: rebase the TCP port iterator.
@visibleForTesting
void debugSetDirconPortBase(int base) => _portNumberIterator = base;

class DirconEmulator {
  /// [preferredPort] pins the TCP port the emulator asks its server to bind
  /// first. Left unset it auto-assigns a distinct port so concurrent
  /// instances don't pile onto one.
  DirconEmulator({int? preferredPort}) : _ownPort = preferredPort ?? _portNumberIterator++;

  final int _ownPort;

  /// Serve on the standard DirCon port instead of this instance's own port
  /// while it returns true.
  bool Function()? preferStandardPort;

  /// The port this emulator prefers for its DirCon TCP server. The port it
  /// *actually* bound is [boundPort] (may differ after fallback).
  int get preferredPort => (preferStandardPort?.call() ?? false) ? kStandardDirconPort : _ownPort;

  /// Forces the TCP listener to IPv4 only while it returns true.
  bool Function()? forceIPv4;

  /// Overrides the advertised peripheral / service name.
  String? Function()? advertisementNameOverride;

  /// Advertises 16-bit service UUIDs in their bare form while it returns true.
  bool Function()? bareShortServiceUuids;

  /// Optional advertiser selector for clients that resolve only through a
  /// specific mDNS daemon. Null uses the platform default advertiser.
  ServiceAdvertiser? Function()? serviceAdvertiser;

  final ValueNotifier<bool> isStarted = ValueNotifier(false);
  final ValueNotifier<bool> isConnected = ValueNotifier(false);
  final ValueNotifier<String> data = ValueNotifier('');

  final ValueNotifier<String?> _localAddressN = ValueNotifier<String?>(null);
  ValueListenable<String?> get localAddress => _localAddressN;

  ResilientTcpServer? _server;
  ServiceAdvertisement? _mdnsRegistration;
  NetworkTransporter? _transporter;

  /// Name/port currently registered in [SelfAdvertisementRegistry] so the
  /// WiFi scanner excludes our own advertisement, and so teardown can remove
  /// exactly the entry we added (the advertisement name can change).
  ({String name, int port})? _registeredEntry;

  /// The port the TCP listener actually bound (fallback-aware), or null when
  /// the server is not running.
  int? get boundPort => _server?.isRunning == true ? _server!.boundPort : null;

  /// All child definitions exposed by this emulator share a single transport
  /// via this composite.
  final CompositeBleDefinition composite = CompositeBleDefinition();

  /// Callback deciding whether the emulator should advertise on session start.
  bool Function()? shouldAdvertise;

  /// Returns the connected trainer-app name (e.g. "Rouvy", "Zwift").
  String? Function()? trainerApp;

  /// Returns `true` when the user is in trial / non-Pro state.
  bool Function()? isTrial;

  /// Returns the connected device's display name.
  String? Function()? deviceName;

  /// Name used for the mDNS SRV instance and the peripheral advertisement.
  String get advertisementName =>
      advertisementNameOverride?.call() ?? deviceName?.call() ?? trainerApp?.call() ?? 'BikeControl';

  /// Forward a raw characteristic notification from the physical trainer into
  /// the composite (used by bridge devices that receive BLE notifications
  /// through the app-level scan connection rather than BleTrainerTransport).
  bool processCharacteristic(String characteristic, Uint8List bytes) {
    try {
      // Route upstream trainer notifications straight to the child that owns
      // the characteristic (FitnessBikeDefinition decodes FTMS/CPS/HR data);
      // fan-out on the composite would drop them into the game-facing sink.
      final norm = characteristic.trim().toLowerCase();
      for (final c in composite.children) {
        if (identical(c, composite)) continue;
        for (final svc in c.serviceUUIDs) {
          if (c.getCharacteristics(svc).any((ch) => ch.uuid.trim().toLowerCase() == norm)) {
            c.onNotification(characteristic, bytes);
            return true;
          }
        }
      }
      composite.onNotification(characteristic, bytes);
      return true;
    } catch (e, s) {
      debugPrint('DirconEmulator.processCharacteristic failed: $e\n$s');
      return false;
    }
  }

  Future<void> startServer({
    required RetrofitMode mode,
    Map<String, Uint8List> mdnsTxt = const {},
  }) async {
    _lastMode = mode;
    _lastMdnsTxt = mdnsTxt;
    // Internal teardown only: stop() would clear _lastMode/_lastMdnsTxt and
    // make a restart() during the reconnect window lose the session.
    await _cleanup();

    if (mode == RetrofitMode.bluetooth && Platform.isWindows) {
      // No native GATT server available: keep serving over TCP so the
      // feature still works for apps that support DirCon-over-WiFi.
      debugPrint('DirconEmulator: BLE peripheral unsupported on Windows, using TCP transport.');
    }

    isConnected.value = false;

    final server = ResilientTcpServer(
      preferredPort: preferredPort,
      forceIPv4: forceIPv4?.call() ?? false,
      owner: this,
      label: 'DirCon ${advertisementName}',
      onClientConnected: (socket) {
        NetworkTransporter.markExternalListen(socket);
        _transporter = NetworkTransporter(socket: socket, definition: composite);
        isConnected.value = true;
        SharedLogic.keepAlive();
        data.value = 'Client connected: ${socket.remoteAddress.address}';
      },
      onData: (socket, chunk) {
        _transporter?.handleIncomingData(chunk);
      },
      onClientDisconnected: () {
        _transporter?.dispose();
        _transporter = null;
        isConnected.value = false;
        SharedLogic.stopKeepAlive();
        data.value = 'Client disconnected';
      },
    );

    await server.start();
    _server = server;
    isStarted.value = true;

    final address = await _resolveAdvertiseAddress();
    _localAddressN.value = address?.address;

    if (address != null && (shouldAdvertise?.call() ?? true)) {
      await _advertise(address, server.boundPort, mdnsTxt);
    }
  }

  Future<InternetAddress?> _resolveAdvertiseAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final i in interfaces) {
        for (final a in i.addresses) {
          if (!a.isLoopback) return a;
        }
      }
    } catch (e) {
      debugPrint('DirconEmulator: interface lookup failed: $e');
    }
    return null;
  }

  Future<void> _advertise(InternetAddress address, int port, Map<String, Uint8List> txt) async {
    final bare = bareShortServiceUuids?.call() ?? false;
    final uuids = composite.advertiseServiceUUIDs.map((u) => _shortForm(u, bare)).join(',');
    final full = <String, Uint8List>{
      ...txt,
      'ble-service-uuids': Uint8List.fromList(uuids.codeUnits),
    };
    try {
      final advertiser = serviceAdvertiser?.call() ?? ServiceAdvertiser.platformDefault();
      _mdnsRegistration = await advertiser.register(
        AdvertisedService(
          name: advertisementName,
          type: '_wahoo-fitness-tnp._tcp',
          port: port,
          address: address,
          txt: full,
        ),
      );
      _registeredEntry = (name: advertisementName, port: port);
      SelfAdvertisementRegistry.instance.add(name: advertisementName, port: port);
      if (kDebugMode) {
        print('DirconEmulator advertising at ${address.address}:$port as "$advertisementName"');
      }
    } catch (e, s) {
      // Advertising failure must not tear down the working TCP server: the
      // app may still be pointed at the port manually.
      debugPrint('DirconEmulator: mDNS registration failed: $e\n$s');
      data.value = 'mDNS advertisement failed (${e.toString().split('\n').first}); '
          'connect manually to ${address.address}:$port';
    }
  }

  static String _shortForm(String uuid, bool bare) {
    final t = uuid.trim().toLowerCase();
    final short = t.startsWith('0000') && t.endsWith('-0000-1000-8000-00805f9b34fb')
        ? t.substring(4, 8)
        : t.replaceAll('-', '');
    return bare ? short : '0x$short';
  }

  Future<void> stop() async {
    _lastMode = null;
    _lastMdnsTxt = const {};
    await _cleanup();
  }

  Future<void> _cleanup() async {
    final entry = _registeredEntry;
    _registeredEntry = null;
    await _mdnsRegistration?.unregister().catchError((Object e) {
      debugPrint('DirconEmulator: mDNS unregister failed: $e');
    });
    _mdnsRegistration = null;
    if (entry != null) {
      SelfAdvertisementRegistry.instance.remove(name: entry.name, port: entry.port);
    }
    _transporter?.dispose();
    _transporter = null;
    await _server?.stop();
    _server = null;
    isStarted.value = false;
    isConnected.value = false;
    _localAddressN.value = null;
  }

  /// Tear down and bring back the server+advertisement (used after a child
  /// definition change alters the service set).
  Future<void> restart() async {
    if (!isStarted.value) return;
    final txt = _lastMdnsTxt;
    await startServer(mode: _lastMode ?? RetrofitMode.wifi, mdnsTxt: txt);
  }

  RetrofitMode? _lastMode;
  Map<String, Uint8List> _lastMdnsTxt = const {};

  void reconnect() {
    _server?.dropClient();
  }

  Future<void> pauseAdvertising() async {
    final reg = _mdnsRegistration;
    final entry = _registeredEntry;
    _registeredEntry = null;
    if (reg != null) {
      await reg.unregister().catchError((Object e) => debugPrint('pauseAdvertising: $e'));
      _mdnsRegistration = null;
    }
    if (entry != null) {
      SelfAdvertisementRegistry.instance.remove(name: entry.name, port: entry.port);
    }
  }

  Future<void> debug() async {
    composite.debug();
  }

  BleDefinition? get activeDefinition => composite;

  /// Whether the composite holds nothing a trainer app would connect for —
  /// rider-metric sinks alone don't count.
  bool get hasNothingToServe => composite.children.every((c) => c is SensorDefinition);

  /// Attach [def] as a child of this emulator's [composite].
  Future<void> attachDefinition(BleDefinition def) async {
    if (def is ZwiftClickDefinition && composite.firstOfType<ZwiftEmulatorDefinition>() != null) {
      composite.detach(composite.firstOfType<ZwiftEmulatorDefinition>()!);
    }
    composite.attach(def);
  }

  /// Detach [def] from this emulator's [composite]. Stops the server when the
  /// last servable child goes away; otherwise re-advertises without its
  /// services.
  Future<void> detachDefinition(BleDefinition def) async {
    composite.detach(def);
    if (!isStarted.value) return;
    if (hasNothingToServe) {
      await stop();
    } else {
      await restart();
    }
  }

  FitnessBikeDefinition? get fitnessBike => composite.firstOfType<FitnessBikeDefinition>();

  @visibleForTesting
  void debugSetActiveDefinition(BleDefinition def) {
    for (final c in List<BleDefinition>.from(composite.children)) {
      composite.detach(c);
    }
    composite.attach(def);
  }

  @visibleForTesting
  void debugSetTransporter(NetworkTransporter transporter) {
    _transporter = transporter;
  }

  /// Remember the mode/txt of the current session so [restart] can replay it.
  /// Called by startServer internally via wrapper below.
  @visibleForTesting
  void debugRecordSession(RetrofitMode mode, Map<String, Uint8List> txt) {
    _lastMode = mode;
    _lastMdnsTxt = txt;
  }
}
