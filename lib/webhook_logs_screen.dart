import 'package:flutter/material.dart';
import 'webhook_config.dart';
import 'webhook_service.dart';

class WebhookLogsScreen extends StatefulWidget {
  final String? webhookId;
  final String? webhookName;

  const WebhookLogsScreen({Key? key, this.webhookId, this.webhookName}) : super(key: key);

  @override
  State<WebhookLogsScreen> createState() => _WebhookLogsScreenState();
}

class _WebhookLogsScreenState extends State<WebhookLogsScreen> {
  List<WebhookLog> _logs = [];
  bool _loading = true;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    setState(() => _loading = true);
    await WebhookService.instance.loadLogs();
    var logs = WebhookService.instance.logs.reversed.toList();
    if (widget.webhookId != null) {
      logs = logs.where((l) => l.webhookId == widget.webhookId).toList();
    }
    setState(() {
      _logs = logs;
      _loading = false;
    });
  }

  List<WebhookLog> get _filteredLogs {
    if (_filter == 'all') return _logs;
    return _logs.where((l) {
      if (_filter == 'success') return l.status == WebhookLogStatus.success;
      if (_filter == 'failed') return l.status == WebhookLogStatus.failed;
      return true;
    }).toList();
  }

  Future<void> _deleteLog(WebhookLog log) async {
    await WebhookService.instance.deleteLog(log.id);
    await _loadLogs();
  }

  Future<void> _clearAllLogs() async {
    final target = widget.webhookId != null ? 'logs for "${widget.webhookName}"' : 'all webhook logs';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Logs'),
        content: Text('Delete $target? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      if (widget.webhookId != null) {
        await WebhookService.instance.deleteLogsForWebhook(widget.webhookId!);
      } else {
        await WebhookService.instance.clearLogs();
      }
      await _loadLogs();
    }
  }

  void _showLogDetails(WebhookLog log) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF2d2d2d),
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        minChildSize: 0.3,
        expand: false,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    log.status == WebhookLogStatus.success ? Icons.check_circle : Icons.error,
                    color: log.status == WebhookLogStatus.success ? Colors.green : Colors.redAccent,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    log.webhookName,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const Divider(),
              const SizedBox(height: 8),
              _buildDetailRow('Status', _formatStatus(log)),
              _buildDetailRow('Trigger', log.trigger.name),
              if (log.statusCode != null)
                _buildDetailRow('HTTP Status', log.statusCode.toString()),
              _buildDetailRow('Duration', '${log.durationMs}ms'),
              _buildDetailRow('Timestamp', _formatTimestamp(log.timestamp)),
              if (log.error != null) ...[
                const SizedBox(height: 16),
                const Text('Error:', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SelectableText(
                    log.error!,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ],
              if (log.response != null) ...[
                const SizedBox(height: 16),
                const Text('Response:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SelectableText(
                    log.response!,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.delete, color: Colors.redAccent),
                  label: const Text('Delete Log', style: TextStyle(color: Colors.redAccent)),
                  onPressed: () {
                    Navigator.pop(context);
                    _deleteLog(log);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text('$label:', style: const TextStyle(color: Colors.grey, fontSize: 13)),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  String _formatStatus(WebhookLog log) {
    switch (log.status) {
      case WebhookLogStatus.success:
        return 'Success';
      case WebhookLogStatus.failed:
        return 'Failed';
      case WebhookLogStatus.pending:
        return 'Pending';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a1a),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2d2d2d),
        title: Text(widget.webhookName != null ? 'Logs: ${widget.webhookName}' : 'Webhook Logs'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'clear') _clearAllLogs();
              if (value == 'refresh') _loadLogs();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'refresh',
                child: Row(
                  children: [
                    Icon(Icons.refresh, size: 18),
                    SizedBox(width: 8),
                    Text('Refresh'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'clear',
                child: Row(
                  children: [
                    Icon(Icons.delete_sweep, size: 18, color: Colors.redAccent),
                    SizedBox(width: 8),
                    Text('Clear All', style: TextStyle(color: Colors.redAccent)),
                  ],
                ),
              ),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(50),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                _buildFilterChip('all', 'All'),
                const SizedBox(width: 8),
                _buildFilterChip('success', 'Success'),
                const SizedBox(width: 8),
                _buildFilterChip('failed', 'Failed'),
                const Spacer(),
                Text(
                  '${_filteredLogs.length} log(s)',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _filteredLogs.isEmpty
              ? _buildEmptyState()
              : _buildLogsList(),
    );
  }

  Widget _buildFilterChip(String value, String label) {
    final selected = _filter == value;
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _filter = value),
      backgroundColor: const Color(0xFF2d2d2d),
      selectedColor: const Color(0xFFF6821F),
      labelStyle: TextStyle(
        color: selected ? Colors.white : Colors.grey,
        fontSize: 12,
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.history, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          Text(
            _filter == 'all' ? 'No logs yet' : 'No ${_filter} logs',
            style: const TextStyle(fontSize: 18, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildLogsList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _filteredLogs.length,
      itemBuilder: (context, index) {
        final log = _filteredLogs[index];
        return Card(
          color: const Color(0xFF2d2d2d),
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: Icon(
              log.status == WebhookLogStatus.success ? Icons.check_circle : Icons.error,
              color: log.status == WebhookLogStatus.success ? Colors.green : Colors.redAccent,
            ),
            title: Text(log.webhookName),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_formatTriggerName(log.trigger)}${log.statusCode != null ? ' • HTTP ${log.statusCode}' : ''} • ${log.durationMs}ms',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                Text(
                  _formatShortTimestamp(log.timestamp),
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
                if (log.error != null)
                  Text(
                    log.error!,
                    style: const TextStyle(fontSize: 10, color: Colors.redAccent),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete, size: 18, color: Colors.redAccent),
              onPressed: () => _confirmDelete(log),
            ),
            onTap: () => _showLogDetails(log),
          ),
        );
      },
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

  String _formatTimestamp(DateTime dt) {
    final p = (int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${p(dt.month)}-${p(dt.day)} ${p(dt.hour)}:${p(dt.minute)}:${p(dt.second)}';
  }

  String _formatShortTimestamp(DateTime dt) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final p = (int v) => v.toString().padLeft(2, '0');
    return '${months[dt.month - 1]} ${dt.day}, ${p(dt.hour)}:${p(dt.minute)}:${p(dt.second)}';
  }

  void _confirmDelete(WebhookLog log) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Log'),
        content: const Text('Delete this log entry?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteLog(log);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}
