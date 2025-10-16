#!/bin/bash
# Modified by ChatGPT
# Default: Let's Encrypt + Docker MariaDB + automatic trojan-web setup
# Only input domain required.

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

while [[ $# > 0 ]];do
    case $1 in
        --remove) remove=1 ;;
        -h|--help) help=1 ;;
    esac
    shift
done

help(){
    echo "bash $0 [--remove]"
    echo "  --remove    Uninstall trojan"
}

removeTrojan() {
    docker rm -f trojan-mariadb >/dev/null 2>&1
    rm -rf /home/mariadb >/dev/null 2>&1
    rm -rf /usr/local/etc/trojan /usr/local/bin/trojan /var/lib/trojan-manager
    rm -f /etc/systemd/system/trojan-web.service
    systemctl daemon-reload
    colorEcho ${green} "uninstall success!"
}

checkSys() {
    [ $(id -u) != "0" ] && { colorEcho ${red} "请使用root权限运行"; exit 1; }
    arch=$(uname -m)
    if [[ $arch != x86_64 && $arch != aarch64 ]];then
        colorEcho $yellow "不支持的架构: $arch"; exit 1
    fi
    if command -v apt-get >/dev/null; then
        package_manager='apt-get'
    elif command -v dnf >/dev/null; then
        package_manager='dnf'
    elif command -v yum >/dev/null; then
        package_manager='yum'
    else
        colorEcho $red "不支持的系统"; exit 1
    fi
}

installDependent(){
    if [[ ${package_manager} == 'dnf' || ${package_manager} == 'yum' ]];then
        ${package_manager} install -y socat crontabs bash-completion docker
    else
        ${package_manager} update -y
        ${package_manager} install -y socat cron bash-completion xz-utils docker.io
    fi
    systemctl enable docker && systemctl start docker
}

setupCron() {
    if [[ `crontab -l 2>/dev/null|grep acme` ]]; then
        crontab -l 2>/dev/null|sed '/acme.sh/d' > crontab.txt
        echo "0 3 * * * systemctl stop trojan-web; \"/root/.acme.sh\"/acme.sh --cron --home \"/root/.acme.sh\" > /dev/null; systemctl start trojan-web" >> crontab.txt
        crontab crontab.txt && rm -f crontab.txt
    fi
}

readDomainAndPrepare(){
    while true; do
        read -p "请输入你的域名（例如 example.com）: " DOMAIN
        DOMAIN="${DOMAIN// /}"
        [[ -n "$DOMAIN" ]] && break
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
    colorEcho $blue "正在安装 Docker 版 MariaDB..."
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
    colorEcho $green "MariaDB 已启动，数据库: ${DB_NAME}, 用户: ${DB_USER}, 密码: ${DB_PASS}"
}

installTrojan(){
    local show_tip=0
    [[ $update == 1 ]] && { systemctl stop trojan-web >/dev/null 2>&1; rm -f /usr/local/bin/trojan; }

    lastest_version=$(curl -H 'Cache-Control: no-cache' -s "$version_check" | grep '"tag_name"' | cut -d\" -f4)
    [[ -z "$lastest_version" ]] && lastest_version="latest"
    colorEcho $blue "正在下载 trojan 管理程序 ${lastest_version}..."
    [[ $(uname -m) == x86_64 ]] && bin="trojan-linux-amd64" || bin="trojan-linux-arm64"
    curl -L "${download_url}/${lastest_version}/${bin}" -o /usr/local/bin/trojan
    chmod +x /usr/local/bin/trojan

    [[ ! -e /etc/systemd/system/trojan-web.service ]] && {
        curl -L $service_url -o /etc/systemd/system/trojan-web.service
        systemctl daemon-reload && systemctl enable trojan-web
        show_tip=1
    }

    mkdir -p /usr/local/etc/trojan
    CONFIG_FILE="/usr/local/etc/trojan/config.json"

    cat > "$CONFIG_FILE" <<EOF
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

    colorEcho $green "trojan 配置文件已生成: ${CONFIG_FILE}"
    systemctl restart docker

    /usr/local/bin/trojan || true
    systemctl restart trojan-web

    setupCron

    [[ $show_tip == 1 ]] && echo "访问: https://${DOMAIN} 查看 trojan 管理后台"

    SHARE_LINK="trojan://${ADMIN_PASS}@${DOMAIN}:${TROJAN_PORT}"
    OPENCLASH_ENTRY="- {name: ${DOMAIN}, server: ${DOMAIN}, port: ${TROJAN_PORT}, type: trojan, password: ${ADMIN_PASS}}"

    echo
    colorEcho ${fuchsia} "==== 安装完成 ===="
    echo "管理员账号: ${ADMIN_USER}"
    echo "管理员密码: ${ADMIN_PASS}"
    echo "数据库用户: ${DB_USER}"
    echo "数据库密码: ${DB_PASS}"
    echo
    colorEcho ${green} "Trojan 分享链接:"
    echo "${SHARE_LINK}"
    echo
    colorEcho ${green} "OpenClash 配置行:"
    echo "${OPENCLASH_ENTRY}"
    echo "=================="
}

main(){
    [[ ${help} == 1 ]] && help && return
    [[ ${remove} == 1 ]] && removeTrojan && return
    colorEcho ${blue} "自动安装 Trojan 管理程序 + Let's Encrypt + Docker MariaDB"
    readDomainAndPrepare
    checkSys
    installDependent
    installMariaDB
    installTrojan
}

main
