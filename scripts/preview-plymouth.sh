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
echo "===== 테마 스크립트 오류 ====="
if [[ -s $LOG ]]; then
    if grep -inE 'error|cannot|unable|failed|no such|syntax|expected|undefined' "$LOG" \
        | grep -viE 'no such file or directory: /run/plymouth' | head -30; then
        :
    fi
    grep -icE 'error|cannot|unable|failed|syntax' "$LOG" >/dev/null || echo "  (오류 없음)"
    echo
    echo "===== 읽어 들인 테마 ====="
    grep -iE 'theme|\.script|ImageDir|loading' "$LOG" | head -10
    echo
    echo "전체 로그: $LOG  ($(wc -l < "$LOG") 줄)"
else
    echo "  로그가 비었습니다 ($LOG). plymouthd 가 아예 못 떴을 수 있습니다."
fi

cat <<TIP

화면에 인트로가 보였나요?
  보였다  → 재부팅하면 부팅할 때도 그대로 나옵니다
  안 보였다 → 위 오류 줄과 '읽어 들인 테마' 부분을 알려 주세요
TIP
