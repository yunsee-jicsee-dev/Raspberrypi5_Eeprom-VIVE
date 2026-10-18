"""로그인하면 뜨는 "획득!" 장면 — 커널 로그처럼 생긴 화면.

    [    0.412913] login: jicsee logged in on tty7
    [    0.998214] 권한 목록 확인 중...
    ★ 당신은 sudo 권한을 얻었다!
    ★ python 을(를) 얻었다!
    ...

intro.Intro 와 같은 모양(draw(surf, t), LENGTH) 이라 play.py 가 그대로 쓴다.
HDMI·프레임버퍼·SPI LCD 어디든 같은 방식으로 올라간다.

    python3 play.py --scene unlock --display sdl --fullscreen
    sudo python3 play.py --scene unlock --kmsg     # 진짜 커널 로그에도 남기기

한글 글자는 시스템 폰트를 찾아 쓴다. 쓸 만한 게 없으면 pixelfont 로 떨어지면서
글귀도 ASCII 로 바꾼다 (네모(□) 만 늘어서는 것보다는 낫다).
"""
import glob
import os
import time

import pygame

BG = (8, 8, 12)
DIM = (96, 112, 104)       # 평범한 커널 로그 줄
TIME_COL = (70, 84, 80)    # [   0.123456] 부분
GOT = (254, 196, 72)       # 획득 줄
STAR = (255, 236, 160)
WHITE = (236, 240, 238)
RULE = (40, 48, 46)

CPS = 48.0        # 글자 찍히는 속도 (초당)
GAP = 0.10        # 줄 사이 틈
HOLD = 1.4        # 다 찍고 머무는 시간
FADE = 0.6        # 암전

# 한글이 들어 있을 만한 폰트. 앞엣것부터 찾는다.
FONT_GLOBS = (
    "/usr/share/fonts/**/NanumGothic*.tt[fc]",
    "/usr/share/fonts/**/NanumBarunGothic*.tt[fc]",
    "/usr/share/fonts/**/NanumSquare*.tt[fc]",
    "/usr/share/fonts/**/NotoSansCJK*.ot[fc]",
    "/usr/share/fonts/**/NotoSansKR*.[ot]tf",
    "/usr/share/fonts/**/NotoSansMonoCJK*.ot[fc]",
    "/usr/share/fonts/**/*CJK*.ot[fc]",
    "/usr/share/fonts/**/malgun*.ttf",
    "/usr/share/fonts/**/wqy-zenhei*.ttc",
    "/usr/share/fonts/**/unifont*.otf",
)

DEFAULT_ITEMS = ["python", "chromium", "firefox", "설정 권한"]

# 한글 폰트가 없을 때 쓸 영문 이름. 여기 없는 한글 항목은 조용히 건너뛴다
# (pixelfont 는 ASCII 전용이라 그대로 두면 '?????' 가 된다).
ASCII_ALIAS = {
    "설정 권한": "settings access",
    "sudo 권한": "sudo",
    "관리자 권한": "root access",
}


def particle(word):
    """받침이 있으면 '을', 없으면 '를'. 한글이 아니면 판단할 수 없으니 '을(를)'."""
    last = word.rstrip()[-1:]
    if "가" <= last <= "힣":
        return "을" if (ord(last) - 0xAC00) % 28 else "를"
    return "을(를)"


def ascii_item(it):
    """ASCII 로 쓸 수 있는 이름. 없으면 None (= 목록에서 뺀다)."""
    return it if it.isascii() else ASCII_ALIAS.get(it)


def _renders_hangul(font):
    """한글을 진짜로 그리는 폰트인지. 서로 다른 글자가 전부 같으면 네모(토푸) 다."""
    def shot(ch):
        s = font.render(ch, True, (255, 255, 255), (0, 0, 0))
        return s.get_size(), pygame.image.tobytes(s, "RGB")
    try:
        if shot("권") == shot(""):     # 없는 글자와 같으면 네모
            return False
        return len({shot(c) for c in "권한얻었다빛감"}) >= 5
    except Exception:
        return False


def korean_font(size, want_path=False):
    """한글을 그릴 수 있는 폰트 하나. 없으면 None. want_path 면 (폰트, 경로)."""
    if not pygame.font.get_init():
        pygame.font.init()
    seen = []
    for pat in FONT_GLOBS:
        seen += sorted(glob.glob(pat, recursive=True))
    for name in ("nanumgothic", "nanumbarungothic", "notosanscjkkr", "notosanskr",
                 "notosansmonocjkkr", "malgungothic"):
        p = pygame.font.match_font(name)
        if p:
            seen.append(p)
    for path in seen:
        try:
            f = pygame.font.Font(path, size)
        except Exception:
            continue
        if _renders_hangul(f):
            return (f, path) if want_path else f
    return (None, None) if want_path else None


def build_lines(items=None, user=None, hangul=True, compact=False):
    """(종류, 글귀) 목록. 종류: 'log' 평범한 줄, 'got' 획득, 'rule' 구분선.

    compact 는 LCD 처럼 좁은 화면용 — 긴 커널 줄을 빼고 시각 표시도 생략한다.
    160픽셀 폭에 "systemd[1]: Reached target graphical.target" 은 들어가지 않는다.
    """
    user = user or os.environ.get("SUDO_USER") or os.environ.get("USER") or "pi"
    items = list(items) if items else list(DEFAULT_ITEMS)
    tty = os.environ.get("XDG_SESSION_TYPE", "wayland")

    if not hangul:   # 한글 폰트가 없을 때
        safe = [a for a in (ascii_item(i) for i in items) if a]
        if compact:
            lines = [("log", "checking perms ..."), ("rule", ""),
                     ("got", "sudo")]
            lines += [("got", it) for it in safe]
            lines += [("got", "... and more!"), ("rule", ""),
                      ("log", f"welcome, {user}")]
            return lines
        lines = [("log", "systemd[1]: Reached target graphical.target"),
                 ("log", f"login: {user} logged in on {tty}"),
                 ("log", "checking permissions ..."),
                 ("rule", ""),
                 ("got", "YOU OBTAINED: sudo")]
        lines += [("got", f"YOU OBTAINED: {it}") for it in safe]
        lines += [("got", "YOU OBTAINED: ... and more!"),
                  ("rule", ""),
                  ("log", f"welcome back, {user}.")]
        return lines

    if compact:
        lines = [("log", "권한 확인 중 ..."), ("rule", ""),
                 ("got", "sudo 권한!")]
        lines += [("got", f"{it}!") for it in items]
        lines += [("got", "... 등등!"), ("rule", ""),
                  ("log", f"{user} 님, 환영합니다")]
        return lines

    lines = [("log", "systemd[1]: Reached target graphical.target"),
             ("log", f"login: {user} logged in on {tty}"),
             ("log", "권한 목록 확인 중 ..."),
             ("rule", ""),
             ("got", "당신은 sudo 권한을 얻었다!")]
    lines += [("got", f"{it}{particle(it)} 얻었다!") for it in items]
    lines += [("got", "... 등등을 얻었다!"),
              ("rule", ""),
              ("log", f"{user} 님, 환영합니다.")]
    return lines


def schedule(lines, cps=CPS, gap=GAP):
    """각 줄이 언제 시작해 언제 다 찍히는지."""
    out, t = [], 0.25
    for kind, text in lines:
        dur = 0.18 if kind == "rule" else max(0.12, len(text) / cps)
        out.append((t, t + dur, kind, text))
        t += dur + gap
    return out, t + HOLD + FADE


def to_kmsg(items=None, user=None, tag="rpi5-intro"):
    """진짜 커널 로그(dmesg) 에 남긴다. root 여야 하고, 안 되면 조용히 넘어간다.

    두 가지를 지켜야 한다.

    1) /dev/kmsg 는 write() 한 번이 기록 한 줄이다. 버퍼에 모았다가 한꺼번에
       쓰면 통째로 한 기록이 되어 dmesg 에서 이어 붙은 꼴로 보이고, 둘째 줄부터의
       <6> 접두어가 글자 그대로 남는다. 그래서 줄마다 따로, 버퍼 없이 쓴다.
    2) 커널 기록은 ASCII 밖의 바이트를 \\xNN 으로 바꿔 저장한다. 한글을 넣으면
       dmesg 에 \\xec\\x9d\\x84 처럼 나와 읽을 수 없다. 그래서 ASCII 판을 쓴다.
    """
    lines = build_lines(items, user, hangul=False)
    try:
        fd = os.open("/dev/kmsg", os.O_WRONLY)
    except OSError:
        return False
    try:
        for kind, text in lines:
            if kind == "rule" or not text:
                continue
            os.write(fd, f"<6>{tag}: {text}\n".encode("ascii", "replace"))
    except OSError:
        return False
    finally:
        os.close(fd)
    return True


class Unlock:
    """획득 장면 한 판. intro.Intro 와 같은 쓰임새."""

    def __init__(self, text, w, h, k=1, items=None, user=None):
        self.w, self.h, self.k = w, h, k
        self.pixel = text                      # pixelfont (ASCII 폴백용)

        self.pad = max(2, w // 60)
        avail = w - 2 * self.pad

        size = max(7, int(h / 17))
        self.font, self.font_path = korean_font(size, want_path=True)
        self.hangul = self.font is not None
        self.compact = w < 240          # LCD 처럼 좁으면 시각 표시와 긴 줄을 뺀다
        self.lines = build_lines(items, user, self.hangul, self.compact)

        # 가장 긴 줄이 가로로 들어갈 때까지 줄인다. 안 그러면 LCD 나 ASCII 폴백에서
        # 글자가 화면 밖으로 잘려 나간다.
        widest = max((self._width_of(t, k) for _, t in self.lines), default=1)
        if self.hangul:
            while size > 7 and widest > avail:
                size -= 1
                self.font = pygame.font.Font(self.font_path, size) if self.font_path \
                    else korean_font(size)
                widest = max(self._width_of(t, k) for _, t in self.lines)
            self.line_h = self.font.get_linesize()
        else:
            # pixelfont 은 한 글자 6*k 픽셀. 배율로 맞춘다.
            longest = max((len(t) for _, t in self.lines), default=1) + 2
            self.k = k = max(1, min(k, avail // (6 * longest) or 1))
            self.line_h = 7 * k + 3
        self.plan, self.LENGTH = schedule(self.lines)
        self.rows = max(1, (h - 6) // self.line_h)   # 한 화면에 들어가는 줄 수
        self._fx = pygame.Surface((w, h), pygame.SRCALPHA)
        self._cache = {}

    def _width_of(self, text, k):
        """★ 과 시각 표시까지 더한 한 줄의 대략적인 가로 길이."""
        prefix = "* " if self.compact else "[   0.000000] "
        if self.hangul:
            return self.font.size(text)[0] + self.font.size(prefix)[0]
        return (len(text) + len(prefix)) * 6 * k

    # ---- 글자 ----
    def _text(self, s, color):
        key = (s, color)
        img = self._cache.get(key)
        if img is None:
            if self.hangul:
                img = self.font.render(s, True, color)
            else:
                img = self.pixel.render(s, color, self.k, shadow=False)
            self._cache[key] = img
        return img

    def _stamp(self, i, done):
        """[    1.234567] 커널 로그 시각. 줄 번호로 만들어서 매번 같게."""
        v = 0.4 + i * 0.37 + (0.0 if done else 0.0)
        return f"[{v:11.6f}] "

    # ---- 본 그림 ----
    def draw(self, surf, t):
        surf.fill(BG)

        shown = []
        for i, (t0, t1, kind, text) in enumerate(self.plan):
            if t < t0:
                break
            if t >= t1:
                shown.append((i, kind, text, True))
            else:                                   # 찍히는 중
                n = int(len(text) * (t - t0) / max(1e-6, t1 - t0))
                shown.append((i, kind, text[:n], False))

        view = shown[-self.rows:]
        y = self.h - self.pad - len(view) * self.line_h
        y = max(self.pad, y)
        for i, kind, text, done in view:
            x = self.pad
            if kind == "rule":
                ry = y + self.line_h // 2
                pygame.draw.line(surf, RULE, (x, ry), (self.w - x, ry), max(1, self.k))
            else:
                if kind == "got":
                    star = self._text("* " if not self.hangul else "★ ", STAR)
                    surf.blit(star, (x, y))
                    x += star.get_width()
                    surf.blit(self._text(text, GOT), (x, y))
                elif self.compact:
                    surf.blit(self._text(text, DIM), (x, y))
                else:
                    stamp = self._text(self._stamp(i, done), TIME_COL)
                    surf.blit(stamp, (x, y))
                    surf.blit(self._text(text, DIM), (x + stamp.get_width(), y))
                if not done:                        # 커서
                    cw = max(2, self.k * 2)
                    img = self._text(text, GOT if kind == "got" else DIM)
                    cx = x + img.get_width() + 1
                    if kind == "log":
                        cx += 0
                    if int(t * 6) % 2 == 0 and cx < self.w - cw:
                        surf.fill(WHITE, (cx, y + 2, cw, self.line_h - 5))
            y += self.line_h

        # 획득 줄이 막 끝났을 때 한 번 번쩍
        for t0, t1, kind, _ in self.plan:
            if kind == "got" and 0 <= t - t1 < 0.12:
                f = self._fx
                f.fill((255, 240, 190, int(46 * (1 - (t - t1) / 0.12))))
                surf.blit(f, (0, 0))
                break

        # 주사선
        for sy in range(0, self.h, 3):
            surf.fill((0, 0, 0), (0, sy, self.w, 1), special_flags=pygame.BLEND_RGB_SUB)

        if t >= self.LENGTH - FADE:
            f = self._fx
            f.fill((0, 0, 0, int(255 * min(1.0, (t - (self.LENGTH - FADE)) / FADE))))
            surf.blit(f, (0, 0))


def demo(argv=None):
    """`python3 unlock.py` — 창에서 한 번 본다."""
    import argparse
    import intro

    ap = argparse.ArgumentParser(description="획득 장면 미리보기")
    ap.add_argument("--size", default="400x240")
    ap.add_argument("--scale", type=int, default=3)
    ap.add_argument("--fps", type=int, default=30)
    a = ap.parse_args(argv)
    w, h = (int(v) for v in a.size.lower().split("x"))

    pygame.init()
    win = pygame.display.set_mode((w * a.scale, h * a.scale))
    pygame.display.set_caption("획득!")
    sc = Unlock(intro.load_text(), w, h, 2 if w >= 320 else 1)
    canvas = pygame.Surface((w, h))
    clock = pygame.time.Clock()
    t0 = time.monotonic()
    while True:
        clock.tick(a.fps)
        for e in pygame.event.get():
            if e.type in (pygame.QUIT, pygame.KEYDOWN):
                pygame.quit()
                return 0
        t = time.monotonic() - t0
        if t >= sc.LENGTH:
            t0 = time.monotonic()
        sc.draw(canvas, t)
        pygame.transform.scale(canvas, win.get_size(), win)
        pygame.display.flip()


if __name__ == "__main__":
    import sys
    sys.exit(demo())
