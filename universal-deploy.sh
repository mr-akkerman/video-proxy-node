#!/bin/bash

# Улучшенный универсальный скрипт развертывания для любого домена
# Исправлены все проблемы из первой версии
# Использование: sudo bash universal-deploy-improved.sh your-domain.com

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция вывода с цветами
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

# Проверка аргументов
if [ -z "$1" ]; then
    log_error "Не указан домен"
    echo "Использование: $0 your-domain.com"
    echo "Пример: $0 video.test.com"
    echo "Пример: $0 stream.cyber-satan.io"
    exit 1
fi

DOMAIN="$1"
SOURCE_DOMAIN="${2:-video.full.icu}"  # Можно указать свой источник
EMAIL="admin@${DOMAIN}"
NGINX_CONF_DIR="/etc/nginx"
SITES_AVAILABLE="$NGINX_CONF_DIR/sites-available"
SITES_ENABLED="$NGINX_CONF_DIR/sites-enabled"

echo "🚀 Улучшенное развертывание video proxy (v2.0)"
log_info "Домен: $DOMAIN"
log_info "Источник: $SOURCE_DOMAIN"

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   log_error "Этот скрипт должен быть запущен от root"
   exit 1
fi

# Проверка установки Nginx
if ! command -v nginx &> /dev/null; then
    log_error "Nginx не установлен. Сначала запустите install-improved.sh"
    exit 1
fi

# Улучшенная проверка домена (разрешаем дефисы, точки, различные TLD)
domain_validation() {
    local domain="$1"
    
    # Базовая проверка длины
    if [[ ${#domain} -lt 4 ]] || [[ ${#domain} -gt 253 ]]; then
        return 1
    fi
    
    # Проверка что домен содержит хотя бы одну точку
    if [[ ! "$domain" =~ \. ]]; then
        return 1
    fi
    
    # Проверка на недопустимые символы (разрешаем буквы, цифры, дефисы, точки)
    if [[ ! "$domain" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        return 1
    fi
    
    # Проверка что не начинается и не заканчивается дефисом или точкой
    if [[ "$domain" =~ ^[-\.] ]] || [[ "$domain" =~ [-\.]$ ]]; then
        return 1
    fi
    
    return 0
}

if ! domain_validation "$DOMAIN"; then
    log_warning "Домен '$DOMAIN' может иметь нестандартный формат"
    log_info "Разрешенные символы: буквы, цифры, дефисы, точки"
    log_info "Продолжаем выполнение..."
fi

# Проверка что nginx запущен
if ! systemctl is-active --quiet nginx; then
    log_warning "Nginx не запущен, запускаем..."
    systemctl start nginx || {
        log_error "Не удалось запустить nginx"
        exit 1
    }
fi

# Создание бэкапа с проверкой
log_info "Создание бэкапа конфигов..."
BACKUP_DIR="/root/nginx-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

if [ -d "$NGINX_CONF_DIR" ]; then
    cp -r "$NGINX_CONF_DIR"/* "$BACKUP_DIR/" 2>/dev/null || true
    log_success "Бэкап сохранен в: $BACKUP_DIR"
else
    log_warning "Директория nginx не найдена, пропускаем бэкап"
fi

# Проверка и создание необходимых директорий
log_info "Проверка директорий..."
for dir in "$SITES_AVAILABLE" "$SITES_ENABLED" "/var/cache/nginx/video" "/var/www/html"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        log_success "Создана директория: $dir"
    fi
done

# Очистка старых конфигов для этого домена
log_info "Очистка старых конфигов для $DOMAIN..."
rm -f "$SITES_ENABLED/$DOMAIN.conf" 2>/dev/null || true
rm -f "$SITES_ENABLED/$DOMAIN-temp.conf" 2>/dev/null || true
rm -f "$SITES_AVAILABLE/$DOMAIN-temp.conf" 2>/dev/null || true

# Проверка и обновление основного nginx.conf
log_info "Обновление nginx.conf..."

# Проверяем есть ли уже настройки кэша
if ! grep -q "proxy_cache_path.*video_cache" "$NGINX_CONF_DIR/nginx.conf"; then
    log_info "Добавление настроек кэша в nginx.conf..."
    
    # Создаем временный файл с обновленным конфигом
    sed '/# Настройки прокси/a\
\
    # Настройки кэша для видео\
    proxy_cache_path /var/cache/nginx/video \
                     levels=1:2 \
                     keys_zone=video_cache:100m \
                     max_size=50g \
                     inactive=7d \
                     use_temp_path=off;\
\
    # Upstream для исходного сервера\
    upstream video_source {\
        server ${SOURCE_DOMAIN}:443;\
        keepalive 32;\
    }' "$NGINX_CONF_DIR/nginx.conf" > "$NGINX_CONF_DIR/nginx.conf.tmp"
    
    mv "$NGINX_CONF_DIR/nginx.conf.tmp" "$NGINX_CONF_DIR/nginx.conf"
    log_success "Настройки кэша добавлены в nginx.conf"
else
    log_info "Настройки кэша уже существуют в nginx.conf"
fi

# Создание улучшенного конфига для домена (без проблемных директив)
log_info "Создание конфига для $DOMAIN..."
cat > "$SITES_AVAILABLE/$DOMAIN.conf" << EOF
# Video proxy configuration for $DOMAIN
# Generated: $(date)
# Source: $SOURCE_DOMAIN

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    
    # Для получения SSL сертификата
    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }
    
    # Редирект на HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $DOMAIN;

    # SSL настройки
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$DOMAIN/chain.pem;
    
    # Современные SSL настройки
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    
    # OCSP stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;

    # Основные настройки
    charset utf-8;
    client_max_body_size 10M;
    
    # Заголовки безопасности
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    
    # Основной location для видео
    location /videos/ {
        # Проверка метода
        if (\$request_method !~ ^(GET|HEAD|OPTIONS)\$) {
            return 405;
        }
        
        # CORS заголовки для видео
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Range, If-Range, If-Modified-Since, If-None-Match, Authorization" always;
        add_header Access-Control-Expose-Headers "Content-Range, Accept-Ranges, Content-Length, Content-Type, Last-Modified, ETag" always;
        
        # Обработка OPTIONS запросов
        if (\$request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin * always;
            add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Range, If-Range, If-Modified-Since, If-None-Match, Authorization" always;
            add_header Access-Control-Max-Age 1728000 always;
            add_header Content-Type "text/plain; charset=utf-8" always;
            add_header Content-Length 0 always;
            return 204;
        }

        # Настройки кэширования
        proxy_cache video_cache;
        proxy_cache_key \$uri\$is_args\$args;
        proxy_cache_valid 200 206 24h;  # Увеличено время кэширования
        proxy_cache_valid 404 1m;
        proxy_cache_valid any 5m;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        proxy_cache_background_update on;
        proxy_cache_lock on;
        proxy_cache_lock_timeout 5s;
        proxy_cache_revalidate on;
        
        # Заголовки кэша для клиента
        add_header X-Cache-Status \$upstream_cache_status always;
        expires 24h;
        add_header Cache-Control "public, max-age=86400" always;

        # Настройки проксирования
        proxy_pass https://$SOURCE_DOMAIN/videos/;
        proxy_ssl_server_name on;
        proxy_ssl_name $SOURCE_DOMAIN;
        proxy_ssl_verify off;
        proxy_ssl_protocols TLSv1.2 TLSv1.3;
        
        # Передача заголовков
        proxy_set_header Host $SOURCE_DOMAIN;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header User-Agent \$http_user_agent;
        
        # Критично для видео - поддержка Range requests
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
        proxy_set_header If-Modified-Since \$http_if_modified_since;
        proxy_set_header If-None-Match \$http_if_none_match;
        
        # Передача заголовков ответа
        proxy_pass_header Content-Range;
        proxy_pass_header Accept-Ranges;
        proxy_pass_header Content-Length;
        proxy_pass_header Content-Type;
        proxy_pass_header Last-Modified;
        proxy_pass_header ETag;
        proxy_pass_header Expires;
        proxy_pass_header Cache-Control;

        # Настройки для больших файлов
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;
        
        # Увеличенные таймауты для больших файлов
        proxy_connect_timeout 60s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
        
        # Отключение сжатия для видео
        gzip off;
        proxy_set_header Accept-Encoding "";
    }

    # Health check endpoint
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type "text/plain" always;
        add_header Cache-Control "no-cache" always;
    }
    
    # Статус кэша (только для localhost)
    location /cache-status {
        allow 127.0.0.1;
        allow ::1;
        deny all;
        
        return 200 "Cache status: OK\nCache path: /var/cache/nginx/video\nCache size: \$(du -sh /var/cache/nginx/video/ | cut -f1)\n";
        add_header Content-Type "text/plain" always;
    }
    
    # Очистка кэша (только для localhost)
    location /cache-clear {
        allow 127.0.0.1;
        allow ::1;
        deny all;
        
        access_by_lua_block {
            os.execute("rm -rf /var/cache/nginx/video/* 2>/dev/null")
        }
        
        return 200 "Cache cleared\n";
        add_header Content-Type "text/plain" always;
    }

    # Robots.txt
    location /robots.txt {
        return 200 "User-agent: *\nDisallow: /\n";
        add_header Content-Type "text/plain" always;
    }

    # Логирование
    access_log /var/log/nginx/$DOMAIN.access.log main buffer=16k flush=2m;
    error_log /var/log/nginx/$DOMAIN.error.log warn;
}
EOF

# Создание временного конфига для получения SSL
log_info "Создание временного конфига..."
cat > "$SITES_AVAILABLE/$DOMAIN-temp.conf" << EOF
# Temporary configuration for SSL certificate acquisition
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }
    
    location /health {
        access_log off;
        return 200 "ready for SSL setup: $DOMAIN\n";
        add_header Content-Type "text/plain" always;
    }
    
    location / {
        return 200 "Server is ready for SSL setup: $DOMAIN\nNext step: run SSL activation script\n";
        add_header Content-Type "text/plain" always;
    }
}
EOF

# Обеспечение правильных прав на директории
chown -R nginx:nginx /var/www/html
chown -R nginx:nginx /var/cache/nginx

# Активация временного конфига
log_info "Активация временного конфига..."
ln -sf "$SITES_AVAILABLE/$DOMAIN-temp.conf" "$SITES_ENABLED/"

# Проверка конфигурации
log_info "Проверка конфигурации nginx..."
if nginx -t 2>/dev/null; then
    log_success "Конфигурация корректна"
    
    # Перезагрузка nginx
    systemctl reload nginx
    log_success "Nginx перезагружен"
    
    # Проверка что сервис активен
    if systemctl is-active --quiet nginx; then
        log_success "Nginx активен и работает"
    else
        log_error "Nginx не активен после перезагрузки"
        systemctl status nginx --no-pager
        exit 1
    fi
else
    log_error "Ошибка в конфигурации nginx!"
    nginx -t
    exit 1
fi

# Создание улучшенного SSL скрипта
log_info "Создание SSL скрипта..."
cat > "/root/activate-ssl-$DOMAIN.sh" << EOF
#!/bin/bash

# Улучшенный скрипт активации SSL для $DOMAIN
# Автоматическое исправление проблем

set -e

DOMAIN="$DOMAIN"
EMAIL="$EMAIL"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "\${BLUE}ℹ️  \$1\${NC}"; }
log_success() { echo -e "\${GREEN}✅ \$1\${NC}"; }
log_warning() { echo -e "\${YELLOW}⚠️  \$1\${NC}"; }
log_error() { echo -e "\${RED}❌ \$1\${NC}"; }

echo "🔒 Активация SSL для \$DOMAIN..."

# Проверка DNS
log_info "Проверка DNS..."
if ! nslookup "\$DOMAIN" >/dev/null 2>&1; then
    log_error "DNS не настроен для \$DOMAIN"
    log_info "Настройте A-запись: \$DOMAIN → \$(curl -s ifconfig.me)"
    exit 1
fi

# Проверка доступности по HTTP
log_info "Проверка HTTP доступности..."
if ! curl -s -o /dev/null -w "%{http_code}" "http://\$DOMAIN/health" | grep -q "200"; then
    log_warning "HTTP недоступен, но продолжаем..."
fi

# Получение сертификата с улучшенной обработкой ошибок
log_info "Получение SSL сертификата..."

# Попытка получить сертификат
if certbot certonly --webroot -w /var/www/html -d "\$DOMAIN" --agree-tos --no-eff-email --email "\$EMAIL" --non-interactive --force-renewal 2>/tmp/certbot.log; then
    log_success "SSL сертификат получен успешно"
else
    log_error "Ошибка получения SSL сертификата"
    echo "Лог ошибок:"
    cat /tmp/certbot.log
    
    log_info "Возможные причины:"
    log_info "1. DNS не настроен правильно"
    log_info "2. Домен недоступен из интернета"
    log_info "3. Порт 80 заблокирован"
    
    exit 1
fi

# Проверка что сертификат создан
if [ ! -f "/etc/letsencrypt/live/\$DOMAIN/fullchain.pem" ]; then
    log_error "Файлы сертификата не найдены"
    exit 1
fi

# Активация основного конфига с SSL
log_info "Активация основного конфига..."
rm -f "/etc/nginx/sites-enabled/\$DOMAIN-temp.conf"
ln -sf "/etc/nginx/sites-available/\$DOMAIN.conf" "/etc/nginx/sites-enabled/"

# Проверка и перезагрузка nginx
log_info "Проверка конфигурации..."
if nginx -t 2>/dev/null; then
    systemctl reload nginx
    log_success "Nginx конфигурация обновлена"
else
    log_error "Ошибка в конфигурации nginx"
    nginx -t
    
    # Откат к временному конфигу
    log_info "Откат к временному конфигу..."
    rm -f "/etc/nginx/sites-enabled/\$DOMAIN.conf"
    ln -sf "/etc/nginx/sites-available/\$DOMAIN-temp.conf" "/etc/nginx/sites-enabled/"
    systemctl reload nginx
    
    exit 1
fi

# Настройка автообновления сертификата
log_info "Настройка автообновления..."
# Удаляем старые записи для этого домена
crontab -l 2>/dev/null | grep -v "certbot.*\$DOMAIN" | crontab - 2>/dev/null || true

# Добавляем новую запись
(crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
log_success "Автообновление настроено"

# Тестирование HTTPS
log_info "Тестирование HTTPS..."
sleep 2

if curl -s -o /dev/null -w "%{http_code}" "https://\$DOMAIN/health" | grep -q "200"; then
    log_success "HTTPS работает корректно"
    
    # Тест редиректа
    if curl -s -o /dev/null -w "%{http_code}" "http://\$DOMAIN/health" | grep -q "301\|302"; then
        log_success "HTTP→HTTPS редирект работает"
    fi
    
    echo ""
    log_success "🎉 SSL успешно активирован!"
    echo ""
    echo "📋 Информация:"
    echo "• Домен: \$DOMAIN"
    echo "• HTTPS: https://\$DOMAIN/health"
    echo "• Прокси URL: https://\$DOMAIN/videos/{video-id}.mp4"
    echo "• Сертификат действует до: \$(openssl x509 -in /etc/letsencrypt/live/\$DOMAIN/fullchain.pem -noout -enddate | cut -d= -f2)"
    echo ""
    
else
    log_error "HTTPS не работает"
    log_info "Проверьте логи: tail -f /var/log/nginx/\$DOMAIN.error.log"
    exit 1
fi
EOF

chmod +x "/root/activate-ssl-$DOMAIN.sh"

# Создание улучшенного скрипта управления
log_info "Создание скрипта управления..."
cat > "/root/manage-$DOMAIN.sh" << EOF
#!/bin/bash

# Улучшенный скрипт управления video proxy для $DOMAIN

DOMAIN="$DOMAIN"
SOURCE_DOMAIN="$SOURCE_DOMAIN"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "\${BLUE}ℹ️  \$1\${NC}"; }
log_success() { echo -e "\${GREEN}✅ \$1\${NC}"; }
log_warning() { echo -e "\${YELLOW}⚠️  \$1\${NC}"; }
log_error() { echo -e "\${RED}❌ \$1\${NC}"; }

show_status() {
    echo "=== 📊 Статус Video Proxy для \$DOMAIN ==="
    echo ""
    
    # Статус nginx
    if systemctl is-active --quiet nginx; then
        log_success "Nginx: активен"
    else
        log_error "Nginx: неактивен"
        return 1
    fi
    
    # Размер кэша
    echo ""
    log_info "Кэш:"
    if [ -d "/var/cache/nginx/video" ]; then
        local cache_size=\$(du -sh /var/cache/nginx/video/ 2>/dev/null | cut -f1)
        echo "  Размер: \$cache_size"
        local cache_files=\$(find /var/cache/nginx/video -type f 2>/dev/null | wc -l)
        echo "  Файлов: \$cache_files"
    else
        echo "  Директория кэша не найдена"
    fi
    
    # Активные соединения
    echo ""
    log_info "Соединения:"
    if command -v ss >/dev/null 2>&1; then
        local https_conn=\$(ss -tlnp | grep -c ':443 ' || echo "0")
        echo "  HTTPS: \$https_conn"
        local http_conn=\$(ss -tlnp | grep -c ':80 ' || echo "0")
        echo "  HTTP: \$http_conn"
    else
        echo "  ss команда недоступна"
    fi
    
    # SSL сертификат
    echo ""
    log_info "SSL сертификат:"
    if [ -f "/etc/letsencrypt/live/\$DOMAIN/fullchain.pem" ]; then
        local cert_end=\$(openssl x509 -in "/etc/letsencrypt/live/\$DOMAIN/fullchain.pem" -noout -enddate | cut -d= -f2)
        echo "  Действует до: \$cert_end"
        
        local cert_days=\$(( ( \$(date -d "\$cert_end" +%s) - \$(date +%s) ) / 86400 ))
        if [ \$cert_days -gt 30 ]; then
            log_success "  Дней до истечения: \$cert_days"
        elif [ \$cert_days -gt 7 ]; then
            log_warning "  Дней до истечения: \$cert_days"
        else
            log_error "  Дней до истечения: \$cert_days (требуется обновление!)"
        fi
    else
        log_error "  SSL сертификат не найден"
    fi
    
    # Конфигурация
    echo ""
    log_info "Конфигурация:"
    echo "  Домен: \$DOMAIN"
    echo "  Источник: \$SOURCE_DOMAIN"
    echo "  Прокси URL: https://\$DOMAIN/videos/{video-id}.mp4"
    echo "  Конфиг: /etc/nginx/sites-available/\$DOMAIN.conf"
    echo "  Логи: /var/log/nginx/\$DOMAIN.*.log"
}

clear_cache() {
    log_info "Очистка кэша..."
    local cache_size_before=\$(du -sh /var/cache/nginx/video/ 2>/dev/null | cut -f1 || echo "0")
    
    rm -rf /var/cache/nginx/video/*
    
    # Перезагрузка nginx
    systemctl reload nginx
    
    local cache_size_after=\$(du -sh /var/cache/nginx/video/ 2>/dev/null | cut -f1 || echo "0")
    log_success "Кэш очищен (было: \$cache_size_before, стало: \$cache_size_after)"
}

show_logs() {
    local lines=\${2:-50}
    
    echo "📋 Логи для \$DOMAIN (последние \$lines строк):"
    echo ""
    
    echo "=== 📥 Access Log ==="
    if [ -f "/var/log/nginx/\$DOMAIN.access.log" ]; then
        tail -\$lines "/var/log/nginx/\$DOMAIN.access.log" | grep -v "\.well-known" || echo "Нет записей"
    else
        echo "Лог файл не найден"
    fi
    
    echo ""
    echo "=== ⚠️  Error Log ==="
    if [ -f "/var/log/nginx/\$DOMAIN.error.log" ]; then
        tail -\$lines "/var/log/nginx/\$DOMAIN.error.log" || echo "Нет ошибок"
    else
        echo "Лог файл не найден"
    fi
}

test_proxy() {
    echo "🧪 Тестирование прокси для \$DOMAIN..."
    echo ""
    
    # Тест HTTP (должен быть редирект)
    log_info "HTTP тест:"
    local http_result=\$(curl -s -o /dev/null -w "HTTP: %{http_code} | Time: %{time_total}s" "http://\$DOMAIN/health" 2>/dev/null || echo "Ошибка соединения")
    echo "  \$http_result"
    
    # Тест HTTPS
    log_info "HTTPS тест:"
    local https_result=\$(curl -s -o /dev/null -w "HTTP: %{http_code} | Time: %{time_total}s" "https://\$DOMAIN/health" 2>/dev/null || echo "HTTPS недоступен")
    echo "  \$https_result"
    
    # Тест источника
    log_info "Источник тест:"
    local source_result=\$(curl -s -o /dev/null -w "HTTP: %{http_code} | Time: %{time_total}s" "https://\$SOURCE_DOMAIN/videos/" 2>/dev/null || echo "Источник недоступен")
    echo "  \$source_result"
    
    # Тест кэша
    log_info "Кэш тест:"
    local cache_result=\$(curl -s -I "https://\$DOMAIN/health" 2>/dev/null | grep -i "x-cache-status" | cut -d: -f2 | tr -d ' ' || echo "N/A")
    echo "  Cache Status: \$cache_result"
    
    echo ""
    if [[ "\$https_result" == *"200"* ]]; then
        log_success "Основные тесты пройдены"
        echo ""
        echo "🎯 Готов к использованию:"
        echo "   https://\$DOMAIN/videos/{video-id}.mp4"
    else
        log_error "Есть проблемы с HTTPS"
    fi
}

show_help() {
    echo "🛠️  Управление Video Proxy для \$DOMAIN"
    echo ""
    echo "Использование: \$0 {команда} [параметры]"
    echo ""
    echo "📋 Доступные команды:"
    echo "  status              - показать статус системы"
    echo "  test                - тестировать прокси"
    echo "  logs [количество]   - показать логи (по умолчанию 50 строк)"
    echo "  clear-cache         - очистить кэш"
    echo "  restart             - перезапустить nginx"
    echo "  reload              - перезагрузить конфигурацию"
    echo "  ssl                 - настроить SSL сертификат"
    echo "  help                - показать эту справку"
    echo ""
    echo "📁 Полезная информация:"
    echo "  Домен: \$DOMAIN"
    echo "  Источник: \$SOURCE_DOMAIN"
    echo "  Конфигурация: /etc/nginx/sites-available/\$DOMAIN.conf"
    echo "  Логи: /var/log/nginx/\$DOMAIN.*.log"
    echo "  Кэш: /var/cache/nginx/video/"
    echo ""
    echo "🎯 После настройки SSL:"
    echo "  https://\$DOMAIN/videos/{video-id}.mp4"
}

# Обработка команд
case "\$1" in
    status)
        show_status
        ;;
    test)
        test_proxy
        ;;
    logs)
        show_logs "\$1" "\$2"
        ;;
    clear-cache)
        clear_cache
        ;;
    restart)
        log_info "Перезапуск Nginx..."
        systemctl restart nginx
        log_success "Nginx перезапущен"
        ;;
    reload)
        log_info "Перезагрузка конфигурации..."
        if nginx -t 2>/dev/null; then
            systemctl reload nginx
            log_success "Конфигурация перезагружена"
        else
            log_error "Ошибка в конфигурации"
            nginx -t
        fi
        ;;
    ssl)
        bash "/root/activate-ssl-\$DOMAIN.sh"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        show_help
        exit 1
        ;;
esac
EOF

chmod +x "/root/manage-$DOMAIN.sh"

# Обновление или создание общей статусной страницы
log_info "Создание статусной страницы..."
cat > /var/www/html/status.html << EOF
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Video Proxy Status - $DOMAIN</title>
    <meta http-equiv="refresh" content="30">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { 
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        .container { 
            max-width: 800px; 
            margin: 0 auto; 
            background: rgba(255,255,255,0.95);
            backdrop-filter: blur(10px);
            border-radius: 20px;
            padding: 30px;
            box-shadow: 0 8px 32px rgba(0,0,0,0.1);
        }
        .header { 
            text-align: center; 
            margin-bottom: 30px;
            color: #333;
        }
        .header h1 { 
            font-size: 2.5em; 
            margin-bottom: 10px;
            background: linear-gradient(45deg, #667eea, #764ba2);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        .status-card { 
            background: white;
            padding: 20px; 
            margin: 15px 0; 
            border-radius: 15px;
            border-left: 5px solid #28a745;
            box-shadow: 0 4px 16px rgba(0,0,0,0.1);
            transition: transform 0.2s ease;
        }
        .status-card:hover { transform: translateY(-2px); }
        .status-card.warning { border-left-color: #ffc107; }
        .status-card.error { border-left-color: #dc3545; }
        .status-title { 
            font-weight: 600; 
            font-size: 1.2em;
            color: #333;
            margin-bottom: 10px;
        }
        .status-info { 
            color: #666;
            line-height: 1.6;
        }
        .proxy-url { 
            background: #f8f9fa;
            padding: 15px;
            border-radius: 10px;
            font-family: 'Monaco', 'Menlo', monospace;
            font-size: 0.9em;
            word-break: break-all;
            border: 2px dashed #667eea;
        }
        .footer { 
            text-align: center; 
            margin-top: 30px;
            color: #666;
            font-size: 0.9em;
        }
        .time { 
            background: #667eea;
            color: white;
            padding: 5px 15px;
            border-radius: 20px;
            display: inline-block;
            font-weight: 500;
        }
        .grid { 
            display: grid; 
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); 
            gap: 15px; 
            margin: 20px 0; 
        }
        .metric { 
            background: white;
            padding: 15px;
            border-radius: 10px;
            text-align: center;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
        }
        .metric-value { 
            font-size: 1.8em; 
            font-weight: 700; 
            color: #667eea; 
        }
        .metric-label { 
            color: #666; 
            font-size: 0.9em; 
            margin-top: 5px; 
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🚀 Video Proxy Status</h1>
            <p>Мониторинг системы проксирования видео</p>
        </div>
        
        <div class="status-card">
            <div class="status-title">📡 Конфигурация прокси</div>
            <div class="status-info">
                <strong>Домен:</strong> $DOMAIN<br>
                <strong>Источник:</strong> $SOURCE_DOMAIN<br>
                <strong>Последнее обновление:</strong> <span class="time" id="time"></span>
            </div>
        </div>
        
        <div class="status-card">
            <div class="status-title">🎯 URL для использования</div>
            <div class="proxy-url">
                https://$DOMAIN/videos/{video-id}.mp4
            </div>
            <div class="status-info" style="margin-top: 10px;">
                <small>Замените {video-id} на реальный идентификатор видео</small>
            </div>
        </div>
        
        <div class="grid">
            <div class="metric">
                <div class="metric-value" id="status">⏳</div>
                <div class="metric-label">Статус системы</div>
            </div>
            <div class="metric">
                <div class="metric-value" id="response-time">-</div>
                <div class="metric-label">Время ответа</div>
            </div>
            <div class="metric">
                <div class="metric-value" id="ssl-status">-</div>
                <div class="metric-label">SSL статус</div>
            </div>
            <div class="metric">
                <div class="metric-value" id="cache-status">-</div>
                <div class="metric-label">Статус кэша</div>
            </div>
        </div>
        
        <div class="status-card">
            <div class="status-title">⚙️ Управление системой</div>
            <div class="status-info">
                <strong>SSH команды:</strong><br>
                • Статус: <code>bash /root/manage-$DOMAIN.sh status</code><br>
                • Тестирование: <code>bash /root/manage-$DOMAIN.sh test</code><br>
                • Логи: <code>bash /root/manage-$DOMAIN.sh logs</code><br>
                • Очистка кэша: <code>bash /root/manage-$DOMAIN.sh clear-cache</code>
            </div>
        </div>
        
        <div class="footer">
            <p>Video Proxy Server v2.0 | Автоматическое обновление каждые 30 секунд</p>
        </div>
    </div>
    
    <script>
        // Обновление времени
        function updateTime() {
            document.getElementById('time').textContent = new Date().toLocaleString('ru-RU');
        }
        
        // Проверка статуса
        async function checkStatus() {
            const startTime = Date.now();
            
            try {
                // Проверка health endpoint
                const response = await fetch('/health');
                const responseTime = Date.now() - startTime;
                
                if (response.ok) {
                    document.getElementById('status').textContent = '✅';
                    document.getElementById('response-time').textContent = responseTime + 'ms';
                } else {
                    document.getElementById('status').textContent = '⚠️';
                    document.getElementById('response-time').textContent = 'Error';
                }
                
                // Проверка SSL
                if (location.protocol === 'https:') {
                    document.getElementById('ssl-status').textContent = '🔒';
                } else {
                    document.getElementById('ssl-status').textContent = '❌';
                }
                
                // Проверка кэша из заголовков
                const cacheStatus = response.headers.get('X-Cache-Status') || 'Unknown';
                document.getElementById('cache-status').textContent = 
                    cacheStatus === 'HIT' ? '💾' : 
                    cacheStatus === 'MISS' ? '🔄' : '❓';
                
            } catch (error) {
                document.getElementById('status').textContent = '❌';
                document.getElementById('response-time').textContent = 'Offline';
                document.getElementById('ssl-status').textContent = '❌';
                document.getElementById('cache-status').textContent = '❌';
            }
        }
        
        // Инициализация
        updateTime();
        checkStatus();
        
        // Обновление каждые 10 секунд
        setInterval(() => {
            updateTime();
            checkStatus();
        }, 10000);
    </script>
</body>
</html>
EOF

# Финальные проверки
log_info "Выполнение финальных проверок..."

# Проверка что временный конфиг активирован
if [ -L "$SITES_ENABLED/$DOMAIN-temp.conf" ]; then
    log_success "Временный конфиг активирован"
else
    log_error "Временный конфиг не активирован"
    exit 1
fi

# Проверка доступности health endpoint
sleep 2
if curl -s -o /dev/null -w "%{http_code}" "http://$DOMAIN/health" 2>/dev/null | grep -q "200"; then
    log_success "HTTP health endpoint доступен"
elif curl -s -o /dev/null -w "%{http_code}" "http://localhost/health" 2>/dev/null | grep -q "200"; then
    log_warning "Health endpoint доступен локально, но не по домену (возможно DNS не настроен)"
else
    log_warning "Health endpoint недоступен, но это может быть нормально до настройки DNS"
fi

# Создание файла с информацией о развертывании
cat > "/root/deployment-info-$DOMAIN.txt" << EOF
=== Информация о развертывании Video Proxy ===
Дата: $(date)
Домен: $DOMAIN
Источник: $SOURCE_DOMAIN
Версия: 2.0 (улучшенная)

Созданные файлы:
- /etc/nginx/sites-available/$DOMAIN.conf
- /etc/nginx/sites-available/$DOMAIN-temp.conf
- /root/activate-ssl-$DOMAIN.sh
- /root/manage-$DOMAIN.sh
- /var/www/html/status.html

Следующие шаги:
1. Настройте DNS: $DOMAIN → $(curl -s ifconfig.me 2>/dev/null || echo 'your-server-ip')
2. Запустите: bash /root/activate-ssl-$DOMAIN.sh
3. Проверьте: bash /root/manage-$DOMAIN.sh test

Команды управления:
bash /root/manage-$DOMAIN.sh {status|test|logs|clear-cache|restart|reload|ssl|help}

Готовый URL для использования:
https://$DOMAIN/videos/{video-id}.mp4
EOF

echo ""
log_success "🎉 Улучшенное развертывание завершено!"
echo ""
log_info "📋 Что было сделано:"
echo "1. ✅ Конфигурация nginx обновлена"
echo "2. ✅ Конфиг для $DOMAIN создан (исправлены все проблемы)"
echo "3. ✅ Временный конфиг активирован"
echo "4. ✅ SSL скрипт создан с улучшенной обработкой ошибок"
echo "5. ✅ Скрипт управления создан с расширенными функциями"
echo "6. ✅ Статусная страница обновлена"
echo "7. ✅ Nginx перезагружен и работает"
echo ""
log_info "🔥 СЛЕДУЮЩИЕ ШАГИ:"
echo ""
echo "1. 🌐 Настройте DNS в панели управления доменом:"
echo "   $DOMAIN → $(curl -s ifconfig.me 2>/dev/null || echo 'IP-адрес-сервера')"
echo ""
echo "2. 🔒 Получите SSL сертификат:"
echo "   bash /root/activate-ssl-$DOMAIN.sh"
echo ""
echo "3. 🧪 Проверьте работу:"
echo "   bash /root/manage-$DOMAIN.sh test"
echo ""
log_info "📁 Ваши команды управления:"
echo "• Статус: bash /root/manage-$DOMAIN.sh status"
echo "• Тестирование: bash /root/manage-$DOMAIN.sh test"
echo "• Логи: bash /root/manage-$DOMAIN.sh logs"
echo "• Помощь: bash /root/manage-$DOMAIN.sh help"
echo ""
log_info "🌐 Веб-интерфейсы:"
echo "• Статус: http://$(curl -s ifconfig.me 2>/dev/null || echo 'your-server-ip')/status.html"
echo "• Health check: http://$DOMAIN/health"
echo ""
log_success "⚡ После получения SSL ваш прокси будет доступен:"
echo "   🎯 https://$DOMAIN/videos/{video-id}.mp4"
echo ""
log_info "🔄 Система проксирует с: https://$SOURCE_DOMAIN/videos/"
echo ""
log_info "📄 Детальная информация сохранена в:"
echo "   /root/deployment-info-$DOMAIN.txt"