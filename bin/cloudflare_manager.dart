#!/usr/bin/env dart
import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:cloudflare_manager/api_key_gen.dart';
import 'package:cloudflare_manager/daemon/daemon.dart';
import 'package:cloudflare_manager/daemon/ipc_client.dart';
import 'package:cloudflare_manager/daemon/http_api.dart';

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addCommand('daemon')
    ..addCommand('tunnel')
    ..addCommand('service')
    ..addCommand('api');

  final daemonParser = ArgParser();
  daemonParser.addCommand('start');
  daemonParser.addCommand('stop');
  daemonParser.addCommand('status');

  final tunnelParser = ArgParser();
  tunnelParser.addCommand('list');
  tunnelParser.addCommand('logs');

  final serviceParser = ArgParser();
  serviceParser.addCommand('install');
  serviceParser.addCommand('uninstall');
  serviceParser.addCommand('status');

  final apiParser = ArgParser();
  apiParser.addCommand('start');
  apiParser.addCommand('stop');
  apiParser.addOption('port', abbr: 'p', defaultsTo: '9845');
  apiParser.addOption('key', abbr: 'k', defaultsTo: '');

  if (arguments.isEmpty) {
    _printUsage(parser);
    exit(0);
  }

  final command = arguments.first;

  switch (command) {
    case 'daemon':
      await _handleDaemon(arguments.sublist(1));
      break;
    case 'tunnel':
      await _handleTunnel(arguments.sublist(1));
      break;
    case 'service':
      await _handleService(arguments.sublist(1));
      break;
    case 'api':
      await _handleApi(arguments.sublist(1));
      break;
    case 'status':
      await _daemonStatus();
      break;
    case 'start':
      await _daemonStart();
      break;
    case 'stop':
      await _daemonStop();
      break;
    case 'restart':
      await _daemonStop();
      await Future.delayed(const Duration(seconds: 1));
      await _daemonStart();
      break;
    case 'install-service':
      await _serviceInstall();
      break;
    case 'uninstall-service':
      await _serviceUninstall();
      break;
    case 'api-key':
      await _handleApiKey(arguments.sublist(1));
      break;
    case '--version':
    case '-v':
      print('cloudflare-manager v1.0.0');
      break;
    case '--help':
    case '-h':
      _printUsage(parser);
      break;
    default:
      print('Unknown command: $command');
      _printUsage(parser);
      exit(1);
  }
}

void _printUsage(ArgParser parser) {
  print('''
cloudflare-manager — Tunnel manager daemon

Usage:
  cloudflare-manager <command> [arguments]

Common commands:
  status             Show daemon status and tunnels
  start              Start the daemon (foreground)
  stop               Stop a running daemon
  restart            Restart the daemon
  api-key [regen]    Show or regenerate HTTP API key
  install-service    Install auto-start service (launchd on macOS, systemd on Linux)
  uninstall-service  Remove auto-start service
  --version, -v      Show version
  --help, -h         Show help

Grouped subcommands:
  daemon <start|stop|status>
  tunnel <list|logs>
  service <install|uninstall|status>
  api <start|stop> [--port <port>] [--key <key>]
''');
}

Future<void> _handleApiKey(List<String> args) async {
  final home = Platform.environment['HOME'] ?? '/tmp';
  final keyFile = File('$home/.cloudflared/api-key');
  if (args.isNotEmpty && args.first == 'regen') {
    final newKey = generateApiKey();
    await keyFile.parent.create(recursive: true);
    await keyFile.writeAsString(newKey);
    print('API key regenerated: $newKey');
  } else if (await keyFile.exists()) {
    print((await keyFile.readAsString()).trim());
  } else {
    print('No API key found. Start the daemon first.');
  }
}

Future<void> _handleDaemon(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: cloudflare-manager daemon <start|stop|status>');
    return;
  }

  final sub = args.first;

  switch (sub) {
    case 'start':
      await _daemonStart();
      break;
    case 'stop':
      await _daemonStop();
      break;
    case 'status':
      await _daemonStatus();
      break;
    default:
      print('Unknown daemon subcommand: $sub');
  }
}

Future<void> _daemonStart() async {
  final home = Platform.environment['HOME'] ?? '/tmp';
  final configPath = '$home/.cloudflared/app-tunnels.json';

  final daemon = CloudflareDaemon(configPath: configPath);

  ProcessSignal.sigterm.watch().listen((_) {
    print('\n[cli] Received SIGTERM, shutting down...');
    daemon.stop().then((_) => exit(0));
  });

  ProcessSignal.sigint.watch().listen((_) {
    print('\n[cli] Received SIGINT, shutting down...');
    daemon.stop().then((_) => exit(0));
  });

  await daemon.start();
  print('[cli] Daemon running. Press Ctrl+C to stop.');

  await daemon.waitForShutdown();
}

Future<void> _daemonStop() async {
  final client = DaemonClient();
  final connected = await client.connect();
  if (!connected) {
    print('Daemon is not running.');
    return;
  }
  final result = await client.shutdown();
  client.disconnect();
  if (result['ok'] == true) {
    print('Daemon stopped.');
  } else {
    print('Failed to stop daemon: ${result['error']}');
  }
}

Future<void> _daemonStatus() async {
  final client = DaemonClient();
  final running = await client.isDaemonRunning;
  if (!running) {
    print('Daemon is not running.');
    return;
  }
  final connected = await client.connect();
  if (!connected) {
    print('Daemon socket exists but cannot connect.');
    return;
  }
  final result = await client.getStatus();
  client.disconnect();
  if (result['ok'] == true) {
    final tunnels = result['tunnels'] as List? ?? [];
    print('Daemon is running. Managing ${tunnels.length} tunnel(s).');
    for (final t in tunnels) {
      print('  ${t['tunnelId']}: ${t['state']} (${t['hostname']}:${t['port']})');
    }
  } else {
    print('Error: ${result['error']}');
  }
}

Future<void> _handleTunnel(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: cloudflare-manager tunnel <list|logs>');
    return;
  }

  final sub = args.first;

  switch (sub) {
    case 'list':
      await _tunnelList();
      break;
    case 'logs':
      await _tunnelLogs(args.sublist(1));
      break;
    default:
      print('Unknown tunnel subcommand: $sub');
  }
}

Future<void> _tunnelList() async {
  final client = DaemonClient();
  final connected = await client.connect();
  if (!connected) {
    print('Daemon is not running.');
    return;
  }
  final result = await client.getTunnelList();
  client.disconnect();
  if (result['ok'] == true) {
    final tunnels = result['tunnels'] as List? ?? [];
    if (tunnels.isEmpty) {
      print('No tunnels managed by daemon.');
      return;
    }
    print('Managed tunnels:');
    for (final t in tunnels) {
      final state = t['state'] ?? 'unknown';
      final host = t['hostname'] ?? '';
      final port = t['port'] ?? '';
      final restarts = t['restartCount'] ?? 0;
      print('  ${t['tunnelId']}');
      print('    State: $state  |  $host:$port  |  Restarts: $restarts');
    }
  } else {
    print('Error: ${result['error']}');
  }
}

Future<void> _tunnelLogs(List<String> args) async {
  final client = DaemonClient();
  final connected = await client.connect();
  if (!connected) {
    print('Daemon is not running.');
    return;
  }

  String? tunnelId;
  int limit = 50;

  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--limit' && i + 1 < args.length) {
      limit = int.tryParse(args[i + 1]) ?? 50;
      i++;
    } else if (tunnelId == null) {
      tunnelId = args[i];
    }
  }

  if (tunnelId == null) {
    print('Usage: cloudflare-manager tunnel logs <tunnel-id> [--limit N]');
    client.disconnect();
    return;
  }

  final result = await client.getTunnelLogs(tunnelId, limit: limit);
  client.disconnect();
  if (result['ok'] == true) {
    final logs = result['logs'] as List? ?? [];
    if (logs.isEmpty) {
      print('No logs for tunnel $tunnelId.');
    } else {
      for (final line in logs) {
        print(line);
      }
    }
  } else {
    print('Error: ${result['error']}');
  }
}

Future<void> _handleService(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: cloudflare-manager service <install|uninstall|status>');
    return;
  }

  final sub = args.first;

  switch (sub) {
    case 'install':
      await _serviceInstall();
      break;
    case 'uninstall':
      await _serviceUninstall();
      break;
    case 'status':
      await _serviceStatus();
      break;
    default:
      print('Unknown service subcommand: $sub');
  }
}

Future<void> _serviceInstall() async {
  final home = Platform.environment['HOME'] ?? '/tmp';
  final exe = Platform.resolvedExecutable;

  if (Platform.isLinux) {
    final dir = Directory('$home/.config/systemd/user');
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File('${dir.path}/cloudflare-manager.service');
    await file.writeAsString('''
[Unit]
Description=Cloudflare Manager Daemon
After=network-online.target

[Service]
Type=simple
ExecStart=$exe daemon start
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
''');
    await Process.run('systemctl', ['--user', 'daemon-reload']);
    await Process.run('systemctl', ['--user', 'enable', 'cloudflare-manager.service']);
    print('Service installed. Start with: systemctl --user start cloudflare-manager');
  } else if (Platform.isMacOS) {
    final dir = Directory('$home/Library/LaunchAgents');
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File('${dir.path}/com.cloudflare.manager.daemon.plist');

    final List<String> progArgs;
    final scriptPath = Platform.script.toFilePath();
    if (exe.endsWith('dart') || scriptPath.endsWith('.dart')) {
      progArgs = [exe, 'run', scriptPath, 'daemon', 'start'];
    } else {
      progArgs = [exe, 'daemon', 'start'];
    }

    final argsXml = progArgs.map((a) => '        <string>$a</string>').join('\n');
    await file.writeAsString('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cloudflare.manager.daemon</string>
    <key>ProgramArguments</key>
    <array>
$argsXml
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$home</string>
        <key>PATH</key>
        <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$home/.cloudflared</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/cloudflare-manager-daemon.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/cloudflare-manager-daemon.err</string>
</dict>
</plist>
''');
    final uidResult = await Process.run('id', ['-u']);
    final uid = uidResult.stdout.toString().trim().isNotEmpty ? uidResult.stdout.toString().trim() : '501';
    final domain = 'gui/$uid';

    await Process.run('launchctl', ['bootout', '$domain/com.cloudflare.manager.daemon']);
    await Process.run('launchctl', ['unload', '-w', file.path]);
    final bootResult = await Process.run('launchctl', ['bootstrap', domain, file.path]);
    if (bootResult.exitCode != 0) {
      await Process.run('launchctl', ['load', '-w', file.path]);
    }
    print('Service installed and loaded (launchd).');
  } else {
    print('Unsupported platform. Use Windows Task Scheduler or similar.');
  }
}

Future<void> _serviceUninstall() async {
  final home = Platform.environment['HOME'] ?? '/tmp';

  if (Platform.isLinux) {
    await Process.run('systemctl', ['--user', 'stop', 'cloudflare-manager.service']);
    await Process.run('systemctl', ['--user', 'disable', 'cloudflare-manager.service']);
    final file = File('$home/.config/systemd/user/cloudflare-manager.service');
    if (await file.exists()) await file.delete();
    await Process.run('systemctl', ['--user', 'daemon-reload']);
    print('Service removed.');
  } else if (Platform.isMacOS) {
    final uidResult = await Process.run('id', ['-u']);
    final uid = uidResult.stdout.toString().trim().isNotEmpty ? uidResult.stdout.toString().trim() : '501';
    final domain = 'gui/$uid';

    await Process.run('launchctl', ['bootout', '$domain/com.cloudflare.manager.daemon']);
    final file = File('$home/Library/LaunchAgents/com.cloudflare.manager.daemon.plist');
    if (await file.exists()) {
      await Process.run('launchctl', ['unload', '-w', file.path]);
      await file.delete();
    }
    print('Service removed.');
  }
}

Future<void> _serviceStatus() async {
  if (Platform.isLinux) {
    final result = await Process.run('systemctl', ['--user', 'is-active', 'cloudflare-manager.service']);
    final status = result.stdout.toString().trim();
    print('Service: $status');
  } else if (Platform.isMacOS) {
    final file = File('${Platform.environment['HOME'] ?? '/tmp'}/Library/LaunchAgents/com.cloudflare.manager.daemon.plist');
    if (!await file.exists()) {
      print('Service: not installed');
      return;
    }
    final uidResult = await Process.run('id', ['-u']);
    final uid = uidResult.stdout.toString().trim().isNotEmpty ? uidResult.stdout.toString().trim() : '501';
    final domain = 'gui/$uid';

    final result = await Process.run('launchctl', ['print', '$domain/com.cloudflare.manager.daemon']);
    final running = result.exitCode == 0;
    print('Service: ${running ? "running (loaded)" : "installed (not running)"}');
  }
}

Future<void> _handleApi(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: cloudflare-manager api <start|stop> [--port <port>] [--key <key>]');
    return;
  }

  final sub = args.first;
  final parser = ArgParser();
  parser.addOption('port', abbr: 'p', defaultsTo: '9845');
  parser.addOption('key', abbr: 'k', defaultsTo: '');
  final parsed = parser.parse(args.sublist(1));

  switch (sub) {
    case 'start':
      await _apiStart(
        int.tryParse(parsed['port'] as String) ?? 9845,
        parsed['key'] as String?,
      );
      break;
    case 'stop':
      await _apiStop();
      break;
    default:
      print('Unknown api subcommand: $sub');
  }
}

String _getApiKey() {
  final home = Platform.environment['HOME'] ?? '/tmp';
  final keyFile = File('$home/.cloudflared/api-key');
  if (keyFile.existsSync()) {
    return keyFile.readAsStringSync().trim();
  }
  final key = generateApiKey();
  keyFile.parent.createSync(recursive: true);
  keyFile.writeAsStringSync(key);
  return key;
}

HttpApiServer? _apiServer;

Future<void> _apiStart(int port, String? providedKey) async {
  if (_apiServer != null) {
    print('API server is already running.');
    return;
  }

  final key = (providedKey != null && providedKey.isNotEmpty) ? providedKey : _getApiKey();
  print('[api] Starting API server on port $port...');

  _apiServer = HttpApiServer(port: port, apiKey: key);
  await _apiServer!.start();
}

Future<void> _apiStop() async {
  if (_apiServer == null) {
    final client = DaemonClient();
    if (await client.connect()) {
      await client.shutdown();
      client.disconnect();
      print('Sent stop signal to API server.');
      return;
    }
    print('API server is not running.');
    return;
  }
  await _apiServer!.stop();
  _apiServer = null;
}
