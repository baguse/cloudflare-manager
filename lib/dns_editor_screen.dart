import 'package:flutter/material.dart';
import 'cloudflare_service.dart';

Color _cardBg(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF1E293B) : Colors.white;

Color _panelBg(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF0F172A) : const Color(0xFFF5F5F5);

Color _borderClr(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF334155) : const Color(0xFFE0E0E0);

Color _textPrimary(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? Colors.white : Colors.black87;

Color _textSecondary(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? Colors.white70 : Colors.black54;

class DnsEditorScreen extends StatefulWidget {
  const DnsEditorScreen({super.key});

  @override
  State<DnsEditorScreen> createState() => _DnsEditorScreenState();
}

class _DnsEditorScreenState extends State<DnsEditorScreen> {
  List<Map<String, dynamic>> _zones = [];
  Map<String, dynamic>? _selectedZone;
  List<Map<String, dynamic>> _records = [];
  bool _isLoadingZones = true;
  bool _isLoadingRecords = false;
  String _searchQuery = '';
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchZones();
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text.toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchZones() async {
    setState(() => _isLoadingZones = true);
    final zones = await CloudflareService.getZones();
    if (mounted) {
      setState(() {
        _zones = zones;
        _isLoadingZones = false;
        if (_selectedZone == null && zones.isNotEmpty) {
          _selectedZone = zones.first;
          _fetchRecords();
        }
      });
    }
  }

  Future<void> _fetchRecords() async {
    final zone = _selectedZone;
    if (zone == null) return;
    setState(() => _isLoadingRecords = true);
    final records = await CloudflareService.listDnsRecords(zone['id']);
    if (mounted) {
      setState(() {
        _records = records;
        _isLoadingRecords = false;
      });
    }
  }

  Future<void> _editRecord({Map<String, dynamic>? existing}) async {
    final zone = _selectedZone;
    if (zone == null) return;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => DnsRecordDialog(existing: existing, zoneName: zone['name']),
    );
    if (result == null) return;
    final type = result['type'] as String;
    final name = result['name'] as String;
    final content = result['content'] as String;
    final ttl = result['ttl'] as int;
    final proxied = result['proxied'] as bool?;
    final priority = result['priority'] as int?;
    final ok = existing == null
        ? await CloudflareService.createDnsRecord(
            zone['id'], type: type, name: name, content: content,
            ttl: ttl, proxied: proxied, priority: priority,
          )
        : await CloudflareService.updateDnsRecord(
            zone['id'], existing['id'], type: type, name: name,
            content: content, ttl: ttl, proxied: proxied, priority: priority,
          );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? 'DNS record saved' : 'Failed to save DNS record'),
          backgroundColor: ok ? Colors.green : Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
      if (ok) _fetchRecords();
    }
  }

  Future<void> _deleteRecord(Map<String, dynamic> record) async {
    final zone = _selectedZone;
    if (zone == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _cardBg(context),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
            SizedBox(width: 8),
            Text('Delete DNS record?'),
          ],
        ),
        content: Text('Delete ${record['type']} ${record['name']} → ${record['content']}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final ok = await CloudflareService.deleteDnsRecord(zone['id'], record['id']);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? 'DNS record deleted' : 'Failed to delete'),
          backgroundColor: ok ? Colors.green : Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
      if (ok) _fetchRecords();
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _records.where((r) {
      if (_searchQuery.isEmpty) return true;
      final name = (r['name'] ?? '').toString().toLowerCase();
      final content = (r['content'] ?? '').toString().toLowerCase();
      final type = (r['type'] ?? '').toString().toLowerCase();
      return name.contains(_searchQuery) || content.contains(_searchQuery) || type.contains(_searchQuery);
    }).toList();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: _cardBg(context),
        title: const Text('DNS Editor'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () { _fetchZones(); _fetchRecords(); },
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Row(
        children: [
          SizedBox(
            width: 240,
            child: Material(
              color: _cardBg(context),
              child: _isLoadingZones
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      children: [
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Icon(Icons.dns, color: Color(0xFFF6821F), size: 18),
                              SizedBox(width: 8),
                              Text('Zones', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                            ],
                          ),
                        ),
                        Divider(height: 1, color: _borderClr(context)),
                        Expanded(
                          child: _zones.isEmpty
                              ? const Center(child: Text('No zones found', style: TextStyle(color: Colors.grey, fontSize: 12)))
                              : ListView(
                                  children: _zones.map((z) {
                                    final selected = _selectedZone?['id'] == z['id'];
                                    return ListTile(
                                      dense: true,
                                      selected: selected,
                                      tileColor: _cardBg(context),
                                      selectedTileColor: _panelBg(context),
                                      leading: Icon(Icons.public, size: 16, color: _textSecondary(context)),
                                      title: Text(z['name'], style: TextStyle(fontSize: 13, color: _textPrimary(context))),
                                      subtitle: Text(
                                        z['status'] ?? '',
                                        style: const TextStyle(fontSize: 10, color: Colors.grey),
                                      ),
                                      onTap: () { setState(() => _selectedZone = z); _fetchRecords(); },
                                    );
                                  }).toList(),
                                ),
                        ),
                      ],
                    ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _selectedZone?['name'] ?? 'Select a zone',
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: _textPrimary(context)),
                        ),
                      ),
                      SizedBox(
                        width: 280, height: 36,
                        child: TextField(
                          controller: _searchController,
                          decoration: InputDecoration(
                            hintText: 'Search records...',
                            hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
                            prefixIcon: const Icon(Icons.search, size: 18, color: Colors.grey),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                            filled: true,
                            fillColor: _panelBg(context),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                          ),
                          style: TextStyle(fontSize: 13, color: _textPrimary(context)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton.icon(
                        onPressed: _selectedZone == null ? null : () => _editRecord(),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('New Record'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFF6821F),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_isLoadingRecords)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: LinearProgressIndicator(
                      minHeight: 2,
                      backgroundColor: _panelBg(context),
                      color: const Color(0xFFF6821F),
                    ),
                  ),
                Divider(height: 1, color: _borderClr(context)),
                Expanded(
                  child: _isLoadingRecords && _records.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : filtered.isEmpty
                          ? Center(child: Text(_records.isEmpty ? 'No DNS records in this zone.' : 'No matches found.', style: const TextStyle(color: Colors.grey)))
                          : ListView.separated(
                              itemCount: filtered.length,
                              separatorBuilder: (_, __) => Divider(color: _borderClr(context), height: 1),
                              itemBuilder: (context, i) => _buildRecordRow(filtered[i]),
                            ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordRow(Map<String, dynamic> record) {
    final type = record['type'] ?? '';
    final name = record['name'] ?? '';
    final content = record['content'] ?? '';
    final ttl = record['ttl'];
    final proxied = record['proxied'] == true;
    final autoTtl = ttl == 1;
    final typeColor = _typeColor(type);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 60,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: typeColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: typeColor.withOpacity(0.4)),
            ),
            child: Text(type, textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: typeColor, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Text(name, style: TextStyle(fontSize: 13, color: _textPrimary(context), fontFamily: 'monospace'), overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 4,
            child: Text(content, style: TextStyle(fontSize: 12, color: _textSecondary(context), fontFamily: 'monospace'), overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 12),
          SizedBox(width: 90, child: Text(autoTtl ? 'auto' : '${ttl}s', style: const TextStyle(fontSize: 11, color: Colors.grey, fontFamily: 'monospace'))),
          SizedBox(
            width: 80,
            child: (type == 'A' || type == 'AAAA' || type == 'CNAME')
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: proxied ? Colors.orange.withOpacity(0.15) : Colors.transparent,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: proxied ? Colors.orange.withOpacity(0.4) : _borderClr(context)),
                    ),
                    child: Text(proxied ? 'PROXIED' : 'DNS only', textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 9, color: proxied ? Colors.orangeAccent : Colors.grey, fontWeight: FontWeight.bold)),
                  )
                : const SizedBox.shrink(),
          ),
          IconButton(icon: const Icon(Icons.edit, size: 16, color: Colors.grey), tooltip: 'Edit', onPressed: () => _editRecord(existing: record)),
          IconButton(icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent), tooltip: 'Delete', onPressed: () => _deleteRecord(record)),
        ].map((e) => e is IconButton ? e : e).toList(),
      ),
    );
  }

  Color _typeColor(String type) {
    switch (type) {
      case 'A': return Colors.greenAccent;
      case 'AAAA': return Colors.lightGreenAccent;
      case 'CNAME': return Colors.lightBlueAccent;
      case 'TXT': return Colors.yellowAccent;
      case 'MX': return Colors.purpleAccent;
      case 'NS': return Colors.cyanAccent;
      case 'SRV': return Colors.pinkAccent;
      default: return _textSecondary(context);
    }
  }
}

class DnsRecordDialog extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final String zoneName;
  const DnsRecordDialog({super.key, this.existing, required this.zoneName});

  @override
  State<DnsRecordDialog> createState() => _DnsRecordDialogState();
}

class _DnsRecordDialogState extends State<DnsRecordDialog> {
  late String _type;
  late TextEditingController _nameController, _contentController, _ttlController, _priorityController;
  late bool _proxied, _autoTtl;
  static const _types = ['A', 'AAAA', 'CNAME', 'TXT', 'MX', 'NS', 'SRV'];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _type = e?['type'] ?? 'A';
    _nameController = TextEditingController(text: e?['name'] ?? '');
    _contentController = TextEditingController(text: e?['content'] ?? '');
    _priorityController = TextEditingController(text: '${e?['priority'] ?? 10}');
    final ttl = e?['ttl'];
    _autoTtl = ttl == null || ttl == 1;
    _ttlController = TextEditingController(text: _autoTtl ? '1' : '$ttl');
    _proxied = e?['proxied'] == true;
  }

  @override
  void dispose() {
    _nameController.dispose(); _contentController.dispose();
    _ttlController.dispose(); _priorityController.dispose();
    super.dispose();
  }

  bool get _canProxy => _type == 'A' || _type == 'AAAA' || _type == 'CNAME';
  bool get _isMx => _type == 'MX';

  String? _contentHint() {
    switch (_type) {
      case 'A': return '192.0.2.1';
      case 'AAAA': return '2001:db8::1';
      case 'CNAME': return 'target.example.com';
      case 'TXT': return 'v=spf1 -all';
      case 'MX': return 'mail.example.com';
      case 'NS': return 'ns1.example.com';
      case 'SRV': return '0 5 5060 sip.example.com';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _cardBg(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          const Icon(Icons.dns, color: Color(0xFFF6821F)),
          const SizedBox(width: 8),
          Text(widget.existing == null ? 'New DNS record' : 'Edit DNS record'),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Zone: ${widget.zoneName}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _type,
              decoration: InputDecoration(
                labelText: 'Type', filled: true, fillColor: _panelBg(context),
                border: const OutlineInputBorder(borderSide: BorderSide.none),
              ),
              dropdownColor: _cardBg(context),
              items: _types.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
              onChanged: (v) { if (v != null) setState(() => _type = v); },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: 'Name (subdomain or @ for root)', hintText: 'subdomain (or @ for root)',
                filled: true, fillColor: _panelBg(context),
                border: const OutlineInputBorder(borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _contentController,
              decoration: InputDecoration(
                labelText: 'Content', hintText: _contentHint(),
                filled: true, fillColor: _panelBg(context),
                border: const OutlineInputBorder(borderSide: BorderSide.none),
              ),
              maxLines: 2, minLines: 1,
            ),
            if (_isMx) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _priorityController, keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Priority', filled: true,
                  fillColor: _panelBg(context),
                  border: OutlineInputBorder(borderSide: BorderSide.none),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ttlController, keyboardType: TextInputType.number, enabled: !_autoTtl,
                    decoration: InputDecoration(
                      labelText: 'TTL (seconds)', filled: true, fillColor: _panelBg(context),
                      border: const OutlineInputBorder(borderSide: BorderSide.none),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  children: [
                    Checkbox(value: _autoTtl, onChanged: (v) => setState(() { _autoTtl = v ?? true; if (_autoTtl) _ttlController.text = '1'; })),
                    Text('Auto', style: TextStyle(color: _textSecondary(context), fontSize: 12)),
                  ],
                ),
              ],
            ),
            if (_canProxy) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: _panelBg(context), borderRadius: BorderRadius.circular(8)),
                child: Row(
                  children: [
                    Switch(value: _proxied, onChanged: (v) => setState(() => _proxied = v), activeColor: const Color(0xFFF6821F)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Proxy through Cloudflare (orange cloud)',
                        style: TextStyle(color: _textSecondary(context), fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
        ElevatedButton(
          onPressed: _save,
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF6821F), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
          child: const Text('Save'),
        ),
      ],
    );
  }

  void _save() {
    final name = _nameController.text.trim();
    final content = _contentController.text.trim();
    if (name.isEmpty || content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Name and content are required'), backgroundColor: Colors.redAccent, behavior: SnackBarBehavior.floating));
      return;
    }
    Navigator.pop(context, {
      'type': _type, 'name': name, 'content': content,
      'ttl': int.tryParse(_ttlController.text.trim()) ?? 1,
      if (_canProxy) 'proxied': _proxied,
      if (_isMx) 'priority': int.tryParse(_priorityController.text.trim()) ?? 10,
    });
  }
}
