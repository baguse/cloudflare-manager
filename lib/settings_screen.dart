import 'package:flutter/material.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'cloudflare_service.dart';
import 'daemon/cf_api_client.dart';
import 'tray_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _storage = const FlutterSecureStorage();
  final _tokenController = TextEditingController();
  final _accountIdController = TextEditingController();
  final _minPortController = TextEditingController();
  final _maxPortController = TextEditingController();
  bool _isLoading = false;
  int? _autoBindMinPort;
  int? _autoBindMaxPort;
  bool _closeToTray = false;
  bool _autoStart = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
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

    setState(() => _isLoading = false);
  }

  Future<void> _saveSettings() async {
    setState(() => _isLoading = true);
    await _storage.write(key: CloudflareService.tokenKey, value: _tokenController.text.trim());
    await _storage.write(key: CloudflareService.accountIdKey, value: _accountIdController.text.trim());
    await CfApiClient.setToken(_tokenController.text.trim());
    await CfApiClient.setAccountId(_accountIdController.text.trim());
    await _savePortRange();

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
        Navigator.pop(context);
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
