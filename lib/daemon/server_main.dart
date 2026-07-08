import 'dart:io';
import '../app_storage.dart';
import 'daemon.dart' as daemon_mod;
import 'ipc_client.dart';

Future<void> main(List<String> args) async {
  final home = Platform.environment['HOME'] ?? '/tmp';
  final configPath = '$home/.cloudflared/app-tunnels.json';

  if (args.isEmpty || (args.length == 1 && args.first == 'start')) {
    final daemon = daemon_mod.CloudflareDaemon(configPath: configPath, onEvent: (_) {});
    await daemon.start();
    return;
  }

  final cmd = args.first;
  switch (cmd) {
    case 'status':
      final client = DaemonClient();
      if (await client.connect()) {
        final result = await client.send('status');
        if (result['ok'] == true) {
          final tunnels = result['tunnels'] as List? ?? [];
          print('Daemon: running, ${tunnels.length} tunnel(s)');
        }
        client.disconnect();
      } else {
        print('Daemon: not running');
      }
      break;
    case 'stop':
      final client = DaemonClient();
      if (await client.connect()) {
        await client.send('shutdown');
        client.disconnect();
        print('Daemon stopped');
      } else {
        print('Daemon is not running');
      }
      break;
    case 'api-key':
      final keyFile = File('$home/.cloudflared/api-key');
      if (args.length > 1 && args[1] == 'regen') {
        final newKey = 'cm_${_randStr(32)}_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
        await keyFile.parent.create(recursive: true);
        await keyFile.writeAsString(newKey);
        print('API key regenerated: $newKey');
      } else if (await keyFile.exists()) {
        print(await keyFile.readAsString());
      } else {
        print('No API key. Start the daemon first.');
      }
      break;
    case 'setup':
      final portStr = await AppStorage.instance.read(key: 'api_port');
      final port = int.tryParse(portStr ?? '9845') ?? 9845;
      print('Visit http://localhost:$port to configure.');
      break;
    case 'install-service':
      final uid = (await Process.run('id', ['-u'])).stdout.toString().trim();
      if (uid == '0') {
        // System service (root/headless)
        final exe = Platform.resolvedExecutable;
        final user = Platform.environment['SUDO_USER'] ?? Platform.environment['USER'] ?? 'root';
        final serviceFile = File('/etc/systemd/system/cloudflare-manager-server.service');
        await serviceFile.parent.create(recursive: true);
        await serviceFile.writeAsString('''
[Unit]
Description=Cloudflare Tunnel Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$user
ExecStart=$exe
Restart=always
RestartSec=5
Environment=HOME=/home/$user
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
''');
        await Process.run('systemctl', ['daemon-reload']);
        await Process.run('systemctl', ['enable', 'cloudflare-manager-server']);
        print('System service installed.');
        print('Start:  systemctl start cloudflare-manager-server');
        print('Status: systemctl status cloudflare-manager-server');
        print('Logs:   journalctl -u cloudflare-manager-server -f');
      } else {
        // User service
        final serviceDir = '$home/.config/systemd/user';
        final serviceFile = File('$serviceDir/cloudflare-manager-server.service');
        final exe = Platform.resolvedExecutable;
        await serviceFile.parent.create(recursive: true);
        await serviceFile.writeAsString('''
[Unit]
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
        await Process.run('systemctl', ['--user', 'daemon-reload']);
        await Process.run('systemctl', ['--user', 'enable', 'cloudflare-manager-server']);
        print('User service installed.');
        print('Start:  systemctl --user start cloudflare-manager-server');
        print('Status: systemctl --user status cloudflare-manager-server');
        print('Logs:   journalctl --user -u cloudflare-manager-server -f');
      }
      break;
    default:
      print('Cloudflare Manager Server');
      print('Usage: cloudflare-manager-server [start|status|stop|api-key|setup|install-service]');
      print('No args starts the daemon.');
  }
}

String _randStr(int len) {
  final rnd = List<int>.generate(len, (i) {
    final us = DateTime.now().microsecondsSinceEpoch;
    return 97 + ((us >> (i % 16)) & 0xF) % 26;
  });
  return String.fromCharCodes(rnd);
}
