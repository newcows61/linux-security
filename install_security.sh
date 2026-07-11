#!/bin/bash

# ======================================
# Linux Security OneKey V5
# Linux服务器安全初始化工具
#
# 支持:
# Ubuntu Debian CentOS Rocky Alma Fedora
#
# ======================================


set +e


if [ "$EUID" != "0" ]; then
    echo "请使用 root 执行"
    exit 1
fi


VERSION="V5.0"


clear


echo "===================================="
echo " Linux Security OneKey $VERSION"
echo "===================================="



############################
# 系统检测
############################


if [ -f /etc/os-release ]; then

source /etc/os-release

else

echo "无法识别系统"

exit 1

fi



echo
echo "系统:"
echo "$PRETTY_NAME"



############################
# 包管理
############################


if command -v apt >/dev/null 2>&1
then

PM="apt"


elif command -v dnf >/dev/null 2>&1
then

PM="dnf"


elif command -v yum >/dev/null 2>&1
then

PM="yum"


else

echo "不支持系统"

exit 1

fi



echo "包管理:"
echo "$PM"



############################
# 全局变量
############################


ADMIN=""

CREATE_USER_OK=false

SSH_CONFIG="/etc/ssh/sshd_config"

SSH_PORT=22



############################
# 创建管理员
############################


create_admin(){


echo
echo "================================"
echo " 创建管理员账号"
echo "================================"



read -p "是否创建管理员?(y/n): " CHOICE



if [[ "$CHOICE" != "y" && "$CHOICE" != "Y" ]]
then

echo "跳过"

return

fi



read -p "请输入用户名(空跳过): " ADMIN



if [ -z "$ADMIN" ]
then

echo "用户名为空"

return

fi



read -s -p "请输入密码(空跳过): " PASS

echo



if [ -z "$PASS" ]
then

echo "密码为空"

return

fi



if id "$ADMIN" >/dev/null 2>&1
then

echo "用户已存在"

else


useradd \
-m \
-s /bin/bash \
"$ADMIN"



echo "$ADMIN:$PASS" | chpasswd


fi



if [ "$PM" = "apt" ]
then

usermod -aG sudo "$ADMIN"

else

usermod -aG wheel "$ADMIN"

fi



CREATE_USER_OK=true


echo
echo "管理员创建成功:"
echo "$ADMIN"



}



############################
# SSH设置
############################


ssh_security(){


echo
echo "================================"
echo " SSH安全设置"
echo "================================"



cp "$SSH_CONFIG" \
"$SSH_CONFIG.backup.$(date +%F-%H%M)"


SSH_PORT=$(grep "^Port " "$SSH_CONFIG" | awk '{print $2}')


if [ -z "$SSH_PORT" ]
then

SSH_PORT=22

fi



echo "当前SSH端口:$SSH_PORT"



read -p "是否修改SSH端口?(y/n): " C



if [[ "$C" == "y" || "$C" == "Y" ]]
then


read -p "输入新端口:" NEWPORT


if [ ! -z "$NEWPORT" ]
then


sed -i '/^Port /d' "$SSH_CONFIG"

echo "Port $NEWPORT" >> "$SSH_CONFIG"


SSH_PORT=$NEWPORT


fi


fi




if [ "$CREATE_USER_OK" = true ]
then


read -p "是否禁止root登录?(y/n): " R


if [[ "$R" == "y" || "$R" == "Y" ]]
then


sed -i '/^PermitRootLogin/d' "$SSH_CONFIG"


echo "PermitRootLogin no" >> "$SSH_CONFIG"


echo "root登录已关闭"


fi


else


echo "未创建管理员"
echo "保持root登录"



fi



read -p "是否开启SSH增强?(y/n): " S



if [[ "$S" == "y" || "$S" == "Y" ]]
then


sed -i '/^PermitEmptyPasswords/d' "$SSH_CONFIG"

echo "PermitEmptyPasswords no" >> "$SSH_CONFIG"


sed -i '/^MaxAuthTries/d' "$SSH_CONFIG"

echo "MaxAuthTries 3" >> "$SSH_CONFIG"


echo "SSH增强完成"


fi



sshd -t


systemctl restart sshd 2>/dev/null || systemctl restart ssh



}



############################
# 主菜单
############################


menu(){


while true

do


clear


echo "===================================="
echo " Linux Security OneKey $VERSION"
echo "===================================="


echo

echo "1. 创建管理员账号"

echo "2. SSH安全加固"

echo "3. 防火墙设置"

echo "4. Fail2ban防爆破"

echo "5. BBR网络优化"

echo "6. 创建Swap"

echo "7. Docker优化"

echo "8. Lynis安全检测"

echo "9. 日志清理"

echo "10. 全部执行"

echo "0. 退出"


echo


read -p "请选择:" NUM



case $NUM in


1)

create_admin

;;


2)

ssh_security

;;


10)

create_admin
ssh_security

;;


0)

exit 0

;;


*)

echo "无效选择"

;;

esac


echo

read -p "按回车继续..."


done


}


menu
