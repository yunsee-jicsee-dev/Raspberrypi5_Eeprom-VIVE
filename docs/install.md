# 설치 절차 (Raspberry Pi 5)

순서를 지키는 것이 중요하다. 특히 **4단계(백업)** 와 **7단계(재부팅 전 점검)**
를 건너뛰면 루트에 못 들어가는 상황이 생긴다.

## 0. 준비물과 전제

| 항목 | 설명 |
| --- | --- |
| USB 플로피 드라이브 | UFI 규격. 커널이 `usb-storage` 로 잡아 `/dev/sdX` 로 올린다 |
| 1.44MB 디스켓 | 내용은 전부 지워진다. 가능하면 새것 2장 (본용 + 예비) |
| 암호화된 루트 | 이미 LUKS 로 암호화되어 있고, 지금 패스프레이즈로 부팅된다 |
| 복구용 패스프레이즈 | 종이에 적어 기기와 다른 곳에 보관 |

루트가 아직 암호화되어 있지 않다면 이 작업 전에 LUKS 로 전환해야 한다. 그
작업은 데이터 이전이 필요하고 이 저장소의 범위가 아니다.

```sh
# 현재 상태 확인
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT
sudo cryptsetup status cryptroot      # 또는 crypttab 의 매핑 이름
cat /etc/crypttab
```

패키지:

```sh
sudo apt update
sudo apt install cryptsetup cryptsetup-initramfs initramfs-tools openssl
openssl version                        # 3.0 이상이어야 한다
```

Pi 5 는 기본적으로 initramfs 를 쓰지 않으므로 켜 둔다:

```sh
grep -n auto_initramfs /boot/firmware/config.txt \
  || echo 'auto_initramfs=1' | sudo tee -a /boot/firmware/config.txt
```

## 1. 설치

```sh
git clone <이 저장소> && cd Raspberrypi5_Eeprom-VIVE
sudo ./install.sh
```

`install.sh` 는 설치 후 환경을 점검해 경고를 출력한다. 경고가 나오면 먼저
해결한다.

## 2. 플로피 드라이브 확인

디스켓을 넣고:

```sh
dmesg | tail -20                 # sd 0:0:0:0: [sda] Attached SCSI removable disk
lsblk -o NAME,SIZE,RM,TYPE       # 1.4M, RM=1 인 장치를 찾는다
cat /sys/block/sda/size          # 2880 이어야 한다
```

**장치 이름을 반드시 확인한다.** `/dev/sda` 가 USB SSD 인 환경도 있다.
`format` 은 지정한 장치를 전부 덮어쓴다. 1.44MB 보다 큰 장치는 도구가
거부하지만(`--force` 가 있어야 통과), 눈으로 한 번 더 확인하는 쪽이 안전하다.

## 3. 토큰 만들기

PIN 없이 (플로피를 가진 것만으로 부팅):

```sh
sudo vive-floppy-token format /dev/sda --label PI5-ROOT
```

PIN 과 함께 (2요소. 권장):

```sh
sudo vive-floppy-token format /dev/sda --label PI5-ROOT --ask-pin
```

- PIN 은 영문·숫자 8자 이상을 권한다. 네 자리 숫자는 디스켓을 훔친 사람이
  30분 안에 뚫는다 (`docs/design.md` §3).
- 2880섹터 전체를 난수로 채우므로 USB FDD 에서 2~4분 걸린다.
- `--iter` 기본값은 200000 이다. Pi 5 에서 약 0.2초 걸린다.

확인:

```sh
sudo vive-floppy-token info /dev/sda
sudo vive-floppy-token verify /dev/sda
```

## 4. 백업 (건너뛰지 말 것)

```sh
sudo vive-floppy-token backup /dev/sda /root/token-backup.img
sudo chmod 600 /root/token-backup.img
```

이 이미지는 **토큰과 동등한 비밀값**이다. 암호화된 루트 안이나 오프라인
매체에 두고, 클라우드에 올리지 않는다. 예비 디스켓을 만들려면:

```sh
sudo vive-floppy-token restore /root/token-backup.img /dev/sda   # 새 디스켓으로 교체 후
```

복제본과 원본을 번갈아 쓰면 부팅 카운터가 어긋나 복제 경고가 뜬다. 예비는
금고에 넣어 두고, 본용이 상했을 때만 꺼내 쓰는 것을 전제로 한다.

## 5. 복구용 패스프레이즈 확인

토큰을 등록하기 **전에**, 지금 쓰는 패스프레이즈가 정말 통하는지 확인한다:

```sh
sudo cryptsetup luksDump /dev/nvme0n1p2 | grep -A2 'Keyslot\|Key Slot'
sudo cryptsetup luksOpen --test-passphrase /dev/nvme0n1p2 && echo "통과"
```

비어 있는 키슬롯이 하나 이상 있어야 한다 (LUKS2 는 보통 32개, LUKS1 은 8개).

## 6. LUKS 키슬롯 등록

```sh
sudo vive-luks-enroll --token /dev/sda --crypt-device /dev/nvme0n1p2
```

하는 일:

1. 토큰에서 암호문을 파생해 `/run` (tmpfs) 의 임시 파일에 넣는다.
2. `cryptsetup luksAddKey` 로 새 키슬롯에 등록한다 — 이때 **기존 패스프레이즈**
   를 물어본다.
3. `/etc/crypttab` 의 해당 항목을 `keyscript=` 방식으로 바꾼다
   (원본은 `/etc/crypttab.viveboot.bak` 에 백업).
4. `update-initramfs -u -k all` 을 실행한다.

PIN 을 쓰는 토큰이면 PIN 도 물어본다. 스크립트로 돌릴 때는 `--pin`.

## 7. 재부팅 전 점검

하나라도 어긋나면 재부팅하지 않는다.

아래 (1)~(6) 을 한 번에 보려면:

```sh
sudo vive-boot-mode status --verify
```

`--verify` 는 토큰이 실제로 LUKS 를 여는지까지 확인한다((6) 에 해당). 손으로
하나씩 확인하려면 다음을 그대로 따라간다.

```sh
# (1) crypttab 이 keyscript 를 가리키는지
grep viveboot /etc/crypttab

# (2) initramfs 안에 필요한 것이 다 들어갔는지
sudo lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'viveboot|bin/openssl'
#   → usr/lib/viveboot/viveboot-keyscript
#     usr/lib/viveboot/viveboot-common.sh
#     etc/viveboot/viveboot.conf
#     usr/bin/openssl

# (3) USB 저장장치 모듈이 들어갔는지
sudo lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'usb_storage|uas|sd_mod'

# (4) auto_initramfs 와 initramfs 줄
grep -E 'auto_initramfs|initramfs' /boot/firmware/config.txt

# (5) 키스크립트가 실제로 토큰에서 키를 뽑는지 (실행 중 시스템에서)
sudo /usr/lib/viveboot/viveboot-keyscript none | wc -c      # → 64

# (6) 그 값이 LUKS 를 여는지
sudo /usr/lib/viveboot/viveboot-keyscript none \
  | sudo cryptsetup luksOpen --test-passphrase --key-file=- /dev/nvme0n1p2 \
  && echo "토큰으로 열린다"

# (7) 복구용 패스프레이즈도 여전히 통하는지
sudo cryptsetup luksOpen --test-passphrase /dev/nvme0n1p2 && echo "복구 경로 정상"
```

(5)(6) 을 실행하면 부팅 카운터가 올라가고 `/run/viveboot` 에 기록이 남는다.
정상이다. 다음 부팅에서 `viveboot-seqcheck` 가 상태 파일을 맞춘다.

## 8. 재부팅

디스켓을 **넣은 상태로** 재부팅한다.

```sh
sudo reboot
```

콘솔에 이런 줄이 보여야 한다:

```
viveboot-keyscript: 토큰 장치: /dev/sda
```

부팅 후:

```sh
journalctl -u viveboot-seqcheck -b
#   viveboot-seqcheck: 상태 파일이 없어 새로 만듭니다 (/var/lib/viveboot/state)
sudo vive-floppy-token seq show /dev/sda
cat /var/lib/viveboot/state
```

## 9. 디스켓을 빼고 확인

토큰이 실제로 요구되는지 확인한다. 디스켓을 뺀 채 재부팅하면:

```
viveboot-keyscript: 부팅 토큰 플로피를 USB 드라이브에 넣어 주세요 (최대 60초 대기)
...
viveboot-keyscript: 오류: 제한 시간 60초 안에 부팅 토큰을 찾지 못했습니다
cryptsetup: cryptroot: 해제 실패
(initramfs)
```

여기서 디스켓을 넣고 `exit` 를 입력하면 `cryptsetup` 이 다시 시도한다
(`tries=3`). 또는 복구용 패스프레이즈로 직접 열 수 있다:

```sh
(initramfs) cryptsetup open /dev/nvme0n1p2 cryptroot
(initramfs) exit
```

이 확인까지 해 보면 설치가 끝난 것이다.

## 10. 켜고 끄기 (제거하지 않고)

설치해 둔 채로 토큰 요구만 켜고 끈다. 끈다고 토큰 키슬롯이 지워지는 것은
아니다 — 다시 켜면 같은 디스켓으로 돌아온다.

```sh
sudo vive-boot-mode status      # 현재 모드와 근거
sudo vive-boot-mode off         # 패스프레이즈로 부팅하게
sudo vive-boot-mode on          # 다시 토큰 필수로
```

둘 다 `/etc/crypttab` 의 `keyscript=` 를 고치고 `update-initramfs -u -k all`
까지 돌린다. 끝나면 모드가 실제로 바뀌었는지 다시 읽어 확인하고, 어긋나면
`crypttab` 을 되돌린다. 백업은 `/etc/crypttab.vive-boot-mode.bak`.

### 사전 검증 — 이것 때문에 이 도구를 쓴다

`crypttab` 을 손으로 고치는 것과의 차이는 켜기 전에 확인한다는 점이다.
아래는 성공했을 때 나오는 줄들이다 (장치 이름과 슬롯 번호는 환경마다 다르다):

```
$ sudo vive-boot-mode on
vive-boot-mode: 토큰: /dev/sda
vive-boot-mode: 토큰에서 암호문을 파생합니다 (부팅 때와 같은 키스크립트, 카운터는 올리지 않음)
vive-boot-mode: 그 암호문이 /dev/nvme0n1p2 를 여는지 확인합니다
vive-boot-mode: 토큰이 키슬롯 1 을 엽니다
vive-boot-mode: 키슬롯 2 개 (0 1 ) - 복구 경로가 남아 있습니다
vive-boot-mode: 백업: /etc/crypttab.vive-boot-mode.bak
vive-boot-mode: /etc/crypttab: 'cryptroot' -> on
```

- `on` — 토큰에서 파생한 암호문이 정말 이 LUKS 를 여는지 확인한다. 확인은
  **부팅 때 실제로 도는 그 키스크립트**를 그대로 돌려서 한다(파이썬 쪽
  `derive` 가 아니다). openssl/PBKDF2 경로까지 같이 검증된다. 이때 토큰의
  부팅 카운터는 올리지 않는다 — 올리면 다음 부팅에 복제 경고가 나고
  `SEQ_POLICY=poweroff` 면 전원이 꺼진다.
  토큰 외 키슬롯이 하나도 없으면 켜지 않는다. 토큰을 잃으면 데이터도 잃는
  구성이기 때문이다.
- `off` — 패스프레이즈를 입력받아 그것이 **토큰 슬롯이 아닌** 다른 슬롯을
  여는지 확인한다. 토큰에서 뽑은 64자 암호문을 그대로 붙여 넣으면 같은 슬롯이
  열리므로 걸러낸다. 복구 경로가 없는데 끄는 것을 막는 장치다.

검증을 건너뛰려면 `--force`. 그 경우 다음 부팅에 못 들어갈 수 있다.

### 다음 부팅 한 번만 우회

```sh
sudo vive-boot-mode bypass on    # /boot/firmware/cmdline.txt 에 viveboot=off
sudo reboot
# 들어간 뒤
sudo vive-boot-mode bypass off   # 반드시 되돌린다
```

`initramfs` 를 다시 만들지 않으므로 빠르고, 디스켓이 상했거나 드라이브가
고장 났을 때의 1순위 복구 경로다 (`docs/recovery.md` §4).

## 설정 바꾸기

`/etc/viveboot/viveboot.conf` 를 고친 뒤 **반드시**:

```sh
sudo update-initramfs -u -k all
```

자주 바꾸는 값:

| 값 | 용도 |
| --- | --- |
| `TOKEN_WAIT=120` | 느린 USB FDD. 또는 사람이 디스켓을 찾아 넣을 시간 |
| `TOKEN_DEVICE="/dev/sda"` | 자동 탐색을 끄고 장치를 못박는다 (탐색이 더 안전하다) |
| `SEQ_UPDATE=no` | 디스켓 쓰기를 멈춘다. 복제 탐지를 포기한다 |
| `SEQ_POLICY=poweroff` | 카운터 불일치 시 즉시 전원 차단 |

## 문제 해결

| 증상 | 원인과 조치 |
| --- | --- |
| `openssl kdf PBKDF2 실패` | initramfs 에 openssl 이 없거나 3.0 미만. `lsinitramfs ... \| grep openssl`, `apt install openssl`, `update-initramfs -u` |
| `제한 시간 안에 토큰을 찾지 못했습니다` | USB 모듈 누락(점검 (3)) 또는 FDD 인식 지연. `TOKEN_WAIT` 를 늘린다 |
| `섹터 N 쓰기 중 입출력 오류(EIO)` | ①디스켓 쓰기 금지 탭이 열려 있다 ②디스켓이 상했다 ③드라이브 고장. `cat /sys/block/sdX/ro` 가 1 이면 ①, `sudo dmesg \| tail -30` 의 `Write Protect is on` / `Medium Error` 로 구분된다 |
| `매체가 읽기 전용입니다` | 쓰기 금지 탭을 닫는다 (구멍이 막혀 있어야 쓸 수 있다) |
| `되읽은 키 조각이 쓴 것과 다릅니다` | 쓰기는 됐지만 매체가 값을 유지하지 못한다. 그 디스켓은 버린다 — 썼다면 부팅이 안 됐을 것이다 |
| `shard N (LBA x): MAC 불일치` | 디스켓 손상. 백업 이미지로 새 디스켓을 만든다 (`docs/recovery.md`) |
| `VIVE 토큰이 아닙니다` | 다른 디스켓이거나 다른 OS 가 포맷했다 |
| 카운터 기록 실패 경고 | 쓰기 금지 탭 또는 불량 섹터. 부팅은 된다 |
| `다른 토큰으로 부팅되었습니다` | 예비 디스켓을 썼다면 정상. 아니라면 복제를 의심한다 |
| 부팅은 되는데 토큰을 빼도 된다 | crypttab 이 키파일/패스프레이즈 방식으로 남아 있다. 점검 (1) |
