# 설치

위에서부터 순서대로 복사해 붙이면 된다. 단계마다 **"이게 보이면 성공"** 을
달아 뒀으니 거기서 막히면 그 단계만 들고 오면 된다.

라즈베리파이 5 + 라즈베리파이 OS (Bookworm / Trixie) 기준.

---

## 1. 패키지

```bash
sudo apt update
sudo apt install -y python3-pygame
```

한글 글귀("획득!" 화면) 를 쓸 거면 한글 폰트도:

```bash
sudo apt install -y fonts-nanum
```

> 성공: `python3 -c "import pygame; print(pygame.version.ver)"` 가 버전을 찍는다.

필요한 것만 추가로 깐다.

| 쓸 것 | 패키지 |
| --- | --- |
| ST7735 SPI LCD | `python3-spidev python3-gpiozero python3-lgpio` |
| 부팅 스플래시 (plymouth) | `plymouth plymouth-themes` |

LCD 를 쓰면 SPI 도 켠다 (켠 뒤 재부팅):

```bash
sudo raspi-config nonint do_spi 0
```

> 성공: 재부팅 후 `ls /dev/spidev*` 에 `/dev/spidev0.0` 이 보인다.

---

## 2. 받기

```bash
cd ~ && \
git clone https://github.com/yunsee-jicsee-dev/Raspberrypi5_Eeprom-VIVE.git && \
cd Raspberrypi5_Eeprom-VIVE && \
git checkout claude-and-jicsee/optimistic-euler-i8fyk9 && \
ls
```

`&&` 로 묶어 둔 건 중간에 실패하면 뒤가 엉뚱한 곳에서 돌지 않게 하기 위해서다.

> 성공: `ls` 결과에 `play.py`, `install.sh`, `boot`, `scripts` 가 보인다.

**`git checkout` 을 빠뜨리면 안 된다.** 기본 브랜치(`main`) 에는 README 한 줄뿐이라
`scripts/` 폴더 자체가 없다.

---

## 3. 설치하기 전에 확인

```bash
./scripts/check.sh
```

아래에서 위로 하나씩 짚어 준다.

1. 파이썬과 pygame
2. **인트로가 그려지는가** — 화면이 없어도 확인된다
3. 이 화면에 띄울 수 있는가
4. SPI LCD 가 붙어 있다면 거기에도

> 성공: 2번까지 `[ok]` 면 연출과 코드는 멀쩡하다. 이후 문제는 전부
> "어디에 띄우느냐" 로 좁혀진다.

3번을 제대로 보려면 **콘솔에서** 돌린다 (`Ctrl+Alt+F2` 로 전환 후 로그인).
데스크톱 안에서는 컴포지터가 화면을 쥐고 있어 결과가 다르게 나온다.

---

## 4. 무엇을 설치할지 고르기

| 하고 싶은 것 | 명령 |
| --- | --- |
| 로그인하면 화면에 인트로 | `sudo ./install.sh` |
| 거기에 "획득!" 화면까지 | `sudo ./install.sh --unlock` |
| 거기에 SPI LCD 까지 | `sudo ./install.sh --lcd --unlock` |
| 바탕화면이 비치는 것도 싫다 | 위에 더해 `sudo boot/install.sh` |
| 파이 4 라서 "4" 로 띄우고 싶다 | 위 명령에 `--model 4` 를 덧붙인다 |
| 부팅 스플래시에도 "획득!" 화면 | `sudo boot/install.sh --unlock` |

옵션은 같이 쓸 수 있다. 전부 되돌릴 수 있다.

```bash
sudo ./install.sh --lcd --unlock --model 4
```

`--model` 은 로고 옆 금색 글자다. `4`, `400`, `Zero` 처럼 아무 글자나 된다
(기본 `5`). 미리 보려면 `python3 intro.py --model 4`.

---

## 5. 설치

### 5-1. 로그인할 때 (기본)

```bash
sudo ./install.sh
```

`~/.config/autostart/` 에 항목 하나가 들어간다. **부팅 경로는 건드리지 않으므로
이것 때문에 부팅이 막힐 수 없다.**

> 성공: 로그아웃 후 다시 로그인하면 전체화면으로 재생된다. 재부팅 안 해도 된다.
> 지금 바로 보려면 (sudo 없이):
> `python3 /opt/rpi5-intro/play.py --display sdl --fullscreen`

### 5-2. SPI LCD 에도

배선부터 맞는지 **직접 돌려서** 확인한다.

```bash
sudo python3 play.py --display lcd
```

| LCD | 파이 | 바꾸려면 |
| --- | --- | --- |
| SCL/CLK | GPIO 11 | `--lcd-spi 0.0` |
| SDA/DIN | GPIO 10 | 〃 |
| CS | GPIO 8 (CE0) | 〃 |
| DC/RS | GPIO 25 | `--lcd-dc` |
| RST | GPIO 27 | `--lcd-rst` (없으면 `-1`) |
| BL | GPIO 24 | `--lcd-bl` (없으면 `-1`) |

화면이 나오지만 이상하면:

| 증상 | 옵션 |
| --- | --- |
| 몇 픽셀 밀려 있다 | `--lcd-offset 1,2` 또는 `2,1` |
| 빨강↔파랑이 뒤바뀐다 | `--lcd-rgb` |
| 흑백이 반전돼 있다 | `--lcd-invert` |
| 가로/세로가 틀렸다 | `--lcd-rotation 0\|180\|270` |
| 지직거리거나 깨진다 | `--lcd-speed 16000000` |

> 성공: LCD 에 라즈베리 로고가 보인다. **보고 나서** 설치한다:
> `sudo ./install.sh --lcd`

### 5-3. 부팅 스플래시 (plymouth)

바탕화면이 잠깐 비치는 것까지 없애고 싶을 때만.

```bash
sudo apt install -y plymouth plymouth-themes
sudo boot/install.sh
```

옵션:

```bash
sudo boot/install.sh --unlock       # 인트로 뒤에 "획득!" 화면도
sudo boot/install.sh --model 4      # 금색 글자를 4 로
sudo boot/install.sh --fps 5        # 프레임을 줄여 메모리 아끼기
```

plymouth 는 프레임을 전부 메모리에 올린다. `--unlock` 을 쓰면 길이가 두 배라
기본 프레임레이트를 10 으로 낮춰 잡는다.

스크립트가 알아서 한다: 테마 굽기 → 설치 → 이전 테마 기록 → `cmdline.txt` 에
`splash` 와 `plymouth.ignore-serial-consoles` 넣기(백업 남김) → initramfs 다시 굽기.

재부팅 없이 먼저 보려면 **콘솔에서**:

```bash
sudo boot/preview.sh
```

> 성공: `sudo reboot` 후 부팅 스플래시 자리에 인트로가 나온다.

---

## 6. 되돌리기

```bash
sudo ./install.sh --uninstall       # 로그인 재생 + LCD 서비스 + /opt 전부
sudo boot/install.sh --uninstall    # plymouth 테마를 이전 것으로
```

잠깐만 끄려면:

```bash
sudo systemctl disable --now rpi5-intro-lcd.service      # LCD 만
mv ~/.config/autostart/rpi5-intro.desktop{,.off}         # 로그인 재생만
```

---

## 7. 안 될 때

| 증상 | 할 것 |
| --- | --- |
| `명령이 없습니다` | `cd` 가 실패한 것이다. `pwd` 로 지금 어디인지 확인 |
| `scripts/` 가 없다 | 2단계의 `git checkout` 을 빠뜨렸다 |
| 로그인해도 안 나온다 | `ls ~/.config/autostart/` 에 항목이 있는지. 직접 실행해 보기 |
| 두 번 재생된다 | 옛 `rpi5-bootintro.desktop` 이 같이 남아 있다. 지운다 |
| LCD 가 깜깜하다 | 배선·핀 번호부터. `ls /dev/spidev*` 로 SPI 가 켜졌는지 |
| 부팅 스플래시가 안 뜬다 | `sudo boot/preview.sh` 출력을 본다. 원인과 해결책을 찍어 준다 |
| 글자가 네모(□) 로 나온다 | 한글 폰트가 없다. `sudo apt install -y fonts-nanum` |

더 자세한 진단은 `README.md` 의 "라즈베리파이에서 겪은 것들" 에 있다. 왜 그런
증상이 나는지까지 적어 뒀다.

---

## 8. 요약 (한 번에)

```bash
sudo apt update && sudo apt install -y python3-pygame fonts-nanum
cd ~ && git clone https://github.com/yunsee-jicsee-dev/Raspberrypi5_Eeprom-VIVE.git && \
  cd Raspberrypi5_Eeprom-VIVE && \
  git checkout claude-and-jicsee/optimistic-euler-i8fyk9
./scripts/check.sh
sudo ./install.sh --unlock
```

로그아웃 후 다시 로그인하면 끝.
