"""ST7735 / ST7735S SPI LCD 드라이버 — 화면 한 장을 밀어 넣는 데 필요한 만큼만.

라즈베리파이 5 기준으로 썼다. RPi.GPIO 는 파이 5 에서 동작하지 않으므로 GPIO 는
gpiozero(백엔드 lgpio) 를 쓰고, 없으면 lgpio 를 직접 쓴다.

    sudo apt install -y python3-spidev python3-gpiozero python3-lgpio
    sudo raspi-config nonint do_spi 0      # SPI 켜기 (또는 config.txt 에 dtparam=spi=on)

배선 (기본값, 바꾸려면 옵션으로)
    LCD        파이
    VCC    →   3.3V
    GND    →   GND
    SCL/CLK→   GPIO 11 (SCLK)
    SDA/DIN→   GPIO 10 (MOSI)
    CS     →   GPIO 8  (CE0)
    DC/RS  →   GPIO 25
    RST    →   GPIO 27
    BL     →   GPIO 24   (없으면 --lcd-bl -1)

패널마다 다른 것 — 화면이 밀리거나 색이 뒤집히면 이것들을 건드린다.
    --lcd-rotation   화면 방향 (기본 90: 160x128 가로)
    --lcd-offset     RAM 시작 위치. 그림이 몇 픽셀 밀려 보이면 1,2 또는 2,1 로
    --lcd-rgb        색이 빨강↔파랑 뒤바뀌면 (기본은 BGR)
    --lcd-invert     흑백이 반전돼 보이면
"""
import time

# ST7735 명령
SWRESET, SLPOUT = 0x01, 0x11
INVOFF, INVON, DISPON = 0x20, 0x21, 0x29
CASET, RASET, RAMWR = 0x2A, 0x2B, 0x2C
MADCTL, COLMOD = 0x36, 0x3A
FRMCTR1, FRMCTR2, FRMCTR3, INVCTR = 0xB1, 0xB2, 0xB3, 0xB4
PWCTR1, PWCTR2, PWCTR3, PWCTR4, PWCTR5, VMCTR1 = 0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5
GMCTRP1, GMCTRN1, NORON = 0xE0, 0xE1, 0x13

# MADCTL 비트
MY, MX, MV, BGR = 0x80, 0x40, 0x20, 0x08

# 방향 → MADCTL (BGR 비트는 따로 더한다)
ROTATION = {0: 0, 90: MV | MX, 180: MY | MX, 270: MV | MY}

# 켜자마자 한 번 보내는 설정. ST7735R/S 표준값.
INIT = [
    (FRMCTR1, b"\x01\x2c\x2d", 0),      # 프레임레이트 (보통 모드)
    (FRMCTR2, b"\x01\x2c\x2d", 0),      # 프레임레이트 (아이들)
    (FRMCTR3, b"\x01\x2c\x2d\x01\x2c\x2d", 0),
    (INVCTR, b"\x07", 0),               # 도트 반전 방식
    (PWCTR1, b"\xa2\x02\x84", 0),
    (PWCTR2, b"\xc5", 0),
    (PWCTR3, b"\x0a\x00", 0),
    (PWCTR4, b"\x8a\x2a", 0),
    (PWCTR5, b"\x8a\xee", 0),
    (VMCTR1, b"\x0e", 0),
    (GMCTRP1, bytes([0x02, 0x1c, 0x07, 0x12, 0x37, 0x32, 0x29, 0x2d,
                     0x29, 0x25, 0x2b, 0x39, 0x00, 0x01, 0x03, 0x10]), 0),
    (GMCTRN1, bytes([0x03, 0x1d, 0x07, 0x06, 0x2e, 0x2c, 0x29, 0x2d,
                     0x2e, 0x2e, 0x37, 0x3f, 0x00, 0x00, 0x02, 0x10]), 0),
]


class LcdError(RuntimeError):
    pass


class Pin:
    """출력 핀 하나. gpiozero 를 먼저 쓰고, 없으면 lgpio 를 직접 쓴다."""

    _chip = None   # lgpio 를 쓸 때의 핸들 (모든 핀이 공유)

    def __init__(self, number):
        self.number = number
        self._dev = None
        self._lg = None
        try:
            from gpiozero import DigitalOutputDevice
            self._dev = DigitalOutputDevice(number)
            return
        except Exception:
            pass
        try:
            import lgpio
            self._lg = lgpio
            if Pin._chip is None:
                # 파이 5 는 보통 gpiochip0(RP1). 커널에 따라 4 인 경우도 있다.
                last = None
                for chip in (0, 4):
                    try:
                        Pin._chip = lgpio.gpiochip_open(chip)
                        break
                    except Exception as e:
                        last = e
                else:
                    raise LcdError(f"GPIO 칩을 열지 못했어요: {last}")
            lgpio.gpio_claim_output(Pin._chip, number, 0)
        except LcdError:
            raise
        except Exception as e:
            raise LcdError(
                f"GPIO {number} 번을 잡지 못했어요: {e}\n"
                "  sudo apt install -y python3-gpiozero python3-lgpio") from e

    def set(self, value):
        v = 1 if value else 0
        if self._dev is not None:
            self._dev.value = v
        else:
            self._lg.gpio_write(Pin._chip, self.number, v)

    def close(self):
        if self._dev is not None:
            try:
                self._dev.close()
            except Exception:
                pass


def open_spi(bus, device, speed_hz):
    try:
        import spidev
    except ImportError as e:
        raise LcdError("spidev 가 없어요:  sudo apt install -y python3-spidev") from e
    spi = spidev.SpiDev()
    try:
        spi.open(bus, device)
    except OSError as e:
        raise LcdError(
            f"/dev/spidev{bus}.{device} 를 열지 못했어요: {e}\n"
            "  SPI 가 꺼져 있을 수 있어요:  sudo raspi-config nonint do_spi 0") from e
    spi.max_speed_hz = speed_hz
    spi.mode = 0
    return spi


class ST7735:
    """화면 한 장(RGB565 빅엔디안) 을 받아 그대로 밀어 넣는다."""

    def __init__(self, spi, dc, rst=None, bl=None, width=160, height=128,
                 rotation=90, offset=None, bgr=True, invert=False):
        if rotation not in ROTATION:
            raise LcdError(f"--lcd-rotation 은 {sorted(ROTATION)} 중 하나여야 해요")
        self.spi = spi
        self.dc, self.rst, self.bl = dc, rst, bl
        self.width, self.height = width, height
        self.rotation, self.bgr, self.invert = rotation, bgr, invert
        # RAM 시작 위치. 패널(탭 색깔) 마다 달라서 옵션으로 뺀다.
        self.ox, self.oy = offset if offset else (0, 0)

    # ---- 저수준 ----
    def _cmd(self, code, data=b"", wait=0):
        self.dc.set(0)
        self._write(bytes([code]))
        if data:
            self.dc.set(1)
            self._write(data)
        if wait:
            time.sleep(wait)

    def _write(self, buf):
        # spidev 는 한 번에 보낼 수 있는 양이 제한돼 있다. writebytes2 가 알아서
        # 쪼개 주지만, 없는 판본을 위해 손으로 쪼개는 길도 남겨 둔다.
        w2 = getattr(self.spi, "writebytes2", None)
        if w2 is not None:
            w2(buf)
            return
        step = 4096
        for i in range(0, len(buf), step):
            self.spi.writebytes(list(buf[i:i + step]))

    # ---- 초기화 ----
    def reset(self):
        if self.rst is None:
            return
        for value, pause in ((1, 0.05), (0, 0.05), (1, 0.15)):
            self.rst.set(value)
            time.sleep(pause)

    def begin(self):
        self.reset()
        self._cmd(SWRESET, wait=0.15)
        self._cmd(SLPOUT, wait=0.255)
        for code, data, wait in INIT:
            self._cmd(code, data, wait)
        self._cmd(MADCTL, bytes([ROTATION[self.rotation] | (BGR if self.bgr else 0)]))
        self._cmd(COLMOD, b"\x05")                      # 16비트/픽셀
        self._cmd(INVON if self.invert else INVOFF)
        # 화면은 맨 마지막에 켠다. 켜 놓고 픽셀 형식을 바꾸면 한순간 깨져 보인다.
        self._cmd(NORON, wait=0.01)
        self.blank()                                    # 켜기 전에 검게
        self._cmd(DISPON, wait=0.1)
        if self.bl is not None:
            self.bl.set(1)

    # ---- 그리기 ----
    def window(self, x0, y0, x1, y1):
        x0 += self.ox; x1 += self.ox
        y0 += self.oy; y1 += self.oy
        self._cmd(CASET, bytes([x0 >> 8, x0 & 0xFF, x1 >> 8, x1 & 0xFF]))
        self._cmd(RASET, bytes([y0 >> 8, y0 & 0xFF, y1 >> 8, y1 & 0xFF]))

    def show(self, rgb565_be):
        """화면 전체를 한 번에. 길이는 width*height*2 여야 한다."""
        need = self.width * self.height * 2
        if len(rgb565_be) != need:
            raise LcdError(f"픽셀 수가 안 맞아요: {len(rgb565_be)} 바이트, {need} 필요")
        self.window(0, 0, self.width - 1, self.height - 1)
        self._cmd(RAMWR)
        self.dc.set(1)
        self._write(rgb565_be)

    def blank(self):
        self.fill((0, 0, 0))

    def fill(self, rgb):
        """화면 전체를 한 색으로. 배선과 속도를 가리는 데 쓴다."""
        r, g, b = rgb
        v = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
        self.show(bytes([v >> 8, v & 0xFF]) * (self.width * self.height))

    def close(self, backlight_off=True):
        if self.bl is not None and backlight_off:
            self.bl.set(0)
        for p in (self.dc, self.rst, self.bl):
            if p is not None:
                p.close()
        try:
            self.spi.close()
        except Exception:
            pass
