import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

class CapturedRequest {
  final DateTime timestamp;
  final String method;
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
    } catch (e) {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, listenPort);
    }
    _server!.listen(_handle, onError: (e) {
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    await _requestsController.close();
  }

  bool get isRunning => _server != null;

  void clear() {
    _requests.clear();
  }

  Future<void> _handle(HttpRequest req) async {
    final start = DateTime.now();
    final captured = CapturedRequest(
      timestamp: start,
      method: req.method,
      path: req.uri.path + (req.uri.query.isEmpty ? '' : '?${req.uri.query}'),
      requestHeaders: _copyHeaders(req.headers),
      requestBodySize: req.contentLength,
    );
    _requests.add(captured);
    _requestsController.add(captured);

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
      final forward = await client.openUrl(req.method, targetUri).timeout(const Duration(seconds: 4));
      req.headers.forEach((name, values) {
        if (_hopByHopHeaders.contains(name.toLowerCase())) return;
        for (final v in values) {
          forward.headers.add(name, v);
        }
      });

      final reqTee = await _teeStream(req, forward);
      captured.requestBody = reqTee.body;
      captured.requestBodySize = reqTee.totalBytes > 0 ? reqTee.totalBytes : null;

      final response = await forward.close().timeout(const Duration(seconds: 4));
      captured.statusCode = response.statusCode;
      captured.responseHeaders = _copyHeaders(response.headers);

      req.response.statusCode = response.statusCode;
      response.headers.forEach((name, values) {
        if (_hopByHopHeaders.contains(name.toLowerCase())) return;
        for (final v in values) {
          req.response.headers.add(name, v);
        }
      });

      final respTee = await _teeStream(response, req.response);
      captured.responseBody = respTee.body;
      captured.responseBodySize = respTee.totalBytes > 0 ? respTee.totalBytes : null;
      captured.latencyMs = DateTime.now().difference(start).inMilliseconds;
      captured.completed = true;
      _requestsController.add(captured);
      await req.response.close();
    } on TimeoutException {
      captured.error = 'Upstream timeout (>4s)';
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
}
