# Raspberrypi5_Eeprom-VIVE

라즈베리파이 5 로 돌리는 프로젝트. 전원을 넣으면 라즈베리 로고 인트로가 먼저
나오고, 그 다음 평소 화면으로 넘어간다.

## 파일

| 파일 | 하는 일 |
| --- | --- |
| `intro.py` | 인트로 연출 한 장면 (`Intro.draw(surf, t)`). 혼자 실행하면 창에서 미리보기 |
| `pixelfont.py` | 5x7 비트맵 폰트. ttf 없이 글자를 그린다 |
| `bootintro.py` | 인트로 재생기. 프레임버퍼(`/dev/fb0`) 또는 전체화면 창 |
| `systemd/rpi5-bootintro.service` | 기본. 데스크톱이 뜨기 전에 프레임버퍼로 재생 |
| `desktop/rpi5-bootintro.desktop` | 대안. 로그인 세션 안에서 전체화면 창으로 재생 |
| `scripts/try-intro.sh` | 설치하지 않고 화면에 나오는지만 확인 |
| `scripts/make-plymouth-theme.py` | 인트로를 PNG 프레임으로 구워 plymouth 테마 생성 |
| `scripts/install-plymouth-theme.sh` | 그 테마를 부팅 스플래시로 설치/복구 |
| `scripts/preview-plymouth.sh` | 재부팅 없이 지금 바로 테마를 띄워 보기 |
| `scripts/install-bootintro.sh` | 설치/제거 |
| `scripts/diagnose.sh` | 화면에 안 나올 때 원인 좁히기 |

## 부팅할 때 인트로 띄우기

먼저 **설치하지 말고** 화면에 나오는지부터 본다. 콘솔(`Ctrl+Alt+F2`)에서:

```bash
sudo apt install -y python3-pygame
sudo scripts/try-intro.sh
```

설치는 두 가지 방식이 있다.

### 기본 — 세션 방식 (부팅을 막을 수 없음)

```bash
sudo scripts/install-bootintro.sh
```

`~/.config/autostart/` 에 항목을 넣어 로그인 후 전체화면 창으로 재생한다.
**부팅 경로에 아무것도 넣지 않으므로 이것 때문에 부팅이 막힐 수 없다.**
대신 바탕화면이 그려진 뒤에 프로세스가 시작되므로 바탕화면이 잠깐 보인다.

### plymouth 테마 (부팅 스플래시 자리를 제대로 쓰는 방법)

```bash
sudo apt install -y plymouth plymouth-themes
sudo scripts/install-plymouth-theme.sh
sudo reboot
```

`ModuleName=script` 를 쓰므로 script 플러그인(`/usr/lib/*/plymouth/script.so`)
이 있어야 한다. 설치 스크립트가 미리 확인한다.

**시리얼 콘솔을 조심해야 한다.** 라즈베리파이는 `cmdline.txt` 에 기본으로
`console=ttyAMA0,115200`(또는 `console=serial0`) 이 들어 있다. 이게 있으면
plymouth 가

```
serial consoles detected, managing them with details forced
creating devices for (renderer type: 4294967295)
```

하면서 **그래픽 렌더러를 아예 만들지 않고** 텍스트 모드로 간다. 어떤 테마를
지정하든 화면에는 안 보이고 `load_built_in_theme` 으로 떨어진다. 커널
파라미터 하나로 풀린다:

```
plymouth.ignore-serial-consoles
```

설치 스크립트가 `console=ttyAMA*/ttyS*/serial*` 을 찾으면 `splash` 와 함께
자동으로 넣는다(백업을 남기고, 이미 있으면 건드리지 않는다).

부팅 스플래시 자리는 원래 plymouth 것이다. 거기에 systemd 서비스를 끼워 넣으려
하면 plymouth 와 화면(DRM) 을 두고 다투게 되고, 그래서 아무것도 안 보이거나
부팅이 막힌다. 싸우지 말고 **plymouth 가 우리 인트로를 재생하게** 하면 된다.

연출을 plymouth 스크립트로 다시 짜지는 않는다. `intro.py` 로 PNG 프레임을 구워
두고 테마 스크립트가 한 장씩 넘기므로 **그림은 픽셀 단위로 똑같다.**

```bash
python3 scripts/make-plymouth-theme.py --fps 25 --zoom 3   # 미리 구워 보기
```

기본값은 25fps x 2배(800x480) = 92장, 디스크 0.7MB. plymouth 가 전부 메모리에
올리므로 약 135MB 를 쓴다. `--fps` 와 `--zoom` 으로 줄일 수 있다.
plymouth 는 초당 50회 갱신하므로 `--fps` 는 50 의 약수(50/25/10/5)여야 한다.

설치할 때 이전 테마 이름을 적어 두고, `cmdline.txt` 에 `splash` 가 없으면
넣는다(백업을 남긴다). plymouth 는 `splash` 가 있어야 화면에 뜬다.

**initramfs**: 라즈베리파이 OS 는 `config.txt` 에 `auto_initramfs=1` 이 있어서
plymouth 가 initramfs 안에서 돈다. 테마만 바꾸고 initramfs 를 다시 굽지 않으면
옛 테마가 그대로 쓰인다 (`plymouth-set-default-theme` 은 새 테마를 가리키는데
화면은 그대로인 증상). 설치 스크립트가 감지해서 `update-initramfs -u` 를
돌린다.

**재부팅 없이 확인**: 콘솔(`Ctrl+Alt+F2`)에서

```bash
sudo scripts/preview-plymouth.sh        # 8초 동안 띄워 본다
sudo scripts/preview-plymouth.sh 15     # 15초
```

지금 바로 화면에 띄워 보고, 끝나면 테마 스크립트의 오류와 렌더러 상태를
찍어 준다. 무슨 일이 있어도 plymouth 를 화면에서 치우고 끝낸다(trap).

`cmdline.txt` 를 고쳐도 **돌고 있는 커널의 명령줄은 부팅 시점 것**이라 재부팅
전에는 반영되지 않는다. 그래서 미리보기는 `plymouthd --kernel-command-line` 으로
`splash` 와 `plymouth.ignore-serial-consoles` 가 들어간 상태를 흉내 낸다.
재부팅 뒤에 보일 모습을 재부팅 없이 확인할 수 있다.

되돌리기:

```bash
sudo scripts/install-plymouth-theme.sh --uninstall
```

**이 방식은 부팅을 붙잡지 않는다.** systemd 서비스가 아니라 plymouth 테마일
뿐이라, 테마에 문제가 있어도 스플래시가 안 뜰 뿐 부팅은 그대로 진행된다.

### 부팅 방식 (바탕화면이 안 비치는 대신 위험)

```bash
sudo scripts/install-bootintro.sh --boot
```

`multi-user.target` 과 `display-manager.service` 사이에 systemd 서비스를
끼워 넣는다. 바탕화면이 비칠 일이 없는 대신 **부팅 경로에 들어간다.**
문제가 생기면 부팅이 막히므로, 확인을 한 번 받고 설치한다.

막혔을 때는 `cmdline.txt` 한 줄 끝에 한 칸 띄고:

```
systemd.mask=rpi5-bootintro.service
```

**이건 그 부팅 한 번만 유효하다.** 부팅된 뒤 반드시 지워야 한다:

```bash
sudo scripts/install-bootintro.sh --uninstall
```

지우지 않고 mask 만 빼면 다음 부팅에서 또 막힌다.

서비스 쪽 안전장치: `--max-seconds 20` 으로 프로그램이 스스로 끊고,
`TimeoutStartSec=30` 으로 systemd 가 한 번 더 끊고, `--optional` 이라
화면을 못 열면 조용히 넘어간다.

### 왜 데스크톱 세션 안에서는 안 되나

XDG autostart(`~/.config/autostart/`) 는 바탕화면이 이미 그려진 **뒤에** 실행된다.
창을 아무리 빨리 띄워도 프로세스가 시작되는 시점 자체가 늦어서, 바탕화면이 잠깐
보이는 걸 없앨 수 없다. 게다가 그때는 컴포지터가 화면을 쥐고 있어서 `/dev/fb0`
로는 아무것도 안 보이므로 전체화면 창을 써야 한다.

그래도 이 방식이 필요하면 (기본 방식이 안 통하는 기기 등):

```bash
sudo scripts/install-bootintro.sh --session
```

제거:

```bash
sudo scripts/install-bootintro.sh --uninstall
```

### 안 나올 때

```bash
sudo scripts/diagnose.sh
```

기기/OS, 서비스 등록과 로그, 부팅 순서가 실제로 먹었는지, plymouth 상태,
`/dev/fb*` 와 `/dev/dri/*`, SDL 이 쓸 수 있는 비디오 드라이버를 한 번에 찍고,
마지막에 KMS 와 프레임버퍼로 각각 실제 재생을 시험한다.

서비스 로그만 보려면:

```bash
journalctl -u rpi5-bootintro.service -b
```

화면 정보를 읽었다면 `1920x1080 32bpp, 4배 확대` 같은 줄이 찍힌다. 그 줄이
나오는데도 화면에 아무것도 없다면 `plymouth` 스플래시가 화면(DRM) 을 쥐고 있을
수 있다. `cmdline.txt` 에서 `splash` 를 빼면 된다:

```bash
sudo scripts/install-bootintro.sh --no-plymouth
```

`cmdline.txt` 는 부팅에 치명적인 파일이라 `--no-plymouth` 를 직접 줬을 때만
건드리고, `cmdline.txt.bootintro.bak` 에 백업을 남긴다. 되돌리려면 그 백업을
덮어쓰면 된다.

부팅 로그 글자와 모서리 라즈베리까지 가리려면 `/boot/firmware/cmdline.txt`
(한 줄짜리 파일) 끝에 이어서 적는다:

```
quiet logo.nologo vt.global_cursor_default=0 consoleblank=0
```

### plymouth 에는 손대지 않는다

서비스에서 `plymouth quit` 을 부르면 안 된다. `plymouth-quit-wait.service` 는
`plymouth --wait` 로 plymouthd 가 끝나길 기다리는데, 그 대상을 밖에서 죽이면
기다리던 쪽이 실패한다. 스플래시가 방해되면 죽이지 말고 `splash` 를 빼야 한다.

## 손으로 돌려 보기

```bash
sudo python3 bootintro.py                      # 알아서 고름 (데스크톱이면 창, 아니면 fb0)
python3 bootintro.py --display sdl --fullscreen   # 전체화면
python3 bootintro.py --display sdl --windowed     # 작은 창
python3 bootintro.py --loop                    # 끝나면 다시 (전시용)
python3 bootintro.py --save-frames out/        # 프레임을 PNG 로 떨궈 확인
python3 intro.py --size 160x128                # 인트로만 LCD 크기로 미리보기
```

`--display auto`(기본) 는 `WAYLAND_DISPLAY`/`DISPLAY` 가 있으면 전체화면 창,
없으면 **KMS/DRM → 프레임버퍼** 순으로 시도한다. 라즈베리파이 5 는
`vc4-kms-v3d` 로 도는 KMS 환경이라 `/dev/fb0` 은 DRM 의 fbdev 흉내 장치다.
거기 쓴 게 화면에 안 나타나는 경우가 있어서, 컴포지터가 없는 동안엔 DRM 을
직접 잡는 쪽(`--display kms`) 이 더 확실하다. 실패한 경로는 이유와 함께
로그에 남는다.

화면 정보를 못 읽는 프레임버퍼라면 직접 알려 준다:

```bash
python3 bootintro.py --fb-geometry 1920x1080@32 --fb-stride 7680
```

주요 옵션: `--fps`(기본 30), `--size`(인트로 원본, 기본 400x240),
`--max-scale`(확대 배율 상한), `--delay`(재생 전 대기), `--wait-display`(세션이
뜰 때까지 창 열기 재시도), `--keep-cursor`, `--no-blank`.
16bpp(RGB565) 와 32bpp(XRGB8888) 프레임버퍼를 지원한다.

## 메모

- 인트로 전체 길이는 3.7초(`intro.LENGTH`). 타임라인 상수는 `intro.py` 위쪽에 있다.
- 인트로는 화면 가운데에 정수 배율로만 확대한다. 400x240 원본이 1920x1080 에서는
  4배(1600x960), 나머지는 검은 여백이 된다. 프레임버퍼와 전체화면 창 모두 같다.
- `intro.py` 는 폰트를 `main.py` 에서 먼저 찾고(`intro.load_text()`), 없으면
  `pixelfont` 로 떨어진다. 그래서 메뉴 앱 없이도 부팅 인트로만 따로 돌아간다.
- `intro.CUES` 에 효과음 시점이 들어 있지만 재생기는 아직 소리를 내지 않는다.
