#!/bin/sh
# qwdtt-probe.sh — минутный диагностический пробник канала meridian.
#
# Раз в минуту (из cron):
#   * ping -c2 -W3 -I meridian 8.8.8.8
#   * считает процессы клиента по шаблону '[q]wdtt (-peer|-mode)'
#   * пинг ОК   -> одна короткая строка "OK <дата> procs=N up=..."
#   * пинг ФЕЙЛ -> подробный блок: дата, число процессов, аптайм процесса
#                  qwdtt, причина от ping и последние 15 строк qwdtt.log
#
# Установка задания в cron:  /opt/bin/qwdtt-probe.sh install
# Снятие задания:            /opt/bin/qwdtt-probe.sh uninstall
#
# Пути можно переопределить переменными окружения (нужно для тестов).

IFACE="${PROBE_IFACE:-meridian}"
TARGET="${PROBE_TARGET:-8.8.8.8}"
LOG="${PROBE_LOG:-/opt/var/log/qwdtt-probe.log}"
SRCLOG="${PROBE_SRCLOG:-/opt/var/log/qwdtt.log}"
CRONFILE="${PROBE_CRONFILE:-/opt/etc/crontabs/root}"
PIDF="${PROBE_PIDF:-/opt/var/run/qwdtt-probe.pid}"

MAXBYTES=262144   # 256 КБ — порог обрезки лога
KEEPLINES=500     # сколько последних строк оставляем при обрезке
TAILLINES=15      # сколько строк qwdtt.log подшиваем к отчёту об обрыве

SELF=$(readlink -f "$0" 2>/dev/null) || SELF=""   # bb-ok: неудача обработана, дальше запасной путь
[ -n "$SELF" ] || SELF="$0"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# --- число процессов клиента -------------------------------------------------
# ВАЖНО: шаблон именно в одинарных кавычках и БЕЗ экранирования скобок —
# '[q]' здесь класс символов, он же отсекает строку самого grep из вывода ps.
# Экранированный '\[q\]' в grep -E ищет литеральный текст "[q]wdtt" и не
# находит ничего (см. CLAUDE.md, п.7).
count_procs() {
	ps w 2>/dev/null | grep -E '[q]wdtt (-peer|-mode)' | wc -l | tr -d ' \t'
}

first_pid() {
	ps w 2>/dev/null | grep -E '[q]wdtt (-peer|-mode)' | awk '{print $1; exit}'
}

# --- аптайм процесса по /proc/<pid>/stat ------------------------------------
# Поле 22 (starttime) в тиках с момента загрузки; comm может содержать пробелы,
# поэтому сначала срезаем "pid (comm) " и берём поле 20 остатка.
proc_uptime() {
	pid="$1"
	[ -n "$pid" ] && [ -r "/proc/$pid/stat" ] || { echo "нет процесса"; return; }
	start=$(sed 's/^[0-9]* ([^)]*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')
	up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
	hz=$(getconf CLK_TCK 2>/dev/null) || hz=""
	[ -n "$hz" ] || hz=100
	case "$start$up" in ''|*[!0-9]*) echo "н/д"; return;; esac
	secs=$((up - start / hz))
	[ "$secs" -ge 0 ] 2>/dev/null || secs=0
	d=$((secs / 86400)); h=$(((secs % 86400) / 3600))
	m=$(((secs % 3600) / 60)); s=$((secs % 60))
	if [ "$d" -gt 0 ]; then
		printf '%dд %02d:%02d:%02d' "$d" "$h" "$m" "$s"
	else
		printf '%02d:%02d:%02d' "$h" "$m" "$s"
	fi
}

# --- обрезка собственного лога ----------------------------------------------
rotate_log() {
	[ -f "$LOG" ] || return 0
	# Группировка, а не просто 2>/dev/null: при отсутствии файла ошибку
	# перенаправления печатает сама оболочка, и на команде её не перехватить
	# (тот же дефект, что вылез в апдейтере с /proc/<pid>/cmdline).
	sz=$( { wc -c < "$LOG"; } 2>/dev/null | tr -d ' \t')
	case "$sz" in ''|*[!0-9]*) return 0;; esac
	[ "$sz" -gt "$MAXBYTES" ] || return 0
	if tail -n "$KEEPLINES" "$LOG" > "$LOG.tmp" 2>/dev/null; then
		mv "$LOG.tmp" "$LOG" 2>/dev/null
		echo "$(ts) ROTATE лог обрезан до $KEEPLINES строк (было $sz Б)" >> "$LOG"
	else
		rm -f "$LOG.tmp" 2>/dev/null
	fi
}

# --- защита от наложения запусков -------------------------------------------
# На роутере ~248 МБ ОЗУ и активный OOM-киллер: зависший ping не должен
# накапливать по копии пробника каждую минуту (см. CLAUDE.md, п.8).
take_lock() {
	mkdir -p "$(dirname "$PIDF")" 2>/dev/null
	if [ -f "$PIDF" ]; then
		old=$(cat "$PIDF" 2>/dev/null)
		case "$old" in
			''|*[!0-9]*) ;;
			*) [ -d "/proc/$old" ] && [ "$old" != "$$" ] && exit 0 ;;
		esac
	fi
	echo $$ > "$PIDF" 2>/dev/null
	trap 'rm -f "$PIDF" 2>/dev/null' EXIT INT TERM
}

probe() {
	mkdir -p "$(dirname "$LOG")" 2>/dev/null
	take_lock
	rotate_log

	PROCS=$(count_procs)
	[ -n "$PROCS" ] || PROCS=0
	PID=$(first_pid)
	UP=$(proc_uptime "$PID")

	OUT=$(ping -c2 -W3 -I "$IFACE" "$TARGET" 2>&1)
	if [ $? -eq 0 ]; then
		echo "$(ts) OK ping $TARGET via $IFACE, procs=$PROCS" >> "$LOG"
		return 0
	fi

	{
		echo "$(ts) FAIL ping $TARGET via $IFACE | procs=$PROCS | pid=${PID:-нет} | аптайм qwdtt: $UP"
		echo "  ping: $(echo "$OUT" | grep -v '^$' | tail -n 3 | tr '\n' ' ')"
		if [ -r "$SRCLOG" ]; then
			echo "  --- последние $TAILLINES строк $SRCLOG ---"
			tail -n "$TAILLINES" "$SRCLOG" 2>/dev/null | sed 's/^/  | /'
			echo "  --- конец фрагмента ---"
		else
			echo "  --- $SRCLOG недоступен ---"
		fi
	} >> "$LOG"
	return 1
}

# Убрать свои строки из crontab.
# ВНИМАНИЕ: код возврата grep -v проверять нельзя — если после фильтра не
# остаётся ни одной строки (в crontab была только наша задача), grep выходит
# с кодом 1, и "&& mv" молча не срабатывает: строка остаётся на месте.
strip_cron_line() {
	[ -r "$CRONFILE" ] || return 1
	grep -v "qwdtt-probe.sh" "$CRONFILE" > "$CRONFILE.tmp" 2>/dev/null
	[ -f "$CRONFILE.tmp" ] || return 1
	mv "$CRONFILE.tmp" "$CRONFILE" 2>/dev/null || { rm -f "$CRONFILE.tmp"; return 1; }
	return 0
}

reload_cron() {
	for c in /opt/etc/init.d/S*cron*; do
		[ -x "$c" ] && "$c" restart >/dev/null 2>&1 && return 0
	done
	# OpenWRT: расписание в /etc/crontabs, сервис называется просто cron
	[ -x /etc/init.d/cron ] && /etc/init.d/cron restart >/dev/null 2>&1 && return 0
	# перечитать расписание нечем — хотя бы убедиться, что crond жив
	ps w 2>/dev/null | grep -q '[c]rond' || crond -c "$(dirname "$CRONFILE")" >/dev/null 2>&1
	return 0
}

install_cron() {
	CRONLINE="* * * * * $SELF >/dev/null 2>&1"
	mkdir -p "$(dirname "$CRONFILE")" 2>/dev/null
	[ -f "$CRONFILE" ] || : > "$CRONFILE"
	if grep -q "qwdtt-probe.sh" "$CRONFILE" 2>/dev/null; then
		if grep -qxF "$CRONLINE" "$CRONFILE" 2>/dev/null; then
			echo "задание уже в $CRONFILE — ничего не меняю"
			ps w 2>/dev/null | grep -q '[c]rond' || crond -c "$(dirname "$CRONFILE")" >/dev/null 2>&1
			return 0
		fi
		# путь к скрипту изменился — заменяем только свою строку
		strip_cron_line || { echo "не смог переписать $CRONFILE"; return 1; }
	fi
	echo "$CRONLINE" >> "$CRONFILE"
	reload_cron
	echo "$(ts) INSTALL пробник добавлен в cron: $CRONLINE" >> "$LOG"
	echo "готово: $CRONLINE"
}

uninstall_cron() {
	[ -f "$CRONFILE" ] || { echo "$CRONFILE не найден"; return 0; }
	grep -q "qwdtt-probe.sh" "$CRONFILE" 2>/dev/null || { echo "задания нет"; return 0; }
	strip_cron_line || { echo "не смог переписать $CRONFILE"; return 1; }
	reload_cron
	echo "$(ts) UNINSTALL задание снято с cron" >> "$LOG"
	echo "задание снято"
}

case "$1" in
	install)   install_cron ;;
	uninstall) uninstall_cron ;;
	tail)      tail -n "${2:-40}" "$LOG" 2>/dev/null ;;
	""|run)    probe ;;
	*)
		echo "использование: $SELF [install|uninstall|run|tail [N]]"
		exit 1
		;;
esac
