#!/bin/bash
# =====================================================
# Скрипт настройки auditd + rsyslog + отправка на SIEM
# ALT Linux 9.2
# =====================================================

set -e

# Переменные
SIEM_SERVER="10.8.190.21"
SIEM_PORT="514"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Настройка auditd + rsyslog + SIEM${NC}"
echo -e "${GREEN}========================================${NC}"

# 1. Проверка прав
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Ошибка: Запустите от root${NC}"
    exit 1
fi

# 2. Добавляем /sbin и /usr/sbin в PATH
export PATH=$PATH:/sbin:/usr/sbin

# 3. Установка пакетов
echo -e "\n${YELLOW}[1/6] Установка пакетов...${NC}"
apt-get update -qq
apt-get install -y audit rsyslog tcpdump

# 3.1 Установка заранее скачанных пакетов



# 4. Настройка auditd.conf
echo -e "\n${YELLOW}[2/6] Настройка auditd.conf...${NC}"
cp -n /etc/audit/auditd.conf /etc/audit/auditd.conf.backup 2>/dev/null || true

sed -i 's/^max_log_file =.*/max_log_file = 50/' /etc/audit/auditd.conf
sed -i 's/^num_logs =.*/num_logs = 40/' /etc/audit/auditd.conf
sed -i 's/^name_format =.*/name_format = HOSTNAME/' /etc/audit/auditd.conf
sed -i 's/^space_left =.*/space_left = 512/' /etc/audit/auditd.conf
sed -i 's/^admin_space_left =.*/admin_space_left = 256/' /etc/audit/auditd.conf

# 5. Настройка правил аудита
echo -e "\n${YELLOW}[3/6] Настройка правил аудита...${NC}"
cat > /etc/audit/rules.d/99-custom.rules << 'INNEREOF'
-D
-b 8192
--backlog_wait_time 60000
-f 1

-w /var/log -p w -k var_log_changes
-w /etc/group -p wa -k etcgroup
-w /etc/passwd -p wa -k etcpasswd
-w /etc/shadow -k etcpasswd
-w /etc/sudoers -p wa -k actions
-w /usr/bin/passwd -p x -k passwd_modification
-w /usr/sbin/useradd -p x -k user_modification
-w /usr/sbin/userdel -p x -k user_modification
-w /usr/sbin/usermod -p x -k user_modification

-a exit,always -F arch=b64 -S execve -F uid=0 -k authentication_events
-a exit,always -F arch=b32 -S execve -F uid=0 -k authentication_events
-a exit,always -F arch=b64 -S bind -S connect -F success=0 -k network_events
INNEREOF

# Загрузка правил
augenrules --load 2>/dev/null || auditctl -R /etc/audit/rules.d/99-custom.rules 2>/dev/null

# 6. Применение конфигурации
echo -e "\n${YELLOW}[4/6] Применение конфигурации auditd...${NC}"
kill -SIGHUP $(pidof auditd) 2>/dev/null || true
systemctl start auditd 2>/dev/null || true
systemctl enable auditd 2>/dev/null || true

# 7. Настройка rsyslog
echo -e "\n${YELLOW}[5/6] Настройка rsyslog...${NC}"
cat > /etc/rsyslog.d/99-audit-siem.conf << EOF
module(load="imfile" mode="inotify")

input(type="imfile"
      File="/var/log/audit/audit.log"
      Tag="auditd"
      Facility="local6"
      Severity="info"
      startmsg.regex="^type="
      FreshStartTail="off")

local6.*    /var/log/audit-local.log
local6.*    @${SIEM_SERVER}:${SIEM_PORT}
EOF

systemctl restart rsyslog
systemctl enable rsyslog

# 8. Проверка
echo -e "\n${YELLOW}[6/6] Проверка работоспособности...${NC}"
sleep 3

if pidof auditd >/dev/null; then
    echo -e "${GREEN}  ✓ auditd работает (PID: $(pidof auditd))${NC}"
else
    echo -e "${RED}  ✗ auditd НЕ работает${NC}"
fi

if systemctl is-active --quiet rsyslog; then
    echo -e "${GREEN}  ✓ rsyslog работает${NC}"
else
    echo -e "${RED}  ✗ rsyslog НЕ работает${NC}"
fi

# Тест аудита (с полными путями)
/usr/sbin/useradd audittest123 2>/dev/null
/usr/sbin/userdel audittest123 2>/dev/null
sleep 2

if /sbin/ausearch -k user_modification --format text 2>/dev/null | grep -q "audittest123"; then
    echo -e "${GREEN}  ✓ Тестовое событие (useradd/userdel) успешно обработано${NC}"
else
    echo -e "${RED}  ✗ Тестовое событие НЕ обнаружено${NC}"
fi

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}Настройка ЗАВЕРШЕНА!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Просмотр логов: ${YELLOW}tail -f /var/log/audit-local.log${NC}"
echo -e "Проверка отправки: ${YELLOW}tcpdump -i any udp port ${SIEM_PORT} -n${NC}"
echo -e "\n${GREEN}Готово!${NC}"

chmod +x /tmp/audit01.sh
/root/audit01.sh
