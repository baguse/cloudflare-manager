import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'ipc_client.dart';
import 'cf_api_client.dart';
import 'events.dart';
import '../cloudflare_service.dart';
import '../webhook_service.dart';
import '../webhook_config.dart';
import '../rate_alert_service.dart';
import '../rate_alert.dart';
import '../cloudflared_service.dart';
import '../tunnel_operations.dart';
import '../auto_backup.dart';
import '../app_storage.dart';

class HttpApiServer {
  final int port;
  final String _hash;
  final String _prefix;
  final String _apiKey;
  HttpServer? _server;
  bool setupMode = false;
  Future<Map<String, dynamic>> Function()? onGetStatusDirect;
  Future<Map<String, dynamic>> Function(String cmd, Map<String, dynamic>? args)? onIpcCall;
  void Function(DaemonEvent event)? onDaemonEvent;
  final List<WebSocket> _wsClients = [];

  static String hashKey(String key) {
    return sha256.convert(utf8.encode(key)).toString();
  }

  HttpApiServer({this.port = 9845, required String apiKey, this.onGetStatusDirect, this.onIpcCall, this.onDaemonEvent})
    : _apiKey = apiKey,
      _hash = hashKey(apiKey),
      _prefix = apiKey.substring(0, 4);

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    print('[api] HTTP API listening on http://0.0.0.0:$port');
    print('[api] Auth key prefix: $_prefix...');
    await WebhookService.instance.loadWebhooks();
    await RateAlertService.instance.loadAlerts();

    await for (final request in _server!) {
      _handleRequest(request);
    }
  }

  Future<void> stop() async {
    for (final ws in _wsClients) { try { ws.close(); } catch (_) {} }
    _wsClients.clear();
    await _server?.close(force: true);
    _server = null;
    print('[api] HTTP API stopped');
  }

  void broadcastEvent(DaemonEvent event) {
    final json = jsonEncode(event.toJson());
    final dead = <WebSocket>[];
    for (final ws in _wsClients) {
      try { ws.add(json); } catch (_) { dead.add(ws); }
    }
    _wsClients.removeWhere((w) => dead.contains(w));
  }

  Future<void> _handleWebSocket(HttpRequest request) async {
    final auth = request.headers.value('Authorization');
    final token = request.uri.queryParameters['token'];
    final key = auth?.startsWith('Bearer ') == true ? auth!.substring(7) : token;
    if (key == null || hashKey(key) != _hash) {
      _jsonResponse(request.response, 401, {'error': 'Unauthorized'});
      return;
    }
    final ws = await WebSocketTransformer.upgrade(request);
    _wsClients.add(ws);
    ws.listen(
      (_) {},
      onDone: () => _wsClients.remove(ws),
      onError: (_) => _wsClients.remove(ws),
      cancelOnError: true,
    );
  }

  Future<Map<String, dynamic>> _ipc(String cmd, {Map<String, dynamic>? args}) async {
    if (onIpcCall != null) return await onIpcCall!(cmd, args);
    final client = DaemonClient();
    if (!await client.connect()) return {'ok': false, 'error': 'Daemon not running'};
    final result = await client.send(cmd, args: args);
    client.disconnect();
    return result;
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

    // Setup mode: only serve setup page (no auth, no dashboard)
    if (setupMode) {
      if (method == 'GET' && (routePath == '/' || routePath == '/index.html')) {
        _serveSetupPage(request.response);
        return;
      }
      if (method == 'POST' && routePath == '/setup') {
        await _handleSetup(request);
        return;
      }
      if (method == 'GET' && !path.startsWith('/api/') && path != '/api') {
        if (await _serveStatic(request.response, routePath)) return;
      }
      if (method == 'GET' && routePath == '/health') { _handleHealth(request.response); return; }
      if (method == 'GET' && routePath == '/status') { await _handleStatus(request.response); return; }
      _jsonResponse(request.response, 404, {'error': 'Available only in normal mode'});
      return;
    }

    // Serve web dashboard at /
    if (method == 'GET' && (routePath == '/' || routePath == '/index.html')) {
      await _serveWebDashboard(request.response);
      return;
    }

    // Serve static files + SPA fallback (only for non-API paths)
    if (method == 'GET' && !path.startsWith('/api/') && path != '/api') {
      if (await _serveStatic(request.response, routePath)) return;
      await _serveWebDashboard(request.response);
      return;
    }

    // Swagger / OpenAPI docs - no auth required
    if (method == 'GET' && routePath == '/docs') {
      _serveSwaggerUi(request.response);
      return;
    }
    if (method == 'GET' && routePath == '/openapi.json') {
      _serveOpenApiSpec(request.response);
      return;
    }

    // Health check - no auth required
    if (method == 'GET' && routePath == '/health') {
      _handleHealth(request.response);
      return;
    }

    // WebSocket for real-time daemon events
    if (method == 'GET' && routePath == '/ws') {
      await _handleWebSocket(request);
      return;
    }

    if (!_checkAuth(request)) {
      _jsonResponse(request.response, 401, {'error': 'Unauthorized. Use Authorization: Bearer <key>'});
      return;
    }

      try {
      // Parse path segments: /dns/zones/:zoneId/records, etc.
      final segments = routePath.split('/').where((s) => s.isNotEmpty).toList();

      switch ('$method $routePath') {
        case 'GET /status':
          await _handleStatus(request.response);
          break;
        case 'GET /tunnels/all':
          await _handleListAllTunnels(request.response);
          break;
        case 'GET /tunnels':
          await _handleListTunnels(request.response);
          break;
        case _ when routePath.startsWith('/tunnels/') && method == 'DELETE':
          await _handleUnbindTunnel(segments[1], request.response);
          break;
        case _ when routePath.startsWith('/tunnels/') && routePath.endsWith('/notes') && method == 'PUT':
          await _handleSaveTunnelNotes(segments[1], request);
          break;
        case _ when routePath.startsWith('/tunnels/') && routePath.endsWith('/service') && method == 'PUT':
          await _handleToggleService(segments[1], request);
          break;
        case _ when routePath.startsWith('/tunnels/') && routePath.endsWith('/bind') && method == 'POST':
          await _handleBindExisting(segments[1], request);
          break;
        case _ when routePath.startsWith('/tunnels/') && routePath.endsWith('/delete') && method == 'POST':
          await _handleDeleteTunnel(segments[1], request.response);
          break;
        case _ when routePath.startsWith('/logs/') && method == 'GET':
          await _handleTunnelLogs(segments[1], request.uri.queryParameters['limit'], request.response);
          break;
        case 'POST /webhooks/reload':
          await _handleReloadWebhooks(request.response);
          break;
        case 'GET /webhooks':
          await _handleListWebhooks(request.response);
          break;
        case 'POST /webhooks':
          await _handleCreateWebhook(request);
          break;
        case _ when routePath.startsWith('/webhooks/') && method == 'PUT':
          await _handleUpdateWebhook(segments[1], request);
          break;
        case _ when routePath.startsWith('/webhooks/') && method == 'DELETE':
          await _handleDeleteWebhook(segments[1], request.response);
          break;
        case _ when routePath.startsWith('/webhooks/') && routePath.endsWith('/test') && method == 'POST':
          await _handleTestWebhook(segments[1], request.response);
          break;
        case 'GET /webhook-logs':
          await _handleWebhookLogs(request.response);
          break;
        case 'GET /zones':
          await _handleZones(request.response);
          break;
        case 'GET /dns':
          await _handleListDns(request);
          break;
        case 'POST /dns':
          await _handleCreateDns(request);
          break;
        case _ when routePath.startsWith('/dns/') && method == 'PUT':
          await _handleUpdateDns(request);
          break;
        case _ when routePath.startsWith('/dns/') && method == 'DELETE':
        case _ when routePath == '/dns' && method == 'DELETE':
          await _handleDeleteDns(request);
          break;
        case 'GET /rate-alerts':
          await _handleListRateAlerts(request.response);
          break;
        case 'POST /rate-alerts':
          await _handleCreateRateAlert(request);
          break;
        case _ when routePath.startsWith('/rate-alerts/') && method == 'DELETE':
          await _handleDeleteRateAlert(segments[1], request.response);
          break;
        case _ when routePath.startsWith('/rate-alerts/') && method == 'PUT':
          await _handleUpdateRateAlert(segments[1], request);
          break;
        case 'POST /rate-alerts/check':
          await _handleCheckRateAlerts(request.response);
          break;
        case 'POST /backup':
          if (request.headers.contentType?.mimeType == 'application/json') {
            await _handleCreateBackupWithOptions(request);
          } else {
            await _handleCreateBackup(request.response);
          }
          break;
        case 'GET /backups':
          await _handleListBackups(request.response);
          break;
        case 'GET /backup':
          await _handleFetchBackup(request);
          break;
        case 'DELETE /backup':
          await _handleDeleteBackup(request);
          break;
        case 'POST /restore':
          await _handleRestore(request);
          break;
        case 'POST /backup/decrypt':
          await _handleDecryptBackup(request);
          break;
        case 'POST /daemon/start':
          await _handleDaemonStart(request.response);
          break;
        case 'POST /daemon/stop':
          await _handleDaemonStop(request.response);
          break;
        case 'GET /settings':
          await _handleGetSettings(request.response);
          break;
        case 'PATCH /settings':
          await _handlePatchSettings(request);
          break;
        case 'GET /export':
          await _handleExport(request);
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
    final key = auth.startsWith('Bearer ') ? auth.substring(7) : auth;
    return hashKey(key) == _hash;
  }

  /// Parse JSON body, returning null + 400 response on failure.
  Future<Map<String, dynamic>?> _parseBody(HttpRequest request) async {
    try {
      final body = await utf8.decodeStream(request);
      return json.decode(body);
    } catch (_) {
      _jsonResponse(request.response, 400, {'ok': false, 'error': 'Invalid JSON body'});
      return null;
    }
  }

  void _handleHealth(HttpResponse response) {
    _jsonResponse(response, 200, {'ok': true, 'service': 'cloudflare-manager-api'});
  }

  Future<void> _handleStatus(HttpResponse response) async {
    if (onGetStatusDirect != null) {
      _jsonResponse(response, 200, await onGetStatusDirect!());
      return;
    }
    final result = await _ipc('status');
    if (result['ok'] == true) {
      _jsonResponse(response, 200, result);
    } else {
      _jsonResponse(response, 200, {'ok': true, 'running': false, 'tunnels': const [], 'eventCount': 0});
    }
  }

  String get _socketPath {
    final home = Platform.environment['HOME'] ?? '/tmp';
    return '$home/.cloudflared/cloudflare-manager.sock';
  }

  Future<void> _handleListAllTunnels(HttpResponse response) async {
    final daemonResult = await _ipc('tunnel_list');
    final daemonTunnels = (daemonResult['tunnels'] as List?)?.cast<Map<String,dynamic>>() ?? [];
    final cfConfigs = await CloudflareService.fetchAllTunnelConfigs();
    final cfTunnels = await CloudflareService.listTunnels();

    final all = <Map<String,dynamic>>[];
    final seen = <String>{};
    for (final d in daemonTunnels) {
      final id = d['tunnelId'] as String? ?? '';
      seen.add(id);
      all.add({...d, 'source': 'daemon'});
    }
    for (final t in cfTunnels) {
      final id = t['id'] as String? ?? '';
      if (seen.contains(id)) continue;
      final cfg = cfConfigs[id] ?? <String,String>{};
      all.add({
        'tunnelId': id,
        'name': t['name'] ?? '',
        'hostname': cfg['hostname'] ?? '',
        'port': 0,
        'state': 'inactive',
        'source': 'cloudflare',
        'status': t['status'] ?? 'inactive',
        'service': cfg['service'] ?? '',
      });
    }

    await CloudflaredService.mergeTunnelNotes(all);
    _jsonResponse(response, 200, {'ok': true, 'tunnels': all, 'daemonRunning': onIpcCall != null || File(_socketPath).existsSync()});
  }

  Future<void> _handleListTunnels(HttpResponse response) async {
    final result = await _ipc('tunnel_list');
    _jsonResponse(response, result['ok'] == true ? 200 : 500, result);
  }

  Future<void> _handleBindExisting(String tunnelId, HttpRequest request) async {
    final body = await utf8.decodeStream(request);
    Map<String, dynamic> data;
    try { data = json.decode(body); } catch (_) {
      _jsonResponse(request.response, 400, {'ok': false, 'error': 'Invalid JSON body'});
      return;
    }
    final result = await TunnelOperations.rebind(
      tunnelId: tunnelId,
      port: data['port'] as int?,
      hostname: data['hostname'] as String?,
      ipc: _ipc,
    );
    _jsonResponse(request.response, result['ok'] == true ? 200 : 500, result);
  }

  Future<void> _handleUnbindTunnel(String tunnelId, HttpResponse response) async {
    final result = await TunnelOperations.unbind(tunnelId: tunnelId, ipc: _ipc);
    _jsonResponse(response, result['ok'] == true ? 200 : 404, result);
  }

  Future<void> _handleTunnelLogs(String tunnelId, String? limitStr, HttpResponse response) async {
    final limit = int.tryParse(limitStr ?? '50') ?? 50;
    final result = await _ipc('tunnel_logs', args: {'tunnelId': tunnelId, 'limit': limit});
    _jsonResponse(response, result['ok'] == true ? 200 : 404, result);
  }

  Future<void> _handleReloadWebhooks(HttpResponse response) async {
    final result = await _ipc('reload_webhooks');
    _jsonResponse(response, result['ok'] == true ? 200 : 500, result);
  }

  Future<void> _handleQuickBind(HttpRequest request) async {
    final data = await _parseBody(request);
    if (data == null) return;
    final subdomain = data!['subdomain'] as String?;
    final zoneId = data['zoneId'] as String?;
    final zoneName = data['zoneName'] as String?;
    final port = data['port'] as int?;

    if (subdomain == null || zoneId == null || port == null || zoneName == null) {
      _jsonResponse(request.response, 400, {'ok': false, 'error': 'subdomain, zoneId, zoneName, and port required'});
      return;
    }

    final token = await AppStorage.instance.read(key: CloudflareService.tokenKey);
    final accountId = await AppStorage.instance.read(key: CloudflareService.accountIdKey);
    if (token == null || token.isEmpty || accountId == null) {
      _jsonResponse(request.response, 400, {'ok': false, 'error': 'Cloudflare API not configured'});
      return;
    }

    final result = await TunnelOperations.quickBind(
      token: token, accountId: accountId,
      subdomain: subdomain, zoneId: zoneId, zoneName: zoneName, port: port,
      ipc: _ipc,
    );
    _jsonResponse(request.response, result['ok'] == true ? 200 : 500, result);
  }

  // ---- Webhooks CRUD ----

  Future<void> _handleListWebhooks(HttpResponse response) async {
    _jsonResponse(response, 200, {'ok': true, 'webhooks': WebhookService.instance.webhooks.map((w) => w.toJson()).toList()});
  }

  Future<void> _handleCreateWebhook(HttpRequest request) async {
    final body = json.decode(await utf8.decodeStream(request));
    final cfg = WebhookConfig.fromJson(body);
    await WebhookService.instance.addWebhook(cfg);
    _jsonResponse(request.response, 201, {'ok': true, 'id': cfg.id});
  }

  Future<void> _handleUpdateWebhook(String id, HttpRequest request) async {
    final body = json.decode(await utf8.decodeStream(request));
    final cfg = WebhookConfig.fromJson({...body, 'id': id});
    await WebhookService.instance.updateWebhook(cfg);
    _jsonResponse(request.response, 200, {'ok': true});
  }

  Future<void> _handleDeleteWebhook(String id, HttpResponse response) async {
    await WebhookService.instance.deleteWebhook(id);
    _jsonResponse(response, 200, {'ok': true});
  }

  Future<void> _handleTestWebhook(String id, HttpResponse response) async {
    final w = WebhookService.instance.webhooks.where((w) => w.id == id).firstOrNull;
    if (w == null) {
      _jsonResponse(response, 404, {'ok': false, 'error': 'Webhook not found'});
      return;
    }
    final ok = await WebhookService.instance.testWebhook(w);
    _jsonResponse(response, 200, {'ok': ok});
  }

  Future<void> _handleWebhookLogs(HttpResponse response) async {
    await WebhookService.instance.loadLogs();
    _jsonResponse(response, 200, {'ok': true, 'logs': WebhookService.instance.logs.map((l) => l.toJson()).toList()});
  }

  // ---- DNS Records ----

  Future<void> _handleListDns(HttpRequest request) async {
    final zoneId = request.uri.queryParameters['zoneId'];
    if (zoneId == null) {
      _jsonResponse(request.response, 400, {'ok': false, 'error': '?zoneId= required'});
      return;
    }
    final records = await CloudflareService.listDnsRecords(zoneId);
    _jsonResponse(request.response, 200, {'ok': true, 'records': records});
  }

  Future<void> _handleCreateDns(HttpRequest request) async {
    final body = await _parseBody(request);
    if (body == null) return;
    final zoneId = body['zoneId'] as String?;
    final type = body['type'] as String?;
    final name = body['name'] as String?;
    final content = body['content'] as String?;
    if (zoneId == null || type == null || name == null || content == null) {
      _jsonResponse(request.response, 400, {'ok': false, 'error': 'zoneId, type, name, content required'});
      return;
    }
    final ok = await CloudflareService.createDnsRecord(zoneId,
      type: type, name: name, content: content,
      ttl: body['ttl'] as int? ?? 1,
      proxied: body['proxied'] as bool?,
      priority: body['priority'] as int?,
    );
    _jsonResponse(request.response, ok ? 201 : 500, {'ok': ok});
  }

  Future<void> _handleUpdateDns(HttpRequest request) async {
    final body = await _parseBody(request);
    if (body == null) return;
    final zoneId = body['zoneId'] as String?;
    final recordId = body['recordId'] as String?;
    if (zoneId == null || recordId == null) {
      _jsonResponse(request.response, 400, {'ok': false, 'error': 'zoneId and recordId required'});
      return;
    }
    final ok = await CloudflareService.updateDnsRecord(zoneId, recordId,
      type: body['type'] as String?,
      name: body['name'] as String?,
      content: body['content'] as String?,
      ttl: body['ttl'] as int?,
      proxied: body['proxied'] as bool?,
    );
    _jsonResponse(request.response, ok ? 200 : 500, {'ok': ok});
  }

  Future<void> _handleDeleteDns(HttpRequest request) async {
    String? zoneId, recordId;
    // Try body first (same as PUT), fall back to query params
    try {
      final body = json.decode(await utf8.decodeStream(request));
      zoneId = body['zoneId'] as String?;
      recordId = body['recordId'] as String?;
    } catch (_) {}
    zoneId ??= request.uri.queryParameters['zoneId'];
    recordId ??= request.uri.queryParameters['recordId'];
    if (zoneId == null || recordId == null) {
      _jsonResponse(request.response, 400, {'ok': false, 'error': 'zoneId and recordId required'});
      return;
    }
    final ok = await CloudflareService.deleteDnsRecord(zoneId, recordId);
    _jsonResponse(request.response, ok ? 200 : 500, {'ok': ok});
  }

  // ---- Rate Alerts ----

  Future<void> _handleListRateAlerts(HttpResponse response) async {
    await RateAlertService.instance.loadAlerts();
    _jsonResponse(response, 200, {'ok': true, 'alerts': RateAlertService.instance.alerts.map((a) => a.toJson()).toList()});
  }

  Future<void> _handleCreateRateAlert(HttpRequest request) async {
    final body = await _parseBody(request);
    if (body == null) return;
    final alert = RateAlertConfig.fromJson(body);
    await RateAlertService.instance.loadAlerts();
    await RateAlertService.instance.addAlert(alert);
    _jsonResponse(request.response, 201, {'ok': true});
  }

  Future<void> _handleDeleteRateAlert(String id, HttpResponse response) async {
    await RateAlertService.instance.deleteAlert(id);
    _jsonResponse(response, 200, {'ok': true});
  }

  Future<void> _handleUpdateRateAlert(String id, HttpRequest request) async {
    final body = await _parseBody(request);
    if (body == null) return;
    final alert = RateAlertConfig.fromJson({...body, 'id': id});
    await RateAlertService.instance.updateAlert(alert);
    _jsonResponse(request.response, 200, {'ok': true});
  }

  Future<void> _handleCheckRateAlerts(HttpResponse response) async {
    final results = await RateAlertService.instance.checkNow();
    _jsonResponse(response, 200, {'ok': true, 'results': results});
  }

  // ---- Backup / Restore ----

  Future<void> _handleCreateBackup(HttpResponse response) async {
    await createAutoBackup();
    _jsonResponse(response, 200, {'ok': true, 'message': 'Auto-backup created'});
  }

  Future<void> _handleCreateBackupWithOptions(HttpRequest request) async {
    final body = await _parseBody(request);
    if (body == null) return;
    final sections = (body!['sections'] as List?)?.cast<String>() ?? [];
    final password = body['password'] as String?;
    final includeSecrets = body['includeSecrets'] == true;
    // Use the same logic as createAutoBackup with selective sections
    final home = Platform.environment['HOME'] ?? '/tmp';
    final src = Directory('$home/.cloudflared');
    if (!await src.exists()) {
      _jsonResponse(request.response, 500, {'ok': false, 'error': 'No config directory'});
      return;
    }
    final backup = <String, dynamic>{'version': 1, 'timestamp': DateTime.now().toIso8601String(), 'auto': false};
    final keyMap = {'app-settings.json': 'app_settings', 'webhooks.json': 'webhooks', 'app-tunnels.json': 'app_tunnels', 'daemon.json': 'daemon', 'rate-alerts.json': 'rate_alerts'};
    for (final entry in keyMap.entries) {
      if (!sections.contains(entry.value)) continue;
      final f = File('${src.path}/${entry.key}');
      if (await f.exists()) backup[entry.value] = json.decode(await f.readAsString());
    }
    if (includeSecrets && password != null) {
      final creds = <String, dynamic>{};
      await for (final f in src.list()) {
        final name = f.path.split('/').last;
        if (name.endsWith('.json') && !keyMap.containsKey(name) && name != 'app-settings.json') {
          creds[name] = json.decode(await File(f.path).readAsString());
        }
      }
      if (creds.isNotEmpty) backup['credentials'] = creds;
    }
    String content = const JsonEncoder.withIndent('  ').convert(backup);
    if (password != null && password.isNotEmpty) {
      content = encryptData(content, password);
    }
    // Also save to auto-backups directory
    final dstDir = Directory('$home/.cloudflared/backups');
    if (!await dstDir.exists()) await dstDir.create(recursive: true);
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    await File('${dstDir.path}/$stamp.json').writeAsString(content);
    _jsonResponse(request.response, 200, {'ok': true, 'data': password != null ? content : backup, 'message': 'Backup created'});
  }

  Future<void> _handleListBackups(HttpResponse response) async {
    final backups = await listAutoBackups();
    _jsonResponse(response, 200, {'ok': true, 'backups': backups});
  }

  Future<void> _handleDecryptBackup(HttpRequest request) async {
    final body = await _parseBody(request);
    if (body == null) return;
    final data = body!['data'] as String?;
    final password = body['password'] as String?;
    if (data == null || password == null || password.isEmpty) {
      _jsonResponse(request.response, 400, {'ok': false, 'error': 'data and password required'});
      return;
    }
    final decrypted = decryptData(data, password);
    if (decrypted == null) {
      _jsonResponse(request.response, 400, {'ok': false, 'error': 'Wrong password or corrupt data'});
      return;
    }
    try {
      final parsed = json.decode(decrypted);
      _jsonResponse(request.response, 200, {'ok': true, 'data': parsed});
    } catch (_) {
      _jsonResponse(request.response, 400, {'ok': false, 'error': 'Invalid backup data'});
    }
  }

  Future<void> _handleDeleteBackup(HttpRequest request) async {
    final name = request.uri.queryParameters['name'];
    if (name == null || name.isEmpty || name.contains('/') || name.contains('..')) {
      _jsonResponse(request.response, 400, {'ok':false,'error':'Invalid backup name'}); return;
    }
    final home = Platform.environment['HOME'] ?? '/tmp';
    final file = File('$home/.cloudflared/backups/$name');
    if (await file.exists()) { await file.delete(); _jsonResponse(request.response, 200, {'ok':true}); }
    else { _jsonResponse(request.response, 404, {'ok':false,'error':'Not found'}); }
  }

  Future<void> _handleFetchBackup(HttpRequest request) async {
    final name = request.uri.queryParameters['name'];
    if (name == null || name.isEmpty || name.contains('/') || name.contains('..')) {
      _jsonResponse(request.response, 400, {'ok': false, 'error': 'Invalid backup name'});
      return;
    }
    final home = Platform.environment['HOME'] ?? '/tmp';
    final file = File('$home/.cloudflared/backups/$name');
    if (!await file.exists()) {
      _jsonResponse(request.response, 404, {'ok': false, 'error': 'Backup not found'});
      return;
    }
    final content = await file.readAsString();
    final data = json.decode(content);
    _jsonResponse(request.response, 200, {'ok': true, 'data': data});
  }

  Future<void> _handleRestore(HttpRequest request) async {
    final body = await _parseBody(request);
    if (body == null) return;
    final data = body!['data'] as Map<String, dynamic>?;
    final sections = (body['sections'] as List?)?.cast<String>() ?? [];
    if (data == null || sections.isEmpty) {
      _jsonResponse(request.response, 400, {'ok': false, 'error': 'data and sections required'});
      return;
    }
    final home = Platform.environment['HOME'] ?? '/tmp';
    int restored = 0;
    final keyMap = {'app-settings.json': 'app_settings', 'webhooks.json': 'webhooks', 'app-tunnels.json': 'app_tunnels', 'daemon.json': 'daemon', 'rate-alerts.json': 'rate_alerts'};
    final credsDir = Directory('$home/.cloudflared');
    for (final entry in keyMap.entries) {
      if (!sections.contains(entry.value)) continue;
      final content = data[entry.value];
      if (content == null) continue;
      final file = File('$home/.cloudflared/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(json.encode(content));
      restored++;
    }
    if (sections.contains('tunnel_credentials') && data.containsKey('credentials')) {
      final creds = data['credentials'] as Map<String, dynamic>?;
      if (creds != null) {
        for (final entry in creds.entries) {
          await File('${credsDir.path}/${entry.key}').writeAsString(json.encode(entry.value));
        }
        restored++;
      }
    }
    _jsonResponse(request.response, 200, {'ok': true, 'restored': restored});
  }

  // ---- Daemon Control ----

  Future<void> _handleDaemonStart(HttpResponse response) async {
    final client = DaemonClient();
    if (await client.connect()) {
      _jsonResponse(response, 200, {'ok': true, 'message': 'Daemon already running'});
      client.disconnect();
      return;
    }
    final exe = Platform.resolvedExecutable;
    Process.start(exe, ['daemon', 'start'], mode: ProcessStartMode.detached);
    _jsonResponse(response, 200, {'ok': true, 'message': 'Daemon starting...'});
  }

  Future<void> _handleDaemonStop(HttpResponse response) async {
    final client = DaemonClient();
    if (!await client.connect()) {
      _jsonResponse(response, 503, {'ok': false, 'error': 'Daemon not running'});
      return;
    }
    await client.shutdown();
    client.disconnect();
    _jsonResponse(response, 200, {'ok': true, 'message': 'Daemon stopped'});
  }

  // ---- Settings ----

  Future<void> _handleGetSettings(HttpResponse response) async {
    final data = <String, dynamic>{};
    final home = Platform.environment['HOME'] ?? '/tmp';
    for (final key in ['auto_bind_min_port', 'auto_bind_max_port', 'api_enabled', 'api_port', 'close_to_tray', 'auto_start', 'theme_mode']) {
      data[key] = await AppStorage.instance.read(key: key);
    }
    final dcfg = File('$home/.cloudflared/daemon.json');
    if (await dcfg.exists()) {
      data['daemon'] = json.decode(await dcfg.readAsString());
    }
    _jsonResponse(response, 200, {'ok': true, 'settings': data});
  }

  Future<void> _handlePatchSettings(HttpRequest request) async {
    final body = await _parseBody(request);
    if (body == null) return;
    for (final entry in body.entries) {
      final newVal = entry.value?.toString();
      final oldVal = await AppStorage.instance.read(key: entry.key);
      if (newVal != oldVal) {
        await AppStorage.instance.write(key: entry.key, value: newVal);
      }
    }
    _jsonResponse(request.response, 200, {'ok': true});
  }

  // ---- Export ----

  Future<void> _handleExport(HttpRequest request) async {
    final fmt = request.uri.queryParameters['format'] ?? 'json';
    final export = <String, dynamic>{'generatedAt': DateTime.now().toIso8601String()};

    final tunnels = await CloudflareService.listTunnels();
    final tunnelList = <Map<String, dynamic>>[];
    for (final t in tunnels) {
      final id = t['id'] as String? ?? '';
      final cfg = await CloudflareService.getTunnelConfig(id);
      final ingress = (cfg?['config']?['ingress'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? [];
      tunnelList.add({'id': id, 'name': t['name'], 'status': t['status'] ?? 'unknown', 'connections': t['connections'] ?? [], 'ingress': ingress});
    }
    export['tunnels'] = tunnelList;

    final zones = await CloudflareService.getZones();
    final zoneList = <Map<String, dynamic>>[];
    for (final z in zones) {
      final records = await CloudflareService.listDnsRecords(z['id']);
      zoneList.add({'id': z['id'], 'name': z['name'], 'records': records});
    }
    export['dns'] = zoneList;

    String content;
    String contentType;
    if (fmt == 'md') {
      final buf = StringBuffer();
      buf.writeln('# Cloudflare Manager Export');
      buf.writeln();
      for (final t in tunnelList) {
        buf.writeln('## ${t['name']}');
        buf.writeln('- ID: `${t['id']}` - Status: ${t['status']}');
        buf.writeln();
      }
      content = buf.toString();
      contentType = 'text/markdown';
    } else {
      content = const JsonEncoder.withIndent('  ').convert(export);
      contentType = 'application/json';
    }
    request.response.headers.contentType = ContentType.parse(contentType);
    request.response.headers.set('Access-Control-Allow-Origin', '*');
    request.response.write(content);
    request.response.close();
  }

  Future<void> _handleToggleService(String tunnelId, HttpRequest request) async {
    final body = await _parseBody(request);
    if (body == null) return;
    final enabled = body['enabled'] == true;
    await CloudflaredService.saveServiceEnabled(tunnelId, enabled);
    _jsonResponse(request.response, 200, {'ok': true, 'serviceEnabled': enabled});
  }

  Future<void> _handleSaveTunnelNotes(String tunnelId, HttpRequest request) async {
    final body = json.decode(await utf8.decodeStream(request));
    final notes = body['notes'] as String?;
    final tags = body['tags'] as String?;
    await CloudflaredService.saveTunnelNotes(tunnelId, notes: notes, tags: tags);
    _jsonResponse(request.response, 200, {'ok': true});
  }

  Future<void> _handleDeleteTunnel(String tunnelId, HttpResponse response) async {
    final result = await TunnelOperations.deleteTunnel(tunnelId: tunnelId, ipc: _ipc);
    _jsonResponse(response, result['ok'] == true ? 200 : 500, result);
  }

  Future<void> _handleZones(HttpResponse response) async {
    final zones = await CloudflareService.getZones();
    _jsonResponse(response, 200, {'ok': true, 'zones': zones.map((z) => {'id': z['id'], 'name': z['name']}).toList()});
  }

  Future<void> _handleCfConfig(HttpRequest request) async {
    final body = await _parseBody(request);
    if (body == null) return;
    final token = body['token'] as String?;
    final accountId = body['accountId'] as String?;
    if (token == null || accountId == null) {
      _jsonResponse(request.response, 400, {'ok': false, 'error': 'token and accountId required'});
      return;
    }
    await AppStorage.instance.write(key: CloudflareService.tokenKey, value: token);
    await AppStorage.instance.write(key: CloudflareService.accountIdKey, value: accountId);
    _jsonResponse(request.response, 200, {'ok': true});
  }

  Future<void> _handleCfConfigStatus(HttpResponse response) async {
    final token = await AppStorage.instance.read(key: CloudflareService.tokenKey);
    _jsonResponse(response, 200, {'ok': true, 'configured': token != null && token.isNotEmpty});
  }

  void _jsonResponse(HttpResponse response, int status, Map<String, dynamic> data) {
    _corsHeaders(response);
    response.headers.contentType = ContentType.json;
    response.statusCode = status;
    response.write(json.encode(data));
    response.close();
  }

  String? _cachedWebDistDir;
  String? get _webDistDir {
    if (_cachedWebDistDir != null) return _cachedWebDistDir;
    final home = Platform.environment['HOME'] ?? '/tmp';
    final exe = Platform.resolvedExecutable;
    final exeDir = exe.contains('/') ? exe.substring(0, exe.lastIndexOf('/')) : '';

    final candidates = <String>[
      '$exeDir/web/dist/browser',
      '$exeDir/../web/dist/browser',
      '$home/.cloudflared/web/dist/browser',
      '${Directory.current.path}/web/dist/browser',
      '$exeDir/web/dist',
      '$exeDir/../web/dist',
      '$home/.cloudflared/web/dist',
      '${Directory.current.path}/web/dist',
    ];

    print('[api] Web dist candidates:');
    for (final dir in candidates) {
      final hasIndex = File('$dir/index.html').existsSync();
      print('[api]   $dir ${hasIndex ? "✓ index.html" : "✗ no index.html"}');
      if (hasIndex) {
        _cachedWebDistDir = dir;
        return dir;
      }
    }
    print('[api] No web dist found, current dir: ${Directory.current.path}');
    return null;
  }

  Future<bool> _serveStatic(HttpResponse response, String path) async {
    final webDir = _webDistDir;
    if (webDir == null) return false;

    final file = File('$webDir$path');
    if (!await file.exists()) return false;

    final contentType = path.endsWith('.css')
        ? ContentType('text', 'css', charset: 'utf-8')
        : path.endsWith('.js')
            ? ContentType('application', 'javascript', charset: 'utf-8')
            : path.endsWith('.html')
                ? ContentType('text', 'html', charset: 'utf-8')
                : path.endsWith('.svg')
                    ? ContentType('image', 'svg+xml')
                    : ContentType.binary;

    _corsHeaders(response);
    response.headers.contentType = contentType;
    response.headers.set('Cache-Control', path.endsWith('.html')
        ? 'no-cache, no-store, must-revalidate'
        : 'public, max-age=31536000, immutable');
    response.statusCode = 200;
    final isText = path.endsWith('.css') || path.endsWith('.js') || path.endsWith('.html') || path.endsWith('.svg');
    if (isText) {
      response.write(await file.readAsString());
    } else {
      response.add(await file.readAsBytes());
    }
    response.close();
    return true;
  }

  Future<void> _serveWebDashboard(HttpResponse response) async {
    final webDir = _webDistDir;
    if (webDir == null) {
      response.statusCode = 404;
      response.write('Web dashboard not built. Run: cd web && npm install && npm run build');
      response.close();
      return;
    }

    final file = File('$webDir/index.html');
    if (!await file.exists()) {
      response.statusCode = 404;
      response.write('Web dashboard not built. Run: cd web && npm install && npm run build');
      response.close();
      return;
    }

    final html = await file.readAsString();
    response.headers.contentType = ContentType.html;
    response.headers.set('Cache-Control', 'no-cache, no-store, must-revalidate');
    response.statusCode = 200;
    response.write(html);
    response.close();
  }

  void _corsHeaders(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', 'Authorization, Content-Type');
  }

  void _serveSetupPage(HttpResponse response) {
    final html = '''
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Cloudflare Manager — Setup</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--bg:#0f172a;--card:#1e293b;--border:#334155;--text:#f1f5f9;--muted:#94a3b8;--accent:#F6821F}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:var(--bg);color:var(--text);display:flex;align-items:center;justify-content:center;min-height:100vh}
.card{background:var(--card);border:1px solid var(--border);border-radius:16px;padding:32px;width:100%;max-width:480px}
h1{font-size:20px;margin-bottom:8px} .sub{color:var(--muted);font-size:13px;margin-bottom:24px}
label{font-size:12px;color:var(--muted);display:block;margin:12px 0 4px}
input,select{width:100%;padding:10px 12px;background:var(--bg);border:1px solid var(--border);border-radius:8px;color:var(--text);font-size:13px}
input:focus{border-color:var(--accent);outline:none}
.btn{width:100%;padding:12px;border:none;border-radius:8px;cursor:pointer;font-size:14px;font-weight:600;color:#fff;background:var(--accent);margin-top:20px}
.btn:hover{opacity:.9}
.success{color:#4ade80;font-size:12px;margin-top:8px;display:none}
.error{color:#f87171;font-size:12px;margin-top:8px;display:none}
.mono{font-family:monospace;font-size:11px;color:var(--muted);word-break:break-all;background:var(--bg);padding:8px;border-radius:6px;margin-top:4px}
</style></head><body>
<div class="card">
<h1>⚡ Cloudflare Manager</h1>
<p class="sub">First-run setup — your API key has been auto-generated. Configure your Cloudflare credentials to get started.</p>
<label>API Key (auto-generated — copy this now)</label>
<div class="mono" id="apiKey">$_apiKey</div>
<label>API Port</label>
<input id="port" value="$port" placeholder="9845">
<label>Cloudflare API Token</label>
<input id="token" placeholder="e.g. AbCdEf123...">
<label>Cloudflare Account ID</label>
<input id="accountId" placeholder="e.g. 1a2b3c4d...">
<button class="btn" onclick="submit()">Save &amp; Start</button>
<div class="success" id="ok">Saved! Redirecting to login…</div>
<div class="error" id="err"></div>
</div>
<script>
async function submit(){
 document.getElementById('err').style.display='none';
 document.getElementById('ok').style.display='none';
 const btn=document.querySelector('.btn');
 btn.disabled=true;btn.textContent='Saving…';
 try{
  const r=await fetch('/api/setup',{method:'POST',headers:{'Content-Type':'application/json'},
   body:JSON.stringify({port:document.getElementById('port').value,token:document.getElementById('token').value,accountId:document.getElementById('accountId').value})});
  const d=await r.json();
  if(!d.ok) throw new Error(d.error||'Unknown error');
  document.getElementById('ok').style.display='block';
  setTimeout(()=>location.reload(),2000);
 }catch(e){
  document.getElementById('err').textContent=e.message;document.getElementById('err').style.display='block';
  btn.disabled=false;btn.textContent='Save & Start';
 }
}
</script></body></html>''';
    _html(response, html);
  }

  Future<void> _handleSetup(HttpRequest request) async {
    final body = await _parseBody(request);
    if (body == null) return;
    final portStr = body!['port'] as String?;
    final token = body['token'] as String?;
    final accountId = body['accountId'] as String?;
    if (token == null || token.isEmpty || accountId == null || accountId.isEmpty) {
      _jsonResponse(request.response, 400, {'ok': false, 'error': 'token and accountId required'});
      return;
    }
    if (portStr != null) {
      await AppStorage.instance.write(key: 'api_port', value: portStr);
    }
    await AppStorage.instance.write(key: CloudflareService.tokenKey, value: token);
    await AppStorage.instance.write(key: CloudflareService.accountIdKey, value: accountId);
    await AppStorage.instance.write(key: 'api_enabled', value: 'true');
    _jsonResponse(request.response, 200, {'ok': true});
    // Restart API server in normal mode after a short delay
    Future.delayed(const Duration(milliseconds: 500), () async {
      try {
        final client = DaemonClient();
        if (await client.connect()) {
          await client.send('api_restart');
          client.disconnect();
        }
      } catch (_) {}
    });
  }

  void _serveSwaggerUi(HttpResponse response) {
    final html = '''
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Cloudflare Manager API</title>
<link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css">
<style>html{box-sizing:border-box;overflow-y:scroll}*,:after,:before{box-sizing:inherit}body{background:#fafafa;margin:0}</style>
</head><body>
<div id="swagger-ui"></div>
<script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js" crossorigin></script>
<script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-standalone-preset.js" crossorigin></script>
<script>
SwaggerUIBundle({url:"/openapi.json",dom_id:"#swagger-ui",deepLinking:true,presets:[SwaggerUIBundle.presets.apis,SwaggerUIStandalonePreset],layout:"StandaloneLayout"})
</script></body></html>''';
    _html(response, html);
  }

  void _serveOpenApiSpec(HttpResponse response) {
    final spec = {
      'openapi': '3.0.3',
      'info': {
        'title': 'Cloudflare Manager API',
        'version': '1.0.0',
        'description': 'REST API for managing Cloudflare tunnels, DNS, webhooks, and more.',
      },
      'servers': [{'url': 'http://localhost:$port'}],
      'security': [{'bearerAuth': []}],
      'components': {
        'securitySchemes': {
          'bearerAuth': {'type': 'http', 'scheme': 'bearer'},
        },
      },
      'paths': _buildOpenApiPaths(),
    };
    _jsonResponse(response, 200, spec);
  }

  Map<String, dynamic> _buildOpenApiPaths() {
    final p = <String, dynamic>{
      '/health': {'get': {'summary': 'Health check', 'security': [], 'responses': {'200': {'description': 'OK'}}}},
      '/status': {'get': {'summary': 'Daemon and tunnel status', 'security': [{'bearerAuth': []}], 'responses': {'200': {'description': 'Daemon status'}}}},
      '/tunnels': {
        'get': {'summary': 'List all tunnels', 'security': [{'bearerAuth': []}], 'responses': {'200': {'description': 'Tunnel list'}}},
        'post': {'summary': 'Bind an existing tunnel', 'security': [{'bearerAuth': []}], 'requestBody': {'content': {'application/json': {'schema': {'type': 'object', 'required': ['tunnelId', 'token', 'port'], 'properties': {'tunnelId': {'type': 'string'}, 'token': {'type': 'string'}, 'port': {'type': 'integer'}, 'hostname': {'type': 'string'}}}}}}, 'responses': {'200': {'description': 'Tunnel bound'}}},
      },
      '/tunnels/{id}': {
        'delete': {'summary': 'Unbind a tunnel', 'security': [{'bearerAuth': []}], 'parameters': [{'name': 'id', 'in': 'path', 'required': true, 'schema': {'type': 'string'}}], 'responses': {'200': {'description': 'Tunnel unbound'}}},
      },
      '/tunnels/{id}/delete': {
        'post': {'summary': 'Full delete (Cloudflare + DNS + local)', 'security': [{'bearerAuth': []}], 'parameters': [{'name': 'id', 'in': 'path', 'required': true, 'schema': {'type': 'string'}}], 'responses': {'200': {'description': 'Tunnel deleted'}}},
      },
      '/logs/{id}': {
        'get': {'summary': 'Get tunnel logs', 'security': [{'bearerAuth': []}], 'parameters': [{'name': 'id', 'in': 'path', 'required': true, 'schema': {'type': 'string'}}, {'name': 'limit', 'in': 'query', 'schema': {'type': 'integer', 'default': 50}}], 'responses': {'200': {'description': 'Log entries'}}},
      },
      '/webhooks': {
        'get': {'summary': 'List all webhooks', 'security': [{'bearerAuth': []}], 'responses': {'200': {'description': 'Webhook list'}}},
        'post': {'summary': 'Create a webhook', 'security': [{'bearerAuth': []}], 'requestBody': {'content': {'application/json': {'schema': {'type': 'object'}}}}, 'responses': {'201': {'description': 'Created'}}},
      },
      '/webhooks/{id}': {
        'put': {'summary': 'Update a webhook', 'security': [{'bearerAuth': []}], 'parameters': [{'name': 'id', 'in': 'path', 'required': true, 'schema': {'type': 'string'}}], 'requestBody': {'content': {'application/json': {'schema': {'type': 'object'}}}}, 'responses': {'200': {'description': 'Updated'}}},
        'delete': {'summary': 'Delete a webhook', 'security': [{'bearerAuth': []}], 'parameters': [{'name': 'id', 'in': 'path', 'required': true, 'schema': {'type': 'string'}}], 'responses': {'200': {'description': 'Deleted'}}},
      },
      '/webhooks/{id}/test': {
        'post': {'summary': 'Test a webhook', 'security': [{'bearerAuth': []}], 'parameters': [{'name': 'id', 'in': 'path', 'required': true, 'schema': {'type': 'string'}}], 'responses': {'200': {'description': 'Test result'}}},
      },
      '/webhooks/reload': {
        'post': {'summary': 'Reload webhook configuration', 'security': [{'bearerAuth': []}], 'responses': {'200': {'description': 'Webhooks reloaded'}}},
      },
      '/webhook-logs': {
        'get': {'summary': 'Get webhook execution logs', 'security': [{'bearerAuth': []}], 'responses': {'200': {'description': 'Log entries'}}},
      },
      '/zones': {
        'get': {'summary': 'List Cloudflare zones', 'security': [{'bearerAuth': []}], 'responses': {'200': {'description': 'Zone list'}}},
      },
      '/dns': {
        'get': {'summary': 'List DNS records for a zone', 'security': [{'bearerAuth': []}], 'parameters': [{'name': 'zoneId', 'in': 'query', 'required': true, 'schema': {'type': 'string'}}], 'responses': {'200': {'description': 'Record list'}}},
        'post': {'summary': 'Create a DNS record', 'security': [{'bearerAuth': []}], 'requestBody': {'content': {'application/json': {'schema': {'type': 'object', 'required': ['zoneId', 'type', 'name', 'content'], 'properties': {'zoneId': {'type': 'string'}, 'type': {'type': 'string'}, 'name': {'type': 'string'}, 'content': {'type': 'string'}, 'ttl': {'type': 'integer'}, 'proxied': {'type': 'boolean'}}}}}}, 'responses': {'201': {'description': 'Created'}}},
        'put': {'summary': 'Update a DNS record', 'security': [{'bearerAuth': []}], 'requestBody': {'content': {'application/json': {'schema': {'type': 'object', 'required': ['zoneId', 'recordId'], 'properties': {'zoneId': {'type': 'string'}, 'recordId': {'type': 'string'}, 'type': {'type': 'string'}, 'name': {'type': 'string'}, 'content': {'type': 'string'}}}}}}, 'responses': {'200': {'description': 'Updated'}}},
        'delete': {'summary': 'Delete a DNS record', 'security': [{'bearerAuth': []}], 'parameters': [{'name': 'zoneId', 'in': 'query', 'required': true, 'schema': {'type': 'string'}}, {'name': 'recordId', 'in': 'query', 'required': true, 'schema': {'type': 'string'}}], 'responses': {'200': {'description': 'Deleted'}}},
      },
      '/rate-alerts': {
        'get': {'summary': 'List rate alerts', 'security': [{'bearerAuth': []}], 'responses': {'200': {'description': 'Alert list'}}},
        'post': {'summary': 'Create a rate alert', 'security': [{'bearerAuth': []}], 'requestBody': {'content': {'application/json': {'schema': {'type': 'object'}}}}, 'responses': {'201': {'description': 'Created'}}},
      },
      '/rate-alerts/{id}': {
        'delete': {'summary': 'Delete a rate alert', 'security': [{'bearerAuth': []}], 'parameters': [{'name': 'id', 'in': 'path', 'required': true, 'schema': {'type': 'string'}}], 'responses': {'200': {'description': 'Deleted'}}},
      },
      '/rate-alerts/check': {
        'post': {'summary': 'Run rate alert check now', 'security': [{'bearerAuth': []}], 'responses': {'200': {'description': 'Check results'}}},
      },
      '/backup': {
        'post': {'summary': 'Create an auto-backup', 'security': [{'bearerAuth': []}], 'responses': {'200': {'description': 'Backup created'}}},
      },
      '/backups': {
        'get': {'summary': 'List auto-backups', 'security': [{'bearerAuth': []}], 'responses': {'200': {'description': 'Backup list'}}},
      },
      '/daemon/start': {
        'post': {'summary': 'Start the daemon', 'security': [{'bearerAuth': []}], 'responses': {'200': {'description': 'Daemon starting'}}},
      },
      '/daemon/stop': {
        'post': {'summary': 'Stop the daemon', 'security': [{'bearerAuth': []}], 'responses': {'200': {'description': 'Daemon stopped'}}},
      },
      '/settings': {
        'get': {'summary': 'Read all settings', 'security': [{'bearerAuth': []}], 'responses': {'200': {'description': 'Settings'}}},
        'patch': {'summary': 'Update settings', 'security': [{'bearerAuth': []}], 'requestBody': {'content': {'application/json': {'schema': {'type': 'object'}}}}, 'responses': {'200': {'description': 'Updated'}}},
      },
      '/export': {
        'get': {'summary': 'Export tunnels and DNS', 'security': [{'bearerAuth': []}], 'parameters': [{'name': 'format', 'in': 'query', 'schema': {'type': 'string', 'enum': ['json', 'md'], 'default': 'json'}}], 'responses': {'200': {'description': 'Export data'}}},
      },
      '/bind': {
        'post': {'summary': 'Quick bind — create tunnel + DNS in one call', 'security': [{'bearerAuth': []}], 'requestBody': {'content': {'application/json': {'schema': {'type': 'object', 'required': ['subdomain', 'zoneId', 'zoneName', 'port'], 'properties': {'subdomain': {'type': 'string'}, 'zoneId': {'type': 'string'}, 'zoneName': {'type': 'string'}, 'port': {'type': 'integer'}}}}}}, 'responses': {'200': {'description': 'Tunnel created and bound'}}},
      },
      '/cf-config': {
        'get': {'summary': 'Check if Cloudflare API is configured', 'security': [{'bearerAuth': []}], 'responses': {'200': {'description': 'Config status'}}},
        'post': {'summary': 'Set Cloudflare API credentials', 'security': [{'bearerAuth': []}], 'requestBody': {'content': {'application/json': {'schema': {'type': 'object', 'required': ['token', 'accountId'], 'properties': {'token': {'type': 'string'}, 'accountId': {'type': 'string'}}}}}}, 'responses': {'200': {'description': 'Credentials saved'}}},
      },
    };
    return p;
  }

  void _html(HttpResponse response, String html) {
    response.headers.contentType = ContentType.html;
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.write(html);
    response.close();
  }
}
