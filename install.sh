#!/usr/bin/env bash
# 로그인할 때 인트로가 전체화면으로 한 번 재생되게 한다.
#
#   sudo ./install.sh              설치
#   sudo ./install.sh --uninstall  제거
#
# 부팅 경로에는 아무것도 끼워 넣지 않는다. 잘못돼도 인트로가 안 나올 뿐
# 부팅은 평소대로 진행된다.
#
# 바탕화면이 먼저 비치는 게 싫으면 부팅 스플래시 쪽을 쓴다:  sudo boot/install.sh
set -euo pipefail
export PYGAME_HIDE_SUPPORT_PROMPT=1

PREFIX=/opt/rpi5-intro
ENTRY=rpi5-intro.desktop
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "오류: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "sudo 로 실행해 주세요."

TARGET_USER="${SUDO_USER:-}"
[[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]] || TARGET_USER="$(logname 2>/dev/null || true)"
id -u "$TARGET_USER" >/dev/null 2>&1 \
    || die "일반 사용자로 로그인해 sudo 로 실행해 주세요 (자동 실행을 그 계정에 넣습니다)."
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d $USER_HOME ]] || die "$TARGET_USER 의 홈 디렉터리를 찾지 못했습니다."
AUTOSTART="$USER_HOME/.config/autostart"

# 예전 이름으로 깔린 것들도 같이 걷어낸다
clean() {
    rm -f "$AUTOSTART/$ENTRY" "$AUTOSTART/rpi5-bootintro.desktop"
    rm -rf "$PREFIX" /opt/rpi5-bootintro
    # 부팅 경로에 끼워 넣던 옛 서비스가 남아 있으면 치운다 (이 방식은 폐기했다)
    if [[ -e /etc/systemd/system/rpi5-bootintro.service ]]; then
        systemctl disable --now rpi5-bootintro.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/rpi5-bootintro.service \
              /etc/systemd/system/multi-user.target.wants/rpi5-bootintro.service
        systemctl daemon-reload >/dev/null 2>&1 || true
        echo "폐기된 rpi5-bootintro.service 를 지웠습니다."
    fi
}

if [[ "${1:-}" == "--uninstall" ]]; then
    clean
    echo "제거했습니다."
    exit 0
fi
[[ -z "${1:-}" ]] || die "모르는 옵션: $1"

command -v python3 >/dev/null || die "python3 가 없습니다."
python3 -c "import pygame" 2>/dev/null \
    || die "pygame 이 없습니다:  sudo apt install -y python3-pygame"

clean
install -d "$PREFIX"
for f in play.py intro.py pixelfont.py; do
    [[ -f "$SRC_DIR/$f" ]] || die "$f 를 찾지 못했습니다."
    install -m 644 "$SRC_DIR/$f" "$PREFIX/$f"
done
# main.py 가 있으면 폰트를 그쪽에서 쓴다 (없어도 pixelfont 로 동작)
[[ -f "$SRC_DIR/main.py" ]] && install -m 644 "$SRC_DIR/main.py" "$PREFIX/main.py"

install -d -o "$TARGET_USER" -g "$TARGET_USER" "$AUTOSTART"
install -m 644 -o "$TARGET_USER" -g "$TARGET_USER" \
    "$SRC_DIR/desktop/$ENTRY" "$AUTOSTART/$ENTRY"

cat <<TIP

설치 완료 — $TARGET_USER 로 로그인할 때 재생됩니다.
    $AUTOSTART/$ENTRY

로그아웃 후 다시 로그인하면 바로 보입니다 (재부팅 안 해도 됩니다).

지금 바로 보려면 (sudo 없이, 데스크톱에서):
    python3 $PREFIX/play.py --display sdl --fullscreen

제거:  sudo ./install.sh --uninstall
TIP
