import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'port_scanner.dart';
import 'settings_screen.dart';
import 'cloudflared_service.dart';
import 'cloudflare_service.dart';
import 'tunnel_health.dart';

void main() {
  runApp(const CloudflareManagerApp());
}

class CloudflareManagerApp extends StatelessWidget {
  const CloudflareManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cloudflare Tunnel Manager',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFF6821F), // Cloudflare Orange
          surface: Color(0xFF1E293B),
          background: Color(0xFF0F172A),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        useMaterial3: true,
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<OpenPort> _openPorts = [];
  List<ActiveTunnel> _activeTunnels = [];
  List<Map<String, dynamic>> _remoteTunnels = [];
  Map<String, Map<String, String>> _tunnelConfigs = {}; // tunnelId -> {hostname, service}
  Map<String, OpenPort> _tunnelLocalProcess = {};
  Map<int, OpenPort> _pidToLocalProcess = {};
  Map<int, int> _pidToTunnelPort = {};
  Map<int, String> _pidToTunnelLabel = {};
  List<TunnelInfo> _runningTunnels = [];
  Map<String, TunnelHealth> _tunnelHealth = {};
  bool _isCheckingHealth = false;
  bool _isLoadingPorts = true;
  bool _isLoadingRemoteTunnels = false;
  bool _isCloudflaredInstalled = false;
  Timer? _refreshTimer;
  Timer? _healthTimer;

  final _portsSearchController = TextEditingController();
  final _tunnelsSearchController = TextEditingController();
  String _portsSearchQuery = '';
  String _tunnelsSearchQuery = '';

  @override
  void initState() {
    super.initState();
    _checkCloudflared();
    _fetchPorts();
    _fetchRemoteTunnels();
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _fetchPorts();
      _fetchRemoteTunnels();
    });
    _healthTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      _checkTunnelHealth();
    });

    _portsSearchController.addListener(() {
      setState(() => _portsSearchQuery = _portsSearchController.text.toLowerCase());
    });
    _tunnelsSearchController.addListener(() {
      setState(() => _tunnelsSearchQuery = _tunnelsSearchController.text.toLowerCase());
    });
  }

  Future<void> _checkCloudflared() async {
    final isInstalled = await CloudflaredService.isInstalled();
    if (mounted) setState(() => _isCloudflaredInstalled = isInstalled);
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _healthTimer?.cancel();
    _portsSearchController.dispose();
    _tunnelsSearchController.dispose();
    super.dispose();
  }

  Future<void> _fetchPorts() async {
    final ports = await PortScanner.getOpenPorts();
    if (mounted) {
      setState(() {
        _openPorts = ports;
        _isLoadingPorts = false;
      });
    }
  }

  Future<void> _fetchRemoteTunnels() async {
    setState(() => _isLoadingRemoteTunnels = true);

    final ports = await PortScanner.getOpenPorts();
    final portByNumber = {for (final p in ports) p.port: p};

    final runningTunnels = await CloudflaredService.getRunningTunnels();
    final resolvedPorts = await CloudflaredService.resolveLocalPorts(runningTunnels);

    final Map<String, OpenPort> tunnelLocalProcess = {};
    final Map<int, OpenPort> pidToLocalProcess = {};
    final Map<int, int> pidToTunnelPort = {};
    for (final t in runningTunnels) {
      final port = resolvedPorts[t.pid];
      if (port == null) continue;
      pidToTunnelPort[t.pid] = port;
      final open = portByNumber[port];
      if (open != null) {
        if (t.tunnelId != null) {
          tunnelLocalProcess[t.tunnelId!] = open;
        } else {
          pidToLocalProcess[t.pid] = open;
        }
      }
    }

    final tunnels = await CloudflareService.listTunnels();

    final Map<String, Map<String, String>> configs = {};
    for (var t in tunnels) {
      final id = t['id'] as String;
      final config = await CloudflareService.getTunnelConfig(id);
      if (config != null) {
        try {
          final ingress = config['config']?['ingress'] as List?;
          if (ingress != null && ingress.isNotEmpty) {
            final first = ingress.first as Map<String, dynamic>;
            configs[id] = {
              'hostname': first['hostname'] ?? '',
              'service': first['service'] ?? '',
            };
          }
        } catch (e) {
          // skip
        }
      }
    }

    final pidToLabel = <int, String>{};
    for (final t in runningTunnels) {
      if (t.tunnelId != null) {
        final cfg = configs[t.tunnelId!];
        final host = cfg?['hostname'];
        if (host != null && host.isNotEmpty) {
          pidToLabel[t.pid] = host;
        }
      }
    }

    if (mounted) {
      setState(() {
        _openPorts = ports;
        _isLoadingPorts = false;
        _remoteTunnels = tunnels;
        _tunnelConfigs = configs;
        _tunnelLocalProcess = tunnelLocalProcess;
        _pidToLocalProcess = pidToLocalProcess;
        _pidToTunnelPort = pidToTunnelPort;
        _pidToTunnelLabel = pidToLabel;
        _runningTunnels = runningTunnels;
        _isLoadingRemoteTunnels = false;
      });
    }
    _checkTunnelHealth();
  }

  List<String> _collectHealthCheckUrls() {
    final urls = <String>{};
    for (final a in _activeTunnels) {
      if (a.url.isNotEmpty) urls.add(a.url);
    }
    for (var t in _remoteTunnels) {
      final id = t['id'] as String?;
      if (id == null) continue;
      final cfg = _tunnelConfigs[id];
      final host = cfg?['hostname'];
      if (host != null && host.isNotEmpty) urls.add('https://$host');
    }
    return urls.toList();
  }

  Future<void> _checkTunnelHealth() async {
    if (_isCheckingHealth) return;
    final urls = _collectHealthCheckUrls();
    if (urls.isEmpty) return;
    setState(() => _isCheckingHealth = true);
    final results = await TunnelHealthChecker.checkAll(urls);
    if (mounted) {
      setState(() {
        _tunnelHealth = results;
        _isCheckingHealth = false;
      });
    }
  }

  Future<void> _startTunnel(int port) async {
    if (!_isCloudflaredInstalled) {
      _showToast('cloudflared is not installed!', isError: true);
      return;
    }

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => BindDomainDialog(localPort: port),
    );

    if (result == null) return;

    final String subdomain = result['subdomain'];
    final Map<String, dynamic> zone = result['zone'];
    final String fullDomain = '$subdomain.${zone['name']}';

    try {
      _showToast('Creating tunnel...', isInfo: true);
      final tunnelData = await CloudflareService.createTunnel('tunnel-$subdomain-$port');
      if (tunnelData == null) throw Exception('Failed to create tunnel');

      final tunnelId = tunnelData['id'];
      final tunnelToken = tunnelData['token'];

      _showToast('Configuring routing...', isInfo: true);
      final configured = await CloudflareService.configureTunnel(tunnelId, fullDomain, port);
      if (!configured) throw Exception('Failed to configure tunnel routing');

      _showToast('Creating DNS record...', isInfo: true);
      final dnsCreated = await CloudflareService.createTunnelDnsRecord(zone['id'], subdomain, tunnelId);
      if (!dnsCreated) throw Exception('Failed to create DNS record');

      _showToast('Starting cloudflared...', isInfo: true);
      final process = await CloudflaredService.startTokenTunnel(tunnelToken);

      await CloudflaredService.registerAppTunnel(tunnelId, port);

      final activeTunnel = ActiveTunnel(
        tunnelId: tunnelId,
        name: 'tunnel-$subdomain-$port',
        localPort: port,
        url: 'https://$fullDomain',
        process: process,
        logs: ValueNotifier<List<String>>([]),
      );

      setState(() {
        _activeTunnels.add(activeTunnel);
      });

      process.stdout.transform(utf8.decoder).listen((data) {
        activeTunnel.logs.value = [...activeTunnel.logs.value, data];
      });

      process.stderr.transform(utf8.decoder).listen((data) {
        activeTunnel.logs.value = [...activeTunnel.logs.value, data];
      });
      
      _showToast('Tunnel $fullDomain is active!');
      _fetchRemoteTunnels();
      _checkTunnelHealth();
    } catch (e) {
      _showToast('Error: $e', isError: true);
    }
  }

  void _stopTunnel(ActiveTunnel tunnel) {
    tunnel.process.kill();
    if (tunnel.tunnelId != null) {
      CloudflaredService.unregisterAppTunnel(tunnel.tunnelId!);
    }
    setState(() => _activeTunnels.remove(tunnel));
    _showToast('Tunnel stopped', isInfo: true);
  }

  Future<bool> _confirmDelete({String? title, String? message}) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
            const SizedBox(width: 8),
            Text(title ?? 'Delete tunnel?', style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          message ?? 'This will stop the local cloudflared process and remove the tunnel and its DNS record from Cloudflare. This action cannot be undone.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _deleteTunnel({ActiveTunnel? tunnel, String? tunnelId, int? pid}) async {
    final id = tunnel?.tunnelId ?? tunnelId;
    if (id == null) return;
    if (!await _confirmDelete()) return;
    _showToast('Deleting tunnel...', isInfo: true);

    if (tunnel != null) {
      tunnel.process.kill();
      setState(() => _activeTunnels.remove(tunnel));
    } else if (pid != null) {
      try {
        Process.killPid(pid);
      } catch (e) {
      }
    }

    await CloudflaredService.unregisterAppTunnel(id);
    await CloudflareService.deleteTunnelDnsRecords(id);
    final success = await CloudflareService.deleteTunnel(id);
    if (success) {
      _showToast('Tunnel and DNS record deleted.');
    } else {
      _showToast('Local tunnel stopped, but Cloudflare delete failed.', isError: true);
    }
    _fetchRemoteTunnels();
  }

  Future<void> _deleteRemoteTunnel(String tunnelId) async {
    if (!await _confirmDelete(
      title: 'Delete tunnel from Cloudflare?',
      message: 'This will remove the tunnel and its DNS record from Cloudflare. Any running local cloudflared process for this tunnel will be orphaned.',
    )) return;
    _showToast('Deleting remote tunnel...', isInfo: true);
    await CloudflareService.deleteTunnelDnsRecords(tunnelId);
    final success = await CloudflareService.deleteTunnel(tunnelId);
    if (success) {
      _showToast('Tunnel and DNS record deleted.');
    } else {
      _showToast('Failed to delete tunnel.', isError: true);
    }
  }

  Future<void> _killOrphanedDaemons() async {
    try {
      if (Platform.isLinux || Platform.isMacOS) {
        await Process.run('killall', ['cloudflared']);
        _showToast('Orphaned cloudflared processes killed.', isInfo: true);
        _fetchPorts();
      }
    } catch (e) {
      _showToast('Failed to kill processes: $e', isError: true);
    }
  }

  void _showToast(String message, {bool isError = false, bool isInfo = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.redAccent : (isInfo ? Colors.blueGrey : Colors.green),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // Sidebar
          Material(
            color: const Color(0xFF1E293B),
            child: SizedBox(
              width: 250,
              child: Column(
                children: [
                const SizedBox(height: 40),
                const Icon(Icons.cloud_circle, size: 64, color: Color(0xFFF6821F)),
                const SizedBox(height: 16),
                const Text('Zero Trust\nManager', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, height: 1.2)),
                const SizedBox(height: 40),
                ListTile(
                  leading: const Icon(Icons.dashboard, color: Color(0xFFF6821F)),
                  title: const Text('Dashboard', style: TextStyle(fontWeight: FontWeight.bold)),
                  selected: true,
                  selectedTileColor: const Color(0xFF0F172A),
                  onTap: () {},
                ),
                ListTile(
                  leading: const Icon(Icons.settings, color: Colors.grey),
                  title: const Text('Settings', style: TextStyle(color: Colors.grey)),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
                ),
                ListTile(
                  leading: const Icon(Icons.bug_report, color: Colors.redAccent),
                  title: const Text('Kill Daemons', style: TextStyle(color: Colors.redAccent)),
                  onTap: _killOrphanedDaemons,
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      Icon(
                        _isCloudflaredInstalled ? Icons.check_circle : Icons.error,
                        color: _isCloudflaredInstalled ? Colors.green : Colors.redAccent,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(_isCloudflaredInstalled ? 'Daemon Ready' : 'Daemon Missing', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
          
          // Main Content
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Overview', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 24),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Left Panel: Active Ports
                        Expanded(
                          flex: 5,
                          child: Builder(builder: (context) {
                            final filteredPorts = _openPorts.where((p) => 
                              p.port.toString().contains(_portsSearchQuery) || 
                              p.processName.toLowerCase().contains(_portsSearchQuery)
                            ).toList();
                            
                            return _buildCardPanel(
                              title: 'Local Services',
                              icon: Icons.computer,
                              searchController: _portsSearchController,
                              child: Column(
                                children: [
                                  if (_isLoadingPorts)
                                    const LinearProgressIndicator(
                                      minHeight: 2,
                                      backgroundColor: Color(0xFF0F172A),
                                      color: Color(0xFFF6821F),
                                    ),
                                  Expanded(
                                    child: filteredPorts.isEmpty
                                        ? Center(
                                            child: Text(
                                              _openPorts.isEmpty ? 'No listening ports.' : 'No matches found.',
                                              style: const TextStyle(color: Colors.grey),
                                            ),
                                          )
                                        : ListView.separated(
                                          itemCount: filteredPorts.length,
                                          separatorBuilder: (context, index) => const Divider(color: Color(0xFF334155), height: 1),
                                          itemBuilder: (context, index) {
                                            return _buildPortItem(filteredPorts[index]);
                                          },
                                        ),
                                  ),
                                ],
                              ),
                            );
                          }),
                        ),
                        const SizedBox(width: 24),
                        // Right Panel: Active Tunnels
                        Expanded(
                          flex: 7,
                          child: Builder(builder: (context) {
                            final tunnelWidgets = _buildTunnelItems();
                            return _buildCardPanel(
                              title: 'Active Tunnels',
                              icon: Icons.public,
                              searchController: _tunnelsSearchController,
                              action: _isLoadingRemoteTunnels
                                  ? const Padding(
                                      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      child: SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Color(0xFFF6821F),
                                        ),
                                      ),
                                    )
                                  : IconButton(
                                      icon: const Icon(Icons.refresh, size: 20, color: Colors.grey),
                                      onPressed: _fetchRemoteTunnels,
                                      tooltip: 'Refresh Cloudflare API Tunnels',
                                    ),
                              child: Column(
                                children: [
                                  if (_isLoadingRemoteTunnels)
                                    const LinearProgressIndicator(
                                      minHeight: 2,
                                      backgroundColor: Color(0xFF0F172A),
                                      color: Color(0xFFF6821F),
                                    ),
                                  Expanded(
                                    child: tunnelWidgets.isEmpty
                                        ? Center(
                                            child: Text(
                                              _remoteTunnels.isEmpty && _activeTunnels.isEmpty
                                                  ? 'No active tunnels.'
                                                  : 'No matches found.',
                                              style: const TextStyle(color: Colors.grey),
                                            ),
                                          )
                                        : ListView(children: tunnelWidgets),
                                  ),
                                ],
                              ),
                            );
                          }),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCardPanel({required String title, required IconData icon, required Widget child, Widget? action, TextEditingController? searchController}) {
    return Card(
      color: const Color(0xFF1E293B),
      elevation: 8,
      shadowColor: Colors.black45,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(20.0),
            child: Row(
              children: [
                Icon(icon, color: const Color(0xFFF6821F)),
                const SizedBox(width: 12),
                Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(width: 16),
                if (searchController != null)
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: TextField(
                        controller: searchController,
                        decoration: InputDecoration(
                          hintText: 'Search...',
                          hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
                          prefixIcon: const Icon(Icons.search, size: 18, color: Colors.grey),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                          filled: true,
                          fillColor: const Color(0xFF0F172A),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                        ),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  )
                else
                  const Spacer(),
                if (action != null) ...[
                  const SizedBox(width: 12),
                  action,
                ]
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF334155)),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _buildPortItem(OpenPort portInfo) {
    final tunnelLabel = _tunnelLabelForPort(portInfo.port);
    final isTunneled = tunnelLabel != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 12.0),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFF334155), borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.lan, size: 18, color: Colors.white70),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Text('Port ${portInfo.port}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    if (portInfo.pid != null)
                      Text('pid ${portInfo.pid}', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                    if (isTunneled)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 240),
                        child: Tooltip(
                          message: tunnelLabel,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.green.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: Colors.green.withOpacity(0.4)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.link, size: 10, color: Colors.greenAccent),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    'TUNNELED → $tunnelLabel',
                                    style: const TextStyle(fontSize: 9, color: Colors.greenAccent, fontWeight: FontWeight.bold),
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(4)),
                  child: Text(portInfo.processName, style: const TextStyle(fontSize: 10, color: Colors.grey)),
                ),
              ],
            ),
          ),
          ElevatedButton(
            onPressed: isTunneled ? null : () => _startTunnel(portInfo.port),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF6821F),
              foregroundColor: Colors.white,
              disabledBackgroundColor: const Color(0xFF334155),
              disabledForegroundColor: Colors.grey,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(isTunneled ? 'Linked' : 'Bind'),
          ),
        ],
      ),
    );
  }

  String? _tunnelLabelForPort(int port) {
    for (final a in _activeTunnels) {
      if (a.localPort == port) {
        return a.url.isNotEmpty ? a.url : a.name ?? 'tunnel';
      }
    }
    for (final entry in _tunnelLocalProcess.entries) {
      if (entry.value.port == port) {
        final cfg = _tunnelConfigs[entry.key];
        final host = cfg?['hostname'];
        if (host != null && host.isNotEmpty) return host;
        return 'tunnel ${entry.key.substring(0, 8)}';
      }
    }
    for (final entry in _pidToLocalProcess.entries) {
      if (entry.value.port == port) {
        final label = _pidToTunnelLabel[entry.key];
        if (label != null) return label;
        return 'external tunnel';
      }
    }
    return null;
  }

  List<Widget> _buildTunnelItems() {
    final List<Widget> items = [];
    final renderedPids = <int>{};
    final renderedTunnelIds = <String>{};

    for (var t in _remoteTunnels) {
      final String tunnelId = t['id'];
      final String name = t['name'];
      final String status = t['status'] ?? 'unknown';
      final connections = t['connections'] as List? ?? [];
      final bool hasActiveConnections = connections.isNotEmpty;
      final localProcess = _tunnelLocalProcess[tunnelId];

      final local = _activeTunnels.cast<ActiveTunnel?>().firstWhere((a) => a?.tunnelId == tunnelId, orElse: () => null);
      final url = local?.url ?? '';
      final config = _tunnelConfigs[tunnelId];
      final hostname = config?['hostname'] ?? '';
      final service = config?['service'] ?? '';
      final localLabel = local != null
          ? _composeSubtitle(service: '', status: '', localTunnel: local)
          : (localProcess != null ? _composeSubtitle(service: '', status: '', external: localProcess) : '');

      if (_tunnelsSearchQuery.isNotEmpty) {
        if (!name.toLowerCase().contains(_tunnelsSearchQuery)
            && !url.toLowerCase().contains(_tunnelsSearchQuery)
            && !hostname.toLowerCase().contains(_tunnelsSearchQuery)
            && !localLabel.toLowerCase().contains(_tunnelsSearchQuery)) {
          continue;
        }
      }

      if (local != null) {
        renderedTunnelIds.add(tunnelId);
        items.add(_buildTunnelRow(
          tunnelId: tunnelId,
          title: local.url.isNotEmpty ? local.url : (hostname.isNotEmpty ? 'https://$hostname' : name),
          subtitle: _composeSubtitle(
            service: service,
            status: status,
            localTunnel: local,
          ),
          isLocal: true,
          isConnected: true,
          tunnel: local,
        ));
      } else if (localProcess != null) {
        renderedTunnelIds.add(tunnelId);
        final detectedPid = _runningTunnels
            .where((t) => t.tunnelId == tunnelId)
            .map((t) => t.pid)
            .firstWhere((_) => true, orElse: () => -1);
        items.add(_buildTunnelRow(
          tunnelId: tunnelId,
          title: hostname.isNotEmpty ? 'https://$hostname' : name,
          subtitle: _composeSubtitle(
            service: service,
            status: 'Running locally',
            external: localProcess,
          ),
          isLocal: true,
          isConnected: true,
          pid: detectedPid > 0 ? detectedPid : null,
          url: hostname.isNotEmpty ? 'https://$hostname' : null,
        ));
      } else if (hasActiveConnections) {
        items.add(_buildTunnelRow(
          tunnelId: tunnelId,
          title: hostname.isNotEmpty ? 'https://$hostname' : name,
          subtitle: '$service  •  Connected (${connections.length} conns)',
          isLocal: false,
          isConnected: true,
        ));
      } else {
        items.add(_buildTunnelRow(
          tunnelId: tunnelId,
          title: hostname.isNotEmpty ? hostname : name,
          subtitle: service.isNotEmpty ? '$service  •  Inactive' : 'Inactive',
          isLocal: false,
          isConnected: false,
        ));
      }
    }

    for (var a in _activeTunnels.where((a) => a.tunnelId == null)) {
      if (_tunnelsSearchQuery.isNotEmpty) {
        if (!a.url.toLowerCase().contains(_tunnelsSearchQuery) && !a.localPort.toString().contains(_tunnelsSearchQuery)) {
          continue;
        }
      }

      items.add(_buildTunnelRow(
        tunnelId: null,
        title: a.url,
        subtitle: _composeSubtitle(
          service: '',
          status: 'Quick Tunnel',
          localTunnel: a,
        ),
        isLocal: true,
        tunnel: a,
      ));
    }

    for (final t in _runningTunnels) {
      if (renderedPids.contains(t.pid)) continue;
      if (t.tunnelId != null && renderedTunnelIds.contains(t.tunnelId)) continue;

      final port = _pidToTunnelPort[t.pid];
      if (port == null) continue;

      if (_tunnelsSearchQuery.isNotEmpty) {
        final pidStr = t.pid.toString();
        final portStr = port.toString();
        if (!pidStr.contains(_tunnelsSearchQuery) && !portStr.contains(_tunnelsSearchQuery)) {
          continue;
        }
      }

      renderedPids.add(t.pid);
      if (t.tunnelId != null) renderedTunnelIds.add(t.tunnelId!);

      final proc = _pidToLocalProcess[t.pid];
      final title = _pidToTunnelLabel[t.pid] ?? 'https://...';
      items.add(_buildTunnelRow(
        tunnelId: t.tunnelId,
        title: title,
        subtitle: _composeSubtitle(
          service: '',
          status: t.isQuickTunnel ? 'Quick Tunnel (external)' : 'Running externally',
          external: proc,
          fallbackPort: port,
        ),
        isLocal: true,
        isConnected: true,
        pid: t.pid,
      ));
    }

    return items;
  }

  Widget _buildHealthDot(TunnelHealth health) {
    final Color color;
    final String label;
    if (!health.isReachable) {
      color = Colors.redAccent;
      label = health.error != null
          ? 'Down · ${health.error}'
          : 'Down${health.statusCode != null ? ' (${health.statusCode})' : ''}';
    } else if (health.isSlow) {
      color = Colors.orangeAccent;
      label = 'Slow · ${health.latencyMs} ms${health.statusCode != null ? ' · ${health.statusCode}' : ''}';
    } else {
      color = Colors.greenAccent;
      label = 'Up · ${health.latencyMs} ms${health.statusCode != null ? ' · ${health.statusCode}' : ''}';
    }
    return Tooltip(
      message: label,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: color.withOpacity(0.5), blurRadius: 4, spreadRadius: 1),
          ],
        ),
      ),
    );
  }

  String _composeSubtitle({
    required String service,
    required String status,
    ActiveTunnel? localTunnel,
    OpenPort? external,
    int? fallbackPort,
  }) {
    final parts = <String>[];
    if (service.isNotEmpty) parts.add(service);
    parts.add(status);
    final proc = localTunnel != null
        ? _openPorts.firstWhere(
            (p) => p.port == localTunnel.localPort,
            orElse: () => OpenPort(port: localTunnel.localPort, processName: ''),
          )
        : external;
    if (proc != null && proc.processName.isNotEmpty) {
      final pidSuffix = proc.pid != null ? ' · pid ${proc.pid}' : '';
      parts.add('${proc.processName} · :${proc.port}$pidSuffix');
    } else {
      final port = proc?.port ?? localTunnel?.localPort ?? fallbackPort;
      if (port != null) parts.add('localhost:$port');
    }
    return parts.join('  •  ');
  }

  Widget _buildTunnelRow({String? tunnelId, required String title, required String subtitle, required bool isLocal, bool isConnected = false, ActiveTunnel? tunnel, int? pid, String? url}) {
    final Color borderColor = isLocal
        ? Colors.green.withOpacity(0.5)
        : isConnected
            ? Colors.blue.withOpacity(0.4)
            : const Color(0xFF334155);
    final Color iconColor = isLocal
        ? Colors.green
        : isConnected
            ? Colors.blue
            : Colors.blueGrey;
    final IconData icon = isLocal
        ? Icons.computer
        : isConnected
            ? Icons.cloud_done
            : Icons.cloud_outlined;
    final Color subtitleColor = isLocal
        ? Colors.greenAccent
        : isConnected
            ? Colors.lightBlueAccent
            : Colors.grey;
    final copyUrl = tunnel?.url ?? url ?? title;
    final health = _tunnelHealth[copyUrl];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 28),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (health != null) ...[
                      const SizedBox(width: 8),
                      _buildHealthDot(health),
                    ] else if (_isCheckingHealth) ...[
                      const SizedBox(width: 8),
                      const SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.grey),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(subtitle, style: TextStyle(fontSize: 12, color: subtitleColor)),
              ],
            ),
          ),
          if (isLocal && tunnel != null) ...[
            IconButton(
              icon: const Icon(Icons.copy, size: 20, color: Colors.grey),
              tooltip: 'Copy URL',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: copyUrl));
                _showToast('URL copied to clipboard!', isInfo: true);
              },
            ),
            IconButton(
              icon: const Icon(Icons.terminal, size: 20, color: Colors.grey),
              tooltip: 'View Logs',
              onPressed: () => _showLogsDialog(tunnel),
            ),
            IconButton(
              icon: const Icon(Icons.stop_circle, size: 28, color: Colors.redAccent),
              tooltip: 'Stop Tunnel',
              onPressed: () => _stopTunnel(tunnel),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 24, color: Colors.redAccent),
              tooltip: 'Stop & Delete from Cloudflare',
              onPressed: () => _deleteTunnel(tunnel: tunnel),
            ),
          ] else if (isLocal && pid != null) ...[
            IconButton(
              icon: const Icon(Icons.copy, size: 20, color: Colors.grey),
              tooltip: 'Copy URL',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: copyUrl));
                _showToast('URL copied to clipboard!', isInfo: true);
              },
            ),
            IconButton(
              icon: const Icon(Icons.terminal, size: 20, color: Colors.grey,
                  ),
              tooltip: 'View Logs',
              onPressed: () => _showLogsUnavailableDialog(),
            ),
            IconButton(
              icon: const Icon(Icons.stop_circle, size: 28, color: Colors.redAccent),
              tooltip: 'Kill external cloudflared process',
              onPressed: () async {
                try {
                  Process.killPid(pid);
                  _showToast('Killed cloudflared (pid $pid)', isInfo: true);
                  _fetchRemoteTunnels();
                } catch (e) {
                  _showToast('Failed to kill: $e', isError: true);
                }
              },
            ),
            if (tunnelId != null)
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 24, color: Colors.redAccent),
                tooltip: 'Kill & Delete from Cloudflare',
                onPressed: () => _deleteTunnel(tunnelId: tunnelId, pid: pid),
              ),
          ] else if (!isLocal && tunnelId != null) ...[
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 24, color: Colors.redAccent),
              tooltip: 'Delete from Cloudflare',
              onPressed: () => _deleteRemoteTunnel(tunnelId),
            ),
          ]
        ],
      ),
    );
  }

  void _showLogsDialog(ActiveTunnel tunnel) {
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Container(
            width: 600,
            height: 400,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.terminal, color: Colors.greenAccent),
                    const SizedBox(width: 8),
                    Text('Logs for Port ${tunnel.localPort}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                  ],
                ),
                const Divider(color: Color(0xFF334155)),
                Expanded(
                  child: ValueListenableBuilder<List<String>>(
                    valueListenable: tunnel.logs,
                    builder: (context, logs, child) {
                      if (logs.isEmpty) return const Center(child: Text('No logs available yet.', style: const TextStyle(color: Colors.grey)));
                      return ListView.builder(
                        itemCount: logs.length,
                        itemBuilder: (context, index) {
                          return Text(logs[index], style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.white70));
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showLogsUnavailableDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Row(
          children: [
            Icon(Icons.info_outline, color: Colors.orangeAccent),
            SizedBox(width: 8),
            Text('Logs unavailable'),
          ],
        ),
        content: const Text(
          'This cloudflared process was started outside this app session, so its log stream was never captured. To see live logs, stop the tunnel and start a new one from the app.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK', style: TextStyle(color: Colors.orangeAccent)),
          ),
        ],
      ),
    );
  }
}

class ActiveTunnel {
  final String? tunnelId;
  final String? name;
  final int localPort;
  String url;
  final Process process;
  final ValueNotifier<List<String>> logs;

  ActiveTunnel({
    this.tunnelId,
    this.name,
    required this.localPort,
    required this.url,
    required this.process,
    required this.logs,
  });
}

class BindDomainDialog extends StatefulWidget {
  final int localPort;
  const BindDomainDialog({super.key, required this.localPort});

  @override
  State<BindDomainDialog> createState() => _BindDomainDialogState();
}

class _BindDomainDialogState extends State<BindDomainDialog> {
  final _subdomainController = TextEditingController();
  List<Map<String, dynamic>> _zones = [];
  Map<String, dynamic>? _selectedZone;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchZones();
  }

  Future<void> _fetchZones() async {
    final zones = await CloudflareService.getZones();
    setState(() {
      _zones = zones;
      if (_zones.isNotEmpty) _selectedZone = _zones.first;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Bind Port ${widget.localPort} to Domain', style: const TextStyle(fontWeight: FontWeight.bold)),
      content: _isLoading
          ? const SizedBox(height: 100, child: Center(child: CircularProgressIndicator()))
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_zones.isEmpty)
                  const Text('No domains found in your Cloudflare account. Please add a site first.', style: TextStyle(color: Colors.redAccent))
                else ...[
                  TextField(
                    controller: _subdomainController,
                    decoration: InputDecoration(
                      labelText: 'Subdomain (e.g. app)',
                      filled: true,
                      fillColor: const Color(0xFF0F172A),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<Map<String, dynamic>>(
                    value: _selectedZone,
                    decoration: InputDecoration(
                      labelText: 'Zone / Domain',
                      filled: true,
                      fillColor: const Color(0xFF0F172A),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                    ),
                    dropdownColor: const Color(0xFF1E293B),
                    items: _zones.map((zone) {
                      return DropdownMenuItem<Map<String, dynamic>>(
                        value: zone,
                        child: Text(zone['name']),
                      );
                    }).toList(),
                    onChanged: (val) => setState(() => _selectedZone = val),
                  ),
                ]
              ],
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
        ),
        if (!_isLoading && _zones.isNotEmpty)
          ElevatedButton(
            onPressed: () {
              final sub = _subdomainController.text.trim();
              if (sub.isEmpty || _selectedZone == null) return;
              Navigator.pop(context, {'subdomain': sub, 'zone': _selectedZone});
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF6821F),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Bind'),
          ),
      ],
    );
  }
}
