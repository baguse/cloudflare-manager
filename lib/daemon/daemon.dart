import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../api_key_gen.dart';
import 'events.dart';
import 'tunnel_runner.dart';
import '../webhook_service.dart';
import '../cloudflared_service.dart';
import '../cloudflare_service.dart';
import 'http_api.dart';
import '../app_storage.dart';

const _debugPrint = !bool.fromEnvironment('dart.vm.product');

void _log(String msg) {
  if (_debugPrint) print(msg);
}

class CloudflareDaemon {
  final String configPath;
  final void Function(DaemonEvent event)? onEvent;
  final Map<String, TunnelRunner> _runners = {};
  final List<DaemonEvent> _eventLog = [];
  ServerSocket? _ipcServer;
  final List<Socket> _ipcClients = [];
  bool _running = false;
  final Completer<void> _shutdownCompleter = Completer<void>();
  final Set<Future<void>> _pendingWebhooks = {};
  HttpApiServer? _apiServer;

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

  String get _daemonConfigPath {
    final home = Platform.environment['HOME'] ?? '/tmp';
    return '$home/.cloudflared/daemon.json';
  }

  int get maxStartRetries => _maxStartRetries;
  int _maxStartRetries = 10;
  int get bootDelaySeconds => _bootDelaySeconds;
  int _bootDelaySeconds = 3;

  Future<void> _loadDaemonConfig() async {
    final file = File(_daemonConfigPath);
    if (!await file.exists()) return;
    try {
      final data = json.decode(await file.readAsString());
      if (data is Map) {
        if (data['maxStartRetries'] is int) {
          _maxStartRetries = data['maxStartRetries'] as int;
        }
        if (data['bootDelaySeconds'] is int) {
          _bootDelaySeconds = data['bootDelaySeconds'] as int;
        }
      }
    } catch (e) {
      _log('[daemon] Error reading daemon config: $e');
    }
  }

  Future<void> saveDaemonConfig({int? maxStartRetries, int? bootDelaySeconds}) async {
    final file = File(_daemonConfigPath);
    var data = <String, dynamic>{};
    try {
      if (await file.exists()) {
        data = json.decode(await file.readAsString()) as Map<String, dynamic>;
      }
    } catch (_) {}
    if (maxStartRetries != null) {
      data['maxStartRetries'] = maxStartRetries;
      _maxStartRetries = maxStartRetries;
    }
    if (bootDelaySeconds != null) {
      data['bootDelaySeconds'] = bootDelaySeconds;
      _bootDelaySeconds = bootDelaySeconds;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(json.encode(data));
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;

    await WebhookService.instance.loadWebhooks();
    await _loadDaemonConfig();
    _emit(DaemonEvent(type: DaemonEventType.daemonStarted));

    await _startIpcServer();
    await _loadTunnels();
    await _startApiIfEnabled();

    _log('[daemon] Started, managing ${_runners.length} tunnel(s), max retries=$_maxStartRetries');
    _log('[daemon] IPC socket: $socketPath]');
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;

    _emit(DaemonEvent(type: DaemonEventType.daemonStopping));

    for (final runner in _runners.values) {
      await runner.stop();
    }
    _runners.clear();

    await _flushWebhooks();
    await _apiServer?.stop();
    _apiServer = null;

    for (final client in _ipcClients) {
      await client.close();
    }
    _ipcClients.clear();

    await _ipcServer?.close();
    _ipcServer = null;

    final sockFile = File(socketPath);
    if (await sockFile.exists()) await sockFile.delete();

    if (!_shutdownCompleter.isCompleted) _shutdownCompleter.complete();
    _log('[daemon] Stopped');
  }

  Future<void> waitForShutdown() => _shutdownCompleter.future;

  Future<void> _loadTunnels() async {
    final file = File(configPath);
    if (!await file.exists()) {
      _log('[daemon] No config found at $configPath');
      return;
    }

    final data = json.decode(await file.readAsString());
    if (data is! Map) return;

    if (_bootDelaySeconds > 0) {
      _log('[daemon] Waiting ${_bootDelaySeconds}s for network...');
      await Future.delayed(Duration(seconds: _bootDelaySeconds));
    }

    for (final entry in data.entries) {
      final tunnelId = entry.key;
      final cfg = entry.value;
      if (cfg is! Map) continue;
      if (cfg['serviceEnabled'] != true) continue;

      final token = cfg['token'] as String?;
      final port = cfg['port'] as int?;
      final hostname = cfg['hostname'] as String? ?? '';
      if (port == null) continue;

      final hasCreds = await CloudflaredService.credentialsFileExists(tunnelId);
      if (token == null && !hasCreds) continue;

      final runner = TunnelRunner(
        tunnelId: tunnelId,
        token: token,
        hostname: hostname,
        port: port,
        onEvent: _emit,
        maxRestarts: _maxStartRetries,
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

    try {
      final s = await sockFile.stat();
      if ((s.mode & 0xFFF) != 384) {
        await Process.run('chmod', ['600', socketPath]);
      }
    } catch (_) {}

    _ipcServer!.listen((client) {
      _ipcClients.add(client);
      client.listen(
        (data) => _handleIpcMessage(client, utf8.decode(data)),
        onDone: () => _ipcClients.remove(client),
      );
    });
  }

  Future<void> _startApiIfEnabled() async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final keyFile = File('$home/.cloudflared/api-key');
    String? apiKey;
    if (await keyFile.exists()) {
      apiKey = (await keyFile.readAsString()).trim();
    }
    if (apiKey == null || apiKey.isEmpty) {
      // First run: generate key, start in setup mode
      apiKey = generateApiKey();
      await keyFile.parent.create(recursive: true);
      await keyFile.writeAsString(apiKey);
    }
    final portStr = await AppStorage.instance.read(key: 'api_port');
    final port = int.tryParse(portStr ?? '9845') ?? 9845;
    try {
      _apiServer = HttpApiServer(port: port, apiKey: apiKey,
        onGetStatusDirect: () async {
          final notesMap = await CloudflaredService.readAllTunnelNotes();
          return {
            'ok': true,
            'running': _running,
            'tunnels': _runners.values.map((runner) {
              final j = runner.toJson();
              final n = notesMap[runner.tunnelId];
              if (n?.notes != null) j['notes'] = n!.notes;
              if (n?.tags != null) j['tags'] = n!.tags;
              j['serviceEnabled'] = n?.serviceEnabled == true;
              return j;
            }).toList(),
            'eventCount': _eventLog.length,
          };
        },
        onIpcCall: (String cmd, Map<String, dynamic>? args) async {
          switch (cmd) {
            case 'status':
              final notesMap = await CloudflaredService.readAllTunnelNotes();
              return {
                'ok': true, 'running': _running,
                'tunnels': _runners.values.map((runner) {
                  final j = runner.toJson();
                  final n = notesMap[runner.tunnelId];
                  if (n?.notes != null) j['notes'] = n!.notes;
                  if (n?.tags != null) j['tags'] = n!.tags;
                  j['serviceEnabled'] = n?.serviceEnabled == true;
                  return j;
                }).toList(),
                'eventCount': _eventLog.length,
              };
            case 'tunnel_bind':
              final id = args?['tunnelId'] as String?;
              final token = args?['token'] as String?;
              final hostname = args?['hostname'] as String? ?? '';
              final port = args?['port'] as int?;
              if (id == null || port == null) {
                return {'ok': false, 'error': 'Missing tunnelId or port'};
              }
              if (_runners.containsKey(id)) { await _runners[id]!.stop(); }
              final runner = TunnelRunner(tunnelId: id, token: token, hostname: hostname, port: port, onEvent: _emit, maxRestarts: _maxStartRetries);
              _runners[id] = runner;
              await runner.start();
              return {'ok': true, 'pid': runner.pid};
            case 'tunnel_list':
              return {'ok': true, 'tunnels': _runners.values.map((r) => r.toJson()).toList()};
            case 'tunnel_logs':
              final id = args?['tunnelId'] as String?;
              final limit = args?['limit'] as int? ?? 50;
              final runner = id != null ? _runners[id] : null;
              if (runner != null) {
                return {'ok': true, 'logs': runner.logs.reversed.take(limit).toList().reversed.toList()};
              }
              return {'ok': false, 'error': 'tunnel not found'};
            case 'tunnel_start':
              final id = args?['tunnelId'] as String?;
              if (id != null && _runners.containsKey(id)) {
                try { await _runners[id]!.start(); return {'ok': true}; } catch (e) { return {'ok': false, 'error': e.toString()}; }
              }
              return {'ok': false, 'error': 'tunnel not found'};
            case 'tunnel_stop':
              final id = args?['tunnelId'] as String?;
              if (id != null && _runners.containsKey(id)) {
                await _runners[id]!.stop(); return {'ok': true};
              }
              return {'ok': false, 'error': 'tunnel not found'};
            case 'tunnel_unbind':
              final id = args?['tunnelId'] as String?;
              if (id == null) return {'ok': false, 'error': 'Missing tunnelId'};
              if (_runners.containsKey(id)) {
                await _runners[id]!.stop(); _runners.remove(id); return {'ok': true};
              }
              return {'ok': false, 'error': 'Tunnel not found'};
            case 'shutdown':
              await stop();
              return {'ok': true};
            case 'reload_webhooks':
              await WebhookService.instance.loadWebhooks();
              return {'ok': true, 'count': WebhookService.instance.webhooks.length};
            default:
              return {'ok': false, 'error': 'unknown command: $cmd'};
          }
        },
      );
      final token = await AppStorage.instance.read(key: CloudflareService.tokenKey);
      final accountId = await AppStorage.instance.read(key: CloudflareService.accountIdKey);
      if (token == null || token.isEmpty || accountId == null || accountId.isEmpty) {
        _apiServer!.setupMode = true;
        _log('[daemon] API in setup mode — visit http://0.0.0.0:$port to configure');
      }
      await _apiServer!.start();
      _log('[daemon] HTTP API started on port $port');
    } catch (e) {
      _log('[daemon] Failed to start HTTP API: $e');
    }
  }

  Future<void> _handleIpcMessage(Socket client, String message) async {
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

        case 'tunnel_bind':
          final id = msg['tunnelId'] as String?;
          final token = msg['token'] as String?;
          final hostname = msg['hostname'] as String? ?? '';
          final port = msg['port'] as int?;
          if (id == null || port == null) {
            _sendIpc(client, {'ok': false, 'error': 'Missing tunnelId or port'});
            break;
          }
          if (_runners.containsKey(id)) {
            await _runners[id]!.stop();
          }
          final runner = TunnelRunner(
            tunnelId: id,
            token: token,
            hostname: hostname,
            port: port,
            onEvent: _emit,
            maxRestarts: _maxStartRetries,
          );
          _runners[id] = runner;
          await runner.start();
          _sendIpc(client, {'ok': true, 'pid': runner.pid});
          break;

        case 'tunnel_unbind':
          final id = msg['tunnelId'] as String?;
          if (id == null) {
            _sendIpc(client, {'ok': false, 'error': 'Missing tunnelId'});
            break;
          }
          final r = _runners[id];
          if (r != null) {
            await r.stop();
            _runners.remove(id);
            _sendIpc(client, {'ok': true});
          } else {
            _sendIpc(client, {'ok': false, 'error': 'Tunnel not found'});
          }
          break;

        case 'tunnel_start':
          final id = msg['tunnelId'] as String?;
          final runner = id != null ? _runners[id] : null;
          if (runner != null) {
            try {
              await runner.start();
              _sendIpc(client, {'ok': true});
            } catch (e) {
              _sendIpc(client, {'ok': false, 'error': e.toString()});
            }
          } else {
            _sendIpc(client, {'ok': false, 'error': 'tunnel not found'});
          }
          break;

        case 'tunnel_stop':
          final id = msg['tunnelId'] as String?;
          final runner = id != null ? _runners[id] : null;
          if (runner != null) {
            await runner.stop();
            _sendIpc(client, {'ok': true});
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
          stop().catchError((e) => _log('[daemon] Stop error: $e'));
          break;

        case 'reload_webhooks':
          WebhookService.instance.loadWebhooks().then((_) {
            _sendIpc(client, {'ok': true, 'count': WebhookService.instance.webhooks.length});
          }).catchError((e) {
            _sendIpc(client, {'ok': false, 'error': e.toString()});
          });
          break;

        case 'api_restart':
          _apiServer?.stop();
          _apiServer = null;
          await _startApiIfEnabled();
          _sendIpc(client, {'ok': true, 'running': _apiServer != null});
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
    _apiServer?.broadcastEvent(event);
    
    final future = WebhookService.instance.triggerWebhooks(event).catchError((e) {
      _log('[daemon] Webhook trigger error: $e');
    });
    _pendingWebhooks.add(future);
    future.whenComplete(() => _pendingWebhooks.remove(future));
  }

  Future<void> _flushWebhooks({Duration timeout = const Duration(seconds: 10)}) async {
    if (_pendingWebhooks.isEmpty) return;
    try {
      await Future.wait(_pendingWebhooks.toList()).timeout(timeout);
    } catch (_) {
      _log('[daemon] Webhook flush timed out');
    }
  }
}
