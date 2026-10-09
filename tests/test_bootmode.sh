#!/bin/sh
# vive-boot-mode 테스트. root 권한도 실물 플로피도 LUKS 장치도 필요 없다.
#
# 분리 방법:
#   - crypttab 조작은 CRYPTTAB 로 임시 파일을 가리킨다 (순수 텍스트 변환).
#   - cryptsetup / update-initramfs / lsinitramfs 는 가짜 명령으로 바꿔 끼운다
#     (CRYPTSETUP, UPDATE_INITRAMFS, LSINITRAMFS 환경변수).
#   - 토큰은 가짜가 아니라 진짜다: 파이썬 도구로 1.44MB 이미지를 만들고
#     진짜 키스크립트를 돌린다. 그래야 '켜기 전 검증'이 실제 부팅 경로를
#     검증한다는 사실까지 확인된다.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TOOL="$ROOT/tools/vive-boot-mode"
TOKEN_PY="$ROOT/tools/vive-floppy-token"
KEYSCRIPT="$ROOT/initramfs/scripts/viveboot-keyscript"
LIB="$ROOT/lib/viveboot-common.sh"
ITER=10000

PASS=0
FAIL=0
TMP=$(mktemp -d /tmp/vivemode.XXXXXX)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

ok() {
	PASS=$(( PASS + 1 ))
	printf 'ok   - %s\n' "$1"
}
no() {
	FAIL=$(( FAIL + 1 ))
	printf 'FAIL - %s\n' "$1"
	[ $# -ge 2 ] && printf '       %s\n' "$2"
}

# --- 가짜 명령 --------------------------------------------------------------
# FAKE_STATE 디렉토리의 파일로 동작을 제어한다.
FAKE_STATE="$TMP/fake"
mkdir -p "$FAKE_STATE"

cat > "$TMP/cryptsetup" <<'FAKE'
#!/bin/sh
# 가짜 cryptsetup. $FAKE_STATE/token.key 와 $FAKE_STATE/pass 를 정답으로 본다.
set -u
S=${FAKE_STATE:?}
keyfile=""
verbose=no
cmd=""
for a in "$@"; do
	case $a in
	--key-file=*) keyfile=${a#--key-file=} ;;
	--verbose) verbose=yes ;;
	isLuks | luksDump | luksOpen | luksUUID) [ -n "$cmd" ] || cmd=$a ;;
	esac
done
case $cmd in
isLuks)
	[ -f "$S/notluks" ] && exit 1
	exit 0
	;;
luksUUID)
	echo "11111111-2222-3333-4444-555555555555"
	exit 0
	;;
luksDump)
	echo "LUKS header information"
	echo "Version:       	2"
	echo "Keyslots:"
	i=0
	n=$(cat "$S/slots" 2>/dev/null || echo 2)
	while [ "$i" -lt "$n" ]; do
		printf '  %d: luks2\n' "$i"
		echo "	Key:        512 bits"
		i=$(( i + 1 ))
	done
	echo "Tokens:"
	exit 0
	;;
luksOpen)
	if [ -n "$keyfile" ] && [ "$keyfile" != - ]; then
		got=$(cat "$keyfile")
	else
		# 패스프레이즈를 터미널(=여기서는 stdin)에서 입력받는 흉내
		IFS= read -r got || got=""
	fi
	want_tok=$(cat "$S/token.key" 2>/dev/null || true)
	want_pass=$(cat "$S/pass" 2>/dev/null || true)
	if [ -n "$want_tok" ] && [ "$got" = "$want_tok" ]; then
		[ "$verbose" = yes ] && echo "Key slot $(cat "$S/token.slot" 2>/dev/null || echo 1) unlocked."
		echo "Command successful."
		exit 0
	fi
	if [ -n "$want_pass" ] && [ "$got" = "$want_pass" ]; then
		[ "$verbose" = yes ] && echo "Key slot $(cat "$S/pass.slot" 2>/dev/null || echo 0) unlocked."
		echo "Command successful."
		exit 0
	fi
	echo "No key available with this passphrase." >&2
	exit 2
	;;
esac
exit 0
FAKE

cat > "$TMP/update-initramfs" <<'FAKE'
#!/bin/sh
set -u
S=${FAKE_STATE:?}
echo "update-initramfs: $*" >> "$S/initramfs.log"
[ -f "$S/initramfs.fail" ] && exit 1
exit 0
FAKE

cat > "$TMP/lsinitramfs" <<'FAKE'
#!/bin/sh
set -u
S=${FAKE_STATE:?}
cat "$S/initrd.list" 2>/dev/null
exit 0
FAKE

cat > "$TMP/token-tool" <<'FAKE'
#!/bin/sh
# 가짜 vive-floppy-token: scan/info 만 흉내낸다. 파생은 진짜 키스크립트가 한다.
set -u
S=${FAKE_STATE:?}
case ${1:-} in
scan)
	[ -f "$S/token.dev" ] || exit 1
	printf '%s\t2880\t%s\tTEST-TOKEN\n' "$(cat "$S/token.dev")" \
		"11111111-1111-1111-1111-111111111111"
	;;
info)
	echo "라벨          : TEST-TOKEN"
	echo "토큰 UUID     : 11111111-1111-1111-1111-111111111111"
	echo "PIN 필요      : 아니오"
	echo "부팅 카운터   : 사용"
	;;
esac
exit 0
FAKE

chmod 0755 "$TMP/cryptsetup" "$TMP/update-initramfs" "$TMP/lsinitramfs" \
	"$TMP/token-tool"

# --- 진짜 토큰 이미지 두 개 -------------------------------------------------
IMG="$TMP/token.img"
IMG2="$TMP/other.img"
python3 "$TOKEN_PY" format "$IMG" --iter "$ITER" --label MODE-A >/dev/null 2>&1 \
	|| { no "토큰 이미지 생성"; exit 1; }
python3 "$TOKEN_PY" format "$IMG2" --iter "$ITER" --label MODE-B >/dev/null 2>&1 \
	|| { no "두 번째 토큰 이미지 생성"; exit 1; }
TOKEN_KEY=$(python3 "$TOKEN_PY" derive --no-newline "$IMG")
printf '%s' "$TOKEN_KEY" > "$FAKE_STATE/token.key"
printf '%s' "recovery-pass" > "$FAKE_STATE/pass"
printf '%s' 1 > "$FAKE_STATE/token.slot"
printf '%s' 0 > "$FAKE_STATE/pass.slot"
printf '%s' 2 > "$FAKE_STATE/slots"
printf '%s' "$IMG" > "$FAKE_STATE/token.dev"
cat > "$FAKE_STATE/initrd.list" <<'EOF'
usr/lib/viveboot/viveboot-keyscript
usr/lib/viveboot/viveboot-common.sh
etc/viveboot/viveboot.conf
usr/bin/openssl
lib/cryptsetup/askpass
EOF
: > "$TMP/initrd.img"

# --- 공통 실행 함수 ---------------------------------------------------------
mkcrypttab() {
	# mkcrypttab <경로> <on|off>
	if [ "$2" = on ]; then
		printf '# 주석은 그대로 남아야 한다\n' > "$1"
		printf 'cryptroot\tUUID=dead-beef\tnone\tluks,initramfs,tries=3,keyscript=%s\n' \
			"$KEYSCRIPT" >> "$1"
		printf 'cryptswap\tUUID=0000-1111\tnone\tluks,swap\n' >> "$1"
	else
		printf '# 주석은 그대로 남아야 한다\n' > "$1"
		printf 'cryptroot\tUUID=dead-beef\tnone\tluks,initramfs,tries=3\n' >> "$1"
		printf 'cryptswap\tUUID=0000-1111\tnone\tluks,swap\n' >> "$1"
	fi
}

run_mode() {
	# run_mode <crypttab> <인자...>  (stdin 은 호출자가 준다)
	_ct=$1
	shift
	FAKE_STATE="$FAKE_STATE" \
	CRYPTTAB="$_ct" \
	KEYSCRIPT="$KEYSCRIPT" \
	TOKEN_TOOL="$TMP/token-tool" \
	CRYPTSETUP="$TMP/cryptsetup" \
	UPDATE_INITRAMFS="$TMP/update-initramfs" \
	LSINITRAMFS="$TMP/lsinitramfs" \
	VIVEBOOT_LIB="$LIB" \
	VIVEBOOT_CONF="$TMP/viveboot.conf" \
	VIVEBOOT_RUN="$TMP/run" \
	VIVEBOOT_TMPBASE="$TMP" \
	VIVEBOOT_INITRD="$TMP/initrd.img" \
	VIVEBOOT_CMDLINE="$TMP/cmdline.proc" \
	VIVEBOOT_BOOT_CMDLINE="$TMP/cmdline.txt" \
	VIVEBOOT_MODE_STATE="$TMP/boot-mode" \
	VIVEBOOT_SEQ_STATE="$TMP/seqstate" \
	PATH="$TMP:$PATH" \
		sh "$TOOL" "$@" 2>"$TMP/err" >"$TMP/out"
}

cat > "$TMP/viveboot.conf" <<'EOF'
TOKEN_DEVICE=""
TOKEN_WAIT=2
SEQ_UPDATE=yes
CACHE_IKM=no
PIN_PROMPT="테스트 PIN: "
BYPASS_CMDLINE=yes
EOF
printf 'console=tty1 root=/dev/mapper/cryptroot rw\n' > "$TMP/cmdline.proc"
printf 'console=tty1 root=/dev/mapper/cryptroot rw\n' > "$TMP/cmdline.txt"
mkdir -p "$TMP/run"

ks_opt() {
	# ks_opt <crypttab> <name> -> keyscript 옵션이 있으면 yes
	awk -v n="$2" '!/^[ \t]*#/ && $1 == n && $4 ~ /(^|,)keyscript=/ { print "yes"; exit }' "$1"
}

# ---------------------------------------------------------------------------
echo "# 1. crypttab 변환 (root/장치 없이, --force)"
# ---------------------------------------------------------------------------
CT="$TMP/ct1"
mkcrypttab "$CT" off
run_mode "$CT" on --force --no-initramfs
RC=$?
[ "$RC" -eq 0 ] && [ "$(ks_opt "$CT" cryptroot)" = yes ] \
	&& ok "off -> on 으로 keyscript= 가 붙는다" \
	|| no "on 실패 (rc=$RC)" "$(cat "$TMP/err")"
grep -q '^# 주석은 그대로' "$CT" \
	&& ok "주석 줄이 보존된다" || no "주석이 사라졌다" "$(cat "$CT")"
grep -q '^cryptswap	UUID=0000-1111	none	luks,swap$' "$CT" \
	&& ok "다른 항목은 손대지 않는다" || no "다른 항목이 바뀌었다" "$(cat "$CT")"
grep -q 'luks,initramfs,tries=3,keyscript=' "$CT" \
	&& ok "기존 옵션(tries=3 등)이 유지되고 뒤에 붙는다" \
	|| no "옵션 순서/내용이 깨졌다" "$(grep cryptroot "$CT")"

run_mode "$CT" off --force --no-initramfs
RC=$?
[ "$RC" -eq 0 ] && [ -z "$(ks_opt "$CT" cryptroot)" ] \
	&& ok "on -> off 로 keyscript= 만 빠진다" || no "off 실패 (rc=$RC)" "$(cat "$TMP/err")"
grep -q '^cryptroot	UUID=dead-beef	none	luks,initramfs,tries=3$' "$CT" \
	&& ok "off 후 남은 옵션이 정확하다" || no "off 결과가 다르다" "$(grep cryptroot "$CT")"
[ -f "$CT.vive-boot-mode.bak" ] \
	&& ok "crypttab 백업 파일이 생긴다" || no "백업이 없다"

run_mode "$CT" off --force --no-initramfs
RC=$?
[ "$RC" -eq 0 ] && grep -q '이미 꺼져' "$TMP/err" \
	&& ok "이미 꺼진 상태에서 off 는 무해하게 끝난다" \
	|| no "두 번째 off 가 이상하다 (rc=$RC)" "$(cat "$TMP/err")"

# ---------------------------------------------------------------------------
echo "# 2. on 의 사전 검증 - 진짜 토큰 + 진짜 키스크립트"
# ---------------------------------------------------------------------------
CT="$TMP/ct2"
mkcrypttab "$CT" off
SEQ_BEFORE=$(python3 "$TOKEN_PY" seq show "$IMG")

# LUKS 장치가 없으면 crypttab 을 건드리기 전에 멈춰야 한다
run_mode "$CT" on --token "$IMG" --crypt-device "$TMP/no-such-device"
RC=$?
[ "$RC" -ne 0 ] && grep -q '찾을 수 없습니다' "$TMP/err" \
	&& ok "LUKS 장치가 없으면 거부한다 (rc=$RC)" \
	|| no "없는 장치로 진행했다 (rc=$RC)" "$(cat "$TMP/err")"
[ -z "$(ks_opt "$CT" cryptroot)" ] \
	&& ok "검증 실패 시 crypttab 을 고치지 않는다" || no "검증 실패인데 crypttab 이 바뀌었다"

: > "$TMP/fakeluks"
verify_on() {
	# verify_on <crypttab> <토큰>  - 사전 검증을 전부 돌린다 (--force 없음)
	_ct=$1
	_tk=$2
	run_mode "$_ct" on --token "$_tk" --crypt-device "$TMP/fakeluks"
}

mkcrypttab "$CT" off
verify_on "$CT" "$IMG"
RC=$?
[ "$RC" -eq 0 ] && [ "$(ks_opt "$CT" cryptroot)" = yes ] \
	&& ok "토큰이 LUKS 를 열면 on 이 통과한다" \
	|| no "정상 토큰인데 on 이 실패했다 (rc=$RC)" "$(cat "$TMP/err")"
grep -q '키슬롯 1' "$TMP/err" \
	&& ok "토큰이 여는 키슬롯 번호를 보고한다" || no "슬롯 번호 보고가 없다" "$(cat "$TMP/err")"

SEQ_AFTER=$(python3 "$TOKEN_PY" seq show "$IMG")
[ "$SEQ_BEFORE" = "$SEQ_AFTER" ] \
	&& ok "검증이 부팅 카운터를 올리지 않는다 ($SEQ_BEFORE -> $SEQ_AFTER)" \
	|| no "검증이 카운터를 올렸다 ($SEQ_BEFORE -> $SEQ_AFTER). 다음 부팅에 복제 경고가 난다"
python3 "$TOKEN_PY" verify "$IMG" >/dev/null 2>&1 \
	&& ok "검증 뒤에도 토큰 무결성이 유지된다" || no "검증이 토큰을 훼손했다"

mkcrypttab "$CT" off
verify_on "$CT" "$IMG2"
RC=$?
[ "$RC" -ne 0 ] && [ -z "$(ks_opt "$CT" cryptroot)" ] \
	&& ok "다른 토큰(LUKS 를 못 여는)으로는 켜지 않는다 (rc=$RC)" \
	|| no "엉뚱한 토큰으로 켜 버렸다 (rc=$RC)" "$(cat "$TMP/err")"
grep -q 'vive-luks-enroll' "$TMP/err" \
	&& ok "실패 시 키슬롯 등록 방법을 알려 준다" || no "안내가 없다" "$(cat "$TMP/err")"

mkcrypttab "$CT" off
printf '%s' 1 > "$FAKE_STATE/slots"
verify_on "$CT" "$IMG"
RC=$?
[ "$RC" -ne 0 ] && [ -z "$(ks_opt "$CT" cryptroot)" ] \
	&& ok "키슬롯이 하나뿐이면 (복구 경로 없음) 켜지 않는다" \
	|| no "복구 경로가 없는데 켰다 (rc=$RC)" "$(cat "$TMP/err")"
printf '%s' 2 > "$FAKE_STATE/slots"

# ---------------------------------------------------------------------------
echo "# 3. off 의 사전 검증 - 패스프레이즈 키슬롯 확인"
# ---------------------------------------------------------------------------
verify_off() {
	# verify_off <crypttab> <입력할 패스프레이즈> [추가인자...]
	# 패스프레이즈는 가짜 cryptsetup 이 stdin 에서 읽는다. 실물에서는
	# cryptsetup 이 사용자의 터미널에서 직접 읽는다 (도구가 stdin 을
	# 가로채지 않는 것이 요점이다).
	_ct=$1
	_pw=$2
	shift 2
	printf '%s\n' "$_pw" \
		| run_mode "$_ct" off --crypt-device "$TMP/fakeluks" "$@"
}

CT="$TMP/ct3"
mkcrypttab "$CT" on
verify_off "$CT" "recovery-pass" --token "$IMG"
RC=$?
[ "$RC" -eq 0 ] && [ -z "$(ks_opt "$CT" cryptroot)" ] \
	&& ok "맞는 패스프레이즈로 off 가 통과한다" \
	|| no "정상 패스프레이즈인데 off 가 실패했다 (rc=$RC)" "$(cat "$TMP/err")"
grep -q '키슬롯 0' "$TMP/err" \
	&& ok "패스프레이즈가 여는 슬롯을 보고한다" || no "슬롯 보고가 없다" "$(cat "$TMP/err")"

mkcrypttab "$CT" on
verify_off "$CT" "wrong-pass" --token "$IMG"
RC=$?
[ "$RC" -ne 0 ] && [ "$(ks_opt "$CT" cryptroot)" = yes ] \
	&& ok "틀린 패스프레이즈로는 끄지 않는다 (crypttab 그대로)" \
	|| no "틀린 패스프레이즈인데 껐다 (rc=$RC)" "$(cat "$TMP/err")"

# 토큰 암호문을 '패스프레이즈'로 입력하면 같은 슬롯이 열린다 -> 거부해야 한다
mkcrypttab "$CT" on
verify_off "$CT" "$TOKEN_KEY" --token "$IMG"
RC=$?
[ "$RC" -ne 0 ] && [ "$(ks_opt "$CT" cryptroot)" = yes ] \
	&& ok "토큰 슬롯과 같은 슬롯이 열리면 거부한다" \
	|| no "토큰 암호문을 패스프레이즈로 받아들였다 (rc=$RC)" "$(cat "$TMP/err")"

mkcrypttab "$CT" on
run_mode "$CT" off --force --no-initramfs
RC=$?
[ "$RC" -eq 0 ] && [ -z "$(ks_opt "$CT" cryptroot)" ] \
	&& ok "--force 는 검증을 건너뛴다" || no "--force 가 동작하지 않는다 (rc=$RC)"
grep -q 'force' "$TMP/err" \
	&& ok "--force 사용 시 경고를 남긴다" || no "경고가 없다" "$(cat "$TMP/err")"

# ---------------------------------------------------------------------------
echo "# 4. 되돌리기 - update-initramfs 가 실패하면 crypttab 을 복원한다"
# ---------------------------------------------------------------------------
CT="$TMP/ct4"
mkcrypttab "$CT" off
BEFORE=$(cat "$CT")
: > "$FAKE_STATE/initramfs.fail"
run_mode "$CT" on --force
RC=$?
rm -f "$FAKE_STATE/initramfs.fail"
[ "$RC" -ne 0 ] \
	&& ok "update-initramfs 실패 시 0 이 아닌 값으로 끝난다 (rc=$RC)" \
	|| no "실패를 알리지 않았다"
[ "$(cat "$CT")" = "$BEFORE" ] \
	&& ok "crypttab 이 원래대로 복원된다" \
	|| no "crypttab 이 복원되지 않았다" "$(diff -u "$TMP/before" "$CT" 2>/dev/null; cat "$CT")"
grep -q '되돌' "$TMP/err" \
	&& ok "되돌렸다는 사실을 알려 준다" || no "안내가 없다" "$(cat "$TMP/err")"

CT="$TMP/ct5"
mkcrypttab "$CT" off
rm -f "$FAKE_STATE/initramfs.log"
run_mode "$CT" on --force
RC=$?
[ "$RC" -eq 0 ] && grep -q -- '-u -k all' "$FAKE_STATE/initramfs.log" \
	&& ok "성공 경로에서 update-initramfs -u -k all 을 실행한다" \
	|| no "update-initramfs 를 실행하지 않았다 (rc=$RC)" "$(cat "$TMP/err")"

# ---------------------------------------------------------------------------
echo "# 5. status"
# ---------------------------------------------------------------------------
CT="$TMP/ct6"
mkcrypttab "$CT" on
run_mode "$CT" status
RC=$?
[ "$RC" -eq 0 ] && grep -q '모드          : on' "$TMP/out" \
	&& ok "켜진 상태를 on 으로 보고한다" || no "status 가 on 을 못 읽었다" "$(cat "$TMP/out")"
grep -q 'viveboot keyscript (토큰 필수)' "$TMP/out" \
	&& ok "crypttab 항목별로 keyscript 유무를 보여 준다" || no "항목 표시가 없다"
grep -q 'viveboot-keyscript' "$TMP/out" \
	&& ok "initramfs 안의 키스크립트 존재를 보여 준다" || no "initramfs 표시가 없다"
grep -q 'cryptsetup/askpass' "$TMP/out" \
	&& ok "askpass 포함 여부를 보여 준다 (off 모드에 필요)" || no "askpass 표시가 없다"
grep -q 'TEST-TOKEN' "$TMP/out" \
	&& ok "연결된 토큰과 라벨/UUID 를 보여 준다" || no "토큰 표시가 없다" "$(cat "$TMP/out")"
grep -q '우회' "$TMP/out" \
	&& ok "한 번만 우회 상태를 보여 준다" || no "우회 표시가 없다"

mkcrypttab "$CT" off
run_mode "$CT" status
grep -q '모드          : off' "$TMP/out" \
	&& ok "꺼진 상태를 off 로 보고한다" || no "status 가 off 를 못 읽었다"

# crypttab 이 initrd 보다 새로우면 재생성 필요를 알려야 한다
touch "$TMP/initrd.img"
sleep 1
touch "$CT"
run_mode "$CT" status
grep -q 'update-initramfs -u -k all 필요' "$TMP/out" \
	&& ok "crypttab 이 initramfs 보다 새로우면 경고한다" \
	|| no "최신 여부 판정이 안 된다" "$(grep 최신 "$TMP/out")"

# 다른 keyscript 는 건드리지 않는다
CT="$TMP/ct7"
printf 'cryptroot\tUUID=dead-beef\tcryptroot\tluks,keyscript=/lib/cryptsetup/scripts/decrypt_derived\n' \
	> "$CT"
run_mode "$CT" on --force --no-initramfs
RC=$?
[ "$RC" -ne 0 ] && grep -q '다른 keyscript' "$TMP/err" \
	&& ok "남의 keyscript 가 걸린 항목은 거부한다" \
	|| no "남의 keyscript 를 덮어썼다 (rc=$RC)" "$(cat "$TMP/err")"

# ---------------------------------------------------------------------------
echo "# 6. bypass (커널 커맨드라인)"
# ---------------------------------------------------------------------------
CT="$TMP/ct8"
mkcrypttab "$CT" on
run_mode "$CT" bypass on
RC=$?
[ "$RC" -eq 0 ] && grep -q 'viveboot=off' "$TMP/cmdline.txt" \
	&& ok "bypass on 이 cmdline.txt 에 viveboot=off 를 넣는다 (rc=$RC)" \
	|| no "bypass on 실패 (rc=$RC)" "$(cat "$TMP/err"; cat "$TMP/cmdline.txt")"
[ "$(wc -l < "$TMP/cmdline.txt")" = 1 ] \
	&& ok "cmdline.txt 는 한 줄로 유지된다" || no "줄이 늘어났다"
run_mode "$CT" bypass on
[ "$(tr ' ' '\n' < "$TMP/cmdline.txt" | grep -c '^viveboot=off$')" = 1 ] \
	&& ok "두 번 넣어도 중복되지 않는다" || no "viveboot=off 가 중복됐다"
run_mode "$CT" status
grep -q '다음 부팅   : .*viveboot=off 가 있다' "$TMP/out" \
	&& ok "status 가 다음 부팅의 우회를 경고한다" || no "우회 경고가 없다" "$(grep 부팅 "$TMP/out")"
run_mode "$CT" bypass off
grep -q 'viveboot=off' "$TMP/cmdline.txt" \
	&& no "bypass off 가 지우지 못했다" || ok "bypass off 가 viveboot=off 를 지운다"
grep -q 'root=/dev/mapper/cryptroot' "$TMP/cmdline.txt" \
	&& ok "다른 커맨드라인 인자는 보존된다" || no "다른 인자가 사라졌다" "$(cat "$TMP/cmdline.txt")"

# ---------------------------------------------------------------------------
echo "# 7. 키스크립트의 우회 경로 (viveboot=off)"
# ---------------------------------------------------------------------------
# 핵심: 우회 모드에서 키스크립트가 '빈 출력으로' 끝나면 안 된다.
# cryptsetup 은 keyscript | cryptsetup --key-file=- 로 호출되므로, 빈 출력은
# "Nothing to read on input." 로 실패할 뿐 패스프레이즈를 묻지 않는다.
# 그래서 키스크립트가 askpass 를 직접 exec 해 패스프레이즈를 흘려보내야 한다.
# VIVEBOOT_ASKPASS 로 가짜 askpass 를 꽂아 그 사실을 결정적으로 확인한다.
cat > "$TMP/fake-askpass" <<'FAKE'
#!/bin/sh
# 진짜 askpass 처럼 프롬프트는 stderr, 입력값은 stdout 으로 (개행 없이).
printf '%s' "$1" >&2
printf 'typed-recovery-pass'
FAKE
chmod 0755 "$TMP/fake-askpass"

cat > "$TMP/bypass.conf" <<EOF
TOKEN_DEVICE="$IMG"
TOKEN_WAIT=2
SEQ_UPDATE=no
CACHE_IKM=no
BYPASS_CMDLINE=yes
BYPASS_PROMPT="패스프레이즈 (viveboot 우회): "
EOF
printf 'console=tty1 viveboot=off rw\n' > "$TMP/cmdline.bypass"
mkdir -p "$TMP/bprun"
SEQ_B=$(python3 "$TOKEN_PY" seq show "$IMG")
OUT=$(VIVEBOOT_LIB="$LIB" VIVEBOOT_CONF="$TMP/bypass.conf" \
	VIVEBOOT_RUN="$TMP/bprun" VIVEBOOT_CMDLINE="$TMP/cmdline.bypass" \
	VIVEBOOT_ASKPASS="$TMP/fake-askpass" CRYPTTAB_NAME=cryptroot \
	sh "$KEYSCRIPT" none 2>"$TMP/bp.err")
RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "typed-recovery-pass" ] \
	&& ok "viveboot=off 면 askpass 가 받은 값을 그대로 cryptsetup 에 넘긴다" \
	|| no "우회 경로가 패스프레이즈를 넘기지 않는다 (rc=$RC out='$OUT')" \
		"$(cat "$TMP/bp.err")"
[ -n "$OUT" ] \
	&& ok "우회 시 빈 출력으로 끝나지 않는다 (= cryptsetup 이 패스프레이즈를 받는다)" \
	|| no "빈 출력으로 끝났다. 실물에서는 부팅이 막힌다"
grep -q 'cryptroot 패스프레이즈 (viveboot 우회): ' "$TMP/bp.err" \
	&& ok "프롬프트에 매핑 이름이 붙는다" || no "프롬프트가 다르다" "$(cat "$TMP/bp.err")"
grep -q '토큰 장치' "$TMP/bp.err" \
	&& no "우회인데 토큰을 읽었다" || ok "우회 시 토큰을 아예 읽지 않는다"
[ "$(python3 "$TOKEN_PY" seq show "$IMG")" = "$SEQ_B" ] \
	&& ok "우회 부팅은 토큰 카운터를 올리지 않는다" || no "우회인데 카운터가 올라갔다"

# askpass 가 없으면 조용히 실패하지 말고 이유를 남겨야 한다
OUT=$(VIVEBOOT_LIB="$LIB" VIVEBOOT_CONF="$TMP/bypass.conf" \
	VIVEBOOT_RUN="$TMP/bprun" VIVEBOOT_CMDLINE="$TMP/cmdline.bypass" \
	VIVEBOOT_ASKPASS="$TMP/no-such-askpass" \
	sh "$KEYSCRIPT" none 2>"$TMP/bp1.err")
RC=$?
[ "$RC" -ne 0 ] && [ -z "$OUT" ] && grep -q 'askpass' "$TMP/bp1.err" \
	&& ok "askpass 가 없으면 이유를 남기고 실패한다" \
	|| no "askpass 없을 때의 동작이 불명확 (rc=$RC out='$OUT')" "$(cat "$TMP/bp1.err")"
grep -q 'recovery.md' "$TMP/bp1.err" \
	&& ok "그 경우 initramfs 쉘 복구 방법을 알려 준다" || no "복구 안내가 없다"

printf 'console=tty1 viveboot=offx rw\n' > "$TMP/cmdline.bypass"
OUT=$(VIVEBOOT_LIB="$LIB" VIVEBOOT_CONF="$TMP/bypass.conf" \
	VIVEBOOT_RUN="$TMP/bprun" VIVEBOOT_CMDLINE="$TMP/cmdline.bypass" \
	VIVEBOOT_ASKPASS="$TMP/fake-askpass" \
	sh "$KEYSCRIPT" none 2>"$TMP/bp2.err")
[ ${#OUT} -eq 64 ] \
	&& ok "viveboot=offx 같은 비슷한 값에는 걸리지 않는다" \
	|| no "커맨드라인 토큰 비교가 느슨하다 (out 길이 ${#OUT})" "$(cat "$TMP/bp2.err")"

cat > "$TMP/bypass2.conf" <<EOF
TOKEN_DEVICE="$IMG"
TOKEN_WAIT=2
SEQ_UPDATE=no
CACHE_IKM=no
BYPASS_CMDLINE=no
EOF
printf 'console=tty1 viveboot=off rw\n' > "$TMP/cmdline.bypass"
OUT=$(VIVEBOOT_LIB="$LIB" VIVEBOOT_CONF="$TMP/bypass2.conf" \
	VIVEBOOT_RUN="$TMP/bprun" VIVEBOOT_CMDLINE="$TMP/cmdline.bypass" \
	VIVEBOOT_ASKPASS="$TMP/fake-askpass" \
	sh "$KEYSCRIPT" none 2>"$TMP/bp3.err")
[ ${#OUT} -eq 64 ] \
	&& ok "BYPASS_CMDLINE=no 면 커맨드라인 우회를 무시하고 토큰을 읽는다" \
	|| no "BYPASS_CMDLINE=no 가 먹지 않는다" "$(cat "$TMP/bp3.err")"

# ---------------------------------------------------------------------------
echo "# 8. 인자 처리"
# ---------------------------------------------------------------------------
CT="$TMP/ct9"
mkcrypttab "$CT" off
run_mode "$CT" frobnicate
[ $? -ne 0 ] && grep -q '알 수 없는 명령' "$TMP/err" \
	&& ok "모르는 명령은 거부한다" || no "모르는 명령을 받아들였다"
run_mode "$CT" on --bogus
[ $? -ne 0 ] && grep -q '알 수 없는 인자' "$TMP/err" \
	&& ok "모르는 옵션은 거부한다" || no "모르는 옵션을 받아들였다"
run_mode "$CT" --help
[ $? -eq 2 ] && ok "--help 는 사용법을 내고 2 로 끝난다" || no "--help 동작이 다르다"

rm -f "$TMP/boot-mode"
printf 'a\tUUID=1\tnone\tluks\nb\tUUID=2\tnone\tluks\n' > "$TMP/ct10"
run_mode "$TMP/ct10" on --force --no-initramfs
RC=$?
[ "$RC" -ne 0 ] && grep -qF -- '--name' "$TMP/err" \
	&& ok "후보가 여러 개면 --name 을 요구한다" \
	|| no "아무 항목이나 골랐다 (rc=$RC)" "$(cat "$TMP/err")"
run_mode "$TMP/ct10" on --name b --force --no-initramfs
[ "$(ks_opt "$TMP/ct10" b)" = yes ] && [ -z "$(ks_opt "$TMP/ct10" a)" ] \
	&& ok "--name 으로 지정한 항목만 바꾼다" || no "--name 이 안 먹는다" "$(cat "$TMP/ct10")"

# cryptroot + cryptswap 처럼 initramfs 옵션이 하나뿐이면 --name 없이 고른다
printf 'cryptroot\tUUID=1\tnone\tluks,initramfs,tries=3\ncryptswap\tUUID=2\tnone\tluks,swap\n' \
	> "$TMP/ct11"
rm -f "$TMP/boot-mode"
run_mode "$TMP/ct11" on --force --no-initramfs
RC=$?
[ "$RC" -eq 0 ] && [ "$(ks_opt "$TMP/ct11" cryptroot)" = yes ] \
	&& [ -z "$(ks_opt "$TMP/ct11" cryptswap)" ] \
	&& ok "swap 항목은 건너뛰고 initramfs 항목을 고른다" \
	|| no "항목 자동 선택이 틀렸다 (rc=$RC)" "$(cat "$TMP/err"; cat "$TMP/ct11")"

# 끈 뒤에도 --name 없이 다시 켤 수 있어야 한다 (대상을 기억한다)
run_mode "$TMP/ct11" off --force --no-initramfs
[ -z "$(ks_opt "$TMP/ct11" cryptroot)" ] || no "off 가 안 됐다"
printf 'a\tUUID=1\tnone\tluks\nb\tUUID=2\tnone\tluks\n' > "$TMP/ct12"
run_mode "$TMP/ct12" off --name b --force --no-initramfs
run_mode "$TMP/ct12" on --force --no-initramfs
RC=$?
[ "$RC" -eq 0 ] && [ "$(ks_opt "$TMP/ct12" b)" = yes ] \
	&& ok "지난번 대상을 기억해 --name 없이 다시 켠다" \
	|| no "대상 기억이 동작하지 않는다 (rc=$RC)" "$(cat "$TMP/err")"

# ---------------------------------------------------------------------------
printf '\n통과 %d / 실패 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
