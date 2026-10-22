# vps-hardening-lab

Данная лаба посвящена харденингу моего личного vps сервера. Вся лаба основывается на трех принципах: поверхность атаки, минимальные привилегии, эшелонированная защита. В качестве инструментов использую Lynis, docker-bench-security, nmap. Соответственно, цель - увеличить Hardening index для Lynis, уменьшить количество предупреждений в docker-bench-security, уменьшить количество открытых портов.
Буду сравнивать начальные и итоговые показатели оценки. Ниже начальные показатели:

Lynis (версия 3.1.4):
Lynis security scan details:

  Hardening index : 61 [############        ]

Docker-bench-security:
Score: 1
Pass: 29
Warn: 22

Ports:
18 слушающих сокетов (6 UDP, 12 TCP), из них снаружи 8

## Харденинг

Здесь по порядку, что делаю и как.

### Слой «Система»

1. Обновление системы: 
   sudo apt-get update 
   sudo apt-get upgrade
   sudo apt-get install unattended-upgrades apt-listchanges
   sudo dpkg-reconfigure -plow unattended-upgrades

Unattended-upgrades отвечает за автоматическую установку обновлений безопасности. После dpkg-reconfigure в конфиге /etc/apt/apt.conf.d/20auto-upgrades указаны параметры:
`APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";`
При этих параметрах список пакетов автоматически обновляется, пакеты автоматически устанавливаются. Однако обновления ядра срабатывают только после перезагрузки. Для этого нужен свой конфиг /etc/apt/apt.conf.d/52unattended-upgrades-local, с числом в начале больше чем 50 (основной 50unattended-upgrades сам обновляется вместе с пакетом, поэтому его не трогаю, а свои настройки кладу в отдельный файл, который читается после него):
`Unattended-Upgrade::Origins-Pattern {
        "origin=Docker,codename=${distro_codename},label=Docker CE";
 };
 Unattended-Upgrade::Remove-Unused-Dependencies "true";
 Unattended-Upgrade::Automatic-Reboot "true";
 Unattended-Upgrade::Automatic-Reboot-Time "04:00";`
 В таком случае, в 04:00 система будет перезагружаться, все пакеты будут успешно установлены.
 Origins-Pattern добавил в конце, после замера (подробнее в «Замер после»): по умолчанию unattended-upgrades ставит только пакеты Debian, а Docker из своего репозитория download.docker.com. Списки в apt.conf складываются, так что правила Debian из 50unattended-upgrades остаются. Копия в configs/52unattended-upgrades-local.
Осознанно выбираю второй вариант, так как небольшой простой моего сервера ночью (~2 минуты) не является для меня особой проблемой.

2. Пользователи:
  Здесь я проанализировал пользователей, находящихся в системе и имеющих оболочку, отличающуюся от nologin. Оставил только 4-х: root; sync (системный пользователь Debian); основного пользователя amored, под которым выполняется работа в системе; своего второго, учебного пользователя daniil_plandin. Временного пользователя user2, созданного для лабы, удалил:
   sudo userdel -r user2

  Принятые риски:
  - docker в группе моего пользователя, чтобы не использовать постоянно sudo docker. По факту группа docker = root (см. инцидент №2).
  - учебный пользователь daniil_plandin остается в группе sudo. Попасть в него можно только через su от основного пользователя, пароль сложный. Основной пользователь и так имеет sudo, поэтому новых путей к root это не добавляет. После настройки SSH (AllowUsers) зайти в него снаружи будет нельзя.

3. systemd-resolved:
   Выключение ненужных сервисов резолвера, создаю конфиг /etc/systemd/resolved.conf.d/hardening.conf, выключаю LLMNR и MulticastDNS:

   [Resolve]
   LLMNR = no
   MulticastDNS = no

4. Sysctl:
   Изменяю параметры ядра, пишу в /etc/sysctl.d/99-hardening.conf

   kernel.sysrq = 0
   kernel.unprivileged_bpf_disabled = 1
   kernel.yama.ptrace_scope = 1
   net.core.bpf_jit_harden = 2
   net.ipv4.conf.all.rp_filter = 1
   net.ipv4.conf.all.send_redirects = 0
   net.ipv4.conf.default.accept_source_route = 0
   net.ipv4.conf.all.log_martians = 1
   net.ipv4.conf.default.log_martians = 1

   ptrace_scope = 1 - процесс может отлаживать (читать память) только своих потомков. Без этого любой процесс моего пользователя может подключиться к другому моему процессу и вытащить из памяти секреты.

5. Права к файлам:
   sudo apt-get purge ecryptfs-utils (ecryptfs устарел, плюс бесполезен на облачном сервере)
   Изменил права на все файлы .env (600)
   Удалил заброшенные проекты с секретами.
   Права на домашнюю директорию 700.
   Удалены ненужные компиляторы:
   sudo apt-get purge build-essential gcc g++
   sudo apt-get autoremove --purge
   Все образы собираются в Docker, они не нужны на сервере. Злоумышленник может собрать эксплойт с помощью компилятора прямо в системе.

6. auditd:
   sudo apt-get install auditd
   Правила лежат в /etc/audit/rules.d/hardening.rules (копия в configs/audit/hardening.rules), 35 правил (позже в слое Docker добавил еще 6, итого 41). Следят за изменением пользователей и паролей, sudoers, конфигов SSH, cron и systemd-юнитов, sysctl, apt, nginx, самого auditd, за загрузкой модулей ядра, сменой времени и за Docker (рекомендации CIS, раздел 1.1).
   Файл назван с буквы, а не с цифры: augenrules склеивает файлы по алфавиту, и файл "99-..." встал бы раньше audit.rules, где стоит -D (удалить все правила).
   Загрузка и проверка:
   sudo augenrules --load
   sudo auditctl -l
   sudo ausearch -k sudoers -i
   Правило на /var/lib/docker может сильно шуметь при живых контейнерах. Если audit.log будет раздуваться, уберу его и запишу как принятый риск.

7. AppArmor:
   Модуль в ядре был включен, но сам пакет apparmor не стоял, служба была выключена. Из-за этого контейнеры запускались без профиля docker-default.
   sudo apt-get install apparmor apparmor-utils apparmor-profiles apparmor-profiles-extra
   sudo systemctl enable --now apparmor
   sudo systemctl restart docker
   sudo aa-status
   После этого загружено 141 профиль, 20 в enforce, docker-default среди них. Проверка, что новый контейнер получает профиль:
   docker run --rm alpine cat /proc/self/attr/current
   (должно быть docker-default (enforce))

8. Swap:
   Swap - место на диске, куда ядро выгружает часть оперативной памяти, когда её не хватает. Без него при нехватке памяти OOM killer убивает процесс (обычно самый крупный, например postgres). Со swap система тормозит, но живет.
   Сейчас swap 4 ГБ (/swapfile, прописан в /etc/fstab) при 3.8 ГБ RAM. Для сервера без гибернации хватило бы 1-2 ГБ, но пересоздавать ради 2 ГБ места на диске смысла нет, оставляю 4 ГБ.
   Принятый риск: swap лежит на диске незашифрованным. Читать его может только root, но данные в нём переживают перезагрузку и попадают в снапшоты и бэкапы VPS. Шифрованный swap для моей модели угроз избыточен.

Промежуточный результат после слоя «Система»: Hardening index 61 -> 67.

### Косяк по ходу: chown -R /etc

Когда настраивал auditd, не мог зайти в /etc/audit/rules.d без sudo и выполнил:
   sudo chown -R amored:amored /etc
После этого sudo перестал работать: он отказывается читать /etc/sudoers, если его владелец не root. Вернул владельца через root-контейнер, командой вида chown -R root /etc. Но chown меняет владельца и группу отдельно, а я указал только владельца. В итоге группа amored осталась примерно на 800 объектах в /etc, включая /etc/shadow, /etc/gshadow, /etc/sudoers и ключи хоста SSH. Мой пользователь мог читать хеши паролей без sudo.
Заметил, когда Lynis отказался запускаться: "group owner of directory /etc/lynis/plugins ... should be owned by root group (found: amored)".
Исправление: всем объектам с группой amored вернул группу root, а исключениям Debian - их группы (shadow для shadow/gshadow, ssl-cert для /etc/ssl/private, _chrony для chrony.keys).
   sudo find /etc -group amored -exec chgrp -h root {} +
   sudo chgrp shadow /etc/shadow /etc/gshadow /etc/shadow- /etc/gshadow-
Выводы: никогда не делать chown -R на системных каталогах, для чтения конфигов есть sudo. И то, что я смог откатить /etc через контейнер без sudo, - еще одна демонстрация того, что группа docker = root.

### Слой «SSH + fail2ban»

1. SSH:
   Свои настройки кладу в /etc/ssh/sshd_config.d/01-hardening.conf (копия в configs/ssh/01-hardening.conf), основной sshd_config не трогаю.
   В sshd побеждает первое значение параметра, а Include стоит в самом начале sshd_config. Поэтому файл назван с "01-": он читается раньше 50-cloud-init.conf и раньше основного конфига, где, кстати, дважды стоит PermitRootLogin yes (его и так перекрывал cloud-init).

   PermitRootLogin no
   AllowUsers amored
   PubkeyAuthentication yes
   AuthenticationMethods publickey
   PasswordAuthentication no
   KbdInteractiveAuthentication no
   PermitEmptyPasswords no
   MaxAuthTries 3
   LoginGraceTime 30
   AllowTcpForwarding local
   AllowStreamLocalForwarding no
   GatewayPorts no
   PermitTunnel no
   AllowAgentForwarding no
   X11Forwarding no
   ClientAliveInterval 300
   ClientAliveCountMax 2
   LogLevel VERBOSE

   Вход только под amored и только по ключу (ключи с ПК и айфона). Учебный пользователь daniil_plandin по SSH больше не доступен вообще.
   AllowTcpForwarding local - оставил только локальный проброс, он нужен VS Code Remote-SSH. Обратный проброс, туннели, проброс агента и X11 выключены.
   LogLevel VERBOSE - в логе видно отпечаток ключа, которым вошли, и fail2ban видит больше событий.
   Порт 22 не менял: от сканеров это почти не спасает, а защищает вход ключ и fail2ban. Принятый риск.

   Применение (старую сессию не закрываю, пока не проверю вход в новой):
   sudo cp configs/ssh/01-hardening.conf /etc/ssh/sshd_config.d/
   sudo sshd -t && sudo systemctl reload ssh
   sudo sshd -T | grep -E 'permitrootlogin|allowusers|allowtcpforwarding|loglevel|maxauthtries'
   Проверил вход с ПК, с айфона и через VS Code.

2. fail2ban:
   Уже стоял с backend = systemd (jail.d/defaults-debian.conf), но с настройками по умолчанию. Пишу /etc/fail2ban/jail.local (копия в configs/fail2ban/jail.local), jail.conf не трогаю, он обновляется с пакетом.
   Для sshd: 3 попытки за 10 минут - бан на час, каждый следующий бан в 2 раза дольше, до недели (bantime.increment). mode = aggressive ловит и ошибки по ключам, и сканеры, которые обрывают соединение до авторизации.
   sudo fail2ban-client -t
   sudo systemctl restart fail2ban
   sudo fail2ban-client status sshd
   Сразу после включения: 6 забаненных IP, 10 неудачных попыток. Если сам себя забаню - разбан из другой сети или консоли хостинга:
   sudo fail2ban-client set sshd unbanip <ip>

### Слой «Firewall»

1. ufw:
   Снаружи к этому моменту слушали только 22, 80 и 443 (в замере до снаружи был еще LLMNR на 5355, его выключил в слое Система), остальное только на 127.0.0.1. Так что firewall здесь скорее страховка: при default deny новый сервис или отладочный порт не окажется случайно доступен из интернета.
   sudo ufw default deny incoming
   sudo ufw default allow outgoing
   sudo ufw allow 22/tcp
   sudo ufw allow 80/tcp
   sudo ufw allow 443/tcp
   sudo ufw logging low
   sudo ufw enable
   Сначала allow 22, потом enable, иначе текущая сессия оборвется.
   Для SSH allow, а не limit: limit банит после 6 подключений за 30 секунд, а VS Code открывает несколько соединений сразу и может заблокировать сам себя. Перебор и так ловит fail2ban.
   ufw и fail2ban оба работают через nftables и друг другу не мешают.

   Итог:
   Status: active
   Logging: on (low)
   Default: deny (incoming), allow (outgoing), deny (routed)
   Правила: 22/tcp, 80/tcp, 443/tcp (IPv4 и IPv6)

2. Мертвые правила:
   В ufw остались allow на 8929 и 2224 - это порты GitLab (веб и SSH для git), который уже давно удален. Удалил по самому правилу, а не по номеру (номера сдвигаются после каждого удаления):
   sudo ufw delete allow 8929/tcp
   sudo ufw delete allow 2224/tcp
   Правила остаются после удаленных проектов, поэтому список в ufw надо сверять с ss -tulpn.

3. Docker в обход ufw:
   Docker пишет свои правила в nftables, трафик к контейнерам идет через цепочку FORWARD, а не INPUT, где работает ufw. Поэтому ports: "8080:80" в compose открывает порт в интернет, даже если ufw его запрещает (те же правила для GitLab, скорее всего, ничего и не делали). Решение - публиковать порты контейнеров только на 127.0.0.1 ("127.0.0.1:8080:80"), а наружу отдавать через nginx. Делаю в слое Docker, проверяю nmap снаружи.

4. Ping и policy routing:
   Ping оставил: ufw отвечает на него по умолчанию, скрытие почти ничего не дает (сервер и так находят по открытым портам), а для диагностики полезно.
   Policy routing из-за VPN оказался не нужен: xray на сервере работает как обычный прокси на 127.0.0.1:10809, TUN-интерфейса нет, в ip rule только стандартные правила. Закреплять юнитом нечего.

### Слой «Nginx»

Замер до (SSL Labs и securityheaders.com):
SSL Labs: A (HSTS max-age=300 - TOO SHORT, только http/1.1, нет DNS CAA)
securityheaders: D (из заголовков только HSTS и X-Content-Type-Options)

1. Уборка:
   В sites-enabled висели сайты GitLab и заброшенного проекта, оба отдавали 502 - бэкендов давно нет. Удалил конфиги, сертификат gitlab.ssfp.ru и DNS-запись gitlab:
   sudo rm /etc/nginx/sites-enabled/gitlab /etc/nginx/sites-available/gitlab
   sudo certbot delete --cert-name gitlab.ssfp.ru
   Вместо старого сайта на ssfp.ru теперь заглушка, она крутится в контейнере на 127.0.0.1:8080 (подробнее в слое Docker), nginx на хосте делает TLS и проксирует.
   server_tokens off и TLS 1.2/1.3 уже стояли в nginx.conf и в конфиге certbot.

2. Дефолтный server (sites-available/00-default):
   Без него на запрос по голому IP отвечал первый сайт, вместе с сертификатом ssfp.ru - любой сканер по IP узнавал домен.
   На 80 - return 444 (nginx молча закрывает соединение), на 443 - ssl_reject_handshake on (рукопожатие обрывается до отдачи сертификата, самоподписанный сертификат не нужен).

3. Сайт ssfp.ru (sites-available/ssfp.ru):
   Порт 80 только делает 301 на https, if-блоки certbot убрал (server_name и так ограничивает, остальное ловит дефолтный server).
   http2 on.
   limit_except GET - заглушке нужен только GET (HEAD входит), остальное 403.
   limit_req zone=perip burst=20 nodelay - зона в conf.d/hardening.conf: 10 запросов в секунду с IP, короткий всплеск до 20 проходит, сверх - 429 (limit_req_status 429, чтобы в логах было видно лимит, а не упавший бэкенд).

4. Заголовки (snippets/security-headers.conf):
   Strict-Transport-Security "max-age=31536000; includeSubDomains" - год, поддоменов без https не осталось
   X-Content-Type-Options "nosniff"
   X-Frame-Options "DENY" - защита от clickjacking
   Referrer-Policy "strict-origin-when-cross-origin" - на чужие сайты уходит только домен
   Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()"
   Cross-Origin-Opener-Policy "same-origin"
   Content-Security-Policy "default-src 'none'; style-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
   CSP по плану собирался сначала включить в Report-Only, чтобы не сломать приложение. Но у заглушки нет ни JS, ни сторонних ресурсов (стили отдельным файлом, без inline), ломать нечего - включил сразу боевой.
   Заголовки подключаются через include на уровне server. В location своих add_header быть не должно: если там есть хоть один, nginx перестает наследовать все заголовки сверху.

5. Скрытые файлы (snippets/deny-hidden.conf):
   location ~ /\.(?!well-known/) - на /.git, /.env и все остальное, что начинается с точки, 404. /.well-known/ исключен, без него не продлится сертификат. 404, а не 403 - 403 подтверждает, что файл есть.

6. DNS CAA:
   Добавил у регистратора ssfp.ru. CAA 0 issue "letsencrypt.org" - выпускать сертификаты для домена может только Let's Encrypt.

Применение:
   sudo cp configs/nginx/conf.d/hardening.conf /etc/nginx/conf.d/
   sudo cp configs/nginx/snippets/*.conf /etc/nginx/snippets/
   sudo cp configs/nginx/sites-available/* /etc/nginx/sites-available/
   sudo ln -s /etc/nginx/sites-available/ssfp.ru /etc/nginx/sites-enabled/
   sudo ln -s /etc/nginx/sites-available/00-default /etc/nginx/sites-enabled/
   sudo nginx -t && sudo systemctl reload nginx
   sudo certbot renew --dry-run

Проверка: https - HTTP/2 200 со всеми заголовками, http - 301, по IP соединение закрывается без ответа, /.git/config - 404, POST - 403, из 40 запросов подряд 31 x 200 и 9 x 429. Пробное продление сертификата прошло.

Замер после:
SSL Labs: A+
securityheaders: A+

Косяк по ходу: после включения дефолтного server SSL Labs показал Session resumption: No (IDs assigned but not accepted), до этого было Yes. Кэш TLS-сессий включался в конфиге certbot только внутри server ssfp.ru, а возобновление сессии происходит в начале рукопожатия, когда действуют настройки дефолтного server - а в 00-default кэша нет. Перенес ssl_session_cache shared:le_nginx_SSL:10m и ssl_session_timeout 1440m на уровень http (conf.d/hardening.conf), имя и размер зоны те же, что у certbot. Проверка через openssl s_client -sess_out / -sess_in: Reused.

### Слой «Docker»

1. Уборка:
   Удалил все образы, тома и сети старых проектов (GitLab и заброшенный проект), кэш сборки и hello-world. Около 7 ГБ образов и 1.5 ГБ томов. Остались только образы инструментов для замеров (testssl.sh, zaproxy) и alpine для проверок.

2. Заглушка в контейнере (docker/stub):
   Образ на nginxinc/nginx-unprivileged:1.30.6-alpine - nginx внутри работает от uid 101 и слушает 8080, root не нужен. Версия зафиксирована точно, а не stable - образ не поменяется сам при пересборке. Страница и конфиг копируются в образ, а не монтируются с хоста, поэтому образ неизменяемый.
   Внутренний nginx отдает только GET, без списка файлов, без версии. Заголовки безопасности добавляет nginx на хосте, чтобы не было дублей.

   compose.yml:
   user: "101:101" - явно не root
   read_only: true - корневая ФС только на чтение (touch внутри -> Read-only file system)
   tmpfs /tmp 8 МБ - единственное место для записи (pid и временные файлы nginx)
   cap_drop: ALL - ни одной capability (CapEff: 0000000000000000)
   no-new-privileges:true - setuid-бинарники не повысят права
   mem_limit 64m, cpus 0.5, pids_limit 64 - взломанный или заспамленный контейнер не съест сервер, pids_limit еще и от fork-бомбы
   ports 127.0.0.1:8080:8080 - порт только на localhost, Docker обходит ufw (см. слой Firewall), наружу отдает nginx на хосте
   restart: unless-stopped - поднимается после ночной автоперезагрузки, но не после ручного docker stop
   healthcheck - wget раз в 30 секунд, статус (healthy) в docker ps. Сначала был в compose.yml, потом перенес в Dockerfile (HEALTHCHECK), см. «Замер после», образ стал ssfp-stub:1.1
   AppArmor у контейнера docker-default.

3. daemon.json (/etc/docker/daemon.json, копия в configs/docker/daemon.json):
   "icc": false - контейнеры в дефолтной сети bridge не видят друг друга. На сеть заглушки не действует (compose создает свою), но там контейнер один, а разные compose-проекты и так в разных сетях.
   "live-restore": true - контейнеры не останавливаются при рестарте dockerd, обновление Docker через unattended-upgrades не уронит сайт.
   "no-new-privileges": true - то же, что в compose, но по умолчанию для всех контейнеров, включая ручной docker run.
   "userland-proxy": false - нет отдельного процесса docker-proxy от root на каждый порт, проброс правилами nftables.
   log-opts max-size 10m, max-file 3 - лог контейнера не больше 30 МБ, без этого растет до конца диска.
   sudo dockerd --validate --config-file /etc/docker/daemon.json
   sudo systemctl restart docker
   docker compose up -d --force-recreate
   Ротация применяется только к новым контейнерам, поэтому заглушку пересоздал. Проверка: live=true, LogConfig max-file:3 max-size:10m, процессов docker-proxy нет, сайт 200, порт 8080 по внешнему IP не отвечает.

4. auditd для Docker:
   Добавил в hardening.rules файлы, которые проверяет docker-bench (1.1.x): /etc/default/docker, /etc/containerd/config.toml, /run/containerd/containerd.sock, /usr/bin/containerd-shim-runc-v2, /usr/bin/runc (runc реально запускает контейнеры, его подмена - компрометация всех контейнеров). Всего 14 правил с ключом docker, после замера добавил 15-е на /etc/docker/daemon.json.
   augenrules ругается "Old style watch rules are slower" - советует писать правила через syscall (-a always,exit -F path=... -F perm=) вместо -w. На моей нагрузке разницы нет, оставил -w, так читаемее.

Принятые риски:
   2.9 userns-remap - сильная защита (root в контейнере = обычный пользователь на хосте), но меняет хранилище образов и права bind-монтирований, а группа docker все равно = root. У заглушки и так non-root и cap_drop ALL.
   2.12 авторизация клиента Docker - нужен отдельный плагин, для одного пользователя избыточно.
   2.13 удаленное логирование - нет второго сервера под логи.
   1.1.1 отдельный раздел под /var/lib/docker - на VPS один диск, переразметка не стоит того.
   4.5 Content trust - Docker Content Trust устарел и почти не поддерживается registry, вместо него зафиксирована точная версия образа.

### Замер «после»

Lynis 3.1.4, Hardening index: 61 -> 71
Lynis, предупреждения / подсказки: 1 / 62 -> 2 / 51 (оба предупреждения разобраны ниже)
docker-bench, Score: 1 -> 60
docker-bench, PASS / WARN: 29 / 22 -> 76 / 7
Сокеты, слушающие снаружи (ss -tulpn): 8 (22, 80, 443 и LLMNR 5355 по tcp и udp, IPv4 и IPv6) -> 4 (22 по IPv4 и IPv6, 80, 443)
nmap снаружи, все 65535 TCP: 22, 80, 443 open, остальные 65532 filtered
SSL Labs: A -> A+
securityheaders: D -> A+
fail2ban sshd: 26 банов и 145 неудачных попыток за первые 3.5 часа

Число проверок docker-bench выросло с 86 до 117: при замере до контейнеров не было, теперь проверяется живая заглушка (разделы 4 и 5).
Всего сокетов в ss стало даже больше (было 18, стало 21), но все новые только на 127.0.0.1 - это VS Code server и xray. Снаружи их не видно, что и подтвердил nmap.

Оставшиеся предупреждения Lynis:
   PKGS-7392 (уязвимые пакеты) - вышло обновление безопасности bind9, зеркало получило его после утреннего запуска unattended-upgrades. Ставится автоматически ночью, настройка работает.
   PKGS-7388 (нет репозитория безопасности) - ложное срабатывание: trixie-security есть в /etc/apt/sources.list.d/selectel.sources, но он в новом формате deb822, а Lynis 3.1.4 ищет только строки deb в sources.list и *.list. В замере до предупреждения не было, потому что sources.list тогда еще не был пустым.

Предупреждения docker-bench. В первом замере было Score 58 и 8 WARN, два исправил сразу после него и перемерил:
   1.1.11 - не было отдельного правила аудита на /etc/docker/daemon.json (каталог /etc/docker под аудитом, но docker-bench ищет точный путь). Добавил -w /etc/docker/daemon.json -p rwxa -k docker, теперь PASS.
   4.6 - healthcheck заглушки был в compose.yml, а docker-bench смотрит в сам образ. Перенес HEALTHCHECK в Dockerfile, из compose убрал, заглушка из списка пропала.
Остались:
   1.1.1, 2.9, 2.12, 2.13, 4.5 - принятые риски (см. слой Docker).
   4.6 - у образов нет HEALTHCHECK. Заглушка теперь проходит, остались базовый nginx-unprivileged, testssl.sh и alpine - это инструменты для замеров и база для сборки, контейнеры из них постоянно не крутятся.
   5.9 - открыт порт 8080 у заглушки. Это ручная проверка, порт нужен и опубликован только на 127.0.0.1.

Docker не обновлялся через unattended-upgrades: по умолчанию он ставит только пакеты из репозиториев Debian, а docker-ce из download.docker.com. При замере стоял 29.9.1, а в репозитории уже был 29.9.2. Добавил origin=Docker в 52unattended-upgrades-local (см. слой Система). Обновление dockerd контейнеры не роняет благодаря live-restore.

Косяк по ходу: docker-bench через sh
   В README docker-bench пример запуска через sh, но на Debian sh - это dash, который не понимает [[ ]] из bash. Проверки 2.2, 2.4, 2.5, 2.8, 2.9 и 2.12 (как раз те, что читают daemon.json) тихо считаются невыполненными: через sh 2.2 показывала WARN при "icc": false в конфиге. Запускать только через bash.
   Плюс в Docker 29 поменялась таблица docker images (третья колонка теперь размер, а не ID), и скрипт сыпал "error: no such object: 13MB". Обошел через свой DOCKER_CONFIG с imagesFormat, где колонки как раньше:
   sudo env DOCKER_CONFIG=<каталог с config.json> bash docker-bench-security.sh -b -l /tmp/db.log

Косяк по ходу: nmap через TUN
   Первый внешний скан показал около 1500 открытых портов, причем без 22, 80 и 443, а 8080, который опубликован только на 127.0.0.1, был open. Задержка 0.76 мс (до сервера несколько мс), tracert не отвечал уже на первом узле, а tcpdump на сервере во время скана не увидел ни одного SYN. Причина - TUN-режим VPN-клиента Happ на ПК: весь трафик шел через его виртуальный адаптер, и клиент сам принимал любое TCP-соединение. После выключения TUN (прокси для браузера оставил) скан стал честным.
   Вывод: внешний скан делать с выключенным TUN, и проверять задержку в строке Host is up - если доли миллисекунды, отвечает не сервер.

### Ansible

Весь харденинг выше собран в плейбук ansible/ для чистого Debian 13: если сервер придется переустанавливать, руками ничего повторять не надо. Конфиги плейбук берет прямо из configs/ и docker/stub/, своих копий у него нет, поэтому README, конфиги и плейбук не разъезжаются.

Роли идут в том же порядке, что и слои:
   system - обновления, unattended-upgrades, sysctl, systemd-resolved, удаление компиляторов и ecryptfs, auditd, AppArmor, swap (если swap нет)
   users - пользователь amored, пароль для sudo, ключи, домашний каталог 700
   fail2ban - fail2ban, python3-systemd, nftables, jail.local
   firewall - ufw: deny по умолчанию, 22, 80, 443, logging low
   docker - репозиторий download.docker.com, Docker, daemon.json, amored в группе docker
   nginx - nginx.conf (server_tokens off, только TLS 1.2/1.3), hardening.conf, сниппеты, 00-default, сертификат, сайт ssfp.ru
   stub - заглушка в /opt/stub, сборка через compose, ждет healthy
   ssh - 01-hardening.conf
SSH идет последней: после нее root по SSH уже не войдет, а плейбук на чистом сервере запускается как раз от root. Перед этим роль users проверяет, что ключи и пароль заданы, а роль ssh - что amored есть в AllowUsers. Иначе можно запереть себя на сервере.

Сертификат: если его нет, плейбук поднимает временный сайт на 80 без редиректа, получает сертификат через certbot --nginx (заодно certbot кладет options-ssl-nginx.conf и ssl-dhparams.pem, на них ссылается конфиг сайта), удаляет временный сайт и только потом включает боевой ssfp.ru. Без этого nginx -t падает на отсутствующем сертификате. Перед запуском A-запись уже должна смотреть на новый сервер.

Запуск:
   python3 -m venv ~/.venvs/ansible
   ~/.venvs/ansible/bin/pip install ansible-core ansible-lint
   cd ansible
   ansible-galaxy collection install -r requirements.yml
   ansible-vault create secrets.yml
   (внутри admin_pubkeys - список ключей, admin_password_hash - хеш из mkpasswd -m yescrypt, certbot_email; secrets.yml в .gitignore)
   первый раз, на чистом сервере:
   ansible-playbook site.yml -e ansible_user=root -e @secrets.yml --ask-vault-pass
   (именно -e, а не -u: ansible_user из inventory.ini сильнее -u)
   дальше, на живом сервере:
   ansible-playbook site.yml -K -e @secrets.yml --ask-vault-pass --check --diff
   ansible-playbook site.yml -K -e @secrets.yml --ask-vault-pass --tags nginx

Проверка:
   ansible-playbook site.yml --syntax-check
   ansible-lint (0 ошибок, профиль production)
   Прогнал на чистом Debian 13 в контейнере с systemd (ansible/test): первый прогон 0 ошибок, повторный changed=0, то есть плейбук идемпотентный. После прогона внутри: ssh, fail2ban, nginx, docker active; sshd -T - permitrootlogin no, allowusers amored; ufw как на сервере; заглушка healthy; https - 200 с заголовками, http - 301, по IP обрыв соединения, чужой SNI - обрыв рукопожатия.
   docker build -t hardening-clean:trixie ansible/test
   docker run -d --name hardening-test --privileged --cgroupns=host --security-opt no-new-privileges=false -v /sys/fs/cgroup:/sys/fs/cgroup:rw -v hardening-test-docker:/var/lib/docker -v hardening-test-containerd:/var/lib/containerd --tmpfs /run --tmpfs /run/lock hardening-clean:trixie
   ansible-playbook -i test/inventory.ini -e @<тестовые переменные> --skip-tags auditd,apparmor,sysctl,swap site.yml

Что в контейнере не проверить:
   auditd, AppArmor, kernel.* в sysctl и swap - общие с ядром хоста. Привилегированный контейнер поменял бы их на самом сервере, а auditd в контейнере вообще перехватил бы аудит у auditd хоста. Эти задачи пропущены тегами.
   Выпуск сертификата - нужен настоящий домен. В тесте подложил самоподписанный сертификат, задачи certbot пропустились. Полностью проверить можно только на новом VPS.
   /var/lib/docker и /var/lib/containerd вынесены в тома: Docker внутри контейнера не может собрать образ, когда overlay лежит на overlay.
