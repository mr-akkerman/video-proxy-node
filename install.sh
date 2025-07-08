#!/bin/bash

# Скрипт установки Nginx video proxy на Ubuntu/Debian
# Запуск: sudo bash install.sh

set -e

echo "🚀 Установка Nginx Video Proxy..."

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo "❌ Этот скрипт должен быть запущен от root" 
   exit 1
fi

# Обновление системы
echo "📦 Обновление системы..."
apt update && apt upgrade -y

# Установка необходимых пакетов
echo "📦 Установка пакетов..."
apt install -y curl wget gnupg2 ca-certificates lsb-release software-properties-common

# Установка Nginx
echo "🔧 Установка Nginx..."
curl -fsSL https://nginx.org/keys/nginx_signing.key | apt-key add -
echo "deb http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" > /etc/apt/sources.list.d/nginx.list
apt update
apt install -y nginx

# Создание пользователя nginx
useradd --system --home /var/cache/nginx --shell /sbin/nologin --comment "nginx user" --user-group nginx || true

# Создание директорий
echo "📁 Создание директорий..."
mkdir -p /var/cache/nginx/video
mkdir -p /var/log/nginx
mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-enabled
mkdir -p /etc/nginx/ssl

# Установка прав на директории
chown -R nginx:nginx /var/cache/nginx
chown -R nginx:nginx /var/log/nginx
chmod 755 /var/cache/nginx/video

# Установка Certbot для SSL
echo "🔒 Установка Certbot..."
apt install -y snapd
snap install core; snap refresh core
snap install --classic certbot
ln -sf /snap/bin/certbot /usr/bin/certbot

# Создание systemd сервиса для Nginx
echo "⚙️ Настройка systemd сервиса..."
cat > /etc/systemd/system/nginx.service << 'EOF'
[Unit]
Description=The nginx HTTP and reverse proxy server
After=network.target remote-fs.target nss-lookup.target

[Service]
Type=forking
PIDFile=/var/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t
ExecStart=/usr/sbin/nginx
ExecReload=/bin/kill -s HUP $MAINPID
ExecStop=/bin/kill -s QUIT $MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# Настройка логротации
echo "📝 Настройка logrotate..."
cat > /etc/logrotate.d/nginx << 'EOF'
/var/log/nginx/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 644 nginx nginx
    sharedscripts
    postrotate
        if [ -f /var/run/nginx.pid ]; then
            kill -USR1 `cat /var/run/nginx.pid`
        fi
    endscript
}
EOF

# Настройка файрвола
echo "🔥 Настройка firewall..."
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 22/tcp
ufw --force enable

# Настройка системных лимитов
echo "⚡ Настройка системных лимитов..."
cat >> /etc/security/limits.conf << 'EOF'
nginx soft nofile 65535
nginx hard nofile 65535
nginx soft nproc 65535
nginx hard nproc 65535
EOF

# Настройка sysctl
cat >> /etc/sysctl.conf << 'EOF'
# Nginx optimization
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 5000
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 6000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_rmem = 4096 87380 6291456
net.ipv4.tcp_wmem = 4096 16384 4194304
net.core.rmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_default = 262144
net.core.wmem_max = 16777216
vm.swappiness = 10
EOF

sysctl -p

# Создание скрипта для получения SSL сертификата
echo "📜 Создание SSL скрипта..."
cat > /root/setup-ssl.sh << 'EOF'
#!/bin/bash

# Скрипт для получения SSL сертификата
# Использование: bash setup-ssl.sh video.full.com

if [ -z "$1" ]; then
    echo "Использование: $0 domain.com"
    exit 1
fi

DOMAIN=$1

echo "Получение SSL сертификата для $DOMAIN..."

# Временный конфиг для получения сертификата
cat > /etc/nginx/sites-available/temp-$DOMAIN << EOF
server {
    listen 80;
    server_name $DOMAIN;
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}
EOF

# Создание webroot
mkdir -p /var/www/html
chown -R nginx:nginx /var/www/html

# Активация временного конфига
ln -sf /etc/nginx/sites-available/temp-$DOMAIN /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# Получение сертификата
certbot certonly --webroot -w /var/www/html -d $DOMAIN --agree-tos --no-eff-email --email admin@$DOMAIN

# Удаление временного конфига
rm -f /etc/nginx/sites-enabled/temp-$DOMAIN

echo "SSL сертификат получен для $DOMAIN"
EOF

chmod +x /root/setup-ssl.sh

# Создание скрипта мониторинга
echo "📊 Создание скрипта мониторинга..."
cat > /root/monitor.sh << 'EOF'
#!/bin/bash

# Скрипт мониторинга производительности

echo "=== Nginx Status ==="
systemctl status nginx --no-pager -l

echo -e "\n=== Nginx Processes ==="
ps aux | grep nginx

echo -e "\n=== Cache Size ==="
du -sh /var/cache/nginx/video/

echo -e "\n=== Disk Usage ==="
df -h

echo -e "\n=== Memory Usage ==="
free -h

echo -e "\n=== Network Connections ==="
netstat -an | grep :443 | wc -l

echo -e "\n=== Top Processes ==="
top -bn1 | head -20

echo -e "\n=== Recent Errors ==="
tail -20 /var/log/nginx/error.log

echo -e "\n=== Cache Stats ==="
curl -s http://localhost/health
EOF

chmod +x /root/monitor.sh

# Включение и запуск сервисов
echo "🔄 Запуск сервисов..."
systemctl daemon-reload
systemctl enable nginx
systemctl start nginx

# Проверка статуса
echo "✅ Проверка установки..."
systemctl status nginx --no-pager

echo "🎉 Установка завершена!"
echo ""
echo "Следующие шаги:"
echo "1. Скопируйте конфиги nginx.conf и video.full.com.conf в соответствующие директории"
echo "2. Запустите: bash /root/setup-ssl.sh video.full.com"
echo "3. Активируйте конфиг: ln -s /etc/nginx/sites-available/video.full.com.conf /etc/nginx/sites-enabled/"
echo "4. Перезапустите nginx: systemctl reload nginx"
echo "5. Мониторинг: bash /root/monitor.sh"
echo ""
echo "Полезные команды:"
echo "- Проверка конфига: nginx -t"
echo "- Перезагрузка: systemctl reload nginx"
echo "- Логи: tail -f /var/log/nginx/error.log"
echo "- Очистка кэша: rm -rf /var/cache/nginx/video/*"