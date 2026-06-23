import 'dart:io';

class OpenPort {
  final int port;
  final String processName;
  final int? pid;

  OpenPort({required this.port, required this.processName, this.pid});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpenPort && runtimeType == other.runtimeType && port == other.port;

  @override
  int get hashCode => port.hashCode;
}

class PortScanner {
  static Future<List<OpenPort>> getOpenPorts() async {
    try {
      final String os = Platform.operatingSystem;
      if (os == 'linux') {
        final ssResult = await Process.run('ss', ['-tulnp']);
        if (ssResult.exitCode == 0) {
           return _parseSsOutput(ssResult.stdout.toString());
         }
       }

       if (os == 'linux' || os == 'macos') {
         final result = await Process.run('lsof', ['-iTCP', '-sTCP:LISTEN', '-P', '-n']);
         if (result.exitCode == 0) {
           return _parseLsofOutput(result.stdout.toString());
        }
      }
    } catch (e) {
      print('Error scanning ports: $e');
    }
    return [];
  }

  static List<OpenPort> _parseLsofOutput(String output) {
    final lines = output.split('\n');
    final Map<int, OpenPort> portsMap = {};

    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      final parts = line.split(RegExp(r'\s+'));
      if (parts.length >= 9) {
        final processName = parts[0];
        final pid = int.tryParse(parts[1]);
        final address = parts[8];

        final portString = address.split(':').last;
        final port = int.tryParse(portString);

        if (port != null) {
          portsMap[port] = OpenPort(port: port, processName: processName, pid: pid);
        }
      }
    }

    final sortedPorts = portsMap.values.toList()..sort((a, b) => a.port.compareTo(b.port));
    return sortedPorts;
  }

  static List<OpenPort> _parseSsOutput(String output) {
    final lines = output.split('\n');
    final Map<int, OpenPort> portsMap = {};

    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      final parts = line.split(RegExp(r'\s+'));
      if (parts.length >= 6) {
        final localAddress = parts[4];
        final processInfo = parts.length > 6 ? parts.sublist(6).join(' ') : 'Unknown';

        final portString = localAddress.split(':').last;
        final port = int.tryParse(portString);

        String processName = 'Unknown';
        int? pid;
        if (processInfo.contains('users:(("')) {
          final nameRegex = RegExp(r'users:\(\("([^"]+)"');
          final pidRegex = RegExp(r'pid=(\d+)');
          final nameMatch = nameRegex.firstMatch(processInfo);
          if (nameMatch != null) {
            processName = nameMatch.group(1) ?? 'Unknown';
          }
          final pidMatch = pidRegex.firstMatch(processInfo);
          if (pidMatch != null) {
            pid = int.tryParse(pidMatch.group(1) ?? '');
          }
        }

        if (port != null) {
          portsMap[port] = OpenPort(port: port, processName: processName, pid: pid);
        }
      }
    }

    final sortedPorts = portsMap.values.toList()..sort((a, b) => a.port.compareTo(b.port));
    return sortedPorts;
  }
}
