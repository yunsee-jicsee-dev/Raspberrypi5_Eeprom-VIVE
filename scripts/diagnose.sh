#!/usr/bin/env bash
# 인트로가 화면에 안 나올 때, 원인을 한 번에 좁히기 위한 정보 수집.
#   sudo scripts/diagnose.sh
# 출력을 그대로 복사해서 주시면 됩니다. (읽기만 하고, 마지막 실제 재생 시험만
# 화면에 그림을 그립니다.)
set -uo pipefail

UNIT=rpi5-bootintro.service
PREFIX=/opt/rpi5-bootintro
BOOTINTRO="$PREFIX/bootintro.py"
[[ -f $BOOTINTRO ]] || BOOTINTRO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bootintro.py"

hr() { echo; echo "===== $* ====="; }

hr "기기와 OS"
{ tr -d '\0' < /proc/device-tree/model; echo; } 2>/dev/null || echo '(모델 정보 없음)'
. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"
uname -r
echo "세션: XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-없음} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-없음} DISPLAY=${DISPLAY:-없음}"

hr "서비스 등록 상태"
systemctl is-enabled "$UNIT" 2>&1
systemctl status "$UNIT" --no-pager -l 2>&1 | head -20

hr "이번 부팅의 서비스 로그"
journalctl -b -u "$UNIT" --no-pager 2>&1 | tail -30

hr "순서가 실제로 먹었는지"
echo "-- display-manager 가 가리키는 유닛:"
systemctl show display-manager.service -p Id -p FragmentPath 2>&1
echo "-- 우리 유닛의 Before/After:"
systemctl show "$UNIT" -p Before -p After 2>/dev/null | tr ' ' '\n' | grep -v '^$' | head -40 \
    || echo "   (systemctl 를 쓸 수 없음)"
echo "-- 순서 꼬임(ordering cycle) 이 있었는지:"
journalctl -b --no-pager 2>/dev/null | grep -i 'ordering cycle' | head -10 || echo "   (없음)"

hr "plymouth"
systemctl is-active plymouth-start.service plymouth-quit.service plymouth-quit-wait.service 2>&1 | paste -sd' '
journalctl -b -u plymouth-quit-wait.service --no-pager 2>&1 | tail -10
echo "-- cmdline:"
cat /boot/firmware/cmdline.txt 2>/dev/null || cat /boot/cmdline.txt 2>/dev/null

hr "화면 장치"
echo "-- /dev/fb*:"; ls -l /dev/fb* 2>&1
for n in /sys/class/graphics/fb*; do
    [[ -d $n ]] || continue
    echo "   $(basename "$n"): size=$(cat "$n/virtual_size" 2>/dev/null) bpp=$(cat "$n/bits_per_pixel" 2>/dev/null) stride=$(cat "$n/stride" 2>/dev/null) name=$(cat "$n/name" 2>/dev/null)"
done
echo "-- /dev/dri:"; ls -l /dev/dri/ 2>&1
echo "-- DRM master 를 쥐고 있는 프로세스:"
fuser -v /dev/dri/card* 2>&1 | head -10 || echo "   (fuser 없음 / 없음)"

hr "SDL 이 쓸 수 있는 비디오 드라이버"
python3 - <<'PY' 2>&1 | grep -v -e '^pygame' -e 'Hello from'
import os
os.environ.setdefault("SDL_AUDIODRIVER", "dummy")
import pygame
print("  버전: pygame", pygame.version.ver,
      "/ SDL", ".".join(map(str, pygame.get_sdl_version())))
for drv in ("kmsdrm", "wayland", "x11", "fbcon", "offscreen", "dummy"):
    os.environ["SDL_VIDEODRIVER"] = drv
    try:
        pygame.display.init()
        print(f"  {drv:10s} OK")
        pygame.display.quit()
    except Exception as e:
        print(f"  {drv:10s} 안 됨 — {e}")
PY

hr "실제 재생 시험 (화면을 봐 주세요)"
echo "-- 1) KMS 로:"
timeout 20 python3 "$BOOTINTRO" --display kms --fps 20 2>&1 | grep -v -e '^pygame' -e 'Hello from' | sed 's/^/   /'
echo "-- 2) 프레임버퍼로:"
timeout 20 python3 "$BOOTINTRO" --display fb --fps 20 2>&1 | grep -v -e '^pygame' -e 'Hello from' | sed 's/^/   /'
echo
echo "위 둘 중 화면에 인트로가 보인 게 있으면 알려 주세요 (둘 다 안 보였는지도)."
