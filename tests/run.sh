#!/bin/sh
# 전체 테스트 실행. 실물 플로피나 root 권한 없이 돈다.
set -u
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
rc=0

printf '=== 파이썬 도구 테스트 ===\n'
python3 "$ROOT/tests/test_token.py" || rc=1

printf '\n=== 쉘/파이썬 교차 검증 ===\n'
sh "$ROOT/tests/test_crossimpl.sh" || rc=1

printf '\n=== 쉘 문법 검사 ===\n'
for f in "$ROOT"/install.sh "$ROOT"/uninstall.sh \
	"$ROOT"/lib/viveboot-common.sh \
	"$ROOT"/tools/vive-luks-enroll "$ROOT"/tools/viveboot-seqcheck \
	"$ROOT"/initramfs/hooks/viveboot \
	"$ROOT"/initramfs/scripts/viveboot-keyscript \
	"$ROOT"/initramfs/scripts/local-bottom/viveboot \
	"$ROOT"/etc/viveboot.conf "$ROOT"/tests/test_crossimpl.sh; do
	if sh -n "$f"; then
		printf 'ok   - %s\n' "${f#"$ROOT"/}"
	else
		printf 'FAIL - %s\n' "${f#"$ROOT"/}"
		rc=1
	fi
done

if command -v shellcheck >/dev/null 2>&1; then
	printf '\n=== shellcheck ===\n'
	shellcheck -s sh "$ROOT"/lib/viveboot-common.sh \
		"$ROOT"/initramfs/scripts/viveboot-keyscript \
		"$ROOT"/tools/viveboot-seqcheck "$ROOT"/tools/vive-luks-enroll \
		"$ROOT"/install.sh "$ROOT"/uninstall.sh || rc=1
else
	printf '\n(shellcheck 없음 - 생략)\n'
fi

printf '\n전체 결과: %s\n' "$([ $rc -eq 0 ] && echo 통과 || echo 실패)"
exit $rc
