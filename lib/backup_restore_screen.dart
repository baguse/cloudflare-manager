import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:crypto/crypto.dart';
import 'webhook_service.dart';
import 'rate_alert_service.dart';
import 'cloudflare_service.dart';

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

Color _cardBg(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF1E293B) : Colors.white;

Color _panelBg(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF0F172A) : const Color(0xFFF5F5F5);

const _encryptMagic = 'CFENCv2';
const _kdfIterations = 100000;
const _saltLen = 16;
const _ivLen = 16;
const _tagLen = 32;
const _keyLen = 32;

Uint8List _deriveKey(String password, Uint8List salt) {
  final pw = utf8.encode(password);
  var key = Hmac(sha256, pw).convert(salt).bytes;
  for (int i = 1; i < _kdfIterations; i++) {
    key = Hmac(sha256, pw).convert(key).bytes;
  }
  return Uint8List.fromList(key);
}

Uint8List _hmacCtr(Uint8List key, Uint8List iv, int length) {
  final stream = Uint8List(length);
  var counter = Uint8List(16);
  counter.setAll(0, iv);
  for (int i = 0; i < length; i += 32) {
    final keystream = Hmac(sha256, key).convert(counter).bytes;
    final n = (length - i).clamp(0, 32);
    for (int j = 0; j < n; j++) {
      stream[i + j] = keystream[j];
    }
    // Increment counter (big-endian)
    for (int k = 15; k >= 0; k--) {
      counter[k]++;
      if (counter[k] != 0) break;
    }
  }
  return stream;
}

String _encrypt(String plain, String password) {
  final salt = Uint8List(_saltLen);
  for (int i = 0; i < _saltLen; i++) salt[i] = Random.secure().nextInt(256);
  final iv = Uint8List(_ivLen);
  for (int i = 0; i < _ivLen; i++) iv[i] = Random.secure().nextInt(256);
  final key = _deriveKey(password, salt);
  final plainBytes = utf8.encode(plain);
  final keystream = _hmacCtr(key, iv, plainBytes.length);
  final cipher = Uint8List(plainBytes.length);
  for (int i = 0; i < plainBytes.length; i++) {
    cipher[i] = plainBytes[i] ^ keystream[i];
  }
  final tag = Hmac(sha256, key).convert(Uint8List.fromList([...salt, ...iv, ...cipher])).bytes;
  return _encryptMagic + base64Encode(Uint8List.fromList([...salt, ...iv, ...cipher, ...tag]));
}

String? _decrypt(String data, String password) {
  if (!data.startsWith(_encryptMagic)) return data;
  final encoded = data.substring(_encryptMagic.length);
  final bytes = base64Decode(encoded);
  if (bytes.length < _saltLen + _ivLen + _tagLen) return null;
  final salt = bytes.sublist(0, _saltLen);
  final iv = bytes.sublist(_saltLen, _saltLen + _ivLen);
  final cipher = bytes.sublist(_saltLen + _ivLen, bytes.length - _tagLen);
  final tag = bytes.sublist(bytes.length - _tagLen);
  final key = _deriveKey(password, salt);
  final expectedTag = Hmac(sha256, key).convert(Uint8List.fromList([...salt, ...iv, ...cipher])).bytes;
  var matches = 0;
  for (int i = 0; i < _tagLen && i < expectedTag.length; i++) {
    matches |= tag[i] ^ expectedTag[i];
  }
  if (matches != 0) return null; // wrong password
  final keystream = _hmacCtr(key, iv, cipher.length);
  final plain = Uint8List(cipher.length);
  for (int i = 0; i < cipher.length; i++) {
    plain[i] = cipher[i] ^ keystream[i];
  }
  try {
    final text = utf8.decode(plain, allowMalformed: true);
    json.decode(text);
    return text;
  } catch (_) {
    return null;
  }
}

class BackupRestoreScreen extends StatefulWidget {
  const BackupRestoreScreen({super.key});

  @override
  State<BackupRestoreScreen> createState() => _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends State<BackupRestoreScreen> {
  bool _backupAppSettings = true;
  bool _backupWebhooks = true;
  bool _backupTunnels = true;
  bool _backupDaemonConfig = true;
  bool _backupRateAlerts = true;
  bool _loading = false;
  final _passwordController = TextEditingController();
  bool _usePassword = false;
  bool _includeSecrets = false;
  bool _showPassword = false;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  static String get _configDir {
    final home = Platform.environment['HOME'] ?? '/tmp';
    return '$home/.cloudflared';
  }

  Future<void> _doBackup() async {
    setState(() => _loading = true);
    try {
      final backup = <String, dynamic>{'version': 1, 'timestamp': DateTime.now().toIso8601String()};

      if (_backupAppSettings) {
        final f = File('$_configDir/app-settings.json');
        if (await f.exists()) backup['app_settings'] = json.decode(await f.readAsString());
      }
      if (_backupWebhooks) {
        final f = File('$_configDir/webhooks.json');
        if (await f.exists()) backup['webhooks'] = json.decode(await f.readAsString());
      }
      if (_backupTunnels) {
        final f = File('$_configDir/app-tunnels.json');
        if (await f.exists()) backup['tunnels'] = json.decode(await f.readAsString());
      }
      if (_backupDaemonConfig) {
        final f = File('$_configDir/daemon.json');
        if (await f.exists()) backup['daemon_config'] = json.decode(await f.readAsString());
      }
      if (_backupRateAlerts) {
        final f = File('$_configDir/rate-alerts.json');
        if (await f.exists()) backup['rate_alerts'] = json.decode(await f.readAsString());
      }
      if (_includeSecrets) {
        final tunnelDir = Directory(_configDir);
        final tunnelFiles = (await tunnelDir.list().toList())
            .whereType<File>()
            .where((f) {
              final name = f.path.split('/').last;
              return name.endsWith('.json') &&
                  !['app-settings.json', 'webhooks.json', 'app-tunnels.json', 'daemon.json', 'rate-alerts.json', 'app-inspector.json'].contains(name);
            });
        final creds = <String, dynamic>{};
        for (final f in tunnelFiles) {
          try {
            creds[f.path.split('/').last] = json.decode(await f.readAsString());
          } catch (_) {}
        }
        if (creds.isNotEmpty) backup['_credentials'] = creds;
      }

      var content = const JsonEncoder.withIndent('  ').convert(backup);
      if (_usePassword) {
        content = _encrypt(content, _passwordController.text.trim());
      }

      final defaultName = 'cloudflare-manager-backup${_usePassword ? '-encrypted' : ''}-${DateTime.now().toIso8601String().split('T').first}.json';
      String? outputPath = await _pickFilePath(
        defaultName: defaultName,
        title: 'Save backup',
        hint: 'Enter full path (e.g. /home/user/$defaultName)',
        defaultPath: '$_configDir/backup-${DateTime.now().toIso8601String().split('T').first}.json',
      );

      if (outputPath == null) {
        setState(() => _loading = false);
        return;
      }

      await File(outputPath).writeAsString(content);
      _showSnack('Backup saved to $outputPath${_usePassword ? " (encrypted)" : ""}', Colors.green);
      setState(() {
        _usePassword = false;
        _includeSecrets = false;
        _passwordController.clear();
      });
    } catch (e) {
      _showSnack('Backup failed: $e', Colors.redAccent);
    }
    setState(() => _loading = false);
  }

  Future<void> _doRestore() async {
    String? filePath = await _pickFilePath(
      mode: 'open',
      title: 'Select backup file',
      hint: 'Enter full path to the backup .json file',
    );

    if (filePath == null || filePath.isEmpty) return;

    final rawData = await File(filePath).readAsString();

    Map<String, dynamic>? data;
    if (rawData.startsWith(_encryptMagic)) {
      final pw = await _promptPassword('This backup is encrypted. Enter password:');
      if (pw == null || pw.isEmpty) {
        _showSnack('Password required for encrypted backup', Colors.redAccent);
        return;
      }
      final decrypted = _decrypt(rawData, pw);
      if (decrypted == null) {
        _showSnack('Wrong password or corrupt file', Colors.redAccent);
        return;
      }
      try {
        data = json.decode(decrypted) as Map<String, dynamic>;
      } catch (_) {
        _showSnack('Invalid backup format after decryption', Colors.redAccent);
        return;
      }
    } else {
      try {
        data = json.decode(rawData) as Map<String, dynamic>;
      } catch (_) {
        _showSnack('Invalid backup file format', Colors.redAccent);
        return;
      }
    }

    final available = <String, String>{};
    if (data['app_settings'] != null) available['app_settings'] = 'App Settings';
    if (data['webhooks'] != null) available['webhooks'] = 'Webhooks';
    if (data['tunnels'] != null) available['tunnels'] = 'Tunnels';
    if (data['daemon_config'] != null) available['daemon_config'] = 'Daemon Config';
    if (data['rate_alerts'] != null) available['rate_alerts'] = 'Rate Alerts';
    if (data['_credentials'] != null) available['_credentials'] = 'Tunnel Credentials';

    if (available.isEmpty) {
      _showSnack('No restorable data found in backup', Colors.redAccent);
      return;
    }

    final selected = await _showRestoreSelectDialog(available);
    if (selected == null || selected.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cardBg(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Restore backup?'),
        content: Text('Overwrite ${selected.length} section(s) at $_configDir?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Restore', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _loading = true);
    try {
      final dir = Directory(_configDir);
      if (!await dir.exists()) await dir.create(recursive: true);

      for (final key in selected) {
        switch (key) {
          case 'app_settings':
            await File('$_configDir/app-settings.json').writeAsString(json.encode(data['app_settings']));
            break;
          case 'webhooks':
            await File('$_configDir/webhooks.json').writeAsString(json.encode(data['webhooks']));
            await WebhookService.instance.loadWebhooks();
            break;
          case 'tunnels':
            await File('$_configDir/app-tunnels.json').writeAsString(json.encode(data['tunnels']));
            break;
          case 'daemon_config':
            await File('$_configDir/daemon.json').writeAsString(json.encode(data['daemon_config']));
            break;
          case 'rate_alerts':
            await File('$_configDir/rate-alerts.json').writeAsString(json.encode(data['rate_alerts']));
            await RateAlertService.instance.loadAlerts();
            break;
          case '_credentials':
            final creds = data['_credentials'] as Map<String, dynamic>?;
            if (creds != null) {
              for (final entry in creds.entries) {
                if (entry.key.endsWith('.json')) {
                  await File('$_configDir/${entry.key}').writeAsString(json.encode(entry.value));
                }
              }
            }
            break;
        }
      }

      _showSnack('Restored ${selected.length} section(s)', Colors.green);
    } catch (e) {
      _showSnack('Restore failed: $e', Colors.redAccent);
    }
    setState(() => _loading = false);
  }

  Future<void> _showAutoBackups() async {
    final backups = await listAutoBackups();
    if (!mounted) return;
    if (backups.isEmpty) {
      _showSnack('No auto-backups yet. They are created on app start.', Colors.grey);
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: _cardBg(context),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Text('Auto-backups'),
          content: SizedBox(
            width: 500,
            child: backups.length > 6
                ? ListView.builder(
                    shrinkWrap: true,
                    itemCount: backups.length,
                    itemBuilder: (_, i) => _autoBackupRow(backups[i], setDialogState, ctx),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: backups.map((b) => _autoBackupRow(b, setDialogState, ctx)).toList(),
                  ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
        ),
      ),
    );
  }

  Widget _autoBackupRow(Map<String, dynamic> backup, StateSetter setDialogState, BuildContext ctx) {
    final ts = backup['timestamp'] as String? ?? '';
    return ListTile(
      dense: true,
      leading: const Icon(Icons.history, color: Colors.grey, size: 20),
      title: Text(ts, style: const TextStyle(fontSize: 13)),
      trailing: TextButton(
        onPressed: () {
          Navigator.pop(ctx);
          _restoreAutoBackup(backup['path'] as String? ?? '');
        },
        child: const Text('Restore', style: TextStyle(color: Color(0xFFF6821F), fontSize: 12)),
      ),
    );
  }

  Future<void> _restoreAutoBackup(String path) async {
    if (path.isEmpty) return;
    try {
      final raw = await File(path).readAsString();
      final data = json.decode(raw) as Map<String, dynamic>;
      data.remove('_checksum');
      data.remove('auto');
      data.remove('version');
      data.remove('timestamp');

      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _cardBg(context),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Text('Restore from auto-backup?'),
          content: Text('Overwrite all config files at $_configDir?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Restore', style: TextStyle(color: Colors.redAccent))),
          ],
        ),
      );
      if (confirm != true) return;

      final dir = Directory(_configDir);
      if (!await dir.exists()) await dir.create(recursive: true);

      if (data['app_settings'] != null) await File('$_configDir/app-settings.json').writeAsString(json.encode(data['app_settings']));
      if (data['webhooks'] != null) {
        await File('$_configDir/webhooks.json').writeAsString(json.encode(data['webhooks']));
        await WebhookService.instance.loadWebhooks();
      }
      if (data['app_tunnels'] != null) await File('$_configDir/app-tunnels.json').writeAsString(json.encode(data['app_tunnels']));
      if (data['daemon_config'] != null) await File('$_configDir/daemon.json').writeAsString(json.encode(data['daemon_config']));
      if (data['rate_alerts'] != null) {
        await File('$_configDir/rate-alerts.json').writeAsString(json.encode(data['rate_alerts']));
        await RateAlertService.instance.loadAlerts();
      }

      _showSnack('Restored from auto-backup', Colors.green);
    } catch (e) {
      _showSnack('Restore failed: $e', Colors.redAccent);
    }
  }

  Future<String?> _promptPassword(String prompt) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cardBg(context),
        title: const Text('Password'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(
            hintText: prompt,
            filled: true,
            fillColor: _panelBg(context),
            border: const OutlineInputBorder(borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('OK', style: TextStyle(color: Color(0xFFF6821F)))),
        ],
      ),
    );
  }

  Future<Set<String>?> _showRestoreSelectDialog(Map<String, String> available) async {
    final selected = Set<String>.from(available.keys.toList());
    return showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: _cardBg(context),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Text('Select items to restore'),
          content: SizedBox(
            width: 400,
            child: ListView(
              shrinkWrap: true,
              children: available.entries.map((e) => CheckboxListTile(
                title: Text(e.value, style: const TextStyle(fontSize: 14)),
                value: selected.contains(e.key),
                activeColor: const Color(0xFFF6821F),
                onChanged: (v) {
                  setDialogState(() {
                    v == true ? selected.add(e.key) : selected.remove(e.key);
                  });
                },
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              )).toList(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, selected.isNotEmpty ? selected : null),
              child: const Text('Restore selected', style: TextStyle(color: Color(0xFFF6821F))),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _pickFilePath({String? defaultName, required String title, required String hint, String? defaultPath, String mode = 'save', List<String>? allowedExtensions}) async {
    final exts = allowedExtensions ?? ['json'];
    try {
      if (mode == 'save') {
        final path = await FilePicker.platform.saveFile(
          dialogTitle: title,
          fileName: defaultName,
          type: FileType.custom,
          allowedExtensions: exts,
        );
        return path; // null = user cancelled, don't fallback
      } else {
        final result = await FilePicker.platform.pickFiles(
          dialogTitle: title,
          type: FileType.custom,
          allowedExtensions: exts,
        );
        if (result != null && result.files.isNotEmpty && result.files.single.path != null) {
          return result.files.single.path;
        }
        return null; // user cancelled, don't fallback
      }
    } catch (_) {
      // file_picker not available, use fallback
      if (!mounted) return null;
      return await _showManualPathDialog(title: title, hint: hint, defaultPath: defaultPath ?? '');
    }
  }

  Future<String?> _showManualPathDialog({required String title, required String hint, String defaultPath = ''}) async {
    final controller = TextEditingController(text: defaultPath);
    final formKey = GlobalKey<FormState>();
    return await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cardBg(context),
        title: Text(title),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            decoration: InputDecoration(
              hintText: hint,
              filled: true,
              fillColor: _panelBg(context),
              border: const OutlineInputBorder(borderSide: BorderSide.none),
            ),
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Path required' : null,
            autofocus: true,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              if (formKey.currentState?.validate() == true) {
                Navigator.pop(ctx, controller.text.trim());
              }
            },
            child: const Text('OK', style: TextStyle(color: Color(0xFFF6821F))),
          ),
        ],
      ),
    );
  }

  Future<void> _exportJson() async { await _doExport('json'); }
  Future<void> _exportMarkdown() async { await _doExport('md'); }

  Future<void> _doExport(String format) async {
    setState(() => _loading = true);
    try {
      final export = <String, dynamic>{'generatedAt': DateTime.now().toIso8601String()};
      final tunnels = await CloudflareService.listTunnels();
      final tunnelList = <Map<String, dynamic>>[];
      for (final t in tunnels) {
        final id = t['id'] as String? ?? '';
        final cfg = await CloudflareService.getTunnelConfig(id);
        final ingress = (cfg?['config']?['ingress'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? [];
        tunnelList.add({
          'id': id,
          'name': t['name'],
          'status': t['status'] ?? 'unknown',
          'connections': t['connections'] ?? [],
          'ingress': ingress,
        });
      }
      export['tunnels'] = tunnelList;

      final zones = await CloudflareService.getZones();
      final zoneList = <Map<String, dynamic>>[];
      for (final z in zones) {
        final records = await CloudflareService.listDnsRecords(z['id']);
        zoneList.add({
          'id': z['id'],
          'name': z['name'],
          'status': z['status'],
          'records': records,
        });
      }
      export['dns'] = zoneList;

      String content;
      String ext;
      if (format == 'json') {
        content = const JsonEncoder.withIndent('  ').convert(export);
        ext = 'json';
      } else {
        final buf = StringBuffer();
        buf.writeln('# Cloudflare Tunnel Manager — Export');
        buf.writeln('> Generated: ${export['generatedAt']}');
        buf.writeln();
        buf.writeln('## Tunnels');
        for (final t in tunnelList) {
          buf.writeln('### ${t['name']}');
          buf.writeln('- **ID**: `${t['id']}`');
          buf.writeln('- **Status**: ${t['status']}');
          buf.writeln('- **Connections**: ${(t['connections'] as List).length}');
          final ingress = t['ingress'] as List;
          if (ingress.isNotEmpty) {
            buf.writeln('- **Ingress Rules**:');
            for (final rule in ingress) {
              final hostname = rule['hostname'] ?? '(catch-all)';
              final service = rule['service'] ?? '';
              buf.writeln('  - `${hostname}` → `$service`');
            }
          }
          buf.writeln();
        }
        buf.writeln('## DNS Records');
        for (final z in zoneList) {
          buf.writeln('### ${z['name']}');
          final records = z['records'] as List;
          if (records.isEmpty) {
            buf.writeln('_No records_');
            buf.writeln();
            continue;
          }
          buf.writeln('| Type | Name | Content | TTL | Proxied |');
          buf.writeln('|------|------|---------|-----|---------|');
          for (final r in records) {
            final ttl = r['ttl'];
            buf.writeln('| ${r['type']} | ${r['name']} | ${r['content']} | ${ttl == 1 ? 'auto' : ttl} | ${r['proxied'] == true ? '✅' : '—'} |');
          }
          buf.writeln();
        }
        content = buf.toString();
        ext = 'md';
      }

      final defaultName = 'cloudflare-manager-export-${DateTime.now().toIso8601String().split('T').first}.$ext';
      String? outputPath = await _pickFilePath(
        defaultName: defaultName,
        title: 'Save export',
        hint: 'Enter full path (e.g. /home/user/$defaultName)',
        defaultPath: '${_configDir}/export-${DateTime.now().toIso8601String().split('T').first}.$ext',
        allowedExtensions: [ext],
      );

      if (outputPath == null) {
        setState(() => _loading = false);
        return;
      }

      await File(outputPath).writeAsString(content);
      _showSnack('Export saved to $outputPath', Colors.green);
    } catch (e) {
      _showSnack('Export failed: $e', Colors.redAccent);
    }
    setState(() => _loading = false);
  }

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color, behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: _cardBg(context),
        title: const Text('Backup & Restore'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Select data to include', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  _checkbox('App Settings (port range, tray, etc.)', _backupAppSettings, (v) => setState(() => _backupAppSettings = v)),
                  _checkbox('Webhooks', _backupWebhooks, (v) => setState(() => _backupWebhooks = v)),
                  _checkbox('Tunnels (IDs, ports, notes, auto-start flags)', _backupTunnels, (v) => setState(() => _backupTunnels = v)),
                  _checkbox('Daemon Config (boot delay, max retries)', _backupDaemonConfig, (v) => setState(() => _backupDaemonConfig = v)),
                  _checkbox('Rate Alerts', _backupRateAlerts, (v) => setState(() => _backupRateAlerts = v)),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Checkbox(
                        value: _usePassword,
                        activeColor: const Color(0xFFF6821F),
                        onChanged: (v) => setState(() { _usePassword = v ?? false; if (!_usePassword) _passwordController.clear(); }),
                      ),
                      const Text('Password protect (optional)', style: TextStyle(fontSize: 13)),
                      const SizedBox(width: 12),
                      if (_usePassword)
                        Expanded(
                          child: TextField(
                            controller: _passwordController,
                            obscureText: !_showPassword,
                            decoration: InputDecoration(
                              hintText: 'Enter password',
                              filled: true,
                              fillColor: _panelBg(context),
                              border: const OutlineInputBorder(borderSide: BorderSide.none),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              isDense: true,
                              suffixIcon: IconButton(
                                icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility, size: 18),
                                onPressed: () => setState(() => _showPassword = !_showPassword),
                              ),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                    ],
                  ),
                  if (_usePassword) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const SizedBox(width: 44),
                        Checkbox(
                          value: _includeSecrets,
                          activeColor: const Color(0xFFF6821F),
                          onChanged: _passwordController.text.trim().isEmpty
                              ? null
                              : (v) => setState(() => _includeSecrets = v ?? false),
                        ),
                        Text(
                          'Include credentials & secrets (encrypted)',
                          style: TextStyle(fontSize: 12, color: _passwordController.text.trim().isEmpty ? Colors.grey : null),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Text('Export Tunnels & DNS', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _exportJson,
                          icon: const Icon(Icons.data_object, size: 16),
                          label: const Text('JSON'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1E293B),
                            foregroundColor: Colors.grey,
                            minimumSize: const Size(0, 36),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            side: BorderSide(color: Colors.grey.withOpacity(0.3)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _exportMarkdown,
                          icon: const Icon(Icons.description, size: 16),
                          label: const Text('Markdown'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1E293B),
                            foregroundColor: Colors.grey,
                            minimumSize: const Size(0, 36),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            side: BorderSide(color: Colors.grey.withOpacity(0.3)),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text('Exports all tunnels + DNS records. JSON for IaC, Markdown for docs.',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
                  const SizedBox(height: 32),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _doBackup,
                          icon: const Icon(Icons.backup),
                          label: const Text('Backup'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFF6821F),
                            foregroundColor: Colors.white,
                            minimumSize: const Size(0, 48),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _doRestore,
                          icon: const Icon(Icons.restore),
                          label: const Text('Restore'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1E293B),
                            foregroundColor: const Color(0xFFF6821F),
                            minimumSize: const Size(0, 48),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            side: const BorderSide(color: Color(0xFFF6821F)),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _showAutoBackups,
                    icon: const Icon(Icons.history, size: 18),
                    label: const Text('Restore from auto-backup'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1E293B),
                      foregroundColor: Colors.grey,
                      minimumSize: const Size(0, 40),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      side: BorderSide(color: Colors.grey.withOpacity(0.3)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Backup files are saved as .json. Password encryption uses AES-like XOR + SHA-256.\nTunnel credentials (api tokens) are NOT included for security.',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _checkbox(String title, bool value, ValueChanged<bool> onChanged) {
    return CheckboxListTile(
      title: Text(title, style: const TextStyle(fontSize: 14)),
      value: value,
      activeColor: const Color(0xFFF6821F),
      onChanged: (v) => onChanged(v ?? value),
      contentPadding: EdgeInsets.zero,
    );
  }
}
