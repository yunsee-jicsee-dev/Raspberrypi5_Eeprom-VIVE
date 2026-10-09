#!/bin/sh
# 부팅 게이트 (암호화하지 않은 루트용) 테스트. root/실물 없이 이미지 파일로 돈다.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TOOL="$ROOT/tools/vive-floppy-token"
GATE="$ROOT/initramfs/scripts/local-top/viveboot-gate"
GATECTL="$ROOT/tools/vive-boot-gate"
KEYSCRIPT="$ROOT/initramfs/scripts/viveboot-keyscript"
LIB="$ROOT/lib/viveboot-common.sh"
ITER=10000

PASS=0
FAIL=0
TMP=$(mktemp -d /tmp/vivegate.XXXXXX)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
no() {
	FAIL=$((FAIL + 1))
	printf 'FAIL - %s\n' "$1"
	if [ $# -ge 2 ]; then printf '       %s\n' "$2"; fi
	return 0
}

# 가짜 update-initramfs / lsinitramfs. lsinitramfs 는 LS_LIST 파일 내용을 낸다.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/update-initramfs" <<'EOF'
#!/bin/sh
echo "$*" >> "$UPD_LOG"
exit "${UPD_RC:-0}"
EOF
cat > "$TMP/bin/lsinitramfs" <<'EOF'
#!/bin/sh
cat "$LS_LIST"
if [ -e "$GATE_FILE" ]; then echo etc/viveboot/gate; fi
EOF
chmod +x "$TMP/bin/update-initramfs" "$TMP/bin/lsinitramfs"
: > "$TMP/initrd"
cat > "$TMP/ls.full" <<'EOF'
scripts/local-top/viveboot-gate
usr/lib/viveboot/viveboot-keyscript
usr/lib/viveboot/viveboot-common.sh
usr/bin/openssl
EOF
grep -v openssl "$TMP/ls.full" > "$TMP/ls.noopenssl"

export UPD_LOG="$TMP/upd.log" LS_LIST="$TMP/ls.full" GATE_FILE="$TMP/gate"
export PATH="$TMP/bin:$PATH"

gatectl() {
	VIVEBOOT_TEST=1 VIVEBOOT_LIB="$LIB" VIVEBOOT_GATE="$TMP/gate" \
		KEYSCRIPT="$KEYSCRIPT" TOKEN_TOOL="$TOOL" VIVEBOOT_INITRD="$TMP/initrd" \
		VIVEBOOT_BOOT_CONFIG=/dev/null VIVEBOOT_TMPBASE="$TMP" \
		sh "$GATECTL" "$@" 2>"$TMP/err"
}

# boot <conf추가줄...>  게이트 스크립트를 부팅 때처럼 돌린다. rc 반환
boot() {
	{
		printf 'TOKEN_DEVICE="%s"\nTOKEN_WAIT=2\nGATE_TRIES=2\nGATE_FAIL=exit\n' "$DEV"
		for l in "$@"; do printf '%s\n' "$l"; done
	} > "$TMP/conf"
	rm -rf "$TMP/run"
	mkdir -p "$TMP/run"
	VIVEBOOT_LIB="$LIB" VIVEBOOT_CONF="$TMP/conf" VIVEBOOT_GATE="$TMP/gate" \
		VIVEBOOT_RUN="$TMP/run" VIVEBOOT_CMDLINE="${CMDLINE:-/dev/null}" \
		KEYSCRIPT="$KEYSCRIPT" sh "$GATE" 2>"$TMP/boot.err"
}

python3 "$TOOL" format "$TMP/a.img" --iter $ITER --compact >/dev/null 2>&1
python3 "$TOOL" format "$TMP/b.img" --iter $ITER --compact >/dev/null 2>&1
python3 "$TOOL" format "$TMP/p.img" --iter $ITER --pin 4321 >/dev/null 2>&1

echo "# 1. 게이트가 꺼져 있으면 아무것도 하지 않는다"
DEV="$TMP/missing.img" boot && ok "gate 파일이 없으면 토큰 없이 통과" \
	|| no "게이트가 꺼져 있는데 막았다" "$(cat "$TMP/boot.err")"

echo "# 2. enable"
gatectl enable --token "$TMP/a.img"
RC=$?
[ "$RC" -eq 0 ] && [ -s "$TMP/gate" ] && ok "enable 이 gate 파일을 쓴다" \
	|| no "enable 실패 (rc=$RC)" "$(cat "$TMP/err")"
[ "$(sed -n 's/^verifier=//p' "$TMP/gate" | tr -d '\n' | wc -c)" -eq 64 ] \
	&& ok "검증값 64자" || no "검증값 형식이 틀렸다"
grep -q -- '-u -k all' "$UPD_LOG" && ok "update-initramfs 를 돌린다" \
	|| no "update-initramfs 를 안 돌렸다"
case $(stat -c %a "$TMP/gate") in
600) ok "gate 파일 권한 0600" ;;
*) no "gate 파일 권한이 $(stat -c %a "$TMP/gate")" ;;
esac
SEQ=$(python3 "$TOOL" seq show "$TMP/a.img")
[ "$SEQ" = 1 ] && ok "enable 의 확인은 부팅 카운터를 올리지 않는다" \
	|| no "enable 이 카운터를 올렸다 ($SEQ)"

echo "# 3. 부팅"
DEV="$TMP/a.img" boot && ok "맞는 토큰이면 통과" \
	|| no "맞는 토큰인데 막았다" "$(cat "$TMP/boot.err")"
[ "$(python3 "$TOOL" seq show "$TMP/a.img")" = 2 ] \
	&& ok "게이트 부팅이 카운터를 1 올린다 (복제 탐지 유지)" \
	|| no "카운터가 안 올랐다"
DEV="$TMP/b.img" boot && no "다른 토큰인데 통과했다" \
	|| ok "다른 토큰(다른 디스켓)이면 막는다"
grep -q '이 기기의 토큰이 아니거나' "$TMP/boot.err" \
	&& ok "다른 토큰이라는 이유를 알린다" || no "이유가 불명확" "$(cat "$TMP/boot.err")"
DEV="$TMP/missing.img" boot && no "토큰이 없는데 통과했다" \
	|| ok "토큰이 없으면 막는다"
grep -q '부팅하지 않습니다' "$TMP/boot.err" && ok "막을 때 이유를 알린다" \
	|| no "막는 이유가 없다"
grep -q '토큰 확인 실패 (2/2)' "$TMP/boot.err" && ok "GATE_TRIES 만큼 다시 시도한다" \
	|| no "재시도 횟수가 틀렸다" "$(cat "$TMP/boot.err")"

echo "# 4. 우회와 손상"
CL="$TMP/cl"
printf 'console=tty1 viveboot=off quiet\n' > "$CL"
CMDLINE="$CL" DEV="$TMP/missing.img" boot && ok "viveboot=off 면 토큰 없이 통과" \
	|| no "우회가 안 된다"
CMDLINE="$CL" DEV="$TMP/missing.img" boot "BYPASS_CMDLINE=no" \
	&& no "BYPASS_CMDLINE=no 인데 우회됐다" || ok "BYPASS_CMDLINE=no 면 우회를 무시한다"
cp "$TMP/gate" "$TMP/gate.good"
printf 'version=1\nverifier=abc\n' > "$TMP/gate"
DEV="$TMP/a.img" boot && no "손상된 gate 인데 통과했다" \
	|| ok "gate 파일이 손상되면 막는다 (통과시키지 않는다)"
cp "$TMP/gate.good" "$TMP/gate"

echo "# 5. PIN 토큰"
gatectl enable --token "$TMP/p.img" --pin 4321 || no "PIN 토큰 enable 실패" "$(cat "$TMP/err")"
VIVEBOOT_PIN=4321 DEV="$TMP/p.img" boot && ok "PIN 이 맞으면 통과" \
	|| no "맞는 PIN 인데 막았다" "$(cat "$TMP/boot.err")"
VIVEBOOT_PIN=0000 DEV="$TMP/p.img" boot && no "틀린 PIN 인데 통과했다" \
	|| ok "PIN 이 틀리면 막는다"
gatectl enable --token "$TMP/p.img" --pin 9999
RC=$?
[ "$RC" -eq 0 ] && grep -q "verifier" "$TMP/gate" \
	&& VIVEBOOT_PIN=4321 DEV="$TMP/p.img" boot \
	&& no "틀린 PIN 으로 enable 했는데 맞는 PIN 이 통과" \
	|| ok "enable 때의 PIN 이 검증값에 들어간다"

echo "# 6. 통과할 수 없는 게이트는 켜지 않는다 (매번 전원이 꺼지는 사고 방지)"
rm -f "$TMP/gate"
LS_LIST="$TMP/ls.noopenssl" gatectl enable --token "$TMP/a.img"
RC=$?
[ "$RC" -ne 0 ] && [ ! -e "$TMP/gate" ] \
	&& ok "initramfs 에 openssl 이 없으면 되돌린다 (gate 삭제)" \
	|| no "빠진 initramfs 로 게이트를 켰다 (rc=$RC)" "$(cat "$TMP/err")"
grep -q 'bin/openssl' "$TMP/err" && ok "무엇이 빠졌는지 알린다" || no "빠진 항목을 안 알린다"
UPD_RC=1 gatectl enable --token "$TMP/a.img"
RC=$?
[ "$RC" -ne 0 ] && [ ! -e "$TMP/gate" ] && ok "update-initramfs 실패 시 되돌린다" \
	|| no "update-initramfs 실패에도 게이트를 남겼다"
gatectl enable --token "$TMP/missing.img"
RC=$?
[ "$RC" -ne 0 ] && [ ! -e "$TMP/gate" ] && ok "토큰을 못 읽으면 켜지 않는다" \
	|| no "토큰 없이 게이트를 켰다"

echo "# 7. disable / status"
gatectl enable --token "$TMP/a.img" >/dev/null 2>&1
gatectl status > "$TMP/st" 2>&1
grep -q '켜짐' "$TMP/st" && grep -q '게이트 동작' "$TMP/st" \
	&& ok "status 가 켜짐과 다음 부팅 동작을 보여 준다" || no "status 이상" "$(cat "$TMP/st")"
gatectl disable
RC=$?
[ "$RC" -eq 0 ] && [ ! -e "$TMP/gate" ] && ok "disable 이 gate 를 지운다" \
	|| no "disable 실패 (rc=$RC)" "$(cat "$TMP/err")"
DEV="$TMP/missing.img" boot && ok "끈 뒤에는 토큰 없이 부팅된다" || no "끈 뒤에도 막는다"
gatectl status > "$TMP/st" 2>&1
grep -q '꺼짐' "$TMP/st" && ok "status 가 꺼짐을 보여 준다" || no "status 이상"

printf '\n통과 %d / 실패 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
