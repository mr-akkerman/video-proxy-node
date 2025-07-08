#!/bin/bash

# Расширенный скрипт мониторинга video proxy
# Можно добавить в cron для автоматического мониторинга

LOG_FILE="/var/log/video-proxy-monitor.log"
DOMAIN="video.full.com"
ALERT_EMAIL="admin@${DOMAIN}"
CACHE_DIR="/var/cache/nginx/video"

# Функция логирования
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

# Проверка статуса Nginx
check_nginx_status() {
    if systemctl is-active --quiet nginx; then
        log "✅ Nginx активен"
        return 0
    else
        log "❌ Nginx неактивен!"
        return 1
    fi
}

# Проверка доступности endpoint'а
check_health_endpoint() {
    local response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/health 2>/dev/null)
    if [ "$response" = "200" ]; then
        log "✅ Health endpoint доступен (HTTP $response)"
        return 0
    else
        log "❌ Health endpoint недоступен (HTTP $response)"
        return 1
    fi
}

# Проверка SSL сертификата
check_ssl_certificate() {
    if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
        local expiry_date=$(openssl x509 -in "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" -noout -enddate | cut -d= -f2)
        local expiry_epoch=$(date -d "$expiry_date" +%s)
        local current_epoch=$(date +%s)
        local days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
        
        if [ $days_left -gt 30 ]; then
            log "✅ SSL сертификат валиден ($days_left дней до истечения)"
            return 0
        elif [ $days_left -gt 7 ]; then
            log "⚠️  SSL сертификат истекает через $days_left дней"
            return 1
        else
            log "❌ SSL сертификат истекает через $days_left дней!"
            return 2
        fi
    else
        log "❌ SSL сертификат не найден"
        return 3
    fi
}

# Проверка использования диска для кэша
check_cache_size() {
    if [ -d "$CACHE_DIR" ]; then
        local cache_size=$(du -s $CACHE_DIR | awk '{print $1}')
        local cache_size_gb=$((cache_size / 1024 / 1024))
        local disk_usage=$(df $CACHE_DIR | awk 'NR==2 {print $5}' | sed 's/%//')
        
        log "📊 Размер кэша: ${cache_size_gb}GB, использование диска: ${disk_usage}%"
        
        if [ $disk_usage -gt 90 ]; then
            log "⚠️  Критическое использование диска: ${disk_usage}%"
            return 1
        elif [ $disk_usage -gt 80 ]; then
            log "⚠️  Высокое использование диска: ${disk_usage}%"
            return 1
        fi
        return 0
    else
        log "❌ Директория кэша не найдена"
        return 1
    fi
}

# Проверка производительности
check_performance() {
    local connections=$(netstat -an | grep :443 | wc -l)
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    local memory_usage=$(free | awk 'NR==2{printf "%.1f", $3*100/$2}')
    
    log "📈 Активные HTTPS соединения: $connections"
    log "📈 Load Average: $load_avg"
    log "📈 Использование памяти: ${memory_usage}%"
    
    # Проверка критических значений
    if (( $(echo "$load_avg > 5.0" | bc -l) )); then
        log "⚠️  Высокая нагрузка: $load_avg"
        return 1
    fi
    
    if (( $(echo "$memory_usage > 90.0" | bc -l) )); then
        log "⚠️  Высокое использование памяти: ${memory_usage}%"
        return 1
    fi
    
    return 0
}

# Проверка логов на ошибки
check_error_logs() {
    local recent_errors=$(tail -100 /var/log/nginx/error.log | grep "$(date '+%Y/%m/%d')" | grep -E "(error|crit|alert|emerg)" | wc -l)
    
    if [ $recent_errors -gt 0 ]; then
        log "⚠️  Найдено $recent_errors ошибок в логах за сегодня"
        log "Последние ошибки:"
        tail -10 /var/log/nginx/error.log | grep -E "(error|crit|alert|emerg)" | tail -3 | while read line; do
            log "  $line"
        done
        return 1
    else
        log "✅ Критических ошибок в логах не найдено"
        return 0
    fi
}

# Тест прокси (опционально)
test_proxy_functionality() {
    if [ "$1" = "--test-proxy" ]; then
        log "🧪 Тестирование прокси функциональности..."
        
        # Тест основного endpoint'а
        local test_response=$(curl -s -o /dev/null -w "%{http_code}:%{time_total}" "https://${DOMAIN}/health" 2>/dev/null)
        local http_code=$(echo $test_response | cut -d: -f1)
        local response_time=$(echo $test_response | cut -d: -f2)
        
        if [ "$http_code" = "200" ]; then
            log "✅ HTTPS endpoint работает (время ответа: ${response_time}s)"
        else
            log "❌ HTTPS endpoint недоступен (HTTP $http_code)"
            return 1
        fi
    fi
    return 0
}

# Функция очистки старых логов
cleanup_old_logs() {
    if [ "$1" = "--cleanup" ]; then
        log "🧹 Очистка старых логов мониторинга..."
        find /var/log -name "video-proxy-monitor.log.*" -mtime +30 -delete
        
        # Ротация текущего лога если он больше 10MB
        if [ -f "$LOG_FILE" ]; then
            local log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null)
            if [ $log_size -gt 10485760 ]; then  # 10MB
                mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d_%H%M%S)"
                log "Лог ротирован из-за размера"
            fi
        fi
    fi
}

# Отправка уведомлений (при наличии mail)
send_alert() {
    local message="$1"
    local severity="$2"
    
    if command -v mail &> /dev/null && [ -n "$ALERT_EMAIL" ]; then
        echo "$message" | mail -s "Video Proxy Alert [$severity]" "$ALERT_EMAIL"
        log "📧 Уведомление отправлено на $ALERT_EMAIL"
    fi
}

# Основная функция мониторинга
main_monitoring() {
    log "🔍 Начало проверки системы..."
    
    local issues=0
    local critical_issues=0
    
    # Базовые проверки
    check_nginx_status || ((issues++))
    check_health_endpoint || ((issues++))
    
    # Проверка SSL
    check_ssl_certificate
    local ssl_status=$?
    if [ $ssl_status -eq 2 ] || [ $ssl_status -eq 3 ]; then
        ((critical_issues++))
    elif [ $ssl_status -eq 1 ]; then
        ((issues++))
    fi
    
    # Остальные проверки
    check_cache_size || ((issues++))
    check_performance || ((issues++))
    check_error_logs || ((issues++))
    test_proxy_functionality "$1" || ((critical_issues++))
    
    # Итоговый отчет
    if [ $critical_issues -gt 0 ]; then
        log "🚨 КРИТИЧЕСКИЕ ПРОБЛЕМЫ: $critical_issues, Обычные проблемы: $issues"
        send_alert "Video proxy имеет критические проблемы! Проверьте логи." "CRITICAL"
        exit 2
    elif [ $issues -gt 0 ]; then
        log "⚠️  Найдено проблем: $issues"
        send_alert "Video proxy имеет некоторые проблемы. Рекомендуется проверка." "WARNING"
        exit 1
    else
        log "✅ Все проверки пройдены успешно"
        exit 0
    fi
}

# Показ использования
show_usage() {
    echo "Использование: $0 [опции]"
    echo ""
    echo "Опции:"
    echo "  --test-proxy    Включить тестирование прокси функциональности"
    echo "  --cleanup      Очистить старые логи"
    echo "  --help         Показать эту справку"
    echo ""
    echo "Примеры:"
    echo "  $0                    # Базовый мониторинг"
    echo "  $0 --test-proxy      # Полный мониторинг с тестом прокси"
    echo "  $0 --cleanup         # Мониторинг + очистка логов"
    echo ""
    echo "Для автоматического мониторинга добавьте в crontab:"
    echo "  */5 * * * * /root/monitoring.sh >/dev/null 2>&1"
}

# Обработка аргументов
case "$1" in
    --help|-h)
        show_usage
        exit 0
        ;;
    *)
        cleanup_old_logs "$1"
        main_monitoring "$1"
        ;;
esac