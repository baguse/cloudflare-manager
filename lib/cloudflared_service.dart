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

  static Future<bool> isInstalled() async {
    final home = Platform.environment['HOME'] ?? '';
    final commonPaths = [
      'cloudflared',
      '/usr/local/bin/cloudflared',
      '/opt/homebrew/bin/cloudflared',
      '/usr/bin/cloudflared',
      if (home.isNotEmpty) '$home/.cloudflared/cloudflared',
    ];

    for (final path in commonPaths) {
      try {
        final result = await Process.run(path, ['--version']);
        if (result.exitCode == 0) {
          _executablePath = path;
          return true;
        }
      } catch (e) {
        // Continue checking other paths
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
              final decoded = utf8.decode(base64Decode(token));
              final tokenData = json.decode(decoded);
              final id = tokenData['t'];
              if (id is String) tunnelId = id;
            } catch (e) {
              // Token might not be valid base64/JSON, skip
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
        return data.map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
      }
    } catch (e) {
    }
    return {};
  }

  static Future<void> registerAppTunnel(String tunnelId, int localPort) async {
    final file = _appTunnelMapFile();
    if (file == null) return;
    final map = await readAppTunnelPortMap();
    map[tunnelId] = localPort;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(json.encode(map));
    } catch (e) {
      print('Error persisting tunnel map: $e');
    }
  }

  static Future<void> unregisterAppTunnel(String tunnelId) async {
    final file = _appTunnelMapFile();
    if (file == null) return;
    final map = await readAppTunnelPortMap();
    if (map.remove(tunnelId) != null) {
      try {
        await file.writeAsString(json.encode(map));
      } catch (e) {
      }
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

  static Future<Process> startTokenTunnel(String token) async {
    return await Process.start(_executablePath, [
      'tunnel',
      '--no-autoupdate',
      'run',
      '--token',
      token
    ]);
  }

  static Future<bool> killTunnelById(String tunnelId) async {
    try {
      final result = await Process.run('ps', ['aux']);
      if (result.exitCode != 0) return false;

      final lines = (result.stdout as String).split('\n');
      for (final line in lines) {
        if (!line.contains('cloudflared')) continue;
        if (line.contains('grep')) continue;

        final tokenIndex = line.indexOf('--token');
        if (tokenIndex == -1) continue;

        final afterToken = line.substring(tokenIndex + '--token'.length).trimLeft();
        final tokenEnd = afterToken.indexOf(RegExp(r'\s'));
        final token = tokenEnd == -1 ? afterToken : afterToken.substring(0, tokenEnd);

        try {
          final decoded = utf8.decode(base64Decode(token));
          final tokenData = json.decode(decoded);
          if (tokenData['t'] == tunnelId) {
            final parts = line.trim().split(RegExp(r'\s+'));
            if (parts.length >= 2) {
              final pid = int.tryParse(parts[1]);
              if (pid != null) {
                Process.killPid(pid);
                return true;
              }
            }
          }
        } catch (e) {
          // skip
        }
      }
    } catch (e) {
      print('Error killing tunnel: $e');
    }
    return false;
  }
}
