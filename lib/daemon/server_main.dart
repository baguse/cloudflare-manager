import 'dart:io';
import '../api_key_gen.dart';
import 'daemon.dart' as daemon_mod;
import 'ipc_client.dart';

Future<void> main(List<String> args) async {
  final home = Platform.environment['HOME'] ?? '/tmp';
  final configPath = '$home/.cloudflared/app-tunnels.json';

  final isStartCommand = args.isEmpty ||
      args.first == 'start' ||
      (args.first == 'daemon' && (args.length == 1 || args[1] == 'start'));

  if (isStartCommand) {
    final daemon = daemon_mod.CloudflareDaemon(configPath: configPath, onEvent: (_) {});

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
    // start() now returns once bound; block here until shutdown so the
    // process stays alive to serve tunnels and the API.
    await daemon.waitForShutdown();
    return;
  }

  final cmd = args.first;
  switch (cmd) {
    case 'status':
      await _showStatus();
      break;

    case 'stop':
      await _stopDaemon();
      break;

    case 'restart':
      await _stopDaemon();
      await Future.delayed(const Duration(seconds: 1));
      print('Restarting daemon in foreground...');
      final daemon = daemon_mod.CloudflareDaemon(configPath: configPath, onEvent: (_) {});
      ProcessSignal.sigterm.watch().listen((_) {
        daemon.stop().then((_) => exit(0));
      });
      ProcessSignal.sigint.watch().listen((_) {
        daemon.stop().then((_) => exit(0));
      });
      await daemon.start();
      await daemon.waitForShutdown();
      break;

    case 'api-key':
      final keyFile = File('$home/.cloudflared/api-key');
      if (args.length > 1 && args[1] == 'regen') {
        final newKey = generateApiKey();
        await keyFile.parent.create(recursive: true);
        await keyFile.writeAsString(newKey);
        print('API key regenerated: $newKey');
      } else if (await keyFile.exists()) {
        print((await keyFile.readAsString()).trim());
      } else {
        print('No API key. Start the daemon first.');
      }
      break;

    case 'install-service':
      await _installService(home);
      break;

    case 'uninstall-service':
      await _uninstallService(home);
      break;

    case 'service':
      final sub = args.length > 1 ? args[1] : '';
      if (sub == 'install') {
        await _installService(home);
      } else if (sub == 'uninstall') {
        await _uninstallService(home);
      } else if (sub == 'status') {
        await _serviceStatus(home);
      } else {
        print('Usage: cloudflare-manager-server service <install|uninstall|status>');
      }
      break;

    case 'daemon':
      final sub = args.length > 1 ? args[1] : '';
      if (sub == 'status') {
        await _showStatus();
      } else if (sub == 'stop') {
        await _stopDaemon();
      } else {
        print('Usage: cloudflare-manager-server daemon <start|stop|status>');
      }
      break;

    case 'tunnel':
      final sub = args.length > 1 ? args[1] : 'list';
      if (sub == 'logs') {
        final tunnelId = args.length > 2 ? args[2] : null;
        if (tunnelId == null) {
          print('Usage: cloudflare-manager-server tunnel logs <tunnel-id>');
          return;
        }
        final client = DaemonClient();
        if (await client.connect()) {
          final result = await client.getTunnelLogs(tunnelId);
          client.disconnect();
          if (result['ok'] == true) {
            final logs = result['logs'] as List? ?? [];
            for (final l in logs) print(l);
          } else {
            print('Error: ${result['error']}');
          }
        } else {
          print('Daemon: not running');
        }
      } else {
        final client = DaemonClient();
        if (await client.connect()) {
          final result = await client.getTunnelList();
          client.disconnect();
          if (result['ok'] == true) {
            final tunnels = result['tunnels'] as List? ?? [];
            if (tunnels.isEmpty) {
              print('No tunnels managed by daemon.');
            } else {
              print('Managed tunnels:');
              for (final t in tunnels) {
                print('  ${t['tunnelId']}: ${t['state']} (${t['hostname']}:${t['port']})');
              }
            }
          }
        } else {
          print('Daemon: not running');
        }
      }
      break;

    case '--version':
    case '-v':
      print('cloudflare-manager-server v1.0.0');
      break;

    case 'help':
    case '--help':
    case '-h':
    default:
      _printUsage();
      break;
  }
  exit(0);
}

Future<void> _showStatus() async {
  final client = DaemonClient();
  if (await client.connect()) {
    final result = await client.send('status');
    if (result['ok'] == true) {
      final tunnels = result['tunnels'] as List? ?? [];
      print('Daemon: running, managing ${tunnels.length} tunnel(s)');
      for (final t in tunnels) {
        print('  ${t['tunnelId']}: ${t['state']} (${t['hostname']}:${t['port']})');
      }
    }
    client.disconnect();
  } else {
    print('Daemon: not running');
  }
}

Future<void> _stopDaemon() async {
  final client = DaemonClient();
  if (await client.connect()) {
    final result = await client.shutdown();
    client.disconnect();
    if (result['ok'] == true) {
      print('Daemon stopped.');
    } else {
      print('Failed to stop daemon: ${result['error']}');
    }
  } else {
    print('Daemon: not running');
  }
}

Future<void> _installService(String home) async {
  if (Platform.isMacOS) {
    final dir = Directory('$home/Library/LaunchAgents');
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File('${dir.path}/com.cloudflare.manager.server.plist');
    final exe = Platform.resolvedExecutable;

    final List<String> progArgs;
    final scriptPath = Platform.script.toFilePath();
    if (exe.endsWith('dart') || scriptPath.endsWith('.dart')) {
      progArgs = [exe, 'run', scriptPath];
    } else {
      progArgs = [exe];
    }

    final argsXml = progArgs.map((a) => '        <string>$a</string>').join('\n');
    await file.writeAsString('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cloudflare.manager.server</string>
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
    <string>/tmp/cloudflare-manager-server.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/cloudflare-manager-server.err</string>
</dict>
</plist>
''');
    final uidResult = await Process.run('id', ['-u']);
    final uid = uidResult.stdout.toString().trim().isNotEmpty ? uidResult.stdout.toString().trim() : '501';
    final domain = 'gui/$uid';

    await Process.run('launchctl', ['bootout', '$domain/com.cloudflare.manager.server']);
    await Process.run('launchctl', ['unload', '-w', file.path]);
    final bootResult = await Process.run('launchctl', ['bootstrap', domain, file.path]);
    if (bootResult.exitCode != 0) {
      await Process.run('launchctl', ['load', '-w', file.path]);
    }
    print('User service installed and started (launchd).');
  } else if (Platform.isLinux) {
    final serviceDir = '$home/.config/systemd/user';
    final src = File('/usr/lib/systemd/system/cloudflare-manager-server.service');
    await Directory(serviceDir).create(recursive: true);
    if (await src.exists()) {
      await src.copy('$serviceDir/cloudflare-manager-server.service');
    } else {
      final exe = Platform.resolvedExecutable;
      await File('$serviceDir/cloudflare-manager-server.service').writeAsString('''[Unit]
Description=Cloudflare Tunnel Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$exe
Restart=always
RestartSec=5
Environment=HOME=$home
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
''');
    }
    await Process.run('systemctl', ['--user', 'daemon-reload']);
    await Process.run('systemctl', ['--user', 'enable', 'cloudflare-manager-server']);
    await Process.run('systemctl', ['--user', 'start', 'cloudflare-manager-server']);
    print('User service enabled and started (systemd).');
  } else {
    print('Unsupported platform for service installation.');
  }
}

Future<void> _uninstallService(String home) async {
  if (Platform.isMacOS) {
    final uidResult = await Process.run('id', ['-u']);
    final uid = uidResult.stdout.toString().trim().isNotEmpty ? uidResult.stdout.toString().trim() : '501';
    final domain = 'gui/$uid';

    await Process.run('launchctl', ['bootout', '$domain/com.cloudflare.manager.server']);
    final file = File('$home/Library/LaunchAgents/com.cloudflare.manager.server.plist');
    if (await file.exists()) {
      await Process.run('launchctl', ['unload', '-w', file.path]);
      await file.delete();
    }
    print('User service removed.');
  } else if (Platform.isLinux) {
    await Process.run('systemctl', ['--user', 'stop', 'cloudflare-manager-server']);
    await Process.run('systemctl', ['--user', 'disable', 'cloudflare-manager-server']);
    final file = File('$home/.config/systemd/user/cloudflare-manager-server.service');
    if (await file.exists()) await file.delete();
    await Process.run('systemctl', ['--user', 'daemon-reload']);
    print('User service removed.');
  } else {
    print('Unsupported platform for service uninstallation.');
  }
}

Future<void> _serviceStatus(String home) async {
  if (Platform.isMacOS) {
    final file = File('$home/Library/LaunchAgents/com.cloudflare.manager.server.plist');
    if (!await file.exists()) {
      print('Service: not installed');
      return;
    }
    final uidResult = await Process.run('id', ['-u']);
    final uid = uidResult.stdout.toString().trim().isNotEmpty ? uidResult.stdout.toString().trim() : '501';
    final domain = 'gui/$uid';

    final result = await Process.run('launchctl', ['print', '$domain/com.cloudflare.manager.server']);
    final running = result.exitCode == 0;
    print('Service: ${running ? "running (loaded)" : "installed (not running)"}');
  } else if (Platform.isLinux) {
    final result = await Process.run('systemctl', ['--user', 'is-active', 'cloudflare-manager-server']);
    final status = result.stdout.toString().trim();
    print('Service: $status');
  } else {
    print('Unsupported platform for service status.');
  }
}

void _printUsage() {
  print('''Cloudflare Manager Server

Usage: cloudflare-manager-server [command]

Commands:
  (no args)           Start the daemon (foreground)
  start               Start the daemon (foreground)
  stop                Stop running daemon
  restart             Restart daemon
  status              Show daemon status and tunnel count
  api-key [regen]     Show or regenerate HTTP API key
  install-service     Install auto-start service (launchd on macOS, systemd on Linux)
  uninstall-service   Remove auto-start service
  tunnel <list|logs>  Manage tunnels
  --version, -v       Show version
  --help, -h          Show help
''');
}
