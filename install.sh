#!/bin/sh
# install.sh - viveboot 구성요소를 시스템에 설치한다 (Raspberry Pi OS / Debian).
set -eu

PREFIX=${PREFIX:-}
DESTDIR=${DESTDIR:-}
SRC=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

BIN=$DESTDIR$PREFIX/usr/bin
LIBDIR=$DESTDIR$PREFIX/usr/lib/viveboot
CONFDIR=$DESTDIR$PREFIX/etc/viveboot
HOOKDIR=$DESTDIR$PREFIX/usr/share/initramfs-tools/hooks
BOTTOMDIR=$DESTDIR$PREFIX/usr/share/initramfs-tools/scripts/local-bottom
TOPDIR=$DESTDIR$PREFIX/usr/share/initramfs-tools/scripts/local-top
UNITDIR=$DESTDIR$PREFIX/lib/systemd/system
UDEVDIR=$DESTDIR$PREFIX/etc/udev/rules.d
DOCDIR=$DESTDIR$PREFIX/usr/share/doc/viveboot

log() { printf 'install: %s\n' "$*" >&2; }

[ -n "$DESTDIR" ] || [ "$(id -u)" = 0 ] || {
	printf 'install: root 권한이 필요합니다 (sudo ./install.sh)\n' >&2
	exit 1
}

for d in "$BIN" "$LIBDIR" "$CONFDIR" "$HOOKDIR" "$BOTTOMDIR" "$TOPDIR" "$UNITDIR" "$UDEVDIR" "$DOCDIR"; do
	mkdir -p "$d"
done

install -m 0755 "$SRC/tools/vive-floppy-token" "$BIN/vive-floppy-token"
install -m 0755 "$SRC/tools/vive-luks-enroll" "$BIN/vive-luks-enroll"
install -m 0755 "$SRC/tools/vive-boot-mode" "$BIN/vive-boot-mode"
install -m 0755 "$SRC/tools/vive-boot-gate" "$BIN/vive-boot-gate"
install -m 0755 "$SRC/tools/viveboot-seqcheck" "$LIBDIR/viveboot-seqcheck"
install -m 0644 "$SRC/lib/viveboot-common.sh" "$LIBDIR/viveboot-common.sh"
install -m 0755 "$SRC/initramfs/scripts/viveboot-keyscript" \
	"$LIBDIR/viveboot-keyscript"
install -m 0755 "$SRC/initramfs/hooks/viveboot" "$HOOKDIR/viveboot"
install -m 0755 "$SRC/initramfs/scripts/local-bottom/viveboot" \
	"$BOTTOMDIR/viveboot"
install -m 0755 "$SRC/initramfs/scripts/local-top/viveboot-gate" \
	"$TOPDIR/viveboot-gate"
install -m 0644 "$SRC/udev/59-viveboot-floppy.rules" \
	"$UDEVDIR/59-viveboot-floppy.rules"
install -m 0644 "$SRC/systemd/viveboot-seqcheck.service" \
	"$UNITDIR/viveboot-seqcheck.service"
for f in "$SRC"/docs/*.md "$SRC/README.md"; do
	if [ -f "$f" ]; then
		install -m 0644 "$f" "$DOCDIR/"
	fi
done

if [ -f "$CONFDIR/viveboot.conf" ]; then
	log "$CONFDIR/viveboot.conf 는 그대로 둡니다 (새 기본값은 viveboot.conf.dist 참고)"
	install -m 0644 "$SRC/etc/viveboot.conf" "$CONFDIR/viveboot.conf.dist"
else
	install -m 0644 "$SRC/etc/viveboot.conf" "$CONFDIR/viveboot.conf"
fi

# --- 환경 점검 --------------------------------------------------------------
if [ -z "$DESTDIR" ]; then
	command -v openssl >/dev/null 2>&1 \
		|| log "경고: openssl 이 없습니다 -> apt install openssl"
	openssl kdf -keylen 32 -kdfopt digest:SHA2-256 -kdfopt hexpass:00 \
		-kdfopt hexsalt:00 -kdfopt iter:1000 PBKDF2 >/dev/null 2>&1 \
		|| log "경고: 이 openssl 은 'kdf PBKDF2' 를 지원하지 않습니다 (3.0 이상 필요)"
	command -v cryptsetup >/dev/null 2>&1 \
		|| log "경고: cryptsetup 이 없습니다 -> apt install cryptsetup cryptsetup-initramfs"
	[ -d /usr/share/initramfs-tools ] \
		|| log "경고: initramfs-tools 가 없습니다 -> apt install initramfs-tools"
	if [ -f /boot/firmware/config.txt ] \
		&& ! grep -qE '^[[:space:]]*auto_initramfs=1' /boot/firmware/config.txt; then
		log "경고: /boot/firmware/config.txt 에 auto_initramfs=1 이 없습니다"
	fi
	if command -v udevadm >/dev/null 2>&1; then
		udevadm control --reload-rules || true
	fi
	if command -v systemctl >/dev/null 2>&1; then
		systemctl daemon-reload || true
		if systemctl enable viveboot-seqcheck.service >/dev/null 2>&1; then
			log "viveboot-seqcheck.service 를 활성화했습니다"
		else
			log "경고: viveboot-seqcheck.service 활성화 실패"
		fi
	fi
fi

cat >&2 <<'EOF'
install: 설치 완료.

다음 순서로 진행하세요 (자세한 내용은 docs/install.md):
  1) sudo vive-floppy-token format /dev/sdX --label MY-TOKEN --ask-pin
  2) sudo vive-floppy-token backup /dev/sdX /root/token-backup.img
  3) sudo vive-luks-enroll --token /dev/sdX --crypt-device /dev/<LUKS파티션>
  4) 재부팅 전 docs/install.md 의 '재부팅 전 점검' 을 반드시 확인
     또는 sudo vive-boot-mode status 로 한 화면에 확인

켜고 끄기 (제거하지 않고):
  sudo vive-boot-mode status      현재 모드와 근거
  sudo vive-boot-mode off         패스프레이즈로 부팅 (토큰 키슬롯은 남는다)
  sudo vive-boot-mode on          다시 토큰 필수로
  sudo vive-boot-mode bypass on   다음 부팅 한 번만 우회
EOF
