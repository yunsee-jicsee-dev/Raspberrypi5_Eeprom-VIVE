# Raspberrypi5_Eeprom-VIVE

라즈베리파이 5 로 돌리는 프로젝트. 전원을 넣으면 라즈베리 로고 인트로가 먼저
나오고, 그 다음 평소 화면으로 넘어간다.

## 파일

| 파일 | 하는 일 |
| --- | --- |
| `intro.py` | 인트로 연출 한 장면 (`Intro.draw(surf, t)`). 혼자 실행하면 창에서 미리보기 |
| `pixelfont.py` | 5x7 비트맵 폰트. ttf 없이 글자를 그린다 |
| `bootintro.py` | 인트로 재생기. 프레임버퍼(`/dev/fb0`) 또는 전체화면 창 |
| `systemd/rpi5-bootintro.service` | 콘솔/헤드리스용. 부팅이 끝난 뒤 한 번 재생 |
| `desktop/rpi5-bootintro.desktop` | 데스크톱용. 로그인 후 전체화면으로 한 번 재생 |
| `scripts/install-bootintro.sh` | 기기에 맞는 쪽을 골라 설치/제거 |

## 부팅할 때 인트로 띄우기

```bash
sudo apt install -y python3-pygame
sudo scripts/install-bootintro.sh
```

설치 스크립트가 `systemctl get-default` 를 보고 둘 중 하나를 고른다.

**데스크톱으로 부팅하는 기기** (`graphical.target`) — 로그인 세션이 시작되자마자
전체화면 창으로 재생한다. `~/.config/autostart/rpi5-bootintro.desktop` 이 들어간다.
데스크톱이 떠 있으면 컴포지터(Wayland) 가 화면을 쥐고 있어서 `/dev/fb0` 에 써 봐야
아무것도 안 보이기 때문에, 이쪽은 프레임버퍼를 쓰지 않는다.

바탕화면이 잠깐 비치지 않도록, 창을 연 직후 검은 화면을 한 번 그려서 먼저 덮는다
(Wayland 는 첫 `flip()` 전까지 서피스를 화면에 올리지 않는다). `--delay` 를 줘도
그동안 바탕화면이 아니라 검은 화면이 보인다.

**콘솔/헤드리스 기기** — `rpi5-bootintro.service` 가 `multi-user.target`,
`graphical.target`, `display-manager.service` 가 **다 올라온 뒤에** 돈다.
부팅 과정을 붙잡지 않으므로 부팅이 느려지지 않는다.

둘 중 하나만 깔린다. 다른 쪽으로 바꾸려면 `--desktop` / `--console` 을 직접 준다.

```bash
sudo scripts/install-bootintro.sh --desktop
sudo scripts/install-bootintro.sh --console
sudo scripts/install-bootintro.sh --uninstall
```

바로 확인:

```bash
python3 bootintro.py --display sdl --fullscreen          # 데스크톱에서 (sudo 없이)
sudo systemctl start rpi5-bootintro.service              # 콘솔에서 (Ctrl+Alt+F2)
```

콘솔 쪽에서 부팅 로그 글자와 모서리 라즈베리를 가리려면 `/boot/firmware/cmdline.txt`
(한 줄짜리 파일) 끝에 이어서 적는다:

```
quiet logo.nologo vt.global_cursor_default=0 consoleblank=0
```

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
없으면 `/dev/fb0` 을 쓴다.

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
