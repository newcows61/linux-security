#!/usr/bin/env bash

# ============================================================
# Linux Security OneKey V6（中文菜单一体版）
#
# 支持的主要系统：
#   - Ubuntu / Debian 及其常见衍生系统（APT）
#   - Rocky Linux / AlmaLinux / Fedora / CentOS Stream / RHEL
#     及其常见衍生系统（DNF/YUM）
#
# 设计原则：
#   - 菜单只显示一次，不清屏、不来回跳动
#   - 可以一次输入多个编号，例如：1 2 4 5
#   - 所有修改操作都再次询问 y/N；直接回车等同于 N
#   - 用户名、密码、端口、大小等输入为空时不修改
#   - SSH 修改前自动备份，配置检测失败会立即回滚
#   - 即使使用 curl ... | bash，也从 /dev/tty 读取交互输入
#
# 建议运行：
#   bash <(curl -fsSL https://raw.githubusercontent.com/newcows61/linux-security/main/install_security.sh)
#
# 也兼容：
#   curl -fsSL https://raw.githubusercontent.com/newcows61/linux-security/main/install_security.sh | bash
# ============================================================

set -o pipefail
umask 077

VERSION="6.0.0"
SCRIPT_NAME="Linux Security OneKey"
TTY_DEVICE="/dev/tty"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "错误：请使用 root 用户执行此脚本。"
    exit 1
fi

if [[ ! -r "$TTY_DEVICE" || ! -w "$TTY_DEVICE" ]]; then
    echo "错误：当前没有可用的交互终端。"
    echo "请通过 SSH/控制台登录后执行，不要放在无人值守任务中运行。"
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    echo "错误：无法读取 /etc/os-release，不能识别系统。"
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
OS_ID="${ID:-unknown}"
OS_LIKE="${ID_LIKE:-}"
OS_NAME="${PRETTY_NAME:-$OS_ID}"

if command -v apt-get >/dev/null 2>&1; then
    PKG_FAMILY="debian"
    PKG_MANAGER="apt-get"
elif command -v dnf >/dev/null 2>&1; then
    PKG_FAMILY="rhel"
    PKG_MANAGER="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG_FAMILY="rhel"
    PKG_MANAGER="yum"
else
    echo "错误：当前只支持 APT、DNF 或 YUM 软件包管理器。"
    echo "检测到的系统：$OS_NAME"
    exit 1
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="/root/linux-security-backups"
BACKUP_DIR="$BACKUP_ROOT/$RUN_ID"
BACKUP_MANIFEST="$BACKUP_DIR/manifest.txt"
LOG_DIR="/var/log/linux-security"
LOG_FILE="$LOG_DIR/run-$RUN_ID.log"
mkdir -p "$BACKUP_DIR" "$LOG_DIR"
touch "$BACKUP_MANIFEST"
chmod 700 "$BACKUP_ROOT" "$BACKUP_DIR" 2>/dev/null || true
chmod 600 "$BACKUP_MANIFEST" 2>/dev/null || true

# 将执行输出写入日志；交互输入仍从 /dev/tty 读取。
exec > >(tee -a "$LOG_FILE") 2>&1

ADMIN_USER=""
APT_UPDATED=0
SSH_CHANGED=0

line() {
    printf '%s\n' "------------------------------------------------------------"
}

section() {
    echo
    line
    echo "$1"
    line
}

info() {
    echo "[信息] $*"
}

ok() {
    echo "[完成] $*"
}

warn() {
    echo "[警告] $*" >&2
}

err() {
    echo "[错误] $*" >&2
}

pause_short() {
    sleep 1
}

read_text() {
    # 用法：read_text 变量名 "提示文字"
    local __var_name="$1"
    local __prompt="$2"
    local __value=""
    IFS= read -r -p "$__prompt" __value < "$TTY_DEVICE" || __value=""
    printf -v "$__var_name" '%s' "$__value"
}

read_secret() {
    # 用法：read_secret 变量名 "提示文字"
    local __var_name="$1"
    local __prompt="$2"
    local __value=""
    IFS= read -r -s -p "$__prompt" __value < "$TTY_DEVICE" || __value=""
    echo > "$TTY_DEVICE"
    printf -v "$__var_name" '%s' "$__value"
}

ask_yes_no() {
    # 只有明确输入 y/Y 才返回成功；回车、n/N、其他内容都跳过。
    local prompt="$1"
    local answer=""
    IFS= read -r -p "$prompt [y/N]: " answer < "$TTY_DEVICE" || answer=""
    [[ "$answer" =~ ^[Yy]$ ]]
}

is_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_valid_port() {
    local port="$1"
    is_integer "$port" && (( port >= 1 && port <= 65535 ))
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

service_exists() {
    systemctl list-unit-files "$1" >/dev/null 2>&1
}

backup_file() {
    # 仅在本次运行中第一次遇到该路径时备份。
    local path="$1"
    local relative="${path#/}"

    if grep -Fq "|$path" "$BACKUP_MANIFEST" 2>/dev/null; then
        return 0
    fi

    mkdir -p "$BACKUP_DIR/$(dirname "$relative")"

    if [[ -e "$path" || -L "$path" ]]; then
        cp -a "$path" "$BACKUP_DIR/$relative"
        echo "EXISTS|$path" >> "$BACKUP_MANIFEST"
    else
        echo "MISSING|$path" >> "$BACKUP_MANIFEST"
    fi
}

restore_backup_directory() {
    local selected="$1"
    local manifest="$selected/manifest.txt"
    local state path relative

    if [[ ! -f "$manifest" ]]; then
        err "备份清单不存在：$manifest"
        return 1
    fi

    while IFS='|' read -r state path; do
        [[ -z "$state" || -z "$path" ]] && continue
        relative="${path#/}"

        if [[ "$state" == "EXISTS" ]]; then
            if [[ -e "$selected/$relative" || -L "$selected/$relative" ]]; then
                mkdir -p "$(dirname "$path")"
                rm -rf "$path"
                cp -a "$selected/$relative" "$path"
                info "已恢复：$path"
            fi
        elif [[ "$state" == "MISSING" ]]; then
            rm -rf "$path"
            info "已删除本来不存在的新增路径：$path"
        fi
    done < "$manifest"

    systemctl daemon-reload 2>/dev/null || true
    restart_ssh_service false
    systemctl restart fail2ban 2>/dev/null || true
    systemctl restart systemd-journald 2>/dev/null || true
    systemctl restart docker 2>/dev/null || true
    ok "配置文件恢复完成。请重新检查服务状态。"
}

apt_update_once() {
    if [[ "$PKG_FAMILY" == "debian" && "$APT_UPDATED" -eq 0 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get update
        APT_UPDATED=1
    fi
}

pkg_install() {
    local packages=("$@")

    if [[ "$PKG_FAMILY" == "debian" ]]; then
        apt_update_once || return 1
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
    else
        "$PKG_MANAGER" install -y "${packages[@]}"
    fi
}

try_enable_epel() {
    [[ "$PKG_FAMILY" != "rhel" ]] && return 1

    if "$PKG_MANAGER" repolist 2>/dev/null | grep -qiE '(^|[[:space:]])epel([[:space:]/-]|$)'; then
        return 0
    fi

    info "尝试启用 EPEL 软件源，以安装 Fail2ban/Lynis 等软件。"
    "$PKG_MANAGER" install -y epel-release
}

restart_ssh_service() {
    local show_result="${1:-true}"
    local service_name=""

    if systemctl cat ssh.service >/dev/null 2>&1; then
        service_name="ssh"
    elif systemctl cat sshd.service >/dev/null 2>&1; then
        service_name="sshd"
    fi

    if [[ -z "$service_name" ]]; then
        [[ "$show_result" == "true" ]] && warn "未找到 ssh/sshd systemd 服务。"
        return 1
    fi

    if systemctl restart "$service_name"; then
        [[ "$show_result" == "true" ]] && ok "SSH 服务已重启：$service_name"
        return 0
    fi

    [[ "$show_result" == "true" ]] && err "SSH 服务重启失败：$service_name"
    return 1
}

get_ssh_port() {
    local port=""

    if command_exists sshd; then
        port="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')"
    fi

    if ! is_valid_port "$port"; then
        port="22"
    fi

    echo "$port"
}

get_sshd_binary() {
    if command_exists sshd; then
        command -v sshd
    elif [[ -x /usr/sbin/sshd ]]; then
        echo "/usr/sbin/sshd"
    else
        return 1
    fi
}

ensure_sshd_dropin() {
    local config="/etc/ssh/sshd_config"
    local dir="/etc/ssh/sshd_config.d"

    if [[ ! -f "$config" ]]; then
        err "未找到 $config，请先安装 OpenSSH Server。"
        return 1
    fi

    backup_file "$config"
    mkdir -p "$dir"

    # OpenSSH 对同一关键字采用先读取到的值；把 Include 放在文件开头，
    # 并使用 00- 前缀，确保本脚本的配置优先被读取。
    if ! grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf([[:space:]]|$)' "$config"; then
        local tmp
        tmp="$(mktemp)"
        {
            echo "Include /etc/ssh/sshd_config.d/*.conf"
            cat "$config"
        } > "$tmp"
        cat "$tmp" > "$config"
        rm -f "$tmp"
    fi
}

set_sshd_option() {
    local key="$1"
    local value="$2"
    local file="/etc/ssh/sshd_config.d/00-linux-security.conf"

    ensure_sshd_dropin || return 1
    backup_file "$file"
    touch "$file"
    chmod 600 "$file"

    if grep -Eiq "^[[:space:]]*${key}[[:space:]]+" "$file"; then
        sed -ri "s|^[[:space:]]*${key}[[:space:]]+.*|${key} ${value}|I" "$file"
    else
        echo "$key $value" >> "$file"
    fi
}

user_has_password() {
    local user="$1"
    local status=""
    status="$(passwd -S "$user" 2>/dev/null | awk '{print $2}')"
    [[ "$status" == "P" || "$status" == "PS" ]]
}

user_has_key() {
    local user="$1"
    local home=""
    home="$(getent passwd "$user" | cut -d: -f6)"
    [[ -n "$home" && -s "$home/.ssh/authorized_keys" ]]
}

user_is_admin() {
    local user="$1"
    id "$user" >/dev/null 2>&1 || return 1

    if [[ "$PKG_FAMILY" == "debian" ]]; then
        id -nG "$user" | tr ' ' '\n' | grep -qx sudo
    else
        id -nG "$user" | tr ' ' '\n' | grep -qx wheel
    fi
}

user_can_login() {
    local user="$1"
    [[ "$user" != "root" ]] || return 1
    user_is_admin "$user" || return 1
    user_has_password "$user" || user_has_key "$user"
}

get_safe_admin_user() {
    local candidate="${ADMIN_USER:-}"

    if [[ -n "$candidate" ]] && user_can_login "$candidate"; then
        echo "$candidate"
        return 0
    fi

    read_text candidate "请输入已经可以登录并拥有 sudo/wheel 权限的普通用户名（留空取消）: "
    if [[ -z "$candidate" ]]; then
        return 1
    fi

    if user_can_login "$candidate"; then
        ADMIN_USER="$candidate"
        echo "$candidate"
        return 0
    fi

    err "用户不存在、没有管理员权限，或没有密码/SSH 公钥登录方式：$candidate"
    return 1
}

open_firewall_port_if_active() {
    local port="$1"

    if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow "$port/tcp" || return 1
        info "已提前在 UFW 放行新 SSH 端口：$port/tcp"
    fi

    if command_exists firewall-cmd && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="$port/tcp" || return 1
        firewall-cmd --add-port="$port/tcp" || true
        info "已提前在 firewalld 放行新 SSH 端口：$port/tcp"
    fi
}

install_basic_tools() {
    section "1. 安装基础工具"

    if ! ask_yes_no "是否安装/补全基础管理和安全工具？"; then
        info "已跳过基础工具安装。"
        return 0
    fi

    if [[ "$PKG_FAMILY" == "debian" ]]; then
        pkg_install sudo curl wget ca-certificates openssh-server iproute2 lsof net-tools python3 cron logrotate
    else
        pkg_install sudo curl wget ca-certificates openssh-server iproute lsof net-tools python3 cronie logrotate
        systemctl enable --now crond 2>/dev/null || true
    fi

    ok "基础工具安装完成。"
}

create_admin_user() {
    section "2. 创建或配置管理员账号"

    if ! ask_yes_no "是否创建/配置普通管理员账号？"; then
        info "已跳过管理员账号设置；不会因此自动禁止 root 登录。"
        return 0
    fi

    local username=""
    local password1=""
    local password2=""
    local admin_group=""
    local home=""

    read_text username "请输入管理员用户名（留空跳过）: "
    if [[ -z "$username" ]]; then
        info "用户名为空，已跳过；不会禁止 root 登录。"
        return 0
    fi

    if [[ "$username" == "root" || ! "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        err "用户名格式不正确。只能使用小写字母、数字、下划线和短横线，且不能是 root。"
        return 1
    fi

    if id "$username" >/dev/null 2>&1; then
        info "用户已存在：$username"
        if ask_yes_no "是否重新设置该用户的密码？"; then
            read_secret password1 "请输入新密码（留空不修改）: "
            [[ -z "$password1" ]] && { info "密码为空，未修改密码。"; password1=""; }
            if [[ -n "$password1" ]]; then
                read_secret password2 "请再次输入新密码: "
                if [[ "$password1" != "$password2" ]]; then
                    err "两次密码不一致，未修改密码。"
                    return 1
                fi
                echo "$username:$password1" | chpasswd || return 1
                ok "密码已更新。"
            fi
        fi
    else
        read_secret password1 "请输入管理员密码（留空跳过创建）: "
        if [[ -z "$password1" ]]; then
            info "密码为空，已跳过创建；不会禁止 root 登录。"
            return 0
        fi

        read_secret password2 "请再次输入管理员密码: "
        if [[ "$password1" != "$password2" ]]; then
            err "两次密码不一致，已取消创建。"
            return 1
        fi

        if ! useradd -m -s /bin/bash "$username"; then
            err "创建用户失败。"
            return 1
        fi

        if ! echo "$username:$password1" | chpasswd; then
            userdel -r "$username" 2>/dev/null || true
            err "设置密码失败，已回滚新用户。"
            return 1
        fi
        ok "用户已创建：$username"
    fi

    if [[ "$PKG_FAMILY" == "debian" ]]; then
        admin_group="sudo"
    else
        admin_group="wheel"
    fi

    getent group "$admin_group" >/dev/null 2>&1 || groupadd "$admin_group"
    usermod -aG "$admin_group" "$username" || return 1

    home="$(getent passwd "$username" | cut -d: -f6)"
    mkdir -p "$home/.ssh"
    chmod 700 "$home/.ssh"
    touch "$home/.ssh/authorized_keys"
    chmod 600 "$home/.ssh/authorized_keys"
    chown -R "$username:$username" "$home/.ssh"

    if [[ -s /root/.ssh/authorized_keys ]] && ask_yes_no "是否把 root 的 authorized_keys 公钥复制给 $username？"; then
        cat /root/.ssh/authorized_keys >> "$home/.ssh/authorized_keys"
        awk '!seen[$0]++' "$home/.ssh/authorized_keys" > "$home/.ssh/authorized_keys.tmp"
        mv "$home/.ssh/authorized_keys.tmp" "$home/.ssh/authorized_keys"
        chmod 600 "$home/.ssh/authorized_keys"
        chown "$username:$username" "$home/.ssh/authorized_keys"
        ok "SSH 公钥已复制。"
    fi

    ADMIN_USER="$username"
    ok "管理员账号配置完成：$username（管理员组：$admin_group）"
    warn "请保持当前 SSH 会话不要退出，并另开窗口测试该账号。"
}

configure_ssh_security() {
    section "3. SSH 安全设置"

    if ! ask_yes_no "是否进入 SSH 安全设置？"; then
        info "已跳过 SSH 设置。"
        return 0
    fi

    local sshd_bin=""
    local current_port=""
    local new_port=""
    local safe_admin=""
    local main_temp=""
    local drop_temp=""
    local drop_existed=0
    local drop_file="/etc/ssh/sshd_config.d/00-linux-security.conf"

    sshd_bin="$(get_sshd_binary)" || {
        err "没有找到 sshd。请先选择 1 安装基础工具。"
        return 1
    }

    main_temp="$(mktemp)"
    cp -a /etc/ssh/sshd_config "$main_temp"
    drop_temp="$(mktemp)"
    if [[ -f "$drop_file" ]]; then
        cp -a "$drop_file" "$drop_temp"
        drop_existed=1
    fi

    current_port="$(get_ssh_port)"
    info "当前生效的 SSH 端口：$current_port"

    if ask_yes_no "是否修改 SSH 端口？"; then
        read_text new_port "请输入新 SSH 端口（1-65535，留空不修改）: "
        if [[ -z "$new_port" ]]; then
            info "端口为空，保持当前端口。"
        elif ! is_valid_port "$new_port"; then
            warn "端口不合法，保持当前端口。"
        elif [[ "$new_port" == "$current_port" ]]; then
            info "新端口与当前端口相同，不修改。"
        elif command_exists ss && ss -H -ltn "sport = :$new_port" 2>/dev/null | grep -q .; then
            warn "端口 $new_port 已被其他程序监听，未修改。"
        else
            if open_firewall_port_if_active "$new_port"; then
                set_sshd_option Port "$new_port"
                SSH_CHANGED=1
                current_port="$new_port"
                ok "已写入新 SSH 端口：$new_port"
                warn "脚本不会自动删除旧端口的防火墙规则，请测试新端口后再手动删除。"
            else
                err "无法提前放行新端口，已取消端口修改。"
            fi
        fi
    fi

    if ask_yes_no "是否禁止 root 远程 SSH 登录？"; then
        if safe_admin="$(get_safe_admin_user)"; then
            set_sshd_option PermitRootLogin no
            SSH_CHANGED=1
            ok "已设置禁止 root SSH 登录。备用管理员：$safe_admin"
        else
            warn "没有确认可登录的普通管理员，拒绝禁止 root，防止锁机。"
        fi
    fi

    if ask_yes_no "是否开启 SSH 基础增强（禁止空密码、限制尝试次数、空闲检测）？"; then
        set_sshd_option PermitEmptyPasswords no
        set_sshd_option MaxAuthTries 3
        set_sshd_option LoginGraceTime 30
        set_sshd_option ClientAliveInterval 300
        set_sshd_option ClientAliveCountMax 2
        set_sshd_option PubkeyAuthentication yes
        SSH_CHANGED=1
        ok "SSH 基础增强已写入。"
    fi

    if ask_yes_no "是否关闭 SSH 密码登录，只允许公钥？"; then
        if safe_admin="$(get_safe_admin_user)" && user_has_key "$safe_admin"; then
            set_sshd_option PubkeyAuthentication yes
            set_sshd_option PasswordAuthentication no
            set_sshd_option KbdInteractiveAuthentication no
            set_sshd_option ChallengeResponseAuthentication no
            SSH_CHANGED=1
            ok "已关闭密码认证。公钥用户：$safe_admin"
        else
            warn "未检测到该管理员的 authorized_keys 公钥，拒绝关闭密码登录。"
        fi
    fi

    if [[ "$SSH_CHANGED" -eq 0 ]]; then
        info "没有修改任何 SSH 配置。"
        rm -f "$main_temp" "$drop_temp"
        return 0
    fi

    if ! "$sshd_bin" -t; then
        err "SSH 配置检查失败，正在立即回滚。"
        cp -a "$main_temp" /etc/ssh/sshd_config
        if [[ "$drop_existed" -eq 1 ]]; then
            cp -a "$drop_temp" "$drop_file"
        else
            rm -f "$drop_file"
        fi
        "$sshd_bin" -t || err "回滚后 SSH 配置仍异常，请不要退出当前连接。"
        rm -f "$main_temp" "$drop_temp"
        return 1
    fi

    if ! restart_ssh_service true; then
        err "SSH 重启失败，正在回滚配置。"
        cp -a "$main_temp" /etc/ssh/sshd_config
        if [[ "$drop_existed" -eq 1 ]]; then
            cp -a "$drop_temp" "$drop_file"
        else
            rm -f "$drop_file"
        fi
        restart_ssh_service false || true
        rm -f "$main_temp" "$drop_temp"
        return 1
    fi

    rm -f "$main_temp" "$drop_temp"

    echo
    info "当前 SSH 关键生效配置："
    "$sshd_bin" -T 2>/dev/null | grep -E '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|maxauthtries|permitemptypasswords|clientaliveinterval|clientalivecountmax) ' || true
    warn "不要关闭当前 SSH 窗口。请先另开窗口测试新账号和新端口。"
}

parse_extra_ports() {
    # 将合法条目逐行输出。格式：3000/tcp,39000-40000/tcp,53/udp
    local input="$1"
    local item=""
    input="${input//,/ }"
    for item in $input; do
        if [[ "$item" =~ ^([0-9]{1,5})(-([0-9]{1,5}))?/(tcp|udp)$ ]]; then
            local first="${BASH_REMATCH[1]}"
            local second="${BASH_REMATCH[3]:-}"
            if ! is_valid_port "$first"; then
                warn "忽略无效端口：$item"
                continue
            fi
            if [[ -n "$second" ]]; then
                if ! is_valid_port "$second" || (( second < first )); then
                    warn "忽略无效端口范围：$item"
                    continue
                fi
            fi
            echo "$item"
        else
            warn "忽略格式错误的端口：$item"
        fi
    done
}

configure_firewall() {
    section "4. 防火墙设置"

    if ! ask_yes_no "是否安装并启用防火墙？"; then
        info "已跳过防火墙设置。"
        return 0
    fi

    local ssh_port="$(get_ssh_port)"
    local extra_input=""
    local entry=""
    local ufw_entry=""

    info "将首先放行当前 SSH 端口：$ssh_port/tcp，防止断开。"

    if [[ "$PKG_FAMILY" == "debian" ]]; then
        pkg_install ufw || return 1
        backup_file /etc/ufw

        ufw allow "$ssh_port/tcp" || return 1

        if ask_yes_no "是否开放网站端口 80/tcp 和 443/tcp？"; then
            ufw allow 80/tcp
            ufw allow 443/tcp
        fi

        read_text extra_input "请输入额外端口（留空不添加，例如 3000/tcp,39000-40000/tcp,53/udp）: "
        if [[ -n "$extra_input" ]]; then
            while IFS= read -r entry; do
                [[ -z "$entry" ]] && continue
                ufw_entry="${entry/-/:}"
                ufw allow "$ufw_entry"
            done < <(parse_extra_ports "$extra_input")
        fi

        ufw default deny incoming
        ufw default allow outgoing
        ufw --force enable
        ufw status verbose
    else
        pkg_install firewalld || return 1
        backup_file /etc/firewalld
        systemctl enable --now firewalld || return 1

        firewall-cmd --permanent --add-port="$ssh_port/tcp"
        firewall-cmd --add-port="$ssh_port/tcp" || true

        if ask_yes_no "是否开放网站服务 HTTP 和 HTTPS？"; then
            firewall-cmd --permanent --add-service=http
            firewall-cmd --permanent --add-service=https
        fi

        read_text extra_input "请输入额外端口（留空不添加，例如 3000/tcp,39000-40000/tcp,53/udp）: "
        if [[ -n "$extra_input" ]]; then
            while IFS= read -r entry; do
                [[ -z "$entry" ]] && continue
                firewall-cmd --permanent --add-port="$entry"
            done < <(parse_extra_ports "$extra_input")
        fi

        firewall-cmd --reload
        firewall-cmd --list-all
    fi

    ok "防火墙配置完成。"
    if command_exists docker; then
        warn "检测到 Docker。Docker 发布端口还会受到 Docker 自身网络规则影响，请结合 docker ps 检查公网端口。"
    fi
}

install_fail2ban_package() {
    if command_exists fail2ban-client; then
        return 0
    fi

    if pkg_install fail2ban; then
        return 0
    fi

    if [[ "$PKG_FAMILY" == "rhel" ]]; then
        try_enable_epel || true
        pkg_install fail2ban
        return $?
    fi

    return 1
}

configure_fail2ban() {
    section "5. Fail2ban SSH 防爆破"

    if ! ask_yes_no "是否安装并配置 Fail2ban？"; then
        info "已跳过 Fail2ban。"
        return 0
    fi

    install_fail2ban_package || {
        err "Fail2ban 安装失败。请检查系统软件源。"
        return 1
    }

    local ssh_port="$(get_ssh_port)"
    local maxretry=""
    local findtime=""
    local bantime=""
    local config="/etc/fail2ban/jail.d/99-linux-security.local"

    read_text maxretry "允许失败次数（留空使用 5）: "
    read_text findtime "统计时间窗口（留空使用 10m，例如 10m/1h）: "
    read_text bantime "封禁时间（留空使用 24h，例如 1h/24h/7d）: "

    [[ -z "$maxretry" ]] && maxretry="5"
    [[ -z "$findtime" ]] && findtime="10m"
    [[ -z "$bantime" ]] && bantime="24h"

    if ! is_integer "$maxretry" || (( maxretry < 1 || maxretry > 100 )); then
        warn "失败次数无效，改用 5。"
        maxretry="5"
    fi

    mkdir -p /etc/fail2ban/jail.d
    backup_file "$config"

    cat > "$config" <<EOF
# 由 Linux Security OneKey 管理
[DEFAULT]
bantime = $bantime
findtime = $findtime
maxretry = $maxretry

[sshd]
enabled = true
port = $ssh_port
EOF

    systemctl enable fail2ban || true
    if ! systemctl restart fail2ban; then
        err "Fail2ban 启动失败，最近日志如下："
        journalctl -u fail2ban -n 30 --no-pager 2>/dev/null || true
        return 1
    fi

    sleep 1
    fail2ban-client status sshd || true
    ok "Fail2ban 配置完成。"
}

configure_auto_updates() {
    section "6. 自动安全更新"

    if ! ask_yes_no "是否开启自动安装安全更新？"; then
        info "已跳过自动更新设置。"
        return 0
    fi

    if [[ "$PKG_FAMILY" == "debian" ]]; then
        pkg_install unattended-upgrades apt-listchanges || return 1
        backup_file /etc/apt/apt.conf.d/20auto-upgrades
        cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
        dpkg-reconfigure -f noninteractive unattended-upgrades || true
        systemctl enable --now unattended-upgrades 2>/dev/null || true
        ok "APT 自动安全更新已开启。"
    else
        if [[ "$PKG_MANAGER" == "dnf" ]]; then
            pkg_install dnf-automatic || return 1
            backup_file /etc/dnf/automatic.conf

            sed -ri 's/^[[:space:]]*upgrade_type[[:space:]]*=.*/upgrade_type = security/' /etc/dnf/automatic.conf
            sed -ri 's/^[[:space:]]*apply_updates[[:space:]]*=.*/apply_updates = yes/' /etc/dnf/automatic.conf

            if systemctl list-unit-files dnf-automatic-install.timer >/dev/null 2>&1; then
                systemctl enable --now dnf-automatic-install.timer
            else
                systemctl enable --now dnf-automatic.timer
            fi
            ok "DNF 自动安全更新已开启。"
        else
            pkg_install yum-cron || return 1
            backup_file /etc/yum/yum-cron.conf
            sed -ri 's/^[[:space:]]*update_cmd[[:space:]]*=.*/update_cmd = security/' /etc/yum/yum-cron.conf
            sed -ri 's/^[[:space:]]*apply_updates[[:space:]]*=.*/apply_updates = yes/' /etc/yum/yum-cron.conf
            systemctl enable --now yum-cron
            ok "YUM 自动安全更新已开启。"
        fi
    fi
}

configure_bbr() {
    section "7. BBR 网络优化"

    if ! ask_yes_no "是否尝试开启 TCP BBR？"; then
        info "已跳过 BBR。"
        return 0
    fi

    if ! command_exists sysctl; then
        err "系统缺少 sysctl。"
        return 1
    fi

    modprobe tcp_bbr 2>/dev/null || true

    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        warn "当前内核或虚拟化环境不支持 BBR，未修改。"
        return 1
    fi

    backup_file /etc/sysctl.d/99-linux-security-bbr.conf
    backup_file /etc/modules-load.d/bbr.conf

    cat > /etc/sysctl.d/99-linux-security-bbr.conf <<'EOF'
# 由 Linux Security OneKey 管理
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

    sysctl --system >/dev/null || {
        err "应用 BBR 参数失败。"
        return 1
    }

    info "当前队列算法：$(sysctl -n net.core.default_qdisc 2>/dev/null || echo 未知)"
    info "当前拥塞算法：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 未知)"
    ok "BBR 已配置。"
}

configure_swap() {
    section "8. Swap 交换空间"

    if ! ask_yes_no "是否创建新的 Swap 文件？"; then
        info "已跳过 Swap。"
        return 0
    fi

    local current_swap=""
    local size_gb=""
    local swapfile="/swapfile"
    local fs_type=""
    local swappiness=""

    current_swap="$(swapon --show --noheadings 2>/dev/null || true)"
    if [[ -n "$current_swap" ]]; then
        info "当前已经存在 Swap："
        swapon --show
        if ! ask_yes_no "是否仍然继续创建 /swapfile？"; then
            return 0
        fi
    fi

    if [[ -e "$swapfile" ]]; then
        warn "$swapfile 已存在，脚本不会覆盖。"
        return 1
    fi

    read_text size_gb "请输入 Swap 大小（GB，留空不创建，例如 2）: "
    if [[ -z "$size_gb" ]]; then
        info "大小为空，未创建 Swap。"
        return 0
    fi
    if ! is_integer "$size_gb" || (( size_gb < 1 || size_gb > 128 )); then
        err "Swap 大小必须是 1-128 的整数。"
        return 1
    fi

    fs_type="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
    if [[ "$fs_type" == "btrfs" ]]; then
        if command_exists btrfs && btrfs filesystem mkswapfile --help >/dev/null 2>&1; then
            btrfs filesystem mkswapfile --size "${size_gb}g" "$swapfile" || return 1
        else
            warn "根文件系统是 Btrfs，但当前 btrfs 工具不支持安全创建交换文件，已跳过。"
            return 1
        fi
    else
        if command_exists fallocate; then
            fallocate -l "${size_gb}G" "$swapfile" || dd if=/dev/zero of="$swapfile" bs=1M count="$((size_gb * 1024))" status=progress
        else
            dd if=/dev/zero of="$swapfile" bs=1M count="$((size_gb * 1024))" status=progress
        fi
        chmod 600 "$swapfile"
        mkswap "$swapfile" >/dev/null || { rm -f "$swapfile"; return 1; }
    fi

    chmod 600 "$swapfile"
    swapon "$swapfile" || { rm -f "$swapfile"; return 1; }

    backup_file /etc/fstab
    grep -qE '^/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

    read_text swappiness "请输入 vm.swappiness（0-100，留空保持当前值）: "
    if [[ -n "$swappiness" ]]; then
        if is_integer "$swappiness" && (( swappiness >= 0 && swappiness <= 100 )); then
            backup_file /etc/sysctl.d/99-linux-security-swap.conf
            echo "vm.swappiness = $swappiness" > /etc/sysctl.d/99-linux-security-swap.conf
            sysctl -w "vm.swappiness=$swappiness" >/dev/null
        else
            warn "swappiness 无效，未修改。"
        fi
    fi

    swapon --show
    free -h
    ok "Swap 创建完成。"
}

configure_docker_logs() {
    section "9. Docker 日志限制"

    if ! ask_yes_no "是否配置 Docker 容器日志轮转？"; then
        info "已跳过 Docker 日志设置。"
        return 0
    fi

    if ! command_exists docker || ! command_exists dockerd; then
        warn "没有检测到 Docker Engine，未修改。"
        return 0
    fi

    local max_size=""
    local max_file=""
    local config="/etc/docker/daemon.json"
    local previous_config=""
    local previous_existed=0

    read_text max_size "单个日志文件最大大小（留空不修改，例如 10m/100m）: "
    if [[ -z "$max_size" ]]; then
        info "大小为空，未修改 Docker。"
        return 0
    fi
    if [[ ! "$max_size" =~ ^[1-9][0-9]*[kKmMgG]$ ]]; then
        err "格式不正确，例如：10m、100m、1g。"
        return 1
    fi

    read_text max_file "最多保留文件数量（留空不修改，例如 3）: "
    if [[ -z "$max_file" ]]; then
        info "数量为空，未修改 Docker。"
        return 0
    fi
    if ! is_integer "$max_file" || (( max_file < 1 || max_file > 100 )); then
        err "文件数量必须是 1-100 的整数。"
        return 1
    fi

    mkdir -p /etc/docker
    backup_file "$config"
    previous_config="$(mktemp)"
    if [[ -f "$config" ]]; then
        cp -a "$config" "$previous_config"
        previous_existed=1
    fi

    if [[ -s "$config" ]] && ! python3 -m json.tool "$config" >/dev/null 2>&1; then
        rm -f "$previous_config"
        err "$config 不是合法 JSON，拒绝覆盖。请先手动修复。"
        return 1
    fi

    CONFIG_PATH="$config" MAX_SIZE="$max_size" MAX_FILE="$max_file" python3 <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["CONFIG_PATH"])
if path.exists() and path.stat().st_size:
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
else:
    data = {}

data["log-driver"] = "json-file"
opts = data.setdefault("log-opts", {})
opts["max-size"] = os.environ["MAX_SIZE"].lower()
opts["max-file"] = str(os.environ["MAX_FILE"])

with path.open("w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

    if dockerd --validate --config-file "$config" >/dev/null 2>&1; then
        ok "Docker 配置检查通过。"
    else
        err "Docker 配置检查失败，正在回滚。"
        if [[ "$previous_existed" -eq 1 ]]; then
            cp -a "$previous_config" "$config"
        else
            rm -f "$config"
        fi
        rm -f "$previous_config"
        return 1
    fi

    if ask_yes_no "是否现在重启 Docker？正在运行的容器可能短暂中断"; then
        if systemctl restart docker; then
            ok "Docker 已重启。"
        else
            err "Docker 重启失败，正在恢复原配置。"
            if [[ "$previous_existed" -eq 1 ]]; then
                cp -a "$previous_config" "$config"
            else
                rm -f "$config"
            fi
            systemctl restart docker 2>/dev/null || true
            rm -f "$previous_config"
            return 1
        fi
    else
        warn "尚未重启 Docker，新配置暂未生效。"
    fi

    rm -f "$previous_config"
    warn "默认日志配置通常只影响新建容器；已有容器可能需要重新创建。"
}

configure_journal_retention() {
    section "10. 系统日志保留限制"

    if ! ask_yes_no "是否限制 systemd journal 的保留时间和磁盘占用？"; then
        info "已跳过日志限制。"
        return 0
    fi

    local days=""
    local max_mb=""
    local config="/etc/systemd/journald.conf.d/99-linux-security.conf"

    read_text days "日志最多保留天数（留空不设置，例如 30）: "
    read_text max_mb "日志最大占用 MB（留空不设置，例如 500）: "

    if [[ -z "$days" && -z "$max_mb" ]]; then
        info "两个值都为空，未修改。"
        return 0
    fi

    if [[ -n "$days" ]] && { ! is_integer "$days" || (( days < 1 || days > 3650 )); }; then
        err "天数必须是 1-3650 的整数。"
        return 1
    fi
    if [[ -n "$max_mb" ]] && { ! is_integer "$max_mb" || (( max_mb < 50 || max_mb > 1048576 )); }; then
        err "最大占用必须是 50-1048576 MB 的整数。"
        return 1
    fi

    mkdir -p /etc/systemd/journald.conf.d
    backup_file "$config"
    {
        echo "# 由 Linux Security OneKey 管理"
        echo "[Journal]"
        [[ -n "$days" ]] && echo "MaxRetentionSec=${days}day"
        [[ -n "$max_mb" ]] && echo "SystemMaxUse=${max_mb}M"
    } > "$config"

    systemctl restart systemd-journald || return 1
    journalctl --disk-usage || true
    ok "系统日志限制已配置。"
}

install_lynis_package() {
    if command_exists lynis; then
        return 0
    fi

    if pkg_install lynis; then
        return 0
    fi

    if [[ "$PKG_FAMILY" == "rhel" ]]; then
        try_enable_epel || true
        pkg_install lynis
        return $?
    fi

    return 1
}

run_lynis_audit() {
    section "11. Lynis 安全审计"

    if ! ask_yes_no "是否安装并运行 Lynis 安全审计？"; then
        info "已跳过 Lynis。"
        return 0
    fi

    install_lynis_package || {
        err "Lynis 安装失败，请检查软件源。"
        return 1
    }

    if ask_yes_no "是否现在执行 lynis audit system --quick？可能需要几分钟"; then
        lynis audit system --quick || true
        ok "Lynis 扫描结束。详细报告通常位于 /var/log/lynis.log 和 /var/log/lynis-report.dat。"
    else
        info "Lynis 已安装，但没有运行扫描。"
    fi
}

run_rootkit_scan() {
    section "12. Rootkit 检测"

    if ! ask_yes_no "是否安装并运行 Rootkit 检测工具？"; then
        info "已跳过 Rootkit 检测。"
        return 0
    fi

    local installed=0

    if [[ "$PKG_FAMILY" == "debian" ]]; then
        apt_update_once || return 1
        if DEBIAN_FRONTEND=noninteractive apt-get install -y chkrootkit; then
            installed=1
        fi
    else
        try_enable_epel || true
        if "$PKG_MANAGER" install -y rkhunter; then
            installed=2
        fi
    fi

    if [[ "$installed" -eq 1 ]]; then
        warn "Rootkit 工具可能产生误报，结果需要人工核实。"
        chkrootkit || true
    elif [[ "$installed" -eq 2 ]]; then
        warn "Rootkit 工具可能产生误报，结果需要人工核实。"
        rkhunter --update || true
        rkhunter --check --skip-keypress || true
    else
        err "Rootkit 检测工具安装失败。"
        return 1
    fi
}

configure_daily_check() {
    section "13. 每日安全巡检"

    if ! ask_yes_no "是否创建每日安全巡检任务？"; then
        info "已跳过每日巡检。"
        return 0
    fi

    local threshold=""
    local script="/usr/local/sbin/linux-security-daily-check"
    local service="/etc/systemd/system/linux-security-daily-check.service"
    local timer="/etc/systemd/system/linux-security-daily-check.timer"

    read_text threshold "磁盘使用率告警阈值（百分比，留空使用 85）: "
    [[ -z "$threshold" ]] && threshold="85"
    if ! is_integer "$threshold" || (( threshold < 1 || threshold > 100 )); then
        warn "阈值无效，使用 85。"
        threshold="85"
    fi

    backup_file "$script"
    backup_file "$service"
    backup_file "$timer"

    cat > "$script" <<EOF
#!/usr/bin/env bash
set -o pipefail
REPORT_DIR="/var/log/linux-security/daily"
mkdir -p "\$REPORT_DIR"
REPORT="\$REPORT_DIR/\$(date +%F).log"
{
    echo "===== 每日安全巡检 \$(date '+%F %T') ====="
    echo
    echo "[磁盘]"
    df -h
    echo
    echo "[超过 ${threshold}% 的分区]"
    df -P | awk -v limit="$threshold" 'NR>1 {gsub(/%/,"",\$5); if (\$5+0 >= limit) print}'
    echo
    echo "[内存与 Swap]"
    free -h
    echo
    echo "[最近登录]"
    last -n 10 2>/dev/null || true
    echo
    echo "[最近 SSH 失败]"
    journalctl -u ssh -u sshd --since '24 hours ago' --no-pager 2>/dev/null | grep -Ei 'failed|invalid user|authentication failure' | tail -n 100 || true
    echo
    echo "[Fail2ban]"
    fail2ban-client status sshd 2>/dev/null || true
    echo
    echo "[监听端口]"
    ss -lntup 2>/dev/null || true
} > "\$REPORT" 2>&1
find "\$REPORT_DIR" -type f -name '*.log' -mtime +30 -delete
EOF
    chmod 700 "$script"

    cat > "$service" <<EOF
[Unit]
Description=Linux Security Daily Check

[Service]
Type=oneshot
ExecStart=$script
EOF

    cat > "$timer" <<'EOF'
[Unit]
Description=Run Linux Security Daily Check

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now linux-security-daily-check.timer
    systemctl start linux-security-daily-check.service || true
    systemctl list-timers linux-security-daily-check.timer --no-pager || true
    ok "每日巡检已开启，报告目录：/var/log/linux-security/daily/"
}

show_security_report() {
    section "14. 当前安全报告（只读）"

    local sshd_bin=""
    local ssh_port="$(get_ssh_port)"
    local root_login="未知"
    local password_login="未知"
    local pubkey_login="未知"

    sshd_bin="$(get_sshd_binary 2>/dev/null || true)"
    if [[ -n "$sshd_bin" ]]; then
        root_login="$($sshd_bin -T 2>/dev/null | awk '$1=="permitrootlogin"{print $2;exit}')"
        password_login="$($sshd_bin -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2;exit}')"
        pubkey_login="$($sshd_bin -T 2>/dev/null | awk '$1=="pubkeyauthentication"{print $2;exit}')"
    fi

    echo "系统：$OS_NAME"
    echo "内核：$(uname -r)"
    echo "包管理器：$PKG_MANAGER"
    echo "SSH 端口：$ssh_port"
    echo "root SSH：$root_login"
    echo "密码认证：$password_login"
    echo "公钥认证：$pubkey_login"
    echo

    echo "防火墙："
    if command_exists ufw; then
        ufw status 2>/dev/null | head -n 20 || true
    elif command_exists firewall-cmd; then
        systemctl is-active firewalld 2>/dev/null || true
        firewall-cmd --list-all 2>/dev/null || true
    else
        echo "未检测到 UFW/firewalld"
    fi

    echo
    echo "Fail2ban："
    if command_exists fail2ban-client; then
        fail2ban-client status sshd 2>/dev/null || systemctl status fail2ban --no-pager -l 2>/dev/null | head -n 20 || true
    else
        echo "未安装"
    fi

    echo
    echo "BBR："
    echo "可用算法：$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo 未知)"
    echo "当前算法：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 未知)"

    echo
    echo "Swap："
    swapon --show 2>/dev/null || true
    free -h 2>/dev/null || true

    echo
    echo "磁盘："
    df -h

    echo
    echo "监听端口："
    ss -lntup 2>/dev/null || netstat -lntup 2>/dev/null || true

    echo
    echo "最近登录："
    last -n 10 2>/dev/null || true

    echo
    echo "最近 SSH 失败记录："
    journalctl -u ssh -u sshd --since '24 hours ago' --no-pager 2>/dev/null | grep -Ei 'failed|invalid user|authentication failure' | tail -n 30 || true
}

restore_config_backup() {
    section "15. 恢复配置备份"

    if ! ask_yes_no "是否恢复以前的配置备份？"; then
        info "已取消恢复。"
        return 0
    fi

    local latest=""
    local selected=""
    local directory=""
    local -a candidates=()

    while IFS= read -r directory; do
        [[ -s "$directory/manifest.txt" ]] && candidates+=("$directory")
    done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)

    if [[ "${#candidates[@]}" -eq 0 ]]; then
        warn "没有找到包含配置文件的历史备份。"
        return 0
    fi
    latest="${candidates[0]}"

    echo "可用备份："
    printf '%s\n' "${candidates[@]}" | xargs -n1 basename | head -n 20
    echo
    info "最新备份：$(basename "$latest")"
    read_text selected "输入要恢复的备份名称（留空使用最新备份）: "
    [[ -z "$selected" ]] && selected="$(basename "$latest")"
    selected="$BACKUP_ROOT/$selected"

    if [[ ! -d "$selected" ]]; then
        err "备份目录不存在：$selected"
        return 1
    fi

    warn "恢复会覆盖当前相关配置。"
    if ask_yes_no "确认恢复 $selected？"; then
        restore_backup_directory "$selected"
    else
        info "已取消恢复。"
    fi
}

run_all_modules() {
    section "99. 全部模块"
    info "接下来会依次进入所有模块；每个模块仍需明确输入 y 才会修改。"
    install_basic_tools
    create_admin_user
    configure_ssh_security
    configure_firewall
    configure_fail2ban
    configure_auto_updates
    configure_bbr
    configure_swap
    configure_docker_logs
    configure_journal_retention
    run_lynis_audit
    run_rootkit_scan
    configure_daily_check
    show_security_report
}

show_menu() {
    echo
    line
    echo "$SCRIPT_NAME $VERSION"
    echo "系统：$OS_NAME"
    echo "包管理器：$PKG_MANAGER"
    echo "本次备份目录：$BACKUP_DIR"
    echo "本次日志：$LOG_FILE"
    line
    cat <<'MENU'
               By:豆浆与油条
         飞机:xhs_pp  
         QQ:289246620

功能是防止小黑客下手.功能已经测试很久了.安装了基本没事。
爆破可选次数，我默认3次 ，三次 不对封ip
防端口22 注入。
禁止root 爆破登录。禁止后，可通过 (ssh 你的用户名@您服务器ip)括号是执行命令登录命令

首要还是防路径穿透。扫描。可用Nginx 设置。py 可用入口设置。具体可问ai 

做到以上几点基本无从下手了。 爆破还是要花很多ip的 这是一笔费用。小黑客 基本不会死磕，

如果是很贵重的东西, 你可以vps 做虚拟。隐藏真实服务器。 这个最好是同机房。速度才不影响

 
 1. 安装基础工具
 2. 创建/配置普通管理员账号
 3. SSH 安全设置
 4. 防火墙设置
 5. Fail2ban SSH 防爆破
 6. 自动安全更新
 7. 开启 BBR 网络优化
 8. 创建 Swap 交换空间
 9. Docker 日志轮转限制
10. 系统日志保留限制
11. Lynis 安全审计
12. Rootkit 检测
13. 每日安全巡检
14. 查看当前安全报告（只读）
15. 恢复历史配置备份
99. 全部依次执行（每项仍然询问 y/N）
 0. 退出

可以一次输入多个编号，用空格或逗号分隔，例如：1 2 4 5
菜单只显示一次，执行完成后自动退出。
MENU
    line
}

main() {
    local choices=""
    local choice=""
    local normalized=""

    echo "============================================================"
    echo " $SCRIPT_NAME $VERSION"
    echo "============================================================"
    echo "当前系统：$OS_NAME"
    echo
    warn "本脚本不能替代系统升级、应用安全、数据库安全和异地备份。"
    warn "进行 SSH/防火墙修改时，请保持当前连接，不要提前退出。"

    if [[ "$OS_ID" == "centos" && "${VERSION_ID%%.*}" == "7" ]]; then
        warn "检测到 CentOS 7。该系统已停止常规维护，不建议继续用于公网生产环境。"
        if ! ask_yes_no "仍要继续运行脚本？"; then
            exit 0
        fi
    fi

    show_menu
    read_text choices "请输入功能编号（留空直接退出）: "

    if [[ -z "$choices" ]]; then
        info "没有选择功能，脚本结束。"
        exit 0
    fi

    normalized="${choices//,/ }"

    for choice in $normalized; do
        case "$choice" in
            0)  info "已选择退出。"; break ;;
            1)  install_basic_tools ;;
            2)  create_admin_user ;;
            3)  configure_ssh_security ;;
            4)  configure_firewall ;;
            5)  configure_fail2ban ;;
            6)  configure_auto_updates ;;
            7)  configure_bbr ;;
            8)  configure_swap ;;
            9)  configure_docker_logs ;;
            10) configure_journal_retention ;;
            11) run_lynis_audit ;;
            12) run_rootkit_scan ;;
            13) configure_daily_check ;;
            14) show_security_report ;;
            15) restore_config_backup ;;
            99) run_all_modules ;;
            *)  warn "忽略未知编号：$choice" ;;
        esac
    done

    echo
    line
    echo "执行结束。"
    echo "日志文件：$LOG_FILE"
    echo "配置备份：$BACKUP_DIR"
    line

    if [[ "$SSH_CHANGED" -eq 1 ]]; then
        warn "SSH 配置已修改。请保持当前窗口，另开窗口测试登录成功后再退出。"
    fi
}

main "$@"
