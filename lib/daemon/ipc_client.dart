import 'dart:async';
import 'dart:convert';
import 'dart:io';

class DaemonClient {
  Socket? _socket;
  final _eventsController = StreamController<Map<String, dynamic>>.broadcast();
  final _pending = <Completer<Map<String, dynamic>>>[];
  String _buffer = '';

  static const _socketName = 'cloudflare-manager.sock';

  Stream<Map<String, dynamic>> get events => _eventsController.stream;

  String get socketPath {
    final home = Platform.environment['HOME'] ?? '/tmp';
    return '$home/.cloudflared/$_socketName';
  }

  Future<bool> get isDaemonRunning async {
    return File(socketPath).exists();
  }

  Future<bool> connect() async {
    try {
      _socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      _socket!.listen(
        _onData,
        onDone: () {
          _socket = null;
          for (final c in _pending) {
            if (!c.isCompleted) c.complete({'ok': false, 'error': 'disconnected'});
          }
          _pending.clear();
        },
        onError: (_) {
          _socket = null;
        },
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  void disconnect() {
    _socket?.destroy();
    _socket = null;
  }

  Future<Map<String, dynamic>> send(String command, {Map<String, dynamic>? args}) async {
    if (_socket == null) {
      final connected = await connect();
      if (!connected) return {'ok': false, 'error': 'daemon not running'};
    }

    final completer = Completer<Map<String, dynamic>>();
    _pending.add(completer);

    final msg = {'command': command, ...?args};
    _socket!.add(utf8.encode(json.encode(msg) + '\n'));

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _pending.remove(completer);
        return {'ok': false, 'error': 'timeout'};
      },
    );
  }

  Future<Map<String, dynamic>> getStatus() => send('status');
  Future<Map<String, dynamic>> getTunnelList() => send('tunnel_list');
  Future<Map<String, dynamic>> getTunnelLogs(String tunnelId, {int limit = 50}) =>
      send('tunnel_logs', args: {'tunnelId': tunnelId, 'limit': limit});
  Future<Map<String, dynamic>> startTunnel(String tunnelId) =>
      send('tunnel_start', args: {'tunnelId': tunnelId});
  Future<Map<String, dynamic>> stopTunnel(String tunnelId) =>
      send('tunnel_stop', args: {'tunnelId': tunnelId});
  Future<Map<String, dynamic>> shutdown() => send('shutdown');
  Future<Map<String, dynamic>> reloadWebhooks() => send('reload_webhooks');
  Future<Map<String, dynamic>> bindTunnel(String tunnelId, String? token, String hostname, int port) =>
      send('tunnel_bind', args: {'tunnelId': tunnelId, 'token': token, 'hostname': hostname, 'port': port});
  Future<Map<String, dynamic>> unbindTunnel(String tunnelId) =>
      send('tunnel_unbind', args: {'tunnelId': tunnelId});

  void _onData(List<int> data) {
    _buffer += utf8.decode(data);
    final lines = _buffer.split('\n');
    _buffer = lines.removeLast();

    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final msg = json.decode(line.trim()) as Map<String, dynamic>;
        if (msg['type'] == 'event') {
          _eventsController.add(msg['event'] as Map<String, dynamic>);
        } else if (_pending.isNotEmpty) {
          _pending.removeAt(0).complete(msg);
        }
      } catch (_) {}
    }
  }
}
