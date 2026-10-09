#!/usr/bin/env bash
# 부팅 인트로를 /opt 에 복사하고 systemd 서비스로 등록한다.
#   sudo scripts/install-bootintro.sh              설치 + 사용 설정
#   sudo scripts/install-bootintro.sh --uninstall  제거
set -euo pipefail

PREFIX=/opt/rpi5-bootintro
UNIT=rpi5-bootintro.service
UNIT_DIR=/etc/systemd/system
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "오류: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "sudo 로 실행해 주세요."

if [[ "${1:-}" == "--uninstall" ]]; then
    systemctl disable --now "$UNIT" 2>/dev/null || true
    rm -f "$UNIT_DIR/$UNIT"
    rm -rf "$PREFIX"
    systemctl daemon-reload
    echo "제거했습니다."
    exit 0
fi

command -v python3 >/dev/null || die "python3 가 없습니다."
python3 -c "import pygame" 2>/dev/null \
    || die "pygame 이 없습니다:  sudo apt install -y python3-pygame"

install -d "$PREFIX"
for f in bootintro.py intro.py pixelfont.py; do
    [[ -f "$SRC_DIR/$f" ]] || die "$f 를 찾지 못했습니다."
    install -m 644 "$SRC_DIR/$f" "$PREFIX/$f"
done
# main.py 가 있으면 폰트를 그쪽에서 가져다 쓴다 (없어도 pixelfont 로 동작)
[[ -f "$SRC_DIR/main.py" ]] && install -m 644 "$SRC_DIR/main.py" "$PREFIX/main.py"

install -m 644 "$SRC_DIR/systemd/$UNIT" "$UNIT_DIR/$UNIT"
systemctl daemon-reload
systemctl enable "$UNIT"

cat <<'TIP'

설치 완료. 지금 바로 확인하려면:
    sudo systemctl start rpi5-bootintro.service

부팅 로그와 무지개 화면을 가리려면 /boot/firmware/cmdline.txt 끝에 아래를 덧붙이세요
(한 줄짜리 파일이니 줄바꿈 없이 이어서):
    quiet logo.nologo vt.global_cursor_default=0 consoleblank=0

데스크톱의 기본 스플래시(plymouth) 와 겹치면 cmdline.txt 에서 splash 를 지우거나
    sudo systemctl disable plymouth-quit-wait.service
TIP
