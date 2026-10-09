# Raspberrypi5_Eeprom-VIVE

라즈베리파이 5 로 돌리는 프로젝트. 전원을 넣으면 라즈베리 로고 인트로가 먼저
나오고, 그 다음 평소 화면으로 넘어간다.

## 파일

| 파일 | 하는 일 |
| --- | --- |
| `intro.py` | 인트로 연출 한 장면 (`Intro.draw(surf, t)`). 혼자 실행하면 창에서 미리보기 |
| `pixelfont.py` | 5x7 비트맵 폰트. ttf 없이 글자를 그린다 |
| `bootintro.py` | 인트로를 프레임버퍼(`/dev/fb0`) 에 재생하는 부팅용 재생기 |
| `systemd/rpi5-bootintro.service` | 부팅 때 인트로를 한 번 트는 서비스 |
| `scripts/install-bootintro.sh` | 위 두 개를 설치/제거 |

## 부팅할 때 인트로 띄우기

데스크톱도 X 도 없는 부팅 초기에 돌아야 해서, 창을 띄우는 대신
`/dev/fb0` 에 픽셀을 직접 써 넣는다. 그래서 HDMI 모니터만 꽂혀 있으면 된다.

```bash
sudo apt install -y python3-pygame
sudo scripts/install-bootintro.sh
sudo systemctl start rpi5-bootintro.service   # 재부팅 전에 바로 확인
```

서비스는 `multi-user.target` 에 붙고 `display-manager.service`, `getty@tty1.service`
보다 **먼저** 돌게 돼 있다. 인트로(3.7초) 가 끝나야 로그인 화면이나 콘솔이 뜬다.

부팅 로그 글자와 모서리 라즈베리 네 마리를 가리려면 `/boot/firmware/cmdline.txt`
(한 줄짜리 파일) 끝에 이어서 적는다:

```
quiet logo.nologo vt.global_cursor_default=0 consoleblank=0
```

라즈베리파이 OS 기본 스플래시(plymouth) 와 겹치면 `cmdline.txt` 에서 `splash` 를
지우거나 `sudo systemctl disable plymouth-quit-wait.service`.

제거는 `sudo scripts/install-bootintro.sh --uninstall`.

## 손으로 돌려 보기

```bash
python3 bootintro.py                       # /dev/fb0 에 한 번
python3 bootintro.py --loop                # 끝나면 다시 (전시용)
python3 bootintro.py --display sdl         # 개발 PC 에서 창으로
python3 bootintro.py --save-frames out/    # 프레임을 PNG 로 떨궈 확인
python3 intro.py --size 160x128            # 인트로만 LCD 크기로 미리보기
```

화면 정보를 못 읽는 프레임버퍼라면 직접 알려 준다:

```bash
python3 bootintro.py --fb-geometry 1920x1080@32 --fb-stride 7680
```

주요 옵션: `--fps`(기본 30), `--size`(인트로 원본, 기본 400x240),
`--max-scale`(확대 배율 상한), `--keep-cursor`, `--no-blank`.
16bpp(RGB565) 와 32bpp(XRGB8888) 프레임버퍼를 지원한다.

## 메모

- 인트로 전체 길이는 3.7초(`intro.LENGTH`). 타임라인 상수는 `intro.py` 위쪽에 있다.
- 인트로는 화면 가운데에 정수 배율로만 확대한다. 400x240 원본이 1920x1080 에서는
  4배(1600x960), 나머지는 검은 여백이 된다.
- `intro.py` 는 폰트를 `main.py` 에서 먼저 찾고(`intro.load_text()`), 없으면
  `pixelfont` 로 떨어진다. 그래서 메뉴 앱 없이도 부팅 인트로만 따로 돌아간다.
- `intro.CUES` 에 효과음 시점이 들어 있지만 재생기는 아직 소리를 내지 않는다.
