import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'rate_alert.dart';
import 'rate_alert_service.dart';
import 'webhook_service.dart';

class RateAlertScreen extends StatefulWidget {
  const RateAlertScreen({Key? key}) : super(key: key);

  @override
  State<RateAlertScreen> createState() => _RateAlertScreenState();
}

class _RateAlertScreenState extends State<RateAlertScreen> {
  List<RateAlertConfig> _alerts = [];
  bool _loading = true;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    await RateAlertService.instance.loadAlerts();
    setState(() {
      _alerts = RateAlertService.instance.alerts;
      _loading = false;
    });
  }

  Future<void> _deleteAlert(String id) async {
    await RateAlertService.instance.deleteAlert(id);
    await _load();
  }

  Future<void> _toggleAlert(RateAlertConfig alert) async {
    final updated = alert.copyWith(enabled: !alert.enabled);
    await RateAlertService.instance.updateAlert(updated);
    await _load();
  }

  Future<void> _runCheck() async {
    setState(() => _checking = true);
    final results = await RateAlertService.instance.checkNow();
    await _load();
    setState(() => _checking = false);
    if (mounted) {
      final items = results.entries.map((e) => '${e.key}: ${e.value?.toString() ?? "N/A"} req/h').join('\n');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Check complete:\n$items'), duration: const Duration(seconds: 5)),
      );
    }
  }

  void _showEditor({RateAlertConfig? alert}) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => RateAlertEditorScreen(alert: alert)),
    );
    if (result == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a1a),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2d2d2d),
        title: const Text('Rate Alerts'),
        actions: [
          if (_alerts.isNotEmpty)
            IconButton(
              icon: _checking ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh),
              tooltip: 'Check All Now',
              onPressed: _checking ? null : _runCheck,
            ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _showEditor(),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _alerts.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.speed, size: 64, color: Colors.grey),
                      const SizedBox(height: 16),
                      const Text('No rate alerts', style: TextStyle(fontSize: 18, color: Colors.grey)),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('Add Alert'),
                        onPressed: () => _showEditor(),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _alerts.length,
                  itemBuilder: (context, index) {
                    final alert = _alerts[index];
                    return Card(
                      color: const Color(0xFF2d2d2d),
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        leading: Icon(Icons.speed, color: alert.enabled ? const Color(0xFFF6821F) : Colors.grey),
                        title: Text(alert.name),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(alert.domain, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                            Text(
                              'Threshold: ${_formatCount(alert.thresholdPerHour)} req/h',
                              style: const TextStyle(fontSize: 11, color: Colors.grey),
                            ),
                            if (alert.lastRequestCount != null)
                              Text(
                                'Last check: ${_formatCount(alert.lastRequestCount!)} req/h at ${_formatTime(alert.lastCheckedAt!)}',
                                style: const TextStyle(fontSize: 10, color: Colors.grey),
                              ),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Switch(value: alert.enabled, onChanged: (_) => _toggleAlert(alert), activeColor: Colors.green),
                            IconButton(icon: const Icon(Icons.edit, size: 20), onPressed: () => _showEditor(alert: alert)),
                            IconButton(icon: const Icon(Icons.delete, size: 20, color: Colors.redAccent), onPressed: () => _deleteAlert(alert.id)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  String _formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return n.toString();
  }

  String _formatTime(DateTime dt) {
    final p = (int v) => v.toString().padLeft(2, '0');
    return '${p(dt.hour)}:${p(dt.minute)}';
  }
}

class RateAlertEditorScreen extends StatefulWidget {
  final RateAlertConfig? alert;
  const RateAlertEditorScreen({Key? key, this.alert}) : super(key: key);

  @override
  State<RateAlertEditorScreen> createState() => _RateAlertEditorScreenState();
}

class _RateAlertEditorScreenState extends State<RateAlertEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _domainController;
  late TextEditingController _thresholdController;
  String? _selectedWebhookId;
  bool _enabled = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final alert = widget.alert;
    _nameController = TextEditingController(text: alert?.name ?? '');
    _domainController = TextEditingController(text: alert?.domain ?? '');
    _thresholdController = TextEditingController(text: alert?.thresholdPerHour.toString() ?? '10000');
    _selectedWebhookId = alert?.webhookId;
    _enabled = alert?.enabled ?? true;
    WebhookService.instance.loadWebhooks();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _domainController.dispose();
    _thresholdController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);

    final alert = RateAlertConfig(
      id: widget.alert?.id ?? const Uuid().v4(),
      name: _nameController.text.trim(),
      domain: _domainController.text.trim(),
      thresholdPerHour: int.tryParse(_thresholdController.text.trim()) ?? 10000,
      webhookId: _selectedWebhookId,
      enabled: _enabled,
    );

    if (widget.alert != null) {
      await RateAlertService.instance.updateAlert(alert);
    } else {
      await RateAlertService.instance.addAlert(alert);
    }

    setState(() => _saving = false);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final webhooks = WebhookService.instance.webhooks;

    return Scaffold(
      backgroundColor: const Color(0xFF1a1a1a),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2d2d2d),
        title: Text(widget.alert == null ? 'New Alert' : 'Edit Alert'),
        actions: [
          TextButton.icon(
            icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save),
            label: const Text('Save'),
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder(), hintText: 'My API rate alert'),
              validator: (v) => v?.trim().isEmpty == true ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _domainController,
              decoration: const InputDecoration(labelText: 'Domain', border: OutlineInputBorder(), hintText: 'api.example.com'),
              validator: (v) => v?.trim().isEmpty == true ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _thresholdController,
              decoration: const InputDecoration(labelText: 'Threshold (requests/hour)', border: OutlineInputBorder(), hintText: '10000'),
              keyboardType: TextInputType.number,
              validator: (v) {
                if (v?.trim().isEmpty == true) return 'Required';
                if (int.tryParse(v!.trim()) == null) return 'Enter a number';
                return null;
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String?>(
              value: _selectedWebhookId,
              decoration: const InputDecoration(labelText: 'Notify via Webhook', border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem(value: null, child: Text('None')),
                ...webhooks.map((w) => DropdownMenuItem(value: w.id, child: Text('${w.name} (${w.type.name.toUpperCase()})'))),
              ],
              onChanged: (v) => setState(() => _selectedWebhookId = v),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('Enabled'),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
              activeColor: Colors.green,
            ),
          ],
        ),
      ),
    );
  }
}
