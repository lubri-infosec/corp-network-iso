#!/bin/bash
BACKUP_DIR="/var/backups/vtech_siem"
DATE=$(date +%Y-%m-%d_%H-%M)
ARCHIVE_NAME="siem_configs_${DATE}.tar.gz.enc"

tar -czf - \
  /var/ossec/etc/ossec.conf \
  /var/ossec/etc/rules/local_rules.xml \
  /var/ossec/integrations/custom-ntfy* \
  /etc/ssh/sshd_config \
  /etc/iptables/rules.v4 2>/dev/null | \
  openssl enc -aes-256-cbc -salt -pbkdf2 -pass file:/root/.backup_pass -out "${BACKUP_DIR}/${ARCHIVE_NAME}"

chmod 600 "${BACKUP_DIR}/${ARCHIVE_NAME}"
find "$BACKUP_DIR" -type f -name "*.enc" -mtime +7 -delete
