# NLBInstaller (Not LTE Blocker)

**NLBInstaller — это скрипт, который автоматически отследит и заблокирует входящие подключения не из подсетей мобильных операторов. Используются сервисы proxycheck.io и ip-api.com.**

# Использование

**`bash <(curl -Ls https://raw.githubusercontent.com/sngvy/NLBInstaller/refs/heads/main/NLBInstaller.sh)`**

# Технические детали

- **Сбор: Анализирует access.log и собирает активные IP (TCP/UDP).**
- **Анализ: Проверяет список IP через proxycheck.io и ip-api.com на принадлежность к мобильным операторам с помощью консесуса.**
- **Вердикт: Если тип соединения Residential (домашний) или Business (офисный) — IP мгновенно улетает в DROP через таблицу RAW.**
- **Автоматизация: Работает в фоне каждые 15 минут через cron и восстанавливается после перезагрузки через systemd.**
