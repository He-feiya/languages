#!/usr/bin/env bash

# --- 常量 ---
SOMETHING_INSTALLED=0
FAILED_INSTALLS=()
UPDATED_RC_FILES=()
NEEDS_LOCAL_BIN_PATH=0
NEEDS_PNPM_HOME_PATH=0
NEEDS_BREW_SHELLENV=0
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

CURL="curl -fsSL --proto =https --tlsv1.2"

# --- 输出辅助函数 ---
say() { printf "%b\n" "$*"; }
info() { say "${BLUE}$*${NC}"; }
warn() { say "${YELLOW}$*${NC}"; }
err() { say "${RED}$*${NC}"; }
ok() { say "${GREEN}$*${NC}"; }

press_any_key() {
  local msg="${1:-按任意键继续，或按 Ctrl-C 退出。}"
  printf '%b' "${BOLD}${msg}${NC} "
  local input_fd="/dev/tty"
  { true </dev/tty; } 2>/dev/null || input_fd="/dev/stdin"
  read -r -s -n 1 <"$input_fd" || true
  printf '\n'
}

show_screen() {
  say ""
  say "${BOLD}============================================================${NC}"
  say "${BOLD}  $1${NC}"
  say "${BOLD}============================================================${NC}"
  say ""
}

# --- 退出清理 ---
cleanup() {
  local rc=$?
  if [ $rc -ne 0 ] && [ $rc -ne 130 ]; then
    err "\n安装未完成（退出码 $rc）。"
    err "请先解决上面的问题，然后重新运行：bash install.sh"
  fi
}
trap cleanup EXIT
trap 'printf "\n"; warn "安装已取消。"; exit 130' INT

# --- 用法 ---
usage() {
  cat <<EOF
用法：bash install.sh [选项]

在 macOS 或 Linux 上安装 Skill Pilot 及其依赖。

选项：
  -h, --help    显示此帮助信息并退出

执行步骤：
  1. 安装 Homebrew、Git、curl、wget、uv、pnpm、Node.js、Python 3、tmux、ffmpeg
  2. 克隆 Skill Pilot 仓库
EOF
}

# --- 提示辅助函数 ---
ask_yes_no() {
  local prompt="$1"
  local answer
  local input_fd="/dev/tty"
  if ! { true </dev/tty; } 2>/dev/null; then
    input_fd="/dev/stdin"
  fi
  while true; do
    read -r -p "$prompt [Y/n]: " answer <"$input_fd"
    case "${answer:-}" in
      [Yy]|[Yy][Ee][Ss]|"") return 0 ;;
      [Nn]|[Nn][Oo]) return 1 ;;
      *) warn "请输入 y 或 n。" ;;
    esac
  done
}

# --- 刷新 shell 环境 ---
reload_shell_env() {
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

  case "$(uname -s 2>/dev/null || true)" in
    Darwin) export PNPM_HOME="${PNPM_HOME:-$HOME/Library/pnpm}" ;;
    *) export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}" ;;
  esac
  export PATH="$PNPM_HOME:$PATH"

  if command -v pnpm >/dev/null 2>&1; then
    local pnpm_bin
    pnpm_bin="$(pnpm bin -g 2>/dev/null || true)"
    [ -n "$pnpm_bin" ] && export PATH="$pnpm_bin:$PATH"
  fi

  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  hash -r 2>/dev/null || true
}

# --- sudo 辅助函数 ---
is_root() { [ "$(id -u)" = "0" ]; }

require_sudo() {
  if is_root; then return 0; fi
  if ! command -v sudo >/dev/null 2>&1; then
    warn "需要 sudo，但当前未找到 —— 跳过此步骤。"
    return 1
  fi
}

# --- Linux 构建工具 ---
install_build_tools_linux() {
  require_sudo || return 1
  if command -v apt-get >/dev/null 2>&1; then
    local base_pkgs=(build-essential git curl python3 make g++ cmake pkg-config)
    if is_root; then
      apt-get update -qq
      apt-get install -y -qq "${base_pkgs[@]}"
    else
      sudo apt-get update -qq
      sudo apt-get install -y -qq "${base_pkgs[@]}"
    fi
    return 0
  fi
  if command -v dnf >/dev/null 2>&1; then
    local base_pkgs=(gcc gcc-c++ make cmake python3 git curl)
    if is_root; then
      dnf install -y -q "${base_pkgs[@]}"
    else
      sudo dnf install -y -q "${base_pkgs[@]}"
    fi
    return 0
  fi
  warn "未找到受支持的包管理器（需要 apt-get 或 dnf）—— 跳过构建工具安装。"
  return 1
}

# --- 包管理器分发 ---
pkg_install() {
  local pkg="$1"
  if ! command -v brew >/dev/null 2>&1; then
    warn "未找到 Homebrew —— 无法安装 '$pkg'。已跳过。"
    return 1
  fi
  brew install "$pkg"
}

# --- 安装步骤执行器 ---
install_step() {
  local title="$1"
  local edu_text="$2"
  local cmd_name="$3"
  local install_fn="$4"
  local path_requirement="${5:-}"

  show_screen "$title"
  say "$edu_text"
  say ""

  if command -v "$cmd_name" >/dev/null 2>&1; then
    ok "很好 —— ${title} 已经安装。"
    press_any_key
    return 0
  fi

  press_any_key "按任意键，我将为你安装；或按 Ctrl-C 退出。"

  if ! "$install_fn"; then
    warn "${title} 安装失败 —— 将在没有它的情况下继续。"
    FAILED_INSTALLS+=("${title}")
    return 0
  fi
  SOMETHING_INSTALLED=1
  mark_path_requirement "$path_requirement"
  reload_shell_env

  if command -v "$cmd_name" >/dev/null 2>&1; then
    ok "${title} 已安装并可用。"
  else
    warn "${title} 已安装，但当前 PATH 中还不可见。如有需要，请打开一个新的终端。"
  fi
}

# --- 单项安装函数 ---
install_homebrew() {
  local tmpscript
  tmpscript="$(mktemp)" || { warn "无法为 Homebrew 安装器创建临时文件。"; return 1; }
  if ! $CURL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh > "$tmpscript" \
     || [ ! -s "$tmpscript" ]; then
    rm -f "$tmpscript"
    warn "下载 Homebrew 安装器失败。"
    return 1
  fi
  NONINTERACTIVE=1 /bin/bash "$tmpscript"
  local rc=$?
  rm -f "$tmpscript"
  return $rc
}

install_git()   { pkg_install git; }
install_curl()  { pkg_install curl; }
install_wget()  { pkg_install wget; }
install_tmux()  { pkg_install tmux; }
install_ffmpeg() { pkg_install ffmpeg; }

install_gxmessage_linux() {
  if command -v gxmessage >/dev/null 2>&1; then
    return 0
  fi
  require_sudo || return 1
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "未找到 apt-get —— 跳过 gxmessage 安装。"
    return 1
  fi
  if is_root; then
    apt-get update -qq
    apt-get install -y -qq gxmessage
  else
    sudo apt-get update -qq
    sudo apt-get install -y -qq gxmessage
  fi
}

install_uv() {
  export SHELL="${SHELL:-bash}"
  local tmpscript
  tmpscript="$(mktemp)" || { warn "无法为 uv 安装器创建临时文件。"; return 1; }
  if ! $CURL https://astral.sh/uv/install.sh > "$tmpscript" || [ ! -s "$tmpscript" ]; then
    rm -f "$tmpscript"
    warn "下载 uv 安装器失败。"
    return 1
  fi
  sh "$tmpscript"; local rc=$?
  rm -f "$tmpscript"
  return $rc
}

install_pnpm() {
  export SHELL="${SHELL:-bash}"
  local tmpscript
  tmpscript="$(mktemp)" || { warn "无法为 pnpm 安装器创建临时文件。"; return 1; }
  if ! $CURL https://get.pnpm.io/install.sh > "$tmpscript" || [ ! -s "$tmpscript" ]; then
    rm -f "$tmpscript"
    warn "下载 pnpm 安装器失败。"
    return 1
  fi
  sh "$tmpscript"; local rc=$?
  rm -f "$tmpscript"
  return $rc
}

# --- 版本检查 ---
check_node_version() {
  if ! command -v node >/dev/null 2>&1; then
    return 1
  fi
  local major
  major="$(node -e 'console.log(process.versions.node.split(".")[0])')"
  if [ "$major" -lt 18 ] 2>/dev/null; then
    warn "检测到 Node.js v${major}.x —— 需要 v18 及以上版本。"
    return 1
  fi
  return 0
}

check_python_version() {
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi
  local version_ok
  version_ok="$(python3 -c 'import sys; print(1 if sys.version_info >= (3, 9) else 0)')"
  if [ "${version_ok}" != "1" ]; then
    local ver
    ver="$(python3 -c 'import sys; v=sys.version_info; print(f"{v.major}.{v.minor}")')"
    warn "检测到 Python ${ver} —— 需要 3.9 及以上版本。"
    return 1
  fi
  return 0
}

# --- 持久化 shell PATH ---
mark_path_requirement() {
  case "${1:-}" in
    local_bin) NEEDS_LOCAL_BIN_PATH=1 ;;
    pnpm_home) NEEDS_PNPM_HOME_PATH=1 ;;
    brew_shellenv) NEEDS_BREW_SHELLENV=1 ;;
    both)
      NEEDS_LOCAL_BIN_PATH=1
      NEEDS_PNPM_HOME_PATH=1
      ;;
    all)
      NEEDS_LOCAL_BIN_PATH=1
      NEEDS_PNPM_HOME_PATH=1
      NEEDS_BREW_SHELLENV=1
      ;;
  esac
}

profile_has_token() {
  local rc="$1"
  local token="$2"
  grep -F "$token" "$rc" 2>/dev/null | grep -qv '^[[:space:]]*#'
}

profile_has_local_bin_path() {
  local rc="$1"
  profile_has_token "$rc" '$HOME/.local/bin' \
    || profile_has_token "$rc" "$HOME/.local/bin" \
    || profile_has_token "$rc" '~/.local/bin'
}

profile_has_pnpm_home_decl() {
  local rc="$1"
  local pnpm_home="$2"
  profile_has_token "$rc" 'export PNPM_HOME=' \
    || profile_has_token "$rc" 'PNPM_HOME=' \
    || profile_has_token "$rc" "$pnpm_home"
}

profile_has_pnpm_path() {
  local rc="$1"
  local pnpm_home="$2"
  profile_has_token "$rc" '$PNPM_HOME' \
    || profile_has_token "$rc" "$pnpm_home"
}

resolve_brew_bin() {
  if command -v brew >/dev/null 2>&1; then
    command -v brew
    return 0
  fi
  if [ -x /opt/homebrew/bin/brew ]; then
    printf '%s\n' /opt/homebrew/bin/brew
    return 0
  fi
  if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
    printf '%s\n' /home/linuxbrew/.linuxbrew/bin/brew
    return 0
  fi
  if [ -x /usr/local/bin/brew ]; then
    printf '%s\n' /usr/local/bin/brew
    return 0
  fi
  return 1
}

profile_has_brew_shellenv() {
  local rc="$1"
  local brew_bin="$2"
  profile_has_token "$rc" 'brew shellenv' \
    || profile_has_token "$rc" "$brew_bin shellenv"
}

setup_shell_paths() {
  local rc_files=()
  [ -f "$HOME/.bashrc" ] && rc_files+=("$HOME/.bashrc")
  [ -f "$HOME/.zshrc" ]  && rc_files+=("$HOME/.zshrc")

  if [ "$NEEDS_LOCAL_BIN_PATH" -eq 0 ] && [ "$NEEDS_PNPM_HOME_PATH" -eq 0 ] && [ "$NEEDS_BREW_SHELLENV" -eq 0 ]; then
    ok "本次安装的工具不需要更新 profile 中的 PATH。"
    return 0
  fi

  # 解析实际的 PNPM_HOME 路径
  local pnpm_home
  case "$(uname -s 2>/dev/null || true)" in
    Darwin) pnpm_home="$HOME/Library/pnpm" ;;
    *)      pnpm_home="$HOME/.local/share/pnpm" ;;
  esac
  pnpm_home="${PNPM_HOME:-$pnpm_home}"

  local can_add_local_bin=0
  local can_add_pnpm_home=0
  local can_add_brew_shellenv=0
  local brew_bin=""

  if [ "$NEEDS_LOCAL_BIN_PATH" -eq 1 ]; then
    if [ -d "$HOME/.local/bin" ]; then
      can_add_local_bin=1
    else
      warn "跳过 profile PATH 更新：$HOME/.local/bin 不存在。"
    fi
  fi

  if [ "$NEEDS_PNPM_HOME_PATH" -eq 1 ]; then
    if [ -d "$pnpm_home" ]; then
      can_add_pnpm_home=1
    else
      warn "跳过 profile PATH 更新：$pnpm_home 不存在。"
    fi
  fi

  if [ "$NEEDS_BREW_SHELLENV" -eq 1 ]; then
    if brew_bin="$(resolve_brew_bin)"; then
      can_add_brew_shellenv=1
    else
      warn "跳过 profile 中的 Homebrew 更新：未找到 brew 可执行文件。"
    fi
  fi

  if [ "$can_add_local_bin" -eq 0 ] && [ "$can_add_pnpm_home" -eq 0 ] && [ "$can_add_brew_shellenv" -eq 0 ]; then
    ok "现有安装路径目录不需要更新 profile。"
    return 0
  fi

  if [ "${#rc_files[@]}" -eq 0 ]; then
    warn "未找到可自动更新的 shell profile 文件（.bashrc 或 .zshrc）。"
    warn "请将以下内容手动添加到你的 shell 配置中："
    warn "────────────────────────────────────────────"
    if [ "$can_add_local_bin" -eq 1 ]; then
      warn 'export PATH="$HOME/.local/bin:$PATH"'
    fi
    if [ "$can_add_pnpm_home" -eq 1 ]; then
      warn "export PNPM_HOME=\"$pnpm_home\""
      warn 'export PATH="$PNPM_HOME:$PATH"'
    fi
    if [ "$can_add_brew_shellenv" -eq 1 ]; then
      warn "eval \"\$($brew_bin shellenv)\""
    fi
    warn "────────────────────────────────────────────"
    warn "然后运行：source <rc-file>（例如：source ~/.zshrc）"
    warn "或者打开一个新的终端来应用这些更改。"
    return 0
  fi

  local manual_files=()
  local manual_need_local_bin=0
  local manual_need_pnpm_home_decl=0
  local manual_need_pnpm_path=0
  local manual_need_brew_shellenv=0
  for rc in "${rc_files[@]}"; do
    local lines=""

    if [ "$can_add_local_bin" -eq 1 ]; then
      if profile_has_local_bin_path "$rc"; then
        ok "$rc 中已经包含 ~/.local/bin 的 PATH 条目。"
      else
        lines+='export PATH="$HOME/.local/bin:$PATH"'$'\n'
      fi
    fi

    if [ "$can_add_pnpm_home" -eq 1 ]; then
      if profile_has_pnpm_home_decl "$rc" "$pnpm_home"; then
        :
      else
        lines+="export PNPM_HOME=\"$pnpm_home\""$'\n'
      fi

      if profile_has_pnpm_path "$rc" "$pnpm_home"; then
        :
      else
        lines+='export PATH="$PNPM_HOME:$PATH"'$'\n'
      fi
    fi

    if [ "$can_add_brew_shellenv" -eq 1 ]; then
      if profile_has_brew_shellenv "$rc" "$brew_bin"; then
        ok "$rc 中已经包含 Homebrew shellenv。"
      else
        lines+="eval \"\$($brew_bin shellenv)\""$'\n'
      fi
    fi

    if [ -z "$lines" ]; then
      ok "$rc 不需要更新 PATH。"
      continue
    fi

    if [ ! -w "$rc" ]; then
      warn "无法写入 $rc（权限不足）—— 已跳过。"
      manual_files+=("$rc")
      if printf '%s' "$lines" | grep -Fq 'export PATH="$HOME/.local/bin:$PATH"'; then
        manual_need_local_bin=1
      fi
      if printf '%s' "$lines" | grep -Fq 'export PNPM_HOME='; then
        manual_need_pnpm_home_decl=1
      fi
      if printf '%s' "$lines" | grep -Fq 'export PATH="$PNPM_HOME:$PATH"'; then
        manual_need_pnpm_path=1
      fi
      if printf '%s' "$lines" | grep -Fq 'brew shellenv'; then
        manual_need_brew_shellenv=1
      fi
      continue
    fi

    local block=$'\n# --- Skill Pilot 安装器添加 ---\n'"$lines"
    printf '%s\n' "$block" >> "$rc"
    ok "已将缺失的工具 PATH 条目写入 $rc。"
    UPDATED_RC_FILES+=("$rc")
  done

  if [ "${#manual_files[@]}" -gt 0 ]; then
    warn "\n无法自动更新以下 shell 配置文件："
    for rc in "${manual_files[@]}"; do
      warn "  $rc"
    done
    warn "\nAdd the following lines to your shell config manually:"
    warn "────────────────────────────────────────────"
    if [ "$manual_need_local_bin" -eq 1 ]; then
      warn 'export PATH="$HOME/.local/bin:$PATH"'
    fi
    if [ "$manual_need_pnpm_home_decl" -eq 1 ]; then
      warn "export PNPM_HOME=\"$pnpm_home\""
    fi
    if [ "$manual_need_pnpm_path" -eq 1 ]; then
      warn 'export PATH="$PNPM_HOME:$PATH"'
    fi
    if [ "$manual_need_brew_shellenv" -eq 1 ]; then
      warn "eval \"\$($brew_bin shellenv)\""
    fi
    warn "────────────────────────────────────────────"
    warn "然后运行：source <rc-file>（例如：source ~/.zshrc）"
    warn "或者打开一个新的终端来应用这些更改。"
  fi
}

# --- skillpilot.sh 的内部 profile ---
write_skillpilot_profile() {
  local profile_dir="$HOME/.skillpilot"
  local profile_file="${profile_dir}/.profile"
  mkdir -p "$profile_dir" 2>/dev/null || true

  local pnpm_home_line
  case "$(uname -s 2>/dev/null || true)" in
    Darwin) pnpm_home_line='export PNPM_HOME="${PNPM_HOME:-$HOME/Library/pnpm}"' ;;
    *)      pnpm_home_line='export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"' ;;
  esac

  local brew_env=""
  if [ -x /opt/homebrew/bin/brew ]; then
    brew_env='eval "$(/opt/homebrew/bin/brew shellenv)"'
  elif [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
    brew_env='eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'
  elif [ -x /usr/local/bin/brew ]; then
    brew_env='eval "$(/usr/local/bin/brew shellenv)"'
  fi

  {
    echo '# --- Skill Pilot 安装器添加 ---'
    echo 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"'
    echo "$pnpm_home_line"
    echo 'export PATH="$PNPM_HOME:$PATH"'
    [ -n "$brew_env" ] && echo "$brew_env"
  } > "$profile_file"
}

# --- Git 分支设置 ---
setup_branches() {
  info "\n正在设置 Git 分支..."
  local current_branch
  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

  if git show-ref --verify --quiet "refs/heads/user"; then
    ok "分支 'user' 已存在。"
  else
    git branch user
    ok "已创建分支 'user'。"
  fi

  if [ "$current_branch" != "user" ]; then
    git checkout user
    ok "已切换到分支 'user'（工作分支）。"
  else
    ok "当前已经位于分支 'user'（工作分支）。"
  fi
}

# --- 后续步骤提醒 ---
print_next_steps() {
  if [ "${#UPDATED_RC_FILES[@]}" -eq 0 ]; then
    return 0
  fi
  say ""
  say "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  say "${BOLD}  需要执行的操作 —— 重新加载你的 shell${NC}"
  say "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  say "  新工具的路径已经添加到你的 shell profile 文件中。"
  say "  若要立即在当前终端中启用这些命令，请运行："
  say ""
  for rc in "${UPDATED_RC_FILES[@]}"; do
    say "    ${BOLD}source $rc${NC}"
  done
  say ""
  say "  或者直接打开一个新的终端窗口。"
  say "  完成任一步骤后，新命令都可以正常使用。"
  say "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# --- 主流程 ---
main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
  esac

  # 第 1 屏 —— 欢迎
  show_screen "欢迎使用 Skill Pilot AI Agent"
  say "你即将搭建一个 Codeware 环境 —— 一个持续演化的"
  say "工作空间，让你和 AI 每天都能一起协作。"
  say ""
  say "这不是那种下载后点一点就能用的普通应用。"
  say "你正在为一个 AI 工作者安装它的工作栖息地。"
  say ""
  say "  传统软件：Human -> UI -> Software -> Fixed result"
  say "  Codeware：Human -> AI -> Codebase -> Evolving result"
  say ""
  say "Skill Pilot 让你能够用更自然的方式写代码、学习、构建产品，"
  say "并亲身探索 AI 真正能做什么 —— 在你自己的终端里，与它并肩工作。"
  say ""
  press_any_key

  reload_shell_env

  local os OS_KIND
  os="$(uname -s 2>/dev/null || true)"
  case "$os" in
    Darwin) OS_KIND="mac" ;;
    Linux)  OS_KIND="linux" ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
      # 第 2 屏 —— Windows
      show_screen "检测到 Windows"
      say "Windows 与 Skill Pilot 依赖的 AI 和开发者工具"
      say "并不是原生兼容的。"
      say ""
      say "好消息是：微软为 Windows 提供了一个免费的 Linux 层"
      say "，叫作 WSL（Windows Subsystem for Linux）。它可以让你在"
      say "Windows 内运行一个完整的 Linux 终端。"
      say ""
      say "第 1 步 —— 在浏览器中打开下面的链接并跟随指南操作："
      say "  https://learn.microsoft.com/en-us/windows/wsl/install"
      say ""
      say "第 2 步 —— 当系统要求你选择 Linux 发行版时，请选择："
      say "  Ubuntu（开发者和云环境中使用最广泛）"
      say ""
      say "第 3 步 —— 安装好 WSL 后，打开 Ubuntu 终端，然后"
      say "  在那里运行 Skill Pilot 的安装命令。"
      press_any_key "按任意键退出，然后先安装 WSL。"
      exit 0
      ;;
    *)
      warn "无法识别的操作系统：$os —— 仍将继续，但某些步骤可能失败。"
      OS_KIND="unknown"
      ;;
  esac

  local script_path
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
  local skip_clone="false"
  case "$script_path" in
    */core/engine/dev_swarm/*) skip_clone="true" ;;
  esac

  # 第 3 屏 —— 仅 macOS：Xcode Command Line Tools
  if [ "$OS_KIND" = "mac" ]; then
    show_screen "Xcode 命令行工具"
    say "AI 需要苹果提供的一套免费小工具，叫作 "Xcode Command Line Tools"。"
    say ""
    say "它包含的内容："
    say "  - clang   ：把代码编译成程序的编译器"
    say "  - make    ：按步骤构建软件的工具"
    say "  - git     ：版本控制工具（稍后会解释）"
    say ""
    say "可以把它看作在 macOS 上安装任何 AI / 开发者工具之前的"
    say "基础层。"
    say ""
    if xcode-select -p >/dev/null 2>&1; then
      ok "很好 —— 你的 Mac 上已经安装了 Xcode 命令行工具。"
      press_any_key
    else
      press_any_key "按任意键，我将开始为你安装；或按 Ctrl-C 退出。"
      xcode-select --install 2>/dev/null || true
      warn "系统弹窗已经出现。请先完成 Xcode CLT 的安装，"
      warn "然后回到这里并按 Enter。"
      { read -r -p "" </dev/tty; } 2>/dev/null || read -r -p ""
      if xcode-select -p >/dev/null 2>&1; then
        ok "Xcode 命令行工具已安装。"
      else
        warn "暂未检测到 Xcode 命令行工具 —— 仍将继续。"
      fi
    fi
  fi

  # 第 4 屏 —— 仅 Linux：构建工具
  if [ "$OS_KIND" = "linux" ]; then
    show_screen "Linux 构建工具"
    say "AI 在 Linux 上需要一组编译器和实用工具。"
    say ""
    say "将要安装的内容："
    say "  - gcc / g++ ：把代码编译成程序的编译器"
    say "  - make      ：构建协调工具"
    say "  - cmake     ：许多工具和库都会用到"
    say "  - pkg-config：帮助程序找到其他依赖库"
    say ""
    say "可以把它看作在 macOS 上安装任何 AI / 开发者工具之前的"
    say "基础层。"
    say ""
    if command -v make >/dev/null 2>&1; then
      ok "很好 —— 构建工具已经可用。"
      press_any_key
    else
      press_any_key "按任意键，我将为你安装它们；或按 Ctrl-C 退出。"
      install_build_tools_linux || warn "构建工具安装失败 —— 仍将继续。"
    fi
  fi

  # Homebrew 之前的 Git 检查（静默）
  if ! command -v git >/dev/null 2>&1 && [ "$OS_KIND" = "linux" ]; then
    if command -v apt-get >/dev/null 2>&1; then
      if is_root; then apt-get install -y -qq git 2>/dev/null; else sudo apt-get install -y -qq git 2>/dev/null; fi
    elif command -v dnf >/dev/null 2>&1; then
      if is_root; then dnf install -y -q git 2>/dev/null; else sudo dnf install -y -q git 2>/dev/null; fi
    fi
  fi

  # 第 5 屏 —— Homebrew
  install_step \
    "Homebrew —— 你的包管理器" \
    "$(printf '%s\n%s\n\n%s\n%s\n%s\n%s\n%s' \
      "包管理器就像开发者工具的应用商店，" \
      "但它完全通过终端来操作。" \
      "为什么是 Homebrew？" \
      "  - 安装软件通常不需要管理员 / root 密码" \
      "  - 把内容都放在自己的目录里（安全、整洁）" \
      "  - Skill Pilot 中大多数 AI agent 技能都会用到它" \
      "  - 同时支持 macOS 和 Linux")" \
    "brew" \
    "install_homebrew" \
    "brew_shellenv"

  # 第 6 屏 —— uv
  install_step \
    "uv —— 快速 Python 管理器" \
    "$(printf '%s\n%s\n%s\n\n%s\n\n%s\n%s\n%s\n%s\n\n%s' \
      "Python 是 AI 的第一语言。" \
      "AI agents 会用 Python 做计算、调用 API，" \
      "处理文件，以及完成单靠 LLM 做不到的事情。" \
      "uv 是一个现代的 Python 管理工具。对比如下：" \
      "  旧方式（pip）：安装慢、项目之间共享包，" \
      "                  容易把环境弄坏" \
      "  uv：            非常快，每个项目都有自己的" \
      "                  独立包环境，还能节省磁盘空间" \
      "Skill Pilot 的引擎就是基于 Python + uv 构建的。")" \
    "uv" \
    "install_uv" \
    "local_bin"

  # 第 7 屏 —— Python 3
  show_screen "Python 3 —— AI 的第一语言"
  say "Python 是 AI 研究和工程中使用最广泛的语言，"
  say "Skill Pilot 的引擎、LLM 路由以及大多数"
  say "自动化工具都使用 Python 编写。"
  say ""
  say "我们需要 Python 3.9 或更高版本。"
  say "uv 会自动安装合适的版本。"
  say ""
  if check_python_version; then
    ok "很好 —— Python 3 已安装且版本符合要求。"
    press_any_key
  else
    press_any_key "按任意键，我将为你安装最新的 Python 3；或按 Ctrl-C 退出。"
    if uv python install; then
      SOMETHING_INSTALLED=1
      reload_shell_env
      ok "Python 3 已安装。"
    else
      warn "Python 3 安装失败 —— 将在没有它的情况下继续。"
    fi
  fi

  # 第 8 屏 —— pnpm
  install_step \
    "pnpm —— 快速 Node.js 包管理器" \
    "$(printf '%s\n%s\n\n%s\n%s\n\n%s\n%s\n%s\n%s\n%s' \
      "Node.js 是构建网站、AI agents 和云服务时最流行的运行时之一，" \
      "" \
      "Skill Pilot 的 Web 界面基于 Next.js 构建 —— 这是一个" \
      "运行在 Node.js 之上的框架。" \
      "pnpm 用来管理 Node.js 包。对比如下：" \
      "  旧方式（npm）：每个项目都会下载一整份包副本，" \
      "                  会占用很多磁盘空间" \
      "  pnpm：          用智能链接在项目之间共享包，" \
      "                  更快，而且更省磁盘空间")" \
    "pnpm" \
    "install_pnpm" \
    "pnpm_home"

  # 第 9 屏 —— Node.js
  show_screen "Node.js —— JavaScript 运行时"
  say "Node.js 可以让 JavaScript 代码运行在你的电脑上（不只是"
  say "浏览器里）。它支撑着："
  say ""
  say "  - Skill Pilot 的 Web 界面（Next.js）"
  say "  - 许多 AI agent 工具和 CLI 程序"
  say "  - 现代云服务和 API"
  say ""
  say "我们需要 Node.js 18 或更高版本。"
  say "pnpm 会为你安装合适的版本。"
  say ""
  say "  LTS = Long-Term Support —— 稳定且推荐使用的版本"
  say "  会持续获得多年的安全更新。"
  say ""
  if check_node_version; then
    ok "很好 —— Node.js 已安装且版本符合要求。"
    press_any_key
  else
    press_any_key "按任意键，我将为你安装最新的 LTS Node.js；或按 Ctrl-C 退出。"
    if pnpm env use --global lts; then
      SOMETHING_INSTALLED=1
      mark_path_requirement "pnpm_home"
      reload_shell_env
      ok "Node.js 已安装。"
    else
      warn "Node.js 安装失败 —— 将在没有它的情况下继续。"
    fi
  fi

  # 第 10 屏 —— tmux
  install_step \
    "tmux —— 你们共享的终端空间" \
    "$(printf '%s\n\n%s\n%s\n\n%s\n%s\n%s\n\n%s\n%s' \
      "tmux 是 Skill Pilot 中最重要的工具之一。" \
      "通常当你关闭终端窗口时，里面运行的一切" \
      "都会停止。tmux 可以让会话继续在后台存活，" \
      "即使你关掉窗口也没关系。" \
      "对 Skill Pilot 更重要的是：" \
      "  tmux 让你和 AI 能共享同一个终端视图。" \
      "  你们可以同时看到正在发生什么 ——" \
      "  这对调试和协作非常有帮助。" \
      "  你可以看着 AI 工作。" \
      "  AI 也能看到你的终端输出。")" \
    "tmux" \
    "install_tmux"

  # 第 11 屏 —— wget
  install_step \
    "wget —— 文件下载器" \
    "$(printf '%s\n%s\n%s\n\n%s\n%s' \
      "wget 是一个从互联网下载文件的命令行工具，" \
      "许多 AI agent 技能会用它来拉取数据集、" \
      "模型、配置文件以及其他资源。" \
      "curl 也能下载文件，但 wget 在处理大文件" \
      "以及断点重试时更稳妥。")" \
    "wget" \
    "install_wget"

  # 第 12 屏 —— ffmpeg
  install_step \
    "ffmpeg —— 媒体工具箱" \
    "$(printf '%s\n%s\n%s\n\n%s\n%s\n%s' \
      "ffmpeg 是 Skill Pilot 用于处理媒体任务的命令行工具箱，" \
      "可用于视频和音频处理，例如转码、" \
      "合并片段、提取帧以及生成缩略图。" \
      "多个媒体和工作流功能都依赖它" \
      "在 PATH 中可用。" \
      "如果缺少 ffmpeg，这个安装器会通过" \
      "Homebrew 把它安装上。")" \
    "ffmpeg" \
    "install_ffmpeg"

  # 第 12 屏 —— gxmessage（仅 Linux）
  if [ "$OS_KIND" = "linux" ]; then
    install_step \
      "gxmessage —— Linux 确认对话框" \
      "$(printf '%s\n%s\n\n%s\n%s' \
        "在 Linux 上，当 Skill Pilot 需要一个简单的" \
        "桌面确认窗口来暂停某个操作时，会使用 gxmessage。" \
        "这样可以让确认流程保持轻量，同时避免额外的 Python" \
        "GUI 依赖，适合无头或混合环境。")" \
      "gxmessage" \
      "install_gxmessage_linux"
  fi

  if [ "$SOMETHING_INSTALLED" -eq 1 ]; then
    setup_shell_paths
  fi

  # 写入供 skillpilot.sh 静默 source 的内部 profile
  write_skillpilot_profile

  # 第 16 屏 —— PATH 环境设置（仅在安装了新工具时显示）
  if [ "$SOMETHING_INSTALLED" -eq 1 ]; then
    show_screen "保存工具路径"
    say "当你安装一个工具后，终端需要知道"
    say "去哪里找到它。这就叫 PATH。"
    say ""
    say "刚刚安装的工具对应的 PATH 设置已经"
    say "写入了你的 shell profile。安装器已经检测到你的"
    say "shell，并自动更新了正确的文件。"
    say ""
    say "新的终端窗口会自动读取这些设置。"
    say ""
    say "如果你想立刻在当前终端中使用新安装的工具，"
    say "请运行下面显示的命令（你的文件名可能不同）："
    say ""
    if [ "${#UPDATED_RC_FILES[@]}" -gt 0 ]; then
      for rc in "${UPDATED_RC_FILES[@]}"; do
        say "  source $rc"
      done
    else
      say "  source ~/.zshrc   或   source ~/.bashrc"
    fi
    say ""
    say "或者直接打开一个新的终端窗口 —— 两种方式都可以。"
    press_any_key
  fi

  if [ "$skip_clone" = "true" ]; then
    warn "检测到安装器路径位于 'core/engine/dev_swarm' 下；跳过仓库克隆步骤。"
    ok "安装引导已完成。"
    say ""
    say "当前目录：$(pwd)"
    if [ -x "./skillpilot.sh" ]; then
      setup_branches
      say ""
      info "正在运行：./skillpilot.sh help"
      ./skillpilot.sh help
    else
      warn "由于当前目录中的 ./skillpilot.sh 不可执行，已跳过 './skillpilot.sh help'。"
    fi
    return 0
  fi

  # 第 13 屏 —— 选择安装位置
  show_screen "选择安装位置"
  say "符号 ~/  表示你的主目录。"
  say "在 macOS 上：/Users/your-username/"
  say "在 Linux 上：/home/your-username/"
  say ""
  say "这是你在这台电脑上的个人空间。安装到这里"
  say "不会影响其他用户，也不需要特殊的"
  say "权限。"
  say ""
  say "我们建议安装在你的主目录下："
  say ""

  local opt1="$HOME/workspace/skill-pilot"
  local opt2
  opt2="$(pwd)/skill-pilot"
  local install_base
  local input_fd="/dev/tty"
  { true </dev/tty; } 2>/dev/null || input_fd="/dev/stdin"

  say "  ${BOLD}1)${NC} ~/workspace/skill-pilot          ${BLUE}(推荐)${NC}"
  say "     ${BLUE}-> $opt1${NC}"
  say ""
  say "  ${BOLD}2)${NC} 当前文件夹 / skill-pilot"
  say "     ${BLUE}-> $opt2${NC}"
  say ""
  say "  ${BOLD}3)${NC} 输入自定义路径（你来指定完整项目目录）"
  say ""

  local choice
  while true; do
    read -r -p "请输入你的选择 [1/2/3]：" choice <"$input_fd"
    case "${choice:-}" in
      1)
        install_base="$opt1"
        ok "安装位置：$install_base"
        break
        ;;
      2)
        install_base="$opt2"
        ok "安装位置：$install_base"
        break
        ;;
      3)
        local custom_base
        printf "\n请输入完整安装路径（这将作为项目目录）：" >/dev/tty 2>&1 \
          || printf "\n请输入完整安装路径（这将作为项目目录）："
        IFS= read -r custom_base <"$input_fd" || true
        custom_base="${custom_base%/}"
        if [ -z "$custom_base" ]; then
          warn "未输入路径 —— 将使用默认值：$opt1"
          install_base="$opt1"
        else
          install_base="$custom_base"
        fi
        ok "安装位置：$install_base"
        break
        ;;
      *) warn "请输入 1、2 或 3。" ;;
    esac
  done

  local clone_dir="$install_base"
  local parent_dir
  parent_dir="$(dirname "$clone_dir")"

  if [ ! -d "$parent_dir" ]; then
    say "正在创建目录：$parent_dir"
    mkdir -p "$parent_dir" || { warn "无法创建 $parent_dir —— 跳过克隆。"; return 0; }
  fi

  if [ ! -w "$parent_dir" ]; then
    warn "目录不可写：$parent_dir —— 跳过克隆。"
    return 0
  fi

  # 第 14 屏 —— Git 克隆
  show_screen "下载 Skill Pilot（git clone）"
  say "什么是 git？"
  say "  git 是一个版本控制工具 —— 它会跟踪代码库中的每一次改动"
  say "  随时间发生的变化。有点像文档里的 "修订"，"
  say "  只不过对象变成了代码。"
  say ""
  say "什么是 git clone？"
  say "  git clone 会把一整份代码库从互联网下载到你的电脑上"
  say "  和下载 zip 不同，clone 后的仓库仍然保留历史与连接，"
  say "  会保留与原仓库的连接 —— 这样你就能接收"
  say "  后续更新。"
  say ""
  say "  在 Skill Pilot 中，codeware（稳定发布层）的更新"
  say "  会以 Git 更新的形式到来，就像普通软件"
  say "  的版本更新一样。"
  say ""
  say "正在把 Skill Pilot 克隆到：$clone_dir"
  press_any_key "按任意键开始下载，或按 Ctrl-C 退出。"

  if [ -d "$clone_dir/.git" ]; then
    warn "$clone_dir 中已存在仓库 —— 将复用现有仓库。"
  else
    if ! git clone --depth 1 https://github.com/x-school-academy/skill-pilot "$clone_dir"; then
      warn "git clone 失败 —— 跳过后续设置。"
      return 0
    fi
  fi

  cd "$clone_dir"

  # 第 15 屏 —— Git 分支
  show_screen "设置你的工作区分支"
  say "git 使用分支来管理同一代码库的并行版本。"
  say ""
  say ""
  say "在正常的本地使用场景下，Skill Pilot 会用到两个分支："
  say ""
  say "  codeware  稳定发布层 —— 由"
  say "            Skill Pilot 团队维护。你可以把它理解为 "main""
  say "            软件发布分支。你应保持它干净，并把它作为"
  say "            获取更新的来源。"
  say ""
  say "  user      你的个人工作区 —— 你和 AI 会在这里"
  say "            进行日常的所有修改。这个分支"
  say "            可以由你自由编辑。"
  say ""
  say "只有当你准备把改动干净地贡献回官方仓库时，"
  say "才需要创建贡献分支。"
  say ""
  say "日常流程："
  say "  codeware -> user       （你从这里接收更新）"
  say ""
  say "贡献流程（仅在需要时）："
  say "  user -> 从 upstream/contrib 创建功能分支 -> pull request"
  press_any_key "按任意键立即创建 'user' 分支并切换过去。"

  setup_branches

  # 第 17 屏 —— 安装完成
  show_screen "安装完成"
  if [ "${#FAILED_INSTALLS[@]}" -eq 0 ]; then
    ok "所有工具都已安装完成，你的工作区已经准备就绪。"
  else
    warn "安装已结束，但以下工具未能成功安装："
    for t in "${FAILED_INSTALLS[@]}"; do
      warn "  - ${t}"
    done
    say ""
    say "你可以手动安装缺失的工具，然后重新运行："
    say "  bash install.sh"
    say ""
    say "除此之外，你的工作区已经准备好了 —— 将继续。"
  fi
  say ""
  say "下一步 —— 启动 Skill Pilot："
  say ""
  say "1. 在当前终端中激活新的工具路径："
  if [ "${#UPDATED_RC_FILES[@]}" -gt 0 ]; then
    for rc in "${UPDATED_RC_FILES[@]}"; do
      say "     source $rc"
    done
  else
    say "     （无需新增路径 —— 所有工具都已提前配置好）"
  fi
  say "   （或者直接打开一个新的终端窗口）"
  say ""
  say "2. 运行 Skill Pilot 设置向导："
  say "     cd $clone_dir"
  say "     ./skillpilot.sh"
  say ""
  say "该向导将会："
  say "  - 解释端口、地址和网络设置"
  say "  - 安装免费的 AI agent CLI 工具"
  say "  - 配置你的 AI 提供方"
  say "  - 首次启动 Skill Pilot"
  press_any_key "按任意键退出安装器。"
}

main "$@"
