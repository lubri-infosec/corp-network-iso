#!/bin/bash
BACKUP_DIR="/var/backups/vtech_ad"
TMP_DIR="/tmp/samba_ad_tmp"
DATE=$(date +%Y-%m-%d_%H-%M)
ARCHIVE_NAME="ad_backup_${DATE}.tar.gz.enc"

rm -rf "$TMP_DIR" && mkdir -p "$TMP_DIR"

samba-tool domain backup offline --targetdir="$TMP_DIR" > /dev/null 2>&1

tar -czf - -C "$TMP_DIR" . | openssl enc -aes-256-cbc -salt -pbkdf2 -pass file:/root/.backup_pass -out "${BACKUP_DIR}/${ARCHIVE_NAME}"

rm -rf "$TMP_DIR"
chmod 600 "${BACKUP_DIR}/${ARCHIVE_NAME}"

find "$BACKUP_DIR" -type f -name "*.enc" -mtime +7 -delete
