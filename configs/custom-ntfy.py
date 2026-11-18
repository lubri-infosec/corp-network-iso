#!/usr/bin/env python3
import sys
import json
import urllib.request

alert_file = open(sys.argv[1])
hook_url = sys.argv[3]
alert_json = json.loads(alert_file.read())
alert_file.close()

level = alert_json.get('rule', {}).get('level', 0)
description = alert_json.get('rule', {}).get('description', 'Без описания')
agent_name = alert_json.get('agent', {}).get('name', 'Неизвестный узел')
srcip = alert_json.get('data', {}).get('srcip', '')
rule_id = alert_json.get('rule', {}).get('id', '')

priority = "urgent" if level >= 12 else ("high" if level >= 8 else "default")

msg_lines = [
    f"Узел: {agent_name}",
    f"Уровень: {level} (Rule ID: {rule_id})",
    f"Событие: {description}"
]
if srcip:
    msg_lines.append(f"IP источника: {srcip}")

message = "\n".join(msg_lines)
title = f"Wazuh SIEM [Level {level}]"

req = urllib.request.Request(
    hook_url,
    data=message.encode('utf-8'),
    headers={
        'Title': title.encode('utf-8'),
        'Priority': priority,
        'Tags': 'warning'
    }
)
urllib.request.urlopen(req, timeout=10)
sys.exit(0)
