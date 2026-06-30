import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'events.dart';
import '../cloudflared_service.dart';

enum TunnelRunState { idle, starting, running, crashed, stopped }

class TunnelRunner {
  final String tunnelId;
  final String? token;
  final String hostname;
  final int port;
  final void Function(DaemonEvent event) onEvent;
  final int maxRestarts;

  Process? _process;
  TunnelRunState _state = TunnelRunState.idle;
  final List<String> _logs = [];
  Timer? _healthTimer;
  Timer? _restartTimer;
  int _restartCount = 0;
  static const _baseDelay = Duration(seconds: 2);
  DateTime? _startedAt;

  TunnelRunner({
    required this.tunnelId,
    this.token,
    required this.hostname,
    required this.port,
    required this.onEvent,
    this.maxRestarts = 10,
  });

  TunnelRunState get state => _state;
  List<String> get logs => List.unmodifiable(_logs);
  DateTime? get startedAt => _startedAt;
  int get restartCount => _restartCount;
  int? get pid => _process?.pid;

  Future<void> start() async {
    if (_state == TunnelRunState.running) return;
    _state = TunnelRunState.starting;

    try {
      final cloudflared = await _findCloudflared();
      if (token != null) {
        await CloudflaredService.writeCredentialsFile(token!);
      }
      final args = ['tunnel', '--no-autoupdate', 'run', tunnelId];
      _process = await Process.start(cloudflared, args);

      _state = TunnelRunState.running;
      _startedAt = DateTime.now();
      _restartCount = 0;

      onEvent(DaemonEvent(
        type: DaemonEventType.tunnelStarted,
        tunnelId: tunnelId,
        hostname: hostname,
        port: port,
      ));

      _process!.stdout.transform(utf8.decoder).listen((data) {
        _addLog(data);
      });

      _process!.stderr.transform(utf8.decoder).listen((data) {
        _addLog(data);
      });

      _process!.exitCode.then((code) {
        if (_state == TunnelRunState.running) {
          _state = TunnelRunState.crashed;
          onEvent(DaemonEvent(
            type: DaemonEventType.tunnelCrashed,
            tunnelId: tunnelId,
            hostname: hostname,
            port: port,
            reason: 'exit code $code',
          ));
          _scheduleRestart();
        }
      });

      _startHealthCheck();
    } catch (e) {
      _state = TunnelRunState.crashed;
      onEvent(DaemonEvent(
        type: DaemonEventType.tunnelCrashed,
        tunnelId: tunnelId,
        hostname: hostname,
        port: port,
        error: e.toString(),
      ));
      _scheduleRestart();
    }
  }

  Future<void> stop() async {
    _state = TunnelRunState.stopped;
    _healthTimer?.cancel();
    _restartTimer?.cancel();
    _process?.kill(ProcessSignal.sigterm);
    await _process?.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process?.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    _process = null;
    onEvent(DaemonEvent(
      type: DaemonEventType.tunnelStopped,
      tunnelId: tunnelId,
      hostname: hostname,
      port: port,
      reason: 'manual stop',
    ));
  }

  void _scheduleRestart() {
    if (_restartCount >= maxRestarts) {
      _addLog('Max restarts ($maxRestarts) reached, giving up.');
      return;
    }
    final delay = _baseDelay * (1 << _restartCount.clamp(0, 5));
    _restartCount++;
    _addLog('Restarting in ${delay.inSeconds}s (attempt $_restartCount/$maxRestarts)...');
    _restartTimer?.cancel();
    _restartTimer = Timer(delay, () {
      if (_state == TunnelRunState.crashed) {
        onEvent(DaemonEvent(
          type: DaemonEventType.tunnelReconnected,
          tunnelId: tunnelId,
          hostname: hostname,
          port: port,
          reason: 'auto-restart attempt $_restartCount',
        ));
        start();
      }
    });
  }

  void _startHealthCheck() {
    _healthTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_process != null && _state == TunnelRunState.running) {
        try {
          Process.runSync('kill', ['-0', '${_process!.pid}']);
        } catch (_) {
          _state = TunnelRunState.crashed;
          onEvent(DaemonEvent(
            type: DaemonEventType.tunnelCrashed,
            tunnelId: tunnelId,
            hostname: hostname,
            port: port,
            reason: 'process disappeared',
          ));
          _scheduleRestart();
        }
      }
    });
  }

  void _addLog(String data) {
    final lines = data.split('\n').where((l) => l.trim().isNotEmpty);
    for (final line in lines) {
      _logs.add(line);
      if (_logs.length > 500) _logs.removeAt(0);
    }
  }

  static Future<String> _findCloudflared() async {
    const paths = [
      'cloudflared',
      '/usr/local/bin/cloudflared',
      '/opt/homebrew/bin/cloudflared',
      '/usr/bin/cloudflared',
    ];
    for (final p in paths) {
      try {
        final result = await Process.run(p, ['--version']);
        if (result.exitCode == 0) return p;
      } catch (_) {}
    }
    final home = Platform.environment['HOME'];
    if (home != null) {
      final h = '$home/.cloudflared/cloudflared';
      try {
        final result = await Process.run(h, ['--version']);
        if (result.exitCode == 0) return h;
      } catch (_) {}
    }
    return 'cloudflared';
  }

  Map<String, dynamic> toJson() => {
    'tunnelId': tunnelId,
    'hostname': hostname,
    'port': port,
    'state': _state.name,
    'restartCount': _restartCount,
    'startedAt': _startedAt?.toIso8601String(),
    'logCount': _logs.length,
    if (_process?.pid != null) 'pid': _process!.pid,
  };
}
