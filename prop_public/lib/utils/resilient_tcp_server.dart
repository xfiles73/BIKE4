// Reimplementation for the public build: a resilient TCP server with
// dual-stack (IPv6+IPv4) listening, owner-based supersede on restart,
// port-fallback walking and single- or multi-client handling.
//
// Public surface is identical to the original so every caller in lib/
// (OpenBikeControl emulator, MyWhoosh link, DirCon/Rouvy emulators) works
// unchanged.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// One accepted probe marker: while an entry is pending, the next accepted
/// socket whose remote address+port match is dropped silently (it came from
/// our own liveness probe).
class _PendingProbe {
  final String address;
  final int sourcePort;
  final DateTime expires;

  _PendingProbe(this.address, this.sourcePort, this.expires);

  bool matches(InternetAddress addr, int port) {
    final remoteAddress = addr.address.toLowerCase();
    final expectedAddress = address.toLowerCase();
    final normalizedRemoteAddress = remoteAddress.startsWith('::ffff:')
        ? remoteAddress.substring('::ffff:'.length)
        : remoteAddress;
    return normalizedRemoteAddress == expectedAddress &&
        port == sourcePort &&
        DateTime.now().isBefore(expires);
  }

  bool get expired => DateTime.now().isAfter(expires);
}

class ResilientTcpServer {
  ResilientTcpServer({
    required this.preferredPort,
    this.portAttempts = 5,
    this.forceIPv4 = false,
    this.allowConcurrentClients = false,
    this.maxConcurrentClients = 8,
    this.label,
    this.owner,
    required this.onClientConnected,
    required this.onData,
    required this.onClientDisconnected,
    this.onClientLeft,
  }) : assert(portAttempts >= 1),
       assert(maxConcurrentClients >= 1);

  final int preferredPort;
  final int portAttempts;
  final bool forceIPv4;
  final bool allowConcurrentClients;
  final int maxConcurrentClients;
  final String? label;

  /// Whoever this server serves on behalf of — the emulator instance, or a
  /// stable key. Compared with `==`.
  final Object? owner;

  /// Every currently-running server, for the diagnostics block.
  static final List<ResilientTcpServer> activeServers = [];

  final void Function(Socket socket) onClientConnected;
  final void Function(Socket socket, List<int> data) onData;
  final void Function() onClientDisconnected;

  /// One client went away, while others may remain.
  final void Function(Socket socket)? onClientLeft;

  ServerSocket? _server;
  final List<Socket> _clients = [];
  final List<_PendingProbe> _probes = [];
  Completer<void>? _stoppedCompleter;

  InternetAddress get _bindAddress => forceIPv4 ? InternetAddress.anyIPv4 : InternetAddress.anyIPv6;

  bool get isRunning => _server != null;
  bool get hasClient => _clients.isNotEmpty;

  /// Most recent connected client (`null` when none). Kept as a getter over
  /// the list so single-client callers see the live socket after reconnects.
  Socket? get client => _clients.isEmpty ? null : _clients.last;

  List<Socket> get clients => List.unmodifiable(_clients);

  int get boundPort => _server?.port ?? preferredPort;

  /// Completes once the server has fully stopped (after [stop]).
  Future<void> get stopped => (_stoppedCompleter ??= Completer<void>()).future;

  /// Binds [preferredPort], walking to the next free port up to
  /// [portAttempts] times. Any previously registered server with the same
  /// [owner] is stopped first, so a restart rebinds the preferred port
  /// instead of walking past it.
  Future<void> start() async {
    // Supersede any still-registered server of ours (one whose stop is
    // closing, or one a previous start lost track of).
    for (final s in activeServers.where((s) => s != this && s.owner == owner && owner != null).toList()) {
      await s.stop();
    }

    Object? lastError;
    for (var attempt = 0; attempt < portAttempts; attempt++) {
      final port = preferredPort + attempt;
      try {
        final server = await ServerSocket.bind(
          _bindAddress,
          port,
          shared: false,
          v6Only: false, // Keep IPv4 clients working on the default IPv6 listener.
        );
        _server = server;
        activeServers.add(this);
        if (kDebugMode) {
          print('${label ?? 'TcpServer'} listening on port ${server.port}'
              '${attempt > 0 ? ' (fallback after $attempt)' : ''}');
        }
        server.listen(
          _accept,
          onError: (Object e, StackTrace st) {
            debugPrint('${label ?? 'TcpServer'} accept error: $e');
          },
          cancelOnError: false,
        );
        return;
      } on SocketException catch (e) {
        // Address already in use -> walk to the next port; anything else ->
        // fail loudly (fixed-port contracts like MyWhoosh rely on this).
        lastError = e;
        final osError = e.osError?.errorCode;
        final inUse = osError == 98 || osError == 10048; // EADDRINUSE / WSAEADDRINUSE
        if (!inUse) rethrow;
        if (attempt + 1 >= portAttempts) rethrow;
      }
    }
    throw lastError ?? SocketException('Failed to bind $preferredPort');
  }

  void _accept(Socket socket) {
    // Drop our own liveness probes silently.
    _probes.removeWhere((p) => p.expired);
    final probeIdx = _probes.indexWhere((p) => p.matches(socket.remoteAddress, socket.remotePort));
    if (probeIdx >= 0) {
      _probes.removeAt(probeIdx);
      socket.destroy();
      return;
    }

    if (!allowConcurrentClients) {
      // Supersede: a new client replaces the old one.
      for (final old in List.of(_clients)) {
        _detach(old, notifyDisconnect: true);
      }
    } else if (_clients.length >= maxConcurrentClients) {
      socket.destroy();
      return;
    }

    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}

    _clients.add(socket);
    socket.done.then((_) => _detach(socket, notifyDisconnect: !_clients.contains(socket)));
    socket.listen(
      (data) => onData(socket, data),
      onError: (Object e) {
        debugPrint('${label ?? 'TcpServer'} client error: $e');
        _detach(socket, notifyDisconnect: true);
      },
      cancelOnError: false,
    );

    try {
      onClientConnected(socket);
    } catch (e, st) {
      debugPrint('${label ?? 'TcpServer'} onClientConnected threw: $e\n$st');
    }
  }

  void _detach(Socket socket, {required bool notifyDisconnect}) {
    if (!_clients.remove(socket)) return;
    try {
      socket.destroy();
    } catch (_) {}
    if (notifyDisconnect) {
      if (allowConcurrentClients && _clients.isNotEmpty) {
        onClientLeft?.call(socket);
      } else {
        onClientDisconnected();
      }
    } else {
      onClientLeft?.call(socket);
    }
  }

  /// Announces that this process is about to open a throwaway TCP connection
  /// to its own server, so the next matching accepted socket is ignored.
  void expectProbe({
    required String address,
    required int sourcePort,
    Duration validity = const Duration(seconds: 5),
  }) {
    _probes.add(_PendingProbe(address, sourcePort, DateTime.now().add(validity)));
  }

  /// Disconnects the current client(s) but keeps the listener running.
  void dropClient() {
    for (final c in List.of(_clients)) {
      _detach(c, notifyDisconnect: true);
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    activeServers.remove(this);

    for (final c in List.of(_clients)) {
      _detach(c, notifyDisconnect: true);
    }

    if (server != null) {
      try {
        await server.close();
      } catch (e) {
        debugPrint('${label ?? 'TcpServer'} close error: $e');
      }
    }
    final completer = _stoppedCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
  }
}
