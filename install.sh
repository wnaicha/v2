#!/bin/bash
# ============================================================
# 自动安装 Docker + MariaDB + SSL (acme.sh)
# 作者: GPT-5 改进版（DNS智能检测增强）
# ============================================================

set -e

# 彩色输出
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[36m"
RESET="\033[0m"

DB_USER="adminaa"
DB_PASS="wf1234567"
DB_NAME="mydb"

echo -e "${BLUE}🔧 自动安装 Docker + MariaDB + SSL${RESET}"
echo "----------------------------------------------"
read -p "请输入绑定的域名（例如 example.com）: " DOMAIN

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}❌ 域名不能为空${RESET}"
    exit 1
fi

# 获取服务器公网 IP
SERVER_IP=$(curl -s https://ipinfo.io/ip || curl -s https://api.ipify.org)
if [ -z "$SERVER_IP" ]; then
    echo -e "${RED}❌ 无法获取公网 IP，请检查网络${RESET}"
    exit 1
fi
echo -e "${BLUE}🌐 当前服务器公网 IP: ${RESET}${GREEN}$SERVER_IP${RESET}"

# ------------------------------------------------------------
# 检查 dig 工具是否存在
# ------------------------------------------------------------
if ! command -v dig >/dev/null 2>&1; then
    echo -e "${YELLOW}🔍 检测到 dig 未安装，正在安装...${RESET}"
    if command -v apt >/dev/null 2>&1; then
        apt update -y && apt install -y dnsutils
    elif command -v yum >/dev/null 2>&1; then
        yum install -y bind-utils
    else
        echo -e "${RED}❌ 未检测到合适的包管理器（apt 或 yum）${RESET}"
        exit 1
    fi
fi

# ------------------------------------------------------------
# 检查域名解析是否指向当前 IP（智能重试机制）
# ------------------------------------------------------------
MAX_RETRY=30
RETRY_INTERVAL=10
count=0
echo -e "${BLUE}🔎 正在检测域名解析情况...${RESET}"

while true; do
    DOMAIN_IP=$(dig +short "$DOMAIN" | tail -n1)
    if [ -z "$DOMAIN_IP" ]; then
        echo -e "${YELLOW}⚠️  未检测到 $DOMAIN 的 A 记录，等待中 (${count}/${MAX_RETRY})...${RESET}"
    elif [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
        echo -e "${YELLOW}⚠️  域名解析 IP: ${DOMAIN_IP} ≠ 服务器 IP: ${SERVER_IP}${RESET}"
    else
        echo -e "${GREEN}✅ 域名解析正确: ${DOMAIN_IP}${RESET}"
        break
    fi
    count=$((count+1))
    if [ $count -ge $MAX_RETRY ]; then
        echo -e "${RED}❌ 域名未正确解析到服务器，退出安装！${RESET}"
        echo -e "${YELLOW}请确认 DNS A 记录已指向: ${SERVER_IP}${RESET}"
        exit 1
    fi
    sleep $RETRY_INTERVAL
done

echo "----------------------------------------------"
echo -e "${BLUE}请选择操作:${RESET}"
echo "1️⃣  安装 Docker + MariaDB + SSL"
echo "2️⃣  卸载所有相关组件"
read -p "请输入 [1/2]: " OPTION
echo "----------------------------------------------"

# ------------------------------------------------------------
# 卸载逻辑
# ------------------------------------------------------------
if [ "$OPTION" == "2" ]; then
    echo -e "${YELLOW}🧹 开始卸载...${RESET}"
    docker stop mariadb 2>/dev/null || true
    docker rm mariadb 2>/dev/null || true
    docker rmi mariadb:latest 2>/dev/null || true
    rm -rf ~/.acme.sh
    apt remove -y docker docker.io containerd runc dnsutils || true
    apt autoremove -y
    echo -e "${GREEN}✅ 卸载完成${RESET}"
    exit 0
fi

# ------------------------------------------------------------
# 安装 Docker
# ------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo -e "${BLUE}📦 安装 Docker...${RESET}"
    apt update -y
    apt install -y ca-certificates curl gnupg lsb-release
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update -y
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable docker
    systemctl start docker
    echo -e "${GREEN}✅ Docker 安装完成${RESET}"
else
    echo -e "${GREEN}✅ Docker 已安装${RESET}"
fi

# ------------------------------------------------------------
# 启动 MariaDB 容器
# ------------------------------------------------------------
echo -e "${BLUE}🐬 启动 MariaDB 容器...${RESET}"
docker run -d --name mariadb \
  -e MARIADB_ROOT_PASSWORD=$DB_PASS \
  -e MARIADB_USER=$DB_USER \
  -e MARIADB_PASSWORD=$DB_PASS \
  -e MARIADB_DATABASE=$DB_NAME \
  -p 3306:3306 \
  --restart unless-stopped mariadb:latest

echo -e "${GREEN}✅ MariaDB 已启动${RESET}"

# ------------------------------------------------------------
# 安装 acme.sh 并签发证书
# ------------------------------------------------------------
if [ ! -d ~/.acme.sh ]; then
    echo -e "${BLUE}🔐 安装 acme.sh...${RESET}"
    curl https://get.acme.sh | sh
    source ~/.bashrc
else
    echo -e "${GREEN}✅ acme.sh 已安装${RESET}"
fi

echo -e "${BLUE}🌍 使用 Let's Encrypt 签发证书...${RESET}"
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --force --debug

CERT_DIR="$HOME/.acme.sh/$DOMAIN"
if [ -f "$CERT_DIR/fullchain.cer" ]; then
    echo -e "${GREEN}✅ SSL 证书签发成功${RESET}"
    echo -e "${BLUE}📁 证书路径:${RESET} $CERT_DIR"
else
    echo -e "${RED}❌ 证书签发失败，请检查日志${RESET}"
    exit 1
fi

# ------------------------------------------------------------
# 输出结果
# ------------------------------------------------------------
echo "----------------------------------------------"
echo -e "${GREEN}🎉 安装完成！${RESET}"
echo "----------------------------------------------"
echo -e "${BLUE}数据库信息:${RESET}"
echo "  用户名: $DB_USER"
echo "  密码:   $DB_PASS"
echo "  数据库: $DB_NAME"
echo "  端口:   3306"
echo
echo -e "${BLUE}SSL 证书位置:${RESET}"
echo "  $CERT_DIR"
echo
echo -e "${BLUE}📦 OpenClash配置示例:${RESET}"
echo "- {name: trojan-$DOMAIN, server: $DOMAIN, port: 443, type: trojan, password: $DB_PASS}"
echo
echo -e "${YELLOW}✨ 可用命令:${RESET}"
echo "  docker logs -f mariadb     查看数据库日志"
echo "  sudo bash install.sh       重新运行本脚本"
echo "----------------------------------------------"
