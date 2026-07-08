import 'dart:io';
import 'daemon.dart' as daemon_mod;
import 'ipc_client.dart';

Future<void> main(List<String> args) async {
  final home = Platform.environment['HOME'] ?? '/tmp';
  final configPath = '$home/.cloudflared/app-tunnels.json';

  if (args.isEmpty) {
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
    case 'install-service':
      {
        final serviceDir = '$home/.config/systemd/user';
        final src = File('/usr/lib/systemd/system/cloudflare-manager-server.service');
        await Directory(serviceDir).create(recursive: true);
        if (await src.exists()) {
          await src.copy('$serviceDir/cloudflare-manager-server.service');
        }
        await Process.run('systemctl', ['--user', 'daemon-reload']);
        await Process.run('systemctl', ['--user', 'enable', 'cloudflare-manager-server']);
        await Process.run('systemctl', ['--user', 'start', 'cloudflare-manager-server']);
        print('User service enabled and started.');
      }
      break;
    default:
      print('Cloudflare Manager Server');
      print('Usage: cloudflare-manager-server [status|api-key|install-service]');
      print('No args starts the daemon (systemd).');
  }
}

String _randStr(int len) {
  final rnd = List<int>.generate(len, (i) {
    final us = DateTime.now().microsecondsSinceEpoch;
    return 97 + ((us >> (i % 16)) & 0xF) % 26;
  });
  return String.fromCharCodes(rnd);
}
