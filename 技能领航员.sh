#!/opt/homebrew/bin/bash

set -euo pipefail

reload_shell_env() {
  export PATH="$HOME/.local/bin:$PATH"
  case "$(uname -s 2>/dev/null || true)" in
    Darwin) export PNPM_HOME="${PNPM_HOME:-$HOME/Library/pnpm}" ;;
    *) export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}" ;;
  esac
  export PATH="$PNPM_HOME:$PATH"

  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  hash -r 2>/dev/null || true
}

reload_shell_env

# 加载由 install.sh 写入的内部 profile（为全新安装提供兜底）
# shellcheck source=/dev/null
[ -f "$HOME/.skillpilot/.profile" ] && source "$HOME/.skillpilot/.profile" || true
reload_shell_env

if ! command -v tmux >/dev/null 2>&1; then
  printf '\n\033[1m============================================================\033[0m\n'
  printf '\033[1m  错误：需要 tmux，但当前未找到\033[0m\n'
  printf '\033[1m============================================================\033[0m\n\n'
  printf 'tmux 是 Skill Pilot 运行后台\n'
  printf '会话并与 AI 共享终端所必需的。\n\n'
  printf '若要修复此问题，请重新运行安装器：\n'
  printf '  bash install.sh\n\n'
  printf '  或者\n\n'
  printf '  brew install tmux   # 然后重新运行 ./skillpilot.sh\n\n'
  printf '或者前往以下地址提交 issue：\n'
  printf '  https://github.com/x-school-academy/skill-pilot\n\n'
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ENV_FILE="${ROOT_DIR}/config/.env"
ACTION="start"
ACTION_TARGET=""
TEST_FILES=()
IS_DEV=0
AVAILABLE_PROVIDERS=()
HUMAN_DETECTION_REQUIREMENTS="${ROOT_DIR}/core/engine/mcp_servers/cameras/requirements-human-detection.txt"
LIVE_TTS_REQUIREMENTS="${ROOT_DIR}/core/engine/mcp_servers/live_tts/requirements-live-tts.txt"

print_help() {
  cat <<'EOF_HELP'
用法：./skillpilot.sh [help|build|start|stop|test] [--dev]
       ./skillpilot.sh <enable|disable> <human-detection|live-tts>
       ./skillpilot.sh test '[test_file[func1,func2]' | test_file:func1,func2 | test_file::func1 ...]

命令：
  help    显示此帮助信息。
  build   构建静态 WebUI 导出文件（core/webui/www）。
  start   启动服务。默认命令。
  stop    停止正在运行的 tmux 会话。使用 `--dev` 仅停止开发环境会话。
  test    运行 engine 的 pytest 测试套件，或仅运行 core/engine/tests 下指定的文件。
  enable human-detection    安装可选的人体检测依赖。
  disable human-detection   卸载可选的人体检测依赖。
  enable live-tts           安装可选的 live-tts 依赖。
  disable live-tts          卸载可选的 live-tts 依赖。

选项：
  --dev   对 `start` 使用开发模式，或对 `stop` 仅停止开发环境会话。

默认值：
  - 默认命令：start
  - 默认模式：production（不带 --dev）
  - 测试文件名可以省略 `.py`，也可以省略 `test_` 前缀，并可用空格或逗号分隔传入
  - 测试选择器支持按文件范围筛选函数："media_mcp[text_to_image,text_to_song]"
  - 同时支持对 zsh 更安全的写法："media_mcp:text_to_image,text_to_song" 或 "media_mcp::text_to_image"
  - 空方括号表示该文件中的全部测试："media_mcp[]"
EOF_HELP
}

append_test_specs_from_arg() {
  local input="$1"
  local char current="" depth=0 i

  for ((i = 0; i < ${#input}; i++)); do
    char="${input:i:1}"
    case "${char}" in
      '[')
        depth=$((depth + 1))
        current+="${char}"
        ;;
      ']')
        if ((depth > 0)); then
          depth=$((depth - 1))
        fi
        current+="${char}"
        ;;
      ',')
        if ((depth == 0)); then
          current="${current#"${current%%[![:space:]]*}"}"
          current="${current%"${current##*[![:space:]]}"}"
          [[ -n "${current}" ]] && TEST_FILES+=("${current}")
          current=""
        else
          current+="${char}"
        fi
        ;;
      *)
        current+="${char}"
        ;;
    esac
  done

  current="${current#"${current%%[![:space:]]*}"}"
  current="${current%"${current##*[![:space:]]}"}"
  [[ -n "${current}" ]] && TEST_FILES+=("${current}")
}

parse_args() {
  local action_set=0
  local expect_test_files=0
  while (($# > 0)); do
    case "$1" in
      --dev)
        IS_DEV=1
        ;;
      help|-h|--help|build|start|stop|test|enable|disable)
        if ((action_set == 1)); then
          echo "错误：提供了多个命令。"
          print_help
          exit 1
        fi
        ACTION="$1"
        action_set=1
        if [[ "${ACTION}" == "test" ]]; then
          expect_test_files=1
        else
          expect_test_files=0
        fi
        ;;
      human-detection|live-tts)
        if [[ "${ACTION}" != "enable" && "${ACTION}" != "disable" ]]; then
          echo "错误：目标 '$1' 需要搭配 enable/disable 命令使用。"
          print_help
          exit 1
        fi
        if [[ -n "${ACTION_TARGET}" ]]; then
          echo "错误：提供了多个目标。"
          print_help
          exit 1
        fi
        ACTION_TARGET="$1"
        ;;
      *)
        if ((expect_test_files == 1)); then
          append_test_specs_from_arg "$1"
          shift
          continue
        fi
        echo "错误：未知参数 '$1'。"
        print_help
        exit 1
        ;;
    esac
    shift
  done

  if ((IS_DEV == 1)) && [[ "${ACTION}" != "start" && "${ACTION}" != "stop" ]]; then
    echo "错误：--dev 仅支持与 'start' 或 'stop' 一起使用。"
    print_help
    exit 1
  fi

  if [[ "${ACTION}" == "enable" || "${ACTION}" == "disable" ]]; then
    if [[ -z "${ACTION_TARGET}" ]]; then
      echo "错误：'${ACTION}' 需要一个目标。支持的目标：human-detection、live-tts。"
      print_help
      exit 1
    fi
    if [[ "${ACTION_TARGET}" != "human-detection" && "${ACTION_TARGET}" != "live-tts" ]]; then
      echo "错误：不支持的目标 '${ACTION_TARGET}'。支持的目标：human-detection、live-tts。"
      print_help
      exit 1
    fi
  elif [[ -n "${ACTION_TARGET}" ]]; then
    echo "错误：目标 '${ACTION_TARGET}' 仅在 enable/disable 命令下有效。"
    print_help
    exit 1
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "错误：需要 ${cmd}。"
    exit 1
  fi
}

ensure_webui_deps() {
  require_cmd pnpm
  if [[ ! -d "${ROOT_DIR}/core/webui/node_modules" ]]; then
    echo "缺少 core/webui/node_modules，正在运行 pnpm install..."
    pnpm -C "${ROOT_DIR}/core/webui" install
  fi
}

ensure_engine_venv() {
  require_cmd uv
  if [[ ! -d "${ROOT_DIR}/core/engine/.venv" ]]; then
    echo "缺少 core/engine/.venv，正在运行 uv --directory core/engine sync..."
    if ! uv --directory "${ROOT_DIR}/core/engine" sync; then
      echo "错误：uv sync 失败。"
      echo "安装依赖后，请运行："
      echo "  uv --directory ${ROOT_DIR}/core/engine sync"
      exit 1
    fi
  fi
}

engine_venv_python() {
  local py="${ROOT_DIR}/core/engine/.venv/bin/python"
  ensure_engine_venv
  if [[ ! -x "${py}" ]]; then
    echo "错误：缺少位于 ${ROOT_DIR}/core/engine/.venv 的 engine 虚拟环境。"
    echo "运行：uv --directory ${ROOT_DIR}/core/engine sync"
    exit 1
  fi
  echo "${py}"
}

install_human_detection_deps() {
  local py
  ensure_engine_venv
  py="$(engine_venv_python)"
  if [[ ! -f "${HUMAN_DETECTION_REQUIREMENTS}" ]]; then
    echo "错误：缺少 ${HUMAN_DETECTION_REQUIREMENTS}。"
    exit 1
  fi
  echo "正在安装可选的人体检测依赖..."
  uv --directory "${ROOT_DIR}/core/engine" pip install --python "${py}" -r "${HUMAN_DETECTION_REQUIREMENTS}"
  echo "人体检测依赖已安装。"
}

uninstall_human_detection_deps() {
  local py
  require_cmd uv
  py="$(engine_venv_python)"
  echo "正在卸载可选的人体检测依赖..."
  uv --directory "${ROOT_DIR}/core/engine" pip uninstall --python "${py}" ultralytics ultralytics-thop torch torchvision
  echo "人体检测依赖已移除。"
}

install_live_tts_build_deps() {
  local os_name
  os_name="$(uname -s 2>/dev/null || true)"

  case "${os_name}" in
    Darwin)
      require_cmd brew
      echo "正在安装 macOS 音频构建依赖（portaudio、pkg-config）..."
      brew install portaudio pkg-config
      ;;
    Linux)
      local use_sudo=0
      if [[ "$(id -u)" -ne 0 ]]; then
        require_cmd sudo
        use_sudo=1
      fi

      if command -v apt-get >/dev/null 2>&1; then
        echo "正在安装 Linux 音频构建依赖（portaudio19-dev、pkg-config）..."
        if ((use_sudo == 1)); then
          sudo apt-get update
          sudo apt-get install -y portaudio19-dev pkg-config
        else
          apt-get update
          apt-get install -y portaudio19-dev pkg-config
        fi
      elif command -v dnf >/dev/null 2>&1; then
        echo "正在安装 Linux 音频构建依赖（portaudio-devel、pkgconf-pkg-config）..."
        if ((use_sudo == 1)); then
          sudo dnf install -y portaudio-devel pkgconf-pkg-config
        else
          dnf install -y portaudio-devel pkgconf-pkg-config
        fi
      else
        echo "错误：不支持的 Linux 包管理器。"
        echo "请先手动安装 PortAudio 开发头文件，然后重试。"
        exit 1
      fi
      ;;
    *)
      echo "错误：live-tts enable 仅支持 macOS 和 Linux。"
      exit 1
      ;;
  esac
}

install_live_tts_deps() {
  local py
  ensure_engine_venv
  py="$(engine_venv_python)"
  if [[ ! -f "${LIVE_TTS_REQUIREMENTS}" ]]; then
    echo "错误：缺少 ${LIVE_TTS_REQUIREMENTS}。"
    exit 1
  fi
  install_live_tts_build_deps
  echo "正在安装可选的 live-tts 依赖..."
  uv --directory "${ROOT_DIR}/core/engine" pip install --python "${py}" -r "${LIVE_TTS_REQUIREMENTS}"
  echo "live-tts 依赖已安装。"
}

uninstall_live_tts_deps() {
  local py
  require_cmd uv
  py="$(engine_venv_python)"
  echo "正在卸载可选的 live-tts 依赖..."
  uv --directory "${ROOT_DIR}/core/engine" pip uninstall --python "${py}" pyaudio
  echo "live-tts 依赖已移除。"
}

engine_python() {
  local py="${ROOT_DIR}/core/engine/.venv/bin/python"
  if [[ -x "${py}" ]]; then
    echo "${py}"
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    echo "python3"
    return
  fi
  echo "错误：需要 python3。" >&2
  exit 1
}

press_any_key() {
  local msg="${1:-按任意键继续，或按 Ctrl-C 退出。}"
  printf '\033[1m%s\033[0m ' "$msg"
  local input_fd="/dev/tty"
  { true </dev/tty; } 2>/dev/null || input_fd="/dev/stdin"
  read -r -s -n 1 <"$input_fd" || true
  printf '\n'
}

show_screen() {
  printf '\n\033[1m============================================================\033[0m\n'
  printf '\033[1m  %s\033[0m\n' "$1"
  printf '\033[1m============================================================\033[0m\n\n'
}

install_free_cli_tools() {
  # 接收要安装的 agent 名称列表：claude、copilot、gemini、codex、opencode
  local agents_to_install=("$@")
  local -A pkg_map=(
    [copilot]="@github/copilot"
    [gemini]="@google/gemini-cli"
    [codex]="@openai/codex"
    [opencode]="opencode-ai"
  )
  for agent in "${agents_to_install[@]}"; do
    if [[ "${agent}" == "claude" ]]; then
      if ! command -v curl >/dev/null 2>&1; then
        echo "未找到 curl —— 无法自动安装 Claude Code。"
        continue
      fi
      echo "正在安装 Claude Code..."
      curl -fsSL https://claude.ai/install.sh | bash || echo "Claude 安装器执行失败。"
      continue
    fi
    local pkg="${pkg_map[$agent]:-}"
    if [[ -z "$pkg" ]]; then
      echo "未知的 agent：$agent —— 已跳过。"
      continue
    fi
    if ! command -v pnpm >/dev/null 2>&1; then
      echo "未找到 pnpm —— 无法自动安装 ${pkg}。"
      continue
    fi
    echo "正在安装 ${pkg}..."
    pnpm install -g "${pkg}" || echo "${pkg} 安装失败。"
  done
}

ask_yes_no() {
  local prompt="$1"
  local default_no="${2:-1}"
  local answer=""
  while true; do
    if [[ "${default_no}" == "0" ]]; then
      read -r -p "${prompt} [Y/n]: " answer
      answer="${answer:-y}"
    else
      read -r -p "${prompt} [y/N]: " answer
      answer="${answer:-n}"
    fi
    case "${answer}" in
      y|Y|yes|YES|Yes)
        return 0
        ;;
      n|N|no|NO|No)
        return 1
        ;;
      *)
        echo "请输入 y 或 n。"
        ;;
    esac
  done
}

port_available() {
  local host="$1"
  local port="$2"
  local py
  py="$(engine_python)"
  "${py}" - "$host" "$port" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    sock.bind((host, port))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
raise SystemExit(0)
PY
}

pick_port() {
  local label="$1"
  local host="$2"
  local suggested="$3"
  local blocked_port="${4:-}"
  local chosen=""

  while true; do
    read -r -p "${label} port [${suggested}]: " chosen
    chosen="${chosen:-${suggested}}"

    if [[ ! "${chosen}" =~ ^[0-9]+$ ]] || ((chosen < 1 || chosen > 65535)); then
      echo "Invalid port '${chosen}'. Enter a number between 1 and 65535." >&2
      continue
    fi

    if [[ -n "${blocked_port}" && "${chosen}" == "${blocked_port}" ]]; then
      echo "Port ${chosen} is already used by another Skill Pilot service." >&2
      continue
    fi

    if port_available "${host}" "${chosen}"; then
      echo "${chosen}"
      return
    fi

    echo "Port ${chosen} is not available on ${host}." >&2
  done
}

generate_uuid() {
  local py
  py="$(engine_python)"
  "${py}" - <<'PY'
import uuid
print(uuid.uuid4())
PY
}

choose_provider() {
  local choice=""
  local i=1

  echo "检测到以下可用的 CLI 提供方："
  for provider in "${AVAILABLE_PROVIDERS[@]}"; do
    echo "  ${i}. ${provider}"
    ((i += 1))
  done

  while true; do
    read -r -p "选择默认 LLM 提供方 [1]：" choice
    choice="${choice:-1}"
    if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#AVAILABLE_PROVIDERS[@]})); then
      echo "${AVAILABLE_PROVIDERS[$((choice - 1))]}"
      return
    fi
    echo "无效选择。请输入 1 到 ${#AVAILABLE_PROVIDERS[@]} 之间的数字。"
  done
}

update_settings_json5() {
  local host="$1"
  local prod_engine_port="$2"
  local dev_engine_port="$3"
  local dev_webui_port="$4"
  local py
  py="$(engine_python)"

  "${py}" - "${ROOT_DIR}/config/settings.json5" "${host}" "${prod_engine_port}" "${dev_engine_port}" "${dev_webui_port}" <<'PY'
import json
import sys
from pathlib import Path

import json5

settings_path = Path(sys.argv[1])
host = sys.argv[2]
prod_engine_port = int(sys.argv[3])
dev_engine_port = int(sys.argv[4])
dev_webui_port = int(sys.argv[5])

if settings_path.is_file():
    data = json5.loads(settings_path.read_text(encoding="utf-8"))
else:
    data = {}

if not isinstance(data, dict):
    data = {}

services = data.setdefault("services", {})
if not isinstance(services, dict):
    services = {}
    data["services"] = services

webui = services.setdefault("webui", {})
if not isinstance(webui, dict):
    webui = {}
    services["webui"] = webui
webui["host"] = host
webui_dev = webui.setdefault("development", {})
if not isinstance(webui_dev, dict):
    webui_dev = {}
    webui["development"] = webui_dev
webui_dev["port"] = dev_webui_port

engine = services.setdefault("engine", {})
if not isinstance(engine, dict):
    engine = {}
    services["engine"] = engine
engine["host"] = host
engine_prod = engine.setdefault("production", {})
if not isinstance(engine_prod, dict):
    engine_prod = {}
    engine["production"] = engine_prod
engine_prod["port"] = prod_engine_port
engine_dev = engine.setdefault("development", {})
if not isinstance(engine_dev, dict):
    engine_dev = {}
    engine["development"] = engine_dev
engine_dev["port"] = dev_engine_port

settings_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

update_ai_providers_json5() {
  local provider_id="$1"
  shift
  local installed_providers=("$@")
  local py
  py="$(engine_python)"

  "${py}" - "${ROOT_DIR}/config/ai_providers.json5" "${provider_id}" "${installed_providers[@]}" <<'PY'
import json
import sys
from pathlib import Path

import json5

providers_path = Path(sys.argv[1])
default_provider = sys.argv[2]
installed_providers = set(sys.argv[3:])

data = json5.loads(providers_path.read_text(encoding="utf-8"))
if not isinstance(data, dict):
    raise SystemExit("ai_providers.json5 格式无效")

defaults = data.setdefault("default", {})
if not isinstance(defaults, dict):
    defaults = {}
    data["default"] = defaults
defaults["llm"] = default_provider

llm = data.get("llm", [])
if isinstance(llm, list):
    for item in llm:
        if not isinstance(item, dict):
            continue
        item_id = str(item.get("id") or "").strip()
        if not item_id:
            continue
        # 已安装的提供方设置 disabled=False，缺失的设置 disabled=True
        item["disabled"] = item_id not in installed_providers

providers_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

write_engine_env() {
  local only_allow_https="$1"
  local auth_token="$2"
  local api_type="$3"
  local api_url="$4"
  local api_key="$5"

  {
    echo "ONLY_ALLOW_HTTPS=${only_allow_https}"
    echo "AUTH_TOKEN=${auth_token}"
    case "${api_type}" in
      anthropic)
        echo "ANTHROPIC_BASE_URL=${api_url}"
        echo "ANTHROPIC_AUTH_TOKEN=${api_key}"
        echo "ANTHROPIC_API_KEY="
        ;;
      openai)
        echo "OPENAI_BASE_URL=${api_url}"
        echo "OPENAI_API_KEY=${api_key}"
        ;;
      *)
        ;;
    esac
  } > "${ENGINE_ENV_FILE}"

  chmod 600 "${ENGINE_ENV_FILE}" 2>/dev/null || true
}

detect_available_providers() {
  AVAILABLE_PROVIDERS=()

  if command -v claude >/dev/null 2>&1; then
    AVAILABLE_PROVIDERS+=("claude")
  fi
  if command -v copilot >/dev/null 2>&1; then
    AVAILABLE_PROVIDERS+=("copilot")
  fi
  if command -v codex >/dev/null 2>&1; then
    AVAILABLE_PROVIDERS+=("codex")
  fi
  if command -v gemini >/dev/null 2>&1; then
    AVAILABLE_PROVIDERS+=("gemini")
  fi
  if command -v opencode >/dev/null 2>&1; then
    AVAILABLE_PROVIDERS+=("opencode")
  fi
}

maybe_install_cli_tools() {
  local installed_any=1

  if ask_yes_no "Install Claude Code CLI now with: curl -fsSL https://claude.ai/install.sh | bash?" 1; then
    if curl -fsSL https://claude.ai/install.sh | bash; then
      installed_any=0
    else
      echo "Claude installer failed."
    fi
  fi

  if command -v pnpm >/dev/null 2>&1; then
    if ask_yes_no "Install GitHub Copilot CLI now with: pnpm install -g @github/copilot?" 1; then
      if pnpm install -g @github/copilot; then
        installed_any=0
      else
        echo "pnpm install -g @github/copilot failed."
      fi
    fi

    if ask_yes_no "Install OpenAI Codex CLI now with: pnpm install -g @openai/codex?" 1; then
      if pnpm install -g @openai/codex; then
        installed_any=0
      else
        echo "pnpm install -g @openai/codex failed."
      fi
    fi
  else
    echo "当前没有 pnpm，跳过基于 pnpm 的 CLI 安装。"
  fi

  return "${installed_any}"
}

run_init_wizard_if_needed() {
  if [[ -f "${ENGINE_ENV_FILE}" ]]; then
    return
  fi

  # 向导第 2 屏 —— 介绍
  show_screen "Skill Pilot 首次设置"
  echo "欢迎！这个向导会带你完成几个设置步骤，"
  echo "然后 Skill Pilot 才会首次启动。"
  echo ""
  echo "每一步都会简要解释你正在选择什么，"
  echo "以及它为什么重要。"
  press_any_key "按任意键开始。"

  local listen_host only_allow_https
  local prod_engine_port dev_engine_port dev_webui_port
  local provider_id=""
  local webui_auth_token

  # 向导第 3 屏 —— 端口与地址说明
  show_screen "理解端口与地址"
  echo '当你的电脑运行一个 Web 服务时，它会监听一个'
  echo '“端口”——一个带编号的入口，连接会从这里进入。'
  echo ""
  echo "可以把你的电脑想象成一栋楼："
  echo "  IP 地址 = 这栋楼的地址"
  echo "  端口号 = 楼里的具体房间号"
  echo ""
  echo "你在 Skill Pilot 中常用的端口号有："
  echo ""
  echo "  3001  ->  生产环境 engine API 和打包后的发布版 UI"
  echo "  3002  ->  开发环境 engine API"
  echo "  3003  ->  开发环境 WebUI"
  echo ""
  echo "什么是 127.0.0.1？"
  echo '  这叫作“localhost”——它表示你自己的电脑。'
  echo "  当你在浏览器里打开 http://127.0.0.1:3003 时，"
  echo "  你连接的是运行在自己机器上的服务。"
  echo "  互联网上的其他人无法访问它。"
  echo ""
  echo "什么是 0.0.0.0？"
  echo '  这表示“监听所有网络接口”——你的'
  echo "  电脑将接受来自其他设备的连接，"
  echo "  这些设备可能来自你的本地网络（例如手机或另一台笔记本）。"
  press_any_key "按任意键选择你的网络绑定方式。"

  # 向导第 4 屏 —— 选择监听地址
  show_screen "选择 Skill Pilot 的监听位置"
  echo "  1)  127.0.0.1  （localhost —— 仅你的电脑可访问）"
  echo "      最安全的选项。只有你可以访问 Skill Pilot。"
  echo "      适合：单机个人使用。"
  echo ""
  echo "  2)  0.0.0.0    （所有接口 —— 局域网可访问）"
  echo "      你家里或办公室网络中的其他设备也可以"
  echo "      连接到 Skill Pilot。"
  echo "      适合：从手机或平板访问。"
  echo ""
  local host_choice
  while true; do
    read -r -p "请输入你的选择 [1/2]：" host_choice
    case "${host_choice:-1}" in
      1) listen_host="127.0.0.1"; break ;;
      2) listen_host="0.0.0.0";   break ;;
      *) echo "请输入 1 或 2。" ;;
    esac
  done
  only_allow_https=0
  if [[ "${listen_host}" != "127.0.0.1" && "${listen_host}" != "localhost" ]]; then
    # 向导第 4b 屏 —— HTTPS 说明
    show_screen "HTTP 与 HTTPS"
    echo "当一个服务可在你的局域网中访问时（而不仅仅是"
    echo "localhost），最佳实践是对连接进行加密。"
    echo ""
    echo ""
    echo "  HTTP   = 明文 —— 一旦被截获，数据可被直接读取"
    echo "  HTTPS  = 加密 —— 即使在共享网络中也更安全"
    echo ""
    echo "你是否打算只在本地家庭或办公室网络中访问"
    echo "Skill Pilot？"
    echo ""
    echo "  1)  是 —— 仅本地网络（ONLY_ALLOW_HTTPS=0）"
    echo "      可以接受 HTTP。设置更简单。"
    echo ""
    echo "  2)  否 —— 我可能会把它暴露到公网（ONLY_ALLOW_HTTPS=1）"
    echo "      出于安全考虑将强制启用 HTTPS。"
    echo ""
    echo "注意：你之后可以通过编辑以下文件来修改："
    echo "  config/.env  ->  ONLY_ALLOW_HTTPS=0  或  1"
    echo ""
    local https_choice
    while true; do
      read -r -p "请输入你的选择 [1/2]：" https_choice
      case "${https_choice:-1}" in
        1) only_allow_https=0; break ;;
        2) only_allow_https=1; break ;;
        *) echo "请输入 1 或 2。" ;;
      esac
    done
  fi

  # 向导第 4c 屏 —— 选择端口
  show_screen "选择你的端口号"
  echo "Skill Pilot 可以同时运行生产环境和开发环境。"
  echo ""
  echo "请为以下服务选择默认端口："
  echo ""
  echo "  Prod engine  ->  发布版 engine API 和打包后的发布版 UI"
  echo "  Dev engine   ->  用于开发的自动重载 engine API"
  echo "  Dev WebUI    ->  Next.js 开发服务器"
  echo ""
  echo "默认值适用于大多数场景。只有在"
  echo "你的电脑上已有其他程序占用了该端口时，才需要修改。"
  echo ""
  echo "按 Enter 接受默认值，或输入一个端口号（1-65535）。"
  echo ""
  prod_engine_port="$(pick_port "Prod (Engine API)" "${listen_host}" "3001")"
  dev_engine_port="$(pick_port "Dev  (Engine API)" "${listen_host}" "3002" "${prod_engine_port}")"
  dev_webui_port="$(pick_port "Dev  (WebUI)" "${listen_host}" "3003" "${prod_engine_port}")"
  while [[ "${dev_webui_port}" == "${dev_engine_port}" ]]; do
    echo "端口 ${dev_webui_port} 已被另一个 Skill Pilot 服务占用。" >&2
    dev_webui_port="$(pick_port "Dev  (WebUI)" "${listen_host}" "3003" "${prod_engine_port}")"
  done
  echo ""
  echo "  Prod engine: ${prod_engine_port}  ->  http://${listen_host}:${prod_engine_port}"
  echo "  Dev  engine: ${dev_engine_port}  ->  http://${listen_host}:${dev_engine_port}"
  echo "  Dev  WebUI : ${dev_webui_port}  ->  http://${listen_host}:${dev_webui_port}"
  press_any_key

  # 向导第 5 屏 —— AI agent CLI 检测
  show_screen "AI Agent CLI 工具"
  echo "Skill Pilot 可与以下 AI 代码代理 CLI 配合使用："
  echo ""
  echo "  claude    Anthropic 的 Claude Code"
  echo "  copilot   GitHub Copilot CLI"
  echo "  codex     OpenAI Codex CLI"
  echo "  gemini    Google Gemini CLI"
  echo "  opencode  OpenCode（开源，兼容 OpenAI）"
  echo ""
  echo "正在检查你已经安装了哪些工具..."
  echo ""
  detect_available_providers
  local all_agents=("claude" "copilot" "codex" "gemini" "opencode")
  for agent in "${all_agents[@]}"; do
    local found=0
    for p in "${AVAILABLE_PROVIDERS[@]}"; do
      [[ "$p" == "$agent" ]] && found=1 && break
    done
    if ((found)); then
      printf '  \033[0;32m%-10s  ✓ 已安装\033[0m\n' "${agent}"
    else
      printf '  \033[1;33m%-10s  ✗ 未找到\033[0m\n' "${agent}"
    fi
  done
  echo ""

  # 向导第 5b 屏 —— 安装免费 CLI 工具
  local missing_free=()
  for agent in claude copilot gemini codex opencode; do
    local found=0
    for p in "${AVAILABLE_PROVIDERS[@]}"; do
      [[ "$p" == "$agent" ]] && found=1 && break
    done
    ((found)) || missing_free+=("$agent")
  done

  if ((${#missing_free[@]} > 0)); then
    show_screen "安装免费的 AI Agent CLI"
    echo "我们也建议把免费的（开源的）替代方案一起安装。"
    echo ""
    echo "以下工具尚未安装："
    echo ""
    local -A agent_labels=(
      [claude]="Claude Code        —— 提供免费方案"
      [copilot]="GitHub Copilot CLI —— 提供免费方案"
      [gemini]="Google Gemini CLI —— 提供免费层"
      [codex]="OpenAI Codex CLI  —— 提供免费层"
      [opencode]="OpenCode           —— 提供免费层"
    )
    local -A agent_pkgs=(
      [claude]="curl -fsSL https://claude.ai/install.sh | bash"
      [copilot]="@github/copilot"
      [gemini]="@google/gemini-cli"
      [codex]="@openai/codex"
      [opencode]="opencode-ai"
    )
    for agent in claude copilot gemini codex opencode; do
      local is_missing=0
      for m in "${missing_free[@]}"; do
        [[ "$m" == "$agent" ]] && is_missing=1 && break
      done
      if ((is_missing)); then
        printf '  %-10s  %s\n' "${agent}" "${agent_labels[$agent]}"
      else
        printf '  %-10s  （已安装 —— 已跳过）\n' "${agent}"
      fi
    done
    echo ""
    echo "为什么把它们都装上？"
    echo "  不同的 AI 模型各有不同的强项。"
    echo "  全部可用时，你就可以比较结果并选择"
    echo "  每项任务最合适的工具 —— 而且是免费的。"
    echo ""
    echo "按任意键，我将为你安装缺失的那些："
    echo ""
    for agent in "${missing_free[@]}"; do
      if [[ "${agent}" == "claude" ]]; then
        echo "  ${agent_pkgs[$agent]}"
      else
        echo "  pnpm install -g ${agent_pkgs[$agent]}"
      fi
    done
    echo ""
    if ((${#AVAILABLE_PROVIDERS[@]} == 0)); then
      echo "注意：当前没有安装任何 AI agent —— 必须先安装才能继续。"
      press_any_key "按任意键开始安装，或按 Ctrl-C 退出。"
      install_free_cli_tools "${missing_free[@]}"
      detect_available_providers
      if ((${#AVAILABLE_PROVIDERS[@]} == 0)); then
        echo "错误：尝试安装后仍没有可用的 AI agent CLI。"
        echo "请手动安装一个，然后重新运行：./skillpilot.sh"
        exit 1
      fi
    else
      echo "或者按 Ctrl-C 跳过。"
      press_any_key "按任意键开始安装，或按 Ctrl-C 跳过。"
      install_free_cli_tools "${missing_free[@]}" || true
      detect_available_providers
    fi
  fi

  # 向导第 6 屏 —— 选择默认提供方
  if ((${#AVAILABLE_PROVIDERS[@]} == 1)); then
    provider_id="${AVAILABLE_PROVIDERS[0]}"
    echo "将 ${provider_id} 作为默认 AI agent。"
  else
    show_screen "选择你的默认 AI Agent"
    echo "你希望 Skill Pilot 默认使用哪个 AI agent？"
    echo "你之后可以在 config/ai_providers.json5 中修改它。"
    echo ""
    local i=1
    for p in "${AVAILABLE_PROVIDERS[@]}"; do
      echo "  ${i})  ${p}"
      ((i++))
    done
    echo ""
    local provider_choice
    while true; do
      read -r -p "请输入你的选择 [1]：" provider_choice
      provider_choice="${provider_choice:-1}"
      if [[ "${provider_choice}" =~ ^[0-9]+$ ]] && \
         ((provider_choice >= 1 && provider_choice <= ${#AVAILABLE_PROVIDERS[@]})); then
        provider_id="${AVAILABLE_PROVIDERS[$((provider_choice - 1))]}"
        echo "默认 AI agent：${provider_id}"
        break
      fi
      echo "无效选择。请输入 1 到 ${#AVAILABLE_PROVIDERS[@]} 之间的数字。"
    done
  fi

  # 自动生成 auth token（新手无需手动输入）
  webui_auth_token="$(generate_uuid)"

  write_engine_env "${only_allow_https}" "${webui_auth_token}" "none" "" ""
  update_settings_json5 "${listen_host}" "${prod_engine_port}" "${dev_engine_port}" "${dev_webui_port}"
  update_ai_providers_json5 "${provider_id}" "${AVAILABLE_PROVIDERS[@]}"

  # 向导第 7 屏 —— 配置已保存
  show_screen "配置已保存"
  echo "你的设置已经写入以下文件："
  echo "  config/.env"
  echo "  config/settings.json5"
  echo "  config/ai_providers.json5"
  echo ""
  echo "你随时都可以查看并编辑这些文件。"
  press_any_key "按任意键启动 Skill Pilot。"
}

get_service_port() {
  local service_name="$1"
  local mode="$2"
  local py
  py="$(engine_python)"
  "${py}" - "${ROOT_DIR}/config/settings.json5" "${service_name}" "${mode}" "port" <<'PY'
import sys
from pathlib import Path

try:
    import json5
except Exception:
    json5 = None

settings_path = Path(sys.argv[1])
service_name = sys.argv[2]
mode = sys.argv[3]
field_name = sys.argv[4]

default_ports = {
    ("engine", "production"): 3001,
    ("engine", "development"): 3002,
    ("webui", "development"): 3003,
}

default_port = default_ports.get((service_name, mode), 3001)
default_host = "127.0.0.1"

try:
    data = json5.loads(settings_path.read_text(encoding="utf-8")) if json5 else {}
except Exception:
    data = {}

services = data.get("services", {}) if isinstance(data, dict) else {}
service = services.get(service_name, {}) if isinstance(services, dict) else {}
mode_config = service.get(mode, {}) if isinstance(service, dict) else {}

if not isinstance(service, dict):
    service = {}
if not isinstance(mode_config, dict):
    mode_config = {}

if field_name == "host":
    value = mode_config.get(field_name, service.get(field_name, default_host))
else:
    value = mode_config.get(field_name, default_port)
if field_name == "port":
    print(int(value))
else:
    print(str(value))
PY
}

get_service_host() {
  local service_name="$1"
  local mode="$2"
  local py
  py="$(engine_python)"
  "${py}" - "${ROOT_DIR}/config/settings.json5" "${service_name}" "${mode}" "host" <<'PY'
import sys
from pathlib import Path

try:
    import json5
except Exception:
    json5 = None

settings_path = Path(sys.argv[1])
service_name = sys.argv[2]
mode = sys.argv[3]
field_name = sys.argv[4]

default_ports = {
    ("engine", "production"): 3001,
    ("engine", "development"): 3002,
    ("webui", "development"): 3003,
}

default_port = default_ports.get((service_name, mode), 3001)
default_host = "127.0.0.1"

try:
    data = json5.loads(settings_path.read_text(encoding="utf-8")) if json5 else {}
except Exception:
    data = {}

services = data.get("services", {}) if isinstance(data, dict) else {}
service = services.get(service_name, {}) if isinstance(services, dict) else {}
mode_config = service.get(mode, {}) if isinstance(service, dict) else {}

if not isinstance(service, dict):
    service = {}
if not isinstance(mode_config, dict):
    mode_config = {}

if field_name == "host":
    value = mode_config.get(field_name, service.get(field_name, default_host))
else:
    value = mode_config.get(field_name, default_port)
print(str(value))
PY
}

get_service_base_url() {
  local service_name="$1"
  local mode="$2"
  local host port
  host="$(get_service_host "${service_name}" "${mode}")"
  port="$(get_service_port "${service_name}" "${mode}")"
  echo "http://${host}:${port}/"
}

build_webui_export() {
  ensure_webui_deps
  echo "正在构建静态 WebUI 导出文件..."
  pnpm -C "${ROOT_DIR}/core/webui" export
}

run_engine_tests() {
  require_cmd uv

  local tests_dir="${ROOT_DIR}/core/engine/tests"
  local pytest_targets=()
  local spec name path func_spec raw_func normalized_func added_func_target
  local -a funcs

  if [[ ! -d "${tests_dir}" ]]; then
    echo "错误：缺少测试目录 ${tests_dir}。"
    exit 1
  fi

  if ((${#TEST_FILES[@]} == 0)); then
    pytest_targets=("tests")
  else
    for spec in "${TEST_FILES[@]}"; do
      name="${spec}"
      func_spec=""
      if [[ "${spec}" == *'['* ]]; then
        if [[ "${spec}" != *']' ]] || [[ "${spec}" == \[* ]] || [[ "${spec}" == *']'*'['* ]]; then
          echo "错误：无效的测试选择器 '${spec}'。期望格式：file[func1,func2]。"
          exit 1
        fi
        name="${spec%%[*}"
        func_spec="${spec#*[}"
        func_spec="${func_spec%]}"
        if [[ -z "${name}" ]]; then
          echo "错误：无效的测试选择器 '${spec}'。期望格式：file[func1,func2]。"
          exit 1
        fi
      elif [[ "${spec}" == *"::"* ]]; then
        name="${spec%%::*}"
        func_spec="${spec#*::}"
      elif [[ "${spec}" == *":"* ]]; then
        name="${spec%%:*}"
        func_spec="${spec#*:}"
      fi
      if [[ "${name}" == */* ]]; then
        echo "错误：测试文件必须只是 core/engine/tests 下的文件名：'${name}'。"
        exit 1
      fi
      [[ "${name}" == test_* ]] || name="test_${name}"
      [[ "${name}" == *.py ]] || name="${name}.py"
      path="${tests_dir}/${name}"
      if [[ ! -f "${path}" ]]; then
        echo "错误：未找到测试文件：${path}"
        exit 1
      fi
      if [[ -z "${func_spec}" ]]; then
        pytest_targets+=("tests/${name}")
        continue
      fi

      funcs=()
      if [[ -n "${func_spec}" ]]; then
        IFS=',' read -r -a funcs <<< "${func_spec}"
      fi
      if ((${#funcs[@]} == 0)); then
        pytest_targets+=("tests/${name}")
        continue
      fi

      added_func_target=0
      for raw_func in "${funcs[@]}"; do
        raw_func="${raw_func#"${raw_func%%[![:space:]]*}"}"
        raw_func="${raw_func%"${raw_func##*[![:space:]]}"}"
        [[ -n "${raw_func}" ]] || continue
        normalized_func="${raw_func}"
        [[ "${normalized_func}" == test_* ]] || normalized_func="test_${normalized_func}"
        pytest_targets+=("tests/${name}::${normalized_func}")
        added_func_target=1
      done

      if ((added_func_target == 0)); then
        pytest_targets+=("tests/${name}")
      fi
    done
  fi

  echo "正在运行 engine 测试：${pytest_targets[*]}"
  uv --directory "${ROOT_DIR}/core/engine" run pytest -s "${pytest_targets[@]}"
}

ensure_webui_release_assets() {
  local webui_www_dir="${ROOT_DIR}/core/webui/www"
  local webui_index="${webui_www_dir}/index.html"
  if [[ ! -f "${webui_index}" ]]; then
    echo "错误：缺少位于 ${webui_www_dir} 的 WebUI 发布资源。"
    echo "请先运行 './skillpilot.sh build'，或者提交 core/webui/www 以供发布启动使用。"
    exit 1
  fi
}

load_guarded_env() {
  if [[ ! -f "${ENGINE_ENV_FILE}" ]]; then
    return
  fi

  unset SAFE_DOTENV_LOADED_KEYS SAFE_DOTENV_UNSET_KEYS

  local env_content=""
  if [[ -r "${ENGINE_ENV_FILE}" ]]; then
    env_content="$(cat "${ENGINE_ENV_FILE}")"
  else
    echo "正在从 ${ENGINE_ENV_FILE} 加载受保护的环境变量（需要 sudo）..."
    sudo -k
    env_content="$(sudo cat -- "${ENGINE_ENV_FILE}")"
    sudo -k
  fi

  local parser_python
  parser_python="$(engine_python)"

  local loaded_keys=()
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    export "${key}=${value}"
    loaded_keys+=("${key}")
  done < <(printf '%s' "${env_content}" | "${parser_python}" -c '
from io import StringIO
import sys
try:
    from dotenv import dotenv_values
except Exception as exc:
    print(f"错误：解析 .env 需要 python-dotenv（{exc}）", file=sys.stderr)
    raise SystemExit(2)
values = dotenv_values(stream=StringIO(sys.stdin.read()))
for key, value in values.items():
    if isinstance(key, str) and isinstance(value, str):
        sys.stdout.write(key)
        sys.stdout.write("\0")
        sys.stdout.write(value)
        sys.stdout.write("\0")
')

  if ((${#loaded_keys[@]} > 0)); then
    local loaded_key_csv
    loaded_key_csv="$(IFS=,; echo "${loaded_keys[*]}")"
    export SAFE_DOTENV_LOADED_KEYS="${loaded_key_csv}"
  fi

  export IN_KEYS_SAFE_GUARD=1
  local unset_keys=("${loaded_keys[@]}" "IN_KEYS_SAFE_GUARD")
  if ((${#unset_keys[@]} > 0)); then
    local key_csv
    key_csv="$(IFS=,; echo "${unset_keys[*]}")"
    export SAFE_DOTENV_UNSET_KEYS="${key_csv}"
  fi
}


get_webui_base_url() {
  local mode="$1"
  if [[ "${mode}" == "dev" ]]; then
    get_service_base_url "webui" "development"
  else
    get_service_base_url "engine" "production"
  fi
}

has_gui_env() {
  local os_type
  os_type="$(uname -s 2>/dev/null)"
  if [[ "${os_type}" == "Darwin" ]]; then
    # macOS: no GUI only when inside an SSH session without X11 forwarding
    if [[ -n "${SSH_TTY:-}" || -n "${SSH_CLIENT:-}" ]] && [[ -z "${DISPLAY:-}" ]]; then
      return 1
    fi
    return 0
  else
    # Linux / 其他系统：GUI 需要 DISPLAY 或 WAYLAND_DISPLAY
    [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]
  fi
}

open_in_browser() {
  local url="$1"
  if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    open "${url}" 2>/dev/null || true
  else
    xdg-open "${url}" 2>/dev/null || true
  fi
}

wait_for_http_ready() {
  local url="$1"
  local timeout_seconds="${2:-30}"
  local start_ts now

  start_ts="$(date +%s)"
  while true; do
    if curl -fsS -m 2 -o /dev/null "${url}" >/dev/null 2>&1; then
      return 0
    fi

    now="$(date +%s)"
    if (( now - start_ts >= timeout_seconds )); then
      return 1
    fi
    sleep 1
  done
}

wait_for_tcp_ready() {
  local url="$1"
  local py host port
  py="$(engine_python)"
  read -r host port < <("${py}" - "${url}" <<'PY'
import sys
from urllib.parse import urlparse

parsed = urlparse(sys.argv[1])
host = parsed.hostname or "127.0.0.1"
port = parsed.port or (443 if parsed.scheme == "https" else 80)
print(host, port)
PY
)

  if "${py}" - "${host}" "${port}" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(1.0)
try:
    sock.connect((host, port))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
raise SystemExit(0)
PY
  then
    return 0
  fi
  return 1
}

session_exists() {
  local session_name="$1"
  tmux has-session -t "${session_name}" 2>/dev/null
}

required_sessions_live() {
  local mode="$1"
  if [[ "${mode}" == "dev" ]]; then
    session_exists "sp-webui-dev" && session_exists "sp-engine-dev"
  else
    session_exists "sp-engine-prod"
  fi
}

print_startup_troubleshooting() {
  local mode="$1"
  echo "某个启动中的 tmux 会话在 Skill Pilot 可访问前就退出了。"
  echo "请运行下面的原始命令进行排查："
  if [[ "${mode}" == "dev" ]]; then
    local dev_webui_host dev_webui_port
    dev_webui_host="$(get_service_host "webui" "development")"
    dev_webui_port="$(get_service_port "webui" "development")"
    echo "  cd ${ROOT_DIR}/core/webui && SKILL_PILOT_RUNTIME_MODE=development HOSTNAME=${dev_webui_host} PORT=${dev_webui_port} node scripts/with-timestamp-logs.js dev --webpack --hostname ${dev_webui_host} --port ${dev_webui_port}"
    echo "  cd ${ROOT_DIR} && SKILL_PILOT_RUNTIME_MODE=development uv --project core/engine run core/engine/main.py --reload --reload-dir core/engine --reload-exclude core/engine/tests"
  else
    echo "  cd ${ROOT_DIR} && SKILL_PILOT_RUNTIME_MODE=production uv --project core/engine run core/engine/main.py"
  fi
}

wait_for_service_ready_or_session_exit() {
  local mode="$1"
  local url="$2"
  local start_ts now
  local next_notice=45

  start_ts="$(date +%s)"
  while true; do
    if wait_for_tcp_ready "${url}"; then
      return 0
    fi

    if ! required_sessions_live "${mode}"; then
      return 1
    fi

    now="$(date +%s)"
    if (( now - start_ts >= next_notice )); then
      echo "Skill Pilot 仍在启动中。tmux 会话仍然存活，因此将继续等待..."
      next_notice=$((next_notice + 30))
    fi
    sleep 1
  done
}

open_or_print_webui_url() {
  local mode="$1"
  local base_url url ready_url
  base_url="$(get_webui_base_url "${mode}")"
  if [[ -n "${AUTH_TOKEN:-}" ]]; then
    url="${base_url}?token=${AUTH_TOKEN}"
  else
    url="${base_url}"
  fi

  if [[ "${mode}" == "dev" ]]; then
    ready_url="${base_url}"
  else
    ready_url="${base_url}"
  fi

  echo ""
  if has_gui_env; then
    echo "正在等待 Skill Pilot 可访问：${ready_url}"
    if wait_for_service_ready_or_session_exit "${mode}" "${ready_url}"; then
      echo "Skill Pilot 已可访问。"
    else
      print_startup_troubleshooting "${mode}"
      return 1
    fi
    echo "正在浏览器中打开 WebUI：${url}"
    open_in_browser "${url}"
  else
    echo "WebUI 已准备就绪。请在浏览器中打开这个地址："
    echo "  ${url}"
  fi
}

start_session() {
  local session_name="$1"
  local command="$2"

  if tmux has-session -t "${session_name}" 2>/dev/null; then
    echo "会话 '${session_name}' 已存在。已跳过。"
    return
  fi

  tmux new-session -d -s "${session_name}" "cd '${ROOT_DIR}' && ${command}"
  echo "已启动会话 '${session_name}'。"
}

stop_session() {
  local session_name="$1"

  if ! tmux has-session -t "${session_name}" 2>/dev/null; then
    echo "会话 '${session_name}' 不存在。已跳过。"
    return
  fi

  tmux kill-session -t "${session_name}"
  echo "已停止会话 '${session_name}'。"
}

parse_args "$@"

case "${ACTION}" in
  help|-h|--help)
    print_help
    ;;
  build)
    build_webui_export
    echo "完成。"
    ;;
  test)
    run_engine_tests
    ;;
  start)
    ensure_engine_venv
    run_init_wizard_if_needed
    load_guarded_env
    # 向导第 8 屏 —— 启动服务
    show_screen "启动 Skill Pilot"
    echo "正在 tmux 后台会话中启动服务..."
    echo ""
    if ((IS_DEV == 1)); then
      ensure_webui_deps
      _dev_webui_host="$(get_service_host "webui" "development")"
      _dev_webui_port="$(get_service_port "webui" "development")"
      start_session "sp-webui-dev" "cd core/webui && SKILL_PILOT_RUNTIME_MODE=development HOSTNAME=${_dev_webui_host} PORT=${_dev_webui_port} node scripts/with-timestamp-logs.js dev --webpack --hostname ${_dev_webui_host} --port ${_dev_webui_port}"
      start_session "sp-engine-dev" "SKILL_PILOT_RUNTIME_MODE=development uv --project core/engine run core/engine/main.py --reload --reload-dir core/engine --reload-exclude core/engine/tests"
      _dev_engine_url="$(get_service_base_url "engine" "development")"
      _webui_url="$(get_webui_base_url "dev")"
      echo "  开发 engine   ->  ${_dev_engine_url%/}"
      echo "  WebUI        ->  ${_webui_url%/}  （开发模式）"
      echo ""
      echo "使用 'tmux attach -t sp-webui-dev -r' 或 'tmux attach -t sp-engine-dev -r' 查看日志。"
    else
      ensure_webui_release_assets
      start_session "sp-engine-prod" "SKILL_PILOT_RUNTIME_MODE=production uv --project core/engine run core/engine/main.py"
      _engine_url="$(get_webui_base_url "prod")"
      echo "  Engine + WebUI ->  ${_engine_url%/}  （生产模式）"
      echo ""
      echo "使用 'tmux attach -t sp-engine-prod -r' 查看日志。"
    fi
    echo ""
    echo "要在任意时刻停止 Skill Pilot，请运行："
    if ((IS_DEV == 1)); then
      echo "  ./skillpilot.sh stop --dev"
    else
      echo "  ./skillpilot.sh stop"
    fi
    if ((IS_DEV == 1)); then
      open_or_print_webui_url "dev"
    else
      open_or_print_webui_url "prod"
    fi
    ;;
  stop)
    if ((IS_DEV == 1)); then
      stop_session "sp-webui-dev"
      stop_session "sp-engine-dev"
    else
      stop_session "sp-engine-prod"
    fi
    echo "完成。"
    ;;
  enable)
    case "${ACTION_TARGET}" in
      human-detection)
        install_human_detection_deps
        ;;
      live-tts)
        install_live_tts_deps
        ;;
      *)
        echo "错误：不支持的 enable 目标 '${ACTION_TARGET}'。"
        exit 1
        ;;
    esac
    ;;
  disable)
    case "${ACTION_TARGET}" in
      human-detection)
        uninstall_human_detection_deps
        ;;
      live-tts)
        uninstall_live_tts_deps
        ;;
      *)
        echo "错误：不支持的 disable 目标 '${ACTION_TARGET}'。"
        exit 1
        ;;
    esac
    ;;
  *)
    print_help
    exit 1
    ;;
esac
