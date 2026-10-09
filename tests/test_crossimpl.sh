#!/bin/sh
# 쉘 구현(initramfs 키스크립트)과 파이썬 구현이 같은 값을 내는지 확인한다.
# 이 테스트가 깨지면 부팅 시 루트를 열 수 없다는 뜻이므로 가장 중요하다.
#
# 실물 플로피 없이 1.44MB 이미지 파일로 돌린다.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TOOL="$ROOT/tools/vive-floppy-token"
KEYSCRIPT="$ROOT/initramfs/scripts/viveboot-keyscript"
SEQCHECK="$ROOT/tools/viveboot-seqcheck"
LIB="$ROOT/lib/viveboot-common.sh"
ITER=10000

PASS=0
FAIL=0
TMP=$(mktemp -d /tmp/vivecross.XXXXXX)
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

mkconf() {
	# mkconf <conf경로> <토큰장치> [추가 줄...]
	_c=$1
	shift
	cat > "$_c" <<EOF
TOKEN_DEVICE="$1"
TOKEN_WAIT=2
SEQ_UPDATE=yes
CACHE_IKM=no
SEQ_POLICY=warn
EOF
	shift
	for _line in "$@"; do
		printf '%s\n' "$_line" >> "$_c"
	done
}

run_keyscript() {
	# run_keyscript <conf> <run디렉토리> -> stdout 에 암호문
	VIVEBOOT_LIB="$LIB" VIVEBOOT_CONF="$1" VIVEBOOT_RUN="$2" \
		sh "$KEYSCRIPT" none 2>"$TMP/keyscript.err"
}

# ---------------------------------------------------------------------------
echo "# 1. PIN 없는 토큰: 쉘 == 파이썬"
# ---------------------------------------------------------------------------
IMG="$TMP/a.img"
python3 "$TOOL" format "$IMG" --iter "$ITER" --label CROSS-A >/dev/null 2>&1 \
	|| { no "토큰 생성"; exit 1; }
mkconf "$TMP/a.conf" "$IMG"
mkdir -p "$TMP/a.run"
PY_KEY=$(python3 "$TOOL" derive --no-newline "$IMG")
SH_KEY=$(run_keyscript "$TMP/a.conf" "$TMP/a.run")
if [ -n "$SH_KEY" ] && [ "$SH_KEY" = "$PY_KEY" ]; then
	ok "키스크립트 암호문이 파이썬과 일치 ($SH_KEY)"
else
	no "암호문 불일치" "shell='$SH_KEY' python='$PY_KEY' / $(cat "$TMP/keyscript.err")"
fi
[ ${#SH_KEY} -eq 64 ] && ok "암호문 길이 64자" || no "암호문 길이 ${#SH_KEY}"
case $SH_KEY in
*[!0-9a-f]*) no "암호문에 16진 아닌 문자 포함" ;;
*) ok "암호문이 소문자 16진" ;;
esac

# ---------------------------------------------------------------------------
echo "# 2. 키스크립트가 부팅 카운터를 증가시킨다"
# ---------------------------------------------------------------------------
SEQ_AFTER=$(python3 "$TOOL" seq show "$IMG")
[ "$SEQ_AFTER" = 2 ] \
	&& ok "카운터 1 -> 2 (쉘이 쓴 섹터를 파이썬이 검증)" \
	|| no "카운터가 2가 아님: $SEQ_AFTER" "$(cat "$TMP/keyscript.err")"
python3 "$TOOL" verify "$IMG" >/dev/null 2>&1 \
	&& ok "쉘이 쓴 뒤에도 전체 검증 통과" \
	|| no "쉘이 쓴 뒤 검증 실패"
[ -s "$TMP/a.run/boot-seq" ] \
	&& ok "/run/viveboot/boot-seq 기록됨" \
	|| no "boot-seq 파일 없음"
[ -s "$TMP/a.run/mackey" ] \
	&& ok "/run/viveboot/mackey 기록됨" \
	|| no "mackey 파일 없음"
grep -q 'seq_seen=1' "$TMP/a.run/boot-seq" 2>/dev/null \
	&& ok "boot-seq 의 seq_seen=1" \
	|| no "boot-seq 내용이 예상과 다름" "$(cat "$TMP/a.run/boot-seq" 2>/dev/null)"

# 카운터 사본도 같은 값인지 (쉘이 양쪽 다 썼는지)
MIRROR_OK=$(python3 - "$TOOL" "$IMG" <<'PYEOF'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("vt", sys.argv[1])
spec = importlib.util.spec_from_loader("vt", loader)
vt = importlib.util.module_from_spec(spec)
loader.exec_module(vt)
hdr = vt.Header.unpack(vt.read_sector(sys.argv[2], 0))
ikm = vt.collect_ikm(sys.argv[2], hdr)
_, mackey = vt.derive(ikm, hdr.salt, hdr.iter, "")
a = vt.unpack_seq(vt.read_sector(sys.argv[2], hdr.seq_lba), mackey)
b = vt.unpack_seq(vt.read_sector(sys.argv[2], hdr.seq_lba_mirror), mackey)
print("yes" if a == b == 2 else "no:%d,%d" % (a, b))
PYEOF
)
[ "$MIRROR_OK" = yes ] \
	&& ok "카운터 원본/사본 모두 쉘이 갱신" \
	|| no "카운터 사본 불일치: $MIRROR_OK"

# 간이 모드(--compact) 토큰도 부팅 쪽 쉘이 똑같이 읽어야 한다.
IMGK="$TMP/k.img"
python3 "$TOOL" format "$IMGK" --iter "$ITER" --compact --at 15 >/dev/null 2>&1
mkconf "$TMP/k.conf" "$IMGK"
mkdir -p "$TMP/k.run"
PY_KEY_K=$(python3 "$TOOL" derive --no-newline "$IMGK")
SH_KEY_K=$(run_keyscript "$TMP/k.conf" "$TMP/k.run")
[ -n "$SH_KEY_K" ] && [ "$SH_KEY_K" = "$PY_KEY_K" ] \
	&& ok "간이 모드(--compact --at 15) 토큰도 쉘 == 파이썬" \
	|| no "간이 모드 암호문 불일치" "$(cat "$TMP/keyscript.err")"

# ---------------------------------------------------------------------------
echo "# 3. PIN 있는 토큰"
# ---------------------------------------------------------------------------
IMGP="$TMP/b.img"
python3 "$TOOL" format "$IMGP" --iter "$ITER" --pin 4321 >/dev/null 2>&1
mkconf "$TMP/b.conf" "$IMGP"
mkdir -p "$TMP/b.run"
PY_KEY_P=$(python3 "$TOOL" derive --no-newline --pin 4321 "$IMGP")
SH_KEY_P=$(VIVEBOOT_PIN=4321 run_keyscript "$TMP/b.conf" "$TMP/b.run")
[ -n "$SH_KEY_P" ] && [ "$SH_KEY_P" = "$PY_KEY_P" ] \
	&& ok "PIN 토큰에서도 쉘 == 파이썬" \
	|| no "PIN 토큰 암호문 불일치" "$(cat "$TMP/keyscript.err")"
SH_KEY_W=$(VIVEBOOT_PIN=9999 run_keyscript "$TMP/b.conf" "$TMP/b.run")
[ "$SH_KEY_W" != "$SH_KEY_P" ] \
	&& ok "틀린 PIN 은 다른 암호문을 낸다" \
	|| no "PIN 이 암호문에 반영되지 않는다"

# ---------------------------------------------------------------------------
echo "# 4. 손상/위조 토큰은 키를 내주지 않는다"
# ---------------------------------------------------------------------------
IMGC="$TMP/c.img"
python3 "$TOOL" format "$IMGC" --iter "$ITER" >/dev/null 2>&1
SHARD_LBA=$(python3 "$TOOL" info "$IMGC" | awk -F: '/shard LBA/ { print $2 }' \
	| awk '{ print $1 }')
dd if=/dev/zero of="$IMGC" bs=512 seek="$SHARD_LBA" count=1 conv=notrunc \
	2>/dev/null
mkconf "$TMP/c.conf" "$IMGC"
mkdir -p "$TMP/c.run"
SH_OUT=$(run_keyscript "$TMP/c.conf" "$TMP/c.run")
RC=$?
[ "$RC" -ne 0 ] && [ -z "$SH_OUT" ] \
	&& ok "조각 섹터 훼손 시 실패하고 아무것도 출력하지 않는다 (rc=$RC)" \
	|| no "훼손된 토큰에서 키가 나왔다" "rc=$RC out='$SH_OUT'"
grep -q 'magic 불일치' "$TMP/keyscript.err" \
	&& ok "실패 이유가 로그에 남는다" \
	|| no "실패 이유가 불명확" "$(cat "$TMP/keyscript.err")"

IMGN="$TMP/n.img"
dd if=/dev/zero of="$IMGN" bs=512 count=2880 2>/dev/null
mkconf "$TMP/n.conf" "$IMGN"
mkdir -p "$TMP/n.run"
SH_OUT=$(run_keyscript "$TMP/n.conf" "$TMP/n.run")
RC=$?
[ "$RC" -ne 0 ] && [ -z "$SH_OUT" ] \
	&& ok "토큰이 아닌 매체는 거부한다" \
	|| no "빈 매체에서 키가 나왔다"

MISS="$TMP/does-not-exist.img"
mkconf "$TMP/m.conf" "$MISS"
mkdir -p "$TMP/m.run"
SH_OUT=$(run_keyscript "$TMP/m.conf" "$TMP/m.run")
RC=$?
[ "$RC" -ne 0 ] && [ -z "$SH_OUT" ] \
	&& ok "토큰이 없으면 제한 시간 뒤 실패한다" \
	|| no "없는 토큰인데 성공했다"

# ---------------------------------------------------------------------------
echo "# 5. 부팅 후 카운터 검사 (viveboot-seqcheck)"
# ---------------------------------------------------------------------------
STATE="$TMP/state"
SC_CONF="$TMP/sc.conf"
cat > "$SC_CONF" <<EOF
SEQ_POLICY=warn
SEQ_STATE=$STATE
EOF
VIVEBOOT_LIB="$LIB" VIVEBOOT_CONF="$SC_CONF" VIVEBOOT_RUN="$TMP/a.run" \
	sh "$SEQCHECK" >"$TMP/sc1.out" 2>&1
RC=$?
[ "$RC" -eq 0 ] && [ -s "$STATE" ] \
	&& ok "첫 부팅에서 상태 파일을 만든다" \
	|| no "상태 파일 생성 실패 (rc=$RC)" "$(cat "$TMP/sc1.out")"
grep -q 'seq=2' "$STATE" 2>/dev/null \
	&& ok "상태 파일에 seq=2 기록" \
	|| no "상태 파일 내용이 예상과 다름" "$(cat "$STATE" 2>/dev/null)"
[ ! -e "$TMP/a.run/mackey" ] \
	&& ok "검사 후 /run 의 MAC 키를 지운다" \
	|| no "MAC 키가 /run 에 남아 있다"

# 복제본 시나리오: seq 를 되돌린 토큰으로 부팅한 것처럼 꾸민다.
mkdir -p "$TMP/clone.run"
python3 "$TOOL" format "$IMG" --iter "$ITER" --force >/dev/null 2>&1
mkconf "$TMP/clone.conf" "$IMG"
run_keyscript "$TMP/clone.conf" "$TMP/clone.run" >/dev/null
# 새 토큰이므로 UUID 가 달라 '다른 토큰' 이상으로 걸려야 한다.
VIVEBOOT_LIB="$LIB" VIVEBOOT_CONF="$SC_CONF" VIVEBOOT_RUN="$TMP/clone.run" \
	sh "$SEQCHECK" >"$TMP/sc2.out" 2>&1
RC=$?
[ "$RC" -eq 1 ] && grep -q '경고' "$TMP/sc2.out" \
	&& ok "다른 토큰/카운터 불일치를 경고한다 (rc=1)" \
	|| no "불일치를 잡지 못했다 (rc=$RC)" "$(cat "$TMP/sc2.out")"

# ---------------------------------------------------------------------------
echo "# 6. 쉘 저수준 함수"
# ---------------------------------------------------------------------------
LE_OUT=$(
	# shellcheck source=../lib/viveboot-common.sh
	. "$LIB"
	printf '%s %s %s' "$(vb_le 0100)" "$(vb_le ffff)" \
		"$(vb_le "$(vb_hex_at 'deadbeefcafe' 2 2)")"
)
[ "$LE_OUT" = "1 65535 61374" ] \
	&& ok "vb_le / vb_hex_at 동작 ($LE_OUT)" \
	|| no "vb_le/vb_hex_at 결과가 다름: $LE_OUT"

VEC_KEY=$(
	. "$LIB"
	VB_IKM_HEX=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
	VB_SALT_HEX=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	VB_ITER=1000
	vb_derive "" >/dev/null 2>&1 && printf '%s' "$VB_PASSPHRASE"
)
[ "$VEC_KEY" = \
	"17e9654b9c7c7675b2e69e1b6fa7ede559d7622705ee7664ec17f53066c604e9" ] \
	&& ok "쉘 vb_derive 가 고정 벡터와 일치" \
	|| no "쉘 vb_derive 벡터 불일치: $VEC_KEY"

VEC_MAC=$(
	. "$LIB"
	VB_IKM_HEX=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
	VB_SALT_HEX=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	VB_ITER=1000
	vb_derive "" >/dev/null 2>&1 && printf '%s' "$VB_MACKEY_HEX"
)
[ "$VEC_MAC" = \
	"72a0fd6405d1a8bd51f158cc74bed45c3f5a2c86c7fc0b11af58b032586ce264" ] \
	&& ok "쉘 MAC 키가 고정 벡터와 일치" \
	|| no "쉘 MAC 키 벡터 불일치: $VEC_MAC"

# ---------------------------------------------------------------------------
printf '\n통과 %d / 실패 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
