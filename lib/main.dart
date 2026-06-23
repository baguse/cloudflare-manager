import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'port_scanner.dart';
import 'settings_screen.dart';
import 'dns_editor_screen.dart';
import 'webhook_screen.dart';
import 'rate_alert_screen.dart';
import 'webhook_service.dart';
import 'rate_alert_service.dart';
import 'daemon/events.dart';
import 'cloudflared_service.dart';
import 'cloudflare_service.dart';
import 'tunnel_health.dart';
import 'latency_sparkline.dart';
import 'tunnel_heatmap.dart';
import 'tunnel_watcher.dart';
import 'http_inspector.dart';
import 'har_exporter.dart';
import 'tray_service.dart';
import 'tunnel_service_manager.dart';
import 'daemon/ipc_client.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:brotli/brotli.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(1280, 720),
    minimumSize: Size(900, 600),
    center: true,
    title: 'Cloudflare Manager',
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

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

class _DashboardScreenState extends State<DashboardScreen> with WindowListener {
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
  final Map<String, List<int>> _tunnelHealthHistory = {};
  final Map<String, Map<String, int>> _tunnelActivity = {};
  bool _isCheckingHealth = false;
  HttpInspector? _inspector;
  StreamSubscription<CapturedRequest>? _inspectorSub;
  final TunnelWatcher _watcher = TunnelWatcher();
  StreamSubscription<WatcherEvent>? _watcherSub;
  bool _isLoadingPorts = true;
  bool _isLoadingRemoteTunnels = false;
  bool _isCloudflaredInstalled = false;
  Timer? _refreshTimer;
  Timer? _connectivityTimer;
  Set<int> _previousPorts = {};
  Set<int> _offeredPorts = {};
  int? _autoBindMinPort;
  int? _autoBindMaxPort;
  bool _isDaemonRunning = false;
  bool _isDaemonLoading = false;
  final DaemonClient _daemonClient = DaemonClient();
  final _secureStorage = const FlutterSecureStorage();

  final _portsSearchController = TextEditingController();
  final _tunnelsSearchController = TextEditingController();
  final _inspectorSearchController = TextEditingController();
  String _portsSearchQuery = '';
  String _tunnelsSearchQuery = '';
  String _inspectorSearchQuery = '';
  String? _selectedTunnelTag;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    TrayService.instance.init();
    _checkCloudflared();
    _checkDaemonStatus();
    _fetchPorts();
    _restoreInspector();
    _bootstrap();
    _loadPortRange();
    RateAlertService.instance.loadAlerts().then((_) => RateAlertService.instance.startChecker());
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _fetchPorts();
      _fetchRemoteTunnels();
      _checkDaemonStatus();
    });
    _connectivityTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      _checkTunnelConnectivity();
    });

    _portsSearchController.addListener(() {
      setState(() => _portsSearchQuery = _portsSearchController.text.toLowerCase());
    });
    _tunnelsSearchController.addListener(() {
      setState(() => _tunnelsSearchQuery = _tunnelsSearchController.text.toLowerCase());
    });
    _inspectorSearchController.addListener(() {
      setState(() => _inspectorSearchQuery = _inspectorSearchController.text.toLowerCase());
    });
  }

  Future<void> _bootstrap() async {
    await _fetchRemoteTunnels();
    await _restoreWatchedTunnels();
    _watcherSub = _watcher.events.listen(_onWatcherEvent);
    _watcher.start();
  }

  Future<void> _checkCloudflared() async {
    final isInstalled = await CloudflaredService.isInstalled();
    if (mounted) setState(() => _isCloudflaredInstalled = isInstalled);
  }

  Future<void> _checkDaemonStatus() async {
    final running = await _daemonClient.isDaemonRunning;
    if (mounted) setState(() => _isDaemonRunning = running);
  }

  Future<void> _startDaemon() async {
    if (_isDaemonLoading) return;
    setState(() => _isDaemonLoading = true);
    
    final installed = await TunnelServiceManager.instance.isServiceInstalled();
    if (!installed) {
      final error = await TunnelServiceManager.instance.installService();
      if (error != null) {
        _showToast('Failed to install service: $error', isError: true);
        await _checkDaemonStatus();
        setState(() => _isDaemonLoading = false);
        return;
      }
      _showToast('Service installed and started', isInfo: true);
    } else {
      final error = await TunnelServiceManager.instance.startDaemon();
      if (error != null) {
        _showToast('Failed to start daemon: $error', isError: true);
      } else {
        _showToast('Daemon started', isInfo: true);
      }
    }
    await Future.delayed(const Duration(seconds: 2));
    await _checkDaemonStatus();
    setState(() => _isDaemonLoading = false);
  }

  Future<void> _stopDaemon() async {
    if (_isDaemonLoading) return;
    setState(() => _isDaemonLoading = true);
    
    final error = await TunnelServiceManager.instance.stopDaemon();
    if (error != null) {
      _showToast('Failed to stop daemon: $error', isError: true);
    } else {
      _showToast('Daemon stopped', isInfo: true);
    }
    await _checkDaemonStatus();
    setState(() => _isDaemonLoading = false);
  }

  Future<void> _performServiceToggle(String tunnelId, bool enabled) async {
    final token = await CloudflaredService.readAppTunnelToken(tunnelId);
    if (token == null) {
      _showToast('No token stored. Create tunnel from the app first.', isError: true);
      return;
    }
    await CloudflaredService.saveServiceEnabled(tunnelId, enabled);
    String? error;
    if (enabled) {
      error = await TunnelServiceManager.instance.installService();
    } else {
      error = await TunnelServiceManager.instance.stopDaemon();
    }
    if (error != null) {
      _showToast('Error: $error', isError: true);
      return;
    }
    if (mounted) setState(() {});
    _showToast(enabled ? 'Service installed' : 'Service stopped', isInfo: true);
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _connectivityTimer?.cancel();
    _watcherSub?.cancel();
    _watcher.stop();
    _inspectorSub?.cancel();
    _inspector?.stop();
    _portsSearchController.dispose();
    _tunnelsSearchController.dispose();
    _inspectorSearchController.dispose();
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    TrayService.instance.handleWindowClose();
  }

  Future<void> _fetchPorts() async {
    final ports = await PortScanner.getOpenPorts();
    if (!mounted) return;

    final currentPorts = ports.map((p) => p.port).toSet();
    if (_previousPorts.isNotEmpty) {
      final newPorts = currentPorts.difference(_previousPorts);
      for (final port in newPorts) {
        final openPort = ports.where((p) => p.port == port).firstOrNull;
        _offerBind(port, openPort);
      }
    }
    _previousPorts = currentPorts;
    _offeredPorts.removeWhere((p) => !currentPorts.contains(p));

    setState(() {
      _openPorts = ports;
      _isLoadingPorts = false;
    });
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

    final allNotes = await CloudflaredService.readAllTunnelNotes();
    for (final entry in allNotes.entries) {
      final id = entry.key;
      configs[id] ??= <String, String>{};
      if (entry.value.notes != null) configs[id]!['notes'] = entry.value.notes!;
      if (entry.value.tags != null) configs[id]!['tags'] = entry.value.tags!;
    }

    for (final id in configs.keys) {
      final enabled = await CloudflaredService.readServiceEnabled(id);
      if (enabled) configs[id]!['serviceEnabled'] = 'true';
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
    _checkTunnelConnectivity();
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

  Future<void> _checkTunnelConnectivity() async {
    if (_isCheckingHealth) return;
    final urls = _collectHealthCheckUrls();
    if (urls.isEmpty) return;
    setState(() => _isCheckingHealth = true);
    final results = await TunnelHealthChecker.checkAll(urls);
    if (mounted) {
      setState(() {
        _tunnelHealth = results;
        for (final entry in results.entries) {
          final sample = entry.value.isReachable ? entry.value.latencyMs : -1;
          final history = _tunnelHealthHistory.putIfAbsent(entry.key, () => <int>[]);
          history.add(sample);
          if (history.length > 30) {
            history.removeRange(0, history.length - 30);
          }
          if (entry.value.isReachable) {
            final today = DateTime.now().toIso8601String().substring(0, 10);
            final dayMap = _tunnelActivity.putIfAbsent(entry.key, () => <String, int>{});
            dayMap[today] = (dayMap[today] ?? 0) + 1;
            _pruneOldActivity(dayMap);
          }
        }
        _isCheckingHealth = false;
      });
    }
  }

  List<int> _getHealthHistory(String url) {
    final history = _tunnelHealthHistory[url];
    if (history != null && history.isNotEmpty) return history;
    final current = _tunnelHealth[url];
    if (current != null) {
      final sample = current.isReachable ? current.latencyMs : -1;
      return <int>[sample];
    }
    return <int>[];
  }

  void _pruneOldActivity(Map<String, int> dayMap) {
    final cutoff = DateTime.now().subtract(const Duration(days: 30)).toIso8601String().substring(0, 10);
    dayMap.removeWhere((date, _) => date.compareTo(cutoff) < 0);
  }

  void _toggleWatcher() {
    setState(() {
      _watcher.setEnabled(!_watcher.isEnabled);
    });
    _showToast(
      _watcher.isEnabled ? 'Watcher enabled' : 'Watcher disabled',
      isInfo: true,
    );
  }

  Future<void> _restoreWatchedTunnels() async {
    final appMap = await CloudflaredService.readAppTunnelPortMapFull();
    final runningTunnels = await CloudflaredService.getRunningTunnels();
    for (final entry in appMap.entries) {
      final tunnelId = entry.key;
      final port = entry.value.port;

      if (!await CloudflaredService.credentialsFileExists(tunnelId)) continue;

      final serviceEnabled = await CloudflaredService.readServiceEnabled(tunnelId);
      if (serviceEnabled) continue;

      final cfg = _tunnelConfigs[tunnelId];
      final hostname = cfg?['hostname'];
      if (hostname == null || hostname.isEmpty) {
        await CloudflaredService.unregisterAppTunnel(tunnelId);
        await CloudflaredService.deleteCredentialsFile(tunnelId);
        continue;
      }

      final existsRemotely = _remoteTunnels.any((t) => t['id'] == tunnelId);
      if (!existsRemotely) {
        await CloudflaredService.unregisterAppTunnel(tunnelId);
        await CloudflaredService.deleteCredentialsFile(tunnelId);
        continue;
      }

      final match = runningTunnels.where((t) => t.tunnelId == tunnelId).toList();
      if (match.isEmpty) {
        continue;
      }
      final pid = match.first.pid;
      _watcher.watch(
        tunnelId: tunnelId,
        port: port,
        hostname: hostname,
        currentPid: pid,
      );
    }
  }

  void _onWatcherEvent(WatcherEvent event) {
    if (!mounted) return;
    final newProcess = event.newProcess;
    if (newProcess != null) {
      final id = event.tunnelId;
      final tunnel = _activeTunnels.cast<ActiveTunnel?>().firstWhere(
        (t) => t?.tunnelId == id,
        orElse: () => null,
      );
      if (tunnel != null) {
        tunnel.replaceProcess(newProcess);
        newProcess.stdout.transform(utf8.decoder).listen((data) {
          tunnel.logs.value = [...tunnel.logs.value, data];
        });
        newProcess.stderr.transform(utf8.decoder).listen((data) {
          tunnel.logs.value = [...tunnel.logs.value, data];
        });
      }
    }
    if (event.status == TunnelWatcherStatus.reconnecting) {
      _showToast('Tunnel reconnecting…', isInfo: true);
    } else if (event.status == TunnelWatcherStatus.crashLoop) {
      _showToast('Tunnel crash loop — check configuration', isError: true);
    } else if (event.status == TunnelWatcherStatus.lostNoToken) {
      _showToast('Tunnel died — no stored token to respawn', isError: true);
    } else if (event.newProcess != null) {
      _showToast('Tunnel reconnected', isInfo: true);
    }
    setState(() {});
  }

  void _fireWebhook(DaemonEventType type, {String? tunnelId, String? hostname, int? port}) {
    WebhookService.instance.loadWebhooks().then((_) {
      WebhookService.instance.triggerWebhooks(DaemonEvent(
        type: type,
        tunnelId: tunnelId,
        hostname: hostname,
        port: port,
      ));
    }).catchError((e) {
      _showToast('Webhook error: $e', isError: true);
    });
  }

  Future<void> _ensureDaemon() async {
    if (_isDaemonRunning) return;
    _showToast('Starting daemon service...', isInfo: true);
    await _startDaemon();
    await Future.delayed(const Duration(seconds: 2));
    await _checkDaemonStatus();
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

      _fireWebhook(DaemonEventType.tunnelCreated, tunnelId: tunnelId, hostname: fullDomain, port: port);

      _showToast('Configuring routing...', isInfo: true);
      final configured = await CloudflareService.configureTunnel(tunnelId, fullDomain, port);
      if (!configured) throw Exception('Failed to configure tunnel routing');

      _showToast('Creating DNS record...', isInfo: true);
      final dnsCreated = await CloudflareService.createTunnelDnsRecord(zone['id'], subdomain, tunnelId);
      if (!dnsCreated) throw Exception('Failed to create DNS record');

      await CloudflaredService.registerAppTunnel(tunnelId, port, token: tunnelToken, hostname: fullDomain);

      _showToast('Starting via daemon...', isInfo: true);
      await _ensureDaemon();

      final client = DaemonClient();
      if (!await client.connect()) throw Exception('Daemon not reachable');
      final bindResult = await client.bindTunnel(tunnelId, tunnelToken, fullDomain, port);
      client.disconnect();

      if (bindResult['ok'] != true) {
        throw Exception(bindResult['error'] ?? 'Daemon failed to bind tunnel');
      }

      final daemonPid = bindResult['pid'] as int?;

      _watcher.watch(
        tunnelId: tunnelId,
        port: port,
        hostname: fullDomain,
        token: tunnelToken,
        currentPid: daemonPid,
      );

      final activeTunnel = ActiveTunnel(
        tunnelId: tunnelId,
        name: 'tunnel-$subdomain-$port',
        localPort: port,
        url: 'https://$fullDomain',
        pid: daemonPid,
        logs: ValueNotifier<List<String>>([]),
      );

      setState(() => _activeTunnels.add(activeTunnel));

      _showToast('Tunnel $fullDomain is active!');
      _fetchRemoteTunnels();
      Future.delayed(const Duration(seconds: 3), _checkTunnelConnectivity);
    } catch (e) {
      _showToast('Error: $e', isError: true);
    }
  }

  Future<void> _stopTunnel(ActiveTunnel tunnel) async {
    tunnel.process?.kill();
    if (tunnel.tunnelId != null) {
      _watcher.unwatch(tunnel.tunnelId!);
      _tunnelLocalProcess.remove(tunnel.tunnelId);
      _runningTunnels.removeWhere((t) => t.tunnelId == tunnel.tunnelId);
      _daemonClient.unbindTunnel(tunnel.tunnelId!).catchError((_) => <String, dynamic>{});
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

  Future<void> _startInspector(OpenPort localService) async {
    if (_inspector != null) {
      _showToast('Inspector is already running on port ${_inspector!.listenPort}', isInfo: true);
      return;
    }
    final result = await showDialog<Map<String, int>>(
      context: context,
      builder: (context) => InspectorConfigDialog(service: localService),
    );
    if (result == null) return;
    final listenPort = result['listen']!;
    final targetPort = result['target']!;
    if (listenPort == localService.port) {
      _showToast('Inspector port must differ from the service port', isError: true);
      return;
    }
    try {
      final inspector = HttpInspector(listenPort: listenPort, targetPort: targetPort);
      await inspector.start();
      final sub = inspector.onRequest.listen((_) {
        if (mounted) setState(() {});
      });
      if (mounted) {
        setState(() {
          _inspector = inspector;
          _inspectorSub = sub;
        });
      }
      await CloudflaredService.saveInspectorConfig(listenPort, targetPort);
      _showToast('Inspector listening on :$listenPort → :$targetPort', isInfo: true);
    } catch (e) {
      _showToast('Failed to start inspector: $e', isError: true);
    }
  }

  Future<void> _stopInspector() async {
    await _inspectorSub?.cancel();
    _inspectorSub = null;
    await _inspector?.stop();
    await CloudflaredService.clearInspectorConfig();
    if (mounted) setState(() => _inspector = null);
    _showToast('Inspector stopped', isInfo: true);
  }

  void _clearInspectorLogs() {
    _inspector?.clear();
    if (mounted) setState(() {});
  }

  Future<void> _saveHar() async {
    final inspector = _inspector;
    if (inspector == null || inspector.requests.isEmpty) {
      _showToast('No requests to export', isInfo: true);
      return;
    }
    try {
      final har = HarExporter.build(
        inspector.requests,
        inspectorUrl: 'http://localhost:${inspector.listenPort}',
      );
      final encoder = const JsonEncoder.withIndent('  ');
      final json = encoder.convert(har);

      final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      final dir = home != null ? Directory('$home/Downloads') : Directory.systemTemp;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final file = File('${dir.path}/cloudflare-inspector-$stamp.har');
      await file.writeAsString(json);

      if (mounted) {
        _showToast('Saved ${inspector.requests.length} requests to ${file.path}', isInfo: true);
        Clipboard.setData(ClipboardData(text: file.path));
        await Future.delayed(const Duration(milliseconds: 200));
        _showToast('Path copied to clipboard', isInfo: true);
      }
    } catch (e) {
      _showToast('Failed to save HAR: $e', isError: true);
    }
  }

  Future<void> _bindExistingTunnel(String tunnelId) async {
    if (!_isCloudflaredInstalled) {
      _showToast('cloudflared is not installed!', isError: true);
      return;
    }
    final token = await CloudflaredService.readAppTunnelToken(tunnelId);
    final hasCreds = await CloudflaredService.credentialsFileExists(tunnelId);
    if (token == null && !hasCreds) {
      _showToast('No stored credentials for this tunnel. Create it from the app first.', isError: true);
      return;
    }
    final cfg = _tunnelConfigs[tunnelId];
    final hostname = cfg?['hostname'];
    if (hostname == null || hostname.isEmpty) {
      _showToast('Tunnel has no hostname configured.', isError: true);
      return;
    }
    final port = await showDialog<int>(
      context: context,
      builder: (context) => BindPortDialog(
        tunnelConfigs: _tunnelConfigs,
        tunnelId: tunnelId,
        openPorts: _openPorts,
      ),
    );
    if (port == null) return;

    try {
      _showToast('Reconfiguring tunnel...', isInfo: true);
      final ok = await CloudflareService.configureTunnel(tunnelId, hostname, port);
      if (!ok) throw Exception('Failed to reconfigure tunnel');

      await CloudflaredService.registerAppTunnel(tunnelId, port, token: token, hostname: hostname);

      int? startPid;
      if (token != null) {
        _showToast('Starting via daemon...', isInfo: true);
        await _ensureDaemon();

        final client = DaemonClient();
        if (!await client.connect()) throw Exception('Daemon not reachable');
        final bindResult = await client.bindTunnel(tunnelId, token, hostname, port);
        client.disconnect();

        if (bindResult['ok'] != true) {
          throw Exception(bindResult['error'] ?? 'Daemon failed to bind tunnel');
        }
        startPid = bindResult['pid'] as int?;
      } else {
        _showToast('Starting cloudflared...', isInfo: true);
        final process = await CloudflaredService.startTunnelById(tunnelId);
        if (process == null) throw Exception('No credentials file found');
        startPid = process.pid;
      }

      _watcher.watch(
        tunnelId: tunnelId,
        port: port,
        hostname: hostname,
        currentPid: startPid,
      );

      final activeTunnel = ActiveTunnel(
        tunnelId: tunnelId,
        name: 'tunnel-$hostname',
        localPort: port,
        url: 'https://$hostname',
        pid: startPid,
        logs: ValueNotifier<List<String>>([]),
      );

      setState(() => _activeTunnels.add(activeTunnel));

      _showToast('Tunnel https://$hostname → :$port is active!');
      _fetchRemoteTunnels();
      Future.delayed(const Duration(seconds: 3), _checkTunnelConnectivity);
    } catch (e) {
      _showToast('Bind failed: $e', isError: true);
    }
  }

  Future<void> _restoreInspector() async {
    final cfg = await CloudflaredService.readInspectorConfig();
    if (cfg == null) return;
    try {
      final inspector = HttpInspector(listenPort: cfg.listen, targetPort: cfg.target);
      await inspector.start();
      final sub = inspector.onRequest.listen((_) {
        if (mounted) setState(() {});
      });
      if (mounted) {
        setState(() {
          _inspector = inspector;
          _inspectorSub = sub;
        });
        _showToast('Inspector restored on :${cfg.listen} → :${cfg.target}', isInfo: true);
      }
    } catch (e) {
      await CloudflaredService.clearInspectorConfig();
    }
  }

  Future<void> _deleteTunnel({ActiveTunnel? tunnel, String? tunnelId, int? pid}) async {
    final id = tunnel?.tunnelId ?? tunnelId;
    if (id == null) return;
    if (!await _confirmDelete()) return;
    _showToast('Deleting tunnel...', isInfo: true);

    if (tunnel != null) {
      tunnel.process?.kill();
      if (tunnel.tunnelId != null) {
        _tunnelLocalProcess.remove(tunnel.tunnelId!);
        _runningTunnels.removeWhere((t) => t.tunnelId == tunnel.tunnelId);
        try { await _daemonClient.unbindTunnel(tunnel.tunnelId!); } catch (_) {}
      }
      setState(() => _activeTunnels.remove(tunnel));
    } else if (pid != null) {
      try {
        Process.killPid(pid);
        _runningTunnels.removeWhere((t) => t.pid == pid);
        if (tunnelId != null) {
          try { await _daemonClient.unbindTunnel(tunnelId); } catch (_) {}
        }
      } catch (e) {
      }
    }

    await CloudflaredService.saveServiceEnabled(id, false);
    await CloudflaredService.unregisterAppTunnel(id);
    await CloudflaredService.deleteCredentialsFile(id);
    _watcher.unwatch(id);
    await CloudflareService.deleteTunnelDnsRecords(id);
    final success = await CloudflareService.deleteTunnel(id);
    if (success) {
      _showToast('Tunnel and DNS record deleted.');
      _fireWebhook(DaemonEventType.tunnelDeleted, tunnelId: id);
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
    await CloudflaredService.deleteCredentialsFile(tunnelId);
    await CloudflaredService.unregisterAppTunnel(tunnelId);
    final success = await CloudflareService.deleteTunnel(tunnelId);
    if (success) {
      _showToast('Tunnel and DNS record deleted.');
      _fireWebhook(DaemonEventType.tunnelDeleted, tunnelId: tunnelId);
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

  Future<void> _loadPortRange() async {
    final min = await _secureStorage.read(key: 'auto_bind_min_port');
    final max = await _secureStorage.read(key: 'auto_bind_max_port');
    if (min != null) _autoBindMinPort = int.tryParse(min);
    if (max != null) _autoBindMaxPort = int.tryParse(max);
  }

  bool _isPortAllowed(int port) {
    if (_autoBindMinPort != null && port < _autoBindMinPort!) return false;
    if (_autoBindMaxPort != null && port > _autoBindMaxPort!) return false;
    return true;
  }

  void _offerBind(int port, OpenPort? openPort) {
    if (_tunnelLabelForPort(port) != null) return;
    if (!_isPortAllowed(port)) return;
    if (_offeredPorts.contains(port)) return;
    _offeredPorts.add(port);
    final label = openPort?.processName ?? 'port $port';
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Expanded(
              child: Text(
                'Detected new service: $label on :$port',
                style: const TextStyle(fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: () => _startTunnel(port),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('BIND', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            ),
          ],
        ),
        backgroundColor: const Color(0xFFF6821F),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: '✕',
          textColor: Colors.white70,
          onPressed: () => messenger.hideCurrentSnackBar(),
        ),
      ),
    );
  }

  void _showToast(String message, {bool isError = false, bool isInfo = false}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.redAccent : (isInfo ? Colors.blueGrey : Colors.green),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: '✕',
          textColor: Colors.white70,
          onPressed: () => messenger.hideCurrentSnackBar(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 1200;
          return Row(
            children: [
              _buildSidebar(isWide: isWide),
              Expanded(child: _buildMainContent(isWide: isWide)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSidebar({required bool isWide}) {
    return Material(
      color: const Color(0xFF1E293B),
      child: SizedBox(
        width: isWide ? 250 : 60,
        child: isWide ? _buildWideSidebar() : _buildNarrowSidebar(),
      ),
    );
  }

  Widget _buildWideSidebar() {
    return Column(
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
          tileColor: const Color(0xFF1E293B),
          selectedTileColor: const Color(0xFF0F172A),
          onTap: () {},
        ),
        ListTile(
          leading: const Icon(Icons.dns, color: Colors.grey),
          title: const Text('DNS Editor', style: TextStyle(color: Colors.grey)),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DnsEditorScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.webhook, color: Colors.grey),
          title: const Text('Webhooks', style: TextStyle(color: Colors.grey)),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WebhookScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.speed, color: Colors.grey),
          title: const Text('Rate Alerts', style: TextStyle(color: Colors.grey)),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RateAlertScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.settings, color: Colors.grey),
          title: const Text('Settings', style: TextStyle(color: Colors.grey)),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
        ),
        ListTile(
          leading: Icon(
            _watcher.isEnabled ? Icons.visibility : Icons.visibility_off,
            color: _watcher.isEnabled ? const Color(0xFFF6821F) : Colors.grey,
          ),
          title: Text(
            'Watcher: ${_watcher.isEnabled ? "ON" : "OFF"} (${_watcher.watched.length})',
            style: TextStyle(color: _watcher.isEnabled ? const Color(0xFFF6821F) : Colors.grey),
          ),
          onTap: _toggleWatcher,
        ),
        ListTile(
          leading: const Icon(Icons.bug_report, color: Colors.redAccent),
          title: const Text('Kill Daemons', style: TextStyle(color: Colors.redAccent)),
          onTap: _killOrphanedDaemons,
        ),
        ListTile(
          leading: Icon(Icons.dns, color: _isDaemonRunning ? Colors.green : Colors.grey),
          title: Text(
            'Daemon: ${_isDaemonRunning ? "Running" : "Stopped"}',
            style: TextStyle(color: _isDaemonRunning ? Colors.green : Colors.grey),
          ),
          subtitle: const Text(
            'User-level service',
            style: TextStyle(fontSize: 10, color: Colors.grey),
          ),
          trailing: _isDaemonLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  icon: Icon(_isDaemonRunning ? Icons.stop : Icons.play_arrow, size: 20),
                  color: _isDaemonRunning ? Colors.redAccent : Colors.green,
                  onPressed: _isDaemonRunning ? _stopDaemon : _startDaemon,
                ),
          onTap: _isDaemonLoading ? null : (_isDaemonRunning ? _stopDaemon : _startDaemon),
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
    );
  }

  Widget _buildNarrowSidebar() {
    return Column(
      children: [
        const SizedBox(height: 16),
        const Icon(Icons.cloud_circle, size: 32, color: Color(0xFFF6821F)),
        const SizedBox(height: 24),
        _sidebarIcon(Icons.dashboard, 'Dashboard', active: true),
        const SizedBox(height: 8),
        _sidebarIcon(Icons.dns, 'DNS Editor', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DnsEditorScreen()))),
        const SizedBox(height: 8),
        _sidebarIcon(Icons.webhook, 'Webhooks', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WebhookScreen()))),
        const SizedBox(height: 8),
        _sidebarIcon(Icons.speed, 'Rate Alerts', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RateAlertScreen()))),
        const SizedBox(height: 8),
        _sidebarIcon(Icons.settings, 'Settings', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()))),
        const SizedBox(height: 8),
        _sidebarIcon(
          _watcher.isEnabled ? Icons.visibility : Icons.visibility_off,
          'Watcher',
          active: _watcher.isEnabled,
          onTap: _toggleWatcher,
        ),
        const SizedBox(height: 8),
        _sidebarIcon(Icons.bug_report, 'Kill Daemons', onTap: _killOrphanedDaemons, active: true, activeColor: Colors.redAccent),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Icon(
            _isCloudflaredInstalled ? Icons.check_circle : Icons.error,
            color: _isCloudflaredInstalled ? Colors.green : Colors.redAccent,
            size: 18,
          ),
        ),
      ],
    );
  }

  Widget _sidebarIcon(IconData icon, String tooltip, {bool active = false, Color activeColor = const Color(0xFFF6821F), VoidCallback? onTap}) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF0F172A) : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 20, color: active ? activeColor : Colors.grey),
        ),
      ),
    );
  }

  Widget _buildMainContent({required bool isWide}) {
    return Padding(
      padding: EdgeInsets.all(isWide ? 32.0 : 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Overview', style: TextStyle(fontSize: isWide ? 28 : 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 24),
          Expanded(
            child: isWide ? _buildWidePanels() : _buildNarrowPanels(),
          ),
          if (isWide && _inspector != null) ...[
            const SizedBox(height: 16),
            SizedBox(
              height: 280,
              child: _buildInspectorPanel(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWidePanels() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 5, child: _buildLocalServicesPanel()),
        const SizedBox(width: 24),
        Expanded(flex: 7, child: _buildTunnelsPanel()),
      ],
    );
  }

  Widget _buildNarrowPanels() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final panelHeight = (_inspector != null)
            ? constraints.maxHeight * 0.42
            : constraints.maxHeight * 0.48;
        return SingleChildScrollView(
          child: Column(
            children: [
              SizedBox(height: panelHeight, child: _buildLocalServicesPanel()),
              const SizedBox(height: 12),
              SizedBox(height: panelHeight, child: _buildTunnelsPanel()),
              if (_inspector != null) ...[
                const SizedBox(height: 12),
                SizedBox(
                  height: constraints.maxHeight * 0.30,
                  child: _buildInspectorPanel(),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildLocalServicesPanel() {
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
                    itemBuilder: (context, index) => _buildPortItem(filteredPorts[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTunnelsPanel() {
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
          _buildTunnelTagFilter(),
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
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Start HTTP Inspector',
                icon: Icon(
                  _inspector != null ? Icons.visibility : Icons.visibility_outlined,
                  size: 20,
                  color: _inspector != null ? const Color(0xFFF6821F) : Colors.grey,
                ),
                onPressed: isTunneled ? null : () => _startInspector(portInfo),
              ),
              const SizedBox(width: 4),
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
        ],
      ),
    );
  }

  Widget _buildInspectorPanel() {
    final inspector = _inspector!;
    final requests = inspector.requests;
    final filtered = _inspectorSearchQuery.isEmpty
        ? requests
        : requests.where((r) {
            final q = _inspectorSearchQuery;
            if (r.path.toLowerCase().contains(q)) return true;
            if (r.method.toLowerCase().contains(q)) return true;
            if (r.statusCode != null && r.statusCode.toString().contains(q)) return true;
            if (r.error != null && r.error!.toLowerCase().contains(q)) return true;
            final ct = _contentType(r.responseHeaders);
            if (ct != null && ct.toLowerCase().contains(q)) return true;
            return false;
          }).toList();
    return Card(
      color: const Color(0xFF1E293B),
      elevation: 8,
      shadowColor: Colors.black45,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final isPanelWide = constraints.maxWidth > 750;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(20, 12, 20, isPanelWide ? 12 : 4),
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.visibility, color: Color(0xFFF6821F), size: 20),
                            const SizedBox(width: 12),
                            const Text('Request Inspector', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'localhost:${inspector.listenPort} → localhost:${inspector.targetPort}',
                            style: const TextStyle(fontSize: 11, color: Colors.white70, fontFamily: 'monospace'),
                          ),
                        ),
                        SizedBox(
                          width: 140,
                          height: 28,
                          child: TextField(
                            controller: _inspectorSearchController,
                            style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.white70),
                            decoration: InputDecoration(
                              hintText: 'Filter...',
                              hintStyle: const TextStyle(fontSize: 11, color: Colors.grey, fontFamily: 'monospace'),
                              prefixIcon: const Icon(Icons.search, size: 14, color: Colors.grey),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                              filled: true,
                              fillColor: const Color(0xFF0F172A),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide.none),
                              isDense: true,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.green.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: Colors.green.withOpacity(0.4)),
                          ),
                          child: Text(
                            _inspectorSearchQuery.isEmpty
                                ? '${requests.length} REQ'
                                : '${filtered.length}/${requests.length}',
                            style: const TextStyle(fontSize: 10, color: Colors.greenAccent, fontWeight: FontWeight.bold),
                          ),
                        ),
                        if (isPanelWide) _buildInspectorActions(inspector, requests),
                      ],
                    ),
                  ),
                  if (!isPanelWide)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                      child: _buildInspectorActions(inspector, requests),
                    ),
                ],
              );
            },
          ),
          const Divider(height: 1, color: Color(0xFF334155)),
          Expanded(
            child: requests.isEmpty
                ? const Center(
                    child: Text(
                      'No requests captured yet. Hit localhost:PORT in your browser or curl it.',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  )
                : filtered.isEmpty
                    ? const Center(
                        child: Text('No matching entries.', style: TextStyle(color: Colors.grey, fontSize: 12)),
                      )
                    : ListView.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const Divider(color: Color(0xFF334155), height: 1),
                        itemBuilder: (context, i) => _buildCapturedRequestRow(filtered[filtered.length - 1 - i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildInspectorActions(HttpInspector inspector, List<CapturedRequest> requests) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      children: [
        TextButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: 'http://localhost:${inspector.listenPort}'));
            _showToast('Inspector URL copied', isInfo: true);
          },
          icon: const Icon(Icons.copy, size: 14, color: Colors.grey),
          label: const Text('Copy', style: TextStyle(color: Colors.grey, fontSize: 12)),
        ),
        TextButton.icon(
          onPressed: requests.isEmpty ? null : _clearInspectorLogs,
          icon: const Icon(Icons.cleaning_services, size: 16, color: Colors.grey),
          label: const Text('Clear', style: TextStyle(color: Colors.grey, fontSize: 12)),
        ),
        TextButton.icon(
          onPressed: requests.isEmpty ? null : _saveHar,
          icon: const Icon(Icons.download, size: 16, color: Color(0xFFF6821F)),
          label: const Text('Save as HAR', style: TextStyle(color: Color(0xFFF6821F), fontSize: 12)),
        ),
        TextButton.icon(
          onPressed: _stopInspector,
          icon: const Icon(Icons.stop_circle, size: 16, color: Colors.redAccent),
          label: const Text('Stop', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
        ),
      ],
    );
  }

  Widget _buildCapturedRequestRow(CapturedRequest r) {
    final time = '${r.timestamp.hour.toString().padLeft(2, '0')}:${r.timestamp.minute.toString().padLeft(2, '0')}:${r.timestamp.second.toString().padLeft(2, '0')}';
    final isWs = r.wsFrames != null;
    final Color statusColor;
    if (!r.completed && !isWs) {
      statusColor = Colors.grey;
    } else if (r.error != null) {
      statusColor = Colors.redAccent;
    } else if (isWs && !r.completed) {
      statusColor = Colors.greenAccent;
    } else if (r.wsCloseCode != null && r.wsCloseCode! > 1001) {
      statusColor = Colors.redAccent;
    } else if (isWs) {
      statusColor = Colors.greenAccent;
    } else if (r.statusCode != null && r.statusCode! >= 500) {
      statusColor = Colors.redAccent;
    } else if (r.statusCode != null && r.statusCode! >= 400) {
      statusColor = Colors.orangeAccent;
    } else if (r.statusCode != null && r.statusCode! >= 300) {
      statusColor = Colors.lightBlueAccent;
    } else {
      statusColor = Colors.greenAccent;
    }
    final contentType = isWs ? null : _contentType(r.responseHeaders);
    final methodColor = isWs ? const Color(0xFF42A5F5) : const Color(0xFFF6821F);
    return InkWell(
      onTap: () => _showRequestDetailDialog(r),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 70,
              child: Text(time, style: const TextStyle(fontSize: 11, color: Colors.grey, fontFamily: 'monospace')),
            ),
            SizedBox(
              width: 50,
              child: Text(
                isWs
                  ? (r.completed
                      ? '${r.wsCloseCode ?? 101}'
                      : '101')
                  : (r.completed ? '${r.statusCode ?? (r.error != null ? 'ERR' : '…')}' : '…'),
                style: TextStyle(fontSize: 12, color: statusColor, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 50,
              child: Text(
                r.method,
                style: TextStyle(fontSize: 11, color: methodColor, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ),
            ),
            Expanded(
              child: Text(
                r.path,
                style: const TextStyle(fontSize: 12, color: Colors.white70, fontFamily: 'monospace'),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (contentType != null) ...[
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: const Color(0xFF334155)),
                  ),
                  child: Text(
                    contentType,
                    style: const TextStyle(fontSize: 9, color: Colors.white60, fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 8),
            SizedBox(
              width: 60,
              child: Text(
                isWs && !r.completed
                    ? 'live'
                    : (r.completed ? '${r.latencyMs ?? 0} ms' : '...'),
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 11, color: r.latencyMs != null && r.latencyMs! > 500 ? Colors.orangeAccent : Colors.grey, fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, size: 16, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  String? _contentType(Map<String, List<String>>? headers) {
    if (headers == null) return null;
    String? raw;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'content-type' && entry.value.isNotEmpty) {
        raw = entry.value.first;
        break;
      }
    }
    if (raw == null) return null;
    final mime = raw.split(';').first.trim();
    if (mime.isEmpty) return null;
    return mime;
  }

  String? _contentEncodingFromHeaders(Map<String, List<String>>? headers) {
    if (headers == null) return null;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'content-encoding' && entry.value.isNotEmpty) {
        return entry.value.first;
      }
    }
    return null;
  }

  String? _contentTypeFromHeaders(Map<String, List<String>>? headers) {
    if (headers == null) return null;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'content-type' && entry.value.isNotEmpty) {
        return entry.value.first.split(';').first.trim();
      }
    }
    return null;
  }

  void _showRequestDetailDialog(CapturedRequest r) {
    if (r.wsFrames != null) {
      _showWsDetailDialog(r);
      return;
    }
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          width: 700,
          height: 500,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('${r.method} ', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFFF6821F), fontFamily: 'monospace')),
                  Expanded(
                    child: Text(
                      r.path,
                      style: const TextStyle(fontSize: 14, color: Colors.white, fontFamily: 'monospace'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (r.statusCode != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: (r.statusCode! >= 400 ? Colors.redAccent : Colors.greenAccent).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('${r.statusCode}', style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                ],
              ),
              const Divider(color: Color(0xFF334155)),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildDetailSection('Request headers', r.requestHeaders),
                      if (r.requestBody != null) ...[
                        const SizedBox(height: 12),
                        _buildBodyDetail('Request body', r.requestBody!),
                      ],
                      if (r.responseHeaders != null) ...[
                        const SizedBox(height: 12),
                        _buildDetailSection('Response headers', r.responseHeaders!),
                      ],
                      if (r.responseBody != null) ...[
                        const SizedBox(height: 12),
                        _buildBodyDetail(
                          'Response body',
                          r.responseBody!,
                          contentEncoding: _contentEncodingFromHeaders(r.responseHeaders),
                          contentType: _contentTypeFromHeaders(r.responseHeaders),
                        ),
                      ],
                      if (r.error != null) ...[
                        const SizedBox(height: 12),
                        _buildSimpleDetail('Error', r.error!),
                      ],
                      const SizedBox(height: 12),
                      Text(
                        'Latency: ${r.latencyMs ?? '—'} ms  ·  ${r.timestamp.toIso8601String()}',
                        style: const TextStyle(color: Colors.grey, fontSize: 11, fontFamily: 'monospace'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showWsDetailDialog(CapturedRequest r) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          width: 700,
          height: 500,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('GET ', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF42A5F5), fontFamily: 'monospace')),
                  Expanded(
                    child: Text(
                      r.path,
                      style: const TextStyle(fontSize: 14, color: Colors.white, fontFamily: 'monospace'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: r.completed && r.wsCloseCode != null && r.wsCloseCode! > 1001
                          ? Colors.redAccent.withOpacity(0.2)
                          : Colors.greenAccent.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      r.completed ? '${r.wsCloseCode ?? 1005}' : '101',
                      style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF42A5F5).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('WS', style: TextStyle(fontSize: 10, color: Color(0xFF42A5F5), fontWeight: FontWeight.bold)),
                  ),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                ],
              ),
              const Divider(color: Color(0xFF334155)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildDetailSection('Request headers', r.requestHeaders),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.swap_horiz, size: 14, color: Color(0xFF42A5F5)),
                          const SizedBox(width: 8),
                          const Text('WebSocket Frames', style: TextStyle(fontSize: 12, color: Color(0xFFF6821F), fontWeight: FontWeight.bold)),
                          const Spacer(),
                          Text('${r.wsFrames!.length} frames', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: r.wsFrames!.isEmpty
                          ? const Center(child: Text('No frames captured yet', style: TextStyle(color: Colors.grey, fontSize: 12)))
                          : ListView.separated(
                              itemCount: r.wsFrames!.length,
                              separatorBuilder: (_, __) => const Divider(color: Color(0xFF334155), height: 1),
                              itemBuilder: (context, i) => _buildWsFrameRow(r.wsFrames![i]),
                            ),
                    ),
                    if (r.error != null) ...[
                      const SizedBox(height: 8),
                      _buildSimpleDetail('Error', r.error!),
                    ],
                    if (r.completed) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Connection closed  ·  ${r.wsCloseReason ?? 'no reason'}  ·  ${r.latencyMs ?? 0} ms  ·  ${r.timestamp.toIso8601String()}',
                        style: const TextStyle(color: Colors.grey, fontSize: 11, fontFamily: 'monospace'),
                      ),
                    ] else ...[
                      const SizedBox(height: 8),
                      const Row(
                        children: [
                          Icon(Icons.circle, size: 6, color: Colors.greenAccent),
                          SizedBox(width: 6),
                          Text('Connected', style: TextStyle(color: Colors.greenAccent, fontSize: 11)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWsFrameRow(CapturedWsFrame f) {
    final ts = '${f.timestamp.hour.toString().padLeft(2, '0')}:${f.timestamp.minute.toString().padLeft(2, '0')}:${f.timestamp.second.toString().padLeft(2, '0')}';
    final isUp = f.direction.contains('\u2191');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(ts, style: const TextStyle(fontSize: 10, color: Colors.grey, fontFamily: 'monospace')),
          const SizedBox(width: 8),
          Text(isUp ? '\u2191' : '\u2193', style: TextStyle(fontSize: 12, color: isUp ? Colors.orangeAccent : Colors.cyanAccent, fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: f.isText ? Colors.green.withOpacity(0.15) : Colors.grey.withOpacity(0.15),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              f.isText ? 'TEXT' : 'BIN',
              style: TextStyle(fontSize: 9, color: f.isText ? Colors.greenAccent : Colors.grey, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: f.isText && f.text != null
                ? Text(
                    f.text!.length > 200 ? '${f.text!.substring(0, 200)}…' : f.text!,
                    style: const TextStyle(fontSize: 11, color: Colors.white70, fontFamily: 'monospace'),
                  )
                : Text(
                    '[binary ${f.size} bytes]',
                    style: const TextStyle(fontSize: 11, color: Colors.grey, fontFamily: 'monospace', fontStyle: FontStyle.italic),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSimpleDetail(String title, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 12, color: Color(0xFFF6821F), fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(value, style: const TextStyle(fontSize: 11, color: Colors.white70, fontFamily: 'monospace')),
        ),
      ],
    );
  }

  Widget _buildBodyDetail(String title, CapturedBody body, {String? contentEncoding, String? contentType}) {
    final enc = contentEncoding?.toLowerCase().trim();
    final mime = contentType?.toLowerCase().trim();
    final isImage = mime != null && mime.startsWith('image/');

    String? displayText;
    if (enc == 'gzip' || enc == 'deflate' || enc == 'x-gzip') {
      try {
        final codec = (enc == 'deflate') ? ZLibCodec() : GZipCodec();
        final decompressed = codec.decoder.convert(body.bytes);
        displayText = utf8.decode(decompressed, allowMalformed: true);
      } catch (e) {
        displayText = '[decompress failed: $e]';
      }
    } else if (enc == 'br') {
      try {
        final decompressed = brotliDecode(body.bytes);
        displayText = utf8.decode(decompressed, allowMalformed: true);
      } catch (e) {
        displayText = '[decompress failed: $e]';
      }
    } else if (!isImage) {
      displayText = body.text;
    }

    final isJson = displayText != null && (displayText.trimLeft().startsWith('{') || displayText.trimLeft().startsWith('['));
    final pretty = isJson ? _tryPrettyJson(displayText) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(title, style: const TextStyle(fontSize: 12, color: Color(0xFFF6821F), fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Text(
              body.truncated
                  ? '${body.totalBytes} bytes (truncated, showing first ${body.bytes.length})'
                  : '${body.totalBytes} bytes',
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
            if (mime != null) ...[
              const SizedBox(width: 8),
              Text(mime, style: const TextStyle(fontSize: 10, color: Colors.grey, fontFamily: 'monospace')),
            ],
          ],
        ),
        const SizedBox(height: 4),
        if (isImage) ...[
          Container(
            constraints: const BoxConstraints(maxHeight: 320),
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(6),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.memory(
                Uint8List.fromList(body.bytes),
                fit: BoxFit.contain,
                errorBuilder: (context, error, stack) => Text(
                  'Image failed to render: $error',
                  style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                ),
              ),
            ),
          ),
          if (displayText != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'Raw bytes (first 200): ${body.bytes.take(200).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}',
                style: const TextStyle(fontSize: 10, color: Colors.grey, fontFamily: 'monospace'),
              ),
            ),
          ],
        ] else ...[
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.vertical,
                child: SelectableText(
                  pretty ?? displayText ?? body.text,
                  style: const TextStyle(fontSize: 11, color: Colors.white70, fontFamily: 'monospace', height: 1.4),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  String? _tryPrettyJson(String text) {
    try {
      final decoded = json.decode(text);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      return null;
    }
  }

  Widget _buildDetailSection(String title, Map<String, List<String>> headers) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 12, color: Color(0xFFF6821F), fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: headers.entries.expand((entry) {
              return entry.value.map((v) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: RichText(
                  text: TextSpan(
                    style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.white70),
                    children: [
                      TextSpan(text: '${entry.key}: ', style: const TextStyle(color: Color(0xFFF6821F))),
                      TextSpan(text: v),
                    ],
                  ),
                ),
              ));
            }).toList(),
          ),
        ),
      ],
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

      if (_selectedTunnelTag != null && _selectedTunnelTag!.isNotEmpty) {
        final tags = config?['tags'] ?? '';
        if (!tags.split(',').map((t) => t.trim()).contains(_selectedTunnelTag)) {
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
          watcherStatus: _watcher.watched[tunnelId]?.status,
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
      } else {
        renderedTunnelIds.add(tunnelId);
        if (hasActiveConnections) {
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
            onBind: hostname.isNotEmpty ? () => _bindExistingTunnel(tunnelId) : null,
          ));
        }
      }
    }

    for (var a in _activeTunnels.where((a) => a.tunnelId == null)) {
      if (_tunnelsSearchQuery.isNotEmpty) {
        if (!a.url.toLowerCase().contains(_tunnelsSearchQuery) && !a.localPort.toString().contains(_tunnelsSearchQuery)) {
          continue;
        }
      }
      if (_selectedTunnelTag != null && _selectedTunnelTag!.isNotEmpty) continue;

      renderedPids.add(a.pid ?? a.process?.pid ?? -1);
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
      if (_selectedTunnelTag != null && _selectedTunnelTag!.isNotEmpty) {
        final tid = t.tunnelId;
        if (tid == null) continue;
        final ttags = _tunnelConfigs[tid]?['tags'] ?? '';
        if (!ttags.split(',').map((t) => t.trim()).contains(_selectedTunnelTag)) {
          continue;
        }
      }

      renderedPids.add(t.pid);
      if (t.tunnelId != null) renderedTunnelIds.add(t.tunnelId!);

      final proc = _pidToLocalProcess[t.pid];
      final label = _pidToTunnelLabel[t.pid];
      if (label == null) {
        items.add(_buildOrphanProcessRow(t, port, proc));
      } else {
        items.add(_buildTunnelRow(
          tunnelId: t.tunnelId,
          title: label,
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
    }

    return items;
  }

  Widget _buildTunnelTagFilter() {
    final allTags = <String>{};
    for (final id in _tunnelConfigs.keys) {
      final tags = _tunnelConfigs[id]?['tags'] ?? '';
      for (final t in tags.split(',').map((t) => t.trim())) {
        if (t.isNotEmpty) allTags.add(t);
      }
    }
    if (allTags.isEmpty) return const SizedBox.shrink();

    final sorted = allTags.toList()..sort();
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: FilterChip(
              label: const Text('All', style: TextStyle(fontSize: 12)),
              selected: _selectedTunnelTag == null || _selectedTunnelTag!.isEmpty,
              onSelected: (_) => setState(() => _selectedTunnelTag = null),
              selectedColor: const Color(0xFFF6821F),
              checkmarkColor: Colors.white,
              labelStyle: TextStyle(
                fontSize: 12,
                color: _selectedTunnelTag == null || _selectedTunnelTag!.isEmpty ? Colors.white : Colors.grey,
              ),
              backgroundColor: const Color(0xFF1E293B),
              side: BorderSide.none,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              visualDensity: VisualDensity.compact,
            ),
          ),
          ...sorted.map((tag) {
            final color = _tagColors[tag] ?? const Color(0xFF6366F1);
            final isSelected = _selectedTunnelTag == tag;
            return Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                label: Text(tag, style: TextStyle(fontSize: 12, color: isSelected ? Colors.white : Colors.grey[300])),
                selected: isSelected,
                onSelected: (_) => setState(() => _selectedTunnelTag = isSelected ? null : tag),
                selectedColor: color,
                checkmarkColor: Colors.white,
                backgroundColor: const Color(0xFF1E293B),
                side: BorderSide.none,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                visualDensity: VisualDensity.compact,
              ),
            );
          }),
        ],
      ),
    );
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

  Widget _buildOrphanProcessRow(TunnelInfo t, int port, OpenPort? proc) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        border: Border.all(color: Colors.grey.withOpacity(0.5)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.help_outline, color: Colors.grey, size: 28),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        'Orphan cloudflared process',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white70),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.grey.withOpacity(0.4)),
                      ),
                      child: const Text('NO TUNNEL', style: TextStyle(fontSize: 9, color: Colors.grey, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'localhost:$port · pid ${t.pid} · started outside this app and not in your Cloudflare account',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.stop_circle, size: 28, color: Colors.redAccent),
            tooltip: 'Kill process',
            onPressed: () async {
              try {
                Process.killPid(t.pid);
                _runningTunnels.removeWhere((r) => r.pid == t.pid);
                _showToast('Killed cloudflared (pid ${t.pid})', isInfo: true);
                _fetchRemoteTunnels();
              } catch (e) {
                _showToast('Failed to kill: $e', isError: true);
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildWatcherChip(TunnelWatcherStatus status) {
    final String label;
    final Color color;
    switch (status) {
      case TunnelWatcherStatus.watching:
        label = 'WATCHING';
        color = Colors.greenAccent;
        break;
      case TunnelWatcherStatus.reconnecting:
        label = 'RECONNECTING';
        color = Colors.orangeAccent;
        break;
      case TunnelWatcherStatus.crashLoop:
        label = 'CRASH LOOP';
        color = Colors.redAccent;
        break;
      case TunnelWatcherStatus.lostNoToken:
        label = 'NO TOKEN';
        color = Colors.grey;
        break;
    }
    return Tooltip(
      message: 'Auto-reconnect: ${label.toLowerCase()}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 9, color: color, fontWeight: FontWeight.bold),
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

  Widget _buildTunnelRow({String? tunnelId, required String title, required String subtitle, required bool isLocal, bool isConnected = false, ActiveTunnel? tunnel, int? pid, String? url, VoidCallback? onBind, TunnelWatcherStatus? watcherStatus}) {
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
    final noteData = tunnelId != null ? _tunnelConfigs[tunnelId] : null;
    final notes = noteData?['notes'];
    final tags = noteData?['tags'];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
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
                          const SizedBox(width: 6),
                          LatencySparkline(
                            samples: _getHealthHistory(copyUrl),
                          ),
                        ] else if (_isCheckingHealth) ...[
                          const SizedBox(width: 8),
                          const SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.grey),
                          ),
                        ],
                        if (watcherStatus != null) ...[
                          const SizedBox(width: 8),
                          _buildWatcherChip(watcherStatus),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(subtitle, style: TextStyle(fontSize: 12, color: subtitleColor)),
                    if (tags != null && tags.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      _buildTagChips(tags),
                    ],
                    if (notes != null && notes.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          const Icon(Icons.notes, size: 12, color: Colors.orangeAccent),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              notes,
                              style: const TextStyle(fontSize: 11, color: Colors.grey, fontStyle: FontStyle.italic),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
            if (tunnelId != null)
              IconButton(
                icon: Icon(Icons.edit_note, size: 20, color: (notes != null && notes.isNotEmpty) ? const Color(0xFFF6821F) : Colors.grey),
                tooltip: 'Edit notes & tags',
                onPressed: () => _showNotesDialog(tunnelId),
              ),
            if (tunnelId != null)
              IconButton(
                icon: Icon(Icons.shield, size: 20, color: _tunnelConfigs[tunnelId]?['serviceEnabled'] == 'true' ? Colors.green : Colors.grey),
                tooltip: 'Service mode',
                onPressed: () => _showServiceDialog(tunnelId),
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
              icon: const Icon(Icons.qr_code, size: 20, color: Colors.grey),
              tooltip: 'Show QR Code',
              onPressed: () => _showQrDialog(copyUrl),
            ),
            IconButton(
              icon: const Icon(Icons.calendar_month, size: 18, color: Colors.grey),
              tooltip: 'Activity heatmap',
              onPressed: () => _showHeatmapDialog(copyUrl),
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
              icon: const Icon(Icons.qr_code, size: 20, color: Colors.grey),
              tooltip: 'Show QR Code',
              onPressed: () => _showQrDialog(copyUrl),
            ),
            IconButton(
              icon: const Icon(Icons.calendar_month, size: 18, color: Colors.grey),
              tooltip: 'Activity heatmap',
              onPressed: () => _showHeatmapDialog(copyUrl),
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
                  if (tunnelId != null) {
                    _tunnelLocalProcess.remove(tunnelId);
                    _daemonClient.unbindTunnel(tunnelId).catchError((_) => <String, dynamic>{});
                  }
                  _runningTunnels.removeWhere((r) => r.pid == pid);
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
              icon: const Icon(Icons.qr_code, size: 20, color: Colors.grey),
              tooltip: 'Show QR Code',
              onPressed: () => _showQrDialog(copyUrl),
            ),
            IconButton(
              icon: const Icon(Icons.calendar_month, size: 18, color: Colors.grey),
              tooltip: 'Activity heatmap',
              onPressed: () => _showHeatmapDialog(copyUrl),
            ),
            if (onBind != null)
              TextButton.icon(
                icon: const Icon(Icons.link, size: 16, color: Color(0xFFF6821F)),
                label: const Text('Bind', style: TextStyle(color: Color(0xFFF6821F), fontSize: 12)),
                onPressed: onBind,
              ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 24, color: Colors.redAccent),
              tooltip: 'Delete from Cloudflare',
              onPressed: () => _deleteRemoteTunnel(tunnelId),
            ),
          ]
            ],
          ),
        ],
      ),
    );
  }

  static const Map<String, Color> _tagColors = {
    'prod': Color(0xFFE53935),
    'production': Color(0xFFE53935),
    'staging': Color(0xFFFF8F00),
    'dev': Color(0xFF42A5F5),
    'development': Color(0xFF42A5F5),
    'api': Color(0xFF7C4DFF),
    'internal': Color(0xFF00ACC1),
    'testing': Color(0xFF43A047),
    'monitoring': Color(0xFFFDD835),
    'backend': Color(0xFF1E88E5),
    'frontend': Color(0xFF43A047),
    'database': Color(0xFF8E24AA),
    'auth': Color(0xFFE53935),
    'webhook': Color(0xFFFF8F00),
  };

  Color _tagColor(String tag) {
    return _tagColors[tag.toLowerCase()] ?? const Color(0xFF546E7A);
  }

  Widget _buildTagChips(String tags) {
    final parts = tags.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    return Wrap(
      spacing: 4,
      children: parts.map((tag) {
        final display = tag.length > 12 ? '${tag.substring(0, 12)}…' : tag;
        return Tooltip(
          message: tag,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: _tagColor(tag).withOpacity(0.15),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: _tagColor(tag).withOpacity(0.4)),
            ),
            child: Text(display, style: TextStyle(fontSize: 9, color: _tagColor(tag), fontWeight: FontWeight.bold)),
          ),
        );
      }).toList(),
    );
  }

  static const List<String> _presetTags = [
    'prod', 'staging', 'dev', 'api', 'internal', 'testing', 'monitoring',
    'backend', 'frontend', 'database', 'auth', 'webhook',
  ];

  void _showNotesDialog(String tunnelId) {
    final cfg = _tunnelConfigs[tunnelId] ?? {};
    final notesController = TextEditingController(text: cfg['notes'] ?? '');
    final initialTags = (cfg['tags'] ?? '').split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    final selectedTags = ValueNotifier<List<String>>(List.from(initialTags));
    final tagInputController = TextEditingController();

    void _toggleTag(String tag) {
      final current = List<String>.from(selectedTags.value);
      if (current.contains(tag)) {
        current.remove(tag);
      } else {
        if (current.length >= 5) {
          _showToast('Max 5 tags allowed', isInfo: true);
          return;
        }
        current.add(tag);
      }
      selectedTags.value = current;
    }

    void _addCustomTag(String tag) {
      final trimmed = tag.trim();
      if (trimmed.isEmpty) return;
      final current = List<String>.from(selectedTags.value);
      if (!current.contains(trimmed)) {
        if (current.length >= 5) {
          _showToast('Max 5 tags allowed', isInfo: true);
          return;
        }
        current.add(trimmed);
        selectedTags.value = current;
      }
      tagInputController.clear();
    }

    showDialog(
      context: context,
      builder: (dialogCtx) => Dialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          width: 450,
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.edit_note, color: Color(0xFFF6821F), size: 20),
                  const SizedBox(width: 10),
                  const Text('Tunnel Notes & Tags', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.pop(dialogCtx),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('Notes', style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 6),
              TextField(
                controller: notesController,
                maxLines: 4,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                decoration: InputDecoration(
                  hintText: 'e.g. staging env, behind SSO, owned by @alice',
                  hintStyle: const TextStyle(fontSize: 12, color: Colors.grey),
                  filled: true,
                  fillColor: const Color(0xFF1E293B),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.all(12),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Tags', style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 2),
              const Text('Max 5 tags', style: TextStyle(fontSize: 10, color: Colors.grey)),
              const SizedBox(height: 6),
              ValueListenableBuilder<List<String>>(
                valueListenable: selectedTags,
                builder: (context, tags, _) {
                  return Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: tags.map((tag) => Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: _tagColor(tag).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: _tagColor(tag).withOpacity(0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(tag, style: TextStyle(fontSize: 10, color: _tagColor(tag), fontWeight: FontWeight.bold)),
                          const SizedBox(width: 4),
                          GestureDetector(
                            onTap: () => _toggleTag(tag),
                            child: Icon(Icons.close, size: 12, color: _tagColor(tag)),
                          ),
                        ],
                      ),
                    )).toList(),
                  );
                },
              ),
              const SizedBox(height: 8),
              const Text('Preset tags:', style: TextStyle(fontSize: 10, color: Colors.grey)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: _presetTags.map((tag) {
                  return ValueListenableBuilder<List<String>>(
                    valueListenable: selectedTags,
                    builder: (context, tags, _) {
                      final isSelected = tags.contains(tag);
                      final disabled = !isSelected && tags.length >= 5;
                      return GestureDetector(
                        onTap: disabled ? null : () => _toggleTag(tag),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: isSelected ? _tagColor(tag).withOpacity(0.2) : const Color(0xFF1E293B),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: isSelected ? _tagColor(tag).withOpacity(0.5) : const Color(0xFF334155),
                            ),
                          ),
                          child: Text(
                            tag,
                            style: TextStyle(
                              fontSize: 10,
                              color: disabled ? Colors.grey : (isSelected ? _tagColor(tag) : Colors.grey),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.add, size: 14, color: Colors.grey),
                  const SizedBox(width: 6),
                  Expanded(
                    child: ValueListenableBuilder<List<String>>(
                      valueListenable: selectedTags,
                      builder: (context, tags, _) {
                        final atMax = tags.length >= 5;
                        return Autocomplete<String>(
                          optionsBuilder: atMax
                              ? (_) => const []
                              : (textEditingValue) {
                                  final query = textEditingValue.text.trim();
                                  if (query.isEmpty) return _presetTags;
                                  return _presetTags.where((t) => t.toLowerCase().contains(query.toLowerCase()));
                                },
                          fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
                            tagInputController.text = controller.text;
                            return TextField(
                              controller: controller,
                              focusNode: focusNode,
                              enabled: !atMax,
                              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                              decoration: InputDecoration(
                                hintText: atMax ? 'Max 5 tags reached' : 'Select or type custom…',
                                hintStyle: TextStyle(fontSize: 11, color: atMax ? Colors.redAccent.withOpacity(0.6) : Colors.grey),
                                filled: true,
                                fillColor: const Color(0xFF1E293B),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                isDense: true,
                              ),
                              onSubmitted: atMax ? null : (v) {
                                _addCustomTag(v);
                                controller.clear();
                              },
                            );
                          },
                          onSelected: atMax ? null : (option) {
                            _toggleTag(option);
                            tagInputController.clear();
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 40,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFF6821F),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () async {
                    final notes = notesController.text.trim();
                    final tags = selectedTags.value.join(',');
                    await CloudflaredService.saveTunnelNotes(
                      tunnelId,
                      notes: notes.isEmpty ? null : notes,
                      tags: tags.isEmpty ? null : tags,
                    );
                    if (mounted) {
                      setState(() {
                        _tunnelConfigs[tunnelId] ??= {};
                        _tunnelConfigs[tunnelId]!['notes'] = notes.isEmpty ? '' : notes;
                        _tunnelConfigs[tunnelId]!['tags'] = tags.isEmpty ? '' : tags;
                      });
                    }
                    Navigator.pop(dialogCtx);
                  },
                  child: const Text('Save', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showQrDialog(String url) {
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Container(
            width: 340,
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.qr_code_2, color: Color(0xFFF6821F)),
                    const SizedBox(width: 8),
                    const Text(
                      'Scan to open',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: QrImageView(
                    data: url,
                    version: QrVersions.auto,
                    size: 240,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Color(0xFF0F172A),
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Color(0xFF0F172A),
                    ),
                    errorStateBuilder: (context, err) => Container(
                      width: 240,
                      height: 240,
                      alignment: Alignment.center,
                      child: Text('QR error: $err', style: const TextStyle(color: Colors.red)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SelectableText(
                  url,
                  style: const TextStyle(fontSize: 12, color: Colors.white70, fontFamily: 'monospace'),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.copy, size: 16, color: Colors.white70),
                      label: const Text('Copy URL', style: TextStyle(color: Colors.white70)),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: url));
                        _showToast('URL copied to clipboard!', isInfo: true);
                      },
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      icon: const Icon(Icons.open_in_new, size: 16, color: Color(0xFFF6821F)),
                      label: const Text('Open', style: TextStyle(color: Color(0xFFF6821F))),
                      onPressed: () async {
                        final uri = Uri.parse(url);
                        var launched = false;
                        try {
                          launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
                        } catch (e) {
                          launched = false;
                        }
                        if (!launched && Platform.isLinux) {
                          try {
                            final result = await Process.run('xdg-open', [url]);
                            launched = result.exitCode == 0;
                          } catch (e) {
                            launched = false;
                          }
                        }
                        if (!launched) {
                          _showToast('Could not open browser. Install xdg-utils.', isError: true);
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showServiceDialog(String tunnelId) async {
    final installed = await TunnelServiceManager.instance.isServiceInstalled();
    final running = await TunnelServiceManager.instance.isDaemonRunning();
    final cfg = _tunnelConfigs[tunnelId] ?? {};
    final hostname = cfg['hostname'] ?? '';

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final serviceEnabled = _tunnelConfigs[tunnelId]?['serviceEnabled'] == 'true';
            return Dialog(
              backgroundColor: const Color(0xFF0F172A),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Container(
                width: 360,
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.shield, color: Color(0xFFF6821F), size: 20),
                        const SizedBox(width: 10),
                        const Text('Service Mode', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(hostname, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Icon(
                          running ? Icons.check_circle : (installed ? Icons.pause_circle : Icons.cancel),
                          color: running ? Colors.green : (installed ? Colors.orange : Colors.grey),
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          running ? 'Service running' : (installed ? 'Service installed (stopped)' : 'Not registered'),
                          style: TextStyle(
                            fontSize: 13,
                            color: running ? Colors.green : (installed ? Colors.orange : Colors.grey),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile(
                      title: const Text('Run as system service', style: TextStyle(fontSize: 14)),
                      subtitle: const Text('Survives app exit & reboots', style: TextStyle(fontSize: 11, color: Colors.grey)),
                      value: serviceEnabled,
                      activeThumbColor: const Color(0xFFF6821F),
                      onChanged: (v) {
                        _tunnelConfigs[tunnelId] ??= {};
                        _tunnelConfigs[tunnelId]!['serviceEnabled'] = v.toString();
                        setDialogState(() {});
                        if (mounted) setState(() {});
                        _performServiceToggle(tunnelId, v);
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      TunnelServiceManager.instance.privilegeNote(),
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showHeatmapDialog(String url) {
    final counts = _tunnelActivity[url] ?? const {};
    final max = counts.isEmpty ? 0 : counts.values.reduce((a, b) => a > b ? a : b);
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          width: 360,
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.calendar_month, color: Color(0xFFF6821F), size: 20),
                  const SizedBox(width: 10),
                  const Text('Activity Heatmap', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: TunnelHeatmap(dayCounts: counts, maxCount: max),
              ),
            ],
          ),
        ),
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
  Process? process;
  int? pid;
  final ValueNotifier<List<String>> logs;

  ActiveTunnel({
    this.tunnelId,
    this.name,
    required this.localPort,
    required this.url,
    this.process,
    this.pid,
    required this.logs,
  });

  void replaceProcess(Process? newProcess) {
    process = newProcess;
    if (newProcess != null) pid = newProcess.pid;
  }
}

class BindDomainDialog extends StatefulWidget {
  final int localPort;
  const BindDomainDialog({super.key, required this.localPort});

  @override
  State<BindDomainDialog> createState() => _BindDomainDialogState();
}

class InspectorConfigDialog extends StatefulWidget {
  final OpenPort service;
  const InspectorConfigDialog({super.key, required this.service});

  @override
  State<InspectorConfigDialog> createState() => _InspectorConfigDialogState();
}

class _InspectorConfigDialogState extends State<InspectorConfigDialog> {
  late final TextEditingController _listenController;
  late final TextEditingController _targetController;

  @override
  void initState() {
    super.initState();
    _listenController = TextEditingController(text: '${widget.service.port + 1}');
    _targetController = TextEditingController(text: '${widget.service.port}');
  }

  @override
  void dispose() {
    _listenController.dispose();
    _targetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Row(
        children: [
          Icon(Icons.visibility, color: Color(0xFFF6821F)),
          SizedBox(width: 8),
          Text('Start HTTP Inspector', style: TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Service on :${widget.service.port} (${widget.service.processName}) will be moved to a different port. The inspector will proxy between the two.',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _listenController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Inspector listen port',
              filled: true,
              fillColor: Color(0xFF0F172A),
              border: OutlineInputBorder(borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _targetController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Upstream port (your real service)',
              filled: true,
              fillColor: Color(0xFF0F172A),
              border: OutlineInputBorder(borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text(
              'Workflow: 1) stop the service on :PORT, 2) restart it on the upstream port, 3) click Bind on :INSPECTOR_PORT, 4) all tunneled traffic will be logged here.',
              style: TextStyle(color: Colors.grey, fontSize: 11),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
        ),
        ElevatedButton(
          onPressed: () {
            final listen = int.tryParse(_listenController.text.trim());
            final target = int.tryParse(_targetController.text.trim());
            if (listen == null || target == null || listen <= 0 || target <= 0) {
              return;
            }
            Navigator.pop(context, {'listen': listen, 'target': target});
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFF6821F),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: const Text('Start Inspector'),
        ),
      ],
    );
  }
}

class BindPortDialog extends StatefulWidget {
  final Map<String, Map<String, String>> tunnelConfigs;
  final String tunnelId;
  final List<OpenPort> openPorts;

  const BindPortDialog({
    super.key,
    required this.tunnelConfigs,
    required this.tunnelId,
    required this.openPorts,
  });

  @override
  State<BindPortDialog> createState() => _BindPortDialogState();
}

class _BindPortDialogState extends State<BindPortDialog> {
  late int _selectedPort;
  final TextEditingController _portController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final existing = widget.tunnelConfigs[widget.tunnelId];
    final service = existing?['service'] ?? '';
    final match = RegExp(r'localhost:(\d+)').firstMatch(service);
    _selectedPort = match != null ? int.parse(match.group(1)!) : (widget.openPorts.isNotEmpty ? widget.openPorts.first.port : 8080);
    _portController.text = '$_selectedPort';
  }

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cfg = widget.tunnelConfigs[widget.tunnelId];
    final hostname = cfg?['hostname'] ?? widget.tunnelId.substring(0, 8);
    final fullDomain = hostname.contains('.') ? hostname : 'https://$hostname';
    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          const Icon(Icons.link, color: Color(0xFFF6821F)),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Bind $fullDomain → local port', style: const TextStyle(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Reconfigures the tunnel to point at a local port, then starts cloudflared. Existing DNS stays as-is.',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 16),
          if (widget.openPorts.isNotEmpty) ...[
            const Text('Quick pick from listening ports:', style: TextStyle(color: Colors.grey, fontSize: 11)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: widget.openPorts.map((p) {
                final selected = p.port == _selectedPort;
                return ChoiceChip(
                  label: Text('${p.port}  ·  ${p.processName}', style: const TextStyle(fontSize: 11)),
                  selected: selected,
                  selectedColor: const Color(0xFFF6821F).withOpacity(0.3),
                  backgroundColor: const Color(0xFF0F172A),
                  side: BorderSide(color: selected ? const Color(0xFFF6821F) : const Color(0xFF334155)),
                  onSelected: (_) {
                    setState(() {
                      _selectedPort = p.port;
                      _portController.text = '${p.port}';
                    });
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _portController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Port',
              filled: true,
              fillColor: Color(0xFF0F172A),
              border: OutlineInputBorder(borderSide: BorderSide.none),
            ),
            onChanged: (v) {
              final p = int.tryParse(v);
              if (p != null) _selectedPort = p;
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
        ),
        ElevatedButton(
          onPressed: () {
            final p = int.tryParse(_portController.text.trim());
            if (p == null || p <= 0 || p > 65535) return;
            Navigator.pop(context, p);
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
