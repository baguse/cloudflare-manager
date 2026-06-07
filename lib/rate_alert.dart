import 'dart:convert';

class RateAlertConfig {
  final String id;
  final String name;
  final String domain;
  final int thresholdPerHour;
  final String? webhookId;
  final bool enabled;
  final DateTime? lastTriggeredAt;
  final DateTime? lastCheckedAt;
  final int? lastRequestCount;

  RateAlertConfig({
    required this.id,
    required this.name,
    required this.domain,
    required this.thresholdPerHour,
    this.webhookId,
    this.enabled = true,
    this.lastTriggeredAt,
    this.lastCheckedAt,
    this.lastRequestCount,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'domain': domain,
    'thresholdPerHour': thresholdPerHour,
    if (webhookId != null) 'webhookId': webhookId,
    'enabled': enabled,
    if (lastTriggeredAt != null) 'lastTriggeredAt': lastTriggeredAt!.toIso8601String(),
    if (lastCheckedAt != null) 'lastCheckedAt': lastCheckedAt!.toIso8601String(),
    if (lastRequestCount != null) 'lastRequestCount': lastRequestCount,
  };

  factory RateAlertConfig.fromJson(Map<String, dynamic> json) {
    return RateAlertConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      domain: json['domain'] as String,
      thresholdPerHour: json['thresholdPerHour'] as int,
      webhookId: json['webhookId'] as String?,
      enabled: json['enabled'] as bool? ?? true,
      lastTriggeredAt: json['lastTriggeredAt'] != null
          ? DateTime.tryParse(json['lastTriggeredAt'] as String)
          : null,
      lastCheckedAt: json['lastCheckedAt'] != null
          ? DateTime.tryParse(json['lastCheckedAt'] as String)
          : null,
      lastRequestCount: json['lastRequestCount'] as int?,
    );
  }

  RateAlertConfig copyWith({
    String? id,
    String? name,
    String? domain,
    int? thresholdPerHour,
    String? webhookId,
    bool? enabled,
    DateTime? lastTriggeredAt,
    DateTime? lastCheckedAt,
    int? lastRequestCount,
  }) {
    return RateAlertConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      domain: domain ?? this.domain,
      thresholdPerHour: thresholdPerHour ?? this.thresholdPerHour,
      webhookId: webhookId ?? this.webhookId,
      enabled: enabled ?? this.enabled,
      lastTriggeredAt: lastTriggeredAt ?? this.lastTriggeredAt,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      lastRequestCount: lastRequestCount ?? this.lastRequestCount,
    );
  }

  String toJsonString() => json.encode(toJson());
}
