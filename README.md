# vps-hardening-lab

Данная лаба посвящена харденингу моего личного vps сервера. Вся лаба основывается на трех принципах: поверхность атаки, минимальные привилегии, эшелонированная защита. В качестве инструментов использую Lynis, docker-bench-security, nmap. Соответственно, цель - увеличить Hardening index для Lynis, уменьшить количество предупреждений в docker-bench-security, уменьшить количество открытых портов.
Буду сравнивать начальные и итоговые показатели оценки. Ниже начальные показатели:

Lynis (версия 3.1.4):
Lynis security scan details:

  Hardening index : 61 [############        ]

Docker-bench-security:
Score: 1
Pass: 29
Warn: 24

Ports:
18 портов открыто (7 на UDP, 11 на TCP)

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
`Unattended-Upgrade::Remove-Unused-Dependencies "true";
 Unattended-Upgrade::Automatic-Reboot "true";
 Unattended-Upgrade::Automatic-Reboot-Time "04:00";`
 В таком случае, в 04:00 система будет перезагружаться, все пакеты будут успешно установлены.
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
   Правила лежат в /etc/audit/rules.d/hardening.rules (копия в configs/audit/hardening.rules), 35 правил. Следят за изменением пользователей и паролей, sudoers, конфигов SSH, cron и systemd-юнитов, sysctl, apt, nginx, самого auditd, за загрузкой модулей ядра, сменой времени и за Docker (рекомендации CIS, раздел 1.1).
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
   Снаружи к этому моменту слушали только 22, 80 и 443 (было 18 портов), остальное только на 127.0.0.1. Так что firewall здесь скорее страховка: при default deny новый сервис или отладочный порт не окажется случайно доступен из интернета.
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
