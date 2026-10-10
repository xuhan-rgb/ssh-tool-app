import 'package:hive/hive.dart';

part 'ssh_connection.g.dart';

@HiveType(typeId: 0)
class SshConnection extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String name;

  @HiveField(2)
  String host;

  @HiveField(3)
  int port;

  @HiveField(4)
  String username;

  @HiveField(5)
  String? password;

  @HiveField(6)
  String? privateKeyPath;

  @HiveField(7)
  String? passphrase;

  @HiveField(8)
  DateTime createdAt;

  @HiveField(9)
  DateTime updatedAt;

  @HiveField(10)
  int? terminalColor;

  @HiveField(11, defaultValue: false)
  bool useTmux;

  @HiveField(12, defaultValue: false)
  bool useP2p;

  @HiveField(13)
  Map<String, dynamic>? p2pOptions;

  SshConnection({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    this.password,
    this.privateKeyPath,
    this.passphrase,
    required this.createdAt,
    required this.updatedAt,
    this.terminalColor,
    this.useTmux = false,
    this.useP2p = false,
    this.p2pOptions,
  });

  // 工厂方法：创建新连接
  factory SshConnection.create({
    required String name,
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKeyPath,
    String? passphrase,
    int? terminalColor,
    bool useTmux = false,
    bool useP2p = false,
    Map<String, dynamic>? p2pOptions,
  }) {
    final now = DateTime.now();
    return SshConnection(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      host: host,
      port: port,
      username: username,
      password: password,
      privateKeyPath: privateKeyPath,
      passphrase: passphrase,
      createdAt: now,
      updatedAt: now,
      terminalColor: terminalColor,
      useTmux: useTmux,
      useP2p: useP2p,
      p2pOptions: p2pOptions,
    );
  }

  // 复制并更新
  SshConnection copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    String? password,
    String? privateKeyPath,
    String? passphrase,
    int? terminalColor,
    bool? useTmux,
    bool? useP2p,
    Map<String, dynamic>? p2pOptions,
  }) {
    return SshConnection(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
      privateKeyPath: privateKeyPath ?? this.privateKeyPath,
      passphrase: passphrase ?? this.passphrase,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      terminalColor: terminalColor ?? this.terminalColor,
      useTmux: useTmux ?? this.useTmux,
      useP2p: useP2p ?? this.useP2p,
      p2pOptions: p2pOptions ?? this.p2pOptions,
    );
  }

  // 是否使用密钥认证
  bool get usePrivateKey => privateKeyPath != null && privateKeyPath!.isNotEmpty;

  // 连接字符串
  String get connectionString => '$username@$host:$port';

}
