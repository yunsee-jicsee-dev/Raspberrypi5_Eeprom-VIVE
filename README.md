# Raspberrypi5_Eeprom-VIVE — 플로피 섹터 보안 부팅 (viveboot)

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

## 구성

| 경로 | 설치 위치 | 역할 |
| --- | --- | --- |
| `tools/vive-floppy-token` | `/usr/bin/` | 토큰 생성·검증·백업·카운터 관리 (Python 3) |
| `tools/vive-luks-enroll` | `/usr/bin/` | LUKS 키슬롯 등록/해제, `crypttab` 연결 |
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
