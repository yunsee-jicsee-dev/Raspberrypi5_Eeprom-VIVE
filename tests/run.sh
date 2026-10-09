#!/bin/sh
# 전체 테스트 실행. 실물 플로피나 root 권한 없이 돈다.
set -u
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
rc=0

printf '=== 파이썬 도구 테스트 ===\n'
python3 "$ROOT/tests/test_token.py" || rc=1

printf '\n=== 쉘/파이썬 교차 검증 ===\n'
sh "$ROOT/tests/test_crossimpl.sh" || rc=1

printf '\n=== 부팅 모드 on/off 스위치 ===\n'
sh "$ROOT/tests/test_bootmode.sh" || rc=1

printf '\n=== 쉘 문법 검사 ===\n'
for f in "$ROOT"/install.sh "$ROOT"/uninstall.sh \
	"$ROOT"/lib/viveboot-common.sh \
	"$ROOT"/tools/vive-luks-enroll "$ROOT"/tools/viveboot-seqcheck \
	"$ROOT"/tools/vive-boot-mode \
	"$ROOT"/initramfs/hooks/viveboot \
	"$ROOT"/initramfs/scripts/viveboot-keyscript \
	"$ROOT"/initramfs/scripts/local-bottom/viveboot \
	"$ROOT"/etc/viveboot.conf "$ROOT"/tests/test_crossimpl.sh \
	"$ROOT"/tests/test_bootmode.sh; do
	if sh -n "$f"; then
		printf 'ok   - %s\n' "${f#"$ROOT"/}"
	else
		printf 'FAIL - %s\n' "${f#"$ROOT"/}"
		rc=1
	fi
done

# 규칙은 저장소 루트의 .shellcheckrc 에 있다 (shell=sh, SC2034 해제).
# --severity=warning: info 단계 지적은 전부 의도한 관용구라 막지 않는다.
if command -v shellcheck >/dev/null 2>&1; then
	printf '\n=== shellcheck ===\n'
	shellcheck -s sh --severity=warning "$ROOT"/lib/viveboot-common.sh \
		"$ROOT"/initramfs/scripts/viveboot-keyscript \
		"$ROOT"/tools/viveboot-seqcheck "$ROOT"/tools/vive-luks-enroll \
		"$ROOT"/tools/vive-boot-mode \
		"$ROOT"/install.sh "$ROOT"/uninstall.sh || rc=1
elif [ "${VIVEBOOT_REQUIRE_SHELLCHECK:-0}" = 1 ]; then
	# CI 는 이 값을 1 로 두어 '없으면 생략' 을 금지한다.
	printf '\n=== shellcheck ===\n'
	printf 'FAIL - shellcheck 가 없습니다 (VIVEBOOT_REQUIRE_SHELLCHECK=1)\n'
	printf '       apt install shellcheck\n'
	rc=1
else
	printf '\n(shellcheck 없음 - 생략. 반드시 돌리려면 VIVEBOOT_REQUIRE_SHELLCHECK=1)\n'
fi

printf '\n전체 결과: %s\n' "$([ $rc -eq 0 ] && echo 통과 || echo 실패)"
exit $rc
