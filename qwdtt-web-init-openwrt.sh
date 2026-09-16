#!/bin/sh /etc/rc.common
# Автозапуск панели управления на OpenWRT (procd).
#
# Раздаётся файлом с 17.08.2026 — по той же причине, что и Entware-вариант.
# Отдельно важное: без `enable` (симлинк в /etc/rc.d) служба не поднимется после
# перезагрузки роутера. На GL-MT3000 с OpenWrt 25.12.5 автозапуска не оказалось
# вовсе, и панель с клиентом работали только потому, что их запустил установщик
# в той же сессии.
START=98
STOP=11
USE_PROCD=1

start_service() {
	procd_open_instance
	procd_set_param command /opt/bin/qwdtt-web
	procd_set_param respawn 3600 5 0
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}
