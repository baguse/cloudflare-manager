import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'rate_alert.dart';
import 'cloudflare_service.dart';
import 'webhook_service.dart';
import 'daemon/events.dart';

class RateAlertService {
  static final instance = RateAlertService._();
  RateAlertService._();

  final List<RateAlertConfig> _alerts = [];
  Timer? _checkTimer;
  static const _checkInterval = Duration(minutes: 15);

  static File _getFile() {
    final home = Platform.environment['HOME'] ?? '/tmp';
    return File('$home/.cloudflared/rate-alerts.json');
  }

  Future<void> loadAlerts() async {
    try {
      final file = _getFile();
      if (!await file.exists()) {
        _alerts.clear();
        return;
      }
      final content = await file.readAsString();
      final data = json.decode(content) as List;
      _alerts.clear();
      _alerts.addAll(data.map((a) => RateAlertConfig.fromJson(a as Map<String, dynamic>)));
    } catch (_) {
      _alerts.clear();
    }
  }

  Future<void> saveAlerts() async {
    try {
      final file = _getFile();
      await file.parent.create(recursive: true);
      final data = _alerts.map((a) => a.toJson()).toList();
      await file.writeAsString(json.encode(data));
    } catch (_) {}
  }

  List<RateAlertConfig> get alerts => List.unmodifiable(_alerts);

  Future<void> addAlert(RateAlertConfig alert) async {
    _alerts.add(alert);
    await saveAlerts();
    _ensureChecker();
  }

  Future<void> updateAlert(RateAlertConfig alert) async {
    final idx = _alerts.indexWhere((a) => a.id == alert.id);
    if (idx >= 0) {
      _alerts[idx] = alert;
      await saveAlerts();
      _ensureChecker();
    }
  }

  Future<void> deleteAlert(String id) async {
    _alerts.removeWhere((a) => a.id == id);
    await saveAlerts();
  }

  void startChecker() {
    _checkTimer?.cancel();
    _checkTimer = Timer.periodic(_checkInterval, (_) => checkNow());
  }

  void _ensureChecker() {
    if (_alerts.any((a) => a.enabled) && (_checkTimer == null || !_checkTimer!.isActive)) {
      startChecker();
    }
  }

  Future<Map<String, int?>> checkNow() async {
    final enabled = _alerts.where((a) => a.enabled).toList();
    final results = <String, int?>{};
    if (enabled.isEmpty) return results;

    final zones = await CloudflareService.getZones();

    for (final alert in enabled) {
      try {
        final zoneId = _findZoneId(alert.domain, zones);
        if (zoneId == null) {
          results[alert.name] = null;
          continue;
        }
        final count = await CloudflareService.fetchHourlyRequestCount(zoneId, alert.domain);
        results[alert.name] = count;

        final updated = alert.copyWith(lastCheckedAt: DateTime.now(), lastRequestCount: count);
        final idx = _alerts.indexWhere((a) => a.id == alert.id);
        if (idx >= 0) _alerts[idx] = updated;

        if (count != null && count > alert.thresholdPerHour) {
          await _fireAlert(alert, count);
        }
      } catch (_) {
        results[alert.name] = null;
      }
    }

    await saveAlerts();
    return results;
  }

  String? _findZoneId(String domain, List<Map<String, dynamic>> zones) {
    for (final zone in zones) {
      final zoneName = zone['name'] as String?;
      if (zoneName != null && domain.endsWith(zoneName)) {
        return zone['id'] as String?;
      }
    }
    return null;
  }

  String _formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return n.toString();
  }

  Future<void> _fireAlert(RateAlertConfig alert, int currentCount) async {
    await WebhookService.instance.loadWebhooks();
    final webhook = WebhookService.instance.webhooks
        .where((w) => w.id == alert.webhookId && w.enabled)
        .firstOrNull;
    if (webhook == null) return;

    await WebhookService.instance.triggerWebhooks(DaemonEvent(
      type: DaemonEventType.rateAlert,
      tunnelId: alert.domain,
      hostname: alert.domain,
      reason: '${_formatCount(currentCount)} requests/hour exceeds threshold of ${_formatCount(alert.thresholdPerHour)}',
    ));
  }

  void dispose() {
    _checkTimer?.cancel();
  }
}
