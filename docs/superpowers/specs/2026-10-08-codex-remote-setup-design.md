# 官方 Codex 远端环境准备

用户已确认实现：Linux SSH 远端只有官方 Codex 时，软件检查依赖并提供手动一键准备，默认文字聊天；保留既有共享 daemon、断线跟随、消息去重和状态修复。

## 使用流程

连接 Codex 时检查环境。就绪则进入原对话入口，否则展示环境准备页面。页面明确列出 Codex、登录、Python 3、tmux、共享服务准备状态。缺失系统依赖通过用户确认的交互终端安装；认证通过远端官方登录，不复制本机凭据。版本不兼容时独立展示更新命令，不自动更新。Claude 入口不受影响。

## 运行机制

辅助脚本部署到 ~/.ssh_tool/，原子替换、用户权限目录，重复准备不重复创建服务。检测官方 daemon start、proxy、--remote 的实际能力。通过原生 daemon start 获得 socketPath，并完成 initialize/model/list 验证后标记准备成功。已安装 codex-auth 时兼容其账户环境；否则直接运行 codex。不要求 yolo profile，不修改 .bashrc。

准备后的聊天 worker 使用同一 daemon 的 stdio proxy，保持现有后台 tmux、请求文件、jobId 去重、排队、断线跟随。终端启动脚本使用同一 socket 和 --remote，转发 resume/fork 参数。自定义终端命令优先。既有未准备环境保留旧运行方式，避免破坏现有会话。

共享服务连接和查询使用记录的实际 socket 地址，保留缺省控制 socket 的兼容查询。关闭应用自有空闲会话只取消自身订阅，不停止共享 daemon。运行中不可自动恢复成第二个写入实例。

普通新连接的终端默认是 codex。准备后的文字聊天沿用远端配置，不强制 yolo 或关闭 sandbox。审批请求提供手机处理入口；不支持的交互明确提示，不静默等待。已运行的旧 worker 不强制替换或重启。

## 验证

窄范围 Python 集成测试、Flutter 服务/组件测试覆盖：检测缺失/能力不足/未登录，prepare 原子部署和幂等，daemon/proxy/socket 路由，无 codex-auth/profile 的官方运行路径，审批处理，多轮、断线跟随、去重、关闭、状态回归。隔离 HOME/CODEX_HOME 的真实 Codex 验证服务和协议初始化，不使用真实账号或付费任务。构建 Android APK；无实机 UI 或截图检查授权，不启动实机检查。
