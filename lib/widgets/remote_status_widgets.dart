import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/remote_status_service.dart';

String _percent(double? value) => value == null
    ? '未知'
    : '${value.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '')}%';

class RemoteComputerStatus extends StatefulWidget {
  final String connectionId;
  final Future<ComputerStatus> Function()? load;

  const RemoteComputerStatus(
      {super.key, required this.connectionId, this.load});

  @override
  State<RemoteComputerStatus> createState() => _RemoteComputerStatusState();
}

class _RemoteComputerStatusState extends State<RemoteComputerStatus>
    with WidgetsBindingObserver {
  ComputerStatus? _status;
  bool _busy = false;
  String? _error;
  Timer? _timer;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_foreground && ModalRoute.of(context)?.isCurrent != false) {
        unawaited(_refresh());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && ModalRoute.of(context)?.isCurrent != false) {
      unawaited(_refresh());
    }
  }

  Future<ComputerStatus> _load() =>
      widget.load?.call() ?? RemoteStatusService.computer(widget.connectionId);

  Future<void> _refresh() async {
    if (_busy) return;
    _busy = true;
    try {
      final status = await _load();
      if (mounted) {
        setState(() {
          _status = status;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _status = null;
          _error = '电脑状态暂不可用';
        });
      }
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final gpu = status == null
        ? ''
        : status.gpuError != null
            ? 'GPU 暂不可用'
            : status.gpus.isEmpty
                ? 'GPU 未检测到'
                : status.gpus.length > 1
                    ? 'GPU ${status.gpus.length} 张'
                    : 'GPU ${_percent(status.gpus.first.usedPercent)}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: InkWell(
        key: const ValueKey('computer-status-summary'),
        onTap: () => _showStatusSheet<ComputerStatus>(context,
            title: '电脑状态', load: _load, content: _computerDetails),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(children: [
            const Icon(Icons.monitor_heart_outlined, size: 16),
            const SizedBox(width: 8),
            Expanded(
                child: Text(
              status == null
                  ? (_error ?? '正在读取电脑状态…')
                  : 'CPU ${_percent(status.cpuPercent)} · $gpu',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            )),
            const Icon(Icons.chevron_right, size: 18),
          ]),
        ),
      ),
    );
  }
}

List<Widget> _computerDetails(ComputerStatus status) => [
      ListTile(
        title: Text('CPU 使用率：${_percent(status.cpuPercent)}'),
        subtitle: Text(status.cpuError ??
            (status.cpuCores == null ? '核心数未知' : '${status.cpuCores} 个逻辑核心')),
      ),
      if (status.gpuError != null)
        ListTile(title: Text(status.gpuError!))
      else if (status.gpus.isEmpty)
        const ListTile(title: Text('GPU 未检测到')),
      for (var i = 0; i < status.gpus.length; i++)
        ListTile(
          title: Text('GPU ${i + 1} · ${status.gpus[i].name}'),
          subtitle: Text('使用率：${_percent(status.gpus[i].usedPercent)}\n'
              '显存：${_memory(status.gpus[i])}'),
          isThreeLine: true,
        ),
    ];

String _memory(GpuStatus gpu) {
  if (gpu.memoryUsedMiB == null || gpu.memoryTotalMiB == null) return '未知';
  return '${gpu.memoryUsedMiB!.round()} / ${gpu.memoryTotalMiB!.round()} MiB';
}

class CodexQuotaButton extends StatelessWidget {
  final String connectionId;
  final Future<CodexQuota> Function()? load;

  const CodexQuotaButton({super.key, required this.connectionId, this.load});

  @override
  Widget build(BuildContext context) => TextButton(
        key: const ValueKey('codex-quota-button'),
        onPressed: () => _showStatusSheet<CodexQuota>(
          context,
          title: 'Codex 额度',
          load: load ?? () => RemoteStatusService.quota(connectionId),
          content: _quotaDetails,
        ),
        child: const Text('额度', style: TextStyle(fontSize: 12)),
      );
}

List<Widget> _quotaDetails(CodexQuota quota) => [
      if (quota.buckets.isEmpty)
        const ListTile(
            title: Text('当前账号未返回额度信息'),
            subtitle: Text('API Key 或第三方服务账号可能不提供 Codex 订阅额度。')),
      for (final bucket in quota.buckets) ...[
        ListTile(
            title: Text(bucket.name),
            subtitle:
                bucket.planType == null ? null : Text('套餐：${bucket.planType}')),
        if (bucket.windows.isEmpty) const ListTile(title: Text('暂无法获取周期额度')),
        for (final window in bucket.windows)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${window.label} · 剩余 ${_percent(window.remainingPercent)}'),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: window.remainingPercent / 100),
              const SizedBox(height: 6),
              Text(
                  window.resetsAt == null
                      ? '重置时间未知'
                      : '重置时间：${DateFormat('MM-dd HH:mm').format(window.resetsAt!.toLocal())}',
                  style: const TextStyle(fontSize: 12)),
            ]),
          ),
        if (bucket.unlimitedCredits || bucket.creditBalance != null)
          ListTile(
              title: Text(bucket.unlimitedCredits
                  ? '额外点数：不限额'
                  : '额外点数：${bucket.creditBalance}')),
      ],
    ];

Future<void> _showStatusSheet<T>(
  BuildContext context, {
  required String title,
  required Future<T> Function() load,
  required List<Widget> Function(T) content,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) =>
          _StatusSheet<T>(title: title, load: load, content: content),
    );

class _StatusSheet<T> extends StatefulWidget {
  final String title;
  final Future<T> Function() load;
  final List<Widget> Function(T) content;
  const _StatusSheet(
      {required this.title, required this.load, required this.content});

  @override
  State<_StatusSheet<T>> createState() => _StatusSheetState<T>();
}

class _StatusSheetState<T> extends State<_StatusSheet<T>> {
  late Future<T> _future;
  DateTime? _updated;

  Future<T> _load() async {
    final value = await widget.load();
    _updated = DateTime.now();
    return value;
  }

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.65,
        child: FutureBuilder<T>(
            future: _future,
            builder: (context, snapshot) {
              final busy = snapshot.connectionState != ConnectionState.done;
              return Column(children: [
                ListTile(
                    title: Text(widget.title),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                            tooltip: '刷新状态',
                            onPressed: busy
                                ? null
                                : () {
                                    setState(() {
                                      _updated = null;
                                      _future = _load();
                                    });
                                  },
                            icon: const Icon(Icons.refresh)),
                        IconButton(
                            tooltip: '关闭',
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close)),
                      ],
                    )),
                Expanded(
                    child: busy
                        ? const Center(child: CircularProgressIndicator())
                        : snapshot.hasError
                            ? ListView(children: [
                                ListTile(
                                    title: const Text('暂无法获取，请稍后刷新'),
                                    subtitle: Text(snapshot.error.toString())),
                              ])
                            : ListView(
                                children: widget.content(snapshot.data as T))),
                if (!busy && !snapshot.hasError && _updated != null)
                  Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                          '更新于 ${DateFormat('HH:mm:ss').format(_updated!)}',
                          style: const TextStyle(fontSize: 11))),
              ]);
            }),
      );
}
