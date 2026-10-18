"""인트로 재생기 — 화면에 인트로를 한 번 튼다. 하는 일은 그게 전부다.

창이든 콘솔이든, 쓸 수 있는 출력을 알아서 고른다.

    sudo python3 play.py                 # 알아서 (데스크톱이면 창, 아니면 KMS → fb)
    python3 play.py --display sdl        # 창으로
    python3 play.py --display sdl --fullscreen
    sudo python3 play.py --display kms   # 콘솔에서 화면을 직접 잡아서
    sudo python3 play.py --display lcd   # ST7735 SPI LCD 에
    python3 play.py --save-frames out/   # 재생 대신 PNG 로 떨구기
    python3 play.py --loop               # 끝나면 다시 (전시용)

로그인할 때 자동으로 틀려면:  sudo ./install.sh
부팅 스플래시로 쓰려면:       sudo boot/install.sh
"""
import argparse
import array
import fcntl
import mmap
import os
import signal
import struct
import sys
import time

os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")

import pygame  # noqa: E402

import intro  # noqa: E402

FB_DEFAULT = "/dev/fb0"

FBIOGET_VSCREENINFO = 0x4600
FBIOGET_FSCREENINFO = 0x4602

# ioctl 이 안 될 때 쓰는 기본 픽셀 배치 (라즈베리파이 기본값)
DEFAULT_MASKS = {
    32: (0x00FF0000, 0x0000FF00, 0x000000FF, 0),   # XRGB8888
    16: (0xF800, 0x07E0, 0x001F, 0),               # RGB565
}

CANVAS_W, CANVAS_H = 400, 240   # 인트로를 그리는 원본 해상도


# --------------------------------------------------------------- 프레임버퍼 --
class FramebufferError(RuntimeError):
    pass


class Framebuffer:
    """/dev/fb0 를 mmap 해 두고 Surface 를 그대로 밀어 넣는다."""

    def __init__(self, path=FB_DEFAULT, geometry=None, stride=None):
        try:
            self.fd = os.open(path, os.O_RDWR)
        except OSError as e:
            raise FramebufferError(f"{path} 를 열지 못했어요: {e}") from e
        self.path = path
        self.width, self.height, self.bpp, self.masks = self._probe(geometry)
        if self.bpp not in DEFAULT_MASKS:
            os.close(self.fd)
            raise FramebufferError(f"{self.bpp}bpp 프레임버퍼는 지원하지 않아요 (16 또는 32)")
        self.stride = stride or self._probe_stride()
        self.size = self.stride * self.height
        try:
            self.mm = mmap.mmap(self.fd, self.size, flags=mmap.MAP_SHARED,
                                prot=mmap.PROT_READ | mmap.PROT_WRITE)
        except OSError as e:
            os.close(self.fd)
            raise FramebufferError(f"{path} 를 mmap 하지 못했어요: {e}") from e

    # ---- 화면 정보 캐내기 ----
    def _probe(self, geometry):
        if geometry:
            w, h, bpp = geometry
            return w, h, bpp, DEFAULT_MASKS.get(bpp, DEFAULT_MASKS[32])
        info = self._ioctl_var()
        if info:
            return info
        w, h = self._sysfs_size()
        bpp = int(self._sysfs("bits_per_pixel") or 32)
        return w, h, bpp, DEFAULT_MASKS.get(bpp, DEFAULT_MASKS[32])

    def _ioctl_var(self):
        """FBIOGET_VSCREENINFO — 해상도·색 깊이·채널 위치를 한 번에."""
        buf = array.array("B", bytes(256))
        try:
            fcntl.ioctl(self.fd, FBIOGET_VSCREENINFO, buf, True)
        except OSError:
            return None
        f = struct.unpack_from("<20I", buf, 0)
        w, h, bpp = f[0], f[1], f[6]
        if not (w and h and bpp):
            return None
        # red/green/blue/transp 가 각각 (offset, length, msb_right) 세 칸씩
        masks = tuple(((1 << f[i + 1]) - 1) << f[i] if f[i + 1] else 0
                      for i in (8, 11, 14, 17))
        if not all(masks[:3]):
            masks = DEFAULT_MASKS.get(bpp, DEFAULT_MASKS[32])
        return w, h, bpp, masks

    def _probe_stride(self):
        """한 줄의 바이트 수. sysfs 에 있으면 그걸, 없으면 ioctl, 그것도 없으면 계산."""
        s = self._sysfs("stride")
        if s and s.isdigit() and int(s):
            return int(s)
        buf = array.array("B", bytes(256))
        try:
            fcntl.ioctl(self.fd, FBIOGET_FSCREENINFO, buf, True)
            line = struct.unpack_from("<I", buf, 48)[0]
            if line:
                return line
        except OSError:
            pass
        return self.width * self.bpp // 8

    def _sysfs(self, name):
        node = os.path.basename(self.path)
        try:
            with open(f"/sys/class/graphics/{node}/{name}") as fp:
                return fp.read().strip()
        except OSError:
            return None

    def _sysfs_size(self):
        txt = self._sysfs("virtual_size") or ""
        try:
            w, h = (int(v) for v in txt.split(","))
            return w, h
        except ValueError:
            raise FramebufferError(
                "화면 크기를 알아내지 못했어요. --fb-geometry 1920x1080@32 처럼 직접 알려 주세요")

    # ---- 그리기 ----
    def new_surface(self):
        """프레임버퍼와 픽셀 배치가 똑같은 Surface (변환 없이 그대로 복사된다)."""
        return pygame.Surface((self.width, self.height), 0, self.bpp, self.masks)

    def push(self, surf):
        pitch = surf.get_pitch()
        buf = memoryview(surf.get_buffer())
        if pitch == self.stride and len(buf) >= self.size:
            self.mm[0:self.size] = buf[0:self.size]
        else:
            row = min(pitch, self.stride)
            for y in range(self.height):
                self.mm[y * self.stride:y * self.stride + row] = buf[y * pitch:y * pitch + row]
        del buf

    def close(self):
        try:
            self.mm.close()
        finally:
            os.close(self.fd)


# ------------------------------------------------------------------ 출력기 --
class FbOutput:
    """프레임버퍼 한가운데에 인트로를 정수 배율로 키워서 띄운다."""

    name = "fb"

    def __init__(self, fb, canvas_size, max_scale=0):
        self.fb = fb
        cw, ch = canvas_size
        scale = max(1, min(fb.width // cw, fb.height // ch))
        if max_scale:
            scale = min(scale, max_scale)
        self.scale = scale
        self.dest = ((fb.width - cw * scale) // 2, (fb.height - ch * scale) // 2)
        self.screen = fb.new_surface()
        self.screen.fill((0, 0, 0))
        self._zoom = pygame.Surface((cw * scale, ch * scale))

    def show(self, canvas):
        pygame.transform.scale(canvas, self._zoom.get_size(), self._zoom)
        self.screen.blit(self._zoom, self.dest)
        self.fb.push(self.screen)

    def close(self, blank=True):
        if blank:
            self.screen.fill((0, 0, 0))
            self.fb.push(self.screen)
        self.fb.close()


class SdlOutput:
    """창 또는 전체화면.

    데스크톱(Wayland/X) 이 떠 있으면 컴포지터가 화면을 쥐고 있어서 /dev/fb0 에
    써 봐야 아무것도 안 보인다. 그래서 로그인 뒤에 트는 경우엔 이쪽을 쓴다.
    """

    name = "sdl"

    def __init__(self, canvas_size, scale=3, fullscreen=False, max_scale=0):
        cw, ch = canvas_size
        pygame.display.init()
        if fullscreen:
            info = pygame.display.Info()
            sw, sh = info.current_w, info.current_h
            self.win = pygame.display.set_mode((sw, sh), pygame.FULLSCREEN | pygame.NOFRAME)
            pygame.mouse.set_visible(False)
            scale = max(1, min(sw // cw, sh // ch))
            if max_scale:
                scale = min(scale, max_scale)
            self._zoom = pygame.Surface((cw * scale, ch * scale))
            self.dest = ((sw - cw * scale) // 2, (sh - ch * scale) // 2)
        else:
            self.win = pygame.display.set_mode((cw * scale, ch * scale))
            self._zoom = None
            self.dest = (0, 0)
        self.scale = scale
        pygame.display.set_caption("Raspberry Pi 5 부팅 인트로")
        self.cover()

    def cover(self):
        """검은 화면을 바로 띄운다.

        Wayland 는 첫 버퍼 커밋 전까지 서피스를 화면에 올리지 않는다. 창만 만들고
        가만히 있으면 그 사이 바탕화면이 그대로 보이므로, 만들자마자 한 번 덮는다.
        더블 버퍼라 두 번 flip 해야 양쪽 버퍼가 다 검어진다.
        """
        for _ in range(2):
            self.win.fill((0, 0, 0))
            pygame.display.flip()
        pygame.event.pump()

    def show(self, canvas):
        if self._zoom is None:
            pygame.transform.scale(canvas, self.win.get_size(), self.win)
        else:
            pygame.transform.scale(canvas, self._zoom.get_size(), self._zoom)
            self.win.fill((0, 0, 0))
            self.win.blit(self._zoom, self.dest)
        pygame.display.flip()
        for e in pygame.event.get():
            if e.type in (pygame.QUIT, pygame.KEYDOWN):
                raise KeyboardInterrupt

    def close(self, blank=True):
        pygame.display.quit()


def rgb565_be(surf):
    """16bpp Surface → ST7735 가 먹는 RGB565 빅엔디안 바이트열.

    pygame 의 16비트 Surface 는 호스트 바이트 순서(ARM = 리틀엔디안) 로 저장하는데
    ST7735 는 빅엔디안으로 받는다. array.byteswap() 은 C 로 도니까 프레임마다
    돌려도 부담이 없다.
    """
    w, h = surf.get_size()
    pitch, row = surf.get_pitch(), w * 2
    buf = memoryview(surf.get_buffer())
    if pitch == row:
        raw = bytes(buf[:row * h])
    else:                                  # 줄 끝 패딩이 있으면 줄 단위로 추려낸다
        raw = b"".join(bytes(buf[y * pitch:y * pitch + row]) for y in range(h))
    del buf
    if sys.byteorder == "little":
        a = array.array("H")
        a.frombytes(raw)
        a.byteswap()
        return a.tobytes()
    return raw


class LcdOutput:
    """ST7735 SPI LCD. 패널 크기에 맞춰 가운데에 정수 배율로 올린다."""

    name = "lcd"

    def __init__(self, canvas_size, a):
        import lcd as lcd_mod

        bus, _, dev = a.lcd_spi.partition(".")
        panel = lcd_mod.ST7735(
            lcd_mod.open_spi(int(bus), int(dev or 0), a.lcd_speed),
            dc=lcd_mod.Pin(a.lcd_dc),
            rst=lcd_mod.Pin(a.lcd_rst) if a.lcd_rst >= 0 else None,
            bl=lcd_mod.Pin(a.lcd_bl) if a.lcd_bl >= 0 else None,
            width=a.lcd_size[0], height=a.lcd_size[1],
            rotation=a.lcd_rotation, offset=a.lcd_offset,
            bgr=not a.lcd_rgb, invert=a.lcd_invert)
        panel.begin()
        self.panel = panel

        cw, ch = canvas_size
        scale = max(1, min(panel.width // cw, panel.height // ch))
        if a.max_scale:
            scale = min(scale, a.max_scale)
        self.scale = scale
        self._zoom = pygame.Surface((cw * scale, ch * scale))
        self.dest = ((panel.width - cw * scale) // 2, (panel.height - ch * scale) // 2)
        # 패널과 픽셀 배치가 같은 Surface. 여기 그려서 그대로 밀어 넣는다.
        self.screen = pygame.Surface((panel.width, panel.height), 0, 16,
                                     (0xF800, 0x07E0, 0x001F, 0))
        self.screen.fill((0, 0, 0))

    def show(self, canvas):
        pygame.transform.scale(canvas, self._zoom.get_size(), self._zoom)
        self.screen.blit(self._zoom, self.dest)
        self.panel.show(rgb565_be(self.screen))

    def close(self, blank=True):
        try:
            if blank:
                self.panel.blank()
        finally:
            self.panel.close(backlight_off=blank)


class FrameDumpOutput:
    """프레임을 PNG 로 저장. 하드웨어 없이 연출을 확인할 때."""

    name = "frames"

    def __init__(self, outdir, every=1):
        os.makedirs(outdir, exist_ok=True)
        self.outdir, self.every, self.n = outdir, max(1, every), 0
        self.scale = 1

    def show(self, canvas):
        if self.n % self.every == 0:
            pygame.image.save(canvas, os.path.join(self.outdir, f"f{self.n:05d}.png"))
        self.n += 1

    def close(self, blank=True):
        pass


# --------------------------------------------------------------- 콘솔 정리 --
def _write_quietly(path, value):
    try:
        with open(path, "w") as fp:
            fp.write(value)
        return True
    except OSError:
        return False


def console_cursor(show):
    """콘솔 커서가 인트로 위에서 깜빡이지 않게."""
    _write_quietly("/sys/class/graphics/fbcon/cursor_blink", "1" if show else "0")
    _write_quietly("/dev/tty0", "\033[?25h" if show else "\033[2J\033[H\033[?25l")


def open_window(canvas_size, scale, fullscreen, max_scale, wait=0.0):
    """창 열기. 세션이 아직 안 뜬 상태면 wait 초까지 다시 시도한다."""
    deadline = time.monotonic() + max(0.0, wait)
    while True:
        try:
            return SdlOutput(canvas_size, scale, fullscreen, max_scale)
        except pygame.error:
            if time.monotonic() >= deadline:
                raise
            pygame.display.quit()
            time.sleep(0.25)


def arm_watchdog(seconds):
    """정해진 시간이 지나면 무조건 끝낸다.

    이 프로그램은 부팅 중(display-manager 앞)에 돌기 때문에, 어디서든 멈추면
    부팅 전체가 멈춘다. 드라이버가 안 돌려주든 화면이 안 잡히든, 시간이 되면
    정리고 뭐고 바로 빠져나온다. 종료 코드는 0 이라 서비스가 실패로 뜨지 않는다.
    """
    if not seconds or not hasattr(signal, "SIGALRM"):
        return

    def bail(_signum, _frame):
        try:
            console_cursor(True)      # 커서는 살려 두고 가면 좋지만, 실패해도 그냥 간다
        except Exception:
            pass
        os._exit(0)

    signal.signal(signal.SIGALRM, bail)
    signal.alarm(int(seconds))


def desktop_session():
    """지금 데스크톱(Wayland/X) 이 떠 있는지. 떠 있으면 프레임버퍼는 안 보인다."""
    return bool(os.environ.get("WAYLAND_DISPLAY") or os.environ.get("DISPLAY"))


def wait_for_fb(path, seconds):
    """부팅 직후엔 드라이버가 아직 안 올라왔을 수 있어서 잠깐 기다려 준다."""
    deadline = time.monotonic() + seconds
    while not os.path.exists(path):
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.1)
    return True


# -------------------------------------------------------------------- 재생 --
def lcd_test(out):
    """단색 → 격자 순서로 띄워 어디까지 멀쩡한지 본다.

    단색이 깨끗하면 배선과 SPI 속도는 괜찮다는 뜻이고, 남은 문제는 배치
    (--lcd-offset / --lcd-rotation) 다. 단색부터 블록처럼 깨지면 속도를
    낮추거나 배선을 다시 봐야 한다.
    """
    panel = out.panel
    steps = [("빨강", (255, 0, 0)), ("초록", (0, 255, 0)), ("파랑", (0, 0, 255)),
             ("흰색", (255, 255, 255)), ("검정", (0, 0, 0))]
    for name, rgb in steps:
        print(f"[검사] {name} {rgb}")
        panel.fill(rgb)
        time.sleep(1.2)

    # 가장자리 한 픽셀 테두리 + 격자: 잘림과 밀림을 눈으로 본다
    print("[검사] 테두리+격자 — 네 변이 다 보이면 --lcd-offset 이 맞는 겁니다")
    w, h = panel.width, panel.height
    surf = pygame.Surface((w, h), 0, 16, (0xF800, 0x07E0, 0x001F, 0))
    surf.fill((0, 0, 0))
    for x in range(0, w, 16):
        surf.fill((40, 40, 40), (x, 0, 1, h))
    for y in range(0, h, 16):
        surf.fill((40, 40, 40), (0, y, w, 1))
    pygame.draw.rect(surf, (255, 255, 0), (0, 0, w, h), 1)        # 노란 테두리
    surf.fill((255, 0, 0), (0, 0, 8, 8))                          # 좌상단 빨강
    surf.fill((0, 255, 0), (w - 8, h - 8, 8, 8))                  # 우하단 초록
    panel.show(rgb565_be(surf))
    time.sleep(4)
    print("[검사] 끝. 노란 테두리 네 변이 다 보였나요?")
    return 0


def make_scene(name, canvas_size, k, a):
    """그릴 장면 하나. draw(surf, t) 와 LENGTH 만 있으면 된다."""
    cw, ch = canvas_size
    if name == "unlock":
        import unlock
        sc = unlock.Unlock(intro.load_text(), cw, ch, k,
                           items=a.items, user=a.user)
        if a.kmsg and not unlock.to_kmsg(a.items, a.user, level=a.kmsg_level):
            print("[인트로] /dev/kmsg 에 못 썼어요 (root 여야 합니다)", file=sys.stderr)
        return sc
    return intro.Intro(intro.load_text(), cw, ch, k, a.model, a.title)


def play(out, canvas_size, k, fps, loop=False, scenes=()):
    """장면들을 차례로 재생한다. 창은 하나만 쓰므로 사이에 깜빡임이 없다."""
    canvas = pygame.Surface(canvas_size)
    frame = 1.0 / max(1, fps)
    frames = 0
    started = time.monotonic()
    while True:
        for sc in scenes:
            length = getattr(sc, "LENGTH", intro.LENGTH)
            t0 = time.monotonic()
            while True:
                t = time.monotonic() - t0
                if t >= length:
                    break
                sc.draw(canvas, t)
                out.show(canvas)
                frames += 1
                rest = frame - (time.monotonic() - t0 - t)
                if rest > 0:
                    time.sleep(rest)
        if not loop:
            return frames, time.monotonic() - started


def parse_geometry(txt):
    """'1920x1080@32' → (1920, 1080, 32)"""
    try:
        size, _, bpp = txt.partition("@")
        w, h = (int(v) for v in size.lower().split("x"))
        return w, h, int(bpp) if bpp else 32
    except ValueError:
        raise argparse.ArgumentTypeError("1920x1080@32 처럼 적어 주세요")


def parse_size(txt):
    try:
        w, h = (int(v) for v in txt.lower().split("x"))
        return w, h
    except ValueError:
        raise argparse.ArgumentTypeError("400x240 처럼 적어 주세요")


def parse_pair(txt):
    """'1,2' → (1, 2)"""
    try:
        x, y = (int(v) for v in txt.split(","))
        return x, y
    except ValueError:
        raise argparse.ArgumentTypeError("1,2 처럼 적어 주세요")


def build_parser():
    p = argparse.ArgumentParser(description="부팅 때 라즈베리파이 5 인트로 재생")
    p.add_argument("--scene", nargs="+", choices=("intro", "unlock"), default=["intro"],
                   metavar="이름",
                   help="재생할 장면. intro(기본) 또는 unlock(로그인 '획득!' 화면). "
                        "여러 개를 적으면 차례로 이어서 재생한다: --scene intro unlock")
    p.add_argument("--items", nargs="*", metavar="이름",
                   help="--scene unlock 에서 얻을 것들 (기본: python chromium firefox '설정 권한')")
    p.add_argument("--user", help="--scene unlock 에 쓸 사용자 이름 (기본: 자동)")
    p.add_argument("--model", default="5", metavar="글자",
                   help="로고 옆 금색 글자 (기본 5). 파이 4 면 --model 4")
    p.add_argument("--title", default="Raspberry Pi", help="로고 아래 글귀 (기본 Raspberry Pi)")
    p.add_argument("--kmsg", action="store_true",
                   help="--scene unlock 의 글귀를 진짜 커널 로그(dmesg) 에도 남긴다 (root 필요)")
    p.add_argument("--kmsg-level", type=int, default=4, metavar="N",
                   help="커널 로그 레벨 (기본 4=warning: 부팅 화면에도 보인다)")
    p.add_argument("--display", choices=("auto", "kms", "fb", "sdl", "lcd", "frames"),
                   default="auto",
                   help="auto: 데스크톱이면 전체화면 창, 아니면 kms → fb 순서 (기본). "
                        "lcd 는 ST7735 SPI LCD")
    p.add_argument("--fbdev", default=FB_DEFAULT, help=f"프레임버퍼 장치 (기본 {FB_DEFAULT})")
    p.add_argument("--fb-geometry", type=parse_geometry, metavar="WxH@BPP",
                   help="화면 정보를 못 읽을 때 직접 지정")
    p.add_argument("--fb-stride", type=int, help="한 줄의 바이트 수 직접 지정")
    p.add_argument("--size", type=parse_size, default=None, metavar="WxH",
                   help=f"인트로 원본 크기 (기본 {CANVAS_W}x{CANVAS_H}, --display lcd 면 패널 크기)")
    p.add_argument("--max-scale", type=int, default=0, help="확대 배율 상한 (0=제한 없음)")
    p.add_argument("--window-scale", type=int, default=3, help="--display sdl 의 창 배율")
    p.add_argument("--fullscreen", dest="fullscreen", action="store_true", default=None,
                   help="--display sdl 을 전체화면으로 (데스크톱 세션용)")
    p.add_argument("--windowed", dest="fullscreen", action="store_false",
                   help="전체화면 대신 창으로")
    p.add_argument("--delay", type=float, default=0.0, metavar="SEC",
                   help="재생 전에 이만큼 기다리기 (그동안 화면은 이미 검게 덮인 상태)")
    p.add_argument("--wait-display", type=float, default=0.0, metavar="SEC",
                   help="창을 열지 못하면 이만큼까지 다시 시도 (로그인 직후용)")
    p.add_argument("--fps", type=int, default=30, help="프레임레이트 (기본 30)")
    p.add_argument("--loop", action="store_true", help="끝나면 처음부터 다시")
    p.add_argument("--wait-fb", type=float, default=0.0, metavar="SEC",
                   help="프레임버퍼가 생길 때까지 최대 몇 초 기다릴지")
    p.add_argument("--keep-cursor", action="store_true", help="콘솔 커서를 끄지 않기")
    p.add_argument("--no-blank", action="store_true", help="끝나고 화면을 지우지 않기")
    p.add_argument("--save-frames", metavar="DIR", help="--display frames 의 저장 폴더")
    p.add_argument("--every", type=int, default=1, help="프레임 저장 간격")
    g = p.add_argument_group("ST7735 SPI LCD (--display lcd)")
    g.add_argument("--lcd-spi", default="0.0", metavar="BUS.DEV",
                   help="/dev/spidev<BUS>.<DEV> (기본 0.0)")
    g.add_argument("--lcd-speed", type=int, default=16_000_000, metavar="HZ",
                   help="SPI 속도 (기본 16MHz). 블록처럼 깨지면 8000000, 4000000 으로 낮춰 보세요")
    g.add_argument("--lcd-test", action="store_true",
                   help="인트로 대신 단색/격자 검사 화면을 띄운다 (배선·속도 확인용)")
    g.add_argument("--lcd-dc", type=int, default=25, help="DC/RS 핀 (기본 GPIO 25)")
    g.add_argument("--lcd-rst", type=int, default=27, help="RST 핀 (기본 GPIO 27, 없으면 -1)")
    g.add_argument("--lcd-bl", type=int, default=24, help="백라이트 핀 (기본 GPIO 24, 없으면 -1)")
    g.add_argument("--lcd-size", type=parse_size, default=(160, 128), metavar="WxH",
                   help="패널 해상도 (기본 160x128)")
    g.add_argument("--lcd-rotation", type=int, default=90, choices=(0, 90, 180, 270),
                   help="화면 방향 (기본 90 = 가로)")
    g.add_argument("--lcd-offset", type=parse_pair, default=(0, 0), metavar="X,Y",
                   help="RAM 시작 위치. 그림이 몇 픽셀 밀려 보이면 1,2 또는 2,1")
    g.add_argument("--lcd-rgb", action="store_true",
                   help="색이 빨강↔파랑 뒤바뀌면 (기본은 BGR)")
    g.add_argument("--lcd-invert", action="store_true", help="흑백이 반전돼 보이면")

    p.add_argument("--max-seconds", type=float, default=0.0, metavar="SEC",
                   help="이 시간이 지나면 무조건 종료 (0=제한 없음). 부팅용 안전장치")
    p.add_argument("--optional", action="store_true",
                   help="프레임버퍼가 없으면 조용히 넘어가기 (systemd 서비스용)")
    p.add_argument("--quiet", action="store_true", help="끝나고 요약 출력 안 함")
    return p


def set_video_driver(name):
    """SDL 비디오 드라이버를 바꾼다. 이미 열려 있으면 닫고 다시."""
    if pygame.display.get_init():
        pygame.display.quit()
    if name:
        os.environ["SDL_VIDEODRIVER"] = name
    else:
        os.environ.pop("SDL_VIDEODRIVER", None)


def open_kms(canvas_size, max_scale, wait=0.0):
    """KMS/DRM 로 화면을 직접 잡는다.

    라즈베리파이 5 는 vc4-kms-v3d 로 도는 KMS 환경이라 /dev/fb0 은 DRM 의
    fbdev 흉내 장치다. 거기 쓴 게 화면에 안 나타나는 경우가 있어서, 컴포지터가
    없는 동안엔 DRM 을 직접 잡는 이쪽이 더 확실하다. (root 이거나 video 그룹,
    그리고 다른 DRM master 가 없어야 한다.)
    """
    set_video_driver("kmsdrm")
    return open_window(canvas_size, 1, True, max_scale, wait)


def open_fb(a, canvas_size, quiet):
    """리눅스 프레임버퍼(/dev/fb0) 에 직접 쓴다."""
    set_video_driver("dummy")
    fb = Framebuffer(a.fbdev, a.fb_geometry, a.fb_stride)
    out = FbOutput(fb, canvas_size, a.max_scale)
    if not quiet:
        print(f"[인트로] fb {fb.width}x{fb.height} {fb.bpp}bpp, {out.scale}배 확대")
    return out


def main(argv=None):
    a = build_parser().parse_args(argv)
    arm_watchdog(a.max_seconds)   # 다른 무엇보다 먼저
    # LCD 는 패널에 맞춰 그려야 글자 배율(k) 이 제대로 잡힌다
    if a.size is None:
        a.size = a.lcd_size if a.display == "lcd" else (CANVAS_W, CANVAS_H)
    cw, ch = a.size
    k = 2 if cw >= 320 else 1   # 글자 배율: LCD 처럼 작은 화면은 1

    os.environ.setdefault("SDL_AUDIODRIVER", "dummy")

    mode = a.display
    if a.save_frames:
        mode = "frames"
    on_desktop = desktop_session()
    fullscreen = on_desktop if a.fullscreen is None else a.fullscreen

    # 어떤 출력을 어떤 순서로 시도할지.
    #   데스크톱 세션 안  → 전체화면 창 (컴포지터가 화면을 쥐고 있다)
    #   그 밖(부팅 중 등) → KMS 로 화면을 직접 잡아 보고, 안 되면 프레임버퍼
    if mode == "auto":
        chain = ["sdl"] if on_desktop else ["kms", "fb"]
    else:
        chain = [mode]   # lcd 를 콕 집었으면 다른 데로 떨어지지 않는다

    if "fb" in chain and a.wait_fb and not wait_for_fb(a.fbdev, a.wait_fb):
        print(f"{a.fbdev} 가 {a.wait_fb}초 안에 안 나타났어요", file=sys.stderr)
        chain = [m for m in chain if m != "fb"]

    out = None
    cursor_off = False
    problems = []
    for want in chain:
        try:
            if want == "fb":
                if not a.keep_cursor and not cursor_off:
                    console_cursor(False)
                    cursor_off = True
                out = open_fb(a, (cw, ch), a.quiet)
            elif want == "kms":
                if not a.keep_cursor and not cursor_off:
                    console_cursor(False)
                    cursor_off = True
                out = open_kms((cw, ch), a.max_scale, a.wait_display)
                if not a.quiet:
                    print(f"[인트로] kms {out.win.get_size()}, {out.scale}배 확대")
            elif want == "lcd":
                out = LcdOutput((cw, ch), a)
                if not a.quiet:
                    print(f"[인트로] lcd {out.panel.width}x{out.panel.height} "
                          f"@spidev{a.lcd_spi}, {out.scale}배 확대")
            elif want == "frames":
                out = FrameDumpOutput(a.save_frames or "frames", a.every)
            else:
                if not on_desktop:
                    set_video_driver("dummy")
                out = open_window((cw, ch), a.window_scale, fullscreen,
                                  a.max_scale, a.wait_display)
                if not a.quiet:
                    print(f"[인트로] sdl {out.win.get_size()}, {out.scale}배 확대")
            break
        except (FramebufferError, pygame.error, OSError, ImportError) as e:
            problems.append(f"{want}: {e}")
        except Exception as e:                 # lcd.LcdError 등
            problems.append(f"{want}: {e}")

    if out is None:
        for p in problems:
            print(p, file=sys.stderr)
        if cursor_off:
            console_cursor(True)
        return 0 if a.optional else 1
    if problems and not a.quiet:
        for p in problems:
            print(f"[인트로] 건너뜀 — {p}")

    if getattr(a, "lcd_test", False) and out.name == "lcd":
        rc = lcd_test(out)
        out.close(blank=False)
        if cursor_off:
            console_cursor(True)
        return rc

    if a.delay > 0:
        time.sleep(a.delay)

    t0 = time.monotonic()
    try:
        frames, played = play(out, (cw, ch), k, a.fps, a.loop,
                              [make_scene(n, (cw, ch), k, a) for n in a.scene])
    except KeyboardInterrupt:
        frames, played = 0, time.monotonic() - t0
    finally:
        out.close(blank=not a.no_blank)
        if cursor_off:
            console_cursor(True)
    if not a.quiet and frames:
        print(f"[인트로] {frames}프레임 / {played:.1f}초 = {frames / played:.0f}fps (목표 {a.fps}fps)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
