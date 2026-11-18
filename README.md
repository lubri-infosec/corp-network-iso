# Развертывание защищенного сегмента сети с SIEM Wazuh, Active Directory и криптозащитой данных

Мой проект по построению изолированной корпоративной сети в VirtualBox. Настроил маршрутизацию и фильтрацию трафика через OPNsense, развернул SIEM систему Wazuh, открыл домен и настроил контроллер DC, проверил детекты атак и реализовал защиту базы данных с помощью шифрования. К проекту также прилагается пакет документации (Политика ИБ и Регламент).

## Схема стенда

Весь контур работает в изолированной виртуальной сети **`vtech-lan`** (`10.10.1.0/24`) внутри Oracle VirtualBox:

<img width="1042" height="702" alt="network_topology" src="https://github.com/user-attachments/assets/d8f5a3c3-70ae-4763-b6c9-e4fe34eece43" />

* **OPNsense** — шлюз и межсетевой экран. Раздает адреса по DHCP, выпускает сеть наружу через NAT, фильтрует трафик и шлет логи в SIEM.
* **UbuntuDC-VTech (`10.10.1.10`)** - контроллер домена Active Directory (`vtech.local`). Отвечает за централизованную аутентификацию Kerberos , внутренний DNS и ролевую модель доступа. Диск зашифрован через **LUKS** на этапе установки ОС. 
* **UbuntuServer-VTech (`10.10.1.92`)** — сервер мониторинга. Установлен полный стек Wazuh (`all-in-one`: Indexer, Server, Manager, Dashboard). Диск зашифрован через **LUKS** на этапе установки ОС.
* **UbuntuManagerISO-VTech** — рабочее место администратора ИБ. Нужна для доступа к веб-интерфейсу Wazuh Dashboard по HTTPS (порт 443) прямо изнутри изолированного сегмента. Добавлен в домен vtech.local, вход выполняется под доменной учетной записью Администратора ИБ (`secadmin@vtech.local`) группы Domain Admins с правами sudoers.
* **UbuntuARM-VTech** — рабочая станция обычного сотрудника. Здесь лежат тестовые данные (`vtech_secret_db`) и имитируются атаки. Добавлен в домен vtech.local, вход выполняется под доменной учетной записью Сотрудника (`employee1@vtech.local`) без прав sudo.

## Что было сделано

### Сеть, OPNsense и сбор логов
* Перевел сервер Wazuh на статический IP (`10.10.1.92`) через **Netplan**, чтобы не плавала адресация.
* В **OPNsense** настроил правила Destination NAT для проброса 443 порта на сервер Wazuh, а в самом VirtualBox пробросил порты `443` и `8443`.
* В службе Dnsmasq DNS & DHCP на OPNsense прописал опции dns-server (`10.10.1.10`) и domain-name (`vtech.local`), чтобы все рабочие станции автоматически находили контроллер домена.
* Столкнулся с тем, что хостовая **РЕД ОС** резала локальные порты, поэтому пришлось развернуть отдельный АРМ админа внутри самой виртуальной сети.
* Настроил отправку системных логов и логов файрволла с OPNsense на Wazuh по **UDP 514** (`System → Settings → Logging`), а в `/var/ossec/etc/ossec.conf` разрешил прием логов из подсети `10.10.1.0/24`. Проверил, что пакеты реально долетают:
  ```bash
  sudo tcpdump -i enp0s3 udp port 514 -c 3
  ```

### Установка Wazuh и агентов
* Развернул Wazuh с флагом `-a`. Во время установки словил сетевые таймауты и битые зависимости `dpkg` — пришлось вручную чистить `/var/ossec`, удалять зависшие скрипты в `/var/lib/dpkg/info/`, править базу пакетов и обновлять кэш `apt`.
* Поставил агентов (`wazuh-agent`) на обе рабочие станции (`UbuntuManagerISO-VTech` и `armuser-vtech`), привязал их к серверу и проверил связь. Установил wazuh-agent также на контроллер домена (`UbuntuDC-VTech`) привязал его к серверу `10.10.1.92` и проверил поступление телеметрии в **Threat Hunting**.

### Шифрование базы и контроль целостности (FIM)
* Написал небольшой скрипт на **Python**, который создает базу **SQLite3** (`vtech_secret_db`) с тестовыми персональными данными сотрудников.
* Включил мониторинг папки с базой в реальном времени в конфиге агента `/var/ossec/etc/ossec.conf` (`realtime="yes" report_changes="yes"`).
* Зашифровал базу через **GPG** алгоритмом AES-256 (без сохранения пароля в системе), а исходный файл затер в 3 прохода с перезаписью нулями через `shred`:
  ```bash
  gpg --symmetric --cipher-algo AES256 vtech_secret_db
  shred -u -z -n 3 vtech_secret_db
  ```
* Убедился в панели Wazuh (модуль FIM), что система поймала все этапы: появление `.gpg` файла (`added`), перезапись открытого файла (`modified`) и его удаление (`deleted`).

### Имитация атак (Threat Hunting)
Чтобы проверить, как работают правила корреляции, сымитировал действия нарушителя на станции `armuser-vtech`:
* Попробовал подобрать пароль к руту через `su - root` и прочитать файл `/etc/shadow`.
* Создал и сразу удалил левую учетку для закрепления (`useradd h_backdoor && userdel h_backdoor`).
* Все события корректно прилетели в **Threat Hunting**: сработали правила на неудачную аутентификацию и создание нового пользователя.

### Аудит безопасности (SCA)
* Прогнал рабочую станцию через встроенный модуль **SCA** по профилю **CIS Ubuntu Linux 22.04 LTS Benchmark**.
* Изучил отчет о проверке, разобрал критичные несоответствия (например, отсутствие флага `nodev` при монтировании раздела `/tmp`) и посмотрел рекомендации по их устранению (Rationale и Remediation).

### Активное реагирование на атаки (Active Response)
* Настроил на сервере Wazuh Manager в (`/var/ossec/etc/ossec.conf`) автоматическую блокировку атакующих через встроенный скрипт `firewall-drop` по триггерам (`5712 / 5763`) матрицы **MITRE ATT&CK** локально на атакуемом узле `<location>local</location>` на 5 минут.
* Проверил защиту в действии: с ManagerISO (`10.10.1.58`) запустил брутфорс по SSH серверу на АРМ Сотрудника под фейковым пользователем.
* После многих неудачных попыток входа сработало правило **MITRE ATT&CK** - агент моментально заблокировал IP адрес Администратора ИБ через пакетный фильтр (`connection timed out`), следом через 5 минут снял блокировку процесс которой наглядно видно в (`active-responses.log`) и Threat Hunting (`rule.id 651 / 652`) на Wazuh Dashboard.
* Интегрировал контроллер домена **Samba AD DC** в контур мониторинга SIEM: включил аудит аутентификации и службы каталогов (`auth_audit`, `dsdb_audit`), настроил сбор журнала `log.samba` агентом Wazuh и добавил кастомные правила корреляции (`local_rules.xml`) для выявления ошибок входа и перебора паролей в домене.
* Настроил кастомную интеграцию **Wazuh Integrator (`custom-ntfy.py`)** с push-сервисом **ntfy.sh** для мгновенной доставки критических алертов (`lvl 7+`) на мобильное устройство Администратора ИБ в реальном времени (узел, уровень, событие).

### Служба каталогов Active Directory (Samba AD DC)
* Развернул контроллер домена (`UbuntuDC-VTech`), отключил systemd-resolved для освобождения 53-го порта и инициализировал домен vtech.local через samba-tool domain provision с перенаправлением внешних DNS-запросов на OPNsense (`10.10.1.1`).
* Создал организационную структуру подразделений OU и учетных записей согласно регламенту ИБ: OU - `Security Admins` учетная запись Администратора ИБ (secadmin добавлен в группу Domain Admins), OU - `Employees` учетная запись сотрудника employee1, OU - `Workstations` контейнер для введенных в домен рабочих станций (ManagerISO и armuser-vtech).
* Ввел оба АРМ в домен через связку `realmd` и `sssd`, настроил автоматическое создание домашних директорий (`mkhomedir`) и ограничил права sudoer исключительно для группы Domain Admins на рабочей станции Администратора ИБ.

### Безопасное администрирование по SSH (SSH Hardening)
* Сгенерировал на рабочем месте Администратора ИБ (`ManagerISO`) под доменной учетной записью `secadmin@vtech.local` пару асимметричных ключей по алгоритму **Ed25519** (`ssh-keygen -t ed25519`), защитил приватный ключ парольной фразой **Passphrase** и изолировал правами доступа `chmod 600`.
* Распространил открытый ключ (`id_ed25519.pub`) на критические узлы инфраструктуры: контроллер домена (`UbuntuDC-VTech`), сервер SIEM (`UbuntuServer-VTech`) и межсетевой экран (`OPNsense`), а также настроил клиентский конфиг `~/.ssh/config` для быстрого подключения по псевдонимам `ssh dc`, `ssh srv`, `ssh fw`.
* Ужесточил конфигурацию SSH-демона на серверах Ubuntu (`sshd_config` и `50-cloud-init.conf`): запретил прямой вход под `root` (`PermitRootLogin no`) и полностью отключил парольную аутентификацию (`PasswordAuthentication no`, `KbdInteractiveAuthentication no`), оставив вход строго по ключам (`PubkeyAuthentication yes`).
* На шлюзе **OPNsense** ограничил работу SSH исключительно интерфейсом внутренней сети (`LAN`), закрыл вход по паролям и проверил отказ при несанкционированных попытках доступа (`Permission denied (publickey)`).

### Локальный межсетевой экран на серверах (Host-based Firewall)
* Настроил локальную фильтрацию трафика через `iptables` на серверах **`UbuntuServer-VTech`** (`srv`) и `UbuntuDC-VTech` (`dc`) по принципу **Default Deny** (`INPUT DROP`, `FORWARD DROP`) для защиты от бокового перемещения внутри сети.
* Ограничил доступ к портам управления (SSH `22`, Wazuh Dashboard `443`) исключительно с IP адреса Администратора ИБ (`10.10.1.58`), оставив для подсети `10.10.1.0/24` только необходимые сервисные порты агентов Wazuh (`1514–1515`) и службы каталогов Active Directory (`DNS`, `Kerberos`, `LDAP`, `SMB`).

### Автоматизированное зашифрованное резервное копирование (Backup & Recovery)
* Разработал скрипты резервного копирования (`backup_ad.sh`, `backup_siem.sh`) для создания консистентных слепков базы Active Directory (`samba-tool domain backup offline`) и критических конфигураций серверов (`Wazuh`, `local_rules.xml`, `sshd_config`, `iptables`).
* Настроил шифрование резервных копий алгоритмом **AES-256** (`openssl enc -aes-256-cbc -pbkdf2`), изолировал директории хранения (`/var/backups/`) правами `700`/`600` и автоматизировал запуск по расписанию cron с ротацией архивов старше 7 дней.

## Использованный стек
* **SIEM:** Wazuh (Indexer, Manager, Server, Dashboard), Wazuh Agent, Wazuh Integrator (custom-ntfy.py, ntfy.sh), кастомные правила корреляции (local_rules.xml, аудит Samba AD), FIM, Threat Hunting, SCA, Active Response (firewall-drop, ossec.conf), MITRE ATT&CK.
* **Сеть:** OPNsense, VirtualBox, Destination NAT, Syslog (UDP 514), Netplan, iptables (iptables-persistent).
* **Active Directory и IAM**: Samba AD DC, Kerberos (krb5), `realmd`, `sssd`, `mkhomedir`, Dnsmasq DNS & DHCP.
* **Защита данных:** LUKS, GPG (AES-256), `shred`.
* **ОС и утилиты:** РЕД ОС, Ubuntu Live-Server/Desktop, `tcpdump`, `apt`/`dpkg`, `ssh` (`Ed25519`, `sshd_config`), `systemctl`, `openssl`, AES-256, `tar`, `cron`, Python, SQLite3.

## Что лежит в папках

Все документы и полный отчет лежат в папке **[/docs](./docs)**:

* **[Портфолио](./docs/portfolio.pdf)** — полное описание стенда, настройка OPNsense, Wazuh SIEM и шифрования.
* **[Политика ИБ](./docs/politika_ib.pdf)** — базовые принципы, цели и требования по защите информации в корпоративной сети.
* **[Регламент](./docs/reglament_ib.pdf)** — правила работы пользователей и администраторов, порядок реагирования на инциденты.

Все скриншоты и схемы лежат в папке **[/assets](./assets)**:

* **[Топология](./assets/network_topology.png)** — наглядная схема корпоративной сети в draw.io.
* **[VirtualBox](./assets/VirtualBox_screens)** — настройка и конфигурация виртуальных машин и локальной сети.
* **[Workspace](./assets/Workspace_screens)** — рабочее пространство в области рабочих станций и межсетевого экрана OPNsense.
* **[WazuhDashboard](./assets/WazuhDashboard_screens)** — интерфейс и фичи Wazuh SIEM Администратора ИБ.
* **[ActiveResponse](./assets/ActiveResponse_screens)** — настройка active response в ossec.config и попытка атаки SSH сервера по 22 порту.
* **[ActiveDirectory](./assets/ActiveDirectory_screens)** — развертывание контроллера домена UbuntuDC-VTech, структура OU и вход под доменными учетными записями.
* **[SSHHardening](./assets/SSHHardening_screens)** — генерация ключей Ed25519 c Passphrase, настройка ssh/config и подключение по ключу к OPNsense и серверам.
* **[Firewalliptables](./assets/Firewalliptables_screens)** — настройка политики Default Deny (iptables) на серверах SIEM и контроллере домена, проверка блокировки портов управления с клиентской станции.
* **[EncryptedBackups](./assets/EncryptedBackups_screens)** — создание зашифрованных архивов AES-256 (openssl), проверка содержимого и настройка расписания cron.
* **[WazuhMobileAlerts](./assets/WazuhMobileAlerts_screens)** — мгновенные push-уведомления на смартфон Администратора ИБ при срабатывании правила Wazuh SIEM, включая обнаружение неудачных попыток входа в домен Active Directory.
  

Все рабочие конфигурации ключевых узлов лежат в папке **[/configs](./configs)**:
* **([opnsense-config.xml](configs/opnsense-config.xml)** — обезличенный резервный конфиг межсетевого экрана OPNsense (сегментация интерфейсов, правила фильтрации, NAT и пересылка логов Syslog).
* **[server_ossec.conf](configs/server_ossec.conf)** — конфигурация главного сервера Wazuh (UbuntuServer-VTech): прием Syslog от OPNsense (UDP 514), правила Active Response (firewall-drop) и интеграция мобильных оповещений (custom-ntfy).
* **[local_rules.xml](configs/local_rules.xml)** — пользовательские правила корреляции Wazuh SIEM для выявления неудачных попыток входа и атак перебора паролей (Brute-force) в домене Active Directory.
* **[custom-ntfy.py](configs/custom-ntfy.py)** — Python-скрипт интеграции Wazuh Integrator с push-сервисом ntfy.sh для мгновенной отправки критических алертов (lvl 7+) на смартфон Администратора ИБ.
* **[srv_sshd_config](configs/srv_sshd_config)** — ужесточенная конфигурация SSH-демона (аутентификация строго по ключам Ed25519, запрет входа root и отключение парольного доступа).
* **[iptables_srv.v4](configs/iptables_srv.v4)** — правила локального межсетевого экрана сервера SIEM (Default Deny) с доступом к портам управления только с АРМ Администратора ИБ.
* **[srv_netplan.yaml](configs/srv_netplan.yaml)** — сетевая конфигурация статической IP адресации сервера UbuntuServer-VTech.
* **[backup_siem.sh](configs/backup_siem.sh)** — скрипт автоматического резервного копирования конфигураций Wazuh, правил, SSH и iptables с шифрованием алгоритмом AES-256 (openssl) и ротацией старше 7 дней.
* **[dc_smb.conf](configs/dc_smb.conf)** — конфигурация контроллера домена Samba Active Directory DC (UbuntuDC-VTech) с включенным аудитом аутентификации и службы каталогов (auth_audit, dsdb_audit).
* **[dc_krb5.conf](configs/dc_krb5.conf)** — конфигурация протокола аутентификации Kerberos для области VTECH.LOCAL.
* **[dc_netplan.yaml](configs/dc_netplan.yaml)** — сетевая конфигурация контроллера домена с привязкой к локальному DNS серверу AD.
* **[dc_ossec.conf](configs/dc_ossec.conf)** — конфигурация агента Wazuh на контроллере домена со сбором журнала аудита Samba AD (log.samba).
* **[iptables_dc.v4](configs/iptables_dc.v4)** — правила локального межсетевого экрана контроллера домена (Default Deny) с разрешением сервисных портов AD для доменных узлов и SSH строго для АРМ Администратора ИБ.
* **[backup_ad.sh](configs/backup_ad.sh)** — скрипт автоматического создания консистентного слепка базы Active Directory (samba-tool domain backup offline) с шифрованием AES-256 (openssl) и ротацией старше 7 дней.
* **[agent_arm_ossec.conf](configs/agent_arm_ossec.conf)** — конфигурация агента на контролируемом АРМ сотрудника (armuser-vtech) с контролем целостности файлов (FIM / syscheck) в реальном времени.

