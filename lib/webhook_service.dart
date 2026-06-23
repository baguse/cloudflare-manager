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
      case DaemonEventType.tunnelCreated:
        return WebhookTrigger.tunnelCreated;
      case DaemonEventType.tunnelDeleted:
        return WebhookTrigger.tunnelDeleted;
      case DaemonEventType.daemonStarted:
        return WebhookTrigger.daemonStarted;
      case DaemonEventType.daemonStopping:
        return WebhookTrigger.daemonStopping;
      case DaemonEventType.rateAlert:
        return WebhookTrigger.rateAlert;
    }
  }

  Future<void> _executeWebhook(WebhookConfig webhook, DaemonEvent event, WebhookTrigger trigger) async {
    final startTime = DateTime.now();
    final logId = const Uuid().v4();
    final maxRetries = webhook.maxRetries;
    
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      final attemptStart = DateTime.now();
      try {
        switch (webhook.type) {
          case WebhookType.http:
            await _executeHttpWebhook(webhook, event, trigger, logId, startTime);
            break;
          case WebhookType.slack:
            await _executeSlackWebhook(webhook, event, trigger, logId, startTime);
            break;
          case WebhookType.discord:
            await _executeDiscordWebhook(webhook, event, trigger, logId, startTime);
            break;
          case WebhookType.telegram:
            await _executeTelegramWebhook(webhook, event, trigger, logId, startTime);
            break;
        }
        return;
      } catch (e) {
        if (attempt < maxRetries) {
          _debugLog('[retry ${attempt + 1}/$maxRetries] ${webhook.name}: $e');
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        await _addLog(WebhookLog(
          id: logId,
          webhookId: webhook.id,
          webhookName: webhook.name,
          trigger: trigger,
          status: WebhookLogStatus.failed,
          error: '$e (after $maxRetries retries)',
          durationMs: DateTime.now().difference(startTime).inMilliseconds,
        ));
      }
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

  int _discordColor(DaemonEventType type) {
    switch (type) {
      case DaemonEventType.tunnelStarted:
      case DaemonEventType.tunnelCreated:
      case DaemonEventType.daemonStarted:
        return 65280; // green
      case DaemonEventType.tunnelStopped:
      case DaemonEventType.tunnelDeleted:
      case DaemonEventType.tunnelCrashed:
        return 16711680; // red
      case DaemonEventType.tunnelReconnected:
      case DaemonEventType.daemonStopping:
      case DaemonEventType.rateAlert:
        return 16753920; // orange
    }
  }

  Future<void> _executeDiscordWebhook(
    WebhookConfig webhook,
    DaemonEvent event,
    WebhookTrigger trigger,
    String logId,
    DateTime startTime,
  ) async {
    final webhookUrl = webhook.webhookUrl;
    if (webhookUrl == null || webhookUrl.isEmpty) {
      _debugLog('Discord webhook missing URL');
      await _addLog(WebhookLog(
        id: logId,
        webhookId: webhook.id,
        webhookName: webhook.name,
        trigger: trigger,
        status: WebhookLogStatus.failed,
        error: 'Missing webhook URL',
      ));
      return;
    }

    final fields = <Map<String, dynamic>>[];
    if (event.tunnelId != null && event.tunnelId!.isNotEmpty) {
      fields.add({'name': 'Tunnel ID', 'value': event.tunnelId, 'inline': true});
    }
    if (event.hostname != null && event.hostname!.isNotEmpty) {
      fields.add({'name': 'Hostname', 'value': event.hostname, 'inline': true});
    }
    if (event.port != null) {
      fields.add({'name': 'Port', 'value': event.port.toString(), 'inline': true});
    }
    if (event.reason != null && event.reason!.isNotEmpty) {
      fields.add({'name': 'Reason', 'value': event.reason, 'inline': false});
    }
    if (event.error != null && event.error!.isNotEmpty) {
      fields.add({'name': 'Error', 'value': event.error, 'inline': false});
    }

    final body = json.encode({
      'username': 'Cloudflare Manager',
      'embeds': [
        {
          'title': _discordTitle(event),
          'description': _discordDescription(event),
          'color': _discordColor(event.type),
          'fields': fields,
          'timestamp': event.timestamp.toIso8601String(),
          'footer': {'text': 'Cloudflare Tunnel Manager'},
        }
      ],
    });

    try {
      final response = await http.post(
        Uri.parse(webhookUrl),
        headers: {'Content-Type': 'application/json'},
        body: body,
      ).timeout(const Duration(seconds: 10));

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

  Future<void> _executeTelegramWebhook(
    WebhookConfig webhook,
    DaemonEvent event,
    WebhookTrigger trigger,
    String logId,
    DateTime startTime,
  ) async {
    final botToken = webhook.botToken;
    final chatId = webhook.channelId;
    if (botToken == null || botToken.isEmpty || chatId == null || chatId.isEmpty) {
      _debugLog('Telegram webhook missing bot token or chat ID');
      await _addLog(WebhookLog(
        id: logId,
        webhookId: webhook.id,
        webhookName: webhook.name,
        trigger: trigger,
        status: WebhookLogStatus.failed,
        error: 'Missing bot token or chat ID',
      ));
      return;
    }

    final text = _telegramText(event);

    final body = json.encode({
      'chat_id': chatId,
      'text': text,
      'parse_mode': 'HTML',
    });

    try {
      final response = await http.post(
        Uri.parse('https://api.telegram.org/bot$botToken/sendMessage'),
        headers: {'Content-Type': 'application/json'},
        body: body,
      ).timeout(const Duration(seconds: 10));

      final duration = DateTime.now().difference(startTime).inMilliseconds;
      final result = json.decode(response.body) as Map<String, dynamic>;
      final success = result['ok'] == true;

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

  String _telegramText(DaemonEvent event) {
    final buf = StringBuffer();
    final emoji = _telegramEmoji(event.type);
    buf.writeln('$emoji <b>${_discordTitle(event)}</b>');
    buf.writeln();
    buf.writeln(_discordDescription(event));
    if (event.tunnelId != null && event.tunnelId!.isNotEmpty) {
      buf.writeln('<b>Tunnel ID:</b> <code>${event.tunnelId}</code>');
    }
    if (event.hostname != null && event.hostname!.isNotEmpty) {
      buf.writeln('<b>Hostname:</b> ${event.hostname}');
    }
    if (event.port != null) {
      buf.writeln('<b>Port:</b> ${event.port}');
    }
    if (event.reason != null && event.reason!.isNotEmpty) {
      buf.writeln('<b>Reason:</b> ${event.reason}');
    }
    if (event.error != null && event.error!.isNotEmpty) {
      buf.writeln('<b>Error:</b> <code>${event.error}</code>');
    }
    buf.writeln();
    buf.writeln('<i>${event.timestamp.toIso8601String()}</i>');
    return buf.toString();
  }

  String _telegramEmoji(DaemonEventType type) {
    switch (type) {
      case DaemonEventType.tunnelStarted:
      case DaemonEventType.tunnelCreated:
      case DaemonEventType.daemonStarted:
        return '\u2705'; // ✅
      case DaemonEventType.tunnelStopped:
      case DaemonEventType.tunnelDeleted:
        return '\u274C'; // ❌
      case DaemonEventType.tunnelCrashed:
        return '\u26A0\uFE0F'; // ⚠️
      case DaemonEventType.tunnelReconnected:
        return '\u267B'; // ♻️
      case DaemonEventType.daemonStopping:
        return '\u23F9\uFE0F'; // ⏹️
      case DaemonEventType.rateAlert:
        return '\u26A0\uFE0F'; // ⚠️
    }
  }

  Future<void> _executeSlackWebhook(
    WebhookConfig webhook,
    DaemonEvent event,
    WebhookTrigger trigger,
    String logId,
    DateTime startTime,
  ) async {
    final webhookUrl = webhook.webhookUrl;
    if (webhookUrl == null || webhookUrl.isEmpty) {
      await _addLog(WebhookLog(
        id: logId, webhookId: webhook.id, webhookName: webhook.name,
        trigger: trigger, status: WebhookLogStatus.failed, error: 'Missing webhook URL',
      ));
      return;
    }

    final fields = <Map<String, dynamic>>[];
    if (event.tunnelId != null && event.tunnelId!.isNotEmpty) {
      fields.add({'title': 'Tunnel ID', 'value': event.tunnelId, 'short': true});
    }
    if (event.hostname != null && event.hostname!.isNotEmpty) {
      fields.add({'title': 'Hostname', 'value': event.hostname, 'short': true});
    }
    if (event.port != null) {
      fields.add({'title': 'Port', 'value': event.port.toString(), 'short': true});
    }
    if (event.reason != null && event.reason!.isNotEmpty) {
      fields.add({'title': 'Reason', 'value': event.reason, 'short': false});
    }
    if (event.error != null && event.error!.isNotEmpty) {
      fields.add({'title': 'Error', 'value': event.error, 'short': false});
    }

    final body = json.encode({
      'text': 'Cloudflare Manager',
      'attachments': [
        {
          'color': _slackColor(event.type),
          'title': _discordTitle(event),
          'text': _discordDescription(event),
          if (fields.isNotEmpty) 'fields': fields,
          'footer': 'Cloudflare Tunnel Manager',
          'ts': (event.timestamp.millisecondsSinceEpoch / 1000).floor(),
        }
      ],
    });

    try {
      final response = await http.post(
        Uri.parse(webhookUrl),
        headers: {'Content-Type': 'application/json'},
        body: body,
      ).timeout(const Duration(seconds: 10));

      final duration = DateTime.now().difference(startTime).inMilliseconds;
      final success = response.statusCode >= 200 && response.statusCode < 300;

      await _addLog(WebhookLog(
        id: logId, webhookId: webhook.id, webhookName: webhook.name,
        trigger: trigger,
        status: success ? WebhookLogStatus.success : WebhookLogStatus.failed,
        statusCode: response.statusCode,
        response: response.body.length > 500 ? '${response.body.substring(0, 500)}...' : response.body,
        durationMs: duration,
      ));
    } catch (e) {
      final duration = DateTime.now().difference(startTime).inMilliseconds;
      await _addLog(WebhookLog(
        id: logId, webhookId: webhook.id, webhookName: webhook.name,
        trigger: trigger, status: WebhookLogStatus.failed,
        error: e.toString(), durationMs: duration,
      ));
    }
  }

  String _slackColor(DaemonEventType type) {
    switch (type) {
      case DaemonEventType.tunnelStarted:
      case DaemonEventType.tunnelCreated:
      case DaemonEventType.daemonStarted:
        return 'good';
      case DaemonEventType.tunnelStopped:
      case DaemonEventType.tunnelDeleted:
      case DaemonEventType.tunnelCrashed:
        return 'danger';
      case DaemonEventType.tunnelReconnected:
      case DaemonEventType.daemonStopping:
      case DaemonEventType.rateAlert:
        return 'warning';
    }
  }

  String _discordTitle(DaemonEvent event) {
    switch (event.type) {
      case DaemonEventType.tunnelStarted: return 'Tunnel Started';
      case DaemonEventType.tunnelStopped: return 'Tunnel Stopped';
      case DaemonEventType.tunnelCrashed: return 'Tunnel Crashed';
      case DaemonEventType.tunnelReconnected: return 'Tunnel Reconnected';
      case DaemonEventType.tunnelCreated: return 'Tunnel Created';
      case DaemonEventType.tunnelDeleted: return 'Tunnel Deleted';
      case DaemonEventType.daemonStarted: return 'Daemon Started';
      case DaemonEventType.daemonStopping: return 'Daemon Stopping';
      case DaemonEventType.rateAlert: return 'Rate Alert';
    }
  }

  String _discordDescription(DaemonEvent event) {
    final host = event.hostname?.isNotEmpty == true ? ' (${event.hostname})' : '';
    final port = event.port != null ? ' on port ${event.port}' : '';
    switch (event.type) {
      case DaemonEventType.tunnelStarted:
        return 'Tunnel${event.tunnelId != null ? " ${event.tunnelId}" : ""}$host is now running$port';
      case DaemonEventType.tunnelStopped:
        return 'Tunnel${event.tunnelId != null ? " ${event.tunnelId}" : ""}$host has been stopped';
      case DaemonEventType.tunnelCrashed:
        return 'Tunnel${event.tunnelId != null ? " ${event.tunnelId}" : ""}$host crashed: ${event.reason ?? ""}';
      case DaemonEventType.tunnelReconnected:
        return 'Tunnel${event.tunnelId != null ? " ${event.tunnelId}" : ""}$host reconnected';
      case DaemonEventType.tunnelCreated:
        return 'New tunnel${event.tunnelId != null ? " ${event.tunnelId}" : ""} created$host$port';
      case DaemonEventType.tunnelDeleted:
        return 'Tunnel${event.tunnelId != null ? " ${event.tunnelId}" : ""}$host deleted';
      case DaemonEventType.daemonStarted:
        return 'Cloudflare daemon started';
      case DaemonEventType.daemonStopping:
        return 'Cloudflare daemon is stopping';
      case DaemonEventType.rateAlert:
        return event.reason ?? 'Rate threshold exceeded';
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
          await _executeSlackWebhook(webhook, testEvent, WebhookTrigger.tunnelStarted, logId, startTime);
          return true;
        case WebhookType.discord:
          await _executeDiscordWebhook(webhook, testEvent, WebhookTrigger.tunnelStarted, logId, startTime);
          return true;
        case WebhookType.telegram:
          await _executeTelegramWebhook(webhook, testEvent, WebhookTrigger.tunnelStarted, logId, startTime);
          return true;
      }
    } catch (e) {
      _debugLog('Test failed: $e');
      return false;
    }
  }
}
