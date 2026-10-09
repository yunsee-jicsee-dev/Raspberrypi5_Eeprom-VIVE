"""인트로를 plymouth 부팅 테마로 굽는다.

plymouth 스크립트 언어로 연출을 다시 짜는 대신, 지금 파이썬 연출을 그대로
PNG 프레임으로 뽑아서 plymouth 가 한 장씩 넘기게 한다. 그림은 픽셀 단위로
똑같다.

    python3 scripts/make-plymouth-theme.py            # build/rpi5-intro/ 에 생성
    python3 scripts/make-plymouth-theme.py --fps 25 --zoom 3

프레임은 400x240 으로 그린 뒤 정수 배율로만 키운다 (도트가 뭉개지지 않게).
plymouth 는 이걸 전부 메모리에 올리므로 장수와 크기가 곧 메모리다:
    25fps x 2배(800x480)  = 93장 ≈ 137MB   (기본값)
    10fps x 2배           = 37장 ≈  55MB
"""
import argparse
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ.setdefault("SDL_AUDIODRIVER", "dummy")

import pygame  # noqa: E402

import intro  # noqa: E402

THEME_NAME = "rpi5-intro"
THEME_DIR = "/usr/share/plymouth/themes/" + THEME_NAME

# plymouth 는 refresh 를 초당 50회쯤 부른다. 프레임 간격은 그 비율로 센다.
PLYMOUTH_REFRESH_HZ = 50.0

SCRIPT = '''# 라즈베리파이 5 부팅 인트로 — scripts/make-plymouth-theme.py 가 생성함.
# 연출은 파이썬 쪽에서 구운 PNG 를 한 장씩 넘기는 것뿐이다.
#
# plymouth 스크립트 판본마다 되는 문법이 조금씩 달라서 일부러 소박하게 썼다.
# 파일명은 전부 펼쳐 적었고(숫자→문자열 변환에 기대지 않는다), bare return 과
# Math.Int 도 쓰지 않는다. refresh 는 정수 카운터로만 센다.

Window.SetBackgroundTopColor({bg_r}, {bg_g}, {bg_b});
Window.SetBackgroundBottomColor({bg_r}, {bg_g}, {bg_b});

frame = [];
{frame_lines}

LAST = {last};
EVERY = {every};        # refresh 몇 번마다 다음 장으로 (plymouth 는 초당 50회)

sprite = Sprite();
sprite.SetImage(frame[0]);
sprite.SetX((Window.GetWidth()  - frame[0].GetWidth())  / 2);
sprite.SetY((Window.GetHeight() - frame[0].GetHeight()) / 2);
sprite.SetZ(10000);

idx = 0;
tick = 0;
stopped = 0;

fun refresh () {{
    if (stopped == 0) {{
        tick = tick + 1;
        if (tick >= EVERY) {{
            tick = 0;
            if (idx < LAST) {{
                idx = idx + 1;
                sprite.SetImage(frame[idx]);
            }}
        }}
    }}
}}
Plymouth.SetRefreshFunction(refresh);

# 암호 입력이나 메시지가 필요하면 인트로를 치운다.
fun hide (prompt, bullets) {{
    stopped = 1;
    sprite.SetOpacity(0);
}}
Plymouth.SetDisplayPasswordFunction(hide);
Plymouth.SetDisplayQuestionFunction(hide);

fun go_away () {{
    stopped = 1;
    sprite.SetOpacity(0);
}}
Plymouth.SetDisplayNormalFunction(go_away);
Plymouth.SetQuitFunction(go_away);
'''

CONFIG = '''[Plymouth Theme]
Name=Raspberry Pi 5 Intro
Description=라즈베리 로고가 떨어져 착지하는 부팅 인트로
ModuleName=script

[script]
ImageDir={theme_dir}
ScriptFile={theme_dir}/{name}.script
'''


def build(outdir, fps, zoom, canvas, theme_dir):
    cw, ch = canvas
    k = 2 if cw >= 320 else 1
    it = intro.Intro(intro.load_text(), cw, ch, k)
    canvas_surf = pygame.Surface((cw, ch))
    big = pygame.Surface((cw * zoom, ch * zoom))

    if os.path.isdir(outdir):
        shutil.rmtree(outdir)
    os.makedirs(outdir)

    count = max(1, int(round(intro.LENGTH * fps)))
    for n in range(count):
        it.draw(canvas_surf, n / fps)
        pygame.transform.scale(canvas_surf, big.get_size(), big)   # 정수 배율, 보간 없음
        pygame.image.save(big, os.path.join(outdir, f"f{n}.png"))

    frame_lines = "\n".join(f'frame[{n}] = Image("f{n}.png");' for n in range(count))
    with open(os.path.join(outdir, f"{THEME_NAME}.script"), "w") as fp:
        fp.write(SCRIPT.format(
            frame_lines=frame_lines,
            last=count - 1,
            every=int(round(PLYMOUTH_REFRESH_HZ / fps)),
            bg_r=round(intro.BG0[0] / 255, 4),
            bg_g=round(intro.BG0[1] / 255, 4),
            bg_b=round(intro.BG0[2] / 255, 4),
        ))
    with open(os.path.join(outdir, f"{THEME_NAME}.plymouth"), "w") as fp:
        fp.write(CONFIG.format(theme_dir=theme_dir, name=THEME_NAME))
    return count, big.get_size()


def main(argv=None):
    p = argparse.ArgumentParser(description="인트로를 plymouth 테마로 굽기")
    p.add_argument("--out", default="build", help="테마를 만들 상위 폴더 (기본 build)")
    p.add_argument("--fps", type=int, default=25,
                   help="프레임레이트 (기본 25). plymouth 가 초당 50회 갱신하므로 "
                        "50 의 약수(50/25/10/5)여야 정확하다")
    p.add_argument("--zoom", type=int, default=2, help="정수 확대 배율 (기본 2)")
    p.add_argument("--size", default="400x240", help="원본 크기 (기본 400x240)")
    p.add_argument("--theme-dir", default=THEME_DIR,
                   help=f"설치될 경로 (.plymouth 에 적힌다, 기본 {THEME_DIR})")
    a = p.parse_args(argv)
    try:
        cw, ch = (int(v) for v in a.size.lower().split("x"))
    except ValueError:
        print("--size 는 400x240 처럼 적어 주세요", file=sys.stderr)
        return 2

    if PLYMOUTH_REFRESH_HZ % a.fps:
        print(f"경고: --fps {a.fps} 는 50 의 약수가 아닙니다. "
              f"재생 속도가 {PLYMOUTH_REFRESH_HZ / round(PLYMOUTH_REFRESH_HZ / a.fps):.1f}fps "
              f"로 어긋납니다.", file=sys.stderr)

    outdir = os.path.join(a.out, THEME_NAME)
    count, (w, h) = build(outdir, a.fps, max(1, a.zoom), (cw, ch), a.theme_dir)
    mb = count * w * h * 4 / 1024 / 1024
    total = sum(os.path.getsize(os.path.join(outdir, f)) for f in os.listdir(outdir))
    print(f"{outdir}/ 에 만들었습니다")
    print(f"  {count}장 x {w}x{h} ({a.fps}fps, {intro.LENGTH}초)")
    print(f"  디스크 {total / 1024 / 1024:.1f}MB / plymouth 가 쓸 메모리 약 {mb:.0f}MB")
    print("  설치:  sudo scripts/install-plymouth-theme.sh")
    return 0


if __name__ == "__main__":
    sys.exit(main())
