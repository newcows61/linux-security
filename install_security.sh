#!/bin/bash

# Linux Security OneKey V3
# Ubuntu Debian CentOS Rocky Alma Fedora


set -e


if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 执行"
    exit 1
fi


echo "================================="
echo " Linux Security OneKey V3"
echo "================================="



############################
# 系统检测
############################


if [ -f /etc/os-release ]; then

source /etc/os-release

else

echo "无法识别系统"
exit 1

fi


echo "系统:"
echo "$PRETTY_NAME"



############################
# 包管理
############################


if command -v apt >/dev/null 2>&1; then

PM="apt"

elif command -v dnf >/dev/null 2>&1; then

PM="dnf"

elif command -v yum >/dev/null 2>&1; then

PM="yum"

else

echo "不支持的软件管理器"
exit 1

fi


echo "包管理:"
echo "$PM"



############################
# 安装软件
############################


echo
echo "[1] 安装安全组件"


if [ "$PM" = "apt" ]; then


apt update -y


apt install -y \
sudo \
curl \
wget \
ufw \
fail2ban \
unattended-upgrades



else


$PM install -y \
sudo \
curl \
wget \
firewalld \
fail2ban


fi



############################
# 创建管理员
############################


CREATE_USER_OK=false
ADMIN=""
ADMIN_PASS=""


# 获取命令参数

if [ ! -z "$1" ]; then

    ADMIN="$1"

fi


if [ ! -z "$2" ]; then

    ADMIN_PASS="$2"

fi



echo

read -p "请输入管理员用户名(留空跳过): " ADMIN


if [ -z "$ADMIN" ]; then


echo "未输入用户名"
echo "跳过创建管理员"



else


read -s -p "请输入管理员密码(留空跳过): " ADMIN_PASS

echo



if [ -z "$ADMIN_PASS" ]; then


echo "未输入密码"
echo "跳过创建管理员"



else



if id "$ADMIN" >/dev/null 2>&1; then


echo "用户已经存在"


else


echo "创建用户 $ADMIN"


useradd \
-m \
-s /bin/bash \
"$ADMIN"


echo "$ADMIN:$ADMIN_PASS" | chpasswd



fi



# sudo

if [ "$PM" = "apt" ]; then


usermod -aG sudo "$ADMIN"


else


usermod -aG wheel "$ADMIN"


fi



CREATE_USER_OK=true


echo "管理员创建成功"



fi


fi



############################
# SSH配置
############################


SSH_CONFIG="/etc/ssh/sshd_config"


cp "$SSH_CONFIG" \
"$SSH_CONFIG.backup.$(date +%F-%H%M)"



SSH_PORT=$(grep "^Port " "$SSH_CONFIG" | awk '{print $2}')



if [ -z "$SSH_PORT" ]; then

SSH_PORT=22

fi



echo

echo "当前SSH端口:$SSH_PORT"



read -p "是否修改SSH端口?(y/n): " CHANGE



if [ "$CHANGE" = "y" ]; then


read -p "输入新SSH端口:" NEWPORT


if [ ! -z "$NEWPORT" ]; then


sed -i '/^Port /d' "$SSH_CONFIG"


echo "Port $NEWPORT" >> "$SSH_CONFIG"


SSH_PORT=$NEWPORT


fi


fi



# root控制

if [ "$CREATE_USER_OK" = true ]; then



echo "管理员存在"

echo "禁止root SSH"



sed -i '/^PermitRootLogin/d' "$SSH_CONFIG"


echo "PermitRootLogin no" >> "$SSH_CONFIG"


ROOT_STATUS="已禁止"



else



echo "没有管理员"

echo "保持root SSH"



ROOT_STATUS="保持开启"



fi




# SSH Key

sed -i '/^PubkeyAuthentication/d' "$SSH_CONFIG"

echo "PubkeyAuthentication yes" >> "$SSH_CONFIG"



############################
# 防火墙
############################


echo

echo "[2] 配置防火墙"



if command -v ufw >/dev/null; then



ufw default deny incoming

ufw default allow outgoing


ufw allow "$SSH_PORT"/tcp

ufw allow 80/tcp

ufw allow 443/tcp


ufw --force enable



elif command -v firewall-cmd >/dev/null; then



systemctl enable firewalld

systemctl start firewalld



firewall-cmd \
--permanent \
--add-port="$SSH_PORT/tcp"



firewall-cmd \
--permanent \
--add-port=80/tcp



firewall-cmd \
--permanent \
--add-port=443/tcp



firewall-cmd --reload



fi




############################
# Fail2ban
############################


echo

echo "[3] 配置Fail2ban"



mkdir -p /etc/fail2ban



cat > /etc/fail2ban/jail.local <<EOF


[DEFAULT]

bantime = 24h
findtime = 10m
maxretry = 5



[sshd]

enabled = true
port = $SSH_PORT


EOF



systemctl enable fail2ban

systemctl restart fail2ban




############################
# 自动更新
############################


if [ "$PM" = "apt" ]; then


dpkg-reconfigure \
-f noninteractive \
unattended-upgrades || true


fi




############################
# SSH目录
############################


if [ "$CREATE_USER_OK" = true ]; then



mkdir -p /home/$ADMIN/.ssh


chown -R $ADMIN:$ADMIN \
/home/$ADMIN/.ssh


chmod 700 \
/home/$ADMIN/.ssh



fi





############################
# 重启SSH
############################


systemctl restart sshd 2>/dev/null || \
systemctl restart ssh





############################
# 输出报告
############################


echo

echo "================================"
echo " 安装完成"
echo "================================"



echo

echo "系统:"
echo "$PRETTY_NAME"


echo

echo "管理员:"
if [ "$CREATE_USER_OK" = true ]; then

echo "$ADMIN"

else

echo "未创建"

fi



echo

echo "SSH端口:"
echo "$SSH_PORT"



echo

echo "root SSH:"
echo "$ROOT_STATUS"



echo

echo "防爆破:"
fail2ban-client status sshd || true



echo

echo "完成"

echo

echo "注意:"
echo "如果创建了管理员，请测试:"
echo

if [ "$CREATE_USER_OK" = true ]; then

echo "ssh $ADMIN@服务器IP -p $SSH_PORT"

fi
