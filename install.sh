#!/bin/bash
# ============================================================
# 自动安装 Docker + MariaDB + SSL (acme.sh)
# 作者: GPT-5 改进版
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

# 获取公网 IP
SERVER_IP=$(curl -s https://ipinfo.io/ip || curl -s https://api.ipify.org)
echo -e "${BLUE}🌐 当前服务器公网 IP: ${RESET}${GREEN}$SERVER_IP${RESET}"

# 检查域名解析
DOMAIN_IP=$(dig +short "$DOMAIN" | tail -n1)
if [ -z "$DOMAIN_IP" ]; then
    echo -e "${RED}❌ 无法解析域名，请确认 DNS 已生效${RESET}"
    exit 1
fi

echo -e "${YELLOW}🔍 检测域名解析: ${RESET}$DOMAIN_IP"
if [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
    echo -e "${RED}❌ 域名未正确解析到本机！${RESET}"
    echo "  你的域名解析 IP: $DOMAIN_IP"
    echo "  服务器公网 IP:   $SERVER_IP"
    echo -e "${YELLOW}请先将域名 A 记录解析到该 IP 再运行脚本。${RESET}"
    exit 1
fi
echo -e "${GREEN}✅ 域名解析正确${RESET}"
echo "----------------------------------------------"

# 选择操作
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
    apt remove -y docker docker.io containerd runc || true
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
echo -e "${YELLOW}✨ 提示：可使用以下命令查看数据库日志:${RESET}"
echo "  docker logs -f mariadb"
echo "----------------------------------------------"
