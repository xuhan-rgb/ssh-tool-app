class CodexGoal {
  final String objective;
  final String status;
  final int? tokenBudget;
  final int tokensUsed;
  final int timeUsedSeconds;

  const CodexGoal({
    required this.objective,
    required this.status,
    this.tokenBudget,
    this.tokensUsed = 0,
    this.timeUsedSeconds = 0,
  });

  factory CodexGoal.fromJson(Map<String, dynamic> json) => CodexGoal(
        objective: json['objective'] as String,
        status: json['status'] as String,
        tokenBudget: (json['tokenBudget'] as num?)?.toInt(),
        tokensUsed: (json['tokensUsed'] as num?)?.toInt() ?? 0,
        timeUsedSeconds: (json['timeUsedSeconds'] as num?)?.toInt() ?? 0,
      );
}
