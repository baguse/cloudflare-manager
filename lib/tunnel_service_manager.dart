import 'dart:async';
import 'dart:io';

import 'daemon/ipc_client.dart';

class TunnelServiceManager {
  static final instance = TunnelServiceManager._();
  TunnelServiceManager._();

  static const _serviceName = 'cloudflare-manager';
  static const _serviceLabel = 'com.cloudflare.manager.daemon';

  String get _serviceFileDir {
    if (Platform.isLinux) {
      final home = Platform.environment['HOME'] ?? '/tmp';
      return '$home/.config/systemd/user';
    }
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '/tmp';
      return '$home/Library/LaunchAgents';
    }
    return '/tmp';
  }

  String get _serviceFilePath {
    if (Platform.isLinux) return '$_serviceFileDir/$_serviceName.service';
    if (Platform.isMacOS) return '$_serviceFileDir/$_serviceLabel.plist';
    return '$_serviceFileDir/$_serviceName';
  }

  String get _linuxUnitName => '$_serviceName.service';

  Future<bool> isServiceInstalled() async {
    return File(_serviceFilePath).exists();
  }

  Future<bool> isServiceRunning() async {
    try {
      if (Platform.isLinux) {
        final result = await Process.run('systemctl', ['--user', 'is-active', _linuxUnitName]);
        return result.stdout.toString().trim() == 'active';
      }
      if (Platform.isMacOS) {
        final result = await Process.run('launchctl', ['list']);
        return result.stdout.toString().contains(_serviceLabel);
      }
    } catch (_) {}
    return false;
  }

  Future<bool> isDaemonRunning() async {
    final client = DaemonClient();
    final running = await client.isDaemonRunning;
    if (!running) return false;
    final connected = await client.connect();
    if (!connected) return false;
    final result = await client.getStatus();
    client.disconnect();
    return result['ok'] == true;
  }

  Future<String?> installService() async {
    final exe = Platform.resolvedExecutable;
    final scriptUri = Platform.script;
    final scriptPath = scriptUri.toFilePath();
    final projectDir = scriptPath.contains('/lib/') 
        ? scriptPath.substring(0, scriptPath.indexOf('/lib/'))
        : Directory.current.path;
    final cliScript = '$projectDir/bin/cloudflare_manager.dart';

    if (Platform.isLinux) {
      final dir = Directory(_serviceFileDir);
      if (!await dir.exists()) await dir.create(recursive: true);
      final useDart = await File(cliScript).exists();
      String execLine;
      if (useDart) {
        final dartExe = await _findDart();
        execLine = '$dartExe run $cliScript daemon start';
      } else {
        execLine = '$exe daemon start';
      }
      await File(_serviceFilePath).writeAsString(_linuxServiceContent(execLine));
      await Process.run('systemctl', ['--user', 'daemon-reload']);
      await Process.run('systemctl', ['--user', 'enable', _linuxUnitName]);
      await Process.run('systemctl', ['--user', 'start', _linuxUnitName]);
      return null;
    }

    if (Platform.isMacOS) {
      final dir = Directory(_serviceFileDir);
      if (!await dir.exists()) await dir.create(recursive: true);
      final useDart = await File(cliScript).exists();
      String execLine;
      if (useDart) {
        final dartExe = await _findDart();
        execLine = '$dartExe run $cliScript daemon start';
      } else {
        execLine = '$exe daemon start';
      }
      await File(_serviceFilePath).writeAsString(_macosPlistContent(execLine.split(' ')));
      await Process.run('launchctl', ['load', '-w', _serviceFilePath]);
      return null;
    }

    return 'Unsupported platform';
  }

  Future<String> _findDart() async {
    const candidates = [
      '/opt/flutter/bin/dart',
      '/usr/bin/dart',
      '/usr/local/bin/dart',
    ];
    for (final p in candidates) {
      if (File(p).existsSync()) return p;
    }
    final home = Platform.environment['HOME'];
    if (home != null) {
      final h = '$home/.pub-cache/bin/dart';
      if (File(h).existsSync()) return h;
      final flutter = '$home/flutter/bin/dart';
      if (File(flutter).existsSync()) return flutter;
    }
    return 'dart';
  }

  Future<String?> uninstallService() async {
    if (Platform.isLinux) {
      await Process.run('systemctl', ['--user', 'stop', _linuxUnitName]);
      await Process.run('systemctl', ['--user', 'disable', _linuxUnitName]);
      final file = File(_serviceFilePath);
      if (await file.exists()) await file.delete();
      await Process.run('systemctl', ['--user', 'daemon-reload']);
      return null;
    }

    if (Platform.isMacOS) {
      await Process.run('launchctl', ['unload', '-w', _serviceFilePath]);
      final file = File(_serviceFilePath);
      if (await file.exists()) await file.delete();
      return null;
    }

    return 'Unsupported platform';
  }

  Future<String?> startDaemon() async {
    try {
      if (Platform.isLinux) {
        final result = await Process.run('systemctl', ['--user', 'start', _linuxUnitName]);
        if (result.exitCode != 0) return result.stderr.toString().trim();
        return null;
      }
      if (Platform.isMacOS) {
        final result = await Process.run('launchctl', ['load', '-w', _serviceFilePath]);
        if (result.exitCode != 0) return result.stderr.toString().trim();
        return null;
      }
      return 'Unsupported platform';
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> stopDaemon() async {
    try {
      final client = DaemonClient();
      final connected = await client.connect();
      if (connected) {
        await client.shutdown();
        client.disconnect();
        return null;
      }
      if (Platform.isLinux) {
        final result = await Process.run('systemctl', ['--user', 'stop', _linuxUnitName]);
        if (result.exitCode != 0) return result.stderr.toString().trim();
        return null;
      }
      if (Platform.isMacOS) {
        final result = await Process.run('launchctl', ['unload', _serviceFilePath]);
        if (result.exitCode != 0) return result.stderr.toString().trim();
        return null;
      }
      return 'Daemon not running';
    } catch (e) {
      return e.toString();
    }
  }

  String privilegeNote() {
    if (Platform.isLinux) {
      return 'User-level systemd service. Survives logout with: loginctl enable-linger \$USER';
    }
    if (Platform.isMacOS) {
      return 'User-level LaunchAgent. Runs on login, no password needed.';
    }
    return '';
  }

  String _linuxServiceContent(String execLine) {
    return '''[Unit]
Description=Cloudflare Manager Daemon
After=network-online.target

[Service]
Type=simple
ExecStart=$execLine
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
''';
  }

  String _macosPlistContent(List<String> execArgs) {
    final argsXml = execArgs.map((a) => '        <string>$a</string>').join('\n');
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$_serviceLabel</string>
    <key>ProgramArguments</key>
    <array>
$argsXml
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/$_serviceName.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/$_serviceName.err</string>
</dict>
</plist>
''';
  }
}
