import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

const _kAutoBackupDir = '.cloudflared/backups';
const _kMaxAutoBackups = 10;

String? _homeDir() => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];

Future<void> createAutoBackup() async {
  final home = _homeDir();
  if (home == null) return;
  final src = Directory('$home/.cloudflared');
  if (!await src.exists()) return;
  final dstDir = Directory('$home/$_kAutoBackupDir');
  if (!await dstDir.exists()) await dstDir.create(recursive: true);

  final backup = <String, dynamic>{
    'version': 1,
    'timestamp': DateTime.now().toIso8601String(),
    'auto': true,
  };

  for (final name in ['app-settings.json', 'webhooks.json', 'app-tunnels.json', 'daemon.json', 'rate-alerts.json']) {
    final f = File('${src.path}/$name');
    if (await f.exists()) {
      backup[name.replaceAll('.json', '').replaceAll('-', '_')] = json.decode(await f.readAsString());
    }
  }

  final content = json.encode(backup);
  final checksum = sha256.convert(utf8.encode(content)).toString();
  final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
  await File('${dstDir.path}/auto-$stamp.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert({...backup, '_checksum': checksum}),
  );

  // Rotate old backups
  final files = await dstDir.list().toList();
  final backups = files.whereType<File>().where((f) => f.path.endsWith('.json')).toList()
    ..sort((a, b) => b.path.compareTo(a.path));
  for (var i = _kMaxAutoBackups; i < backups.length; i++) {
    try { await backups[i].delete(); } catch (_) {}
  }
}

Future<List<Map<String, dynamic>>> listAutoBackups() async {
  final home = _homeDir();
  if (home == null) return [];
  final dir = Directory('$home/$_kAutoBackupDir');
  if (!await dir.exists()) return [];
  final files = await dir.list().toList();
  final result = <Map<String, dynamic>>[];
  for (final entity in files.whereType<File>().where((f) => f.path.endsWith('.json'))) {
    try {
      final data = json.decode(await entity.readAsString());
      if (data is Map && data['auto'] == true) {
        result.add({
          'path': entity.path,
          'timestamp': data['timestamp'] ?? '',
          'checksum': data['_checksum'] ?? '',
        });
      }
    } catch (_) {}
  }
  result.sort((a, b) => (b['timestamp'] as String).compareTo(a['timestamp'] as String));
  return result.take(_kMaxAutoBackups).toList();
}
