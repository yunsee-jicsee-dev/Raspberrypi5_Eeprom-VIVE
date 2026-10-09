#!/usr/bin/env bash
# 재부팅하지 않고 지금 바로 plymouth 테마를 화면에 띄워 본다.
#
#   sudo scripts/preview-plymouth.sh         8초 동안 재생
#   sudo scripts/preview-plymouth.sh 15      15초 동안
#
# 콘솔(Ctrl+Alt+F2) 에서 돌리세요. 데스크톱 안에서는 컴포지터가 화면을 쥐고
# 있어서 안 보입니다.
#
# 끝나면 테마 스크립트의 오류를 찍어 줍니다. 문법이 틀렸다면 여기서 몇 번째
# 줄인지 나옵니다.
set -uo pipefail

LOG=/tmp/plymouth-preview.log
SECS="${1:-8}"

die() { echo "오류: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "sudo 로 실행해 주세요."
command -v plymouthd >/dev/null || die "plymouth 가 없습니다:  sudo apt install -y plymouth"
[[ $SECS =~ ^[0-9]+$ ]] || die "초는 숫자로 적어 주세요."

if [[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
    echo "경고: 데스크톱 세션 안입니다. 컴포지터가 화면을 쥐고 있어 안 보일 수 있습니다."
    echo "      Ctrl+Alt+F2 로 콘솔에 로그인해서 돌리는 게 확실합니다."
    echo
fi

# 무슨 일이 있어도 plymouth 를 화면에서 치우고 끝낸다
cleanup() {
    plymouth quit >/dev/null 2>&1
    sleep 1
    pkill -x plymouthd >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

echo "현재 테마: $(plymouth-set-default-theme 2>/dev/null || echo '알 수 없음')"

pkill -x plymouthd >/dev/null 2>&1   # 돌고 있으면 먼저 치운다
sleep 1
rm -f "$LOG"

echo "plymouth 를 띄웁니다 (${SECS}초)..."
plymouthd --no-daemon --debug --debug-file="$LOG" --mode=boot --tty=/dev/tty1 &
sleep 2
plymouth --show-splash
sleep "$SECS"
plymouth quit
sleep 1

echo
echo "===== 플러그인 / 테마 적재 ====="
# 테마가 안 뜨는 원인은 대개 여기서 드러난다. load_built_in_theme 이 보이면
# 우리 테마를 못 읽고 내장 기본 테마로 떨어진 것이다 (보통 script 플러그인 없음).
if [[ -s $LOG ]]; then
    grep -inE 'plugin|load_theme|built_in|built-in|\.so|ModuleName|ImageDir|ScriptFile|get_theme_path|splash' \
        "$LOG" | head -30
else
    echo "  로그가 비었습니다 ($LOG). plymouthd 가 아예 못 떴을 수 있습니다."
fi

echo
echo "===== 오류로 보이는 줄 ====="
if [[ -s $LOG ]]; then
    found=$(grep -inE 'error|cannot|unable|failed|not found|syntax|expected|undefined|no such' "$LOG" \
        | grep -viE 'plymouthd\.defaults|/run/plymouth' | head -30)
    if [[ -n $found ]]; then echo "$found"; else echo "  (없음)"; fi
fi

echo
echo "===== 그래픽 렌더러가 만들어졌는지 ====="
if grep -q 'details forced' "$LOG" 2>/dev/null; then
    cat <<SERIAL
  시리얼 콘솔이 잡혀서 plymouth 가 텍스트(details) 모드를 강제했습니다.
  그래픽 렌더러를 아예 안 만들기 때문에 어떤 테마를 지정해도 안 보입니다.
  cmdline.txt 에 아래를 넣으세요 (설치 스크립트가 해 줍니다):
      plymouth.ignore-serial-consoles
SERIAL
elif grep -q 'renderer type: 4294967295' "$LOG" 2>/dev/null; then
    echo "  렌더러가 만들어지지 않았습니다 (renderer type 없음). 화면 장치를 못 잡았습니다."
else
    grep -iE 'renderer type|create_devices_for' "$LOG" 2>/dev/null | head -5 \
        || echo "  (해당 줄 없음)"
fi

echo
echo "===== 설치된 plymouth 플러그인 ====="
ls /usr/lib/*/plymouth/*.so 2>/dev/null | sed 's|.*/|  |' || echo "  (찾지 못함)"
if ! ls /usr/lib/*/plymouth/script.so >/dev/null 2>&1; then
    cat <<MISSING

  script.so 가 없습니다. 이 테마는 script 모듈을 쓰므로 반드시 필요합니다:
      sudo apt install -y plymouth-themes
MISSING
fi

echo
echo "전체 로그: $LOG  ($(wc -l < "$LOG" 2>/dev/null || echo 0) 줄)"

cat <<TIP

화면에 인트로가 보였나요?
  보였다  → 재부팅하면 부팅할 때도 그대로 나옵니다
  안 보였다 → 위 오류 줄과 '읽어 들인 테마' 부분을 알려 주세요
TIP
