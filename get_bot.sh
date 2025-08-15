#!/bin/bash

# ==============================================================================
# == GJTeam Bot & Web Panel One-Line Installer for Ubuntu 22.04+
# ==
# == 警告: 请务必从你信任的来源运行此脚本。
# == 从互联网直接运行脚本可能存在安全风险。
# ==============================================================================

# --- 脚本设置 ---
# set -e: 如果任何命令失败，立即退出脚本
# set -o pipefail: 如果管道中的任何命令失败，整个管道被视为失败
set -e
set -o pipefail

# --- 变量定义 ---
# 【【【你需要修改这里】】】
GIT_REPO_URL="https://github.com/PuneetGOTO/WEBVABOT.git" # 你的公开Git仓库地址
PROJECT_DIR_NAME="GJTEAM-BOT" # Git仓库克隆下来后的文件夹名
BOT_USER="gjteambot" # 为机器人创建一个专用的、无密码的系统用户
PYTHON_COMMAND="python3"
SERVICE_NAME="gjteam-bot" # systemd 服务的名称

# --- 辅助函数 ---
log_info() {
    echo -e "\033[34m[INFO]\033[0m $1"
}

log_success() {
    echo -e "\033[32m[SUCCESS]\033[0m $1"
}

log_warn() {
    echo -e "\033[33m[WARNING]\033[0m $1"
}

log_error() {
    echo -e "\033[31m[ERROR]\033[0m $1"
}

# --- 脚本开始 ---
log_info "GJTeam Bot & Web Panel 自动配置脚本启动..."

# 1. 检查权限
if [ "$(id -u)" -ne 0 ]; then
    log_error "此脚本需要以 root 权限运行。请使用 'sudo'。"
    exit 1
fi

# 2. 获取用户输入 (非敏感信息)
log_info "我们需要一些信息来配置 Nginx 反向代理..."
read -p "请输入您将用于访问Web面板的域名 (例如: bot.example.com): " DOMAIN_NAME
if [ -z "$DOMAIN_NAME" ]; then
    log_error "域名不能为空。"
    exit 1
fi

# 3. 更新系统并安装系统级依赖
log_info "正在更新系统包并安装必要的依赖 (这可能需要几分钟)..."
apt-get update
apt-get install -y git python3-pip python3-venv nginx ffmpeg build-essential

log_success "系统依赖安装完成。"

# 4. 创建专用的系统用户 (安全最佳实践)
if id "$BOT_USER" &>/dev/null; then
    log_info "用户 '$BOT_USER' 已存在，跳过创建。"
else
    log_info "正在为机器人创建专用的系统用户 '$BOT_USER'..."
    useradd -r -m -d /home/$BOT_USER -s /bin/bash $BOT_USER
    log_success "用户 '$BOT_USER' 创建成功。"
fi

# 5. 克隆项目代码
INSTALL_DIR="/home/$BOT_USER/$PROJECT_DIR_NAME"
log_info "正在从 $GIT_REPO_URL 克隆项目到 $INSTALL_DIR..."
# 如果目录已存在，先删除旧的
if [ -d "$INSTALL_DIR" ]; then
    log_warn "发现旧的安装目录，将进行备份并重新克隆..."
    mv "$INSTALL_DIR" "${INSTALL_DIR}.bak.$(date +%s)"
fi
# 以新用户身份克隆
su - $BOT_USER -c "git clone $GIT_REPO_URL $INSTALL_DIR"
log_success "项目代码克隆成功。"

# 6. 设置 Python 虚拟环境并安装依赖
log_info "正在设置 Python 虚拟环境并安装依赖..."
su - $BOT_USER -c "cd $INSTALL_DIR && $PYTHON_COMMAND -m venv venv"
su - $BOT_USER -c "cd $INSTALL_DIR && source venv/bin/activate && pip install --upgrade pip && pip install -r requirements.txt"
log_success "Python 依赖安装完成。"

# 7. 创建 .env 配置文件模板
log_info "正在创建 .env 配置文件模板..."
# 注意: 我们不在这里要求用户输入敏感信息，以防它们被记录在历史中。
# 我们只生成一个模板，并提醒用户去编辑它。
cat > $INSTALL_DIR/.env <<EOF
# .env - 请务必填写所有标记为【必填】的项

# --- Discord Bot ---
DISCORD_BOT_TOKEN=【必填】你的Discord机器人Token
BOT_RESTART_PASSWORD=【必填】设置一个用于/管理 restart的复杂密码

# --- DeepSeek AI ---
DEEPSEEK_API_KEY=【必填】你的DeepSeek API Key

# --- Alipay (沙箱或生产环境) ---
ALIPAY_APP_ID=【必填】你的支付宝应用APP ID
ALIPAY_PRIVATE_KEY_PATH=$INSTALL_DIR/alipay_private_key.pem  # 私钥文件路径，脚本已为你设置好
ALIPAY_PUBLIC_KEY_FOR_SDK_CONTENT=【必填】你的支付宝公钥内容(Base64字符串)
ALIPAY_PUBLIC_KEY_CONTENT_FOR_CALLBACK_VERIFY=【必填】用于回调验签的支付宝公钥内容(Base64字符串)
ALIPAY_NOTIFY_URL=http://$DOMAIN_NAME/alipay/notify # 回调URL，脚本已为你生成

# --- Web Panel ---
WEB_ADMIN_PASSWORD=【必填】设置一个用于登录Web面板的超级管理员密码
DISCORD_CLIENT_ID=【必填】你的Discord OAuth2应用的Client ID
DISCORD_CLIENT_SECRET=【必填】你的Discord OAuth2应用的Client Secret
DISCORD_REDIRECT_URI=http://$DOMAIN_NAME/callback # OAuth2回调URL，脚本已为你生成

# --- Bot 功能配置 ---
RECHARGE_ADMIN_NOTIFICATION_CHANNEL_ID=【可选】用于接收AI上报和充值通知的Discord频道ID
MIN_RECHARGE_AMOUNT=1.0
MAX_RECHARGE_AMOUNT=10000.0
RECHARGE_CONVERSION_RATE=100
ECONOMY_DEFAULT_BALANCE=100
EOF

# 创建一个空的私钥文件，并提示用户粘贴内容
touch $INSTALL_DIR/alipay_private_key.pem
# 设置正确的文件所有权
chown -R $BOT_USER:$BOT_USER /home/$BOT_USER
chmod -R 755 /home/$BOT_USER

log_success ".env 模板和私钥文件已创建。"

# 8. 创建并配置 systemd 服务
log_info "正在创建 systemd 服务以确保机器人能开机自启并稳定运行..."
cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=GJTeam Discord Bot and Web Panel
After=network.target

[Service]
User=$BOT_USER
Group=$BOT_USER
WorkingDirectory=$INSTALL_DIR
# 使用 gunicorn 启动 Flask 应用，它比 Flask 自带的服务器更适合生产环境
# -w 4: 启动4个工作进程
# -k eventlet: 使用 eventlet 作为工作模式，这对于 Socket.IO 至关重要
# --bind 0.0.0.0:5000: 绑定到5000端口
# role_manager_bot:web_app: 指向 role_manager_bot.py 文件中的 web_app 对象
# 【【【重要修改】】】
# 你的主脚本同时运行机器人和Web服务器，所以我们直接用python启动它
ExecStart=$INSTALL_DIR/venv/bin/python3 $INSTALL_DIR/role_manager_bot.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

log_success "systemd 服务文件创建成功。"

# 9. 配置 Nginx 作为反向代理
log_info "正在配置 Nginx 作为 Web 面板的反向代理..."
cat > /etc/nginx/sites-available/$SERVICE_NAME <<EOF
server {
    listen 80;
    server_name $DOMAIN_NAME;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # 这是 Socket.IO 的关键配置
    location /my-custom-socket-path {
        proxy_pass http://127.0.0.1:5000/my-custom-socket-path;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    
    # 这是支付宝回调的路径，确保它能被访问
    location /alipay/notify {
        proxy_pass http://127.0.0.1:8080; # 注意：这里端口是8080，因为你的机器人里是这样设置的
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

# 启用新的 Nginx 配置
ln -sf /etc/nginx/sites-available/$SERVICE_NAME /etc/nginx/sites-enabled/
# 删除默认的 Nginx 欢迎页（如果存在）
rm -f /etc/nginx/sites-enabled/default

# 检查 Nginx 配置语法
if nginx -t; then
    log_success "Nginx 配置语法正确。"
else
    log_error "Nginx 配置语法错误，请检查 /etc/nginx/sites-available/$SERVICE_NAME 文件。"
    exit 1
fi

# 10. 配置防火墙
log_info "正在配置防火墙 (UFW)..."
ufw allow 'OpenSSH'
ufw allow 'Nginx Full' # 允许 HTTP 和 HTTPS
ufw --force enable
log_success "防火墙配置完成。"

# 11. 重新加载服务并启动
log_info "正在重新加载 systemd 和 Nginx，并启动机器人服务..."
systemctl daemon-reload
systemctl restart nginx
# 我们先不启动机器人服务，因为用户需要先填写 .env 文件
systemctl enable $SERVICE_NAME

log_success "所有服务配置完成！"

# --- 最终说明 ---
echo -e "\n\033[1;32m========================= 安装完成 =========================\033[0m"
echo -e "\n\033[1;33m在你启动机器人之前，必须完成以下关键步骤：\033[0m"
echo ""
echo -e "1. \033[1m编辑配置文件\033[0m: 使用 nano 或其他编辑器打开下面的文件，并填入所有【必填】的密钥和Token："
echo -e "   \033[36msudo nano $INSTALL_DIR/.env\033[0m"
echo ""
echo -e "2. \033[1m配置支付宝私钥\033[0m: 将你的支付宝应用私钥内容粘贴到下面的文件中："
echo -e "   \033[36msudo nano $INSTALL_DIR/alipay_private_key.pem\033[0m"
echo ""
echo -e "3. \033[1m启动机器人服务\033[0m: 完成以上配置后，运行以下命令来启动机器人："
echo -e "   \033[36msudo systemctl start $SERVICE_NAME\033[0m"
echo ""
echo -e "4. \033[1m设置DNS\033[0m: 确保你的域名 \033[1m$DOMAIN_NAME\033[0m 的 A 记录指向你服务器的IP地址。"
echo ""
echo -e "\033[1;34m常用命令:\033[0m"
echo -e "  - \033[1m查看机器人日志\033[0m: \033[36msudo journalctl -u $SERVICE_NAME -f\033[0m"
echo -e "  - \033[1m重启机器人\033[0m: \033[36msudo systemctl restart $SERVICE_NAME\033[0m"
echo -e "  - \033[1m停止机器人\033[0m: \033[36msudo systemctl stop $SERVICE_NAME\033[0m"
echo ""
echo -e "\033[1;31m强烈建议\033[0m: 为你的域名配置 SSL (HTTPS)。你可以使用 Certbot 轻松完成："
echo -e "   1. \033[36msudo apt install certbot python3-certbot-nginx\033[0m"
echo -e "   2. \033[36msudo certbot --nginx -d $DOMAIN_NAME\033[0m"
echo -e "   (在配置SSL后，记得将.env文件中的回调URL从 http 修改为 https)"
echo ""

echo -e "\033[1;32m============================================================\033[0m"
