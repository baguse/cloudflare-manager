import 'dart:convert';

enum WebhookType {
  http,
  slack,
  discord,
  telegram,
}

enum HttpMethod {
  get,
  post,
  put,
  patch,
  delete,
}

enum WebhookTrigger {
  tunnelStarted,
  tunnelStopped,
  tunnelCrashed,
  tunnelReconnected,
  tunnelCreated,
  tunnelDeleted,
  daemonStarted,
  daemonStopping,
  rateAlert,
}

class WebhookConfig {
  final String id;
  final String name;
  final bool enabled;
  final WebhookType type;
  final Set<WebhookTrigger> triggers;
  final int maxRetries;
  
  // HTTP webhook specific
  final String? url;
  final HttpMethod? method;
  final Map<String, String>? headers;
  final String? bodyTemplate;
  
  // Slack/Discord/Telegram specific (for future)
  final String? webhookUrl;
  final String? channelId;
  final String? botToken;

  WebhookConfig({
    required this.id,
    required this.name,
    this.enabled = true,
    required this.type,
    Set<WebhookTrigger>? triggers,
    this.maxRetries = 3,
    this.url,
    this.method,
    this.headers,
    this.bodyTemplate,
    this.webhookUrl,
    this.channelId,
    this.botToken,
  }) : triggers = triggers ?? {};

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'enabled': enabled,
    'type': type.name,
    'triggers': triggers.map((t) => t.name).toList(),
    'maxRetries': maxRetries,
    if (url != null) 'url': url,
    if (method != null) 'method': method!.name,
    if (headers != null) 'headers': headers,
    if (bodyTemplate != null) 'bodyTemplate': bodyTemplate,
    if (webhookUrl != null) 'webhookUrl': webhookUrl,
    if (channelId != null) 'channelId': channelId,
    if (botToken != null) 'botToken': botToken,
  };

  factory WebhookConfig.fromJson(Map<String, dynamic> json) {
    return WebhookConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      enabled: json['enabled'] as bool? ?? true,
      type: WebhookType.values.firstWhere(
        (t) => t.name == json['type'],
        orElse: () => WebhookType.http,
      ),
      triggers: (json['triggers'] as List?)
          ?.map((t) => WebhookTrigger.values.firstWhere(
                (e) => e.name == t,
                orElse: () => WebhookTrigger.tunnelStarted,
              ))
          .toSet() ?? {},
      maxRetries: json['maxRetries'] as int? ?? 3,
      url: json['url'] as String?,
      method: json['method'] != null
          ? HttpMethod.values.firstWhere(
              (m) => m.name == json['method'],
              orElse: () => HttpMethod.post,
            )
          : null,
      headers: json['headers'] != null
          ? Map<String, String>.from(json['headers'] as Map)
          : null,
      bodyTemplate: json['bodyTemplate'] as String?,
      webhookUrl: json['webhookUrl'] as String?,
      channelId: json['channelId'] as String?,
      botToken: json['botToken'] as String?,
    );
  }

  WebhookConfig copyWith({
    String? id,
    String? name,
    bool? enabled,
    WebhookType? type,
    Set<WebhookTrigger>? triggers,
    int? maxRetries,
    String? url,
    HttpMethod? method,
    Map<String, String>? headers,
    String? bodyTemplate,
    String? webhookUrl,
    String? channelId,
    String? botToken,
  }) {
    return WebhookConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      type: type ?? this.type,
      triggers: triggers ?? this.triggers,
      maxRetries: maxRetries ?? this.maxRetries,
      url: url ?? this.url,
      method: method ?? this.method,
      headers: headers ?? this.headers,
      bodyTemplate: bodyTemplate ?? this.bodyTemplate,
      webhookUrl: webhookUrl ?? this.webhookUrl,
      channelId: channelId ?? this.channelId,
      botToken: botToken ?? this.botToken,
    );
  }

  String toJsonString() => json.encode(toJson());
}

enum WebhookLogStatus {
  success,
  failed,
  pending,
}

class WebhookLog {
  final String id;
  final String webhookId;
  final String webhookName;
  final WebhookTrigger trigger;
  final WebhookLogStatus status;
  final int? statusCode;
  final String? response;
  final String? error;
  final DateTime timestamp;
  final int durationMs;

  WebhookLog({
    required this.id,
    required this.webhookId,
    required this.webhookName,
    required this.trigger,
    required this.status,
    this.statusCode,
    this.response,
    this.error,
    this.durationMs = 0,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'webhookId': webhookId,
    'webhookName': webhookName,
    'trigger': trigger.name,
    'status': status.name,
    if (statusCode != null) 'statusCode': statusCode,
    if (response != null) 'response': response,
    if (error != null) 'error': error,
    'durationMs': durationMs,
    'timestamp': timestamp.toIso8601String(),
  };

  factory WebhookLog.fromJson(Map<String, dynamic> json) {
    return WebhookLog(
      id: json['id'] as String,
      webhookId: json['webhookId'] as String,
      webhookName: json['webhookName'] as String,
      trigger: WebhookTrigger.values.firstWhere(
        (t) => t.name == json['trigger'],
        orElse: () => WebhookTrigger.tunnelStarted,
      ),
      status: WebhookLogStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => WebhookLogStatus.failed,
      ),
      statusCode: json['statusCode'] as int?,
      response: json['response'] as String?,
      error: json['error'] as String?,
      durationMs: json['durationMs'] as int? ?? 0,
      timestamp: json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp'] as String)
          : null,
    );
  }
}
