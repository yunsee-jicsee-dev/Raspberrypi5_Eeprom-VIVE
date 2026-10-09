# Raspberrypi5_Eeprom-VIVE

라즈베리파이 5 로 돌리는 프로젝트. 전원을 넣거나 로그인하면 라즈베리 로고
인트로가 먼저 나온다.

## 먼저 확인부터

아무것도 설치하지 말고 이것부터 돌린다. 아래에서 위로 하나씩 짚어 준다.

```bash
sudo apt install -y python3-pygame
./scripts/check.sh
```

1. 파이썬과 pygame 이 있는가
2. **인트로가 그려지기는 하는가** — 화면이 없어도 확인된다
3. 이 화면에 띄울 수 있는가 — 데스크톱이면 창, 콘솔이면 KMS/프레임버퍼

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

## 파일

| 파일 | 하는 일 |
| --- | --- |
| `intro.py` | 인트로 연출 (`Intro.draw(surf, t)`). 혼자 실행하면 창에서 미리보기 |
| `pixelfont.py` | 5x7 비트맵 폰트. ttf 없이 글자를 그린다 |
| `play.py` | 재생기. 화면에 인트로를 튼다. 하는 일은 그게 전부 |
| `install.sh` | 로그인할 때 재생되게 설치/제거 |
| `scripts/check.sh` | 설치 전 확인 사다리 |
| `boot/make-theme.py` | 인트로를 PNG 로 구워 plymouth 테마 생성 |
| `boot/install.sh` | 그 테마를 부팅 스플래시로 설치/복구 |
| `boot/preview.sh` | 재부팅 없이 테마를 띄워 보고 원인 진단 |
| `desktop/rpi5-intro.desktop` | 로그인 자동 실행 항목 |

## 손으로 돌려 보기

```bash
python3 intro.py                            # 창에서 반복 재생
python3 intro.py --size 160x128             # LCD 크기로
python3 play.py --display sdl --fullscreen  # 전체화면
sudo python3 play.py --display kms          # 콘솔에서 화면을 직접 잡아서
python3 play.py --save-frames out/          # PNG 로 떨구기
python3 boot/make-theme.py --fps 25 --zoom 3   # 테마만 구워 보기
```

`play.py` 주요 옵션: `--fps`, `--size`(인트로 원본, 기본 400x240),
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
