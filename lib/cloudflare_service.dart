import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'app_storage.dart';

const _debugPrint = !bool.fromEnvironment('dart.vm.product');

void _analyticsLog(String msg) {
  if (_debugPrint) print(msg);
}

class CloudflareService {
  static const String tokenKey = 'cf_api_token';
  static const String accountIdKey = 'cf_account_id';
  static const String baseUrl = 'https://api.cloudflare.com/client/v4';

  static Future<Map<String, String>> _getHeaders() async {
    final token = await AppStorage.instance.read(key: tokenKey);
    return {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
  }

  static Future<String?> verifyToken() async {
    try {
      final headers = await _getHeaders();
      if (!headers.containsKey('Authorization') || headers['Authorization'] == 'Bearer null') {
        return 'Token is empty.';
      }
      
      final response = await http.get(
        Uri.parse('$baseUrl/user/tokens/verify'),
        headers: headers,
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['success'] == true) {
           return null; // Success
        } else {
           return data['errors']?.first['message'] ?? 'Unknown API error';
        }
      } else {
        return 'API returned status code: ${response.statusCode} - ${response.body}';
      }
    } catch (e) {
      return 'Network Error: $e';
    }
  }

  // Fetch all zones (domains) associated with the account
  static Future<List<Map<String, dynamic>>> getZones() async {
    try {
      final headers = await _getHeaders();
      final response = await http.get(
        Uri.parse('$baseUrl/zones'),
        headers: headers,
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['success'] == true) {
          return List<Map<String, dynamic>>.from(data['result']);
        }
      }
    } catch (e) {
      print('Error getting zones: $e');
    }
    return [];
  }

  static Future<List<Map<String, dynamic>>> listDnsRecords(String zoneId) async {
    try {
      final headers = await _getHeaders();
      final response = await http.get(
        Uri.parse('$baseUrl/zones/$zoneId/dns_records?per_page=100'),
        headers: headers,
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['success'] == true) {
          return List<Map<String, dynamic>>.from(data['result']);
        }
      }
    } catch (e) {
      print('Error listing DNS records: $e');
    }
    return [];
  }

  /// List DNS records matching a specific name (FQDN or root domain) in a zone.
  static Future<List<Map<String, dynamic>>> getDnsRecordsForName(String zoneId, String name) async {
    try {
      final headers = await _getHeaders();
      final response = await http.get(
        Uri.parse('$baseUrl/zones/$zoneId/dns_records?name=${Uri.encodeComponent(name)}'),
        headers: headers,
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['success'] == true) {
          return List<Map<String, dynamic>>.from(data['result'] ?? []);
        }
      }
    } catch (e) {
      print('Error getting DNS records for name $name: $e');
    }
    return [];
  }

  /// Check if root domain or any hostname has existing DNS records, especially conflicting ones (A, AAAA, CNAME).
  static Future<Map<String, dynamic>> checkHostnameDns(String zoneId, String hostname) async {
    final records = await getDnsRecordsForName(zoneId, hostname);
    final conflicts = records.where((r) {
      final t = (r['type'] as String?)?.toUpperCase();
      return t == 'A' || t == 'AAAA' || t == 'CNAME';
    }).toList();
    return {
      'exists': records.isNotEmpty,
      'hasConflict': conflicts.isNotEmpty,
      'records': records,
      'conflicts': conflicts,
    };
  }

  static Future<bool> createDnsRecord(
    String zoneId, {
    required String type,
    required String name,
    required String content,
    int ttl = 1,
    bool? proxied,
    int? priority,
  }) async {
    try {
      final headers = await _getHeaders();
      final body = <String, dynamic>{
        'type': type,
        'name': name,
        'content': content,
        'ttl': ttl,
      };
      if (proxied != null && (type == 'A' || type == 'AAAA' || type == 'CNAME')) {
        body['proxied'] = proxied;
      }
      if (priority != null && type == 'MX') {
        body['priority'] = priority;
      }
      final response = await http.post(
        Uri.parse('$baseUrl/zones/$zoneId/dns_records'),
        headers: headers,
        body: json.encode(body),
      );
      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = json.decode(response.body);
        return data['success'] == true;
      }
    } catch (e) {
      print('Error creating DNS record: $e');
    }
    return false;
  }

  static Future<bool> updateDnsRecord(
    String zoneId,
    String recordId, {
    String? type,
    String? name,
    String? content,
    int? ttl,
    bool? proxied,
    int? priority,
  }) async {
    try {
      final headers = await _getHeaders();
      final body = <String, dynamic>{};
      if (type != null) body['type'] = type;
      if (name != null) body['name'] = name;
      if (content != null) body['content'] = content;
      if (ttl != null) body['ttl'] = ttl;
      if (proxied != null) body['proxied'] = proxied;
      if (priority != null) body['priority'] = priority;
      final response = await http.put(
        Uri.parse('$baseUrl/zones/$zoneId/dns_records/$recordId'),
        headers: headers,
        body: json.encode(body),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['success'] == true;
      }
    } catch (e) {
      print('Error updating DNS record: $e');
    }
    return false;
  }

  static Future<bool> deleteDnsRecord(String zoneId, String recordId) async {
    try {
      final headers = await _getHeaders();
      final response = await http.delete(
        Uri.parse('$baseUrl/zones/$zoneId/dns_records/$recordId'),
        headers: headers,
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['success'] == true;
      }
    } catch (e) {
      print('Error deleting DNS record: $e');
    }
    return false;
  }

  // List all tunnels for the account
  static Future<List<Map<String, dynamic>>> listTunnels() async {
    try {
      final accountId = await AppStorage.instance.read(key: accountIdKey);
      final headers = await _getHeaders();
      
      final response = await http.get(
        Uri.parse('$baseUrl/accounts/$accountId/cfd_tunnel'),
        headers: headers,
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['success'] == true) {
          return List<Map<String, dynamic>>.from(data['result']);
        }
      }
    } catch (e) {
      print('Error listing tunnels: $e');
    }
    return [];
  }

  // Fetch hostname/service from ingress config for all tunnels
  static Future<Map<String, Map<String, String>>> fetchAllTunnelConfigs() async {
    final result = <String, Map<String, String>>{};
    final tunnels = await listTunnels();
    for (final t in tunnels) {
      final id = t['id'] as String? ?? '';
      final cfg = await getTunnelConfig(id);
      if (cfg != null) {
        final ingress = cfg['config']?['ingress'] as List?;
        if (ingress != null && ingress.isNotEmpty) {
          final first = ingress.first as Map<String, dynamic>;
          result[id] = {'hostname': first['hostname'] ?? '', 'service': first['service'] ?? ''};
        }
      }
    }
    return result;
  }

  // Get tunnel configuration (ingress rules)
  static Future<Map<String, dynamic>?> getTunnelConfig(String tunnelId) async {
    try {
      final accountId = await AppStorage.instance.read(key: accountIdKey);
      final headers = await _getHeaders();
      
      final response = await http.get(
        Uri.parse('$baseUrl/accounts/$accountId/cfd_tunnel/$tunnelId/configurations'),
        headers: headers,
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['success'] == true) {
          return data['result'] as Map<String, dynamic>;
        }
      }
    } catch (e) {
      print('Error getting tunnel config: $e');
    }
    return null;
  }

  static String _extractErrorMessage(Map<String, dynamic> data, {int? statusCode}) {
    final errorList = data['errors'] as List?;
    if (errorList != null && errorList.isNotEmpty) {
      final err = errorList.first;
      final msg = err is Map ? (err['message'] ?? err.toString()) : err.toString();
      final code = err is Map ? err['code'] : null;
      if (code == 10000 || msg.toString().toLowerCase().contains('authentication error')) {
        return 'Cloudflare Permission Denied (Error 10000): The saved API token is valid, but it does NOT have the "Account > Cloudflare Tunnel > Edit" permission. In Cloudflare Dashboard, edit this token and add permission: "Account" -> "Cloudflare Tunnel" -> "Edit".';
      }
      return 'Cloudflare error ($code): $msg';
    }
    final messageList = data['messages'] as List?;
    if (messageList != null && messageList.isNotEmpty) {
      return messageList.join(', ');
    }
    if (statusCode != null) {
      return 'Cloudflare returned HTTP $statusCode';
    }
    return 'Unknown Cloudflare API error';
  }

  static Future<Map<String, dynamic>> verifyCredentials() async {
    final token = await AppStorage.instance.read(key: tokenKey);
    final accountId = await AppStorage.instance.read(key: accountIdKey);
    if (token == null || token.trim().isEmpty) {
      return {'ok': false, 'error': 'No Cloudflare API Token saved in settings.'};
    }
    if (accountId == null || accountId.trim().isEmpty) {
      return {'ok': false, 'error': 'No Cloudflare Account ID saved in settings.'};
    }

    try {
      final headers = await _getHeaders();
      final response = await http.get(
        Uri.parse('$baseUrl/zones'),
        headers: headers,
      );

      final data = json.decode(response.body);
      if (response.statusCode != 200 || data['success'] != true) {
        return {'ok': false, 'error': _extractErrorMessage(data, statusCode: response.statusCode)};
      }

      final zones = (data['result'] as List?) ?? [];
      final permissions = zones.isNotEmpty && zones.first['permissions'] is List
          ? (zones.first['permissions'] as List).cast<String>()
          : <String>[];

      // Test account tunnel access
      final tunnelResp = await http.get(
        Uri.parse('$baseUrl/accounts/$accountId/cfd_tunnel'),
        headers: headers,
      );
      final tunnelData = json.decode(tunnelResp.body);
      if (tunnelResp.statusCode != 200 || tunnelData['success'] != true) {
        return {
          'ok': false,
          'error': 'Account ID or Tunnel access error: ${_extractErrorMessage(tunnelData, statusCode: tunnelResp.statusCode)}',
        };
      }

      return {
        'ok': true,
        'tokenPrefix': token.length > 8 ? '${token.substring(0, 8)}...' : token,
        'accountId': accountId,
        'zoneCount': zones.length,
        'zones': zones.map((z) => z['name']).toList(),
        'permissions': permissions,
      };
    } catch (e) {
      return {'ok': false, 'error': 'Network or connection error: $e'};
    }
  }

  // Create a new Zero Trust Tunnel with full result details
  static Future<Map<String, dynamic>> createTunnelResult(String name) async {
    try {
      final accountId = await AppStorage.instance.read(key: accountIdKey);
      final headers = await _getHeaders();
      
      // Generate a 32-byte secret (Base64 encoded)
      final secretBytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
      final tunnelSecret = base64Encode(secretBytes);
      
      final response = await http.post(
        Uri.parse('$baseUrl/accounts/$accountId/cfd_tunnel'),
        headers: headers,
        body: json.encode({
          'name': name,
          'tunnel_secret': tunnelSecret,
        }),
      );

      final data = json.decode(response.body);
      if (response.statusCode == 200 || response.statusCode == 201) {
        if (data['success'] == true) {
          final tunnelId = data['result']['id'];
          final tokenData = {
            "a": accountId,
            "t": tunnelId,
            "s": tunnelSecret,
          };
          final runToken = base64Encode(utf8.encode(json.encode(tokenData)));
          
          return {
            'ok': true,
            'id': tunnelId,
            'token': runToken,
          };
        }
      }
      return {'ok': false, 'error': _extractErrorMessage(data, statusCode: response.statusCode)};
    } catch (e) {
      print('Error creating tunnel: $e');
      return {'ok': false, 'error': 'Network or client error: $e'};
    }
  }

  // Create a new Zero Trust Tunnel (backward compatibility)
  static Future<Map<String, dynamic>?> createTunnel(String name) async {
    final res = await createTunnelResult(name);
    if (res['ok'] == true) return res;
    return null;
  }

  // Create a DNS CNAME record pointing to the tunnel with full result details
  static Future<Map<String, dynamic>> createTunnelDnsRecordResult(
    String zoneId,
    String subdomain,
    String tunnelId, {
    bool overwrite = false,
  }) async {
    try {
      final headers = await _getHeaders();

      // If overwrite requested, delete any existing conflicting A, AAAA, or CNAME records for this name first
      if (overwrite) {
        final existing = await getDnsRecordsForName(zoneId, subdomain);
        for (final rec in existing) {
          final t = (rec['type'] as String?)?.toUpperCase();
          if (t == 'A' || t == 'AAAA' || t == 'CNAME') {
            final recId = rec['id'] as String?;
            if (recId != null) {
              await deleteDnsRecord(zoneId, recId);
            }
          }
        }
      }

      final response = await http.post(
        Uri.parse('$baseUrl/zones/$zoneId/dns_records'),
        headers: headers,
        body: json.encode({
          'type': 'CNAME',
          'name': subdomain,
          'content': '$tunnelId.cfargotunnel.com',
          'proxied': true,
          'comment': 'Created by Cloudflare Manager App',
        }),
      );
      
      final data = json.decode(response.body);
      if (response.statusCode == 200 || response.statusCode == 201) {
        if (data['success'] == true) {
          return {'ok': true};
        }
      }
      return {'ok': false, 'error': _extractErrorMessage(data, statusCode: response.statusCode)};
    } catch (e) {
      print('Error creating DNS record: $e');
      return {'ok': false, 'error': 'Error creating DNS record: $e'};
    }
  }

  // Create a DNS CNAME record pointing to the tunnel (backward compatibility)
  static Future<bool> createTunnelDnsRecord(String zoneId, String subdomain, String tunnelId) async {
    final res = await createTunnelDnsRecordResult(zoneId, subdomain, tunnelId);
    return res['ok'] == true;
  }

  // Delete a Tunnel with full result details
  static Future<Map<String, dynamic>> deleteTunnelResult(String tunnelId, {bool cascade = true}) async {
    try {
      final accountId = await AppStorage.instance.read(key: accountIdKey);
      final headers = await _getHeaders();

      final url = cascade
          ? '$baseUrl/accounts/$accountId/cfd_tunnel/$tunnelId?cascade=true'
          : '$baseUrl/accounts/$accountId/cfd_tunnel/$tunnelId';
      final response = await http.delete(
        Uri.parse(url),
        headers: headers,
      );

      final data = json.decode(response.body);
      if (response.statusCode == 200) {
        if (data['success'] == true) {
          return {'ok': true};
        }
      }
      return {'ok': false, 'error': _extractErrorMessage(data, statusCode: response.statusCode)};
    } catch (e) {
      print('Error deleting tunnel: $e');
      return {'ok': false, 'error': 'Error deleting tunnel: $e'};
    }
  }

  // Delete a Tunnel (backward compatibility)
  static Future<bool> deleteTunnel(String tunnelId, {bool cascade = true}) async {
    final res = await deleteTunnelResult(tunnelId, cascade: cascade);
    return res['ok'] == true;
  }

  static Future<bool> deleteTunnelDnsRecords(String tunnelId) async {
    final target = '$tunnelId.cfargotunnel.com';
    bool anyDeleted = false;
    try {
      final headers = await _getHeaders();
      final zones = await getZones();
      for (final zone in zones) {
        final zoneId = zone['id'];
        try {
          final list = await http.get(
            Uri.parse('$baseUrl/zones/$zoneId/dns_records?type=CNAME&content=$target'),
            headers: headers,
          );
          if (list.statusCode != 200) continue;
          final data = json.decode(list.body);
          if (data['success'] != true) continue;
          for (final record in (data['result'] as List)) {
            final recordId = record['id'];
            final del = await http.delete(
              Uri.parse('$baseUrl/zones/$zoneId/dns_records/$recordId'),
              headers: headers,
            );
            if (del.statusCode == 200) {
              final delData = json.decode(del.body);
              if (delData['success'] == true) anyDeleted = true;
            }
          }
        } catch (e) {
          print('Error searching DNS in zone $zoneId: $e');
        }
      }
    } catch (e) {
      print('Error deleting DNS records: $e');
    }
    return anyDeleted;
  }

  // Configure Tunnel Remote Ingress
  static Future<Map<String, dynamic>> configureTunnelResult(
    String tunnelId,
    String hostname,
    int localPort, {
    String protocol = 'http',
  }) async {
    try {
      final accountId = await AppStorage.instance.read(key: accountIdKey);
      final headers = await _getHeaders();
      
      final proto = protocol.toLowerCase().trim().replaceAll('://', '');
      final serviceUrl = '$proto://localhost:$localPort';
      final response = await http.put(
        Uri.parse('$baseUrl/accounts/$accountId/cfd_tunnel/$tunnelId/configurations'),
        headers: headers,
        body: json.encode({
          'config': {
            'ingress': [
              {
                'hostname': hostname,
                'service': serviceUrl,
                if (proto == 'https') 'originRequest': {'noTLSVerify': true},
              },
              {
                'service': 'http_status:404'
              }
            ]
          }
        }),
      );
      
      final data = json.decode(response.body);
      if (response.statusCode == 200 || response.statusCode == 201) {
        if (data['success'] == true) {
          return {'ok': true};
        }
      }
      return {'ok': false, 'error': _extractErrorMessage(data, statusCode: response.statusCode)};
    } catch (e) {
      print('Error configuring tunnel: $e');
      return {'ok': false, 'error': 'Error configuring tunnel: $e'};
    }
  }

  static Future<bool> configureTunnel(String tunnelId, String hostname, int localPort, {String protocol = 'http'}) async {
    final res = await configureTunnelResult(tunnelId, hostname, localPort, protocol: protocol);
    return res['ok'] == true;
  }

  static Future<Map<String, int>> fetchTunnelAnalytics(String zoneId, String hostname, {int daysBack = 30}) async {
    try {
      final headers = await _getHeaders();
      final since = DateTime.now().toUtc().subtract(Duration(days: daysBack)).toIso8601String();
      final query = '''
query {
  viewer {
    zones(filter: { zoneTag: "$zoneId" }) {
      httpRequestsAdaptiveGroups(
        filter: { datetime_gt: "$since", clientRequestHTTPHost: "$hostname" }
        limit: 10000
      ) {
        dimensions { datetime }
        count
      }
    }
  }
}''';

      final resp = await http.post(
        Uri.parse('$baseUrl/graphql'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: json.encode({'query': query}),
      );

      _analyticsLog('[analytics] fetchTunnelAnalytics status: ${resp.statusCode} for $hostname');

      if (resp.statusCode != 200) return {};

      final body = json.decode(resp.body);
      final zones = body?['data']?['viewer']?['zones'] as List?;
      if (zones == null || zones.isEmpty) return {};

      final groups = zones[0]['httpRequestsAdaptiveGroups'] as List?;
      if (groups == null) return {};

      final out = <String, int>{};
      for (final g in groups) {
        final datetime = g['dimensions']?['datetime'] as String?;
        final requests = g['count'] as int?;
        if (datetime != null && requests != null) {
          final date = datetime.substring(0, 10);
          out[date] = (out[date] ?? 0) + requests;
        }
      }
      _analyticsLog('[analytics] fetchTunnelAnalytics $hostname: ${out.length} day(s) of data, total=${out.values.fold(0, (a, b) => a + b)}');
      return out;
    } catch (_) {
      return {};
    }
  }

  static Future<int?> fetchHourlyRequestCount(String zoneId, String hostname) async {
    try {
      final headers = await _getHeaders();
      final since = DateTime.now().toUtc().subtract(const Duration(hours: 2)).toIso8601String();
      final query = '''
query {
  viewer {
    zones(filter: { zoneTag: "$zoneId" }) {
      httpRequestsAdaptiveGroups(
        filter: { datetime_gt: "$since", clientRequestHTTPHost: "$hostname" }
        limit: 10
      ) {
        count
      }
    }
  }
}''';

      final resp = await http.post(
        Uri.parse('$baseUrl/graphql'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: json.encode({'query': query}),
      ).timeout(const Duration(seconds: 15));

      _analyticsLog('[analytics] GraphQL status: ${resp.statusCode}');
      if (resp.body.length > 1000) {
        _analyticsLog('[analytics] GraphQL body: ${resp.body.substring(0, 1000)}...');
      } else {
        _analyticsLog('[analytics] GraphQL body: $resp.body');
      }

      if (resp.statusCode != 200) return null;

      final body = json.decode(resp.body);
      final errors = body?['errors'] as List?;
      if (errors != null && errors.isNotEmpty) {
        _analyticsLog('[analytics] Permission error — API token needs Zone > Analytics > Read permission');
        return null;
      }

      final zones = body?['data']?['viewer']?['zones'] as List?;
      if (zones == null || zones.isEmpty) {
        _analyticsLog('[analytics] No zones for $hostname');
        return null;
      }

      final groups = zones[0]['httpRequestsAdaptiveGroups'] as List?;
      if (groups == null || groups.isEmpty) {
        _analyticsLog('[analytics] No data for $hostname');
        return null;
      }

      final requests = (groups[0]['count'] as int?) ?? 0;
      _analyticsLog('[analytics] $hostname: $requests req/h');
      return requests;
    } catch (_) {
      return null;
    }
  }
}
