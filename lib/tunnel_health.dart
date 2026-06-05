import 'package:http/http.dart' as http;

class TunnelHealth {
  final String url;
  final bool isReachable;
  final int? statusCode;
  final int latencyMs;
  final DateTime checkedAt;
  final String? error;

  TunnelHealth({
    required this.url,
    required this.isReachable,
    this.statusCode,
    required this.latencyMs,
    required this.checkedAt,
    this.error,
  });

  bool get isSlow => isReachable && latencyMs >= 500;
}

class TunnelHealthChecker {
  static const Duration _timeout = Duration(seconds: 5);
  static const Set<int> _okStatuses = {200, 201, 202, 203, 204, 301, 302, 303, 304, 307, 308, 401, 403, 404, 405};

  static Future<TunnelHealth> check(String url) async {
    final stopwatch = Stopwatch()..start();
    try {
      final response = await http
          .get(Uri.parse(url), headers: const {'User-Agent': 'CloudflareManager/1.0'})
          .timeout(_timeout);
      stopwatch.stop();
      final reachable = _okStatuses.contains(response.statusCode);
      return TunnelHealth(
        url: url,
        isReachable: reachable,
        statusCode: response.statusCode,
        latencyMs: stopwatch.elapsedMilliseconds,
        checkedAt: DateTime.now(),
      );
    } catch (e) {
      stopwatch.stop();
      return TunnelHealth(
        url: url,
        isReachable: false,
        latencyMs: stopwatch.elapsedMilliseconds,
        checkedAt: DateTime.now(),
        error: e.toString(),
      );
    }
  }

  static Future<Map<String, TunnelHealth>> checkAll(List<String> urls) async {
    final unique = urls.toSet().toList();
    final results = await Future.wait(unique.map(check));
    return {for (final r in results) r.url: r};
  }
}
