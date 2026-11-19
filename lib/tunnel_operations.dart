import 'cloudflare_service.dart';
import 'cloudflared_service.dart';
import 'webhook_service.dart';
import 'app_storage.dart';
import 'daemon/events.dart';

typedef IpcCall = Future<Map<String, dynamic>> Function(String cmd, {Map<String, dynamic>? args});

class TunnelOperations {
  /// Create a new tunnel on Cloudflare, configure ingress + DNS, and start it via the daemon.
  static Future<Map<String, dynamic>> quickBind({
    required String token,
    required String accountId,
    required String subdomain,
    required String zoneId,
    required String zoneName,
    required int port,
    required IpcCall ipc,
  }) async {
    final hostname = '$subdomain.$zoneName';

    // Set credentials for CloudflareService
    await AppStorage.instance.write(key: CloudflareService.tokenKey, value: token);
    await AppStorage.instance.write(key: CloudflareService.accountIdKey, value: accountId);

    // 1. Create tunnel on Cloudflare
    final tunnelRes = await CloudflareService.createTunnelResult('tunnel-$subdomain-$port');
    if (tunnelRes['ok'] != true) return {'ok': false, 'error': tunnelRes['error'] ?? 'Failed to create tunnel'};
    final tunnelId = tunnelRes['id'] as String;
    final tunnelToken = tunnelRes['token'] as String?;
    if (tunnelId.isEmpty || tunnelToken == null) return {'ok': false, 'error': 'Invalid tunnel response from Cloudflare'};

    // 2. Configure ingress
    final configRes = await CloudflareService.configureTunnelResult(tunnelId, hostname, port);
    if (configRes['ok'] != true) return {'ok': false, 'error': configRes['error'] ?? 'Failed to configure tunnel routing'};

    // 3. Create DNS record
    final dnsRes = await CloudflareService.createTunnelDnsRecordResult(zoneId, subdomain, tunnelId);
    if (dnsRes['ok'] != true) return {'ok': false, 'error': dnsRes['error'] ?? 'Failed to create DNS record'};

    // 4. Bind via daemon
    final bindResult = await ipc('tunnel_bind', args: {'tunnelId': tunnelId, 'token': tunnelToken, 'hostname': hostname, 'port': port});
    if (bindResult['ok'] != true) return {'ok': false, 'error': 'Tunnel created but daemon bind failed: ${bindResult['error']}'};

    // 5. Register locally
    await CloudflaredService.registerAppTunnel(tunnelId, port, token: tunnelToken, hostname: hostname);

    // 6. Fire webhook
    WebhookService.instance.triggerWebhooks(
      DaemonEvent(type: DaemonEventType.tunnelCreated, tunnelId: tunnelId, hostname: hostname, port: port),
    ).catchError((_) {});

    return {'ok': true, 'tunnelId': tunnelId, 'hostname': hostname, 'url': 'https://$hostname'};
  }

  /// Rebind an existing tunnel — optionally reconfigure Cloudflare if port changed.
  static Future<Map<String, dynamic>> rebind({
    required String tunnelId,
    int? port,
    String? hostname,
    required IpcCall ipc,
  }) async {
    final fullMap = await CloudflaredService.readAppTunnelPortMapFull();
    final cfg = fullMap[tunnelId];
    final storedPort = cfg?.port ?? 0;
    final storedHostname = cfg?.hostname ?? '';
    final effectivePort = port ?? storedPort;
    final effectiveHostname = hostname ?? storedHostname;
    if (effectivePort == 0) return {'ok': false, 'error': 'No port configured'};
    if (effectiveHostname.isEmpty) return {'ok': false, 'error': 'No hostname configured'};

    final hasCreds = await CloudflaredService.credentialsFileExists(tunnelId);
    if (cfg?.token == null && !hasCreds) return {'ok': false, 'error': 'No stored credentials for this tunnel'};

    // Reconfigure Cloudflare if port changed
    if (port != null && port != storedPort) {
      await CloudflareService.configureTunnel(tunnelId, effectiveHostname, effectivePort);
    }

    // Update local storage
    await CloudflaredService.registerAppTunnel(tunnelId, effectivePort, token: cfg?.token, hostname: effectiveHostname);

    // Bind via daemon
    final result = await ipc('tunnel_bind', args: {'tunnelId': tunnelId, 'token': cfg?.token ?? '', 'hostname': effectiveHostname, 'port': effectivePort});
    return result;
  }

  /// Unbind (stop) a tunnel — stops the daemon process but keeps config intact.
  static Future<Map<String, dynamic>> unbind({
    required String tunnelId,
    required IpcCall ipc,
  }) async {
    return await ipc('tunnel_unbind', args: {'tunnelId': tunnelId});
  }

  /// Full delete — stops daemon, cleans up local files, deletes from Cloudflare.
  static Future<Map<String, dynamic>> deleteTunnel({
    required String tunnelId,
    required IpcCall ipc,
  }) async {
    // Stop local process
    await ipc('tunnel_unbind', args: {'tunnelId': tunnelId});
    await CloudflaredService.saveServiceEnabled(tunnelId, false);
    await CloudflaredService.unregisterAppTunnel(tunnelId);
    await CloudflaredService.deleteCredentialsFile(tunnelId);

    // Delete from Cloudflare
    final dnsOk = await CloudflareService.deleteTunnelDnsRecords(tunnelId);
    final tunnelOk = await CloudflareService.deleteTunnel(tunnelId);

    // Fire webhook
    WebhookService.instance.triggerWebhooks(
      DaemonEvent(type: DaemonEventType.tunnelDeleted, tunnelId: tunnelId),
    ).catchError((_) {});

    return {'ok': tunnelOk, 'dnsDeleted': dnsOk};
  }
}
