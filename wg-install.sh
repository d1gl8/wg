#!/usr/bin/env bash
set -euo pipefail

# Требуемые утилиты
required_cmds=(wg wg-quick ip ss iptables sysctl)
missing=()
for cmd in "${required_cmds[@]}"; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		missing+=("$cmd")
	fi
done

if [ "${#missing[@]}" -gt 0 ]; then
	echo "Отсутствуют необходимые утилиты: ${missing[*]}"
	if ! command -v apt-get >/dev/null 2>&1; then
		echo "Пакетный менеджер 'apt-get' не найден. Установите отсутствующие утилиты вручную."
		exit 3
	fi
	if [ "${AUTO_INSTALL}" != "yes" ]; then
		echo "AUTO_INSTALL отключён. Установите пакеты вручную (apt-get)."
		exit 4
	fi
	echo "Попытка установить через apt-get..."
	apt-get update

	# Разделяем установку: wireguard (ядро/ tools) и доп. утилиты
	pkgs="iproute2 iptables iputils-ping net-tools"
	# Если wg/wg-quick отсутствуют, устанавливаем пакет wireguard (включает wg-quick в большинстве дистрибутивов)
	if printf '%s\n' "${missing[@]}" | grep -q -E '^wg$|^wg-quick$'; then
		pkgs="wireguard ${pkgs}"
	fi

	DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs
fi

# Настройки (можно переопределить через окружении, кроме WG_CONF_DIR)
WG_PORT="${WG_PORT:-47547}"
WG_ADDRESS="${WG_ADDRESS:-10.1.1.1/24}"
EXT_IF="${EXT_IF:-eth0}"
# WG_CONF_DIR жёстко фиксирован
WG_CONF_DIR="/etc/wireguard"
PRIVATE_KEY_FILE="${PRIVATE_KEY_FILE:-${WG_CONF_DIR%/}/private.key}"
SEARCH_PORT_START="${SEARCH_PORT_START:-1024}"
SEARCH_PORT_END="${SEARCH_PORT_END:-65535}"
AUTO_INSTALL="${AUTO_INSTALL:-yes}" # yes|no — устанавливать ли пакеты автоматически

# Проверка аргумента
if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
	echo "Ошибка: интерфейс WG_IF должен быть передан первым аргументом."
	echo "Использование: $0 <WG_IF>"
	exit 2
fi
WG_IF="$1"
WG_CONF_FILE="${WG_CONF_DIR%/}/${WG_IF}.conf"

# Проверка существования интерфейса
if ip link show dev "$WG_IF" >/dev/null 2>&1; then
	echo "Интерфейс '$WG_IF' уже существует. Ничего не выполняю."
	exit 0
fi

# Проверить наличие внешнего интерфейса EXT_IF; если нет — выбрать из доступных
select_ext_if_if_needed() {
	if ip link show dev "$EXT_IF" >/dev/null 2>&1; then
		return 0
	fi

	echo "Внешний интерфейс '$EXT_IF' не найден."
	# Собираем список кандидатов: все интерфейсы, кроме lo и wireguard-интерфейсов
	mapfile -t cand < <(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | grep -v '^wg' || true)

	if [ "${#cand[@]}" -eq 0 ]; then
		echo "Не найдено подходящих внешних интерфейсов. Укажите EXT_IF вручную и запустите снова."
		exit 5
	fi

	echo "Доступные интерфейсы:"
	i=1
	for iface in "${cand[@]}"; do
		echo "  $i) $iface"
		i=$((i + 1))
	done

	# Предлагаем выбор пользователю
	printf "Выберите номер интерфейса для NAT (по умолчанию 1): "
	read -r sel || sel="1"
	if ! printf '%s' "$sel" | grep -Eq '^[0-9]+$'; then
		sel=1
	fi
	if [ "$sel" -lt 1 ] || [ "$sel" -gt "${#cand[@]}" ]; then
		sel=1
	fi
	EXT_IF="${cand[$((sel - 1))]}"
	echo "Использую внешний интерфейс: $EXT_IF"
}

select_ext_if_if_needed

# Функция проверки доступности TCP/UDP порта
port_in_use() {
	local port=$1
	if ss -l "( sport = :$port )" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

# Проверка желаемого порта
if port_in_use "$WG_PORT"; then
	echo "Порт $WG_PORT уже занят."
	found=""
	for p in $(seq "$SEARCH_PORT_START" "$SEARCH_PORT_END"); do
		echo $p
		if ! port_in_use "$p"; then
			found="$p"
			break
		fi
	done
	if [ -z "$found" ]; then
		echo "Не найден свободный порт в диапазоне $SEARCH_PORT_START-$SEARCH_PORT_END. Выход."
		exit 7
	fi
	printf "Предлагаю использовать свободный порт %s. Принять? [y/N]: " "$found"
	read -r ans || ans="n"
	case "$ans" in
	[yY] | [yY][eE][sS])
		WG_PORT="$found"
		echo "Использую порт $WG_PORT."
		;;
	*)
		echo "Отменено пользователем."
		exit 8
		;;
	esac
else
	echo "Порт $WG_PORT свободен — буду использовать его."
fi

# Создать интерфейс WireGuard
echo "Создаю интерфейс WireGuard '$WG_IF'..."
ip link add dev "$WG_IF" type wireguard

# Назначение IP-адреса и поднятие интерфейса
ip address add "$WG_ADDRESS" dev "$WG_IF"
ip link set up dev "$WG_IF"

# Включение IP forwarding
if [ "$(sysctl -n net.ipv4.ip_forward)" = "0" ]; then
	echo "Включаю IPv4 forwarding..."
	sysctl -w net.ipv4.ip_forward=1 >/dev/null
fi

# Настроить MASQUERADE через внешний интерфейс
if ip link show dev "$EXT_IF" >/dev/null 2>&1; then
	echo "Добавляю правило NAT (MASQUERADE) через $EXT_IF..."
	if ! iptables -t nat -C POSTROUTING -o "$EXT_IF" -s "${WG_ADDRESS%/*}" -j MASQUERADE >/dev/null 2>&1; then
		iptables -t nat -A POSTROUTING -o "$EXT_IF" -s "${WG_ADDRESS%/*}" -j MASQUERADE
	else
		echo "Правило MASQUERADE уже существует."
	fi
else
	echo "Внешний интерфейс '$EXT_IF' не найден — пропускаю настройку NAT."
fi

# Получаем приватный ключ: читаем из файла или генерируем
if [ -f "$PRIVATE_KEY_FILE" ]; then
	WG_PRIVKEY="$(printf '%s' "$(cat "$PRIVATE_KEY_FILE")")"
	if [ -z "$WG_PRIVKEY" ]; then
		echo "Файл $PRIVATE_KEY_FILE пустой — буду генерировать новый ключ."
		rm -f "$PRIVATE_KEY_FILE"
	fi
fi

if [ -z "${WG_PRIVKEY:-}" ]; then
	echo "Генерирую новый приватный ключ и сохраняю в $PRIVATE_KEY_FILE..."
	umask 077
	wg genkey | tee "$PRIVATE_KEY_FILE" >/dev/null
	chmod 600 "$PRIVATE_KEY_FILE"
	chown root:root "$PRIVATE_KEY_FILE" 2>/dev/null || true
	WG_PRIVKEY="$(cat "$PRIVATE_KEY_FILE")"
fi

# Настройка приватного ключа и порта
wg set "$WG_IF" private-key <(printf '%s' "$WG_PRIVKEY") listen-port "$WG_PORT"

# Создание конфигурационного файла в /etc/wireguard
if [ -f "$WG_CONF_FILE" ]; then
	echo "Файл конфигурации '$WG_CONF_FILE' уже существует — не перезаписываю."
else
	echo "Создаю конфигурационный файл '$WG_CONF_FILE'..."
	cat >"$WG_CONF_FILE" <<EOF
[Interface]
Address = ${WG_ADDRESS}
ListenPort = ${WG_PORT}
PrivateKey = ${WG_PRIVKEY}
PostUp = /sbin/ip link set dev ${WG_IF} up; /sbin/iptables -t nat -A POSTROUTING -o ${EXT_IF} -s ${WG_ADDRESS%/*} -j MASQUERADE
PostDown = /sbin/iptables -t nat -D POSTROUTING -o ${EXT_IF} -s ${WG_ADDRESS%/*} -j MASQUERADE; /sbin/ip link set dev ${WG_IF} down
EOF
	chmod 600 "$WG_CONF_FILE"
	chown root:root "$WG_CONF_FILE" 2>/dev/null || true
	echo "Файл конфигурации создан."

	# Немедленный запуск и включение systemd-сервиса wg-quick@${WG_IF}.service
	if command -v systemctl >/dev/null 2>&1; then
		SERVICE="wg-quick@${WG_IF}.service"
		echo "Запускаю $SERVICE ..."
		if systemctl start "$SERVICE"; then
			echo "$SERVICE запущен."
			if systemctl enable "$SERVICE" >/dev/null 2>&1; then
				echo "$SERVICE включён для автозапуска."
			else
				echo "Не удалось включить $SERVICE в автозапуск (возможно, нет прав)."
			fi
		else
			echo "Не удалось запустить $SERVICE через systemctl. Проверьте, установлен ли wg-quick и доступен ли unit."
			echo "Ручной запуск: sudo systemctl start $SERVICE && sudo systemctl enable $SERVICE"
		fi
	else
		echo "systemctl не найден — пытаюсь запустить через wg-quick напрямую..."
		if command -v wg-quick >/dev/null 2>&1; then
			if wg-quick up "$WG_IF"; then
				echo "Интерфейс $WG_IF поднят через wg-quick."
			else
				echo "wg-quick не смог поднять интерфейс $WG_IF. Проверьте конфигурацию."
			fi
		else
			echo "wg-quick не найден — запустите вручную: sudo wg-quick up ${WG_IF}"
		fi
	fi
fi

echo "Интерфейс '$WG_IF' успешно создан и настроен (порт $WG_PORT). Конфигурация: $WG_CONF_FILE"
