#!/bin/bash
# =========================================
# Trojan 一键安装脚本（自动 Docker + MariaDB + 证书）
# 支持安装 / 卸载，只需输入域名即可完成全自动部署
# =========================================

set -e

red="31m"; green="32m"; yellow="33m"; blue="36m"; fuchsia="35m"
colorEcho(){ echo -e "\033[${1}${@:2}\033[0m"; }

# === 核心配置 ===
DB_USER="adminaa"
DB_PASS="wf1234567"
DB_NAME="trojan"
ADMIN_USER="adminaa"
ADMIN_PASS="wf1234567"
TROJAN_PORT=443
CERT_PROVIDER="letsencrypt"

download_url="https://github.com/Jrohy/trojan/releases/download"
version_check="https://api.github.com/repos/Jrohy/trojan/releases/latest"
service_url="https://raw.githubusercontent.com/Jrohy/trojan/master/asset/trojan-web.service"

# === 函数 ===
checkSys(){
    [ $(id -u) != "0" ] && { colorEcho ${red} "请以 root 用户运行脚本"; exit 1; }
    if command -v apt-get >/dev/null; then
        package_manager='apt-get'
    elif command -v dnf >/dev/null; then
        package_manager='dnf'
    elif command -v yum >/dev/null; then
        package_manager='yum'
    else
        colorEcho ${red} "不支持的系统"; exit 1
    fi
}

installDependent(){
    colorEcho ${blue} "安装依赖（docker、acme.sh、curl 等）..."
    if [[ ${package_manager} == "dnf" || ${package_manager} == "yum" ]]; then
        ${package_manager} install -y epel-release
        ${package_manager} install -y socat crontabs bash-completion curl wget
        ${package_manager} install -y docker
    else
        ${package_manager} update -y
        ${package_manager} install -y socat cron bash-completion curl wget xz-utils docker.io
    fi
    systemctl enable docker && systemctl start docker
}

readDomain(){
    read -p "请输入你的域名 (example.com): " DOMAIN
    DOMAIN="${DOMAIN// /}"
    if [[ -z "$DOMAIN" ]]; then
        colorEcho ${red} "域名不能为空"
        exit 1
    fi
}

installMariaDB(){
    colorEcho ${blue} "安装 Docker 版 MariaDB..."
    docker rm -f trojan-mariadb >/dev/null 2>&1 || true
    mkdir -p /home/mariadb
    docker run -d \
        --name trojan-mariadb \
        -p 3306:3306 \
        -v /home/mariadb:/var/lib/mysql \
        -e MYSQL_ROOT_PASSWORD=${DB_PASS} \
        -e MYSQL_DATABASE=${DB_NAME} \
        -e MYSQL_USER=${DB_USER} \
        -e MYSQL_PASSWORD=${DB_PASS} \
        --restart always mariadb:latest >/dev/null
    sleep 10
    colorEcho ${green} "MariaDB 已启动 → 数据库:${DB_NAME} 用户:${DB_USER} 密码:${DB_PASS}"
}

installAcme(){
    if [[ ! -d /root/.acme.sh ]]; then
        colorEcho ${blue} "安装 acme.sh..."
        curl https://get.acme.sh | sh
    fi
    colorEcho ${blue} "申请 TLS 证书（Let's Encrypt）..."
    ~/.acme.sh/acme.sh --issue -d ${DOMAIN} --standalone --force
    ~/.acme.sh/acme.sh --install-cert -d ${DOMAIN} \
        --fullchain-file /root/.acme.sh/${DOMAIN}/${DOMAIN}.cer \
        --key-file /root/.acme.sh/${DOMAIN}/${DOMAIN}.key \
        --reloadcmd "systemctl restart trojan-web" >/dev/null
    colorEcho ${green} "证书申请成功。"
}

installTrojan(){
    colorEcho ${blue} "下载 Trojan 管理程序..."
    lastest_version=$(curl -s "${version_check}" | grep '"tag_name"' | cut -d\" -f4)
    [[ -z "$lastest_version" ]] && lastest_version="latest"
    [[ $(uname -m) == "x86_64" ]] && bin="trojan-linux-amd64" || bin="trojan-linux-arm64"
    curl -L "${download_url}/${lastest_version}/${bin}" -o /usr/local/bin/trojan
    chmod +x /usr/local/bin/trojan

    mkdir -p /usr/local/etc/trojan
    cat > /usr/local/etc/trojan/config.json <<EOF
{
  "domain": "${DOMAIN}",
  "cert_provider": "${CERT_PROVIDER}",
  "certs": {
    "fullchain": "/root/.acme.sh/${DOMAIN}/${DOMAIN}.cer",
    "privkey": "/root/.acme.sh/${DOMAIN}/${DOMAIN}.key"
  },
  "port": ${TROJAN_PORT},
  "users": [
    {
      "username": "${ADMIN_USER}",
      "password": "${ADMIN_PASS}",
      "remark": "admin"
    }
  ],
  "admin": {
    "username": "${ADMIN_USER}",
    "password": "${ADMIN_PASS}"
  },
  "database": {
    "type": "mysql",
    "host": "127.0.0.1",
    "port": 3306,
    "user": "${DB_USER}",
    "password": "${DB_PASS}",
    "name": "${DB_NAME}"
  }
}
EOF

    curl -L ${service_url} -o /etc/systemd/system/trojan-web.service
    systemctl daemon-reload
    systemctl enable trojan-web
    systemctl restart trojan-web

    SHARE_LINK="trojan://${ADMIN_PASS}@${DOMAIN}:${TROJAN_PORT}"
    OPENCLASH_ENTRY="- {name: ${DOMAIN}, server: ${DOMAIN}, port: ${TROJAN_PORT}, type: trojan, password: ${ADMIN_PASS}}"

    colorEcho ${fuchsia} "\n===== 安装完成 ====="
    echo "管理后台: https://${DOMAIN}"
    echo "管理员账号: ${ADMIN_USER}"
    echo "管理员密码: ${ADMIN_PASS}"
    echo "数据库账号: ${DB_USER}"
    echo "数据库密码: ${DB_PASS}"
    echo
    colorEcho ${green} "Trojan 链接: ${SHARE_LINK}"
    echo "${OPENCLASH_ENTRY}"
    echo "====================="
}

uninstallTrojan(){
    colorEcho ${yellow} "正在卸载 Trojan 与数据库..."
    systemctl stop trojan-web >/dev/null 2>&1 || true
    systemctl disable trojan-web >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/trojan-web.service
    rm -rf /usr/local/etc/trojan /usr/local/bin/trojan
    docker rm -f trojan-mariadb >/dev/null 2>&1 || true
    rm -rf /home/mariadb
    systemctl daemon-reload
    colorEcho ${green} "卸载完成 ✅"
}

# === 主菜单 ===
echo "==============================="
echo " Trojan 一键安装管理脚本"
echo "==============================="
echo "1) 安装 Trojan"
echo "2) 卸载 Trojan"
echo "==============================="
read -p "请输入数字 [1-2]: " num

case "$num" in
1)
    readDomain
    checkSys
    installDependent
    installMariaDB
    installAcme
    installTrojan
    ;;
2)
    uninstallTrojan
    ;;
*)
    echo "输入无效"
    ;;
esac
