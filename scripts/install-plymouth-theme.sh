#!/usr/bin/env bash
# 인트로를 plymouth 부팅 테마로 설치한다.
#
#   sudo scripts/install-plymouth-theme.sh             설치
#   sudo scripts/install-plymouth-theme.sh --uninstall 원래 테마로 복구
#   sudo scripts/install-plymouth-theme.sh --no-cmdline  cmdline.txt 는 건드리지 않기
#
# systemd 서비스와 달리 부팅 경로에 끼어들지 않는다. plymouth 는 원래 그 자리에
# 있는 프로그램이고, 테마가 잘못돼도 스플래시가 안 뜰 뿐 부팅은 그대로 진행된다.
set -euo pipefail

NAME=rpi5-intro
THEME_ROOT=/usr/share/plymouth/themes
THEME_DIR="$THEME_ROOT/$NAME"
SAVED="$THEME_ROOT/.$NAME.previous-theme"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "오류: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "sudo 로 실행해 주세요."

# 라즈베리파이 OS 는 config.txt 에 auto_initramfs=1 이 들어 있다. 그러면 plymouth 가
# initramfs 안에서 돌기 때문에, 테마만 바꾸고 initramfs 를 다시 굽지 않으면 옛 테마가
# 그대로 쓰인다 (테마는 바뀌었는데 화면은 그대로인 증상).
uses_initramfs() {
    grep -qsE '^[[:space:]]*(auto_)?initramfs' /boot/firmware/config.txt /boot/config.txt \
        && return 0
    command -v update-initramfs >/dev/null 2>&1 \
        && compgen -G '/boot/firmware/initramfs*' >/dev/null && return 0
    command -v update-initramfs >/dev/null 2>&1 \
        && compgen -G '/boot/initrd.img*' >/dev/null && return 0
    return 1
}

rebuild_initramfs() {
    if ! uses_initramfs; then
        echo "initramfs 를 쓰지 않는 설정입니다. 다시 구울 필요 없습니다."
        return 0
    fi
    if ! command -v update-initramfs >/dev/null 2>&1; then
        echo "경고: initramfs 를 쓰는데 update-initramfs 가 없습니다. 직접 다시 구워 주세요." >&2
        return 0
    fi
    echo "initramfs 를 다시 굽는 중 (plymouth 가 그 안에서 돕니다)..."
    update-initramfs -u 2>&1 | sed 's/^/  /'
}

find_cmdline() {
    local p
    for p in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
        [[ -f $p ]] && { echo "$p"; return 0; }
    done
    return 1
}

MODE=install
TOUCH_CMDLINE=1
for arg in "$@"; do
    case "$arg" in
        --uninstall)  MODE=uninstall ;;
        --no-cmdline) TOUCH_CMDLINE=0 ;;
        *)            die "모르는 옵션: $arg" ;;
    esac
done

command -v plymouth-set-default-theme >/dev/null \
    || die "plymouth 가 없습니다:  sudo apt install -y plymouth plymouth-themes"

if [[ $MODE == uninstall ]]; then
    back="$(cat "$SAVED" 2>/dev/null || echo)"
    if [[ -n $back ]]; then
        plymouth-set-default-theme "$back"
        echo "테마를 '$back' 로 되돌렸습니다."
    else
        echo "이전 테마 기록이 없습니다. 직접 고르세요:"
        plymouth-set-default-theme --list
    fi
    rm -rf "$THEME_DIR" "$SAVED"
    rebuild_initramfs
    echo "cmdline.txt 의 splash 는 그대로 뒀습니다 (원래 있던 것일 수 있어서)."
    exit 0
fi

# ---- 프레임 굽기 ----
command -v python3 >/dev/null || die "python3 가 없습니다."
python3 -c "import pygame" 2>/dev/null \
    || die "pygame 이 없습니다:  sudo apt install -y python3-pygame"

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
echo "인트로 프레임을 굽는 중..."
python3 "$SRC_DIR/scripts/make-plymouth-theme.py" --out "$BUILD" --theme-dir "$THEME_DIR" \
    | sed 's/^/  /'
[[ -f "$BUILD/$NAME/$NAME.plymouth" ]] || die "테마를 만들지 못했습니다."

# ---- 설치 ----
# 되돌릴 수 있게 지금 테마를 적어 둔다 (우리 테마를 덮어 설치하는 경우는 빼고)
current="$(plymouth-set-default-theme 2>/dev/null || echo)"
if [[ -n $current && $current != "$NAME" ]]; then
    install -d "$THEME_ROOT"
    echo "$current" > "$SAVED"
    echo "이전 테마 '$current' 를 기록했습니다."
fi

rm -rf "$THEME_DIR"
install -d "$THEME_DIR"
install -m 644 "$BUILD/$NAME"/* "$THEME_DIR/"
plymouth-set-default-theme "$NAME"
echo "테마를 '$NAME' 로 바꿨습니다."
rebuild_initramfs

# ---- cmdline: plymouth 는 splash 가 있어야 화면에 뜬다 ----
if [[ $TOUCH_CMDLINE == 1 ]]; then
    if f="$(find_cmdline)"; then
        if grep -qw splash "$f"; then
            echo "$f 에 splash 가 이미 있습니다."
        else
            [[ -f "$f.plymouth.bak" ]] || cp -a "$f" "$f.plymouth.bak"
            python3 - "$f" <<'PY'
import sys
path = sys.argv[1]
with open(path) as fp:
    toks = fp.read().split()
if "splash" not in toks:
    toks.append("splash")
with open(path, "w") as fp:
    fp.write(" ".join(toks) + "\n")
PY
            echo "$f 에 splash 를 넣었습니다 (백업: $f.plymouth.bak)"
        fi
    else
        echo "cmdline.txt 를 찾지 못했습니다. splash 를 직접 넣어 주세요."
    fi
fi

cat <<TIP

설치 완료. 재부팅하면 부팅 스플래시 자리에 인트로가 나옵니다:
    sudo reboot

되돌리기:
    sudo $0 --uninstall

systemd 서비스가 아니라서 부팅을 붙잡지 않습니다. 테마에 문제가 있으면
스플래시가 안 뜰 뿐 부팅은 평소대로 진행됩니다.

안 나오면 콘솔(Ctrl+Alt+F2) 에서 미리보기 + 오류 확인:
    sudo plymouthd --no-daemon --debug --debug-file=/tmp/ply.log &
    sleep 1; sudo plymouth --show-splash; sleep 8; sudo plymouth quit
    grep -iE "error|script|$NAME" /tmp/ply.log | head -40
TIP
