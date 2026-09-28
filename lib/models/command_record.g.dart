// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'command_record.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CommandRecordAdapter extends TypeAdapter<CommandRecord> {
  @override
  final int typeId = 1;

  @override
  CommandRecord read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CommandRecord(
      id: fields[0] as String,
      connectionId: fields[1] as String,
      command: fields[2] as String,
      output: fields[3] as String,
      executedAt: fields[4] as DateTime,
      exitCode: fields[5] as int,
      isError: fields[6] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, CommandRecord obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.connectionId)
      ..writeByte(2)
      ..write(obj.command)
      ..writeByte(3)
      ..write(obj.output)
      ..writeByte(4)
      ..write(obj.executedAt)
      ..writeByte(5)
      ..write(obj.exitCode)
      ..writeByte(6)
      ..write(obj.isError);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CommandRecordAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
