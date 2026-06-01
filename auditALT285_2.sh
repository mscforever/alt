#!/bin/bash

# Проверка на root
if [ "$EUID" -ne 0 ]; then
  echo "Запустите от имени root"
  exit 1
fi

# Добавляем /sbin в PATH
export PATH=$PATH:/sbin

AUDITCFG="/etc/audit/auditd.conf"
AUDITRULES="/etc/audit/rules.d/audit.rules"
AUDISP_REMOTE_CONF="/etc/audisp/audisp-remote.conf"
AUDISP_PLUGIN_CONF="/etc/audisp/plugins.d/au-remote.conf"
TARGETIP="10.8.190.21"

echo "=== Установка и настройка аудита для ALT Linux 9.2 ==="

# Установка audit (если не установлен)
#if ! command -v auditctl &> /dev/null; then
 # apt-get update
  #apt-get install -y audit
#fi

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

# Настройка audisp-remote для отправки на SIEM
echo "Настройка audisp-remote для отправки на $TARGETIP"
cat > "$AUDISP_REMOTE_CONF" <<EOF
remote_server = $TARGETIP
port = 514
EOF

cat > "$AUDISP_PLUGIN_CONF" <<EOF
active = yes
direction = out
path = /sbin/audisp-remote
type = always
EOF

# Перезагрузка конфигурации auditd
systemctl kill -s HUP auditd

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
augenrules --load 2>/dev/null

# Проверка
echo -e "\nУстановленные правила:"
auditctl -l | head -10

echo -e "\nСтатус auditd:"
systemctl status auditd --no-pager | grep Active

echo -e "\nГотово!"