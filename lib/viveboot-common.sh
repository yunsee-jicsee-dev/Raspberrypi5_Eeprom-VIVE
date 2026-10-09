# viveboot 공용 쉘 함수 - POSIX sh (dash / busybox ash) 전용.
#
# initramfs 안에서도 쓰이므로 다음만 사용한다: dd, od, cut, openssl, sleep.
# 파이썬·bash·xxd 같은 것은 쓰지 않는다.
#
# 키 파생식은 tools/vive-floppy-token 과 동일해야 한다:
#   ikm  = shard[0] || ... || shard[n-1]
#   pw   = HMAC-SHA256(key=ikm, msg=PIN)
#   key  = PBKDF2-HMAC-SHA256(pw, salt, iter, 32)
#   LUKS passphrase = hex(key)
#   mackey = HMAC-SHA256(key=ikm, msg="viveboot-mac-v1")

VB_SECTOR=512
VB_HDR_MAGIC_HEX="56495645464c5031"   # "VIVEFLP1"
VB_SHARD_MAGIC_HEX="56534844"         # "VSHD"
VB_SEQ_MAGIC_HEX="56534551"           # "VSEQ"
VB_MAC_INFO="viveboot-mac-v1"
VB_STATE_INFO="viveboot-state-v1"

: "${VB_TAG:=viveboot}"

vb_log() { printf '%s: %s\n' "$VB_TAG" "$*" >&2; }
vb_warn() { printf '%s: 경고: %s\n' "$VB_TAG" "$*" >&2; }
vb_die() { printf '%s: 오류: %s\n' "$VB_TAG" "$*" >&2; return 1; }

# ---------------------------------------------------------------------------
# 16진 문자열 유틸
# ---------------------------------------------------------------------------

# vb_hex_at <hexstr> <byte_off> <byte_len>
vb_hex_at() {
	printf '%s' "$1" | cut -c "$(( $2 * 2 + 1 ))-$(( ($2 + $3) * 2 ))"
}

# vb_le <hexstr>  리틀엔디언 16진 -> 10진
vb_le() {
	_vb_v=0
	_vb_i=0
	_vb_h=$1
	while [ -n "$_vb_h" ]; do
		_vb_b=${_vb_h%"${_vb_h#??}"}
		_vb_h=${_vb_h#??}
		_vb_v=$(( _vb_v + (0x$_vb_b << (8 * _vb_i)) ))
		_vb_i=$(( _vb_i + 1 ))
	done
	printf '%s' "$_vb_v"
}

# vb_sector_hex <device> <lba>  섹터 하나를 공백 없는 16진으로
vb_sector_hex() {
	dd if="$1" bs=$VB_SECTOR skip="$2" count=1 2>/dev/null \
		| od -An -tx1 -v | tr -d ' \n'
}

# vb_hmac_hex <hexkey> <message>   HMAC-SHA256(key, message) -> 16진
vb_hmac_hex() {
	printf '%s' "$2" \
		| openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" -hex 2>/dev/null \
		| sed 's/.*= *//'
}

# vb_hmac_file_raw <hexkey> <file> <outfile>  파일 내용의 HMAC을 raw로 저장
vb_hmac_file_raw() {
	openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" -binary \
		-out "$3" "$2" 2>/dev/null
}

# vb_hmac_file_hex <hexkey> <file>
vb_hmac_file_hex() {
	openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" -hex "$2" 2>/dev/null \
		| sed 's/.*= *//'
}

# ---------------------------------------------------------------------------
# 헤더 파싱
# ---------------------------------------------------------------------------

# vb_parse_header <device>
# 성공 시 VB_FLAGS VB_UUID_HEX VB_SALT_HEX VB_ITER VB_SHARD_COUNT
# VB_SHARD_LEN VB_SHARD_LBAS VB_SEQ_LBA VB_SEQ_LBA_MIRROR VB_LABEL_HEX 설정
vb_parse_header() {
	_vb_hdr=$(vb_sector_hex "$1" 0)
	[ ${#_vb_hdr} -eq $(( VB_SECTOR * 2 )) ] \
		|| { vb_die "$1: 헤더 섹터를 읽을 수 없습니다"; return 1; }
	[ "$(vb_hex_at "$_vb_hdr" 0 8)" = "$VB_HDR_MAGIC_HEX" ] \
		|| { vb_die "$1: VIVE 토큰이 아닙니다 (magic 불일치)"; return 1; }
	[ "$(vb_le "$(vb_hex_at "$_vb_hdr" 8 2)")" = "1" ] \
		|| { vb_die "$1: 지원하지 않는 헤더 버전"; return 1; }

	VB_SALT_HEX=$(vb_hex_at "$_vb_hdr" 32 32)
	_vb_mac=$(vb_hex_at "$_vb_hdr" 464 32)
	_vb_tmp="${VB_TMPDIR:-/run/viveboot}/hdrbody"
	vb_sector_prefix_file "$1" 0 464 "$_vb_tmp" || {
		vb_die "$1: 헤더 본문을 읽을 수 없습니다"
		return 1
	}
	_vb_want=$(vb_hmac_file_hex "$VB_SALT_HEX" "$_vb_tmp")
	rm -f "$_vb_tmp"
	[ -n "$_vb_want" ] && [ "$_vb_want" = "$_vb_mac" ] \
		|| { vb_die "$1: 헤더 MAC 불일치 (손상되었거나 위조)"; return 1; }

	VB_FLAGS=$(vb_le "$(vb_hex_at "$_vb_hdr" 12 4)")
	VB_UUID_HEX=$(vb_hex_at "$_vb_hdr" 16 16)
	VB_ITER=$(vb_le "$(vb_hex_at "$_vb_hdr" 64 4)")
	VB_SHARD_COUNT=$(vb_le "$(vb_hex_at "$_vb_hdr" 68 2)")
	VB_SHARD_LEN=$(vb_le "$(vb_hex_at "$_vb_hdr" 70 2)")
	VB_SEQ_LBA=$(vb_le "$(vb_hex_at "$_vb_hdr" 200 2)")
	VB_SEQ_LBA_MIRROR=$(vb_le "$(vb_hex_at "$_vb_hdr" 202 2)")
	VB_LABEL_HEX=$(vb_hex_at "$_vb_hdr" 212 32)

	[ "$VB_SHARD_COUNT" -ge 1 ] && [ "$VB_SHARD_COUNT" -le 64 ] \
		|| { vb_die "$1: shard 개수 비정상 ($VB_SHARD_COUNT)"; return 1; }
	[ "$VB_SHARD_LEN" -ge 1 ] && [ "$VB_SHARD_LEN" -le 64 ] \
		|| { vb_die "$1: shard 길이 비정상 ($VB_SHARD_LEN)"; return 1; }

	VB_SHARD_LBAS=""
	_vb_i=0
	while [ "$_vb_i" -lt "$VB_SHARD_COUNT" ]; do
		_vb_lba=$(vb_le "$(vb_hex_at "$_vb_hdr" $(( 72 + 2 * _vb_i )) 2)")
		VB_SHARD_LBAS="$VB_SHARD_LBAS $_vb_lba"
		_vb_i=$(( _vb_i + 1 ))
	done
	VB_SHARD_LBAS=${VB_SHARD_LBAS# }
	VB_PIN_REQUIRED=$(( VB_FLAGS & 1 ))
	VB_SEQ_ENABLED=$(( (VB_FLAGS & 2) >> 1 ))
	return 0
}

# vb_read_ikm <device>  -> VB_IKM_HEX
vb_read_ikm() {
	VB_IKM_HEX=""
	_vb_idx=0
	for _vb_lba in $VB_SHARD_LBAS; do
		_vb_sec=$(vb_sector_hex "$1" "$_vb_lba")
		[ ${#_vb_sec} -eq $(( VB_SECTOR * 2 )) ] \
			|| { vb_die "shard $_vb_idx (LBA $_vb_lba) 읽기 실패"; return 1; }
		[ "$(vb_hex_at "$_vb_sec" 0 4)" = "$VB_SHARD_MAGIC_HEX" ] \
			|| { vb_die "shard $_vb_idx (LBA $_vb_lba): magic 불일치"; return 1; }
		[ "$(vb_le "$(vb_hex_at "$_vb_sec" 4 2)")" = "$_vb_idx" ] \
			|| { vb_die "shard $_vb_idx (LBA $_vb_lba): 인덱스 불일치"; return 1; }
		[ "$(vb_le "$(vb_hex_at "$_vb_sec" 6 2)")" = "$VB_SHARD_LEN" ] \
			|| { vb_die "shard $_vb_idx (LBA $_vb_lba): 길이 불일치"; return 1; }
		_vb_tmp="${VB_TMPDIR:-/run/viveboot}/shardbody"
		vb_sector_prefix_file "$1" "$_vb_lba" 72 "$_vb_tmp" || return 1
		_vb_want=$(vb_hmac_file_hex "$VB_SALT_HEX" "$_vb_tmp")
		rm -f "$_vb_tmp"
		[ -n "$_vb_want" ] && [ "$_vb_want" = "$(vb_hex_at "$_vb_sec" 72 32)" ] \
			|| { vb_die "shard $_vb_idx (LBA $_vb_lba): MAC 불일치"; return 1; }
		VB_IKM_HEX="$VB_IKM_HEX$(vb_hex_at "$_vb_sec" 8 "$VB_SHARD_LEN")"
		_vb_idx=$(( _vb_idx + 1 ))
	done
	[ ${#VB_IKM_HEX} -eq $(( VB_SHARD_COUNT * VB_SHARD_LEN * 2 )) ] \
		|| { vb_die "ikm 길이 비정상"; return 1; }
	return 0
}

# vb_derive <pin>  -> VB_PASSPHRASE, VB_MACKEY_HEX
vb_derive() {
	_vb_pw=$(vb_hmac_hex "$VB_IKM_HEX" "$1")
	[ ${#_vb_pw} -eq 64 ] || { vb_die "openssl HMAC 실패"; return 1; }
	VB_PASSPHRASE=$(openssl kdf -keylen 32 -kdfopt digest:SHA2-256 \
		-kdfopt "hexpass:$_vb_pw" -kdfopt "hexsalt:$VB_SALT_HEX" \
		-kdfopt "iter:$VB_ITER" PBKDF2 2>/dev/null \
		| tr -d ':\n' | tr 'A-Z' 'a-z')
	[ ${#VB_PASSPHRASE} -eq 64 ] \
		|| { vb_die "openssl kdf PBKDF2 실패 (openssl 3.0 이상 필요)"; return 1; }
	VB_MACKEY_HEX=$(vb_hmac_hex "$VB_IKM_HEX" "$VB_MAC_INFO")
	[ ${#VB_MACKEY_HEX} -eq 64 ] || { vb_die "mac 키 파생 실패"; return 1; }
	return 0
}

# ---------------------------------------------------------------------------
# MAC 대상 바이트 떠내기
# ---------------------------------------------------------------------------

# vb_sector_prefix_file <device> <lba> <len> <outfile>
# 섹터의 앞 <len> 바이트를 파일로 저장한다. MAC 검증 대상이 항상 섹터
# 선두 영역이므로 16진을 다시 바이너리로 조립할 필요가 없다.
vb_sector_prefix_file() {
	dd if="$1" bs=$VB_SECTOR skip="$2" count=1 2>/dev/null \
		| dd of="$4" bs=1 count="$3" 2>/dev/null
	[ -s "$4" ] || return 1
	return 0
}

# ---------------------------------------------------------------------------
# 부팅 카운터 섹터
# ---------------------------------------------------------------------------

# vb_seq_read <device> <lba>  -> stdout 10진 seq
vb_seq_read() {
	_vb_sec=$(vb_sector_hex "$1" "$2")
	[ ${#_vb_sec} -eq $(( VB_SECTOR * 2 )) ] \
		|| { vb_die "카운터 섹터 $2 읽기 실패"; return 1; }
	[ "$(vb_hex_at "$_vb_sec" 0 4)" = "$VB_SEQ_MAGIC_HEX" ] \
		|| { vb_die "카운터 섹터 $2: magic 불일치"; return 1; }
	_vb_tmp="${VB_TMPDIR:-/run/viveboot}/seqbody"
	vb_sector_prefix_file "$1" "$2" 16 "$_vb_tmp" || return 1
	_vb_want=$(vb_hmac_file_hex "$VB_MACKEY_HEX" "$_vb_tmp")
	rm -f "$_vb_tmp"
	[ -n "$_vb_want" ] && [ "$_vb_want" = "$(vb_hex_at "$_vb_sec" 16 32)" ] \
		|| { vb_die "카운터 섹터 $2: MAC 불일치"; return 1; }
	vb_le "$(vb_hex_at "$_vb_sec" 8 8)"
}

# vb_seq_write <device> <lba> <seq>
# 512바이트 섹터를 조립해 기록한다. 난수 채움 -> 헤더/카운터 -> MAC.
vb_seq_write() {
	_vb_dev=$1
	_vb_lba=$2
	_vb_seq=$3
	_vb_t="${VB_TMPDIR:-/run/viveboot}/seqsec"
	dd if=/dev/urandom of="$_vb_t" bs=$VB_SECTOR count=1 2>/dev/null || return 1
	printf 'VSEQ' | dd of="$_vb_t" bs=1 seek=0 count=4 conv=notrunc 2>/dev/null
	dd if=/dev/zero of="$_vb_t" bs=1 seek=4 count=12 conv=notrunc 2>/dev/null
	_vb_i=0
	while [ "$_vb_i" -lt 8 ]; do
		_vb_byte=$(( (_vb_seq >> (8 * _vb_i)) & 255 ))
		if [ "$_vb_byte" -ne 0 ]; then
			printf '%b' "\\0$(printf '%03o' "$_vb_byte")" \
				| dd of="$_vb_t" bs=1 seek=$(( 8 + _vb_i )) count=1 \
					conv=notrunc 2>/dev/null || return 1
		fi
		_vb_i=$(( _vb_i + 1 ))
	done
	dd if="$_vb_t" of="$_vb_t.pre" bs=1 count=16 2>/dev/null || return 1
	vb_hmac_file_raw "$VB_MACKEY_HEX" "$_vb_t.pre" "$_vb_t.mac" || return 1
	dd if="$_vb_t.mac" of="$_vb_t" bs=1 seek=16 count=32 conv=notrunc \
		2>/dev/null || return 1
	dd if="$_vb_t" of="$_vb_dev" bs=$VB_SECTOR seek="$_vb_lba" count=1 \
		conv=notrunc,fsync 2>/dev/null || {
		rm -f "$_vb_t" "$_vb_t.pre" "$_vb_t.mac"
		return 1
	}
	rm -f "$_vb_t" "$_vb_t.pre" "$_vb_t.mac"
	return 0
}

# ---------------------------------------------------------------------------
# 토큰 장치 찾기
# ---------------------------------------------------------------------------

# vb_candidate_devices [max_sectors]  크기가 작은 블록 장치부터 나열
vb_candidate_devices() {
	_vb_max=${1:-8192}
	for _vb_sys in /sys/block/*; do
		[ -r "$_vb_sys/size" ] || continue
		read -r _vb_sz < "$_vb_sys/size" || continue
		[ "$_vb_sz" -gt 0 ] 2>/dev/null || continue
		[ "$_vb_sz" -le "$_vb_max" ] || continue
		_vb_name=${_vb_sys##*/}
		[ -b "/dev/$_vb_name" ] && printf '/dev/%s\n' "$_vb_name"
	done
}

# vb_find_token <timeout_sec> [max_sectors] -> VB_DEVICE
vb_find_token() {
	_vb_deadline=$1
	_vb_max=${2:-8192}
	_vb_waited=0
	_vb_asked=0
	while :; do
		for _vb_cand in $(vb_candidate_devices "$_vb_max"); do
			_vb_m=$(vb_sector_hex "$_vb_cand" 0 | cut -c1-16)
			if [ "$_vb_m" = "$VB_HDR_MAGIC_HEX" ]; then
				VB_DEVICE=$_vb_cand
				return 0
			fi
		done
		[ "$_vb_waited" -ge "$_vb_deadline" ] && break
		if [ "$_vb_asked" -eq 0 ]; then
			vb_log "부팅 토큰 플로피를 USB 드라이브에 넣어 주세요 (최대 ${_vb_deadline}초 대기)"
			_vb_asked=1
		fi
		sleep 2
		_vb_waited=$(( _vb_waited + 2 ))
	done
	vb_die "제한 시간 ${_vb_deadline}초 안에 부팅 토큰을 찾지 못했습니다"
	return 1
}

# ---------------------------------------------------------------------------
# PIN 입력
# ---------------------------------------------------------------------------

# vb_ask_pin <prompt> -> stdout
# VIVEBOOT_PIN 이 설정되어 있으면 그 값을 쓴다 (무인 부팅과 테스트용).
# 이 경우 PIN 은 '알고 있는 요소' 역할을 못 하므로 평소에는 쓰지 말 것.
vb_ask_pin() {
	if [ -n "${VIVEBOOT_PIN+x}" ]; then
		printf '%s' "$VIVEBOOT_PIN"
		return 0
	fi
	if [ -x /lib/cryptsetup/askpass ]; then
		/lib/cryptsetup/askpass "$1"
		return $?
	fi
	_vb_tty=/dev/console
	[ -c "$_vb_tty" ] || _vb_tty=/dev/tty
	printf '%s' "$1" > "$_vb_tty"
	_vb_stty=$(stty -g < "$_vb_tty" 2>/dev/null) || _vb_stty=""
	[ -n "$_vb_stty" ] && stty -echo < "$_vb_tty" 2>/dev/null
	read -r _vb_pin < "$_vb_tty"
	[ -n "$_vb_stty" ] && stty "$_vb_stty" < "$_vb_tty" 2>/dev/null
	printf '\n' > "$_vb_tty"
	printf '%s' "$_vb_pin"
}
