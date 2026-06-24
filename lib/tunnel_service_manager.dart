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

  Future<String> get _domain async {
    final uid = await _getUid();
    return 'gui/$uid';
  }

  Future<String> _getUid() async {
    try {
      final result = await Process.run('id', ['-u']);
      return (result.stdout as String).trim();
    } catch (_) {
      return Platform.environment['UID'] ?? '501';
    }
  }

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
        final domain = await _domain;
        final result = await Process.run('launchctl', ['print', '$domain/$_serviceLabel']);
        return result.exitCode == 0;
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

    print('[svc] installService: exe=$exe');
    print('[svc] installService: scriptPath=$scriptPath');
    print('[svc] installService: projectDir=$projectDir');
    print('[svc] installService: cliScript=$cliScript');

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
      print('[svc] installService: useDart=$useDart');
      String execLine;
      if (useDart) {
        final dartExe = await _findDart();
        execLine = '$dartExe run $cliScript daemon start';
        print('[svc] installService: dartExe=$dartExe');
      } else {
        execLine = '$exe daemon start';
      }
      print('[svc] installService: plist path=$_serviceFilePath');
      print('[svc] installService: execLine=$execLine');
      await File(_serviceFilePath).writeAsString(_macosPlistContent(execLine.split(' ')));
      final domain = await _domain;
      final bootResult = await Process.run('launchctl', ['bootstrap', domain, _serviceFilePath]);
      print('[svc] installService: bootstrap exit=${bootResult.exitCode} stdout=${bootResult.stdout} stderr=${bootResult.stderr}');
      if (bootResult.exitCode != 0) {
        return 'bootstrap failed: ${bootResult.stderr}'.trim();
      }
      return null;
    }

    return 'Unsupported platform';
  }

  Future<String> _findDart() async {
    try {
      final which = await Process.run('which', ['dart']);
      final path = (which.stdout as String).trim();
      if (which.exitCode == 0 && path.isNotEmpty && File(path).existsSync()) {
        return path;
      }
    } catch (_) {}

    try {
      final sh = await Process.run('/bin/sh', ['-l', '-c', 'which dart']);
      final path = (sh.stdout as String).trim();
      if (path.isNotEmpty && File(path).existsSync()) {
        return path;
      }
    } catch (_) {}

    final candidates = [
      '/opt/homebrew/bin/dart',
      '/usr/local/bin/dart',
      '/opt/flutter/bin/dart',
      '/usr/bin/dart',
    ];
    for (final p in candidates) {
      if (File(p).existsSync()) return p;
    }
    final home = Platform.environment['HOME'];
    if (home != null) {
      for (final dir in ['flutter/bin/dart', 'apps/flutter/bin/dart', '.pub-cache/bin/dart']) {
        final p = '$home/$dir';
        if (File(p).existsSync()) return p;
      }
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
      final domain = await _domain;
      print('[svc] uninstallService: booting out $domain/$_serviceLabel');
      await Process.run('launchctl', ['bootout', '$domain/$_serviceLabel']);
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
        final domain = await _domain;

        print('[svc] startDaemon: booting out old instance...');
        await Process.run('launchctl', ['bootout', '$domain/$_serviceLabel']);
        await Future.delayed(const Duration(milliseconds: 500));

        await _writePlist();
        print('[svc] startDaemon: bootstrapping $_serviceFilePath...');
        final result = await Process.run('launchctl', ['bootstrap', domain, _serviceFilePath]);
        print('[svc] startDaemon: bootstrap exit=${result.exitCode} stdout=${result.stdout} stderr=${result.stderr}');
        if (result.exitCode != 0) {
          return 'bootstrap failed: ${result.stderr}'.trim();
        }
        return null;
      }
      return 'Unsupported platform';
    } catch (e) {
      print('[svc] startDaemon: exception: $e');
      return e.toString();
    }
  }

  Future<void> _writePlist() async {
    final exe = Platform.resolvedExecutable;
    final scriptUri = Platform.script;
    final scriptPath = scriptUri.toFilePath();
    final projectDir = scriptPath.contains('/lib/') 
        ? scriptPath.substring(0, scriptPath.indexOf('/lib/'))
        : Directory.current.path;
    final cliScript = '$projectDir/bin/cloudflare_manager.dart';

    final useDart = await File(cliScript).exists();
    String execLine;
    if (useDart) {
      final dartExe = await _findDart();
      execLine = '$dartExe run $cliScript daemon start';
    } else {
      execLine = '$exe daemon start';
    }
    print('[svc] _writePlist: execLine=$execLine');
    await File(_serviceFilePath).writeAsString(_macosPlistContent(execLine.split(' ')));
  }

  Future<String?> stopDaemon() async {
    try {
      final client = DaemonClient();
      final connected = await client.connect();
      if (connected) {
        await client.shutdown();
        client.disconnect();
        await Future.delayed(const Duration(seconds: 3));
      }
      
      if (Platform.isLinux) {
        final result = await Process.run('systemctl', ['--user', 'stop', _linuxUnitName]);
        if (result.exitCode != 0) return result.stderr.toString().trim();
        return null;
      }
      if (Platform.isMacOS) {
        final domain = await _domain;
        print('[svc] stopDaemon: booting out $domain/$_serviceLabel');
        var result = await Process.run('launchctl', ['bootout', '$domain/$_serviceLabel']);
        print('[svc] stopDaemon: bootout exit=${result.exitCode} stderr=${result.stderr}');
        await Future.delayed(const Duration(seconds: 1));
        await _forceKillDaemon();
        return null;
      }
      return 'Daemon not running';
    } catch (e) {
      print('[svc] stopDaemon: exception: $e');
      return e.toString();
    }
  }

  Future<void> _forceKillDaemon() async {
    final socketPath = '${Platform.environment['HOME'] ?? '/tmp'}/.cloudflared/cloudflare-manager.sock';
    if (!File(socketPath).existsSync()) return;
    try {
      print('[svc] _forceKillDaemon: socket still exists, force-killing...');
      await Process.run('pkill', ['-f', 'cloudflare_manager.dart daemon start']);
      await Future.delayed(const Duration(milliseconds: 500));
      if (File(socketPath).existsSync()) {
        await File(socketPath).delete();
      }
    } catch (e) {
      print('[svc] _forceKillDaemon: error: $e');
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
