#!/usr/bin/env bash
# 부팅 인트로를 /opt 에 복사하고, 부팅 때 한 번 재생되도록 등록한다.
#
#   sudo scripts/install-bootintro.sh              기본: 데스크톱이 뜨기 전에 재생
#   sudo scripts/install-bootintro.sh --session    대안: 로그인 세션 안에서 재생
#   sudo scripts/install-bootintro.sh --uninstall  제거
#
# 기본(--boot) 은 systemd 서비스로 multi-user.target 과 display-manager.service
# 사이에 끼어든다. 올라올 서비스는 다 올라왔고 컴포지터는 아직 없는 자리라서,
# /dev/fb0 이 우리 것이고 바탕화면이 비칠 일이 없다.
#
# --session 은 데스크톱 세션 안에서 전체화면 창으로 띄운다. XDG autostart 는
# 바탕화면이 그려진 뒤에 실행되므로 바탕화면이 잠깐 보인다. 기본 방식이
# 안 통하는 기기에서만 쓴다.
set -euo pipefail

PREFIX=/opt/rpi5-bootintro
UNIT=rpi5-bootintro.service
UNIT_DIR=/etc/systemd/system
DESKTOP_FILE=rpi5-bootintro.desktop
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "오류: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "sudo 로 실행해 주세요."

# 세션 쪽 자동 실행은 로그인하는 사용자의 홈에 들어간다
TARGET_USER="${SUDO_USER:-}"
[[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]] || TARGET_USER="$(logname 2>/dev/null || true)"
USER_HOME=""
[[ -n "$TARGET_USER" ]] && USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
AUTOSTART_DIR="$USER_HOME/.config/autostart"

MODE=boot
case "${1:-}" in
    ""|--boot|--console) MODE=boot ;;
    --session|--desktop) MODE=session ;;
    --uninstall)         MODE=uninstall ;;
    *)                   die "모르는 옵션: $1" ;;
esac

remove_unit() {
    systemctl disable --now "$UNIT" 2>/dev/null || true
    rm -f "$UNIT_DIR/$UNIT"
    systemctl daemon-reload
}
remove_autostart() {
    [[ -n "$AUTOSTART_DIR" ]] && rm -f "$AUTOSTART_DIR/$DESKTOP_FILE"
    return 0
}

if [[ $MODE == uninstall ]]; then
    remove_unit
    remove_autostart
    rm -rf "$PREFIX"
    echo "제거했습니다."
    exit 0
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
if [[ $MODE == session ]]; then
    id -u "$TARGET_USER" >/dev/null 2>&1 && [[ -n "$USER_HOME" && -d "$USER_HOME" ]] \
        || die "자동 실행을 넣을 사용자를 찾지 못했습니다. 일반 사용자로 로그인해 sudo 로 실행해 주세요."
    remove_unit
    install -d -o "$TARGET_USER" -g "$TARGET_USER" "$AUTOSTART_DIR"
    install -m 644 -o "$TARGET_USER" -g "$TARGET_USER" \
        "$SRC_DIR/desktop/$DESKTOP_FILE" "$AUTOSTART_DIR/$DESKTOP_FILE"

    cat <<TIP

설치 완료 — 세션 방식 ($TARGET_USER 로 로그인할 때 재생).
    $AUTOSTART_DIR/$DESKTOP_FILE

이 방식은 바탕화면이 그려진 뒤에 프로세스가 시작되므로 바탕화면이 잠깐 보입니다.
그게 싫으면:  sudo $0

지금 바로 보려면 데스크톱에서 (sudo 없이):
    python3 $PREFIX/bootintro.py --display sdl --fullscreen
TIP
else
    remove_autostart
    install -m 644 "$SRC_DIR/systemd/$UNIT" "$UNIT_DIR/$UNIT"
    systemctl daemon-reload
    systemctl enable "$UNIT"

    cat <<TIP

설치 완료 — 부팅 방식 (데스크톱이 뜨기 전에 재생).
서비스가 multi-user.target 과 display-manager.service 사이에 들어갑니다.
데스크톱은 인트로(3.7초) 가 끝난 뒤에 시작합니다.

재부팅해서 확인하세요:
    sudo reboot

안 나오면 로그부터 보세요:
    journalctl -u $UNIT -b

부팅 로그 글자와 모서리 라즈베리를 가리려면 /boot/firmware/cmdline.txt 끝에
한 줄 그대로 이어서 (그리고 splash 가 있으면 지우세요):
    quiet logo.nologo vt.global_cursor_default=0 consoleblank=0
TIP
fi
