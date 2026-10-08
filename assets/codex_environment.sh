#!/bin/sh
# Read-only checks; never install, log in, or start a daemon.
set -u
field() {
  printf '%s\t' "$1"
  printf '%s' "$2" | base64 | tr -d '\n'
  printf '\n'
}
system=$(uname -s)
field system "$system"
python_available=false
if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; assert sys.version_info >= (3, 9)' >/dev/null 2>&1; then
  python_available=true
fi
field python "$python_available"
if command -v tmux >/dev/null 2>&1; then field tmux true; else field tmux false; fi
codex_path=$(command -v codex 2>/dev/null || true)
path_codex=$codex_path
auth_path=''
if [ -x "$HOME/.local/bin/codex-auth" ]; then auth_path="$HOME/.local/bin/codex-auth"; fi
# Non-interactive SSH may not load nvm's PATH. Prefer capable installed binaries.
base_path=$PATH
first_socket=''
first_capable=''
selected=''
for candidate in "$HOME/.local/bin/codex" "$codex_path" "$HOME"/.config/nvm/versions/node/*/bin/codex "$HOME"/.nvm/versions/node/*/bin/codex; do
  [ -n "$candidate" ] && [ -x "$candidate" ] || continue
  candidate_path="$(dirname "$candidate"):$base_path"
  candidate_help=$(PATH="$candidate_path" "$candidate" app-server daemon start --help 2>/dev/null || true)
  server_help=$(PATH="$candidate_path" "$candidate" app-server --help 2>/dev/null || true)
  main_help=$(PATH="$candidate_path" "$candidate" --help 2>/dev/null || true)
  if { printf '%s' "$candidate_help" | grep -q 'daemon start' ||
       { printf '%s' "$server_help" | grep -q -- '--listen' && printf '%s' "$server_help" | grep -q 'unix://'; }; }; then
    if [ -z "$first_socket" ]; then first_socket=$candidate; fi
    if printf '%s' "$main_help" | grep -q -- '--remote'; then
      if [ -z "$first_capable" ]; then first_capable=$candidate; fi
      if [ -n "$auth_path" ]; then
        if PATH="$candidate_path" CODEX_AUTH_CODEX_BIN="$candidate" "$auth_path" run -- login status >/dev/null 2>&1; then
          selected=$candidate
          break
        fi
      elif PATH="$candidate_path" "$candidate" login status >/dev/null 2>&1; then
        selected=$candidate
        break
      fi
    fi
  fi
done
if [ -n "$selected" ]; then
  codex_path=$selected
elif [ -n "$first_capable" ]; then
  codex_path=$first_capable
elif [ -n "$first_socket" ]; then
  codex_path=$first_socket
elif [ -n "$path_codex" ]; then
  codex_path=$path_codex
else
  codex_path=''
fi
field codexPath "$codex_path"
field authPath "$auth_path"
version=''
compatible=false
logged_in=false
if [ -n "$codex_path" ]; then
  PATH="$(dirname "$codex_path"):$base_path"; export PATH
  version=$("$codex_path" --version 2>/dev/null | head -n 1)
  daemon_help=$("$codex_path" app-server daemon start --help 2>/dev/null || true)
  main_help=$("$codex_path" --help 2>/dev/null || true)
  server_help=$("$codex_path" app-server --help 2>/dev/null || true)
  if { printf '%s' "$daemon_help" | grep -q 'daemon start' ||
       { printf '%s' "$server_help" | grep -q -- '--listen' && printf '%s' "$server_help" | grep -q 'unix://'; }; } &&
     printf '%s' "$main_help" | grep -q -- '--remote'; then
    compatible=true
  fi
  if [ -x "$HOME/.local/bin/codex-auth" ]; then
    if CODEX_AUTH_CODEX_BIN="$codex_path" "$HOME/.local/bin/codex-auth" run -- login status >/dev/null 2>&1; then logged_in=true; fi
  elif "$codex_path" login status >/dev/null 2>&1; then logged_in=true; fi
fi
field version "$version"
field compatible "$compatible"
field loggedIn "$logged_in"
prepared=false
detail=''
if [ "$python_available" = true ] && [ -f "$HOME/.ssh_tool/codex_runtime.py" ]; then
  if check_result=$(python3 "$HOME/.ssh_tool/codex_runtime.py" check 2>/dev/null) &&
     printf '%s' "$check_result" | grep -q '"setupVersion": 4'; then prepared=true; fi
fi
field prepared "$prepared"
if [ -x "$HOME/.local/bin/codex-phone" ]; then field shortcut true; else field shortcut false; fi
if [ "$system" != Linux ]; then detail='首版环境准备仅支持 Linux 远端';
elif [ -z "$codex_path" ]; then detail='未找到 Codex，请先在远端安装官方 Codex';
elif [ "$compatible" != true ]; then detail='当前 Codex 缺少共享 Unix socket 服务或 --remote 能力，请更新后重新检测';
elif [ "$logged_in" != true ]; then detail='需要登录远端 Codex';
elif [ "$python_available" != true ]; then detail='需要 Python 3.9 或更新版本';
elif [ "$prepared" != true ]; then detail='依赖就绪后点击一键准备，验证共享会话服务';
else detail='共享会话服务已就绪'; fi
field detail "$detail"
