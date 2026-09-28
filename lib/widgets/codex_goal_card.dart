import 'dart:async';

import 'package:flutter/material.dart';

import '../models/codex_goal.dart';
import '../services/codex_session_service.dart';
import '../theme/app_theme.dart';

/// Shows the native Codex goal for the currently viewed conversation.
class CodexGoalCard extends StatefulWidget {
  final String connectionId;
  final String conversationId;
  final Future<CodexGoal?> Function()? loadGoal;

  const CodexGoalCard({
    super.key,
    required this.connectionId,
    required this.conversationId,
    this.loadGoal,
  });

  @override
  State<CodexGoalCard> createState() => _CodexGoalCardState();
}

class _CodexGoalCardState extends State<CodexGoalCard>
    with WidgetsBindingObserver {
  static const _refreshInterval = Duration(seconds: 15);

  Timer? _timer;
  CodexGoal? _goal;
  Object? _error;
  bool _loading = false;
  bool _expanded = false;
  bool _routeCurrent = true;
  int _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(_refreshInterval, (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          _isRouteCurrent) {
        _load();
      }
    });
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeCurrent = ModalRoute.of(context)?.isCurrent ?? true;
  }

  @override
  void didUpdateWidget(covariant CodexGoalCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connectionId != widget.connectionId ||
        oldWidget.conversationId != widget.conversationId) {
      _requestGeneration++;
      _goal = null;
      _error = null;
      _expanded = false;
      _loading = false;
      _load();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isRouteCurrent) _load();
  }

  bool get _isRouteCurrent => _routeCurrent;

  Future<void> _load() async {
    if (_loading || !mounted || !_isRouteCurrent) return;
    final generation = _requestGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final goal = await (widget.loadGoal?.call() ??
          CodexSessionService.readGoal(
            widget.connectionId,
            widget.conversationId,
          ));
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _goal = goal;
        _error = null;
      });
    } catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() => _error = error);
    } finally {
      if (mounted && generation == _requestGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    _requestGeneration++;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  String _statusLabel(String status) => switch (status.toLowerCase()) {
        'in_progress' || 'running' || 'active' => '进行中',
        'paused' => '已暂停',
        'completed' || 'complete' || 'done' => '已完成',
        'cancelled' || 'canceled' => '已取消',
        'failed' => '失败',
        _ => status,
      };

  @override
  Widget build(BuildContext context) {
    if (_goal == null) {
      if (_error == null) return const SizedBox.shrink();
      return _errorView();
    }

    final goal = _goal!;
    final longObjective = goal.objective.trim().split('\n').length > 3 ||
        goal.objective.trim().length > 180;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        border: Border.all(color: AppTheme.borderSubtle),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.flag_outlined, size: 16, color: AppTheme.blue),
              const SizedBox(width: 6),
              Text('Goal',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  )),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.blueDim,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(_statusLabel(goal.status),
                    style: TextStyle(fontSize: 11, color: AppTheme.blue)),
              ),
              const Spacer(),
              if (goal.tokenBudget != null)
                Text('${goal.tokensUsed} / ${goal.tokenBudget} tokens',
                    style: TextStyle(fontSize: 10, color: AppTheme.textMuted)),
            ],
          ),
          const SizedBox(height: 6),
          if (_expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                child: Text(goal.objective,
                    style:
                        TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ),
            )
          else
            Text(
              goal.objective,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
          if (longObjective)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(_expanded ? '收起' : '展开',
                    style: TextStyle(fontSize: 11, color: AppTheme.blue)),
              ),
            ),
          if (_error != null) _refreshFailure(),
        ],
      ),
    );
  }

  Widget _errorView() => Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: AppTheme.bgCard,
          border: Border.all(color: AppTheme.borderSubtle),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.error_outline, size: 14, color: AppTheme.orange),
          const SizedBox(width: 6),
          Text('目标读取失败',
              style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          TextButton(
            onPressed: _loading ? null : _load,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(_loading ? '读取中' : '重试',
                style: TextStyle(fontSize: 11, color: AppTheme.blue)),
          ),
        ]),
      );

  Widget _refreshFailure() => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          Text('刷新失败', style: TextStyle(fontSize: 10, color: AppTheme.orange)),
          TextButton(
            onPressed: _loading ? null : _load,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              minimumSize: const Size(0, 24),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text('重试',
                style: TextStyle(fontSize: 10, color: AppTheme.blue)),
          ),
        ]),
      );
}
