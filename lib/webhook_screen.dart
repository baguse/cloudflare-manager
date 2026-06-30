import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'webhook_config.dart';
import 'webhook_service.dart';
import 'webhook_logs_screen.dart';
import 'daemon/ipc_client.dart';

class WebhookScreen extends StatefulWidget {
  const WebhookScreen({Key? key}) : super(key: key);

  @override
  State<WebhookScreen> createState() => _WebhookScreenState();
}

class _WebhookScreenState extends State<WebhookScreen> {
  List<WebhookConfig> _webhooks = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadWebhooks();
  }

  Future<void> _loadWebhooks() async {
    setState(() => _loading = true);
    await WebhookService.instance.loadWebhooks();
    setState(() {
      _webhooks = WebhookService.instance.webhooks;
      _loading = false;
    });
  }

  Future<void> _notifyDaemonReload() async {
    final client = DaemonClient();
    final connected = await client.connect();
    if (connected) {
      await client.reloadWebhooks();
      client.disconnect();
    }
  }

  Future<void> _deleteWebhook(String id) async {
    await WebhookService.instance.deleteWebhook(id);
    await _loadWebhooks();
    _notifyDaemonReload();
  }

  Future<void> _toggleWebhook(WebhookConfig webhook) async {
    final updated = webhook.copyWith(enabled: !webhook.enabled);
    await WebhookService.instance.updateWebhook(updated);
    await _loadWebhooks();
    _notifyDaemonReload();
  }

  void _showWebhookEditor({WebhookConfig? webhook}) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WebhookEditorScreen(webhook: webhook),
      ),
    );
    if (result == true) {
      await _loadWebhooks();
      _notifyDaemonReload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: const Text('Webhook Configuration'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'View Logs',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const WebhookLogsScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _showWebhookEditor(),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _webhooks.isEmpty
              ? _buildEmptyState()
              : _buildWebhookList(),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.webhook, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text(
            'No webhooks configured',
            style: TextStyle(fontSize: 18, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Add Webhook'),
            onPressed: () => _showWebhookEditor(),
          ),
        ],
      ),
    );
  }

  Widget _buildWebhookList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _webhooks.length,
      itemBuilder: (context, index) {
        final webhook = _webhooks[index];
        return Card(
          color: Theme.of(context).colorScheme.surface,
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: Icon(
              _getWebhookIcon(webhook.type),
              color: webhook.enabled ? Colors.green : Colors.grey,
            ),
            title: Text(webhook.name),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  webhook.type.name.toUpperCase(),
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
                if (webhook.url != null)
                  Text(
                    webhook.url!,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (webhook.webhookUrl != null)
                  Text(
                    webhook.webhookUrl!,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (webhook.botToken != null)
                  Text(
                    'Bot: ${webhook.botToken!.length > 20 ? '${webhook.botToken!.substring(0, 20)}...' : webhook.botToken}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                if (webhook.channelId != null)
                  Text(
                    'Chat: ${webhook.channelId}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                Text(
                  '${webhook.triggers.length} trigger(s)',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: webhook.enabled,
                  onChanged: (_) => _toggleWebhook(webhook),
                  activeColor: Colors.green,
                ),
                IconButton(
                  icon: const Icon(Icons.history, size: 20, color: Colors.grey),
                  tooltip: 'View Logs',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => WebhookLogsScreen(
                          webhookId: webhook.id,
                          webhookName: webhook.name,
                        ),
                      ),
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.edit, size: 20),
                  onPressed: () => _showWebhookEditor(webhook: webhook),
                ),
                IconButton(
                  icon: const Icon(Icons.delete, size: 20, color: Colors.redAccent),
                  onPressed: () => _confirmDelete(webhook),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  IconData _getWebhookIcon(WebhookType type) {
    switch (type) {
      case WebhookType.http:
        return Icons.http;
      case WebhookType.slack:
        return Icons.chat;
      case WebhookType.discord:
        return Icons.discord;
      case WebhookType.telegram:
        return Icons.telegram;
    }
  }

  void _confirmDelete(WebhookConfig webhook) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Webhook'),
        content: Text('Delete "${webhook.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteWebhook(webhook.id);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}

class WebhookEditorScreen extends StatefulWidget {
  final WebhookConfig? webhook;

  const WebhookEditorScreen({Key? key, this.webhook}) : super(key: key);

  @override
  State<WebhookEditorScreen> createState() => _WebhookEditorScreenState();
}

class _WebhookEditorScreenState extends State<WebhookEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _urlController;
  late TextEditingController _bodyTemplateController;
  late TextEditingController _webhookUrlController;
  late TextEditingController _botTokenController;
  late TextEditingController _chatIdController;
  
  late WebhookType _selectedType;
  late HttpMethod _selectedMethod;
  late Set<WebhookTrigger> _selectedTriggers;
  int _maxRetries = 3;
  Map<String, String> _headers = {};
  bool _saving = false;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final webhook = widget.webhook;
    _nameController = TextEditingController(text: webhook?.name ?? '');
    _urlController = TextEditingController(text: webhook?.url ?? '');
    _bodyTemplateController = TextEditingController(text: webhook?.bodyTemplate ?? '');
    _webhookUrlController = TextEditingController(text: webhook?.webhookUrl ?? '');
    _botTokenController = TextEditingController(text: webhook?.botToken ?? '');
    _chatIdController = TextEditingController(text: webhook?.channelId ?? '');
    _selectedType = webhook?.type ?? WebhookType.http;
    _selectedMethod = webhook?.method ?? HttpMethod.post;
    _selectedTriggers = webhook?.triggers.toSet() ?? {};
    _maxRetries = webhook?.maxRetries ?? 3;
    _headers = Map.from(webhook?.headers ?? {});
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _bodyTemplateController.dispose();
    _webhookUrlController.dispose();
    _botTokenController.dispose();
    _chatIdController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedTriggers.isEmpty) {
      _showError('Select at least one trigger');
      return;
    }

    setState(() => _saving = true);

    final webhook = WebhookConfig(
      id: widget.webhook?.id ?? const Uuid().v4(),
      name: _nameController.text.trim(),
      enabled: widget.webhook?.enabled ?? true,
      type: _selectedType,
      triggers: _selectedTriggers,
      maxRetries: _maxRetries,
      url: _urlController.text.trim(),
      method: _selectedMethod,
      headers: _headers.isNotEmpty ? _headers : null,
      bodyTemplate: _bodyTemplateController.text.trim().isEmpty ? null : _bodyTemplateController.text.trim(),
      webhookUrl: _webhookUrlController.text.trim().isEmpty ? null : _webhookUrlController.text.trim(),
      botToken: _botTokenController.text.trim().isEmpty ? null : _botTokenController.text.trim(),
      channelId: _chatIdController.text.trim().isEmpty ? null : _chatIdController.text.trim(),
    );

    if (widget.webhook != null) {
      await WebhookService.instance.updateWebhook(webhook);
    } else {
      await WebhookService.instance.addWebhook(webhook);
    }

    setState(() => _saving = false);
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _testWebhook() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _testing = true);

    final webhook = WebhookConfig(
      id: 'test',
      name: _nameController.text.trim(),
      type: _selectedType,
      maxRetries: 0,
      url: _urlController.text.trim(),
      method: _selectedMethod,
      headers: _headers.isNotEmpty ? _headers : null,
      bodyTemplate: _bodyTemplateController.text.trim().isEmpty ? null : _bodyTemplateController.text.trim(),
      webhookUrl: _webhookUrlController.text.trim().isEmpty ? null : _webhookUrlController.text.trim(),
      botToken: _botTokenController.text.trim().isEmpty ? null : _botTokenController.text.trim(),
      channelId: _chatIdController.text.trim().isEmpty ? null : _chatIdController.text.trim(),
    );

    final success = await WebhookService.instance.testWebhook(webhook);
    setState(() => _testing = false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? 'Test successful' : 'Test failed'),
          backgroundColor: success ? Colors.green : Colors.redAccent,
        ),
      );
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(widget.webhook == null ? 'New Webhook' : 'Edit Webhook'),
        actions: [
          TextButton.icon(
            icon: _testing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.science),
            label: const Text('Test'),
            onPressed: _testing ? null : _testWebhook,
          ),
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
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
              ),
              validator: (v) => v?.trim().isEmpty == true ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<WebhookType>(
              value: _selectedType,
              decoration: const InputDecoration(
                labelText: 'Type',
                border: OutlineInputBorder(),
              ),
              items: WebhookType.values.map((type) {
                return DropdownMenuItem(
                  value: type,
                  child: Text(type.name.toUpperCase()),
                );
              }).toList(),
              onChanged: (v) => setState(() => _selectedType = v!),
            ),
            const SizedBox(height: 16),
            if (_selectedType == WebhookType.discord || _selectedType == WebhookType.slack) ...[
              TextFormField(
                controller: _webhookUrlController,
                decoration: const InputDecoration(
                  labelText: 'Webhook URL',
                  border: OutlineInputBorder(),
                  hintText: 'https://discord.com/api/webhooks/... or https://hooks.slack.com/...',
                ),
                validator: (v) {
                  if (v?.trim().isEmpty == true) return 'Required';
                  if (!v!.startsWith('http')) return 'Must start with http:// or https://';
                  return null;
                },
              ),
              const SizedBox(height: 16),
            ],
            if (_selectedType == WebhookType.telegram) ...[
              TextFormField(
                controller: _botTokenController,
                decoration: const InputDecoration(
                  labelText: 'Bot Token',
                  border: OutlineInputBorder(),
                  hintText: '123456:ABC-DEF1234ghikl-zyx57W2v1u123ew11',
                ),
                validator: (v) => v?.trim().isEmpty == true ? 'Required' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _chatIdController,
                decoration: const InputDecoration(
                  labelText: 'Chat ID',
                  border: OutlineInputBorder(),
                  hintText: '@channelname or -1001234567890',
                ),
                validator: (v) => v?.trim().isEmpty == true ? 'Required' : null,
              ),
              const SizedBox(height: 16),
            ],
            if (_selectedType == WebhookType.http) ...[
              TextFormField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'URL',
                  border: OutlineInputBorder(),
                  hintText: 'https://example.com/webhook',
                ),
                validator: (v) {
                  if (v?.trim().isEmpty == true) return 'Required';
                  if (!v!.startsWith('http')) return 'Must start with http:// or https://';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<HttpMethod>(
                value: _selectedMethod,
                decoration: const InputDecoration(
                  labelText: 'HTTP Method',
                  border: OutlineInputBorder(),
                ),
                items: HttpMethod.values.map((method) {
                  return DropdownMenuItem(
                    value: method,
                    child: Text(method.name.toUpperCase()),
                  );
                }).toList(),
                onChanged: (v) => setState(() => _selectedMethod = v!),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _bodyTemplateController,
                decoration: const InputDecoration(
                  labelText: 'Body Template (optional)',
                  border: OutlineInputBorder(),
                  hintText: 'Leave empty for default JSON. Use {{event}}, {{tunnelId}}, etc.',
                ),
                maxLines: 4,
              ),
              const SizedBox(height: 8),
              const Text(
                'Available placeholders: {{event}}, {{tunnelId}}, {{hostname}}, {{port}}, {{reason}}, {{error}}, {{timestamp}}',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                const Text('Max Retries: ', style: TextStyle(color: Colors.white70)),
                const SizedBox(width: 8),
                Expanded(
                  child: Slider(
                    value: _maxRetries.toDouble(),
                    min: 0,
                    max: 10,
                    divisions: 10,
                    label: '$_maxRetries',
                    onChanged: (v) => setState(() => _maxRetries = v.round()),
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text(
                    '$_maxRetries',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Text('Triggers', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            CheckboxListTile(
              title: const Text('All events', style: TextStyle(fontWeight: FontWeight.bold)),
              value: _selectedTriggers.length == WebhookTrigger.values.length,
              onChanged: (checked) {
                setState(() {
                  if (checked == true) {
                    _selectedTriggers = WebhookTrigger.values.toSet();
                  } else {
                    _selectedTriggers.clear();
                  }
                });
              },
            ),
            const Divider(),
            ...WebhookTrigger.values.map((trigger) {
              return CheckboxListTile(
                title: Text(_formatTriggerName(trigger)),
                value: _selectedTriggers.contains(trigger),
                onChanged: (checked) {
                  setState(() {
                    if (checked == true) {
                      _selectedTriggers.add(trigger);
                    } else {
                      _selectedTriggers.remove(trigger);
                    }
                  });
                },
              );
            }).toList(),
          ],
        ),
      ),
    );
  }

  String _formatTriggerName(WebhookTrigger trigger) {
    switch (trigger) {
      case WebhookTrigger.tunnelStarted:
        return 'Tunnel Started';
      case WebhookTrigger.tunnelStopped:
        return 'Tunnel Stopped';
      case WebhookTrigger.tunnelCrashed:
        return 'Tunnel Crashed';
      case WebhookTrigger.tunnelReconnected:
        return 'Tunnel Reconnected';
      case WebhookTrigger.tunnelCreated:
        return 'Tunnel Created';
      case WebhookTrigger.tunnelDeleted:
        return 'Tunnel Deleted';
      case WebhookTrigger.daemonStarted:
        return 'Daemon Started';
      case WebhookTrigger.daemonStopping:
        return 'Daemon Stopping';
      case WebhookTrigger.rateAlert:
        return 'Rate Alert';
    }
  }
}
