#!/bin/bash
# =====================================================
# Скрипт настройки auditd + rsyslog + отправка на SIEM
# ALT Linux 9.2
# =====================================================

set -e

# Переменные
SIEM_SERVER="10.8.190.21"
SIEM_PORT="514"
AUDIT_RULES_FILE="/etc/audit/rules.d/99-custom.rules"
AUDIT_CFG="/etc/audit/auditd.conf"
RSYSLOG_CFG="/etc/rsyslog.d/99-audit-siem.conf"

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
    echo -e "${RED}Ошибка: Скрипт должен запускаться от root${NC}"
    exit 1
fi

# 2. Добавляем /sbin в PATH для ALT Linux
export PATH=$PATH:/sbin

# 3. Установка пакетов
echo -e "\n${YELLOW}[1/6] Установка пакетов...${NC}"
#apt-get update -qq
#apt-get install -y audit rsyslog tcpdump
curl -O https://raw.githubusercontent.com/mscforever/alt/main/libauparse0-2.8.5-alt5.git.e4021a9.x86_64.rpm
apt-get install /root/libauparse0-2.8.5-alt5.git.e4021a9.x86_64.rpm

curl -O https://raw.githubusercontent.com/mscforever/alt/main/audit-2.8.5-alt5.git.e4021a9.x86_64.rpm
apt-get install /root/audit-2.8.5-alt5.git.e4021a9.x86_64.rpm

curl -O https://raw.githubusercontent.com/mscforever/alt/main/libfastjson-0.99.8-alt2.x86_64.rpm
apt-get install /root/libfastjson-0.99.8-alt2.x86_64.rpm

curl -O https://raw.githubusercontent.com/mscforever/alt/main/libestr-0.1.11-alt1.x86_64.rpm
apt-get install /root/libestr-0.1.11-alt1.x86_64.rpm

curl -O https://raw.githubusercontent.com/mscforever/alt/main/rsyslog-8.1901.0-alt1.x86_64.rpm
apt-get install /root/rsyslog-8.1901.0-alt1.x86_64.rpm

# 4. Настройка auditd.conf
echo -e "\n${YELLOW}[2/6] Настройка auditd.conf...${NC}"
cp -n "$AUDIT_CFG" "${AUDIT_CFG}.backup" 2>/dev/null || true

sed -i 's/^max_log_file =.*/max_log_file = 50/' "$AUDIT_CFG"
sed -i 's/^num_logs =.*/num_logs = 40/' "$AUDIT_CFG"
sed -i 's/^log_file =.*/log_file = \/var\/log\/audit\/audit.log/' "$AUDIT_CFG"
sed -i 's/^name_format =.*/name_format = HOSTNAME/' "$AUDIT_CFG"
sed -i 's/^max_log_file_action =.*/max_log_file_action = ROTATE/' "$AUDIT_CFG"
sed -i 's/^space_left =.*/space_left = 512/' "$AUDIT_CFG"
sed -i 's/^space_left_action =.*/space_left_action = SYSLOG/' "$AUDIT_CFG"
sed -i 's/^admin_space_left =.*/admin_space_left = 256/' "$AUDIT_CFG"
sed -i 's/^admin_space_left_action =.*/admin_space_left_action = SYSLOG/' "$AUDIT_CFG"
sed -i 's/^disk_full_action =.*/disk_full_action = SYSLOG/' "$AUDIT_CFG"
sed -i 's/^disk_error_action =.*/disk_error_action = SYSLOG/' "$AUDIT_CFG"

# 5. Настройка правил аудита
echo -e "\n${YELLOW}[3/6] Настройка правил аудита...${NC}"
cat > "$AUDIT_RULES_FILE" << 'INNEREOF'
-D
-b 8192
--backlog_wait_time 60000
-f 1

-w /var/log -p w -k var_log_changes
-w /etc/group -p wa -k etcgroup
-w /etc/passwd -p wa -k etcpasswd
-w /etc/gshadow -k etcgroup
-w /etc/shadow -k etcpasswd
-w /etc/security/opasswd -k opasswd
#-w /etc/adduser.conf -k adduserconf
-w /etc/sudoers -p wa -k actions
-w /etc/sudoers.d/ -p wa -k actions
-w /usr/bin/passwd -p x -k passwd_modification
-w /usr/bin/gpasswd -p x -k gpasswd_modification
-w /usr/sbin/groupadd -p x -k group_modification
-w /usr/sbin/groupmod -p x -k group_modification
-w /usr/sbin/addgroup -p x -k group_modification
-w /usr/sbin/useradd -p x -k user_modification
-w /usr/sbin/userdel -p x -k user_modification
-w /usr/sbin/usermod -p x -k user_modification
-w /usr/sbin/adduser -p x -k user_modification
-w /etc/login.defs -p wa -k login
#-w /etc/securetty -p wa -k login
-w /var/log/faillog -p wa -k login
-w /var/log/lastlog -p wa -k login
-w /var/log/tallylog -p wa -k login

-a exit,always -F arch=b64 -S execve -F uid=0 -k authentication_events
-a exit,always -F arch=b32 -S execve -F uid=0 -k authentication_events
-a exit,always -F arch=b64 -S bind -S connect -F success=0 -k network_events

-w /sys/bus/usb -p rwxa -k usb
INNEREOF

# Загрузка правил
/sbin/augenrules --load 2>/dev/null || /sbin/auditctl -R "$AUDIT_RULES_FILE" 2>/dev/null

# 6. Применение конфигурации auditd
echo -e "\n${YELLOW}[4/6] Применение конфигурации auditd...${NC}"
kill -SIGHUP $(pidof auditd) 2>/dev/null || true
systemctl start auditd 2>/dev/null || true
echo -e "${GREEN}  ✓ Конфигурация применена${NC}"

# 7. Настройка rsyslog (новый синтаксис)
echo -e "\n${YELLOW}[5/6] Настройка rsyslog...${NC}"
cat > "$RSYSLOG_CFG" << EOF

# Загрузка модуля imfile для чтения файлов
module(load="imfile" mode="inotify")

# Чтение audit.log
input(type="imfile"
      File="/var/log/audit/audit.log"
      Tag="auditd"
      Facility="local6"
      Severity="info"
      startmsg.regex="^type="
      FreshStartTail="off")
# Фильтр для audit логов (local6 facility + info severity)
if (\$syslogfacility-text == "local6" and \$syslogpriority-text == "info") then {
    action(type="omfwd"
           name="pt_linux_audit"
           target="${SIEM_SERVER}"
           port="${SIEM_PORT}"
           protocol="udp"
           action.repeatedmsgcontainsoriginalmsg="off")
}

EOF

systemctl restart rsyslog
systemctl enable rsyslog

# 8. Проверка работоспособности
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

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}Настройка ЗАВЕРШЕНА!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Просмотр логов: ${YELLOW}tail -f /var/log/audit/audit.log${NC}"
echo -e "Проверка отправки: ${YELLOW}tcpdump -i any udp port ${SIEM_PORT} -n${NC}"
echo -e "\n${GREEN}Готово!${NC}"
