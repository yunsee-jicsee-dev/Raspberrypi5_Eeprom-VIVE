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
| `scripts/install-bootintro.sh` | 설치/제거 |

## 부팅할 때 인트로 띄우기

```bash
sudo apt install -y python3-pygame
sudo scripts/install-bootintro.sh
sudo reboot
```

`rpi5-bootintro.service` 가 **`multi-user.target` 과 `display-manager.service`
사이**에 들어간다. 여기가 유일하게 맞는 자리다.

- 그 앞: 올라올 서비스는 이미 다 올라왔다 (부팅 과정을 붙잡지 않는다)
- 그 뒤: 컴포지터가 아직 시작되지 않아 `/dev/fb0` 이 우리 것이다

데스크톱(바탕화면) 은 인트로 3.7초가 끝난 뒤에 시작한다. 그래서 바탕화면이
먼저 비칠 일이 없다.

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
journalctl -u rpi5-bootintro.service -b
```

화면 정보를 읽었다면 `1920x1080 32bpp, 4배 확대` 같은 줄이 찍힌다. 그 줄이
나오는데도 화면에 아무것도 없다면 `plymouth` 스플래시가 화면을 쥐고 있을 수 있다.
`/boot/firmware/cmdline.txt` 에서 `splash` 를 지우고 아래를 이어서 적는다
(한 줄짜리 파일이다):

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
