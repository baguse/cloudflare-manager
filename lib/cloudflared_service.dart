import 'dart:io';
import 'dart:convert';

class TunnelInfo {
  final int pid;
  final String? tunnelId;
  final int? localPort;
  final String? configPath;
  final String? command;
  final bool isQuickTunnel;

  TunnelInfo({
    required this.pid,
    this.tunnelId,
    this.localPort,
    this.configPath,
    this.command,
    this.isQuickTunnel = false,
  });
}

class CloudflaredService {
  static String _executablePath = 'cloudflared';

  static String _normalizeBase64(String input) {
    return input.padRight((input.length + 3) ~/ 4 * 4, '=');
  }

  static Future<bool> isInstalled() async {
    final List<String> searchPaths = [];

    try {
      final which = await Process.run('which', ['cloudflared']);
      if (which.exitCode == 0 && (which.stdout as String).trim().isNotEmpty) {
        searchPaths.add((which.stdout as String).trim());
      }
    } catch (_) {}

    final home = Platform.environment['HOME'] ?? '';
    searchPaths.addAll([
      'cloudflared',
      '/usr/local/bin/cloudflared',
      '/opt/homebrew/bin/cloudflared',
      '/usr/bin/cloudflared',
      if (home.isNotEmpty) '$home/.cloudflared/cloudflared',
    ]);

    final seen = <String>{};
    for (final path in searchPaths) {
      if (seen.contains(path)) continue;
      seen.add(path);
      try {
        final result = await Process.run(path, ['--version']);
        if (result.exitCode == 0) {
          _executablePath = path;
          return true;
        }
      } catch (_) {}
    }

    for (final path in seen) {
      if (File(path).existsSync()) {
        _executablePath = path;
        return true;
      }
    }

    return false;
  }

  static Future<Set<String>> getRunningTunnelIds() async {
    final tunnels = await getRunningTunnels();
    return tunnels
        .map((t) => t.tunnelId)
        .whereType<String>()
        .toSet();
  }

  static Future<List<TunnelInfo>> getRunningTunnels() async {
    final List<TunnelInfo> tunnels = [];
    try {
      final result = await Process.run('ps', ['aux']);
      if (result.exitCode != 0) return tunnels;

      final lines = (result.stdout as String).split('\n');
      for (final line in lines) {
        if (!line.contains('cloudflared')) continue;
        if (line.contains('grep')) continue;

        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 11) continue;

        final pid = int.tryParse(parts[1]);
        if (pid == null) continue;

        final command = parts.sublist(10).join(' ');
        if (!command.contains('tunnel')) continue;

        int? localPort;
        String? tunnelId;
        String? configPath;
        bool isQuick = false;

        final tokenIndex = command.indexOf('--token');
        if (tokenIndex != -1) {
          final afterToken = command.substring(tokenIndex + '--token'.length).trimLeft();
          final tokenEnd = afterToken.indexOf(RegExp(r'\s'));
          final token = tokenEnd == -1 ? afterToken : afterToken.substring(0, tokenEnd);
          if (token.isNotEmpty) {
            try {
              final decoded = utf8.decode(base64Decode(_normalizeBase64(token)));
              final tokenData = json.decode(decoded);
              final id = tokenData['t'];
              if (id is String) tunnelId = id;
            } catch (e) {
            }
          }
        }

        if (tunnelId == null) {
          final runMatch = RegExp(r'\brun\s+([0-9a-fA-F\-]{36})').firstMatch(command);
          if (runMatch != null) {
            tunnelId = runMatch.group(1);
          }
        }

        if (tunnelId == null) {
          final credsIndex = command.indexOf('--credentials-file');
          if (credsIndex != -1) {
            final after = command.substring(credsIndex + '--credentials-file'.length).trimLeft();
            final end = after.indexOf(RegExp(r'\s'));
            final path = end == -1 ? after : after.substring(0, end);
            if (path.isNotEmpty) {
              try {
                final file = File(path);
                if (await file.exists()) {
                  final data = json.decode(await file.readAsString());
                  final id = data['TunnelID'];
                  if (id is String) tunnelId = id;
                }
              } catch (e) {
              }
            }
          }
        }

        final urlIndex = command.indexOf('--url');
        if (urlIndex != -1) {
          final afterUrl = command.substring(urlIndex + '--url'.length).trimLeft();
          final urlEnd = afterUrl.indexOf(RegExp(r'\s'));
          final url = urlEnd == -1 ? afterUrl : afterUrl.substring(0, urlEnd);
          final portMatch = RegExp(r'localhost:(\d+)').firstMatch(url);
          if (portMatch != null) {
            localPort = int.tryParse(portMatch.group(1) ?? '');
            isQuick = true;
          }
        }

        final configIndex = command.indexOf('--config');
        if (configIndex != -1) {
          final afterConfig = command.substring(configIndex + '--config'.length).trimLeft();
          final configEnd = afterConfig.indexOf(RegExp(r'\s'));
          final path = configEnd == -1 ? afterConfig : afterConfig.substring(0, configEnd);
          if (path.isNotEmpty) configPath = path;
        }

        tunnels.add(TunnelInfo(
          pid: pid,
          tunnelId: tunnelId,
          localPort: localPort,
          configPath: configPath,
          command: command,
          isQuickTunnel: isQuick,
        ));
      }
    } catch (e) {
      print('Error detecting running tunnels: $e');
    }

    return tunnels;
  }

  static Future<Map<int, int>> resolveLocalPorts(List<TunnelInfo> tunnels) async {
    final Map<int, int> resolved = {};
    final appMap = await readAppTunnelPortMap();
    for (final t in tunnels) {
      if (t.localPort != null) {
        resolved[t.pid] = t.localPort!;
        continue;
      }
      if (t.tunnelId != null && appMap[t.tunnelId!] != null) {
        resolved[t.pid] = appMap[t.tunnelId!]!;
        continue;
      }
      final path = t.configPath ?? _defaultConfigPath();
      if (path == null) continue;
      final port = await _readPortFromConfig(path);
      if (port != null) resolved[t.pid] = port;
    }
    return resolved;
  }

  static File? _appTunnelMapFile() {
    final home = Platform.environment['HOME'];
    if (home == null) return null;
    return File('$home/.cloudflared/app-tunnels.json');
  }

  static Future<Map<String, int>> readAppTunnelPortMap() async {
    final file = _appTunnelMapFile();
    if (file == null) return {};
    try {
      if (!await file.exists()) return {};
      final content = await file.readAsString();
      final data = json.decode(content);
      if (data is Map) {
        final out = <String, int>{};
        data.forEach((k, v) {
          if (v is num) {
            out[k.toString()] = v.toInt();
          } else if (v is Map && v['port'] is num) {
            out[k.toString()] = (v['port'] as num).toInt();
          }
        });
        return out;
      }
    } catch (e) {
    }
    return {};
  }

  static Future<String?> readAppTunnelToken(String tunnelId) async {
    final file = _appTunnelMapFile();
    if (file == null) return null;
    try {
      if (!await file.exists()) return null;
      final data = json.decode(await file.readAsString());
      if (data is Map && data[tunnelId] is Map) {
        final token = data[tunnelId]['token'];
        if (token is String) return token;
      }
    } catch (e) {
    }
    return null;
  }

  static Future<Map<String, ({int port, String? token})>> readAppTunnelPortMapFull() async {
    final file = _appTunnelMapFile();
    if (file == null) return {};
    try {
      if (!await file.exists()) return {};
      final data = json.decode(await file.readAsString());
      if (data is Map) {
        final out = <String, ({int port, String? token})>{};
        data.forEach((k, v) {
          if (v is Map && v['port'] is num) {
            out[k.toString()] = (
              port: (v['port'] as num).toInt(),
              token: v['token'] as String?,
            );
          } else if (v is num) {
            out[k.toString()] = (port: v.toInt(), token: null);
          }
        });
        return out;
      }
    } catch (e) {
    }
    return {};
  }

  static Future<void> registerAppTunnel(String tunnelId, int localPort, {String? token, String? hostname}) async {
    if (token != null) {
      await writeCredentialsFile(token);
    }
    final file = _appTunnelMapFile();
    if (file == null) return;
    try {
      final content = await file.exists() ? await file.readAsString() : '{}';
      final data = json.decode(content);
      final map = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
      final existing = map[tunnelId];
      final String? existingNotes = existing is Map ? existing['notes'] as String? : null;
      final String? existingTags = existing is Map ? existing['tags'] as String? : null;
      final String? existingHostname = existing is Map ? existing['hostname'] as String? : null;
      final existingServiceEnabled = existing is Map ? existing['serviceEnabled'] : null;
      map[tunnelId] = {
        'port': localPort,
        if (hostname != null) 'hostname': hostname else if (existingHostname != null) 'hostname': existingHostname,
        if (existingNotes != null) 'notes': existingNotes,
        if (existingTags != null) 'tags': existingTags,
        if (existingServiceEnabled != null) 'serviceEnabled': existingServiceEnabled,
      };
      await file.parent.create(recursive: true);
      await file.writeAsString(json.encode(map));
    } catch (e) {
      print('Error persisting tunnel map: $e');
    }
  }

  static Future<void> saveTunnelNotes(String tunnelId, {String? notes, String? tags}) async {
    final file = _appTunnelMapFile();
    if (file == null) return;
    try {
      final content = await file.exists() ? await file.readAsString() : '{}';
      final data = json.decode(content);
      final map = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
      final existing = map[tunnelId];
      map[tunnelId] = {
        if (existing is Map) ...existing,
        'port': existing is Map && existing['port'] is num ? existing['port'] : (existing is num ? existing : 0),
        if (notes != null) 'notes': notes,
        if (tags != null) 'tags': tags,
      };
      await file.parent.create(recursive: true);
      await file.writeAsString(json.encode(map));
    } catch (e) {
      print('Error saving tunnel notes: $e');
    }
  }

  static Future<({String? notes, String? tags})> readTunnelNotes(String tunnelId) async {
    final file = _appTunnelMapFile();
    if (file == null) return (notes: null, tags: null);
    try {
      if (!await file.exists()) return (notes: null, tags: null);
      final data = json.decode(await file.readAsString());
      if (data is Map) {
        final entry = data[tunnelId];
        if (entry is Map) {
          return (
            notes: entry['notes'] as String?,
            tags: entry['tags'] as String?,
          );
        }
      }
    } catch (e) {
    }
    return (notes: null, tags: null);
  }

  static Future<Map<String, ({String? notes, String? tags})>> readAllTunnelNotes() async {
    final file = _appTunnelMapFile();
    if (file == null) return {};
    try {
      if (!await file.exists()) return {};
      final data = json.decode(await file.readAsString());
      if (data is Map) {
        final out = <String, ({String? notes, String? tags})>{};
        data.forEach((k, v) {
          if (v is Map) {
            out[k.toString()] = (
              notes: v['notes'] as String?,
              tags: v['tags'] as String?,
            );
          }
        });
        return out;
      }
    } catch (e) {
    }
    return {};
  }

  static Future<void> saveServiceEnabled(String tunnelId, bool enabled) async {
    final file = _appTunnelMapFile();
    if (file == null) return;
    try {
      final content = await file.exists() ? await file.readAsString() : '{}';
      final data = json.decode(content);
      final map = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
      final existing = map[tunnelId];
      map[tunnelId] = {
        if (existing is Map) ...existing,
        'serviceEnabled': enabled,
      };
      await file.parent.create(recursive: true);
      await file.writeAsString(json.encode(map));
    } catch (e) {
      print('Error saving service enabled: $e');
    }
  }

  static Future<bool> readServiceEnabled(String tunnelId) async {
    final file = _appTunnelMapFile();
    if (file == null) return false;
    try {
      if (!await file.exists()) return false;
      final data = json.decode(await file.readAsString());
      if (data is Map && data[tunnelId] is Map) {
        return data[tunnelId]['serviceEnabled'] == true;
      }
    } catch (_) {}
    return false;
  }

  static Future<void> unregisterAppTunnel(String tunnelId) async {
    final file = _appTunnelMapFile();
    if (file == null) return;
    try {
      final content = await file.exists() ? await file.readAsString() : '{}';
      final data = json.decode(content);
      if (data is Map) {
        final map = Map<String, dynamic>.from(data);
        if (map.remove(tunnelId) != null) {
          await file.writeAsString(json.encode(map));
        }
      }
    } catch (e) {
    }
  }

  static File? _inspectorConfigFile() {
    final home = Platform.environment['HOME'];
    if (home == null) return null;
    return File('$home/.cloudflared/app-inspector.json');
  }

  static Future<void> saveInspectorConfig(int listenPort, int targetPort) async {
    final file = _inspectorConfigFile();
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(json.encode({'listen': listenPort, 'target': targetPort}));
    } catch (e) {
      print('Error saving inspector config: $e');
    }
  }

  static Future<({int listen, int target})?> readInspectorConfig() async {
    final file = _inspectorConfigFile();
    if (file == null) return null;
    try {
      if (!await file.exists()) return null;
      final data = json.decode(await file.readAsString());
      if (data is Map && data['listen'] is num && data['target'] is num) {
        return (listen: (data['listen'] as num).toInt(), target: (data['target'] as num).toInt());
      }
    } catch (e) {
    }
    return null;
  }

  static Future<void> clearInspectorConfig() async {
    final file = _inspectorConfigFile();
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
    }
  }

  static String? _defaultConfigPath() {
    final home = Platform.environment['HOME'];
    if (home == null) return null;
    return '$home/.cloudflared/config.yml';
  }

  static Future<int?> _readPortFromConfig(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final content = await file.readAsString();

      final lines = content.split('\n');
      bool inIngress = false;
      for (final raw in lines) {
        final line = raw.split('#').first.trimRight();
        if (line.isEmpty) continue;

        final stripped = line.replaceFirst(RegExp(r'^\s+'), '');
        final indent = line.length - stripped.length;

        if (indent == 0) {
          inIngress = stripped.startsWith('ingress:');
          continue;
        }

        if (inIngress) {
          final serviceMatch = RegExp(r'^\s*service:\s*(.+)$').firstMatch(line);
          if (serviceMatch != null) {
            final value = serviceMatch.group(1)!.trim();
            final portMatch = RegExp(r'localhost:(\d+)').firstMatch(value);
            if (portMatch != null) {
              return int.tryParse(portMatch.group(1) ?? '');
            }
          }
        }
      }
    } catch (e) {
    }
    return null;
  }

  static Future<Process> startQuickTunnel(int localPort) async {
    return await Process.start(_executablePath, [
      'tunnel',
      '--url',
      'http://localhost:$localPort'
    ]);
  }

  static String? _credentialsDirPath() {
    final home = Platform.environment['HOME'];
    if (home == null) return null;
    return '$home/.cloudflared';
  }

  static String? _credentialsFilePath(String tunnelId) {
    final dir = _credentialsDirPath();
    if (dir == null) return null;
    return '$dir/$tunnelId.json';
  }

  static Future<String?> writeCredentialsFile(String token) async {
    try {
      final decoded = json.decode(utf8.decode(base64Decode(_normalizeBase64(token))));
      final tunnelId = decoded['t'] as String?;
      final accountId = decoded['a'] as String?;
      final secret = decoded['s'] as String?;
      if (tunnelId == null || accountId == null || secret == null) return null;
      final path = _credentialsFilePath(tunnelId);
      if (path == null) return null;
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(json.encode({
        'AccountTag': accountId,
        'TunnelSecret': secret,
        'TunnelID': tunnelId,
      }));
      try {
        await Process.run('chmod', ['600', file.path]);
      } catch (_) {}
      return tunnelId;
    } catch (e) {
      print('Error writing credentials file: $e');
      return null;
    }
  }

  static Future<void> deleteCredentialsFile(String tunnelId) async {
    final path = _credentialsFilePath(tunnelId);
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
    }
  }

  static Future<Process> startTokenTunnel(String token) async {
    final tunnelId = await writeCredentialsFile(token);
    if (tunnelId != null && tunnelId.isNotEmpty) {
      return await Process.start(_executablePath, [
        'tunnel',
        '--no-autoupdate',
        'run',
        tunnelId,
      ]);
    }
    return await Process.start(_executablePath, [
      'tunnel',
      '--no-autoupdate',
      'run',
      '--token',
      token,
    ]);
  }

  static Future<bool> credentialsFileExists(String tunnelId) async {
    final path = _credentialsFilePath(tunnelId);
    if (path == null) return false;
    return await File(path).exists();
  }

  static Future<Process?> startTunnelById(String tunnelId) async {
    final path = _credentialsFilePath(tunnelId);
    if (path == null) return null;
    if (!await File(path).exists()) return null;
    return await Process.start(_executablePath, [
      'tunnel',
      '--no-autoupdate',
      'run',
      tunnelId,
    ]);
  }

  static Future<void> forceKillPid(int pid) async {
    try {
      Process.killPid(pid);
      await Future.delayed(const Duration(seconds: 2));
      try {
        final check = await Process.run('kill', ['-0', '$pid']);
        if (check.exitCode == 0) {
          Process.killPid(pid, ProcessSignal.sigkill);
        }
      } catch (_) {}
    } catch (_) {}
  }

  static Future<bool> killTunnelById(String tunnelId) async {
    try {
      final result = await Process.run('ps', ['aux']);
      if (result.exitCode != 0) return false;

      final lines = (result.stdout as String).split('\n');
      for (final line in lines) {
        if (!line.contains('cloudflared')) continue;
        if (line.contains('grep')) continue;

        final parts = line.trim().split(RegExp(r'\s+'));
        final pid = parts.length >= 2 ? int.tryParse(parts[1]) : null;
        if (pid == null) continue;

        final command = parts.sublist(10).join(' ');
        bool match = false;

        final tokenIndex = command.indexOf('--token');
        if (tokenIndex != -1) {
          final afterToken = command.substring(tokenIndex + '--token'.length).trimLeft();
          final tokenEnd = afterToken.indexOf(RegExp(r'\s'));
          final token = tokenEnd == -1 ? afterToken : afterToken.substring(0, tokenEnd);
          try {
            final decoded = utf8.decode(base64Decode(_normalizeBase64(token)));
            final tokenData = json.decode(decoded);
            if (tokenData['t'] == tunnelId) match = true;
          } catch (e) {}
        }

        if (!match) {
          final runMatch = RegExp(r'\brun\s+([0-9a-fA-F\-]{36})').firstMatch(command);
          if (runMatch != null && runMatch.group(1) == tunnelId) match = true;
        }

        if (!match) {
          final credsIndex = command.indexOf('--credentials-file');
          if (credsIndex != -1) {
            final after = command.substring(credsIndex + '--credentials-file'.length).trimLeft();
            final end = after.indexOf(RegExp(r'\s'));
            final path = end == -1 ? after : after.substring(0, end);
            try {
              final file = File(path);
              if (await file.exists()) {
                final data = json.decode(await file.readAsString());
                if (data['TunnelID'] == tunnelId) match = true;
              }
            } catch (e) {}
          }
        }

        if (match) {
          await forceKillPid(pid);
          return true;
        }
      }
    } catch (e) {
      print('Error killing tunnel: $e');
    }
    return false;
  }
}
