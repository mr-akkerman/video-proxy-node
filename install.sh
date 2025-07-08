#!/bin/bash

# Улучшенный скрипт установки Nginx video proxy на Ubuntu/Debian
# Исправлены все проблемы из первой установки
# Запуск: sudo bash install-improved.sh

set -e

echo "🚀 Улучшенная установка Nginx Video Proxy (v2.0)..."

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo "❌ Этот скрипт должен быть запущен от root" 
   exit 1
fi

# Определение ОС
if [[ -f /etc/debian_version ]]; then
    OS="debian"
    echo "✅ Обнаружена Debian/Ubuntu система"
elif [[ -f /etc/redhat-release ]]; then
    OS="redhat"
    echo "✅ Обнаружена RedHat/CentOS система"
else
    echo "⚠️  Неизвестная ОС, продолжаем как Debian"
    OS="debian"
fi

# Обновление системы
echo "📦 Обновление системы..."
if [[ "$OS" == "debian" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt update && apt upgrade -y
    
    # Установка необходимых пакетов (включая net-tools для netstat)
    apt install -y curl wget gnupg2 ca-certificates lsb-release software-properties-common \
                   net-tools htop iotop vim nano ufw cron logrotate
else
    yum update -y
    yum install -y curl wget gnupg2 ca-certificates net-tools htop iotop vim nano
fi

# Проверка и остановка существующих веб-серверов
echo "🔍 Проверка конфликтующих сервисов..."
for service in apache2 httpd lighttpd; do
    if systemctl is-active --quiet $service 2>/dev/null; then
        echo "⚠️  Остановка $service..."
        systemctl stop $service
        systemctl disable $service
    fi
done

# Удаление старых версий nginx если есть
if command -v nginx >/dev/null 2>&1; then
    echo "🗑️ Удаление старой версии nginx..."
    systemctl stop nginx 2>/dev/null || true
    if [[ "$OS" == "debian" ]]; then
        apt remove -y nginx nginx-common nginx-core 2>/dev/null || true
    else
        yum remove -y nginx 2>/dev/null || true
    fi
fi

# Установка Nginx (официальный репозиторий)
echo "🔧 Установка Nginx из официального репозитория..."
if [[ "$OS" == "debian" ]]; then
    # Добавление ключа и репозитория
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /etc/apt/keyrings/nginx.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nginx.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" > /etc/apt/sources.list.d/nginx.list
    
    # Приоритет репозитория
    echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" > /etc/apt/preferences.d/99nginx
    
    apt update
    apt install -y nginx
else
    # Для RedHat/CentOS
    cat > /etc/yum.repos.d/nginx.repo << 'EOF'
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
EOF
    yum install -y nginx
fi

# Создание пользователя nginx если не существует
if ! id -u nginx >/dev/null 2>&1; then
    echo "👤 Создание пользователя nginx..."
    useradd --system --home /var/cache/nginx --shell /sbin/nologin --comment "nginx user" --user-group nginx
fi

# Создание всех необходимых директорий
echo "📁 Создание директорий..."
mkdir -p /var/cache/nginx/video
mkdir -p /var/log/nginx
mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-enabled
mkdir -p /etc/nginx/ssl
mkdir -p /var/www/html

# Очистка старых конфигов если есть
echo "🧹 Очистка старых конфигураций..."
rm -f /etc/nginx/sites-enabled/* 2>/dev/null || true
rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true

# Установка правильных прав
echo "🔒 Настройка прав доступа..."
chown -R nginx:nginx /var/cache/nginx
chown -R nginx:nginx /var/log/nginx
chown -R nginx:nginx /var/www/html
chmod 755 /var/cache/nginx/video
chmod 755 /var/www/html

# Установка Certbot для SSL
echo "🔒 Установка Certbot..."
if [[ "$OS" == "debian" ]]; then
    # Через snapd (рекомендуемый способ)
    if command -v snap >/dev/null 2>&1; then
        snap install core && snap refresh core
        snap install --classic certbot
        ln -sf /snap/bin/certbot /usr/bin/certbot
    else
        # Альтернативный способ через apt
        apt install -y certbot python3-certbot-nginx
    fi
else
    yum install -y certbot python3-certbot-nginx
fi

# Создание улучшенного systemd сервиса
echo "⚙️ Настройка systemd сервиса..."
cat > /etc/systemd/system/nginx.service << 'EOF'
[Unit]
Description=The nginx HTTP and reverse proxy server
Documentation=http://nginx.org/en/docs/
After=network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/var/run/nginx.pid
# Проверка конфигурации перед запуском
ExecStartPre=/usr/sbin/nginx -t
ExecStart=/usr/sbin/nginx
# Перезагрузка конфигурации
ExecReload=/bin/sh -c "/bin/kill -s HUP $(/bin/cat /var/run/nginx.pid)"
ExecStop=/bin/sh -c "/bin/kill -s TERM $(/bin/cat /var/run/nginx.pid)"
KillSignal=SIGQUIT
TimeoutStopSec=5
KillMode=mixed
PrivateTmp=true

# Увеличенные лимиты для высокой нагрузки
LimitNOFILE=65536
LimitNPROC=65536

# Настройки безопасности
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/cache/nginx /var/log/nginx /var/run /tmp
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=false
RestrictRealtime=true
RestrictSUIDSGID=true
RemoveIPC=true

# Автоматический перезапуск
Restart=on-failure
RestartSec=5s

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
    prerotate
        if [ -d /etc/logrotate.d/httpd-prerotate ]; then
            run-parts /etc/logrotate.d/httpd-prerotate
        fi
    endscript
    postrotate
        # Безопасная отправка сигнала
        if [ -f /var/run/nginx.pid ]; then
            /bin/kill -USR1 $(cat /var/run/nginx.pid) 2>/dev/null || true
        fi
    endscript
}
EOF

# Настройка firewall
echo "🔥 Настройка firewall..."
if command -v ufw >/dev/null 2>&1; then
    # UFW (Ubuntu/Debian)
    ufw --force enable
    ufw allow ssh
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    echo "✅ UFW настроен"
elif command -v firewall-cmd >/dev/null 2>&1; then
    # Firewalld (CentOS/RHEL)
    systemctl enable firewalld
    systemctl start firewalld
    firewall-cmd --permanent --add-service=ssh
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
    echo "✅ Firewalld настроен"
else
    echo "⚠️ Firewall не найден, настройте вручную"
fi

# Настройка системных лимитов (исправляет warning о worker_connections)
echo "⚡ Настройка системных лимитов..."
cat >> /etc/security/limits.conf << 'EOF'
# Nginx optimization
nginx soft nofile 65536
nginx hard nofile 65536
nginx soft nproc 65536
nginx hard nproc 65536
* soft nofile 65536
* hard nofile 65536
EOF

# Настройка sysctl для высокой производительности
echo "🚀 Оптимизация ядра..."
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

# Применение настроек sysctl
sysctl -p >/dev/null 2>&1 || true

# Создание базового nginx.conf (без доменов)
echo "📄 Создание базового nginx.conf..."
cat > /etc/nginx/nginx.conf << 'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

# Максимальное количество открытых файлов для worker процесса
worker_rlimit_nofile 65536;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
    accept_mutex off;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Логирование
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for" '
                    'rt=$request_time uct="$upstream_connect_time" '
                    'uht="$upstream_header_time" urt="$upstream_response_time"';

    access_log /var/log/nginx/access.log main;

    # Основные настройки производительности
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    keepalive_requests 1000;
    types_hash_max_size 2048;
    server_tokens off;
    
    # Размеры буферов
    client_body_buffer_size 128k;
    client_max_body_size 10m;
    client_header_buffer_size 1k;
    large_client_header_buffers 4 4k;
    output_buffers 1 32k;
    postpone_output 1460;

    # Настройки прокси
    proxy_connect_timeout 60s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;
    proxy_buffer_size 4k;
    proxy_buffers 16 4k;
    proxy_busy_buffers_size 8k;
    proxy_temp_file_write_size 8k;
    proxy_max_temp_file_size 1024m;
    
    # Настройки кэша (создается позже при развертывании домена)
    # proxy_cache_path будет добавлен автоматически

    # Настройки gzip
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml+rss
        application/atom+xml
        image/svg+xml;

    # Настройки безопасности
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Скрытие версии nginx
    server_tokens off;
    
    # Включаем конфиги сайтов
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
    
    # Дефолтный сервер (отвечает 444 на неизвестные домены)
    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name _;
        return 444;
    }
}
EOF

# Создание утилитарных скриптов
echo "🛠️ Создание утилитарных скриптов..."

# Скрипт проверки системы
cat > /root/check-system.sh << 'EOF'
#!/bin/bash

echo "=== Проверка системы Video Proxy ==="

# Проверка nginx
if systemctl is-active --quiet nginx; then
    echo "✅ Nginx: активен"
else
    echo "❌ Nginx: неактивен"
fi

# Проверка портов
echo "📡 Открытые порты:"
ss -tlnp | grep -E ':(80|443) ' || echo "Порты 80/443 не открыты"

# Проверка конфигурации
echo "⚙️ Конфигурация nginx:"
nginx -t 2>&1 | head -5

# Проверка места на диске
echo "💾 Место на диске:"
df -h / | tail -1

# Проверка кэша
echo "📦 Размер кэша:"
du -sh /var/cache/nginx/video/ 2>/dev/null || echo "Кэш пуст"

# Проверка лимитов
echo "📊 Лимиты файлов:"
ulimit -n

# Проверка certbot
if command -v certbot >/dev/null 2>&1; then
    echo "✅ Certbot: установлен"
else
    echo "❌ Certbot: не установлен"
fi
EOF

chmod +x /root/check-system.sh

# Создание скрипта очистки
cat > /root/cleanup.sh << 'EOF'
#!/bin/bash

echo "🧹 Очистка системы Video Proxy..."

# Очистка кэша nginx
echo "Очистка кэша видео..."
rm -rf /var/cache/nginx/video/*

# Очистка старых логов
echo "Очистка старых логов..."
find /var/log/nginx/ -name "*.log.*" -mtime +7 -delete

# Очистка временных файлов
echo "Очистка временных файлов..."
rm -rf /tmp/nginx* 2>/dev/null || true

# Перезагрузка nginx
echo "Перезагрузка nginx..."
systemctl reload nginx

echo "✅ Очистка завершена"
EOF

chmod +x /root/cleanup.sh

# Включение и запуск сервисов
echo "🔄 Запуск сервисов..."
systemctl daemon-reload
systemctl enable nginx

# Проверка конфигурации перед запуском
if nginx -t; then
    systemctl start nginx
    echo "✅ Nginx запущен успешно"
else
    echo "❌ Ошибка в конфигурации nginx"
    exit 1
fi

# Создание простой тестовой страницы
cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Video Proxy Server</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 600px; margin: 0 auto; background: white; padding: 30px; border-radius: 10px; }
        .status { color: #28a745; font-size: 24px; margin-bottom: 20px; }
        .info { background: #e7f3ff; padding: 15px; border-radius: 5px; margin: 10px 0; }
        code { background: #f8f9fa; padding: 2px 5px; border-radius: 3px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 Video Proxy Server</h1>
        <div class="status">✅ Система установлена и готова к работе!</div>
        
        <div class="info">
            <strong>Следующие шаги:</strong><br>
            1. Запустите: <code>bash universal-deploy-improved.sh your-domain.com</code><br>
            2. Настройте DNS для вашего домена<br>
            3. Получите SSL сертификат<br>
            4. Начните использовать прокси
        </div>
        
        <div class="info">
            <strong>Полезные команды:</strong><br>
            • Проверка системы: <code>bash /root/check-system.sh</code><br>
            • Очистка кэша: <code>bash /root/cleanup.sh</code><br>
            • Статус nginx: <code>systemctl status nginx</code>
        </div>
    </div>
</body>
</html>
EOF

# Финальная проверка
echo "✅ Проверка установки..."

# Проверка статуса nginx
if systemctl is-active --quiet nginx; then
    echo "✅ Nginx: запущен и работает"
else
    echo "❌ Nginx: проблемы с запуском"
    systemctl status nginx --no-pager
fi

# Проверка портов
if ss -tlnp | grep -q ':80 '; then
    echo "✅ Порт 80: открыт"
else
    echo "⚠️ Порт 80: не открыт"
fi

# Проверка certbot
if command -v certbot >/dev/null 2>&1; then
    echo "✅ Certbot: установлен"
else
    echo "⚠️ Certbot: проблемы с установкой"
fi

echo ""
echo "🎉 Улучшенная установка завершена!"
echo ""
echo "📋 Что было установлено и настроено:"
echo "1. ✅ Nginx из официального репозитория"
echo "2. ✅ Certbot для SSL сертификатов"
echo "3. ✅ Systemd сервис с автозапуском"
echo "4. ✅ Firewall настроен (порты 80, 443, 22)"
echo "5. ✅ Логротация настроена"
echo "6. ✅ Системные лимиты увеличены"
echo "7. ✅ Оптимизация ядра применена"
echo "8. ✅ Утилитарные скрипты созданы"
echo ""
echo "🔥 СЛЕДУЮЩИЕ ШАГИ:"
echo "1. Скачайте улучшенный скрипт развертывания"
echo "2. Запустите: bash universal-deploy-improved.sh your-domain.com"
echo ""
echo "📁 Полезные команды:"
echo "- Проверка системы: bash /root/check-system.sh"
echo "- Очистка кэша: bash /root/cleanup.sh"
echo "- Статус: systemctl status nginx"
echo "- Проверка конфига: nginx -t"
echo ""
echo "🌐 Тестовая страница: http://$(curl -s ifconfig.me 2>/dev/null || echo 'your-server-ip')"