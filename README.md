# vps-hardening-lab

Данная лаба посвящена харденингу моего личного vps сервера. Вся лаба основывется на трех принципах: поверхность атаки, минимальные привилегии, эшелонированная защита. В качестве инструментов использую Lynis, docker-bench-security, nmap. Соответвтенно, цель - увеличить Hardening index для Lynis, уменьшить количество предупрждений в docker-bench-security, уменьшить количество открытых портов.
Буду сравнивать начальные и итоговые показатели оценки. Ниже начальные показатели:

Lynis:
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

1. Обновление системы: 
   sudo apt-get update 
   sudo apt-get upgrade
   sudo apt-get install unattended-upgrades apt-listchanges
   sudo dpkg-reconfigure -plow unattended-upgrades

Unattended-upgrades отвечает за автоматическую установку обновлений безопасности. Сейчас в конфиге /etc/apt/apt.conf.d/50unattended-upgrades указаны параметры:
`APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";`
При этих параметрах список пакетов автоматически обновляется, пакеты автоматически устанавливаются. Однако обновления ядра срабатывают только после перезагрузки, для этого необходимо создать новый конфиг, с числом в начале больше чем 50 (нужно, чтобы основной конфиг, который входит в чписок обновляемых пакетов, тоже обновлялся):
`Unattended-Upgrade::Remove-Unused-Dependencies "true";
 Unattended-Upgrade::Automatic-Reboot "true";
 Unattended-Upgrade::Automatic-Reboot-Time "time";`
 В таком случае, в указанное время система будет перезагружаться, все пакеты будут успешно установлены.
Осозанно выбираю второй вариант, так как небольшой простой моего сервера ночью (~2 минуты) не является для меня особой проблемой.

2. Пользователи

