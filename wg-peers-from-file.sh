#!/usr/bin/env bash
set -euo pipefail

WG_CONF_DIR="/etc/wireguard"
PEERS_FILE="${PEERS_FILE:-./peers.list}"
BACKUP_DIR="${BACKUP_DIR:-${WG_CONF_DIR%/}/backups}"
DATE_TAG="$(date +%Y%m%d%H%M%S)"

if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
	echo "Usage: $0 <WG_IF>"
	exit 2
fi
WG_IF="$1"
WG_CONF_FILE="${WG_CONF_DIR%/}/${WG_IF}.conf"

if [ ! -f "$WG_CONF_FILE" ]; then
	echo "Конфиг $WG_CONF_FILE не найден."
	exit 3
fi

if [ ! -f "$PEERS_FILE" ]; then
	echo "Файл пиров $PEERS_FILE не найден."
	exit 4
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR" 2>/dev/null || true

cp -a "$WG_CONF_FILE" "${BACKUP_DIR%/}/${WG_IF}.conf.${DATE_TAG}.bak"
cp -a "$PEERS_FILE" "${BACKUP_DIR%/}/peers.list.${DATE_TAG}.bak"

mapfile -t BLOCKS < <(awk -v RS='' 'NF{gsub(/\r/,""); print}' "$PEERS_FILE")

added=0
skipped=0

for blk in "${BLOCKS[@]}"; do
	blk="$(printf '%s\n' "$blk" | sed '/^[[:space:]]*$/d')"
	if [ -z "$blk" ]; then
		continue
	fi

	PUBKEY="$(printf '%s\n' "$blk" | awk -F'=' '/PublicKey[[:space:]]*=/ {gsub(/ /,"",$2); print $2; exit} /public_key[[:space:]]*=/ {gsub(/ /,"",$2); print $2; exit}')"
	if [ -z "$PUBKEY" ]; then
		PUBKEY="$(printf '%s\n' "$blk" | awk '/^[A-Za-z0-9+\/=]{43,44}$/{print $1; exit}')"
	fi
	if [ -z "$PUBKEY" ]; then
		skipped=$((skipped + 1))
		continue
	fi

	if grep -q -E "PublicKey[[:space:]]*=[[:space:]]*${PUBKEY}" "$WG_CONF_FILE"; then
		skipped=$((skipped + 1))
		continue
	fi

	OUT="[Peer]\n"
	while IFS= read -r line; do
		line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
		[ -z "$line" ] && continue
		case "$line" in
		PublicKey* | public_key* | PresharedKey* | preshared_key* | AllowedIPs* | Endpoint* | PersistentKeepalive*)
			key="$(printf '%s' "$line" | awk -F'=' '{gsub(/ /,"",$1); print $1}')"
			val="$(printf '%s' "$line" | awk -F'=' '{sub(/^[^=]+= */,""); print}')"
			key_lc="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
			case "$key_lc" in
			publickey | public_key) k="PublicKey" ;;
			presharedkey | preshared_key) k="PresharedKey" ;;
			allowedips) k="AllowedIPs" ;;
			endpoint) k="Endpoint" ;;
			persistentkeepalive) k="PersistentKeepalive" ;;
			*) k="$key" ;;
			esac
			OUT="${OUT}${k} = ${val}\n"
			;;
		*)
			if printf '%s' "$line" | grep -Eq '^[A-Za-z0-9+\/=]{43,44}$'; then
				OUT="${OUT}PublicKey = ${line}\n"
			fi
			;;
		esac
	done <<<"$blk"

	if ! printf '%s' "$OUT" | grep -q '^PublicKey'; then
		skipped=$((skipped + 1))
		continue
	fi

	printf '\n%s\n' "$OUT" >>"$WG_CONF_FILE"
	added=$((added + 1))
done

echo "Готово. Добавлено: $added, пропущено: $skipped."
echo "Бэкапы: ${BACKUP_DIR%/}/${WG_IF}.conf.${DATE_TAG}.bak и ${BACKUP_DIR%/}/peers.list.${DATE_TAG}.bak"
