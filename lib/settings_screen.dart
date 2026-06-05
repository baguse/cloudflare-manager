import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'cloudflare_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _storage = const FlutterSecureStorage();
  final _tokenController = TextEditingController();
  final _accountIdController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    setState(() => _isLoading = true);
    final token = await _storage.read(key: CloudflareService.tokenKey);
    final accountId = await _storage.read(key: CloudflareService.accountIdKey);
    
    if (token != null) _tokenController.text = token;
    if (accountId != null) _accountIdController.text = accountId;
    
    setState(() => _isLoading = false);
  }

  Future<void> _saveSettings() async {
    setState(() => _isLoading = true);
    await _storage.write(key: CloudflareService.tokenKey, value: _tokenController.text.trim());
    await _storage.write(key: CloudflareService.accountIdKey, value: _accountIdController.text.trim());
    
    // Test connection
    final error = await CloudflareService.verifyToken();
    
    setState(() => _isLoading = false);
    
    if (mounted) {
      if (error == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings saved and verified!'), backgroundColor: Colors.green),
        );
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $error'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _saveSettings,
                      child: const Text('Save & Verify'),
                    ),
                  )
                ],
              ),
            ),
    );
  }
}
