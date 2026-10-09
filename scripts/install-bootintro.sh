#!/usr/bin/env bash
# 부팅 인트로를 /opt 에 복사하고, 부팅이 다 끝난 뒤 한 번 재생되도록 등록한다.
#
#   sudo scripts/install-bootintro.sh               알아서 고름 (아래 기준)
#   sudo scripts/install-bootintro.sh --desktop     데스크톱 로그인 후 전체화면
#   sudo scripts/install-bootintro.sh --console     콘솔/헤드리스, 프레임버퍼
#   sudo scripts/install-bootintro.sh --uninstall   제거
#
# 고르는 기준: 데스크톱으로 부팅하는 기기(systemctl get-default 가 graphical.target)
# 는 --desktop, 아니면 --console.  데스크톱이 떠 있으면 컴포지터가 화면을 쥐고
# 있어서 /dev/fb0 에 써 봐야 아무것도 안 보이기 때문이다.
set -euo pipefail

PREFIX=/opt/rpi5-bootintro
UNIT=rpi5-bootintro.service
UNIT_DIR=/etc/systemd/system
DESKTOP_FILE=rpi5-bootintro.desktop
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "오류: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "sudo 로 실행해 주세요."

# 데스크톱 쪽 자동 실행은 로그인하는 사용자의 홈에 들어간다
TARGET_USER="${SUDO_USER:-}"
[[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]] || TARGET_USER="$(logname 2>/dev/null || true)"
USER_HOME=""
[[ -n "$TARGET_USER" ]] && USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
AUTOSTART_DIR="$USER_HOME/.config/autostart"

MODE=auto
case "${1:-}" in
    --uninstall) MODE=uninstall ;;
    --desktop)   MODE=desktop ;;
    --console)   MODE=console ;;
    "")          MODE=auto ;;
    *)           die "모르는 옵션: $1" ;;
esac

if [[ $MODE == uninstall ]]; then
    systemctl disable --now "$UNIT" 2>/dev/null || true
    rm -f "$UNIT_DIR/$UNIT"
    [[ -n "$AUTOSTART_DIR" ]] && rm -f "$AUTOSTART_DIR/$DESKTOP_FILE"
    rm -rf "$PREFIX"
    systemctl daemon-reload
    echo "제거했습니다."
    exit 0
fi

if [[ $MODE == auto ]]; then
    if [[ "$(systemctl get-default 2>/dev/null)" == graphical.target ]]; then
        MODE=desktop
    else
        MODE=console
    fi
    echo "부팅 방식을 보고 --$MODE 로 설치합니다."
fi

command -v python3 >/dev/null || die "python3 가 없습니다."
python3 -c "import pygame" 2>/dev/null \
    || die "pygame 이 없습니다:  sudo apt install -y python3-pygame"

# ---- 공통: 코드 복사 ----
install -d "$PREFIX"
for f in bootintro.py intro.py pixelfont.py; do
    [[ -f "$SRC_DIR/$f" ]] || die "$f 를 찾지 못했습니다."
    install -m 644 "$SRC_DIR/$f" "$PREFIX/$f"
done
# main.py 가 있으면 폰트를 그쪽에서 가져다 쓴다 (없어도 pixelfont 로 동작)
[[ -f "$SRC_DIR/main.py" ]] && install -m 644 "$SRC_DIR/main.py" "$PREFIX/main.py"

# 한쪽을 설치하면 다른 쪽은 걷어낸다 (둘 다 돌면 두 번 재생된다)
if [[ $MODE == desktop ]]; then
    id -u "$TARGET_USER" >/dev/null 2>&1 && [[ -n "$USER_HOME" && -d "$USER_HOME" ]] \
        || die "자동 실행을 넣을 사용자를 찾지 못했습니다. 일반 사용자로 로그인해 sudo 로 실행해 주세요."
    systemctl disable --now "$UNIT" 2>/dev/null || true
    rm -f "$UNIT_DIR/$UNIT"
    systemctl daemon-reload

    install -d -o "$TARGET_USER" -g "$TARGET_USER" "$AUTOSTART_DIR"
    install -m 644 -o "$TARGET_USER" -g "$TARGET_USER" \
        "$SRC_DIR/desktop/$DESKTOP_FILE" "$AUTOSTART_DIR/$DESKTOP_FILE"

    cat <<TIP

설치 완료 ($TARGET_USER 로 로그인할 때 재생).
    $AUTOSTART_DIR/$DESKTOP_FILE

지금 바로 보려면 데스크톱에서 (sudo 없이):
    python3 $PREFIX/bootintro.py --display sdl --fullscreen

재생 시점을 늦추려면 .desktop 파일의 --delay 값을 올리세요 (기본 1.5초).
TIP
else
    [[ -n "$AUTOSTART_DIR" ]] && rm -f "$AUTOSTART_DIR/$DESKTOP_FILE"
    install -m 644 "$SRC_DIR/systemd/$UNIT" "$UNIT_DIR/$UNIT"
    systemctl daemon-reload
    systemctl enable "$UNIT"

    cat <<TIP

설치 완료 (부팅이 다 끝난 뒤 재생).
지금 바로 확인하려면 — 데스크톱이 아닌 콘솔에서 (Ctrl+Alt+F2):
    sudo systemctl start $UNIT

부팅 로그 글자와 모서리 라즈베리를 가리려면 /boot/firmware/cmdline.txt 끝에
한 줄 그대로 이어서:
    quiet logo.nologo vt.global_cursor_default=0 consoleblank=0
TIP
fi
