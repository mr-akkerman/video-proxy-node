#!/bin/bash

# Скрипт для смены домена в существующей установке
# Использование: sudo bash change-domain.sh old-domain.com new-domain.com

set -e

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "❌ Использование: $0 old-domain.com new-domain.com"
    echo "Пример: $0 video.full.com video.test.com"
    exit 1
fi

OLD_DOMAIN="$1"
NEW_DOMAIN="$2"
SOURCE_DOMAIN="video.full.icu"
NGINX_CONF_DIR="/etc/nginx"
SITES_AVAILABLE="$NGINX_CONF_DIR/sites-available"
SITES_ENABLED="$NGINX_CONF_DIR/sites-enabled"

echo "🔄 Смена домена с $OLD_DOMAIN на $NEW_DOMAIN"

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo "❌ Этот скрипт должен быть запущен от root" 
   exit 1
fi

# Проверка существования старого конфига
if [ ! -f "$SITES_AVAILABLE/$OLD_DOMAIN.conf" ]; then
    echo "❌ Конфиг для $OLD_DOMAIN не найден!"
    echo "Доступные конфиги:"
    ls -la $SITES_AVAILABLE/*.conf 2>/dev/null || echo "Нет конфигов"
    exit 1
fi

# Создание бэкапа
echo "💾 Создание бэкапа..."
BACKUP_DIR="/root/domain-change-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p $BACKUP_DIR
cp -r $NGINX_CONF_DIR/* $BACKUP_DIR/
cp /root/manage-$OLD_DOMAIN.sh $BACKUP_DIR/ 2>/dev/null || true
cp /root/activate-ssl-$OLD_DOMAIN.sh $BACKUP_DIR/ 2>/dev/null || true
echo "Бэкап сохранен в: $BACKUP_DIR"

# Остановка старого конфига
echo "⏹️  Отключение старого конфига..."
rm -f $SITES_ENABLED/$OLD_DOMAIN.conf
rm -f $SITES_ENABLED/$OLD_DOMAIN-temp.conf

# Создание нового конфига на базе старого
echo "📄 Создание конфига для $NEW_DOMAIN..."
sed "s/$OLD_DOMAIN/$NEW_DOMAIN/g" $SITES_AVAILABLE/$OLD_DOMAIN.conf > $SITES_AVAILABLE/$NEW_DOMAIN.conf

# Создание временного конфига для нового домена
cat > $SITES_AVAILABLE/$NEW_DOMAIN-temp.conf << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $NEW_DOMAIN;
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location /health {
        access_log off;
        return 200 "healthy\\n";
        add_header Content-Type text/plain;
    }
    
    location / {
        return 200 "Server ready for SSL setup for $NEW_DOMAIN";
        add_header Content-Type text/plain;
    }
}
EOF

# Активация временного конфига
echo "🔧 Активация временного конфига для $NEW_DOMAIN..."
ln -sf $SITES_AVAILABLE/$NEW_DOMAIN-temp.conf $SITES_ENABLED/
nginx -t && systemctl reload nginx

# Создание нового SSL скрипта
echo "🔑 Создание SSL скрипта для $NEW_DOMAIN..."
cat > /root/activate-ssl-$NEW_DOMAIN.sh << EOF
#!/bin/bash

DOMAIN="$NEW_DOMAIN"
EMAIL="admin@$NEW_DOMAIN"

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
        
        # Обновление crontab (удаляем старый, добавляем новый)
        crontab -l | grep -v "certbot renew.*$OLD_DOMAIN" | crontab -
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

chmod +x /root/activate-ssl-$NEW_DOMAIN.sh

# Создание нового скрипта управления
echo "⚙️ Создание скрипта управления для $NEW_DOMAIN..."
cat > /root/manage-$NEW_DOMAIN.sh << EOF
#!/bin/bash

# Скрипт управления video proxy для $NEW_DOMAIN

DOMAIN="$NEW_DOMAIN"
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

chmod +x /root/manage-$NEW_DOMAIN.sh

# Обновление статусной страницы
echo "📄 Обновление статусной страницы..."
cat > /var/www/html/status.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Video Proxy Status - $NEW_DOMAIN</title>
    <meta http-equiv="refresh" content="30">
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .status { padding: 10px; margin: 10px 0; border-radius: 5px; }
        .ok { background-color: #d4edda; color: #155724; }
        .error { background-color: #f8d7da; color: #721c24; }
        .info { background-color: #d1ecf1; color: #0c5460; }
        .changed { background-color: #fff3cd; color: #856404; }
    </style>
</head>
<body>
    <h1>Video Proxy Status</h1>
    <div class="status changed">
        <strong>⚠️ Domain Changed:</strong> $OLD_DOMAIN → $NEW_DOMAIN
    </div>
    <div class="status info">
        <strong>New Domain:</strong> $NEW_DOMAIN<br>
        <strong>Source:</strong> $SOURCE_DOMAIN<br>
        <strong>Proxy URL:</strong> https://$NEW_DOMAIN/videos/{video-id}.mp4<br>
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

# Очистка старых файлов (опционально, с подтверждением)
echo ""
echo "🗑️ Хотите удалить старые файлы для $OLD_DOMAIN? (y/N)"
read -r response
if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    echo "Удаление старых файлов..."
    rm -f /root/manage-$OLD_DOMAIN.sh
    rm -f /root/activate-ssl-$OLD_DOMAIN.sh
    rm -f $SITES_AVAILABLE/$OLD_DOMAIN.conf
    rm -f $SITES_AVAILABLE/$OLD_DOMAIN-temp.conf
    echo "✅ Старые файлы удалены"
else
    echo "ℹ️ Старые файлы сохранены в бэкапе: $BACKUP_DIR"
fi

echo ""
echo "✅ Смена домена завершена!"
echo ""
echo "📋 Что было сделано:"
echo "1. ✅ Создан бэкап старой конфигурации"
echo "2. ✅ Отключен старый домен: $OLD_DOMAIN"
echo "3. ✅ Создан конфиг для нового домена: $NEW_DOMAIN"
echo "4. ✅ Активирован временный конфиг (без SSL)"
echo "5. ✅ Созданы новые скрипты управления"
echo "6. ✅ Nginx перезагружен"
echo ""
echo "🔥 СЛЕДУЮЩИЕ ШАГИ:"
echo "1. Настроить DNS для $NEW_DOMAIN на ваш сервер"
echo "2. Получить SSL сертификат:"
echo "   bash /root/activate-ssl-$NEW_DOMAIN.sh"
echo ""
echo "📁 Новые команды:"
echo "- Управление: bash /root/manage-$NEW_DOMAIN.sh"
echo "- SSL: bash /root/activate-ssl-$NEW_DOMAIN.sh"
echo "- Статус: http://your-server-ip/status.html"
echo ""
echo "⚠️ ВАЖНО:"
echo "- Старый домен $OLD_DOMAIN больше не работает"
echo "- Новый прокси будет: https://$NEW_DOMAIN/videos/your-video-id.mp4"
echo "- Не забудьте обновить ссылки в вашем JS плеере!"
echo ""
echo "🔄 Проксирует с: https://$SOURCE_DOMAIN/videos/"