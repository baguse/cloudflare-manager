import 'dart:async';
import 'dart:io';
import 'cloudflared_service.dart';

enum TunnelWatcherStatus {
  watching,
  reconnecting,
  crashLoop,
  lostNoToken,
}

class WatchedTunnel {
  final String tunnelId;
  int port;
  String? hostname;
  String? token;
  int? currentPid;
  int retryCount = 0;
  DateTime? lastRespawnAt;
  Duration nextBackoff = const Duration(seconds: 1);
  TunnelWatcherStatus status = TunnelWatcherStatus.watching;

  WatchedTunnel({
    required this.tunnelId,
    required this.port,
    this.hostname,
    this.token,
    this.currentPid,
  });
}

class WatcherEvent {
  final String tunnelId;
  final TunnelWatcherStatus status;
  final Process? newProcess;
  final int? newPid;
  final String? error;

  WatcherEvent({
    required this.tunnelId,
    required this.status,
    this.newProcess,
    this.newPid,
    this.error,
  });
}

class TunnelWatcher {
  static const int _maxRetries = 5;
  static const Duration _minBackoff = Duration(seconds: 1);
  static const Duration _maxBackoff = Duration(seconds: 30);
  static const Duration _checkInterval = Duration(seconds: 5);

  final Map<String, WatchedTunnel> _watched = {};
  final _events = StreamController<WatcherEvent>.broadcast();
  Timer? _timer;
  bool _enabled = true;

  Stream<WatcherEvent> get events => _events.stream;
  Map<String, WatchedTunnel> get watched => Map.unmodifiable(_watched);
  bool get isEnabled => _enabled;

  void setEnabled(bool value) {
    _enabled = value;
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(_checkInterval, (_) => _checkAll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void watch({
    required String tunnelId,
    required int port,
    String? hostname,
    String? token,
    int? currentPid,
  }) {
    final existing = _watched[tunnelId];
    if (existing != null) {
      existing.currentPid = currentPid ?? existing.currentPid;
      existing.token = token ?? existing.token;
      existing.hostname = hostname ?? existing.hostname;
      existing.port = port;
      existing.retryCount = 0;
      existing.lastRespawnAt = null;
      existing.nextBackoff = _minBackoff;
      existing.status = TunnelWatcherStatus.watching;
      return;
    }
    _watched[tunnelId] = WatchedTunnel(
      tunnelId: tunnelId,
      port: port,
      hostname: hostname,
      token: token,
      currentPid: currentPid,
    );
  }

  void unwatch(String tunnelId) {
    _watched.remove(tunnelId);
  }

  void updatePid(String tunnelId, int? pid) {
    final t = _watched[tunnelId];
    if (t != null) t.currentPid = pid;
  }

  Future<void> _checkAll() async {
    if (!_enabled) return;
    for (final t in _watched.values.toList()) {
      await _check(t);
    }
  }

  Future<void> _check(WatchedTunnel t) async {
    final alive = await _isAlive(t.currentPid);
    if (alive) {
      if (t.status == TunnelWatcherStatus.reconnecting || t.retryCount > 0) {
        t.retryCount = 0;
        t.nextBackoff = _minBackoff;
        t.lastRespawnAt = DateTime.now();
        if (t.status != TunnelWatcherStatus.watching) {
          t.status = TunnelWatcherStatus.watching;
          _events.add(WatcherEvent(tunnelId: t.tunnelId, status: t.status));
        }
      }
      return;
    }

    if (!_shouldRespawnNow(t)) return;

    if (t.token == null) {
      final credsExist = await CloudflaredService.credentialsFileExists(t.tunnelId);
      if (!credsExist) {
        if (t.status != TunnelWatcherStatus.lostNoToken) {
          t.status = TunnelWatcherStatus.lostNoToken;
          _events.add(WatcherEvent(tunnelId: t.tunnelId, status: t.status));
        }
        return;
      }
    }

    t.status = TunnelWatcherStatus.reconnecting;
    _events.add(WatcherEvent(tunnelId: t.tunnelId, status: t.status));

    try {
      final Process? process;
      if (t.token != null) {
        process = await CloudflaredService.startTokenTunnel(t.token!);
      } else {
        process = await CloudflaredService.startTunnelById(t.tunnelId);
      }
      if (process == null) throw Exception('startTunnelById returned null');
      t.currentPid = process.pid;
      t.retryCount = 0;
      t.nextBackoff = _minBackoff;
      t.lastRespawnAt = DateTime.now();
      t.status = TunnelWatcherStatus.watching;
      _events.add(WatcherEvent(
        tunnelId: t.tunnelId,
        status: t.status,
        newProcess: process,
        newPid: process.pid,
      ));
    } catch (e) {
      t.retryCount++;
      t.nextBackoff = Duration(
        seconds: (t.nextBackoff.inSeconds * 2).clamp(_minBackoff.inSeconds, _maxBackoff.inSeconds),
      );
      t.lastRespawnAt = DateTime.now();
      if (t.retryCount >= _maxRetries) {
        t.status = TunnelWatcherStatus.crashLoop;
      }
      _events.add(WatcherEvent(
        tunnelId: t.tunnelId,
        status: t.status,
        error: e.toString(),
      ));
    }
  }

  bool _shouldRespawnNow(WatchedTunnel t) {
    if (t.lastRespawnAt == null) return true;
    return DateTime.now().difference(t.lastRespawnAt!) >= t.nextBackoff;
  }

  Future<bool> _isAlive(int? pid) async {
    if (pid == null) return false;
    try {
      final result = await Process.run('kill', ['-0', '$pid']);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }
}
