#!/bin/bash

# Проверка на root
if [ "$EUID" -ne 0 ]; then
  echo "Запустите от имени root"
  exit 1
fi

AUDITCFG="/etc/audit/auditd.conf"
AUDITRULES="/etc/audit/rules.d/audit.rules"
RSYSLOGCFG="/etc/rsyslog.d/fwd_to_siem.conf"
TARGETIP="10.8.190.21"

echo "=== Установка и настройка аудита для ALT Linux ==="

# Обновление списка пакетов
echo "Обновление списка пакетов..."
apt-get update

echo "Установка и включение auditd"
apt-get install -y auditd audispd-plugins
systemctl enable auditd --now

echo "Установка параметров конфигфайла $AUDITCFG"
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

echo "Установка параметров конфигфайла /etc/audit/plugins.d/syslog.conf"
# В ALT Linux файл может называться иначе или отсутствовать
if [ -f /etc/audit/plugins.d/syslog.conf ]; then
    sed -i 's/^active =.*/active = yes/' /etc/audit/plugins.d/syslog.conf
else
    echo "Внимание: /etc/audit/plugins.d/syslog.conf не найден, создаю..."
    cat > /etc/audit/plugins.d/syslog.conf <<EOF
active = yes
direction = out
path = builtin_syslog
type = always
format = string
EOF
fi

echo "Перезапуск auditd для применения изменений"
systemctl restart auditd

echo "Установка и настройка rsyslog"
apt-get install -y rsyslog

cat > "$RSYSLOGCFG" <<EOF
if (\$syslogfacility-text == "local6" or \$syslogpriority-text == "info") and not re_match(\$syslogfacility-text,"(mail|lpr|news|uucp|cron)") then {
 action(type="omfwd" name="pt_linux_audit" target="$TARGETIP" port="514" protocol="udp" action.repeatedmsgcontainsoriginalmsg="off")
}
if (\$programname == "audispd") then {
 action(type="omfwd" name="pt_linux_audit" target="$TARGETIP" port="514" protocol="udp" action.repeatedmsgcontainsoriginalmsg="off")
 stop
}
EOF

systemctl enable rsyslog --now
systemctl restart systemd-journald

echo "Установка правил аудита"
cat > "$AUDITRULES" <<EOF
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

echo "Обновление правил аудита"
augenrules --load >> /dev/null

# Проверка загрузки правил
if [ $? -eq 0 ]; then
    echo "Правила успешно загружены"
else
    echo "Ошибка при загрузке правил"
fi

echo "Установленные правила:"
auditctl -l

# Проверка статуса сервисов
echo -e "\n=== Статус сервисов ==="
systemctl status auditd --no-pager | grep -E "Active|Loaded"
systemctl status rsyslog --no-pager | grep -E "Active|Loaded"

echo "Готово"