import 'dart:convert';

enum DaemonEventType {
  tunnelStarted,
  tunnelStopped,
  tunnelCrashed,
  tunnelReconnected,
  tunnelCreated,
  tunnelDeleted,
  daemonStarted,
  daemonStopping,
}

class DaemonEvent {
  final DaemonEventType type;
  final String? tunnelId;
  final String? hostname;
  final int? port;
  final String? reason;
  final String? error;
  final DateTime timestamp;

  DaemonEvent({
    required this.type,
    this.tunnelId,
    this.hostname,
    this.port,
    this.reason,
    this.error,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  String get eventName {
    switch (type) {
      case DaemonEventType.tunnelStarted:
        return 'tunnel.started';
      case DaemonEventType.tunnelStopped:
        return 'tunnel.stopped';
      case DaemonEventType.tunnelCrashed:
        return 'tunnel.crashed';
      case DaemonEventType.tunnelReconnected:
        return 'tunnel.reconnected';
      case DaemonEventType.tunnelCreated:
        return 'tunnel.created';
      case DaemonEventType.tunnelDeleted:
        return 'tunnel.deleted';
      case DaemonEventType.daemonStarted:
        return 'daemon.started';
      case DaemonEventType.daemonStopping:
        return 'daemon.stopping';
    }
  }

  Map<String, dynamic> toJson() => {
    'event': eventName,
    if (tunnelId != null) 'tunnelId': tunnelId,
    if (hostname != null) 'hostname': hostname,
    if (port != null) 'port': port,
    if (reason != null) 'reason': reason,
    if (error != null) 'error': error,
    'timestamp': timestamp.toIso8601String(),
  };

  String toJsonLine() => json.encode(toJson());

  factory DaemonEvent.fromJson(Map<String, dynamic> json) {
    return DaemonEvent(
      type: DaemonEventType.values.firstWhere(
        (e) => e.name == json['event']?.toString().replaceAll('.', ''),
        orElse: () => DaemonEventType.tunnelStopped,
      ),
      tunnelId: json['tunnelId'] as String?,
      hostname: json['hostname'] as String?,
      port: json['port'] as int?,
      reason: json['reason'] as String?,
      error: json['error'] as String?,
      timestamp: json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp'] as String)
          : null,
    );
  }
}
