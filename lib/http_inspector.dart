import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

class CapturedBody {
  final List<int> bytes;
  final bool truncated;
  final int totalBytes;
  String? _textCache;

  CapturedBody({required this.bytes, required this.truncated, required this.totalBytes});

  String get text {
    if (_textCache != null) return _textCache!;
    try {
      _textCache = utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      _textCache = '[binary ${bytes.length} bytes]';
    }
    return _textCache!;
  }
}

class CapturedWsFrame {
  final DateTime timestamp;
  final String direction;
  final int opcode;
  final String? text;
  final int size;

  CapturedWsFrame({
    required this.timestamp,
    required this.direction,
    required this.opcode,
    this.text,
    required this.size,
  });

  bool get isText => opcode == 0x1;
  bool get isBinary => opcode == 0x2;
}

class CapturedRequest {
  final DateTime timestamp;
  String method;
  final String path;
  final Map<String, List<String>> requestHeaders;
  int? requestBodySize;
  CapturedBody? requestBody;
  int? statusCode;
  Map<String, List<String>>? responseHeaders;
  int? responseBodySize;
  CapturedBody? responseBody;
  int? latencyMs;
  String? error;
  bool completed = false;
  List<CapturedWsFrame>? wsFrames;
  int? wsCloseCode;
  String? wsCloseReason;

  CapturedRequest({
    required this.timestamp,
    required this.method,
    required this.path,
    required this.requestHeaders,
    this.requestBodySize,
  });
}

class _TeeResult {
  final CapturedBody? body;
  final int totalBytes;
  _TeeResult(this.body, this.totalBytes);
}

class HttpInspector {
  static const int _maxBodyBytes = 64 * 1024;

  final int listenPort;
  final int targetPort;
  final List<CapturedRequest> _requests = [];
  final _requestsController = StreamController<CapturedRequest>.broadcast();

  HttpServer? _server;

  HttpInspector({required this.listenPort, required this.targetPort});

  List<CapturedRequest> get requests => List.unmodifiable(_requests);
  Stream<CapturedRequest> get onRequest => _requestsController.stream;

  Future<void> start() async {
    try {
      _server = await HttpServer.bind(
        InternetAddress.anyIPv6,
        listenPort,
        v6Only: false,
      );
    } catch (_) {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, listenPort);
      } catch (e) {
        throw Exception('Failed to bind to port $listenPort: $e');
      }
    }
    _server!.listen(_handle, onError: (e) {});
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    if (!_requestsController.isClosed) {
      await _requestsController.close();
    }
  }

  bool get isRunning => _server != null;

  void clear() {
    _requests.clear();
  }

  Future<void> _handle(HttpRequest req) async {
    final start = DateTime.now();
    final isWs = req.headers.value('upgrade')?.toLowerCase() == 'websocket' &&
        req.headers.value('sec-websocket-key') != null;

    final captured = CapturedRequest(
      timestamp: start,
      method: isWs ? 'WS' : req.method,
      path: req.uri.path + (req.uri.query.isEmpty ? '' : '?${req.uri.query}'),
      requestHeaders: _copyHeaders(req.headers),
      requestBodySize: req.contentLength,
    );
    _requests.add(captured);
    _requestsController.add(captured);

    if (isWs) {
      await _handleWebSocket(req, captured, start);
      return;
    }

    final client = HttpClient();
    client.autoUncompress = false;
    try {
      final targetUri = Uri(
        scheme: 'http',
        host: 'localhost',
        port: targetPort,
        path: req.uri.path,
        query: req.uri.query.isEmpty ? null : req.uri.query,
      );
      final forward = await client.openUrl(req.method, targetUri).timeout(const Duration(seconds: 10));
      req.headers.forEach((name, values) {
        if (_hopByHopHeaders.contains(name.toLowerCase())) return;
        for (final v in values) {
          forward.headers.add(name, v);
        }
      });

      final reqTee = await _teeStream(req, forward).timeout(const Duration(seconds: 15));
      captured.requestBody = reqTee.body;
      captured.requestBodySize = reqTee.totalBytes > 0 ? reqTee.totalBytes : null;

      final response = await forward.close().timeout(const Duration(seconds: 15));
      captured.statusCode = response.statusCode;
      captured.responseHeaders = _copyHeaders(response.headers);

      req.response.statusCode = response.statusCode;
      response.headers.forEach((name, values) {
        if (_hopByHopHeaders.contains(name.toLowerCase())) return;
        for (final v in values) {
          req.response.headers.add(name, v);
        }
      });

      final respTee = await _teeStream(response, req.response).timeout(const Duration(seconds: 15));
      captured.responseBody = respTee.body;
      captured.responseBodySize = respTee.totalBytes > 0 ? respTee.totalBytes : null;
      captured.latencyMs = DateTime.now().difference(start).inMilliseconds;
      captured.completed = true;
      _requestsController.add(captured);
      await req.response.close();
    } on TimeoutException {
      captured.error = 'Upstream timeout (>15s)';
      captured.statusCode = HttpStatus.gatewayTimeout;
      captured.latencyMs = DateTime.now().difference(start).inMilliseconds;
      captured.completed = true;
      _requestsController.add(captured);
      try {
        req.response.statusCode = HttpStatus.gatewayTimeout;
        req.response.write('Inspector: upstream timeout');
        await req.response.close();
      } catch (_) {}
    } catch (e) {
      captured.error = e.toString();
      captured.latencyMs = DateTime.now().difference(start).inMilliseconds;
      captured.completed = true;
      _requestsController.add(captured);
      try {
        req.response.statusCode = HttpStatus.badGateway;
        req.response.write('Inspector: upstream error: $e');
        await req.response.close();
      } catch (_) {}
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _handleWebSocket(HttpRequest req, CapturedRequest captured, DateTime start) async {
    final query = req.uri.query.isEmpty ? '' : '?${req.uri.query}';
    final uri = 'ws://localhost:$targetPort${req.uri.path}$query';

    WebSocket targetWs;
    try {
      targetWs = await WebSocket.connect(uri).timeout(const Duration(seconds: 15));
    } catch (e) {
      captured.error = 'WS target connect failed: $uri — $e';
      _failWs(captured, start, req);
      return;
    }

    WebSocket clientWs;
    try {
      final key = req.headers.value('sec-websocket-key')!;
      final accept = base64Encode(
        sha1.convert(utf8.encode('$key$_wsMagicGuid')).bytes,
      );

      req.response.statusCode = HttpStatus.switchingProtocols;
      req.response.headers.set('upgrade', 'websocket');
      req.response.headers.set('connection', 'Upgrade');
      req.response.headers.set('sec-websocket-accept', accept);

      final clientSocket = await req.response.detachSocket();
      clientWs = WebSocket.fromUpgradedSocket(clientSocket, serverSide: true);
    } catch (e) {
      captured.error = 'WS client upgrade failed: $e';
      try { await targetWs.close(); } catch (_) {}
      _failWs(captured, start, req);
      return;
    }

    captured.statusCode = 101;
    captured.wsFrames = [];
    captured.latencyMs = DateTime.now().difference(start).inMilliseconds;
    _requestsController.add(captured);

    try {
      await Future.wait([
        _relayWs(clientWs, targetWs, '\u2191 client\u2192server', captured),
        _relayWs(targetWs, clientWs, '\u2193 server\u2192client', captured),
      ]);
    } catch (e) {
      captured.error = 'WS relay error: $e';
    }

    captured.latencyMs = DateTime.now().difference(start).inMilliseconds;
    captured.completed = true;
    _requestsController.add(captured);
  }

  void _failWs(CapturedRequest captured, DateTime start, HttpRequest req) {
    captured.latencyMs = DateTime.now().difference(start).inMilliseconds;
    captured.completed = true;
    _requestsController.add(captured);
    try {
      req.response.statusCode = HttpStatus.badGateway;
      req.response.write('Inspector: ${captured.error}');
      req.response.close();
    } catch (_) {}
  }

  Future<void> _relayWs(WebSocket source, WebSocket dest, String direction, CapturedRequest captured) async {
    final sub = source.listen(
      (data) {
        final now = DateTime.now();
        if (data is String) {
          captured.wsFrames!.add(CapturedWsFrame(
            timestamp: now,
            direction: direction,
            opcode: 0x1,
            text: data,
            size: utf8.encode(data).length,
          ));
        } else if (data is List<int>) {
          captured.wsFrames!.add(CapturedWsFrame(
            timestamp: now,
            direction: direction,
            opcode: 0x2,
            size: data.length,
          ));
        }
        dest.add(data);
        _requestsController.add(captured);
      },
      onDone: () async {
        final closeCode = source.closeCode ?? 1005;
        final closeReason = source.closeReason;
        captured.wsCloseCode ??= closeCode;
        captured.wsCloseReason ??= closeReason;
        try {
          await dest.close(closeCode, closeReason);
        } catch (_) {}
      },
      onError: (e) {
        captured.error = 'WS relay error ($direction): $e';
        try { dest.close(1011, e.toString()); } catch (_) {}
        try { source.close(1011, e.toString()); } catch (_) {}
      },
    );

    try {
      await sub.asFuture();
    } catch (_) {}
  }

  Future<_TeeResult> _teeStream(Stream<List<int>> source, IOSink destination) async {
    final buffer = <int>[];
    int total = 0;
    bool truncated = false;
    await for (final chunk in source) {
      total += chunk.length;
      destination.add(chunk);
      if (buffer.length < _maxBodyBytes) {
        final remaining = _maxBodyBytes - buffer.length;
        if (chunk.length <= remaining) {
          buffer.addAll(chunk);
        } else {
          buffer.addAll(chunk.sublist(0, remaining));
          truncated = true;
        }
      } else {
        truncated = true;
      }
    }
    if (total == 0) return _TeeResult(null, 0);
    return _TeeResult(
      CapturedBody(bytes: buffer, truncated: truncated, totalBytes: total),
      total,
    );
  }

  Map<String, List<String>> _copyHeaders(HttpHeaders headers) {
    final result = <String, List<String>>{};
    headers.forEach((name, values) {
      result[name] = List.of(values);
    });
    return result;
  }

  static const Set<String> _hopByHopHeaders = {
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
    'host',
    'content-length',
  };

  static const String _wsMagicGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
}
