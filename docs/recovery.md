# 복구와 운영

## 0. 먼저 알아야 할 것

토큰은 LUKS 키슬롯 **하나**일 뿐이다. 복구용 패스프레이즈가 들어 있는
키슬롯은 그대로 남아 있다. 즉 **토큰을 잃어도 데이터를 잃는 것은 아니다** —
복구용 패스프레이즈를 보관해 두었다면.

```sh
sudo cryptsetup luksDump /dev/nvme0n1p2 | grep -E '^Keyslot|^  [0-9]+:'
```

## 1. 디스켓이 상했다 (읽기 오류, MAC 불일치)

```
viveboot-keyscript: 오류: shard 3 (LBA 1843): MAC 불일치
```

### 백업 이미지가 있는 경우

1. 복구용 패스프레이즈로 부팅한다 (§4).
2. 새 디스켓을 넣고 복원한다.

```sh
sudo vive-floppy-token restore /root/token-backup.img /dev/sda
sudo vive-floppy-token verify /dev/sda
# 부팅 카운터를 현재 기록에 맞춘다 (복제 경고 방지)
sudo vive-floppy-token seq sync /dev/sda --state /var/lib/viveboot/state
```

`seq sync` 는 상태 파일을 토큰의 현재 값으로 맞춘다. 복원 직후 토큰의
카운터는 백업 시점 값이므로 그대로 두면 "되돌아갔다" 경고가 뜬다.

### 백업 이미지가 없는 경우

토큰은 재현할 수 없다. 복구용 패스프레이즈로 부팅한 뒤 새 토큰을 만들고
새로 등록한다.

```sh
# 1) 새 토큰
sudo vive-floppy-token format /dev/sda --label PI5-ROOT --ask-pin
sudo vive-floppy-token backup /dev/sda /root/token-backup.img

# 2) 옛 토큰의 키슬롯 제거 — 옛 디스켓이 읽히는 경우에만 가능
sudo vive-luks-enroll --remove --token /dev/sdOLD --crypt-device /dev/nvme0n1p2
#    읽히지 않으면 키슬롯 번호로 직접 지운다 (번호를 확실히 알 때만!)
sudo cryptsetup luksDump /dev/nvme0n1p2        # 어느 슬롯이 토큰인지 확인
sudo cryptsetup luksKillSlot /dev/nvme0n1p2 <번호>

# 3) 새 토큰 등록
sudo vive-luks-enroll --token /dev/sda --crypt-device /dev/nvme0n1p2

# 4) 상태 파일 초기화 (토큰 UUID 가 바뀌었다)
sudo rm -f /var/lib/viveboot/state
```

## 2. USB 플로피 드라이브가 고장 났다

토큰 자체는 멀쩡하다. 드라이브만 바꾸면 된다. 당장 부팅해야 한다면
복구용 패스프레이즈로 들어간다 (§4).

백업 이미지를 쓰면 드라이브 없이도 임시로 키를 뽑을 수 있다:

```sh
sudo vive-floppy-token derive --no-newline /root/token-backup.img \
  | sudo cryptsetup luksOpen --key-file=- /dev/nvme0n1p2 cryptroot
```

이미지 파일도 토큰과 동등하게 동작한다. 그래서 이미지를 그렇게 조심해서
보관해야 한다.

## 3. PIN 을 잊었다

PIN 은 어디에도 저장되지 않는다. 검증자도 두지 않았다 (`docs/design.md` §8).
복구할 방법이 없으므로 복구용 패스프레이즈로 들어간 뒤 새 토큰을 만든다
(§1 의 "백업 이미지가 없는 경우" 와 같은 절차).

## 4. 복구용 패스프레이즈로 부팅하기

세 가지 길이 있다. 아직 부팅된 상태라면 (a), 이미 못 들어가는 상태라면 (c).

### (a) 지금 부팅되어 있다 — 다음 부팅 한 번만 우회

```sh
sudo vive-boot-mode bypass on
sudo reboot
# 들어간 뒤 반드시 되돌린다
sudo vive-boot-mode bypass off
```

`/boot/firmware/cmdline.txt` 에 `viveboot=off` 를 넣는다. 키스크립트는 그
단어를 보면 토큰을 아예 읽지 않고 `cryptsetup` 의 기본 대화형 경로처럼
패스프레이즈를 묻는다. `initramfs` 를 다시 만들지 않으니 가장 빠르다.
토큰의 부팅 카운터도 올라가지 않는다.

### (b) 당분간 토큰을 쓰지 않겠다

```sh
sudo vive-boot-mode off
```

패스프레이즈 키슬롯이 있는지 확인한 뒤 `crypttab` 에서 `keyscript=` 를 빼고
`initramfs` 를 다시 만든다. 토큰 키슬롯은 남으므로 나중에
`sudo vive-boot-mode on` 으로 돌아온다 (`docs/install.md` §10).

### (c) 이미 부팅이 막혔다 — initramfs 쉘

디스켓 없이 부팅하면 `TOKEN_WAIT` 초(기본 60) 뒤 initramfs 쉘로 떨어진다.

```sh
(initramfs) cryptsetup open /dev/nvme0n1p2 cryptroot
Enter passphrase for /dev/nvme0n1p2: ********
(initramfs) exit
```

`exit` 하면 부팅이 계속된다. 매핑 이름(`cryptroot`)은 `/etc/crypttab` 의
첫 칸과 같아야 한다.

장치 이름을 모를 때:

```sh
(initramfs) blkid | grep crypto_LUKS
(initramfs) ls /dev/nvme* /dev/mmcblk*
```

들어간 뒤에는 (a) 나 (b) 로 정리한다. 매번 initramfs 쉘을 거치지 않으려면
`bypass on` 을 걸어 두고 원인을 해결하는 쪽이 낫다.

다른 기계에서 SD/NVMe 를 꺼내 고칠 수 있다면, `cmdline.txt` 는 암호화되지
않은 FAT 파티션에 있으므로 거기에 ` viveboot=off` 를 직접 덧붙여도 (a) 와
같은 효과가 난다. 단 `viveboot.conf` 에 `BYPASS_CMDLINE=no` 로 두었다면
이 길은 막혀 있다 (그때는 (c) 뿐이다).

## 5. viveboot 를 완전히 되돌리기

```sh
# 1) 토큰 키슬롯 제거
sudo vive-luks-enroll --remove --token /dev/sda --crypt-device /dev/nvme0n1p2

# 2) crypttab 을 원래대로 (백업이 있다)
sudo cp /etc/crypttab.viveboot.bak /etc/crypttab
grep viveboot /etc/crypttab        # 아무것도 안 나와야 한다

# 3) initramfs 재생성
sudo update-initramfs -u -k all

# 4) 제거
sudo ./uninstall.sh
```

`uninstall.sh` 는 `/etc/crypttab` 에 `viveboot-keyscript` 가 남아 있으면
거부한다. 그 상태로 지우면 다음 부팅에서 루트를 열 수 없기 때문이다.

순서를 반드시 지킬 것: **crypttab 을 먼저, initramfs 다음, 제거는 마지막.**

## 6. 복제 경고가 떴다

```
viveboot-seqcheck: 경고: 토큰 카운터가 되돌아갔습니다 (토큰 5 < 기록 9).
                   복제본이 쓰였을 수 있습니다
```

읽는 법:

| 상황 | 가능한 원인 |
| --- | --- |
| 토큰 seq < 기록 seq | 예비 디스켓을 썼다 / 백업을 복원했다 / **복제본이 쓰였다** |
| 토큰 seq > 기록 seq | 이 토큰으로 다른 기기를 부팅했다 / 상태 파일이 지워졌다 |
| UUID 불일치 | 다른 토큰으로 부팅했다 |

정당한 사유(예비 디스켓 사용, 복원)라면 맞춰 준다:

```sh
sudo vive-floppy-token seq sync /dev/sda --state /var/lib/viveboot/state
```

짚이는 사유가 없다면 토큰이 복제되었다고 보고 **토큰을 교체**한다. 복제본은
원본과 구별할 수 없으므로, 새 토큰을 만들어 등록하고 옛 키슬롯을 지우는 것만이
확실한 조치다 (§1 의 "백업 이미지가 없는 경우" 절차).

## 7. 정기 점검

```sh
# 월 1회: 토큰 무결성 (디스켓 열화는 서서히 온다)
sudo vive-floppy-token verify /dev/sda --state /var/lib/viveboot/state

# 반년에 1회: 복구 경로가 살아 있는지
sudo cryptsetup luksOpen --test-passphrase /dev/nvme0n1p2

# 커널 업데이트 후: initramfs 에 키스크립트가 들어갔는지
sudo lsinitramfs /boot/initrd.img-$(uname -r) | grep -c viveboot   # → 3
```

커널이 올라가면 initramfs 가 다시 만들어진다. 훅이 설치되어 있으므로 보통
자동으로 들어가지만, `apt` 가 `initramfs-tools` 를 건드린 뒤에는 확인하는
편이 좋다. 이 확인이 0 을 내면 다음 부팅에서 루트가 열리지 않는다.

## 8. 여러 대의 Pi 를 한 토큰으로

같은 토큰을 여러 기기에 등록할 수 있다 (각 기기에서 `vive-luks-enroll`).
단 부팅 카운터는 기기마다 따로 기록되므로, 기기를 번갈아 부팅하면 매번
`토큰 seq > 기록 seq` 경고가 뜬다. 그 경우 각 기기에서
`SEQ_POLICY=off` 로 두거나 기기별 토큰을 따로 만드는 쪽이 낫다.
