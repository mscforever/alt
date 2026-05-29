#!/bin/bash

# Проверка на root
if [ "$EUID" -ne 0 ]; then
  echo "Запустите от имени root"
  exit 1
fi

# Добавляем /sbin в PATH для ALT Linux
export PATH=$PATH:/sbin

AUDITCFG="/etc/audit/auditd.conf"
AUDITRULES="/etc/audit/rules.d/audit.rules"
RSYSLOGCFG="/etc/rsyslog.d/fwd_to_siem.conf"
TARGETIP="10.8.190.21"

echo "=== Установка и настройка аудита для ALT Linux (auditd 2.8.5) ==="

# Установка audit
#echo "Установка audit..."
#apt-get update
#apt-get install -y audit

# Включение и запуск auditd
systemctl enable auditd --now

# Настройка auditd.conf
echo "Настройка $AUDITCFG"
sed -i 's/^max_log_file =.*/max_log_file = 50/' $AUDITCFG
sed -i 's/^num_logs =.*/num_logs = 40/' $AUDITCFG
sed -i 's/^log_file =.*/log_file = \/var\/log\/audit\/audit.log/' $AUDITCFG
sed -i 's/^name_format =.*/name_format = HOSTNAME/' $AUDITCFG
sed -i 's/^max_log_file_action =.*/max_log_file_action = ROTATE/' $AUDITCFG
sed -i 's/^space_left =.*/space_left = 512/' $AUDITCFG
sed -i 's/^space_left_action =.*/space_left_action = SYSLOG/' $AUDITCFG
sed -i 's/^admin_space_left =.*/admin_space_left = 256/' $AUDITCFG
sed -i 's/^admin_space_left_action =.*/admin_space_left_action = SYSLOG/' $AUDITCFG
sed -i 's/^disk_full_action =.*/disk_full_action = SYSLOG/' $AUDITCFG
sed -i 's/^disk_error_action =.*/disk_error_action = SYSLOG/' $AUDITCFG

# Настройка плагина syslog (для старой версии auditd 2.8.5)
echo "Настройка плагина syslog в /etc/audisp/plugins.d/syslog.conf"
mkdir -p /etc/audisp/plugins.d
cat > /etc/audisp/plugins.d/syslog.conf <<EOF
active = yes
direction = out
path = builtin_syslog
type = builtin
args = LOG_LOCAL6
format = string
EOF

# Перезапуск auditd для применения изменений
systemctl restart auditd

# Настройка rsyslog
echo "Установка и настройка rsyslog"
apt-get install -y rsyslog

cat > "$RSYSLOGCFG" <<'EOF'
# Отправка audit логов на SIEM (ALT Linux 9.2 compatible)

# Пересылка auditd логов (facility local6) через UDP
local6.*  @10.8.190.21:514

# Пересылка логов от audispd
:programname, isequal, "audispd"  @10.8.190.21:514
EOF

systemctl enable rsyslog --now

# Установка правил аудита
echo "Установка правил аудита"
cat > "$AUDITRULES" <<'EOF'
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
-w /etc/adduser.conf -k adduserconf
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
-w /etc/securetty -p wa -k login
-w /var/log/faillog -p wa -k login
-w /var/log/lastlog -p wa -k login
-w /var/log/tallylog -p wa -k login
-a exit,always -F arch=b64 -S execve -F uid=0 -k authentication_events
-a exit,always -F arch=b32 -S execve -F uid=0 -k authentication_events
-a exit,always -F arch=b64 -S bind -S connect -F success=0 -k network_events
-w /sys/bus/usb -p rwxa -k usb
EOF

# Загрузка правил
echo "Загрузка правил аудита..."
augenrules --load 2>&1

# Проверка
echo -e "\nУстановленные правила:"
auditctl -l

echo -e "\nПроверка плагинов:"
auditctl -s | grep -i plugin

# Проверка статуса сервисов
echo -e "\n=== Статус сервисов ==="
systemctl status auditd --no-pager | grep -E "Active|Loaded"
systemctl status rsyslog --no-pager | grep -E "Active|Loaded"

echo -e "\nГотово!"