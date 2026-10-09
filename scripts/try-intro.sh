#!/usr/bin/env bash
# 설치하지 않고, 화면에 나오는지만 확인한다. 부팅에는 아무것도 손대지 않는다.
#
#   sudo scripts/try-intro.sh
#
# 콘솔(Ctrl+Alt+F2) 에서 돌리세요. 데스크톱 안에서는 컴포지터가 화면을 쥐고
# 있어서 kms 도 fb 도 실패하는 게 정상이라 판별이 안 됩니다.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$HERE/bootintro.py"
[[ -f $PY ]] || { echo "bootintro.py 를 찾지 못했습니다: $PY"; exit 1; }

if [[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
    cat <<WARN
지금 데스크톱 세션 안입니다. 여기서는 전체화면 창으로만 확인할 수 있습니다.
부팅 때 쓸 경로(kms/fb) 를 확인하려면 Ctrl+Alt+F2 로 콘솔에 로그인해서
다시 돌려 주세요.

WARN
    read -rp "그래도 전체화면 창으로 한 번 볼까요? [y/N] " yn
    [[ ${yn,,} == y ]] || exit 0
    python3 "$PY" --display sdl --fullscreen --max-seconds 20
    exit $?
fi

[[ $EUID -eq 0 ]] || echo "참고: sudo 없이는 화면 장치를 못 열 수 있습니다."

ok=""
for mode in kms fb; do
    echo
    echo "───── $mode 로 재생합니다 (약 4초) ─────"
    python3 "$PY" --display "$mode" --fps 30 --max-seconds 20 2>&1 | sed 's/^/  /'
    echo
    read -rp "화면에 라즈베리 인트로가 보였나요? [y/N] " yn
    if [[ ${yn,,} == y ]]; then ok="$mode"; break; fi
done

echo
if [[ -n $ok ]]; then
    cat <<DONE
좋습니다. '$ok' 로 보입니다.

이제 설치해도 됩니다:
    sudo scripts/install-bootintro.sh

서비스는 --display auto 로 돌기 때문에 kms 를 먼저 시도하고 안 되면 fb 로
넘어갑니다. 둘 다 안 되면 조용히 건너뛰고 부팅은 그대로 진행됩니다.
DONE
else
    cat <<FAIL
둘 다 안 보였습니다. 설치하지 마세요.

아래를 돌려서 나온 내용을 알려 주시면 원인을 찾겠습니다:
    sudo scripts/diagnose.sh
FAIL
fi
