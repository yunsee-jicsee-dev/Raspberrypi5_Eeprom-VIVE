"""부팅 인트로 재생기 — 리눅스 프레임버퍼(/dev/fb0) 에 인트로를 틀어 준다.

데스크톱도 X 도 없는 부팅 초기에 돌아가야 하므로 창(SDL 윈도) 대신
/dev/fb0 에 픽셀을 직접 써 넣는다.  systemd 서비스로 등록하면 전원을
넣고 몇 초 뒤 라즈베리 로고 인트로가 모니터에 나오고, 끝나면 평소처럼
데스크톱(또는 콘솔) 으로 넘어간다.

    python3 bootintro.py                      # /dev/fb0 에 한 번 재생
    python3 bootintro.py --display sdl        # 개발 PC 에서 창으로 확인
    python3 bootintro.py --loop               # 끝나면 다시 (전시용)
    python3 bootintro.py --save-frames out/   # 프레임을 PNG 로 떨궈 확인

설치는 scripts/install-bootintro.sh 참고.
"""
import argparse
import array
import fcntl
import mmap
import os
import struct
import sys
import time

import pygame

import intro

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
def play(out, canvas_size, k, fps, loop=False, length=intro.LENGTH):
    cw, ch = canvas_size
    it = intro.Intro(intro.load_text(), cw, ch, k)
    canvas = pygame.Surface((cw, ch))
    frame = 1.0 / max(1, fps)
    t0 = time.monotonic()
    frames = 0
    while True:
        t = time.monotonic() - t0
        if t >= length:
            if not loop:
                return frames, t
            t0, frames = time.monotonic(), 0
            continue
        it.draw(canvas, t)
        out.show(canvas)
        frames += 1
        rest = frame - (time.monotonic() - t0 - t)
        if rest > 0:
            time.sleep(rest)


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


def build_parser():
    p = argparse.ArgumentParser(description="부팅 때 라즈베리파이 5 인트로 재생")
    p.add_argument("--display", choices=("auto", "fb", "sdl", "frames"), default="auto",
                   help="auto: 프레임버퍼가 있으면 거기, 없으면 창 (기본)")
    p.add_argument("--fbdev", default=FB_DEFAULT, help=f"프레임버퍼 장치 (기본 {FB_DEFAULT})")
    p.add_argument("--fb-geometry", type=parse_geometry, metavar="WxH@BPP",
                   help="화면 정보를 못 읽을 때 직접 지정")
    p.add_argument("--fb-stride", type=int, help="한 줄의 바이트 수 직접 지정")
    p.add_argument("--size", type=parse_size, default=(CANVAS_W, CANVAS_H), metavar="WxH",
                   help=f"인트로 원본 크기 (기본 {CANVAS_W}x{CANVAS_H})")
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
    p.add_argument("--optional", action="store_true",
                   help="프레임버퍼가 없으면 조용히 넘어가기 (systemd 서비스용)")
    p.add_argument("--quiet", action="store_true", help="끝나고 요약 출력 안 함")
    return p


def main(argv=None):
    a = build_parser().parse_args(argv)
    cw, ch = a.size
    k = 2 if cw >= 320 else 1   # 글자 배율: LCD 처럼 작은 화면은 1

    os.environ.setdefault("SDL_AUDIODRIVER", "dummy")

    mode = a.display
    if a.save_frames:
        mode = "frames"
    on_desktop = desktop_session()
    if mode == "auto":
        if on_desktop:
            mode = "sdl"          # 컴포지터가 화면을 쥐고 있으니 창으로
        else:
            if a.wait_fb:
                wait_for_fb(a.fbdev, a.wait_fb)
            mode = "fb" if os.path.exists(a.fbdev) else "sdl"
    fullscreen = on_desktop if a.fullscreen is None else a.fullscreen
    if mode in ("fb", "frames") or (mode == "sdl" and not on_desktop):
        os.environ.setdefault("SDL_VIDEODRIVER", "dummy")

    if mode == "fb" and a.wait_fb and not wait_for_fb(a.fbdev, a.wait_fb):
        print(f"{a.fbdev} 가 {a.wait_fb}초 안에 안 나타났어요", file=sys.stderr)
        return 0 if a.optional else 1

    cursor_off = False
    try:
        if mode == "fb":
            fb = Framebuffer(a.fbdev, a.fb_geometry, a.fb_stride)
            if not a.keep_cursor:
                console_cursor(False)
                cursor_off = True
            out = FbOutput(fb, (cw, ch), a.max_scale)
            if not a.quiet:
                print(f"[인트로] {fb.width}x{fb.height} {fb.bpp}bpp, {out.scale}배 확대")
        elif mode == "frames":
            out = FrameDumpOutput(a.save_frames or "frames", a.every)
        else:
            out = open_window((cw, ch), a.window_scale, fullscreen,
                              a.max_scale, a.wait_display)
    except (FramebufferError, pygame.error) as e:
        print(e, file=sys.stderr)
        return 0 if a.optional else 1

    if a.delay > 0:
        time.sleep(a.delay)

    t0 = time.monotonic()
    try:
        frames, played = play(out, (cw, ch), k, a.fps, a.loop)
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
