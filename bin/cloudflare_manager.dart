import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:cloudflare_manager/daemon/daemon.dart';
import 'package:cloudflare_manager/daemon/ipc_client.dart';

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addCommand('daemon')
    ..addCommand('tunnel')
    ..addCommand('service');

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
  cloudflare-manager daemon <subcommand>    Manage the daemon
  cloudflare-manager tunnel <subcommand>    Manage tunnels
  cloudflare-manager service <subcommand>   Manage system service

Daemon subcommands:
  daemon start     Start the daemon (foreground)
  daemon stop      Stop a running daemon
  daemon status    Check if daemon is running

Tunnel subcommands:
  tunnel list      List managed tunnels
  tunnel logs      Show tunnel logs

Service subcommands:
  service install    Install as system service (systemd/launchd)
  service uninstall  Remove system service
  service status     Check service status
''');
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
    await file.writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cloudflare.manager.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>$exe</string>
        <string>daemon</string>
        <string>start</string>
    </array>
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
    await Process.run('launchctl', ['load', '-w', file.path]);
    print('Service installed and loaded.');
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
    final result = await Process.run('launchctl', ['list']);
    final running = result.stdout.toString().contains('com.cloudflare.manager.daemon');
    print('Service: ${running ? "loaded" : "not loaded"}');
  }
}
