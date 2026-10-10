// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ssh_connection.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class SshConnectionAdapter extends TypeAdapter<SshConnection> {
  @override
  final int typeId = 0;

  @override
  SshConnection read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return SshConnection(
      id: fields[0] as String,
      name: fields[1] as String,
      host: fields[2] as String,
      port: fields[3] as int,
      username: fields[4] as String,
      password: fields[5] as String?,
      privateKeyPath: fields[6] as String?,
      passphrase: fields[7] as String?,
      createdAt: fields[8] as DateTime,
      updatedAt: fields[9] as DateTime,
      terminalColor: fields[10] as int?,
      useTmux: fields[11] == null ? false : fields[11] as bool,
      useP2p: fields[12] == null ? false : fields[12] as bool,
      p2pOptions: (fields[13] as Map?)?.cast<String, dynamic>(),
    );
  }

  @override
  void write(BinaryWriter writer, SshConnection obj) {
    writer
      ..writeByte(14)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.host)
      ..writeByte(3)
      ..write(obj.port)
      ..writeByte(4)
      ..write(obj.username)
      ..writeByte(5)
      ..write(obj.password)
      ..writeByte(6)
      ..write(obj.privateKeyPath)
      ..writeByte(7)
      ..write(obj.passphrase)
      ..writeByte(8)
      ..write(obj.createdAt)
      ..writeByte(9)
      ..write(obj.updatedAt)
      ..writeByte(10)
      ..write(obj.terminalColor)
      ..writeByte(11)
      ..write(obj.useTmux)
      ..writeByte(12)
      ..write(obj.useP2p)
      ..writeByte(13)
      ..write(obj.p2pOptions);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SshConnectionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
