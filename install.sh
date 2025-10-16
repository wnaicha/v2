#!/bin/bash
# install-trojan.sh
# 一键安装脚本：Docker MariaDB + acme.sh Let’s Encrypt + trojan 管理程序
# 作者：ChatGPT（改自 Jrohy 脚本 + 你要求的自动化）

help=0
remove=0
update=0

download_url="https://github.com/Jrohy/trojan/releases/download"
version_check="https://api.github.com/repos/Jrohy/trojan/releases/latest"
service_url="https://raw.githubusercontent.com/Jrohy/trojan/master/asset/trojan-web.service"

[[ -e /var/lib/trojan-manager ]] && update=1

[[ -f /etc/redhat-release && -z $(echo $SHELL|grep zsh) ]] && unalias -a
[[ -z $(echo $SHELL|grep zsh) ]] && shell_way="bash" || shell_way="zsh"

red="31m"; green="32m"; yellow="33m"; blue="36m"; fuchsia="35m"
colorEcho(){ echo -e "\033[${1}${@:2}\033[0m"; }

while [[ $# > 0 ]]; do
    case $1 in
        --remove) remove=1 ;;
        -h|--help) help=1 ;;
    esac
    shift
done

help(){
    echo "bash $0 [--remove]"
    echo "  --remove    卸载 trojan（包括 Docker 容器 MariaDB）"
}

removeTrojan(){
    colorEcho ${yellow} "开始卸载 trojan 与 MariaDB ..."
    docker rm -f trojan-mariadb >/dev/null 2>&1
    rm -rf /home/mariadb
    rm -rf /usr/local/etc/trojan /usr/local/bin/trojan /var/lib/trojan-manager
    rm -f /etc/systemd/system/trojan-web.service
    systemctl daemon-reload
    colorEcho ${green} "卸载完成。"
}

checkSys(){
    [ $(id -u) != "0" ] && { colorEcho ${red} "请以 root 用户运行脚本"; exit 1; }
    arch=$(uname -m)
    if [[ "$arch" != "x86_64" && "$arch" != "aarch64" ]]; then
        colorEcho ${red} "不支持的架构: $arch"; exit 1
    fi
    if command -v apt-get >/dev/null; then
        package_manager='apt-get'
    elif command -v dnf >/dev/null; then
        package_manager='dnf'
    elif command -v yum >/dev/null; then
        package_manager='yum'
    else
        colorEcho ${red} "不支持当前 OS"; exit 1
    fi
}

installDependent(){
    colorEcho ${blue} "安装必需依赖（包括 Docker）..."
    if [[ ${package_manager} == "dnf" || ${package_manager} == "yum" ]]; then
        ${package_manager} install -y socat crontabs bash-completion epel-release
        ${package_manager} install -y docker
    else
        ${package_manager} update -y
        ${package_manager} install -y socat cron bash-completion xz-utils
        ${package_manager} install -y docker.io
    fi
    systemctl enable docker && systemctl start docker
}

setupCron(){
    # 每天凌晨执行 acme.sh 更新证书（如果已安装）
    (crontab -l 2>/dev/null | grep -v acme.sh; echo "0 3 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh > /dev/null") | crontab -
}

readDomainAndPrepare(){
    while true; do
        read -p "请输入你的域名 (example.com) : " DOMAIN
        DOMAIN="${DOMAIN// /}"
        if [[ -n "$DOMAIN" ]]; then
            break
        fi
    done
    CERT_PROVIDER="letsencrypt"
    DB_USER="adminaa"
    DB_PASS="wf1234567"
    DB_NAME="trojan"
    ADMIN_USER="adminaa"
    ADMIN_PASS="wf1234567"
    TROJAN_PORT=443
}

installMariaDB(){
    colorEcho ${blue} "部署 Docker MariaDB 容器..."
    docker rm -f trojan-mariadb >/dev/null 2>&1
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
    colorEcho ${green} "MariaDB 容器启动完成。数据库: ${DB_NAME}, 用户: ${DB_USER}, 密码: ${DB_PASS}"
}

installAcme(){
    # 安装 acme.sh 并用它为域名签发证书
    if [[ ! -d /root/.acme.sh ]]; then
        colorEcho ${blue} "安装 acme.sh..."
        curl https://get.acme.sh | sh
    fi
    # 用 acme.sh 签发证书（使用 webroot 模式，监听在 80 端口）
    ~/.acme.sh/acme.sh --issue -d ${DOMAIN} --standalone --force
    if [[ $? -ne 0 ]]; then
        colorEcho ${red} "证书申请失败，请检查 80 端口是否被占用或防火墙设置"
        exit 1
    fi
    ~/.acme.sh/acme.sh --install-cert -d ${DOMAIN} \
        --fullchain-file /root/.acme.sh/${DOMAIN}/${DOMAIN}.cer \
        --key-file /root/.acme.sh/${DOMAIN}/${DOMAIN}.key --reloadcmd "systemctl restart trojan-web"
    colorEcho ${green} "证书签发并安装成功"
}

installTrojan(){
    local show_tip=0
    if [[ $update == 1 ]]; then
        systemctl stop trojan-web >/dev/null 2>&1
        rm -f /usr/local/bin/trojan
    fi

    lastest_version=$(curl -H 'Cache-Control: no-cache' -s "${version_check}" | grep '"tag_name"' | cut -d\" -f4)
    [[ -z "$lastest_version" ]] && lastest_version="latest"
    colorEcho ${blue} "下载 trojan 管理程序版本 ${lastest_version} ..."
    [[ $(uname -m) == "x86_64" ]] && bin="trojan-linux-amd64" || bin="trojan-linux-arm64"
    curl -L "${download_url}/${lastest_version}/${bin}" -o /usr/local/bin/trojan
    chmod +x /usr/local/bin/trojan

    if [[ ! -e /etc/systemd/system/trojan-web.service ]]; then
        curl -L ${service_url} -o /etc/systemd/system/trojan-web.service
        systemctl daemon-reload
        systemctl enable trojan-web
        show_tip=1
    fi

    mkdir -p /usr/local/etc/trojan
    CONFIG_FILE="/usr/local/etc/trojan/config.json"

    cat > "${CONFIG_FILE}" <<EOF
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

    colorEcho ${green} "trojan 配置写入 ${CONFIG_FILE}"

    # 启动 trojan 管理程序（如支持命令启动）
    /usr/local/bin/trojan || true
    systemctl restart trojan-web

    setupCron

    if [[ $show_tip == 1 ]]; then
        echo "浏览器访问: https://${DOMAIN} 查看管理后台"
    fi

    SHARE_LINK="trojan://${ADMIN_PASS}@${DOMAIN}:${TROJAN_PORT}"
    OPENCLASH_ENTRY="- {name: ${DOMAIN}, server: ${DOMAIN}, port: ${TROJAN_PORT}, type: trojan, password: ${ADMIN_PASS}}"

    echo
    colorEcho ${fuchsia} "==== 安装完成 ===="
    echo "管理员账号 : ${ADMIN_USER}"
    echo "管理员密码 : ${ADMIN_PASS}"
    echo "数据库用户 : ${DB_USER}"
    echo "数据库密码 : ${DB_PASS}"
    echo
    colorEcho ${green} "Trojan 分享链接 :"
    echo "${SHARE_LINK}"
    echo
    colorEcho ${green} "OpenClash 配置行 :"
    echo "${OPENCLASH_ENTRY}"
    echo "=================="
}

main(){
    [[ ${help} == 1 ]] && help && return
    [[ ${remove} == 1 ]] && removeTrojan && return

    colorEcho ${blue} "开始一键安装 Trojan 管理程序 + MariaDB + Let's Encrypt"
    readDomainAndPrepare
    checkSys
    installDependent
    installMariaDB
    installAcme
    installTrojan
}

main
