import 'dart:async';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'events.dart';
import 'tunnel_runner.dart';

class CloudflareDaemon {
  final String configPath;
  final void Function(DaemonEvent event)? onEvent;
  final Map<String, TunnelRunner> _runners = {};
  final List<DaemonEvent> _eventLog = [];
  ServerSocket? _ipcServer;
  final List<Socket> _ipcClients = [];
  bool _running = false;
  final Completer<void> _shutdownCompleter = Completer<void>();

  static const _socketName = 'cloudflare-manager.sock';

  CloudflareDaemon({
    required this.configPath,
    this.onEvent,
  });

  bool get isRunning => _running;
  Map<String, TunnelRunner> get runners => Map.unmodifiable(_runners);
  List<DaemonEvent> get eventLog => List.unmodifiable(_eventLog);

  String get socketPath {
    final home = Platform.environment['HOME'] ?? '/tmp';
    return '$home/.cloudflared/$_socketName';
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;

    _emit(DaemonEvent(type: DaemonEventType.daemonStarted));

    await _loadTunnels();
    await _startIpcServer();

    print('[daemon] Started, managing ${_runners.length} tunnel(s)');
    print('[daemon] IPC socket: $socketPath');
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;

    _emit(DaemonEvent(type: DaemonEventType.daemonStopping));

    for (final runner in _runners.values) {
      await runner.stop();
    }
    _runners.clear();

    for (final client in _ipcClients) {
      await client.close();
    }
    _ipcClients.clear();

    await _ipcServer?.close();
    _ipcServer = null;

    final sockFile = File(socketPath);
    if (await sockFile.exists()) await sockFile.delete();

    if (!_shutdownCompleter.isCompleted) _shutdownCompleter.complete();
    print('[daemon] Stopped');
  }

  Future<void> waitForShutdown() => _shutdownCompleter.future;

  Future<void> _loadTunnels() async {
    final file = File(configPath);
    if (!await file.exists()) {
      print('[daemon] No config found at $configPath');
      return;
    }

    final data = json.decode(await file.readAsString());
    if (data is! Map) return;

    for (final entry in data.entries) {
      final tunnelId = entry.key;
      final cfg = entry.value;
      if (cfg is! Map) continue;
      if (cfg['serviceEnabled'] != true) continue;

      final token = cfg['token'] as String?;
      final port = cfg['port'] as int?;
      if (token == null || port == null) continue;

      final runner = TunnelRunner(
        tunnelId: tunnelId,
        token: token,
        hostname: cfg['hostname'] as String? ?? '',
        port: port,
        onEvent: _emit,
      );
      _runners[tunnelId] = runner;
      await runner.start();
    }
  }

  Future<void> _startIpcServer() async {
    final sockFile = File(socketPath);
    if (await sockFile.exists()) await sockFile.delete();
    await sockFile.parent.create(recursive: true);

    _ipcServer = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );

    _ipcServer!.listen((client) {
      _ipcClients.add(client);
      client.listen(
        (data) => _handleIpcMessage(client, utf8.decode(data)),
        onDone: () => _ipcClients.remove(client),
      );
    });
  }

  void _handleIpcMessage(Socket client, String message) {
    try {
      final msg = json.decode(message.trim()) as Map<String, dynamic>;
      final cmd = msg['command'] as String?;

      switch (cmd) {
        case 'status':
          _sendIpc(client, {
            'ok': true,
            'running': _running,
            'tunnels': _runners.values.map((r) => r.toJson()).toList(),
          });
          break;

        case 'tunnel_list':
          _sendIpc(client, {
            'ok': true,
            'tunnels': _runners.values.map((r) => r.toJson()).toList(),
          });
          break;

        case 'tunnel_logs':
          final id = msg['tunnelId'] as String?;
          final runner = id != null ? _runners[id] : null;
          if (runner != null) {
            final limit = msg['limit'] as int? ?? 50;
            final logs = runner.logs.reversed.take(limit).toList().reversed.toList();
            _sendIpc(client, {'ok': true, 'logs': logs});
          } else {
            _sendIpc(client, {'ok': false, 'error': 'tunnel not found'});
          }
          break;

        case 'tunnel_start':
          final id = msg['tunnelId'] as String?;
          final runner = id != null ? _runners[id] : null;
          if (runner != null) {
            runner.start();
            _sendIpc(client, {'ok': true});
          } else {
            _sendIpc(client, {'ok': false, 'error': 'tunnel not found'});
          }
          break;

        case 'tunnel_stop':
          final id = msg['tunnelId'] as String?;
          final runner = id != null ? _runners[id] : null;
          if (runner != null) {
            runner.stop().then((_) => _sendIpc(client, {'ok': true}));
          } else {
            _sendIpc(client, {'ok': false, 'error': 'tunnel not found'});
          }
          break;

        case 'events':
          final since = msg['since'] as String?;
          final sinceDate = since != null ? DateTime.tryParse(since) : null;
          final events = sinceDate != null
              ? _eventLog.where((e) => e.timestamp.isAfter(sinceDate)).toList()
              : _eventLog;
          _sendIpc(client, {
            'ok': true,
            'events': events.map((e) => e.toJson()).toList(),
          });
          break;

        case 'shutdown':
          _sendIpc(client, {'ok': true});
          stop();
          break;

        default:
          _sendIpc(client, {'ok': false, 'error': 'unknown command: $cmd'});
      }
    } catch (e) {
      _sendIpc(client, {'ok': false, 'error': e.toString()});
    }
  }

  void _sendIpc(Socket client, Map<String, dynamic> data) {
    client.add(utf8.encode(json.encode(data) + '\n'));
  }

  void _emit(DaemonEvent event) {
    _eventLog.add(event);
    if (_eventLog.length > 1000) _eventLog.removeAt(0);

    final line = event.toJsonLine();
    stdout.writeln('[event] $line');

    for (final client in _ipcClients) {
      _sendIpc(client, {'type': 'event', 'event': event.toJson()});
    }

    onEvent?.call(event);
  }
}
