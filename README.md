# Raspberrypi5_Eeprom-VIVE

라즈베리파이 5 로 돌리는 프로젝트. 전원을 넣거나 로그인하면 라즈베리 로고
인트로가 먼저 나온다.

설치만 필요하면 **[INSTALL.md](INSTALL.md)** 로 가면 된다. 순서대로 복사해
붙이면 되고, 단계마다 "이게 보이면 성공" 이 달려 있다.

## 먼저 확인부터

아무것도 설치하지 말고 이것부터 돌린다. 아래에서 위로 하나씩 짚어 준다.

```bash
sudo apt install -y python3-pygame
./scripts/check.sh
```

1. 파이썬과 pygame 이 있는가
2. **인트로가 그려지기는 하는가** — 화면이 없어도 확인된다
3. 이 화면에 띄울 수 있는가 — 데스크톱이면 창, 콘솔이면 KMS/프레임버퍼
4. ST7735 SPI LCD 가 붙어 있다면 거기에도

2번까지 되면 연출과 코드는 멀쩡한 것이고, 남은 문제는 전부 "어디에 띄우느냐"다.
설치는 그 다음이다.

## 두 가지 방식

### 로그인할 때 (기본, 안전)

```bash
sudo ./install.sh
```

`~/.config/autostart/` 에 항목을 넣어 로그인 후 전체화면 창으로 한 번 재생한다.
로그아웃 후 다시 로그인하면 바로 보인다 — 재부팅도 필요 없다.

**부팅 경로에는 아무것도 넣지 않는다.** 잘못돼도 인트로가 안 나올 뿐 부팅은
평소대로 진행된다. 대신 바탕화면이 그려진 뒤에 프로세스가 시작되므로 바탕화면이
0.5초쯤 비친다.

제거: `sudo ./install.sh --uninstall`

### 부팅 스플래시로 (plymouth)

```bash
sudo apt install -y plymouth plymouth-themes
sudo boot/install.sh
sudo reboot
```

바탕화면이 비치지 않는다. 부팅 스플래시 자리는 원래 plymouth 것이므로, 거기에
끼어들지 않고 **plymouth 가 우리 인트로를 재생하게** 한다.

연출을 plymouth 스크립트로 다시 짜지는 않는다. `intro.py` 로 PNG 프레임을 굽고
테마는 한 장씩 넘기므로 **그림은 픽셀 단위로 똑같다.**

재부팅 없이 확인:

```bash
sudo boot/preview.sh        # 콘솔(Ctrl+Alt+F2) 에서
```

제거: `sudo boot/install.sh --uninstall`

### "획득!" 화면

로그인하면 커널 로그처럼 생긴 화면이 올라오면서 뭘 얻었는지 알려 준다.

```
[    0.400000] systemd[1]: Reached target graphical.target
[    0.770000] login: jicsee logged in on wayland
[    1.140000] 권한 목록 확인 중 ...
────────────────────────────
★ 당신은 sudo 권한을 얻었다!
★ python을(를) 얻었다!
★ chromium을(를) 얻었다!
★ firefox을(를) 얻었다!
★ 설정 권한을 얻었다!
★ ... 등등을 얻었다!
```

```bash
python3 unlock.py                                  # 창에서 미리보기
python3 play.py --scene unlock --display sdl       # 재생기로
python3 play.py --scene intro unlock               # 인트로 뒤에 이어서
sudo ./install.sh --unlock                         # 로그인할 때 둘 다
```

얻는 것 목록은 바꿀 수 있다:

```bash
python3 play.py --scene unlock --items python vim docker "관리자 권한"
```

`을/를` 은 받침을 보고 고른다. 한글이 아니면 판단할 수 없으니 `을(를)` 로 적는다.

**진짜 커널 로그에도** 남기려면 (`dmesg` 에 보인다, root 필요):

```bash
sudo python3 play.py --scene unlock --kmsg
```

```
[  659.990311] rpi5-intro: YOU OBTAINED: sudo
[  659.991763] rpi5-intro: YOU OBTAINED: python
```

커널 기록은 ASCII 밖의 바이트를 `\xNN` 으로 바꿔 저장하므로 한글은 `dmesg` 에서
읽을 수 없다. 그래서 커널 로그에는 영문판을 쓴다.

**한글 폰트**: `pixelfont` 은 ASCII 전용이라 시스템에서 한글 폰트(나눔/Noto CJK
등) 를 찾아 쓴다. 쓸 만한 게 없으면 영문 글귀로 바꾼다 — 네모(□) 가 늘어서는
것보다 낫다. 폰트가 한글을 진짜로 그리는지는 **서로 다른 한글이 전부 같은
그림으로 나오는지** 보고 판단한다 (토푸는 다 같은 네모다).

좁은 화면(LCD 등) 에서는 시각 표시와 긴 커널 줄을 빼고 짧게 간다. 160픽셀에
`systemd[1]: Reached target graphical.target` 은 들어가지 않는다.

### ST7735 SPI LCD

HDMI 와 별개로, SPI LCD 에도 같은 인트로를 띄울 수 있다.

```bash
sudo apt install -y python3-spidev python3-gpiozero python3-lgpio
sudo raspi-config nonint do_spi 0       # SPI 켜기 (후 재부팅)
sudo python3 play.py --display lcd      # 배선 확인
sudo ./install.sh --lcd                 # 부팅할 때 LCD 에도
```

160x128 패널 기준으로 인트로를 그 크기에 맞춰 그린다(`intro.py` 가 원래 이
크기를 염두에 두고 쓰였다). 확대는 하지 않으므로 도트가 그대로 나온다.

**기본 배선** — 다르면 옵션으로 지정한다.

| LCD | 파이 | 옵션 |
| --- | --- | --- |
| SCL/CLK | GPIO 11 (SCLK) | `--lcd-spi 0.0` |
| SDA/DIN | GPIO 10 (MOSI) | 〃 |
| CS | GPIO 8 (CE0) | 〃 |
| DC/RS | GPIO 25 | `--lcd-dc` |
| RST | GPIO 27 | `--lcd-rst` (없으면 `-1`) |
| BL | GPIO 24 | `--lcd-bl` (없으면 `-1`) |

**화면이 이상하면** — 패널(탭 색깔) 마다 달라서 옵션으로 맞춘다.

| 증상 | 옵션 |
| --- | --- |
| 그림이 몇 픽셀 밀려 있다 | `--lcd-offset 1,2` 또는 `2,1` |
| 빨강↔파랑이 뒤바뀐다 | `--lcd-rgb` |
| 흑백이 반전돼 있다 | `--lcd-invert` |
| 가로/세로가 틀렸다 | `--lcd-rotation 0\|90\|180\|270` |
| 지직거리거나 깨진다 | `--lcd-speed 16000000` |

LCD 서비스(`--lcd`) 는 **`Before=` 가 하나도 없다.** 아무도 기다리지 않으므로
부팅을 붙잡을 수 없고, SPI LCD 는 DRM/plymouth 와 무관해서 화면을 두고 다툴
일도 없다. HDMI 쪽에서 `Before=display-manager.service` 를 썼다가 기기를 못
쓰게 만든 적이 있어서, 이쪽은 처음부터 그 구조를 피했다.

## 파일

| 파일 | 하는 일 |
| --- | --- |
| `intro.py` | 인트로 연출 (`Intro.draw(surf, t)`). 혼자 실행하면 창에서 미리보기 |
| `pixelfont.py` | 5x7 비트맵 폰트. ttf 없이 글자를 그린다 |
| `play.py` | 재생기. 장면을 화면에 튼다 (`--scene intro unlock` 처럼 이어 붙일 수 있다) |
| `unlock.py` | "획득!" 장면 + 커널 로그 쓰기 |
| `lcd.py` | ST7735/ST7735S SPI LCD 드라이버 (필요한 만큼만) |
| `install.sh` | 로그인할 때 재생되게 설치/제거 |
| `scripts/check.sh` | 설치 전 확인 사다리 |
| `boot/make-theme.py` | 인트로를 PNG 로 구워 plymouth 테마 생성 |
| `boot/install.sh` | 그 테마를 부팅 스플래시로 설치/복구 |
| `boot/preview.sh` | 재부팅 없이 테마를 띄워 보고 원인 진단 |
| `desktop/rpi5-intro.desktop` | 로그인 자동 실행 항목 |
| `systemd/rpi5-intro-lcd.service` | 부팅 때 LCD 에 재생 (Before= 없음 = 비차단) |

## 손으로 돌려 보기

```bash
python3 intro.py                            # 창에서 반복 재생
python3 unlock.py                           # "획득!" 화면 미리보기
python3 intro.py --size 160x128             # LCD 크기로
python3 play.py --display sdl --fullscreen  # 전체화면
sudo python3 play.py --display kms          # 콘솔에서 화면을 직접 잡아서
sudo python3 play.py --display lcd          # ST7735 SPI LCD 에
python3 play.py --save-frames out/          # PNG 로 떨구기
python3 boot/make-theme.py --fps 25 --zoom 3   # 테마만 구워 보기
```

`play.py` 주요 옵션: `--scene`(intro/unlock, 여러 개 가능), `--items`, `--user`,
`--kmsg`, `--fps`, `--size`(인트로 원본, 기본 400x240),
`--max-scale`, `--delay`, `--max-seconds`(안전장치), `--loop`.

## 라즈베리파이에서 겪은 것들

실기에서만 드러난 것들이다. 같은 데 다시 빠지지 않게 적어 둔다.

- **부팅 경로에 systemd 서비스를 끼워 넣지 말 것.** `multi-user.target` 과
  `display-manager.service` 사이가 빈자리처럼 보이지만 거기엔 plymouth 가
  설계상 앉아 있다. 화면(DRM) 을 두고 다투게 되고, 잘못되면 부팅이 멈춘다.
  이 방식은 폐기했다.
- **`plymouth quit` 을 부르지 말 것.** `plymouth-quit-wait.service` 는
  `plymouth --wait` 로 plymouthd 가 스스로 끝나길 기다린다. 밖에서 죽이면
  그쪽이 실패하고 부팅이 멈춘다.
- **시리얼 콘솔이 plymouth 를 텍스트 모드로 강제한다.** cmdline 에
  `console=ttyAMA0` 이 있으면 `serial consoles detected, managing them with
  details forced` 가 뜨고 그래픽 렌더러를 아예 만들지 않는다
  (`renderer type: 4294967295`). `plymouth.ignore-serial-consoles` 로 풀린다.
  라즈베리파이는 기본으로 해당된다. `boot/install.sh` 가 넣어 준다.
- **`auto_initramfs=1`** 이라 plymouth 가 initramfs 안에서 돈다. 테마만 바꾸고
  initramfs 를 다시 굽지 않으면 옛 테마가 쓰인다. `boot/install.sh` 가
  `update-initramfs -u` 를 돌린다.
- **`cmdline.txt` 를 고쳐도 재부팅 전에는 적용되지 않는다.** 돌고 있는 커널의
  명령줄은 부팅 시점 것이다. `boot/preview.sh` 는 `--kernel-command-line` 으로
  재부팅 뒤 상태를 흉내 낸다.
- **라즈베리파이 5 의 `/dev/dri/card0` 은 `v3d`** — 3D 전용이라 디스플레이
  출력이 없다. 여기에 DRM 렌더러를 붙이면 `Could not get card resources` 가
  난다. plymouth 는 udev 로 올바른 카드를 찾는데, `--tty` 를 넘기면 udev 를
  꺼 버려서 card0 을 쓴다.
- **Wayland 는 첫 `flip()` 전까지 서피스를 화면에 올리지 않는다.** 창만 만들고
  기다리면 그동안 뒤가 그대로 보인다.
- **XDG autostart 는 바탕화면이 그려진 뒤에 실행된다.** 세션 안에서는 바탕화면
  번쩍임을 없앨 수 없다.
- **`/dev/fb0` 은 KMS 환경에서 DRM 의 fbdev 흉내 장치**라 쓰기가 성공해도
  화면에 안 올라갈 수 있다. 그래서 `--display auto` 는 KMS 를 먼저 시도한다.
- **파이 5 에서 RPi.GPIO 는 동작하지 않는다.** `lcd.py` 는 gpiozero(백엔드
  lgpio) 를 쓰고, 없으면 lgpio 를 직접 쓴다.
- **`/dev/kmsg` 는 `write()` 한 번이 기록 한 줄이다.** 버퍼에 모았다가 한꺼번에
  쓰면 통째로 한 기록이 되어 `dmesg` 에서 이어 붙은 꼴이 되고, 둘째 줄부터의
  `<6>` 접두어가 글자 그대로 남는다. 줄마다 따로, 버퍼 없이 써야 한다.
- **커널 로그는 ASCII 밖의 바이트를 `\xNN` 으로 바꿔 저장한다.** 한글을 넣으면
  `dmesg` 에서 읽을 수 없다.
- **ST7735 는 RGB565 를 빅엔디안으로 받는다.** pygame 의 16비트 Surface 는
  호스트 순서(ARM = 리틀엔디안) 라서 바이트를 뒤집어야 한다. `array.byteswap()`
  이 C 로 돌아서 프레임마다 돌려도 부담이 없다.

### 부팅이 막혔을 때

이 저장소의 현재 방식들은 부팅 경로를 건드리지 않으므로 해당 없다. 혹시 옛
`rpi5-bootintro.service` 가 남아 있다면, `cmdline.txt` 한 줄 끝에 한 칸 띄고

```
systemd.mask=rpi5-bootintro.service
```

를 붙여 한 번 건너뛴 뒤(그 부팅에만 유효하다) `sudo ./install.sh` 를 돌리면
같이 지워 준다.

## 메모

- 인트로 전체 길이는 3.7초(`intro.LENGTH`). 타임라인 상수는 `intro.py` 위쪽에 있다.
- 화면 가운데에 정수 배율로만 확대한다. 400x240 원본이 1920x1080 에서는
  4배(1600x960), 나머지는 검은 여백이 된다.
- `intro.py` 는 폰트를 `main.py` 에서 먼저 찾고(`intro.load_text()`), 없으면
  `pixelfont` 로 떨어진다. 메뉴 앱 없이도 따로 돌아간다.
- `intro.CUES` 에 효과음 시점이 들어 있지만 재생기는 아직 소리를 내지 않는다.
