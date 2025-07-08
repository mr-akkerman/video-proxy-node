#!/bin/bash

# Универсальный скрипт развертывания для любого домена
# Использование: sudo bash universal-deploy.sh your-domain.com

set -e

# Проверка аргументов
if [ -z "$1" ]; then
    echo "❌ Ошибка: Не указан домен"
    echo "Использование: $0 your-domain.com"
    echo "Пример: $0 video.test.com"
    exit 1
fi

DOMAIN="$1"
SOURCE_DOMAIN="video.full.icu"  # Исходный заблокированный домен
EMAIL="admin@${DOMAIN}"
NGINX_CONF_DIR="/etc/nginx"
SITES_AVAILABLE="$NGINX_CONF_DIR/sites-available"
SITES_ENABLED="$NGINX_CONF_DIR/sites-enabled"

echo "🚀 Развертывание video proxy для домена: $DOMAIN"
echo "📡 Источник: $SOURCE_DOMAIN"

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo "❌ Этот скрипт должен быть запущен от root" 
   exit 1
fi

# Проверка установки Nginx
if ! command -v nginx &> /dev/null; then
    echo "❌ Nginx не установлен. Сначала запустите install.sh"
    exit 1
fi

# Проверка валидности домена
if ! [[ $DOMAIN =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]*\.[a-zA-Z]{2,}$ ]]; then
    echo "❌ Некорректный формат домена: $DOMAIN"
    exit 1
fi

# Создание бэкапа
echo "💾 Создание бэкапа конфигов..."
BACKUP_DIR="/root/nginx-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p $BACKUP_DIR
cp -r $NGINX_CONF_DIR/* $BACKUP_DIR/
echo "Бэкап сохранен в: $BACKUP_DIR"

# Применение основного конфига nginx.conf
echo "⚙️ Применение nginx.conf..."
cat > $NGINX_CONF_DIR/nginx.conf << EOF
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Логирование
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for" '
                    'rt=\$request_time uct="\$upstream_connect_time" '
                    'uht="\$upstream_header_time" urt="\$upstream_response_time"';

    access_log /var/log/nginx/access.log main;

    # Основные настройки производительности
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
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

    # Настройки кэша
    proxy_cache_path /var/cache/nginx/video 
                     levels=1:2 
                     keys_zone=video_cache:100m 
                     max_size=50g 
                     inactive=7d 
                     use_temp_path=off;

    # Настройки upstream для исходного сервера
    upstream video_source {
        server ${SOURCE_DOMAIN}:443;
        keepalive 32;
    }

    # Настройки gzip (отключаем для видео)
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
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    # Включаем конфиги сайтов
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

# Создание конфига для видео прокси
echo "📄 Создание конфига для $DOMAIN..."
cat > $SITES_AVAILABLE/$DOMAIN.conf << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    
    # Для получения SSL сертификата
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    # Редирект на HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    # SSL настройки (будут активированы после получения сертификата)
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$DOMAIN/chain.pem;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;

    # Основные настройки
    charset utf-8;
    client_max_body_size 10M;
    
    # Основной location для видео
    location /videos/ {
        # Проверка метода
        if (\$request_method !~ ^(GET|HEAD|OPTIONS)\$) {
            return 405;
        }
        
        # CORS заголовки
        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS";
        add_header Access-Control-Allow-Headers "Range, If-Range, If-Modified-Since, If-None-Match";
        add_header Access-Control-Expose-Headers "Content-Range, Accept-Ranges, Content-Length, Content-Type";
        
        # Отвечаем на OPTIONS запросы
        if (\$request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin *;
            add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS";
            add_header Access-Control-Allow-Headers "Range, If-Range, If-Modified-Since, If-None-Match";
            add_header Access-Control-Max-Age 1728000;
            add_header Content-Type "text/plain; charset=utf-8";
            add_header Content-Length 0;
            return 204;
        }

        # Настройки кэша
        proxy_cache video_cache;
        proxy_cache_key \$uri\$is_args\$args;
        proxy_cache_valid 200 206 1h;
        proxy_cache_valid 404 1m;
        proxy_cache_valid any 5m;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        proxy_cache_background_update on;
        proxy_cache_lock on;
        proxy_cache_lock_timeout 5s;
        
        # Заголовки кэша для клиента
        add_header X-Cache-Status \$upstream_cache_status;
        expires 1h;
        add_header Cache-Control "public, max-age=3600";

        # Настройки прокси
        proxy_pass https://${SOURCE_DOMAIN}/videos/;
        proxy_ssl_server_name on;
        proxy_ssl_name ${SOURCE_DOMAIN};
        proxy_ssl_verify off;
        
        # Передаем важные заголовки
        proxy_set_header Host ${SOURCE_DOMAIN};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Критично для видео - поддержка Range requests
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
        proxy_set_header If-Modified-Since \$http_if_modified_since;
        proxy_set_header If-None-Match \$http_if_none_match;
        
        # Передаем заголовки ответа
        proxy_pass_header Content-Range;
        proxy_pass_header Accept-Ranges;
        proxy_pass_header Content-Length;
        proxy_pass_header Content-Type;
        proxy_pass_header Last-Modified;
        proxy_pass_header ETag;

        # Настройки для больших файлов
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;
        
        # Таймауты
        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        
        # Отключаем сжатие для видео
        gzip off;
        proxy_set_header Accept-Encoding "";
    }

    # Healthcheck endpoint
    location /health {
        access_log off;
        return 200 "healthy\\n";
        add_header Content-Type text/plain;
    }

    # Статус кэша
    location /cache-status {
        allow 127.0.0.1;
        deny all;
        proxy_cache_purge video_cache \$uri\$is_args\$args;
    }

    # Логирование
    access_log /var/log/nginx/${DOMAIN}.access.log main;
    error_log /var/log/nginx/${DOMAIN}.error.log warn;
}
EOF

# Создание временного конфига без SSL
echo "🔧 Создание временного конфига для получения SSL..."
cat > $SITES_AVAILABLE/$DOMAIN-temp.conf << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location /health {
        access_log off;
        return 200 "healthy\\n";
        add_header Content-Type text/plain;
    }
    
    location / {
        return 200 "Server is ready for SSL setup for $DOMAIN";
        add_header Content-Type text/plain;
    }
}
EOF

# Создание webroot директории
mkdir -p /var/www/html
chown -R nginx:nginx /var/www/html

# Активация временного конфига
echo "🔍 Проверка и активация временного конфига..."
ln -sf $SITES_AVAILABLE/$DOMAIN-temp.conf $SITES_ENABLED/
nginx -t

if [ $? -eq 0 ]; then
    echo "✅ Конфигурация корректна"
    systemctl reload nginx
    echo "🔄 Nginx перезагружен с временным конфигом"
else
    echo "❌ Ошибка в конфигурации!"
    exit 1
fi

# Создание скрипта для получения SSL
cat > /root/activate-ssl-$DOMAIN.sh << EOF
#!/bin/bash

DOMAIN="$DOMAIN"
EMAIL="$EMAIL"

echo "🔒 Получение SSL сертификата для \$DOMAIN..."

# Получение сертификата
certbot certonly --webroot -w /var/www/html -d \$DOMAIN --agree-tos --no-eff-email --email \$EMAIL --non-interactive

if [ \$? -eq 0 ]; then
    echo "✅ SSL сертификат получен успешно"
    
    # Активация основного конфига с SSL
    echo "🔄 Активация основного конфига..."
    rm -f /etc/nginx/sites-enabled/\$DOMAIN-temp.conf
    ln -sf /etc/nginx/sites-available/\$DOMAIN.conf /etc/nginx/sites-enabled/
    
    # Проверка и перезагрузка
    nginx -t && systemctl reload nginx
    
    if [ \$? -eq 0 ]; then
        echo "🎉 SSL конфиг активирован успешно!"
        
        # Настройка автообновления сертификата
        echo "📅 Настройка автообновления сертификата..."
        (crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
        echo "✅ Автообновление сертификата настроено"
        
        # Тест подключения
        echo "🧪 Тестирование конфигурации..."
        curl -I http://localhost/health
        echo "✅ Прокси готов: https://\$DOMAIN/videos/your-video-id.mp4"
        
    else
        echo "❌ Ошибка при активации SSL конфига"
        exit 1
    fi
else
    echo "❌ Ошибка получения SSL сертификата"
    exit 1
fi
EOF

chmod +x /root/activate-ssl-$DOMAIN.sh

# Создание персонализированного скрипта управления
cat > /root/manage-$DOMAIN.sh << EOF
#!/bin/bash

# Скрипт управления video proxy для $DOMAIN

DOMAIN="$DOMAIN"
SOURCE_DOMAIN="$SOURCE_DOMAIN"

show_status() {
    echo "=== Статус Video Proxy для \$DOMAIN ==="
    systemctl status nginx --no-pager -l
    
    echo -e "\\n=== Размер кэша ==="
    du -sh /var/cache/nginx/video/ 2>/dev/null || echo "Кэш пуст"
    
    echo -e "\\n=== Активные соединения ==="
    netstat -an | grep :443 | wc -l
    
    echo -e "\\n=== Последние ошибки ==="
    tail -5 /var/log/nginx/error.log 2>/dev/null || echo "Нет ошибок"
    
    echo -e "\\n=== SSL сертификат ==="
    if [ -f /etc/letsencrypt/live/\$DOMAIN/fullchain.pem ]; then
        openssl x509 -in /etc/letsencrypt/live/\$DOMAIN/fullchain.pem -noout -dates
    else
        echo "SSL сертификат не найден"
    fi
    
    echo -e "\\n=== Конфигурация ==="
    echo "Домен: \$DOMAIN"
    echo "Источник: \$SOURCE_DOMAIN"
    echo "Прокси URL: https://\$DOMAIN/videos/{video-id}.mp4"
}

clear_cache() {
    echo "🗑️ Очистка кэша..."
    rm -rf /var/cache/nginx/video/*
    systemctl reload nginx
    echo "✅ Кэш очищен"
}

show_logs() {
    echo "📋 Логи для \$DOMAIN:"
    echo "=== Access Log ==="
    tail -50 /var/log/nginx/\$DOMAIN.access.log 2>/dev/null || echo "Лог не найден"
    
    echo -e "\\n=== Error Log ==="
    tail -50 /var/log/nginx/\$DOMAIN.error.log 2>/dev/null || echo "Лог не найден"
}

test_proxy() {
    echo "🧪 Тестирование прокси для \$DOMAIN..."
    
    echo "Тест health endpoint:"
    curl -s -o /dev/null -w "HTTP: %{http_code} | Time: %{time_total}s\\n" http://localhost/health
    
    echo "Тест HTTPS:"
    curl -s -o /dev/null -w "HTTP: %{http_code} | Time: %{time_total}s\\n" https://\$DOMAIN/health 2>/dev/null || echo "HTTPS недоступен (SSL не настроен?)"
    
    echo "Тест доступности источника:"
    curl -s -o /dev/null -w "HTTP: %{http_code} | Time: %{time_total}s\\n" https://\$SOURCE_DOMAIN/videos/ 2>/dev/null || echo "Источник недоступен"
}

case "\$1" in
    status)
        show_status
        ;;
    logs)
        show_logs
        ;;
    clear-cache)
        clear_cache
        ;;
    test)
        test_proxy
        ;;
    restart)
        echo "🔄 Перезапуск Nginx..."
        systemctl restart nginx
        echo "✅ Nginx перезапущен"
        ;;
    reload)
        echo "🔄 Перезагрузка конфигурации..."
        nginx -t && systemctl reload nginx
        echo "✅ Конфигурация перезагружена"
        ;;
    ssl)
        bash /root/activate-ssl-\$DOMAIN.sh
        ;;
    *)
        echo "Управление Video Proxy для \$DOMAIN"
        echo "Источник: \$SOURCE_DOMAIN"
        echo ""
        echo "Использование: \$0 {status|logs|clear-cache|test|restart|reload|ssl}"
        echo ""
        echo "Команды:"
        echo "  status      - показать статус системы"
        echo "  logs        - показать логи"
        echo "  clear-cache - очистить кэш"
        echo "  test        - тестировать прокси"
        echo "  restart     - перезапустить nginx"
        echo "  reload      - перезагрузить конфигурацию"
        echo "  ssl         - настроить SSL сертификат"
        echo ""
        echo "После настройки SSL прокси будет доступен:"
        echo "https://\$DOMAIN/videos/{video-id}.mp4"
        exit 1
        ;;
esac
EOF

chmod +x /root/manage-$DOMAIN.sh

# Обновление статусной страницы
cat > /var/www/html/status.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Video Proxy Status - $DOMAIN</title>
    <meta http-equiv="refresh" content="30">
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .status { padding: 10px; margin: 10px 0; border-radius: 5px; }
        .ok { background-color: #d4edda; color: #155724; }
        .error { background-color: #f8d7da; color: #721c24; }
        .info { background-color: #d1ecf1; color: #0c5460; }
    </style>
</head>
<body>
    <h1>Video Proxy Status</h1>
    <div class="status info">
        <strong>Domain:</strong> $DOMAIN<br>
        <strong>Source:</strong> $SOURCE_DOMAIN<br>
        <strong>Proxy URL:</strong> https://$DOMAIN/videos/{video-id}.mp4<br>
        <strong>Last Update:</strong> <span id="time"></span>
    </div>
    
    <script>
        document.getElementById('time').innerText = new Date().toLocaleString();
        
        fetch('/health')
            .then(response => response.text())
            .then(data => {
                console.log('Health check:', data);
            })
            .catch(error => {
                console.error('Health check failed:', error);
            });
    </script>
</body>
</html>
EOF

echo "✅ Развертывание завершено для $DOMAIN!"
echo ""
echo "📋 Что было сделано:"
echo "1. ✅ Основной конфиг nginx.conf применен"
echo "2. ✅ Конфиг для $DOMAIN создан"
echo "3. ✅ Временный конфиг активирован (без SSL)"
echo "4. ✅ Созданы персонализированные скрипты"
echo "5. ✅ Nginx перезагружен"
echo ""
echo "🔥 СЛЕДУЮЩИЕ ШАГИ:"
echo "1. Получить SSL сертификат:"
echo "   bash /root/activate-ssl-$DOMAIN.sh"
echo ""
echo "2. Проверить статус:"
echo "   bash /root/manage-$DOMAIN.sh status"
echo ""
echo "3. Тестировать прокси:"
echo "   bash /root/manage-$DOMAIN.sh test"
echo ""
echo "📁 Ваши персональные команды:"
echo "- Управление: bash /root/manage-$DOMAIN.sh"
echo "- Активация SSL: bash /root/activate-ssl-$DOMAIN.sh"
echo "- Статус: http://your-server-ip/status.html"
echo ""
echo "⚠️  После получения SSL сертификата ваш прокси будет:"
echo "   https://$DOMAIN/videos/your-video-id.mp4"
echo ""
echo "🔄 Проксирует с: https://$SOURCE_DOMAIN/videos/"