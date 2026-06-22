import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'ipc_client.dart';
import 'cf_api_client.dart';

class HttpApiServer {
  final int port;
  final String apiKey;
  HttpServer? _server;

  HttpApiServer({this.port = 9845, required this.apiKey});

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    print('[api] HTTP API listening on http://0.0.0.0:$port');
    print('[api] Use header: Authorization: Bearer $apiKey');

    await for (final request in _server!) {
      _handleRequest(request);
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    print('[api] HTTP API stopped');
  }

  void _handleRequest(HttpRequest request) async {
    // CORS preflight
    if (request.method == 'OPTIONS') {
      _corsHeaders(request.response);
      request.response.statusCode = 204;
      request.response.close();
      return;
    }

    final path = request.uri.path;
    final method = request.method;

    // Strip /api prefix for routing
    final routePath = path.startsWith('/api/') ? path.substring(4) : path.startsWith('/api') ? '/' : path;

    // Serve web dashboard at /
    if (method == 'GET' && (routePath == '/' || routePath == '/index.html')) {
      _serveWebDashboard(request.response);
      return;
    }

    // Serve static files from web/dist
    if (method == 'GET' && (routePath.startsWith('/output.css') || routePath.startsWith('/angular/'))) {
      _serveStatic(request.response, routePath);
      return;
    }

    // Health check - no auth required
    if (method == 'GET' && routePath == '/health') {
      _handleHealth(request.response);
      return;
    }

    if (!_checkAuth(request)) {
      _jsonResponse(request.response, 401, {'error': 'Unauthorized. Use Authorization: Bearer <key>'});
      return;
    }

    try {
      switch ('$method $routePath') {
        case 'GET /status':
          await _handleStatus(request.response);
          break;
        case 'GET /tunnels':
          await _handleListTunnels(request.response);
          break;
        case 'POST /tunnels':
          await _handleBindTunnel(request);
          break;
        case _ when routePath.startsWith('/tunnels/') && method == 'DELETE':
          await _handleUnbindTunnel(routePath.split('/').last, request.response);
          break;
        case _ when routePath.startsWith('/logs/') && method == 'GET':
          await _handleTunnelLogs(routePath.split('/').last, request.uri.queryParameters['limit'], request.response);
          break;
        case 'POST /webhooks/reload':
          await _handleReloadWebhooks(request.response);
          break;
        case 'GET /zones':
          await _handleZones(request.response);
          break;
        case 'POST /bind':
          await _handleQuickBind(request);
          break;
        case 'POST /cf-config':
          await _handleCfConfig(request);
          break;
        case 'GET /cf-config':
          await _handleCfConfigStatus(request.response);
          break;
        default:
          _jsonResponse(request.response, 404, {'error': 'Not found', 'path': '$method $path'});
      }
    } catch (e) {
      _jsonResponse(request.response, 500, {'error': e.toString()});
    }
  }

  bool _checkAuth(HttpRequest request) {
    final auth = request.headers.value('Authorization');
    if (auth == null) return false;
    return auth == 'Bearer $apiKey';
  }

  void _handleHealth(HttpResponse response) {
    _jsonResponse(response, 200, {'ok': true, 'service': 'cloudflare-manager-api'});
  }

  Future<void> _handleStatus(HttpResponse response) async {
    final client = DaemonClient();
    try {
      if (!await client.connect()) {
        _jsonResponse(response, 503, {'ok': false, 'error': 'Daemon not running'});
        return;
      }
      final result = await client.getStatus();
      client.disconnect();
      if (result['ok'] == true) {
        _jsonResponse(response, 200, result);
      } else {
        _jsonResponse(response, 500, result);
      }
    } catch (e) {
      _jsonResponse(response, 503, {'ok': false, 'error': 'Daemon unreachable: $e'});
    }
  }

  Future<void> _handleListTunnels(HttpResponse response) async {
    final client = DaemonClient();
    try {
      if (!await client.connect()) {
        _jsonResponse(response, 503, {'ok': false, 'error': 'Daemon not running'});
        return;
      }
      final result = await client.getTunnelList();
      client.disconnect();
      _jsonResponse(response, result['ok'] == true ? 200 : 500, result);
    } catch (e) {
      _jsonResponse(response, 503, {'ok': false, 'error': 'Daemon unreachable: $e'});
    }
  }

  Future<void> _handleBindTunnel(HttpRequest request) async {
    final body = await utf8.decodeStream(request);
    final data = json.decode(body) as Map<String, dynamic>;
    final tunnelId = data['tunnelId'] as String?;
    final token = data['token'] as String?;
    final hostname = data['hostname'] as String? ?? '';
    final port = data['port'] as int?;

    if (tunnelId == null || token == null || port == null) {
      _jsonResponse(request.response, 400, {'ok': false, 'error': 'Missing required fields: tunnelId, token, port'});
      return;
    }

    final client = DaemonClient();
    try {
      if (!await client.connect()) {
        _jsonResponse(request.response, 503, {'ok': false, 'error': 'Daemon not running'});
        return;
      }
      final result = await client.bindTunnel(tunnelId, token, hostname, port);
      client.disconnect();
      _jsonResponse(request.response, result['ok'] == true ? 200 : 500, result);
    } catch (e) {
      _jsonResponse(request.response, 503, {'ok': false, 'error': 'Daemon unreachable: $e'});
    }
  }

  Future<void> _handleUnbindTunnel(String tunnelId, HttpResponse response) async {
    final client = DaemonClient();
    try {
      if (!await client.connect()) {
        _jsonResponse(response, 503, {'ok': false, 'error': 'Daemon not running'});
        return;
      }
      final result = await client.unbindTunnel(tunnelId);
      client.disconnect();
      _jsonResponse(response, result['ok'] == true ? 200 : 404, result);
    } catch (e) {
      _jsonResponse(response, 503, {'ok': false, 'error': 'Daemon unreachable: $e'});
    }
  }

  Future<void> _handleTunnelLogs(String tunnelId, String? limitStr, HttpResponse response) async {
    final limit = int.tryParse(limitStr ?? '50') ?? 50;
    final client = DaemonClient();
    try {
      if (!await client.connect()) {
        _jsonResponse(response, 503, {'ok': false, 'error': 'Daemon not running'});
        return;
      }
      final result = await client.getTunnelLogs(tunnelId, limit: limit);
      client.disconnect();
      _jsonResponse(response, result['ok'] == true ? 200 : 404, result);
    } catch (e) {
      _jsonResponse(response, 503, {'ok': false, 'error': 'Daemon unreachable: $e'});
    }
  }

  Future<void> _handleReloadWebhooks(HttpResponse response) async {
    final client = DaemonClient();
    try {
      if (!await client.connect()) {
        _jsonResponse(response, 503, {'ok': false, 'error': 'Daemon not running'});
        return;
      }
      final result = await client.reloadWebhooks();
      client.disconnect();
      _jsonResponse(response, result['ok'] == true ? 200 : 500, result);
    } catch (e) {
      _jsonResponse(response, 503, {'ok': false, 'error': 'Daemon unreachable: $e'});
    }
  }

  Future<void> _handleZones(HttpResponse response) async {
    final zones = await CfApiClient.getZones();
    final simplified = zones.map((z) => {'id': z['id'], 'name': z['name']}).toList();
    _jsonResponse(response, 200, {'ok': true, 'zones': simplified});
  }

  Future<void> _handleCfConfig(HttpRequest request) async {
    final body = await utf8.decodeStream(request);
    final data = json.decode(body) as Map<String, dynamic>;
    final token = data['token'] as String?;
    final accountId = data['accountId'] as String?;
    if (token == null || accountId == null) {
      _jsonResponse(request.response, 400, {'ok': false, 'error': 'token and accountId required'});
      return;
    }
    await CfApiClient.setToken(token);
    await CfApiClient.setAccountId(accountId);
    _jsonResponse(request.response, 200, {'ok': true});
  }

  Future<void> _handleCfConfigStatus(HttpResponse response) async {
    final token = await CfApiClient.getToken();
    _jsonResponse(response, 200, {'ok': true, 'configured': token != null && token.isNotEmpty});
  }

  Future<void> _handleQuickBind(HttpRequest request) async {
    final body = await utf8.decodeStream(request);
    final data = json.decode(body) as Map<String, dynamic>;
    final subdomain = data['subdomain'] as String?;
    final zoneId = data['zoneId'] as String?;
    final zoneName = data['zoneName'] as String?;
    final port = data['port'] as int?;

    if (subdomain == null || zoneId == null || port == null || zoneName == null) {
      _jsonResponse(request.response, 400, {'ok': false, 'error': 'subdomain, zoneId, zoneName, and port required'});
      return;
    }

    final token = await CfApiClient.getToken();
    final accountId = await CfApiClient.accountId();
    if (token == null || token.isEmpty || accountId == null) {
      _jsonResponse(request.response, 400, {'ok': false, 'error': 'Cloudflare API not configured. POST /cf-config first.'});
      return;
    }

    final hostname = '$subdomain.$zoneName';

    // 1. Create tunnel on Cloudflare
    final tunnelData = await CfApiClient.createTunnel('tunnel-$subdomain-$port');
    if (tunnelData == null) {
      _jsonResponse(request.response, 500, {'ok': false, 'error': 'Failed to create tunnel'});
      return;
    }
    final tunnelId = tunnelData['id'] as String;
    final tunnelToken = tunnelData['token'] as String?;
    if (tunnelId.isEmpty || tunnelToken == null) {
      _jsonResponse(request.response, 500, {'ok': false, 'error': 'Invalid tunnel response'});
      return;
    }

    // 2. Configure ingress
    final configured = await CfApiClient.configureTunnel(tunnelId, zoneId, hostname, port);
    if (!configured) {
      _jsonResponse(request.response, 500, {'ok': false, 'error': 'Failed to configure tunnel routing'});
      return;
    }

    // 3. Create DNS record
    final dnsOk = await CfApiClient.createDnsRecord(zoneId, hostname, tunnelId);
    if (!dnsOk) {
      _jsonResponse(request.response, 500, {'ok': false, 'error': 'Failed to create DNS record'});
      return;
    }

    // 4. Bind via daemon
    final client = DaemonClient();
    if (!await client.connect()) {
      _jsonResponse(request.response, 500, {'ok': false, 'error': 'Daemon not running — tunnel created but not bound'});
      return;
    }
    final bindResult = await client.bindTunnel(tunnelId, tunnelToken, hostname, port);
    client.disconnect();

    if (bindResult['ok'] == true) {
      _jsonResponse(request.response, 200, {
        'ok': true,
        'tunnelId': tunnelId,
        'hostname': hostname,
        'url': 'https://$hostname',
      });
    } else {
      _jsonResponse(request.response, 500, {'ok': false, 'error': 'Tunnel created on Cloudflare but daemon bind failed: ${bindResult['error']}'});
    }
  }

  void _jsonResponse(HttpResponse response, int status, Map<String, dynamic> data) {
    _corsHeaders(response);
    response.headers.contentType = ContentType.json;
    response.statusCode = status;
    response.write(json.encode(data));
    response.close();
  }

  String get _webDistDir {
    // Try current directory first (most reliable)
    final cwdPath = '${Directory.current.path}/web/dist';
    if (Directory(cwdPath).existsSync()) return cwdPath;

    // Fallback: relative to script location
    final scriptPath = Platform.script.toFilePath();
    final parent = scriptPath.substring(0, scriptPath.lastIndexOf('/'));
    if (parent.endsWith('/bin')) {
      return '$parent/../web/dist';
    }
    return '$parent/web/dist';
  }

  void _serveStatic(HttpResponse response, String path) {
    final webDir = _webDistDir;

    final file = File('$webDir$path');
    if (!file.existsSync()) {
      response.statusCode = 404;
      response.close();
      return;
    }

    final contentType = path.endsWith('.css')
        ? ContentType('text', 'css', charset: 'utf-8')
        : path.endsWith('.js')
            ? ContentType('application', 'javascript', charset: 'utf-8')
            : ContentType.binary;

    _corsHeaders(response);
    response.headers.contentType = contentType;
    response.statusCode = 200;
    response.write(file.readAsStringSync());
    response.close();
  }

  void _serveWebDashboard(HttpResponse response) {
    final webDir = _webDistDir;

    final file = File('$webDir/index.html');
    if (!file.existsSync()) {
      response.statusCode = 404;
      response.write('Web dashboard not built. Run: cd web && npm install && npm run build');
      response.close();
      return;
    }

    final html = file.readAsStringSync();
    response.headers.contentType = ContentType.html;
    response.statusCode = 200;
    response.write(html);
    response.close();
  }

  void _corsHeaders(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', 'Authorization, Content-Type');
  }
}
