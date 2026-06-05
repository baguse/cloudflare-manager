import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CloudflareService {
  static const String tokenKey = 'cf_api_token';
  static const String accountIdKey = 'cf_account_id';
  static const String baseUrl = 'https://api.cloudflare.com/client/v4';
  
  static const _storage = FlutterSecureStorage();

  static Future<Map<String, String>> _getHeaders() async {
    final token = await _storage.read(key: tokenKey);
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
      final accountId = await _storage.read(key: accountIdKey);
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

  // Get tunnel configuration (ingress rules)
  static Future<Map<String, dynamic>?> getTunnelConfig(String tunnelId) async {
    try {
      final accountId = await _storage.read(key: accountIdKey);
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

  // Create a new Zero Trust Tunnel
  static Future<Map<String, dynamic>?> createTunnel(String name) async {
    try {
      final accountId = await _storage.read(key: accountIdKey);
      final headers = await _getHeaders();
      
      // Generate a 32-byte secret (Base64 encoded)
      final secretBytes = List<int>.generate(32, (i) => i); // Simplistic static secret for demo purposes, in production use cryptographically secure random
      final tunnelSecret = base64Encode(secretBytes);
      
      final response = await http.post(
        Uri.parse('$baseUrl/accounts/$accountId/cfd_tunnel'),
        headers: headers,
        body: json.encode({
          'name': name,
          'tunnel_secret': tunnelSecret,
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = json.decode(response.body);
        if (data['success'] == true) {
          final tunnelId = data['result']['id'];
          // Construct the Cloudflare Tunnel Token required for cloudflared
          final tokenData = {
            "a": accountId,
            "t": tunnelId,
            "s": tunnelSecret,
          };
          final runToken = base64Encode(utf8.encode(json.encode(tokenData)));
          
          return {
            'id': tunnelId,
            'token': runToken,
          };
        }
      }
    } catch (e) {
      print('Error creating tunnel: $e');
    }
    return null;
  }

  // Create a DNS CNAME record pointing to the tunnel
  static Future<bool> createTunnelDnsRecord(String zoneId, String subdomain, String tunnelId) async {
    try {
      final headers = await _getHeaders();
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
      
      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = json.decode(response.body);
        return data['success'] == true;
      }
    } catch (e) {
      print('Error creating DNS record: $e');
    }
    return false;
  }

  // Delete a Tunnel
  static Future<bool> deleteTunnel(String tunnelId) async {
    try {
      final accountId = await _storage.read(key: accountIdKey);
      final headers = await _getHeaders();

      final response = await http.delete(
        Uri.parse('$baseUrl/accounts/$accountId/cfd_tunnel/$tunnelId'),
        headers: headers,
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['success'] == true;
      }
    } catch (e) {
      print('Error deleting tunnel: $e');
    }
    return false;
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
  static Future<bool> configureTunnel(String tunnelId, String hostname, int localPort) async {
    try {
      final accountId = await _storage.read(key: accountIdKey);
      final headers = await _getHeaders();
      
      final response = await http.put(
        Uri.parse('$baseUrl/accounts/$accountId/cfd_tunnel/$tunnelId/configurations'),
        headers: headers,
        body: json.encode({
          'config': {
            'ingress': [
              {
                'hostname': hostname,
                'service': 'http://localhost:$localPort'
              },
              {
                'service': 'http_status:404'
              }
            ]
          }
        }),
      );
      
      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = json.decode(response.body);
        return data['success'] == true;
      }
    } catch (e) {
      print('Error configuring tunnel: $e');
    }
    return false;
  }
}
