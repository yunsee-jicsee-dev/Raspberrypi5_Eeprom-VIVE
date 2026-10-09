#!/bin/sh
# uninstall.sh - viveboot 를 제거한다.
# LUKS 키슬롯과 crypttab 항목은 자동으로 되돌리지 않는다. 먼저
#   sudo vive-luks-enroll --remove --token <토큰> --crypt-device <LUKS>
# 로 키슬롯을 빼고 crypttab 을 복구한 뒤에 실행하라.
set -eu

PREFIX=${PREFIX:-}
DESTDIR=${DESTDIR:-}
KEEP_CONF=${KEEP_CONF:-yes}

log() { printf 'uninstall: %s\n' "$*" >&2; }

[ -n "$DESTDIR" ] || [ "$(id -u)" = 0 ] || {
	printf 'uninstall: root 권한이 필요합니다\n' >&2
	exit 1
}

if grep -q 'viveboot-keyscript' "$DESTDIR$PREFIX/etc/crypttab" 2>/dev/null; then
	log "경고: /etc/crypttab 에 아직 viveboot keyscript 항목이 있습니다."
	log "       지금 제거하면 다음 부팅에서 루트를 열 수 없습니다."
	log "       먼저 끄세요 (패스프레이즈 확인까지 해 줍니다):"
	log "         sudo vive-boot-mode off"
	log "       직접 하려면 crypttab 을 고치고 update-initramfs -u 를 실행하세요."
	exit 1
fi

if [ -z "$DESTDIR" ] && command -v systemctl >/dev/null 2>&1; then
	systemctl disable --now viveboot-seqcheck.service >/dev/null 2>&1 || true
fi

rm -f "$DESTDIR$PREFIX/usr/bin/vive-floppy-token" \
	"$DESTDIR$PREFIX/usr/bin/vive-luks-enroll" \
	"$DESTDIR$PREFIX/usr/bin/vive-boot-mode" \
	"$DESTDIR$PREFIX/usr/bin/vive-boot-gate" \
	"$DESTDIR$PREFIX/usr/share/initramfs-tools/scripts/local-top/viveboot-gate" \
	"$DESTDIR$PREFIX/usr/share/initramfs-tools/hooks/viveboot" \
	"$DESTDIR$PREFIX/usr/share/initramfs-tools/scripts/local-bottom/viveboot" \
	"$DESTDIR$PREFIX/lib/systemd/system/viveboot-seqcheck.service"
rm -rf "$DESTDIR$PREFIX/usr/lib/viveboot" \
	"$DESTDIR$PREFIX/usr/share/doc/viveboot"

if [ "$KEEP_CONF" = yes ]; then
	log "$DESTDIR$PREFIX/etc/viveboot 는 남겨 둡니다 (KEEP_CONF=no 로 지울 수 있습니다)"
else
	rm -rf "$DESTDIR$PREFIX/etc/viveboot"
fi

if [ -z "$DESTDIR" ] && command -v update-initramfs >/dev/null 2>&1; then
	log "initramfs 를 다시 만듭니다"
	update-initramfs -u -k all
fi

log "제거 완료. /var/lib/viveboot/state 는 그대로 남아 있습니다."
