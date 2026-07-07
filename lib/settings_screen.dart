import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'cloudflare_service.dart';
import 'daemon/cf_api_client.dart';
import 'daemon/http_api.dart';
import 'daemon/ipc_client.dart';
import 'tray_service.dart';
import 'app_storage.dart';

class SettingsScreen extends StatefulWidget {
  final VoidCallback? onPortRangeChanged;
  const SettingsScreen({super.key, this.onPortRangeChanged});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _storage = AppStorage.instance;
  final _tokenController = TextEditingController();
  final _accountIdController = TextEditingController();
  final _minPortController = TextEditingController();
  final _maxPortController = TextEditingController();
  final _bootDelayController = TextEditingController();
  final _maxRetriesController = TextEditingController();
  bool _isLoading = false;
  int? _autoBindMinPort;
  int? _autoBindMaxPort;
  int _bootDelaySeconds = 3;
  int _maxStartRetries = 10;
  bool _closeToTray = false;
  bool _autoStart = false;

  String? _apiKey;
  int _apiPort = 9845;
  bool _apiEnabled = false;
  HttpApiServer? _apiServer;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadApiConfig() async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final keyFile = File('$home/.cloudflared/api-key');
    if (await keyFile.exists()) {
      _apiKey = (await keyFile.readAsString()).trim();
    }
    if (_apiKey == null || _apiKey!.isEmpty) {
      _apiKey = 'cm_${_randomString(32)}_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
      await keyFile.parent.create(recursive: true);
      await keyFile.writeAsString(_apiKey!);
    }
    final portStr = await _storage.read(key: 'api_port');
    if (portStr != null) _apiPort = int.tryParse(portStr) ?? 9845;
    final enabled = await _storage.read(key: 'api_enabled');
    _apiEnabled = enabled == 'true';
  }

  String _randomString(int length) {
    final r = Random();
    return String.fromCharCodes(List.generate(length, (_) => r.nextInt(26) + 97));
  }

  Future<void> _regenerateApiKey() async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final keyFile = File('$home/.cloudflared/api-key');
    final newKey = 'cm_${_randomString(32)}_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    await keyFile.parent.create(recursive: true);
    await keyFile.writeAsString(newKey);
    setState(() => _apiKey = newKey);
    _showSnack('API key regenerated. Copy it now — it won\'t be shown again.', Colors.orange);
    // Restart API server to pick up new key
    try {
      final client = DaemonClient();
      if (await client.connect()) {
        await client.send('api_restart');
        client.disconnect();
      }
    } catch (_) {}
    if (_apiServer != null) {
      await _apiServer?.stop();
      _apiServer = HttpApiServer(port: _apiPort, apiKey: _apiKey!);
      await _apiServer?.start();
    }
  }

  Future<void> _toggleApi(bool enabled) async {
    setState(() => _apiEnabled = enabled);
    await _storage.write(key: 'api_enabled', value: enabled.toString());
    try {
      final client = DaemonClient();
      if (await client.connect()) {
        await client.send('api_restart');
        client.disconnect();
        _showSnack(enabled ? 'API server will restart via daemon' : 'API settings saved', Colors.grey);
        return;
      }
    } catch (_) {}
    if (enabled) {
      try {
        _apiServer = HttpApiServer(port: _apiPort, apiKey: _apiKey!);
        await _apiServer!.start();
        _showSnack('API server running on port $_apiPort');
      } catch (e) {
        setState(() => _apiEnabled = false);
        _showSnack('Failed to start API server: $e', Colors.redAccent);
      }
    } else {
      await _apiServer?.stop();
      _apiServer = null;
      _showSnack('API server stopped', Colors.grey);
    }
  }

  void _showSnack(String msg, [Color color = Colors.green]) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color, behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _loadSettings() async {
    setState(() => _isLoading = true);
    final token = await _storage.read(key: CloudflareService.tokenKey);
    final accountId = await _storage.read(key: CloudflareService.accountIdKey);
    final min = await _storage.read(key: 'auto_bind_min_port');
    final max = await _storage.read(key: 'auto_bind_max_port');
    final closeToTray = await _storage.read(key: 'close_to_tray');
    final autoStart = await _storage.read(key: 'auto_start');

    if (token != null) _tokenController.text = token;
    if (accountId != null) _accountIdController.text = accountId;
    if (min != null) {
      _autoBindMinPort = int.tryParse(min);
      _minPortController.text = min;
    }
    if (max != null) {
      _autoBindMaxPort = int.tryParse(max);
      _maxPortController.text = max;
    }
    _closeToTray = closeToTray == 'true';
    _autoStart = autoStart == 'true';

    await _loadDaemonConfig();
    await _loadApiConfig();

    setState(() => _isLoading = false);
  }

  Future<void> _loadDaemonConfig() async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final file = File('$home/.cloudflared/daemon.json');
    if (!await file.exists()) return;
    try {
      final data = json.decode(await file.readAsString());
      if (data is Map) {
        if (data['bootDelaySeconds'] is int) {
          _bootDelaySeconds = data['bootDelaySeconds'] as int;
        }
        if (data['maxStartRetries'] is int) {
          _maxStartRetries = data['maxStartRetries'] as int;
        }
      }
    } catch (_) {}
    _bootDelayController.text = '$_bootDelaySeconds';
    _maxRetriesController.text = '$_maxStartRetries';
  }

  Future<void> _saveDaemonConfig() async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final dir = Directory('$home/.cloudflared');
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File('${dir.path}/daemon.json');
    await file.writeAsString(json.encode({
      'bootDelaySeconds': int.tryParse(_bootDelayController.text.trim()) ?? _bootDelaySeconds,
      'maxStartRetries': int.tryParse(_maxRetriesController.text.trim()) ?? _maxStartRetries,
    }));
  }

  Future<void> _saveSettings() async {
    setState(() => _isLoading = true);
    await _storage.write(key: CloudflareService.tokenKey, value: _tokenController.text.trim());
    await _storage.write(key: CloudflareService.accountIdKey, value: _accountIdController.text.trim());
    await CfApiClient.setToken(_tokenController.text.trim());
    await CfApiClient.setAccountId(_accountIdController.text.trim());
    await _savePortRange();
    await _saveDaemonConfig();

    final error = await CloudflareService.verifyToken();

    setState(() => _isLoading = false);

    if (mounted) {
      final messenger = ScaffoldMessenger.of(context);
      if (error == null) {
        messenger.showSnackBar(
          SnackBar(
            content: const Text('Settings saved and verified!'),
            backgroundColor: Colors.green,
            action: SnackBarAction(
              label: '✕',
              textColor: Colors.white70,
              onPressed: () => messenger.hideCurrentSnackBar(),
            ),
          ),
        );
        widget.onPortRangeChanged?.call();
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Error: $error'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: '✕',
              textColor: Colors.white70,
              onPressed: () => messenger.hideCurrentSnackBar(),
            ),
          ),
        );
      }
    }
  }

  Future<void> _savePortRange() async {
    if (_autoBindMinPort != null) {
      await _storage.write(key: 'auto_bind_min_port', value: _autoBindMinPort.toString());
    } else {
      await _storage.delete(key: 'auto_bind_min_port');
    }
    if (_autoBindMaxPort != null) {
      await _storage.write(key: 'auto_bind_max_port', value: _autoBindMaxPort.toString());
    } else {
      await _storage.delete(key: 'auto_bind_max_port');
    }
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _accountIdController.dispose();
    _minPortController.dispose();
    _maxPortController.dispose();
    _bootDelayController.dispose();
    _maxRetriesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cloudflare Settings'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16.0),
              child: ListView(
                children: [
                  const Text('Enter your Cloudflare API credentials to manage tunnels.'),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _accountIdController,
                    decoration: const InputDecoration(
                      labelText: 'Cloudflare Account ID',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _tokenController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Cloudflare API Token',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 32),
                  const Text('Auto-bind port range',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('Only show detection toast for new services within this port range. Leave empty to detect all ports.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _minPortController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Min port',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (v) {
                            _autoBindMinPort = int.tryParse(v);
                          },
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text('–', style: TextStyle(fontSize: 18, color: Colors.grey)),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _maxPortController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Max port',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (v) {
                            _autoBindMaxPort = int.tryParse(v);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  const Text('App Behavior',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    title: const Text('Minimize to tray on close'),
                    subtitle: const Text('App stays running in the system tray when you close the window'),
                    value: _closeToTray,
                    activeThumbColor: const Color(0xFFF6821F),
                    onChanged: (v) async {
                      setState(() => _closeToTray = v);
                      await TrayService.instance.setCloseToTray(v);
                    },
                  ),
                  SwitchListTile(
                    title: const Text('Launch on system startup'),
                    subtitle: const Text('Start automatically when you log in, minimized to tray'),
                    value: _autoStart,
                    activeThumbColor: const Color(0xFFF6821F),
                    onChanged: (v) async {
                      setState(() => _autoStart = v);
                      await TrayService.instance.setAutoStart(v);
                      if (v && !_closeToTray) {
                        setState(() => _closeToTray = true);
                        await TrayService.instance.setCloseToTray(true);
                      }
                    },
                  ),
                  const SizedBox(height: 32),
                  const Text('Daemon Boot Settings',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('Configure how the background daemon handles tunnel starts on system boot.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _bootDelayController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Boot delay (seconds)',
                            border: OutlineInputBorder(),
                            helperText: 'Wait before starting tunnels',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _maxRetriesController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Max start retries',
                            border: OutlineInputBorder(),
                            helperText: 'Retries per tunnel on boot',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  const Text('HTTP API Server',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    title: const Text('Enable HTTP API', style: TextStyle(fontSize: 14)),
                    subtitle: Text('Expose app features over HTTP on port $_apiPort', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    value: _apiEnabled,
                    activeThumbColor: const Color(0xFFF6821F),
                    onChanged: (v) => _toggleApi(v),
                  ),
                  if (_apiEnabled && _apiKey != null) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: SelectableText(
                              'API Key: $_apiKey',
                              style: const TextStyle(fontSize: 11, color: Colors.grey, fontFamily: 'monospace'),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy, size: 16, color: Colors.grey),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: _apiKey!));
                              _showSnack('API key copied', Colors.grey);
                            },
                            tooltip: 'Copy API key',
                          ),
                          IconButton(
                            icon: const Icon(Icons.refresh, size: 16, color: Colors.orange),
                            onPressed: _regenerateApiKey,
                            tooltip: 'Regenerate API key',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'curl -H "Authorization: Bearer $_apiKey" http://localhost:$_apiPort/health',
                        style: const TextStyle(fontSize: 10, color: Colors.grey, fontFamily: 'monospace'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _saveSettings,
                      child: const Text('Save & Verify'),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
