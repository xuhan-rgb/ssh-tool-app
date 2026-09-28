import 'package:hive/hive.dart';

part 'command_record.g.dart';

@HiveType(typeId: 1)
class CommandRecord extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String connectionId;

  @HiveField(2)
  String command;

  @HiveField(3)
  String output;

  @HiveField(4)
  DateTime executedAt;

  @HiveField(5)
  int exitCode;

  @HiveField(6)
  bool isError;

  CommandRecord({
    required this.id,
    required this.connectionId,
    required this.command,
    required this.output,
    required this.executedAt,
    this.exitCode = 0,
    this.isError = false,
  });

  // 工厂方法：创建命令记录
  factory CommandRecord.create({
    required String connectionId,
    required String command,
    required String output,
    int exitCode = 0,
  }) {
    return CommandRecord(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      connectionId: connectionId,
      command: command,
      output: output,
      executedAt: DateTime.now(),
      exitCode: exitCode,
      isError: exitCode != 0,
    );
  }

  // 获取格式化的输出文本
  String get formattedOutput {
    if (output.trim().isEmpty) {
      return '(无输出)';
    }
    return output;
  }

  // 获取命令提示符格式
  String get promptFormat => '\$ $command';
}
