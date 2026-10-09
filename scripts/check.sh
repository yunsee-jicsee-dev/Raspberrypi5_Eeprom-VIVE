#!/usr/bin/env bash
# 아무것도 설치하지 않고, 아래에서 위로 하나씩 확인한다.
#
#   ./scripts/check.sh          (화면 출력까지 보려면 sudo)
#
#   1. 파이썬과 pygame 이 있는가
#   2. 인트로가 그려지기는 하는가        ← 화면 없이도 확인된다
#   3. 이 화면에 띄울 수 있는가          ← 데스크톱이면 창, 콘솔이면 KMS/fb
#
# 1~2 가 되면 연출과 코드는 멀쩡한 것이고, 남은 문제는 전부 "어디에 띄우느냐"다.
set -uo pipefail
export PYGAME_HIDE_SUPPORT_PROMPT=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAY="$HERE/play.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { echo "  [ok]   $*"; }
bad()  { echo "  [안됨] $*"; }
note() { echo "         $*"; }

echo "===== 1. 파이썬과 pygame ====="
if ! command -v python3 >/dev/null; then
    bad "python3 이 없습니다."; exit 1
fi
ok "python3 $(python3 -V 2>&1 | cut -d' ' -f2)"
if ! ver=$(python3 -c "import pygame, sys; sys.stdout.write(pygame.version.ver)" 2>/dev/null); then
    bad "pygame 이 없습니다:  sudo apt install -y python3-pygame"; exit 1
fi
ok "pygame $ver"
[[ -f $PLAY ]] || { bad "play.py 를 찾지 못했습니다: $PLAY"; exit 1; }

echo
echo "===== 2. 인트로가 그려지는가 (화면 없이) ====="
# 화면이 전혀 없어도 되는 검사다. 여기까지 되면 연출·폰트·코드는 멀쩡하다.
if out=$(python3 "$PLAY" --save-frames "$TMP/f" --every 20 --fps 20 2>&1); then
    n=$(find "$TMP/f" -name '*.png' 2>/dev/null | wc -l)
    if (( n > 0 )); then
        ok "프레임 $n 장을 그렸습니다. 연출과 코드는 멀쩡합니다."
        note "표본: $(find "$TMP/f" -name '*.png' | head -1)"
    else
        bad "프레임이 하나도 안 나왔습니다."; echo "$out" | tail -5 | sed 's/^/         /'
    fi
else
    bad "그리다가 실패했습니다:"; echo "$out" | tail -10 | sed 's/^/         /'
    exit 1
fi

echo
echo "===== 3. 이 화면에 띄울 수 있는가 ====="
if [[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
    note "데스크톱 세션 안입니다. 전체화면 창으로 띄워 봅니다."
    note "(부팅 스플래시로 쓸 거라면 Ctrl+Alt+F2 콘솔에서 다시 돌려 주세요.)"
    echo
    read -rp "지금 띄워 볼까요? [Y/n] " yn
    if [[ ${yn,,} != n ]]; then
        python3 "$PLAY" --display sdl --fullscreen --max-seconds 20 2>&1 | sed 's/^/         /'
        echo
        read -rp "화면에 라즈베리 인트로가 보였나요? [y/N] " seen
        if [[ ${seen,,} == y ]]; then
            ok "됩니다. 로그인할 때 자동으로 틀려면:  sudo ./install.sh"
        else
            bad "안 보였습니다. 창이 다른 화면에 떴을 수 있습니다."
        fi
    fi
else
    [[ $EUID -eq 0 ]] || note "경고: sudo 없이는 화면 장치를 못 열 수 있습니다."
    seen=""
    for mode in kms fb; do
        echo
        note "--- $mode 로 재생 (약 4초) ---"
        python3 "$PLAY" --display "$mode" --fps 30 --max-seconds 20 2>&1 | sed 's/^/         /'
        echo
        read -rp "보였나요? [y/N] " yn
        [[ ${yn,,} == y ]] && { seen="$mode"; break; }
    done
    echo
    if [[ -n $seen ]]; then
        ok "'$seen' 로 보입니다."
        note "부팅 스플래시로 쓰려면:  sudo boot/install.sh"
    else
        bad "콘솔에서는 둘 다 안 보였습니다."
        note "부팅 스플래시는 plymouth 가 담당하므로 이것과 별개입니다:"
        note "    sudo boot/install.sh  후  sudo boot/preview.sh"
    fi
fi
