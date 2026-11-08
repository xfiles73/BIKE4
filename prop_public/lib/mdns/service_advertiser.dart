// Reimplementation for the public build: two backends — the OS responder
// (via the `nsd` plugin) and an in-process lightweight mDNS announcer
// (RFC 6762 PTR/SRV/TXT/A records, Dart sockets only, no native deps).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:prop/mdns/dnssd_service_advertiser.dart';
import 'package:prop/mdns/mdns_responder.dart';

class AdvertisedService {
  /// Instance name, e.g. 'BikeControl'.
  final String name;

  /// Service type without domain, e.g. '_wahoo-fitness-tnp._tcp'.
  final String type;

  final int port;

  /// The IPv4 address to advertise.
  final InternetAddress address;

  final Map<String, Uint8List> txt;

  AdvertisedService({
    required this.name,
    required this.type,
    required this.port,
    required this.address,
    required this.txt,
  });
}

abstract class ServiceAdvertisement {
  Future<void> unregister();
}

abstract class ServiceAdvertiser {
  /// Process-wide advertiser the emulators use.
  static ServiceAdvertiser instance = platformDefault();

  /// The right backend for the current platform. Desktop hosts use the
  /// pure-Dart responder (no Bonjour dependency); mobile uses the OS plugin.
  static ServiceAdvertiser platformDefault() =>
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
      ? ResponderServiceAdvertiser(announceInterval: ResponderServiceAdvertiser.desktopAnnounceInterval)
      : NsdServiceAdvertiser();

  Future<ServiceAdvertisement> register(AdvertisedService service);

  /// The IPv4 currently in our advertisements, or null when nothing is
  /// advertised. Backends whose daemon owns the records report
  /// [untrackedAddress].
  ValueListenable<String?> get advertisedAddress => untrackedAddress;

  /// A never-changing null [advertisedAddress] for backends that do not own
  /// their host records.
  static final ValueListenable<String?> untrackedAddress = ValueNotifier<String?>(null);
}

/// Hostname-label rules shared by the backends that publish their own host
/// record.
abstract final class MdnsHostLabel {
  /// [serviceName] turned into a DNS label, or null when it cannot be one.
  static String? derivedFrom(String serviceName) {
    final label = serviceName
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (label.isEmpty || label.length > 63) return null;
    return label;
  }

  /// The stored random label, or a fresh one stored on the spot.
  static String storedRandom() {
    _random ??= () {
      final r = _rng;
      final sb = StringBuffer('bikecontrol-');
      for (var i = 0; i < 4; i++) {
        sb.write(r.nextInt(0x10000).toRadixString(16).padLeft(4, '0'));
      }
      return sb.toString();
    }();
    return _random!;
  }

  static String? _random;
}

final Random _rng = Random.secure();

// NOTE: the class `NsdServiceAdvertiser` (used by obc_mdns_emulator.dart and
// debug_diagnostics.dart) lives in dnssd_service_advertiser.dart, where it is
// defined as a thin subclass of ResponderServiceAdvertiser. This keeps the
// whole desktop build free of the `nsd` plugin's *registration* API (Bonjour
// is not available on Windows); discovery/browsing via `nsd` still works
// because nsd 4.1.0 ships native Windows support for startDiscovery().

/// The in-process mDNS responder backend (desktop + Android). Publishes PTR /
/// SRV / TXT / A records for one service by answering queries and announcing
/// periodically on 224.0.0.251:5353.
class ResponderServiceAdvertiser implements ServiceAdvertiser {
  static const Duration desktopAnnounceInterval = Duration(seconds: 10);
  static const Duration defaultAnnounceInterval = Duration(seconds: 60);

  final Duration announceInterval;

  ResponderServiceAdvertiser({this.announceInterval = defaultAnnounceInterval});

  RawDatagramSocket? _sock;
  static int _refCount = 0;
  Timer? _announceTimer;
  AdvertisedService? _service;
  String? _hostLabel;
  final List<MdnsQueryLogEntry> _queryLog = [];

  static const int mdnsPort = 5353;
  // InternetAddress's factory is not const-constructible, so this must be a
  // (lazily initialised) final, not a const.
  static final InternetAddress mdnsGroup = InternetAddress('224.0.0.251');

  /// The dedicated mDNS hostname label (without `.local`) all services share.
  /// Null while nothing is advertised.
  String? get hostLabel => _hostLabel;

  /// Android only: whether the active responder socket holds the multicast
  /// lock. False when nothing is currently advertised.
  bool get holdsMulticastLock => _sock != null;

  /// The most recent mDNS queries this responder saw.
  List<MdnsQueryLogEntry> get recentQueries => List.unmodifiable(_queryLog);

  Future<void> refreshAddress() async {
    // Re-read the interface address is handled at register time; nothing to
    // pin in this simplified responder.
  }

  @override
  ValueListenable<String?> get advertisedAddress => ServiceAdvertiser.untrackedAddress;

  @override
  Future<ServiceAdvertisement> register(AdvertisedService service) async {
    _service = service;
    _hostLabel ??=
        MdnsHostLabel.derivedFrom(service.name) ?? MdnsHostLabel.storedRandom();
    if (_sock == null) {
      _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, mdnsPort, reusePort: false);
      try {
        _sock!.joinMulticast(mdnsGroup);
        _sock!.multicastLoopback = true;
      } catch (_) {}
      _sock!.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = _sock!.receive();
          if (dg != null) _handleQuery(dg);
        }
      });
    }
    _refCount++;
    _announceTimer?.cancel();
    _announceTimer = Timer.periodic(announceInterval, (_) => _announce());
    _announce();
    return _ResponderAdvertisement(this);
  }

  void _unregisterInternal() {
    _refCount--;
    if (_refCount <= 0) {
      _announceTimer?.cancel();
      _announceTimer = null;
      _sock?.close();
      _sock = null;
      _refCount = 0;
      _service = null;
    }
  }

  void _announce() {
    final sock = _sock;
    final svc = _service;
    if (sock == null || svc == null) return;
    final bytes = MdnsBuilder.buildAnnouncement(svc, _hostLabel!);
    sock.send(bytes, mdnsGroup, mdnsPort);
  }

  void _handleQuery(Datagram dg) {
    final svc = _service;
    if (svc == null) return;
    try {
      final questions = MdnsBuilder.parseQuestions(dg.data);
      if (questions.isEmpty) return;
      final entry = MdnsQueryLogEntry(
        at: DateTime.now(),
        source: dg.address.address,
        sourcePort: dg.port,
        wantsUnicast: false,
        questions: questions,
        answeredUnicast: false,
        answeredMulticast: true,
      );
      final reply = MdnsBuilder.buildAnswer(svc, _hostLabel!, questions);
      if (reply != null) {
        _sock?.send(reply, dg.address, dg.port);
        _queryLog.add(entry);
        if (_queryLog.length > 50) _queryLog.removeAt(0);
      }
    } catch (e) {
      debugPrint('ResponderServiceAdvertiser query error: $e');
    }
  }
}

class _ResponderAdvertisement implements ServiceAdvertisement {
  final ResponderServiceAdvertiser _owner;
  bool _done = false;
  _ResponderAdvertisement(this._owner);

  @override
  Future<void> unregister() async {
    if (_done) return;
    _done = true;
    _owner._unregisterInternal();
  }
}


/// Minimal RFC-6762 wire builder/parser for one service: PTR + SRV + TXT + A
/// answers and question parsing. Only what a DirCon client needs to resolve
/// `_wahoo-fitness-tnp._tcp` (or any other single instance).
abstract final class MdnsBuilder {
  static const int typeA = 1;
  static const int typePTR = 12;
  static const int typeTXT = 16;
  static const int typeSRV = 33;
  static const int classIN = 1;
  static const int cacheFlushBit = 0x8000;

  static Uint8List _name(String fqdn) {
    final out = BytesBuilder();
    final parts = fqdn.split('.');
    if (parts.isNotEmpty && parts.last.isEmpty) parts.removeLast(); // trailing dot
    for (final label in parts) {
      if (label.isEmpty) continue;
      final b = utf8.encode(label);
      out.addByte(b.length);
      out.add(b);
    }
    out.addByte(0);
    return out.toBytes();
  }

  static void _u16(BytesBuilder b, int v) {
    b.addByte((v >> 8) & 0xff);
    b.addByte(v & 0xff);
  }

  static void _record(
    BytesBuilder out,
    String name,
    int type,
    int ttl,
    List<int> rdata, {
    bool flush = true,
  }) {
    out.add(_name(name));
    _u16(out, type);
    _u16(out, classIN | (flush ? cacheFlushBit : 0));
    _u16(out, ttl);
    _u16(out, rdata.length);
    out.add(rdata);
  }

  static List<int> _txtRdata(Map<String, Uint8List> txt) {
    final b = BytesBuilder();
    // Split into <=255-byte chunks per TXT record rules.
    final joined = BytesBuilder();
    txt.forEach((k, v) {
      joined.add(utf8.encode('$k='));
      joined.add(v);
      joined.addByte(0);
    });
    final all = joined.toBytes();
    var off = 0;
    while (off < all.length) {
      final chunk = min(255, all.length - off);
      b.addByte(chunk);
      b.add(all.sublist(off, off + chunk));
      off += chunk;
    }
    return b.toBytes();
  }

  static Uint8List buildAnnouncement(AdvertisedService svc, String hostLabel) {
    final serviceFq = '${svc.type}.local';
    final instanceFq = '${svc.name}.$serviceFq';
    final hostFq = '$hostLabel.local';
    final out = BytesBuilder();
    _u16(out, 0); // id
    _u16(out, 0x8400); // response, authoritative
    _u16(out, 0); // questions
    _u16(out, 4); // answers
    _record(out, serviceFq, typePTR, 120, _name(instanceFq), flush: false);
    _record(out, instanceFq, typeSRV, 120, () {
      final r = BytesBuilder();
      _u16(r, 0); // priority
      _u16(r, 0); // weight
      _u16(r, svc.port);
      r.add(_name(hostFq));
      return r.toBytes();
    }());
    _record(out, instanceFq, typeTXT, 120, _txtRdata(svc.txt));
    final ip = svc.address.address.split('.').map(int.parse).toList();
    _record(out, hostFq, typeA, 120, ip);
    return out.toBytes();
  }

  static Uint8List? buildAnswer(AdvertisedService svc, String hostLabel, List<String> questions) {
    // Respond only when a question targets our service/instance/host.
    final serviceFq = '${svc.type}.local';
    final instanceFq = '${svc.name}.$serviceFq';
    final hostFq = '$hostLabel.local';
    final wants = {for (final q in questions) q.toLowerCase()};
    final rel = <String>{serviceFq.toLowerCase(), instanceFq.toLowerCase(), hostFq.toLowerCase()};
    if (!wants.any(rel.contains)) return null;
    return buildAnnouncement(svc, hostLabel);
  }

  /// Parse the question names of an mDNS query into readable strings, e.g.
  /// 'PTR _wahoo-fitness-tnp._tcp.local'. Malformed packets yield [].
  static List<String> parseQuestions(Uint8List data) {
    if (data.length < 12) return const [];
    final qd = (data[4] << 8) | data[5];
    final out = <String>[];
    var off = 12;
    for (var i = 0; i < qd; i++) {
      final sb = StringBuffer();
      while (off < data.length) {
        final len = data[off++];
        if (len == 0) break;
        if (len > 191) {
          off += 1;
          break;
        }
        if (sb.isNotEmpty) sb.write('.');
        sb.write(utf8.decode(data.sublist(off, off + len), allowMalformed: true));
        off += len;
      }
      if (off + 4 > data.length) break;
      final type = (data[off] << 8) | data[off + 1];
      off += 4; // type + class
      final tname = switch (type) {
        typePTR => 'PTR',
        typeSRV => 'SRV',
        typeTXT => 'TXT',
        typeA => 'A',
        _ => 'Q$type',
      };
      out.add('$tname ${sb.toString()}');
    }
    return out;
  }
}
