import 'dart:convert';
import 'http_inspector.dart';

class HarExporter {
  static Map<String, dynamic> build(List<CapturedRequest> requests, {String? inspectorUrl}) {
    final entries = <Map<String, dynamic>>[];
    for (final r in requests) {
      if (r.method.isEmpty) continue;
      if (r.wsFrames != null) continue;
      entries.add(_entryToHar(r, inspectorUrl: inspectorUrl));
    }
    return {
      'log': {
        'version': '1.2',
        'creator': {
          'name': 'Cloudflare Manager',
          'version': '1.0.0',
        },
        'browser': {
          'name': 'Cloudflare Manager Inspector',
          'version': '1.0.0',
        },
        'pages': [],
        'entries': entries,
      },
    };
  }

  static Map<String, dynamic> _entryToHar(CapturedRequest r, {String? inspectorUrl}) {
    return {
      'startedDateTime': r.timestamp.toUtc().toIso8601String(),
      'time': r.latencyMs ?? -1,
      'request': _requestToHar(r, inspectorUrl: inspectorUrl),
      'response': _responseToHar(r),
      'cache': const {},
      'timings': {
        'send': 0,
        'wait': r.latencyMs ?? -1,
        'receive': 0,
        'blocked': -1,
        'dns': -1,
        'connect': -1,
        'ssl': -1,
      },
      '_inspectorError': r.error,
      '_inspectorTruncated': r.responseBody?.truncated == true || r.requestBody?.truncated == true,
      'serverIPAddress': '',
      'connection': '',
    };
  }

  static Map<String, dynamic> _requestToHar(CapturedRequest r, {String? inspectorUrl}) {
    final hostHeader = _firstHeader(r.requestHeaders, 'host') ?? 'inspector.local';
    final scheme = 'http';
    final url = inspectorUrl != null
        ? '$inspectorUrl${r.path}'
        : '$scheme://$hostHeader${r.path}';

    final queryString = <Map<String, String>>[];
    final queryIndex = url.indexOf('?');
    if (queryIndex >= 0) {
      final query = url.substring(queryIndex + 1);
      for (final pair in query.split('&')) {
        if (pair.isEmpty) continue;
        final eq = pair.indexOf('=');
        if (eq < 0) {
          queryString.add({'name': pair, 'value': ''});
        } else {
          queryString.add({'name': pair.substring(0, eq), 'value': pair.substring(eq + 1)});
        }
      }
    }

    final headers = _headersToHarList(r.requestHeaders);
    final postData = _postDataFromBody(r.requestBody, headers);

    return {
      'method': r.method,
      'url': url,
      'httpVersion': 'HTTP/1.1',
      'cookies': const [],
      'headers': headers,
      'queryString': queryString,
      'postData': postData,
      'headersSize': -1,
      'bodySize': r.requestBody?.totalBytes ?? 0,
    };
  }

  static Map<String, dynamic> _responseToHar(CapturedRequest r) {
    final headers = _headersToHarList(r.responseHeaders ?? const {});
    final statusText = _statusText(r.statusCode ?? 0);
    final content = _contentFromBody(r.responseBody, headers);

    return {
      'status': r.statusCode ?? 0,
      'statusText': statusText,
      'httpVersion': 'HTTP/1.1',
      'cookies': const [],
      'headers': headers,
      'content': content,
      'redirectURL': _firstHeader(r.responseHeaders ?? const {}, 'location') ?? '',
      'headersSize': -1,
      'bodySize': r.responseBody?.totalBytes ?? 0,
    };
  }

  static List<Map<String, String>> _headersToHarList(Map<String, List<String>> headers) {
    final out = <Map<String, String>>[];
    headers.forEach((name, values) {
      for (final v in values) {
        out.add({'name': name, 'value': v});
      }
    });
    return out;
  }

  static String? _firstHeader(Map<String, List<String>> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase() && entry.value.isNotEmpty) {
        return entry.value.first;
      }
    }
    return null;
  }

  static String _mimeFromHeaders(List<Map<String, String>> headers) {
    for (final h in headers) {
      if (h['name']?.toLowerCase() == 'content-type') {
        final v = h['value'] ?? '';
        return v.split(';').first.trim();
      }
    }
    return '';
  }

  static Map<String, dynamic>? _postDataFromBody(CapturedBody? body, List<Map<String, String>> requestHeaders) {
    if (body == null) return null;
    final mime = _mimeFromHeaders(requestHeaders);
    final isBinary = !_looksLikeText(body.bytes);
    if (isBinary) {
      return {
        'mimeType': mime,
        'text': base64Encode(body.bytes),
        'encoding': 'base64',
        '_truncated': body.truncated,
        '_totalBytes': body.totalBytes,
      };
    }
    return {
      'mimeType': mime,
      'text': body.text,
      '_truncated': body.truncated,
      '_totalBytes': body.totalBytes,
    };
  }

  static Map<String, dynamic> _contentFromBody(CapturedBody? body, List<Map<String, String>> responseHeaders) {
    if (body == null) {
      return {
        'size': 0,
        'mimeType': '',
        'text': '',
      };
    }
    final mime = _mimeFromHeaders(responseHeaders);
    final isBinary = !_looksLikeText(body.bytes);
    if (isBinary) {
      return {
        'size': body.totalBytes,
        'mimeType': mime,
        'text': base64Encode(body.bytes),
        'encoding': 'base64',
        '_truncated': body.truncated,
        '_capturedBytes': body.bytes.length,
      };
    }
    return {
      'size': body.totalBytes,
      'mimeType': mime,
      'text': body.text,
      '_truncated': body.truncated,
      '_capturedBytes': body.bytes.length,
    };
  }

  static bool _looksLikeText(List<int> bytes) {
    final sample = bytes.length > 256 ? bytes.sublist(0, 256) : bytes;
    for (final b in sample) {
      if (b == 0) return false;
    }
    try {
      utf8.decode(sample, allowMalformed: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _statusText(int code) {
    const map = {
      200: 'OK', 201: 'Created', 202: 'Accepted', 204: 'No Content',
      301: 'Moved Permanently', 302: 'Found', 304: 'Not Modified', 307: 'Temporary Redirect', 308: 'Permanent Redirect',
      400: 'Bad Request', 401: 'Unauthorized', 403: 'Forbidden', 404: 'Not Found', 405: 'Method Not Allowed', 429: 'Too Many Requests',
      500: 'Internal Server Error', 502: 'Bad Gateway', 503: 'Service Unavailable', 504: 'Gateway Timeout',
    };
    return map[code] ?? '';
  }
}
