import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

class CfApiClient {
  static const _baseUrl = 'https://api.cloudflare.com/client/v4';

  static Future<String?> getToken() async {
    final f = _tokenFile();
    if (!await f.exists()) return null;
    return (await f.readAsString()).trim();
  }

  static Future<void> setToken(String token) async {
    final f = _tokenFile();
    await f.parent.create(recursive: true);
    await f.writeAsString(token);
  }

  static File _tokenFile() {
    final home = Platform.environment['HOME'] ?? '/tmp';
    return File('$home/.cloudflared/cf-api-token');
  }

  static Future<Map<String, String>> _headers() async {
    final token = await getToken();
    return {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
  }

  static Future<List<Map<String, dynamic>>> getZones() async {
    try {
      final resp = await http.get(
        Uri.parse('$_baseUrl/zones'),
        headers: await _headers(),
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return [];
      final data = json.decode(resp.body);
      return (data['result'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    } catch (_) {
      return [];
    }
  }

  static Future<Map<String, dynamic>?> createTunnel(String name) async {
    try {
      final resp = await http.post(
        Uri.parse('$_baseUrl/accounts/${await accountId()}/cfd_tunnel'),
        headers: await _headers(),
        body: json.encode({'name': name, 'config_src': 'cloudflare'}),
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final data = json.decode(resp.body);
      return data['result'] as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> configureTunnel(String tunnelId, String zoneId, String hostname, int port) async {
    try {
      final resp = await http.put(
        Uri.parse('$_baseUrl/accounts/${await accountId()}/cfd_tunnel/$tunnelId/configurations'),
        headers: await _headers(),
        body: json.encode({
          'config': {
            'ingress': [
              {
                'hostname': hostname,
                'service': 'http://localhost:$port',
                'originRequest': {},
              },
              {'service': 'http_status:404'},
            ],
          },
        }),
      ).timeout(const Duration(seconds: 15));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> createDnsRecord(String zoneId, String name, String tunnelId) async {
    try {
      final resp = await http.post(
        Uri.parse('$_baseUrl/zones/$zoneId/dns_records'),
        headers: await _headers(),
        body: json.encode({
          'type': 'CNAME',
          'name': name,
          'content': '$tunnelId.cfargotunnel.com',
          'proxied': true,
        }),
      ).timeout(const Duration(seconds: 10));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> accountId() async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final f = File('$home/.cloudflared/cf-account-id');
    if (!await f.exists()) return null;
    return (await f.readAsString()).trim();
  }

  static Future<void> setAccountId(String id) async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final f = File('$home/.cloudflared/cf-account-id');
    await f.parent.create(recursive: true);
    await f.writeAsString(id);
  }
}
