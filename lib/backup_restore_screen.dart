import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'webhook_service.dart';
import 'rate_alert_service.dart';

Color _cardBg(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF1E293B) : Colors.white;

Color _panelBg(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF0F172A) : const Color(0xFFF5F5F5);

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

      final defaultName = 'cloudflare-manager-backup-${DateTime.now().toIso8601String().split('T').first}.json';
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

      await File(outputPath).writeAsString(const JsonEncoder.withIndent('  ').convert(backup));
      _showSnack('Backup saved to $outputPath', Colors.green);
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

    Map<String, dynamic>? data;
    try {
      data = json.decode(await File(filePath).readAsString());
      if (data is! Map<String, dynamic>) {
        _showSnack('Invalid backup file format', Colors.redAccent);
        return;
      }
    } catch (e) {
      _showSnack('Failed to read backup: $e', Colors.redAccent);
      return;
    }

    final available = <String, String>{};
    if (data['app_settings'] != null) available['app_settings'] = 'App Settings';
    if (data['webhooks'] != null) available['webhooks'] = 'Webhooks';
    if (data['tunnels'] != null) available['tunnels'] = 'Tunnels';
    if (data['daemon_config'] != null) available['daemon_config'] = 'Daemon Config';
    if (data['rate_alerts'] != null) available['rate_alerts'] = 'Rate Alerts';

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
        }
      }

      _showSnack('Restored ${selected.length} section(s)', Colors.green);
    } catch (e) {
      _showSnack('Restore failed: $e', Colors.redAccent);
    }
    setState(() => _loading = false);
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

  Future<String?> _pickFilePath({String? defaultName, required String title, required String hint, String? defaultPath, String mode = 'save'}) async {
    try {
      if (mode == 'save') {
        final path = await FilePicker.platform.saveFile(
          dialogTitle: title,
          fileName: defaultName,
          type: FileType.custom,
          allowedExtensions: ['json'],
        );
        if (path != null) return path;
      } else {
        final result = await FilePicker.platform.pickFiles(
          dialogTitle: title,
          type: FileType.custom,
          allowedExtensions: ['json'],
        );
        if (result != null && result.files.isNotEmpty && result.files.single.path != null) {
          return result.files.single.path;
        }
      }
    } catch (_) {}

    if (!mounted) return null;
    return await _showManualPathDialog(title: title, hint: hint, defaultPath: defaultPath ?? '');
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

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color, behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _panelBg(context),
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
                            backgroundColor: _cardBg(context),
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
                  const Text(
                    'Backup files are saved as .json.\nTunnel credentials (api tokens) are NOT included for security.',
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
