import 'dart:convert';

import 'package:flutter/services.dart';

import 'ssh_service.dart';
import 'codex_quota_rpc.dart';

class ComputerStatus {
  final double? cpuPercent;
  final int? cpuCores;
  final List<GpuStatus> gpus;
  final String? cpuError;
  final String? gpuError;

  ComputerStatus.fromJson(Map<String, dynamic> json)
      : cpuPercent = _number(json['cpuPercent']),
        cpuCores = (json['cpuCores'] as num?)?.toInt(),
        gpus = (json['gpus'] as List? ?? [])
            .map(
                (value) => GpuStatus.fromJson(Map<String, dynamic>.from(value)))
            .toList(),
        cpuError = json['cpuError'] as String?,
        gpuError = json['gpuError'] as String?;
}

class GpuStatus {
  final String name;
  final double? usedPercent;
  final double? memoryUsedMiB;
  final double? memoryTotalMiB;

  GpuStatus.fromJson(Map<String, dynamic> json)
      : name = json['name'] as String? ?? 'GPU',
        usedPercent = _number(json['usedPercent']),
        memoryUsedMiB = _number(json['memoryUsedMiB']),
        memoryTotalMiB = _number(json['memoryTotalMiB']);
}

double? _number(dynamic value) =>
    value is num && value.isFinite && value >= 0 ? value.toDouble() : null;

class QuotaWindow {
  final double remainingPercent;
  final int? durationMinutes;
  final DateTime? resetsAt;

  QuotaWindow.fromJson(Map<String, dynamic> json)
      : remainingPercent =
            (100 - (json['usedPercent'] as num)).clamp(0, 100).toDouble(),
        durationMinutes = (json['windowDurationMins'] as num?)?.toInt(),
        resetsAt = json['resetsAt'] is num
            ? DateTime.fromMillisecondsSinceEpoch(
                (json['resetsAt'] as num).toInt() * 1000)
            : null;

  String get label {
    final minutes = durationMinutes;
    if (minutes == null) return '额度周期';
    if (minutes % 1440 == 0) return '${minutes ~/ 1440} 天额度';
    if (minutes % 60 == 0) return '${minutes ~/ 60} 小时额度';
    return '$minutes 分钟额度';
  }
}

class QuotaBucket {
  final String name;
  final List<QuotaWindow> windows;
  final String? planType;
  final bool unlimitedCredits;
  final String? creditBalance;

  QuotaBucket.fromJson(Map<String, dynamic> json)
      : name = (json['limitName'] ?? json['limitId'] ?? 'Codex').toString(),
        planType = json['planType'] as String?,
        windows = [json['primary'], json['secondary']]
            .whereType<Map>()
            .where((value) => _number(value['usedPercent']) != null)
            .map((value) =>
                QuotaWindow.fromJson(Map<String, dynamic>.from(value)))
            .toList(),
        unlimitedCredits = (json['credits'] as Map?)?['unlimited'] == true,
        creditBalance = (json['credits'] as Map?)?['balance']?.toString();
}

class CodexQuota {
  final List<QuotaBucket> buckets;

  CodexQuota.fromJson(Map<String, dynamic> json) : buckets = _buckets(json);

  static List<QuotaBucket> _buckets(Map<String, dynamic> json) {
    final multiple = json['rateLimitsByLimitId'] as Map?;
    final values = multiple != null && multiple.isNotEmpty
        ? multiple.values
        : [if (json['rateLimits'] is Map) json['rateLimits']];
    return values
        .whereType<Map>()
        .map((value) => QuotaBucket.fromJson(Map<String, dynamic>.from(value)))
        .toList();
  }
}

class RemoteStatusService {
  static Future<Map<String, dynamic>> _readComputer(String connectionId) async {
    final client = SshService.getClient(connectionId);
    if (client == null) throw StateError('SSH 连接已断开');
    final source = await rootBundle.loadString('assets/remote_status.py');
    final encoded = base64Encode(utf8.encode(source));
    // Constant command arguments and a base64 alphabet need no user-input interpolation.
    final session = await client.execute(
        'python3 -c "import base64; exec(base64.b64decode(\'$encoded\'))"');
    try {
      final results = await Future.wait([
        utf8.decoder.bind(session.stdout).join(),
        utf8.decoder.bind(session.stderr).join(),
      ]).timeout(const Duration(seconds: 25));
      final value = Map<String, dynamic>.from(jsonDecode(results.first) as Map);
      if (value['error'] != null) throw StateError(value['error'].toString());
      return value;
    } on FormatException {
      throw StateError('电脑未返回有效状态，请检查 Python 3 是否可用');
    } finally {
      session.close();
    }
  }

  static Future<ComputerStatus> computer(String connectionId) async =>
      ComputerStatus.fromJson(await _readComputer(connectionId));

  static Future<CodexQuota> quota(String connectionId) async {
    final client = SshService.getClient(connectionId);
    if (client == null) throw StateError('SSH 连接已断开');
    return CodexQuota.fromJson(await CodexQuotaRpc.readRemote(client));
  }
}
