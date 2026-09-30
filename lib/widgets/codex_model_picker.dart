import 'package:flutter/material.dart';

import '../services/codex_chat_service.dart';

Future<(String, String)?> chooseCodexModel(
    BuildContext context, List<CodexModel> models,
    {String? currentModel, String? currentEffort}) async {
  final model = await showModalBottomSheet<CodexModel>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        const ListTile(title: Text('更改模型'), subtitle: Text('下一轮消息生效，当前任务不受影响')),
        for (final model in models)
          ListTile(
            title: Text(model.name),
            trailing: model.id == currentModel ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(context, model),
          ),
      ]),
    ),
  );
  if (model == null || !context.mounted) return null;
  final efforts = model.efforts.isEmpty
      ? [CodexReasoningEffort(model.defaultEffort, '')]
      : model.efforts;
  final effort = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        ListTile(title: Text('${model.name} · 选择思考级别')),
        for (final effort in efforts)
          ListTile(
            title: Text(effort.id),
            subtitle:
                effort.description.isEmpty ? null : Text(effort.description),
            trailing: effort.id == (currentEffort ?? model.defaultEffort)
                ? const Icon(Icons.check)
                : null,
            onTap: () => Navigator.pop(context, effort.id),
          ),
      ]),
    ),
  );
  return effort == null ? null : (model.id, effort);
}
