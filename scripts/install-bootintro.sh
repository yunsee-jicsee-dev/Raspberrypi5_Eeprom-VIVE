#!/usr/bin/env bash
# 부팅 인트로를 /opt 에 복사하고, 부팅 때 한 번 재생되도록 등록한다.
#
#   sudo scripts/install-bootintro.sh              기본: 데스크톱이 뜨기 전에 재생
#   sudo scripts/install-bootintro.sh --session    대안: 로그인 세션 안에서 재생
#   sudo scripts/install-bootintro.sh --no-plymouth  설치 + cmdline.txt 에서 splash 제거
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
DROP_SPLASH=0
for arg in "$@"; do
    case "$arg" in
        --boot|--console)  MODE=boot ;;
        --session|--desktop) MODE=session ;;
        --uninstall)       MODE=uninstall ;;
        --no-plymouth)     DROP_SPLASH=1 ;;
        *)                 die "모르는 옵션: $arg" ;;
    esac
done

# 커널 커맨드라인에서 splash 를 뺀다. plymouth 스플래시가 떠 있으면 화면(DRM) 을
# 쥐고 있어서 프레임버퍼에 그린 게 안 보인다. 부팅에 치명적인 파일이라
# 백업을 남기고, --no-plymouth 를 직접 준 경우에만 건드린다.
find_cmdline() {
    local p
    for p in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
        [[ -f $p ]] && { echo "$p"; return 0; }
    done
    return 1
}

drop_splash() {
    local f
    f="$(find_cmdline)" || { echo "cmdline.txt 를 찾지 못했습니다. 건너뜁니다."; return 0; }
    grep -qw splash "$f" || { echo "$f 에 splash 가 없습니다. 그대로 둡니다."; return 0; }
    [[ -f "$f.bootintro.bak" ]] || cp -a "$f" "$f.bootintro.bak"
    python3 - "$f" <<'PY'
import sys
path = sys.argv[1]
with open(path) as fp:
    text = fp.read()
kept = [t for t in text.split() if t != "splash"]
with open(path, "w") as fp:
    fp.write(" ".join(kept) + "\n")
PY
    echo "  $f 에서 splash 를 뺐습니다 (백업: $f.bootintro.bak)"
    echo "  되돌리려면:  sudo cp $f.bootintro.bak $f"
}

warn_splash() {
    local f
    f="$(find_cmdline)" || return 0
    grep -qw splash "$f" && cat <<WARN

경고: $f 에 splash 가 있습니다.
plymouth 스플래시가 화면을 쥐고 있으면 인트로가 안 보일 수 있습니다.
빼려면:  sudo $0 --no-plymouth
WARN
    return 0
}

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

if [[ $MODE == boot && ! -e /opt/rpi5-bootintro/bootintro.py ]]; then
    echo "참고: 먼저 'sudo scripts/try-intro.sh' 로 화면에 나오는지 확인하시길 권합니다."
    echo "      (부팅 경로에 넣기 전에 눈으로 보는 게 안전합니다.)"
    echo
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

┌─ 부팅이 막히면 (이것만 기억하세요) ─────────────────────────┐
│ SD/부트 파티션의 cmdline.txt 한 줄 끝에 한 칸 띄고 붙이면     │
│ 이 서비스만 건너뛰고 평소대로 부팅됩니다:                     │
│                                                              │
│     systemd.mask=$UNIT                      │
│                                                              │
│ 부팅된 뒤 제거:  sudo $0 --uninstall  │
└──────────────────────────────────────────────────────────────┘

프로그램은 20초 안에 스스로 끝나고(--max-seconds), 화면을 못 열면 조용히
건너뜁니다(--optional). 그래도 막히면 위 방법을 쓰세요.

재부팅해서 확인하세요:
    sudo reboot

안 나오면 로그부터 보세요:
    journalctl -u $UNIT -b

부팅 로그 글자와 모서리 라즈베리를 가리려면 /boot/firmware/cmdline.txt 끝에
한 줄 그대로 이어서:
    quiet logo.nologo vt.global_cursor_default=0 consoleblank=0
TIP
    if [[ $DROP_SPLASH == 1 ]]; then drop_splash; else warn_splash; fi
fi
