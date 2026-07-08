import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
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

const _encMagic = 'CFENCv2';
const encMagic = _encMagic;
const _kSaltLen = 16, _kIvLen = 16, _kTagLen = 32, _kKdfIter = 100000;

Uint8List _deriveKey(String pwd, Uint8List salt) {
  final pw = utf8.encode(pwd);
  var key = Hmac(sha256, pw).convert(salt).bytes;
  for (int i = 1; i < _kKdfIter; i++) { key = Hmac(sha256, pw).convert(key).bytes; }
  return Uint8List.fromList(key);
}

Uint8List _ctr(Uint8List key, Uint8List iv, int len) {
  final s = Uint8List(len);
  var ctr = Uint8List(16); ctr.setAll(0, iv);
  for (int i = 0; i < len; i += 32) {
    final ks = Hmac(sha256, key).convert(ctr).bytes;
    for (int j = 0; j < 32 && i + j < len; j++) { s[i + j] = ks[j]; }
    for (int k = 15; k >= 0; k--) { ctr[k]++; if (ctr[k] != 0) break; }
  }
  return s;
}

String encryptData(String plain, String password) {
  final salt = Uint8List(_kSaltLen);
  for (int i = 0; i < _kSaltLen; i++) salt[i] = Random.secure().nextInt(256);
  final iv = Uint8List(_kIvLen);
  for (int i = 0; i < _kIvLen; i++) iv[i] = Random.secure().nextInt(256);
  final key = _deriveKey(password, salt);
  final pb = utf8.encode(plain);
  final ks = _ctr(key, iv, pb.length);
  final cipher = Uint8List(pb.length);
  for (int i = 0; i < pb.length; i++) cipher[i] = pb[i] ^ ks[i];
  final tag = Hmac(sha256, key).convert(Uint8List.fromList([...salt, ...iv, ...cipher])).bytes;
  return _encMagic + base64Encode(Uint8List.fromList([...salt, ...iv, ...cipher, ...tag]));
}

String? decryptData(String data, String password) {
  if (!data.startsWith(_encMagic)) return data;
  final bytes = base64Decode(data.substring(_encMagic.length));
  if (bytes.length < _kSaltLen + _kIvLen + _kTagLen) return null;
  final salt = bytes.sublist(0, _kSaltLen);
  final iv = bytes.sublist(_kSaltLen, _kSaltLen + _kIvLen);
  final cipher = bytes.sublist(_kSaltLen + _kIvLen, bytes.length - _kTagLen);
  final tag = bytes.sublist(bytes.length - _kTagLen);
  final key = _deriveKey(password, salt);
  final expected = Hmac(sha256, key).convert(Uint8List.fromList([...salt, ...iv, ...cipher])).bytes;
  int ok = 0;
  for (int i = 0; i < _kTagLen && i < expected.length; i++) ok |= tag[i] ^ expected[i];
  if (ok != 0) return null;
  final ks = _ctr(key, iv, cipher.length);
  final plain = Uint8List(cipher.length);
  for (int i = 0; i < cipher.length; i++) plain[i] = cipher[i] ^ ks[i];
  try { final t = utf8.decode(plain, allowMalformed: true); json.decode(t); return t; } catch (_) { return null; }
}
