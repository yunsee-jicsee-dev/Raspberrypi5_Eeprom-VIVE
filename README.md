# Raspberrypi5_Eeprom-VIVE — 플로피 섹터 보안 부팅 (viveboot)

[![tests](https://github.com/yunsee-jicsee-dev/Raspberrypi5_Eeprom-VIVE/actions/workflows/tests.yml/badge.svg)](https://github.com/yunsee-jicsee-dev/Raspberrypi5_Eeprom-VIVE/actions/workflows/tests.yml)

USB 플로피 디스크의 **원시 섹터**를 물리 부팅 토큰으로 쓰는 Raspberry Pi 5용
보안 부팅 구성이다. 플로피가 드라이브에 꽂혀 있지 않으면 암호화된 루트
파일시스템이 열리지 않고 부팅이 initramfs 에서 멈춘다.

```
전원 ─▶ EEPROM ─▶ firmware ─▶ kernel+initramfs ─▶ [viveboot 키스크립트]
                                                        │
                            USB FDD 의 흩어진 섹터 ──────┤ 키 조각 6개 수집
                                                        │ PBKDF2 → LUKS 암호문
                                                        ▼
                                              LUKS 루트 해제 ─▶ systemd
```

- 파일시스템 없이 **섹터 단위**로만 기록한다. 마운트도, 복사도, 실수로
  포맷하는 것도 어렵다 (FAT 부트 시그니처를 일부러 넣지 않는다).
- 키를 6조각으로 쪼개 디스크 전체에 **흩어 배치**하고, 빈 섹터는 난수로 채워
  키 위치가 드러나지 않게 한다.
- 선택적 **PIN**으로 "가진 것 + 아는 것" 2요소를 만든다.
- 부팅마다 플로피의 **카운터 섹터**를 올려, 복제본이 쓰였는지 사후에 탐지한다.
- initramfs 안에서는 `dd`, `od`, `openssl` 만 쓴다. 파이썬·bash 의존성 없음.

## 빠른 시작

```sh
# 0) 준비: USB 플로피 드라이브 + 1.44MB 디스켓, LUKS 로 암호화된 루트
sudo apt install cryptsetup cryptsetup-initramfs initramfs-tools openssl

# 1) 설치
sudo ./install.sh

# 2) 토큰 만들기 (/dev/sdX 는 플로피 드라이브. 디스켓 내용은 전부 지워진다)
sudo vive-floppy-token scan                     # 후보 장치 확인
sudo vive-floppy-token format /dev/sdX --label MY-TOKEN --ask-pin

# 3) 백업 — 이걸 건너뛰면 디스켓이 상하는 날 루트를 잃는다
sudo vive-floppy-token backup /dev/sdX /root/token-backup.img

# 4) LUKS 키슬롯 등록 + crypttab 연결 + initramfs 재생성
sudo vive-luks-enroll --token /dev/sdX --crypt-device /dev/nvme0n1p2

# 5) 재부팅 전 점검 (docs/install.md '재부팅 전 점검' 을 그대로 따라갈 것)
```

실물 하드웨어 없이 전체 흐름을 시험하려면 1.44MB 이미지 파일로 똑같이 할 수 있다:

```sh
python3 tools/vive-floppy-token format /tmp/token.img --iter 200000
python3 tools/vive-floppy-token info /tmp/token.img
sh tests/run.sh          # 파이썬 구현과 initramfs 쉘 구현이 같은 키를 내는지 검증
```

## 켜고 끄기

제거하지 않고 토큰 요구만 켜고 끈다. 끈 상태에서도 토큰 키슬롯은 LUKS 안에
그대로 남아 있어서, 다시 켜면 같은 디스켓으로 돌아온다.

```sh
sudo vive-boot-mode status      # 현재 모드 + 그 판단의 근거 전부
sudo vive-boot-mode off         # 패스프레이즈로 부팅 (토큰 키슬롯은 유지)
sudo vive-boot-mode on          # 다시 토큰 필수로
sudo vive-boot-mode bypass on   # 다음 부팅 한 번만 우회
```

`on`/`off` 는 `/etc/crypttab` 의 `keyscript=` 를 넣고 빼고 `update-initramfs`
까지 돌린다. 끈 상태의 부팅 경로에는 viveboot 코드가 아예 들어오지 않는다 —
안전장치가 viveboot 자신의 정확성에 의존하지 않게 하려는 선택이다.

**사전 검증이 이 도구의 핵심이다.** 그냥 플래그를 뒤집는 것이 아니다.

| | 켜기 전에 확인하는 것 | 통과 못 하면 |
| --- | --- | --- |
| `on` | 토큰에서 파생한 암호문이 **정말 이 LUKS 를 여는지** (부팅 때 도는 그 키스크립트를 그대로 실행), 그리고 토큰 외 키슬롯이 남아 있는지 | 켜지 않고 `crypttab` 을 그대로 둔다 |
| `off` | 입력한 패스프레이즈가 **토큰 슬롯이 아닌 다른 슬롯**을 여는지 | 끄지 않는다 (복구 경로 없이 끄는 것을 막는다) |

검증을 건너뛰려면 `--force` 가 필요하고, 그 경우 다음 부팅에서 못 들어갈 수
있다고 두 번 경고한다. `update-initramfs` 가 실패하면 `crypttab` 을 되돌린다.

`bypass on` 은 `/boot/firmware/cmdline.txt` 에 `viveboot=off` 를 넣는다. 이
경우 키스크립트는 토큰을 아예 읽지 않고 `cryptsetup` 의 기본 대화형 경로와
똑같이 패스프레이즈를 묻는다. 토큰을 잃었을 때 `initramfs` 를 다시 만들지 않고
들어가는 길이다 — 자세한 것은 [`docs/recovery.md`](docs/recovery.md) §4.
그 파일은 암호화되지 않은 FAT 파티션에 있지만, 넣어서 얻는 것은 패스프레이즈를
묻는 화면뿐이므로 기밀성은 그대로다. 그 경로까지 막으려면
`viveboot.conf` 에서 `BYPASS_CMDLINE=no`.

## CI

위의 `sh tests/run.sh` 를 GitHub Actions 가 push 와 PR 마다 그대로 돌린다
([`.github/workflows/tests.yml`](.github/workflows/tests.yml)). 비밀값을 쓰지
않고 권한은 `contents: read` 뿐이다. Actions 탭에서 손으로 돌릴 수도 있다
(Run workflow).

CI 에서는 `VIVEBOOT_REQUIRE_SHELLCHECK=1` 로 두어 shellcheck 가 없으면 실패로
본다. 손으로 돌릴 때도 똑같이 하려면 `apt install shellcheck` 뒤에
`VIVEBOOT_REQUIRE_SHELLCHECK=1 sh tests/run.sh`. shellcheck 규칙은
[`.shellcheckrc`](.shellcheckrc) 에 있다.

CI 를 끄고 켜는 방법:

| 방법 | 범위 | 하는 법 |
| --- | --- | --- |
| 저장소 변수 | 저장소 전체, 되돌리기 쉬움 | Settings → Secrets and variables → Actions → Variables 에 `VIVEBOOT_CI` = `off`. 다시 켜려면 변수를 지우거나 `on` 으로 바꾼다 |
| 커밋 메시지 | 그 커밋 하나 | 커밋 메시지에 `[skip ci]` 를 넣는다 (GitHub 기본 기능) |
| 워크플로 비활성화 | 저장소 전체, 완전 정지 | Actions 탭 → tests → `...` → Disable workflow |

변수로 끈 경우 잡은 '실패' 가 아니라 'skipped' 로 남으므로 PR 체크는 초록으로
유지된다.

## 구성

| 경로 | 설치 위치 | 역할 |
| --- | --- | --- |
| `tools/vive-floppy-token` | `/usr/bin/` | 토큰 생성·검증·백업·카운터 관리 (Python 3) |
| `tools/vive-luks-enroll` | `/usr/bin/` | LUKS 키슬롯 등록/해제, `crypttab` 연결 |
| `tools/vive-boot-mode` | `/usr/bin/` | 제거 없이 켜고 끄기 (`on`/`off`/`status`/`bypass`) |
| `tools/viveboot-seqcheck` | `/usr/lib/viveboot/` | 부팅 후 복제/롤백 탐지 |
| `lib/viveboot-common.sh` | `/usr/lib/viveboot/` | 섹터 파싱·키 파생 공용 함수 (POSIX sh) |
| `initramfs/scripts/viveboot-keyscript` | `/usr/lib/viveboot/` | `crypttab` 의 `keyscript=` 본체 |
| `initramfs/hooks/viveboot` | `/usr/share/initramfs-tools/hooks/` | initramfs 에 넣을 것들 |
| `etc/viveboot.conf` | `/etc/viveboot/` | 설정 (고치면 `update-initramfs -u`) |

## 이 방식이 막는 것과 막지 못하는 것

**막는다**

- 기기를 훔쳐 간 사람: 디스켓이 없으면 디스크 내용을 읽을 수 없다.
- SD/NVMe 만 복사해 간 경우: 키 재료가 디스크에 없다.
- 디스켓만 훔쳐 간 경우(PIN 사용 시): PIN 없이는 PBKDF2 20만 회를 넘어야 한다.

**막지 못한다 — 반드시 알고 쓸 것**

- **원시 복제.** `dd` 로 디스켓 전체를 뜨면 동등한 토큰이 된다. 부팅 카운터로
  *사후 탐지*만 가능하다. 디스켓을 남의 손에 잠시라도 넘기지 말 것.
- **evil maid.** 부트 파티션(FAT)과 initramfs 는 서명되지 않는다. 기기에
  물리 접근한 사람이 키스크립트를 바꿔치기할 수 있다. 이걸 막으려면 Pi 5 의
  EEPROM 서명 부팅(2단계)이 필요하다 — `docs/design.md` 의 "2단계" 참고.
- **동작 중인 기기.** 부팅이 끝나면 루트는 열려 있다. 디스켓을 빼도
  시스템은 계속 돈다.
- **플로피의 물리적 신뢰성.** 자성 매체는 상한다. 백업 이미지는 필수다.

자세한 설계와 위협 모델은 [`docs/design.md`](docs/design.md),
설치 절차는 [`docs/install.md`](docs/install.md),
토큰을 잃었을 때의 복구는 [`docs/recovery.md`](docs/recovery.md).
