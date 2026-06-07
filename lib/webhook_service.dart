import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'webhook_config.dart';
import 'daemon/events.dart';

class WebhookService {
  static final instance = WebhookService._();
  WebhookService._();

  final _configFile = _getConfigFile();
  final _logFile = _getLogFile();
  final _debugLogFile = _getDebugLogFile();
  final List<WebhookConfig> _webhooks = [];
  final List<WebhookLog> _logs = [];
  static const _maxLogs = 500;

  final _logsController = StreamController<List<WebhookLog>>.broadcast();

  static File _getConfigFile() {
    final home = Platform.environment['HOME'] ?? '/tmp';
    return File('$home/.cloudflared/webhooks.json');
  }

  static File _getLogFile() {
    final home = Platform.environment['HOME'] ?? '/tmp';
    return File('$home/.cloudflared/webhook-logs.json');
  }

  static File _getDebugLogFile() {
    final home = Platform.environment['HOME'] ?? '/tmp';
    return File('$home/.cloudflared/webhook-debug.log');
  }

  void _debugLog(String message) {
    final ts = DateTime.now().toIso8601String();
    final line = '[$ts] $message';
    print(line);
    try {
      _debugLogFile.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  Stream<List<WebhookLog>> get logsStream => _logsController.stream;
  List<WebhookLog> get logs => List.unmodifiable(_logs);

  Future<void> loadWebhooks() async {
    try {
      if (!await _configFile.exists()) {
        _webhooks.clear();
        return;
      }
      final content = await _configFile.readAsString();
      final data = json.decode(content) as List;
      _webhooks.clear();
      _webhooks.addAll(data.map((w) => WebhookConfig.fromJson(w as Map<String, dynamic>)));
    } catch (e) {
      _debugLog('Failed to load webhooks: $e');
      _webhooks.clear();
    }
  }

  Future<void> loadLogs() async {
    try {
      if (!await _logFile.exists()) {
        _logs.clear();
        return;
      }
      final lines = await _logFile.readAsLines();
      _logs.clear();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          _logs.add(WebhookLog.fromJson(json.decode(line) as Map<String, dynamic>));
        } catch (_) {}
      }
      _enforceMaxLogs();
    } catch (e) {
      _debugLog('Failed to load logs: $e');
      _logs.clear();
    }
  }

  void _enforceMaxLogs() {
    while (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }
  }

  Future<void> saveWebhooks() async {
    try {
      await _configFile.parent.create(recursive: true);
      final data = _webhooks.map((w) => w.toJson()).toList();
      await _configFile.writeAsString(json.encode(data));
    } catch (e) {
      _debugLog('Failed to save webhooks: $e');
    }
  }

  Future<void> _rewriteLogFile() async {
    try {
      await _logFile.parent.create(recursive: true);
      final buf = StringBuffer();
      for (final l in _logs) {
        buf.writeln(json.encode(l.toJson()));
      }
      await _logFile.writeAsString(buf.toString());
    } catch (e) {
      _debugLog('Failed to rewrite logs: $e');
    }
  }

  Future<void> _appendLogLine(String line) async {
    try {
      await _logFile.parent.create(recursive: true);
      await _logFile.writeAsString(line, mode: FileMode.append);
    } catch (e) {
      _debugLog('Failed to append log: $e');
    }
  }

  List<WebhookConfig> get webhooks => List.unmodifiable(_webhooks);

  Future<void> addWebhook(WebhookConfig webhook) async {
    _webhooks.add(webhook);
    await saveWebhooks();
  }

  Future<void> updateWebhook(WebhookConfig webhook) async {
    final index = _webhooks.indexWhere((w) => w.id == webhook.id);
    if (index >= 0) {
      _webhooks[index] = webhook;
      await saveWebhooks();
    }
  }

  Future<void> deleteWebhook(String id) async {
    _webhooks.removeWhere((w) => w.id == id);
    await saveWebhooks();
  }

  Future<void> deleteLog(String id) async {
    _logs.removeWhere((l) => l.id == id);
    await _rewriteLogFile();
    _logsController.add(logs);
  }

  Future<void> clearLogs() async {
    _logs.clear();
    await _rewriteLogFile();
    _logsController.add(logs);
  }

  Future<void> deleteLogsForWebhook(String webhookId) async {
    _logs.removeWhere((l) => l.webhookId == webhookId);
    await _rewriteLogFile();
    _logsController.add(logs);
  }

  Future<void> _addLog(WebhookLog log) async {
    _logs.add(log);
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }
    await _appendLogLine('${json.encode(log.toJson())}\n');
    _logsController.add(logs);
  }

  Future<void> triggerWebhooks(DaemonEvent event) async {
    final trigger = _mapEventToTrigger(event.type);
    if (trigger == null) return;

    final matchingWebhooks = _webhooks.where(
      (w) => w.enabled && w.triggers.contains(trigger),
    ).toList();

    if (matchingWebhooks.isEmpty) {
      _debugLog('Event ${event.eventName} — no matching webhooks (${_webhooks.length} configured)');
      return;
    }

    _debugLog('Event ${event.eventName} → triggering ${matchingWebhooks.length} webhook(s): ${matchingWebhooks.map((w) => w.name).join(", ")}');

    for (final webhook in matchingWebhooks) {
      try {
        await _executeWebhook(webhook, event, trigger);
      } catch (e) {
        _debugLog('Failed to execute webhook ${webhook.name}: $e');
      }
    }
  }

  WebhookTrigger? _mapEventToTrigger(DaemonEventType eventType) {
    switch (eventType) {
      case DaemonEventType.tunnelStarted:
        return WebhookTrigger.tunnelStarted;
      case DaemonEventType.tunnelStopped:
        return WebhookTrigger.tunnelStopped;
      case DaemonEventType.tunnelCrashed:
        return WebhookTrigger.tunnelCrashed;
      case DaemonEventType.tunnelReconnected:
        return WebhookTrigger.tunnelReconnected;
      case DaemonEventType.daemonStarted:
        return WebhookTrigger.daemonStarted;
      case DaemonEventType.daemonStopping:
        return WebhookTrigger.daemonStopping;
    }
  }

  Future<void> _executeWebhook(WebhookConfig webhook, DaemonEvent event, WebhookTrigger trigger) async {
    final startTime = DateTime.now();
    String logId = const Uuid().v4();
    
    try {
      switch (webhook.type) {
        case WebhookType.http:
          await _executeHttpWebhook(webhook, event, trigger, logId, startTime);
          break;
        case WebhookType.slack:
        case WebhookType.discord:
        case WebhookType.telegram:
          _debugLog('${webhook.type.name} not yet implemented');
          await _addLog(WebhookLog(
            id: logId,
            webhookId: webhook.id,
            webhookName: webhook.name,
            trigger: trigger,
            status: WebhookLogStatus.failed,
            error: '${webhook.type.name} not yet implemented',
            durationMs: DateTime.now().difference(startTime).inMilliseconds,
          ));
          break;
      }
    } catch (e) {
      await _addLog(WebhookLog(
        id: logId,
        webhookId: webhook.id,
        webhookName: webhook.name,
        trigger: trigger,
        status: WebhookLogStatus.failed,
        error: e.toString(),
        durationMs: DateTime.now().difference(startTime).inMilliseconds,
      ));
    }
  }

  Future<void> _executeHttpWebhook(
    WebhookConfig webhook,
    DaemonEvent event,
    WebhookTrigger trigger,
    String logId,
    DateTime startTime,
  ) async {
    if (webhook.url == null || webhook.method == null) {
      _debugLog('HTTP webhook missing url or method');
      await _addLog(WebhookLog(
        id: logId,
        webhookId: webhook.id,
        webhookName: webhook.name,
        trigger: trigger,
        status: WebhookLogStatus.failed,
        error: 'Missing URL or method',
      ));
      return;
    }

    final uri = Uri.parse(webhook.url!);
    final method = webhook.method!;
    final headers = Map<String, String>.from(webhook.headers ?? {});
    
    String body;
    if (webhook.bodyTemplate != null && webhook.bodyTemplate!.isNotEmpty) {
      body = _replacePlaceholders(webhook.bodyTemplate!, event);
    } else {
      body = json.encode(event.toJson());
      if (!headers.containsKey('Content-Type')) {
        headers['Content-Type'] = 'application/json';
      }
    }

    http.Response response;
    try {
      switch (method) {
        case HttpMethod.get:
          response = await http.get(uri, headers: headers).timeout(const Duration(seconds: 10));
          break;
        case HttpMethod.post:
          response = await http.post(uri, headers: headers, body: body).timeout(const Duration(seconds: 10));
          break;
        case HttpMethod.put:
          response = await http.put(uri, headers: headers, body: body).timeout(const Duration(seconds: 10));
          break;
        case HttpMethod.patch:
          response = await http.patch(uri, headers: headers, body: body).timeout(const Duration(seconds: 10));
          break;
        case HttpMethod.delete:
          response = await http.delete(uri, headers: headers, body: body).timeout(const Duration(seconds: 10));
          break;
      }

      final duration = DateTime.now().difference(startTime).inMilliseconds;
      final success = response.statusCode >= 200 && response.statusCode < 300;
      
      await _addLog(WebhookLog(
        id: logId,
        webhookId: webhook.id,
        webhookName: webhook.name,
        trigger: trigger,
        status: success ? WebhookLogStatus.success : WebhookLogStatus.failed,
        statusCode: response.statusCode,
        response: response.body.length > 500 ? '${response.body.substring(0, 500)}...' : response.body,
        durationMs: duration,
      ));
    } catch (e) {
      final duration = DateTime.now().difference(startTime).inMilliseconds;
      await _addLog(WebhookLog(
        id: logId,
        webhookId: webhook.id,
        webhookName: webhook.name,
        trigger: trigger,
        status: WebhookLogStatus.failed,
        error: e.toString(),
        durationMs: duration,
      ));
    }
  }

  String _replacePlaceholders(String template, DaemonEvent event) {
    var result = template;
    result = result.replaceAll('{{event}}', event.eventName);
    result = result.replaceAll('{{tunnelId}}', event.tunnelId ?? '');
    result = result.replaceAll('{{hostname}}', event.hostname ?? '');
    result = result.replaceAll('{{port}}', event.port?.toString() ?? '');
    result = result.replaceAll('{{reason}}', event.reason ?? '');
    result = result.replaceAll('{{error}}', event.error ?? '');
    result = result.replaceAll('{{timestamp}}', event.timestamp.toIso8601String());
    return result;
  }

  Future<bool> testWebhook(WebhookConfig webhook) async {
    final startTime = DateTime.now();
    final testEvent = DaemonEvent(
      type: DaemonEventType.tunnelStarted,
      tunnelId: 'test-tunnel',
      hostname: 'localhost',
      port: 3000,
    );

    final logId = const Uuid().v4();
    try {
      switch (webhook.type) {
        case WebhookType.http:
          await _executeHttpWebhook(webhook, testEvent, WebhookTrigger.tunnelStarted, logId, startTime);
          return true;
        case WebhookType.slack:
        case WebhookType.discord:
        case WebhookType.telegram:
          _debugLog('Test not available for ${webhook.type.name}');
          return false;
      }
    } catch (e) {
      _debugLog('Test failed: $e');
      return false;
    }
  }
}
