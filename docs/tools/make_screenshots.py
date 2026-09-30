#!/usr/bin/env python3
"""
Makes the README screenshots of the QDOASJulia GUI: drives a headless Google Chrome
through the DevTools protocol, then frames each capture as a macOS browser window with
a soft shadow (transparent PNG).

Needs: google-chrome (or chromium), Python 3 with `websocket-client` and `Pillow`, and
a running GUI on the real-data example, e.g.

    julia --project -t auto examples/run_gui.jl ace        # serves http://127.0.0.1:8765/
    python3 docs/tools/make_screenshots.py [--url http://127.0.0.1:8765/] [--out docs/img]

Copyright (c) 2026 Sunandan Mahant <sunandanmahant@outlook.com>; BSD-3-Clause, see LICENSE.
"""
import argparse, base64, io, json, os, shutil, subprocess, sys, tempfile, time, urllib.request

import websocket
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1440, 900
SCALE = 3            # device pixels per CSS pixel; set with --scale
SPECTRUM = "20170407_180207_e+15.STD"


class Chrome:
    def __init__(self, binary, port=9333):
        self.dir = tempfile.mkdtemp(prefix="qdoasjl-shots-")
        self.proc = subprocess.Popen([binary, "--headless=new", f"--remote-debugging-port={port}",
                                      f"--user-data-dir={self.dir}", "--no-first-run", "--no-default-browser-check",
                                      "--hide-scrollbars", "--force-color-profile=srgb", f"--window-size={W},{H}",
                                      "about:blank"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                tabs = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json"))
                page = next(t for t in tabs if t["type"] == "page")
                break
            except Exception:
                time.sleep(0.1)
        else:
            raise SystemExit("Chrome did not start")
        self.ws = websocket.create_connection(page["webSocketDebuggerUrl"], suppress_origin=True)
        self.seq = 0

    def call(self, method, **params):
        self.seq += 1
        self.ws.send(json.dumps({"id": self.seq, "method": method, "params": params}))
        while True:
            m = json.loads(self.ws.recv())
            if m.get("id") == self.seq:
                if "error" in m:
                    raise RuntimeError(f"{method}: {m['error']}")
                return m.get("result", {})

    def js(self, expr):
        r = self.call("Runtime.evaluate", expression=expr, awaitPromise=True, returnByValue=True)
        if "exceptionDetails" in r:
            raise RuntimeError(r["exceptionDetails"])
        return r.get("result", {}).get("value")

    def wait(self, expr, timeout=30):
        t0 = time.time()
        while time.time() - t0 < timeout:
            try:
                if self.js(expr):
                    return
            except Exception:
                pass
            time.sleep(0.15)
        raise SystemExit(f"timed out waiting for {expr}")

    def goto(self, url):
        self.call("Page.navigate", url=url)
        time.sleep(0.4)
        self.wait("document.readyState === 'complete' && typeof S !== 'undefined' && !!S.st")

    def hover(self, x, y):
        self.call("Input.dispatchMouseEvent", type="mouseMoved", x=x, y=y)

    def click(self, x, y):
        for t in ("mousePressed", "mouseReleased"):
            self.call("Input.dispatchMouseEvent", type=t, x=x, y=y, button="left", clickCount=1)

    def shot(self, hover=None):
        self.js("document.getElementById('toasts').innerHTML = ''; 0")
        time.sleep(0.4)
        if hover:
            # Chrome sends a mouseleave when it captures; keep the hover read-out for the picture
            self.js("window.addEventListener('mouseleave', e => e.stopImmediatePropagation(), true); 0")
            self.hover(*hover)
            time.sleep(0.3)
        png = base64.b64decode(self.call("Page.captureScreenshot", format="png")["data"])
        return Image.open(io.BytesIO(png)).convert("RGBA")

    def close(self):
        self.proc.terminate()
        shutil.rmtree(self.dir, ignore_errors=True)


def font(size, weight="Medium"):
    for f in (f"/usr/share/fonts/opentype/inter/Inter-{weight}.otf", "/System/Library/Fonts/SFNS.ttf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()


def frame(img, url, out_width=None):
    """A macOS-style browser window around `img`, with rounded corners and a shadow."""
    s = SCALE
    bar = 40 * s
    w, h = img.size
    win = Image.new("RGBA", (w, h + bar), (0, 0, 0, 0))
    d = ImageDraw.Draw(win)
    # title bar: a light vertical gradient
    for y in range(bar):
        c = int(246 - 10 * y / bar)
        d.line([(0, y), (w, y)], fill=(c, c, c + 1, 255))
    d.line([(0, bar - 1), (w, bar - 1)], fill=(214, 214, 216, 255))
    for i, col in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        cx, cy, r = (20 + 20 * i) * s, bar // 2, 6 * s
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=col + (255,),
                  outline=tuple(int(v * 0.85) for v in col) + (255,), width=max(1, s // 2))
    # address field
    pw, ph = 460 * s, 26 * s
    px, py = (w - pw) // 2, (bar - ph) // 2
    d.rounded_rectangle([px, py, px + pw, py + ph], radius=7 * s, fill=(226, 226, 229, 255))
    f = font(12 * s, "Medium")
    tw = d.textlength(url, font=f)
    d.text(((w - tw) / 2, py + ph / 2), url, font=f, fill=(80, 82, 88, 255), anchor="lm")
    # navigation arrows, drawn as chevrons
    for k, x0 in enumerate((96 * s, 122 * s)):
        cy = bar // 2
        pts = [(x0 + 4 * s, cy - 5 * s), (x0 - 1 * s, cy), (x0 + 4 * s, cy + 5 * s)] if k == 0 else \
              [(x0 - 1 * s, cy - 5 * s), (x0 + 4 * s, cy), (x0 - 1 * s, cy + 5 * s)]
        d.line(pts, fill=(120, 122, 128, 255) if k == 0 else (185, 186, 190, 255), width=2 * s // 1, joint="curve")
    win.paste(img, (0, bar))
    # rounded corners and a hairline border
    radius = 11 * s
    mask = Image.new("L", win.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, win.size[0] - 1, win.size[1] - 1], radius=radius, fill=255)
    win.putalpha(mask)
    ImageDraw.Draw(win).rounded_rectangle([0, 0, win.size[0] - 1, win.size[1] - 1], radius=radius,
                                          outline=(0, 0, 0, 46), width=max(1, s // 2))
    # soft shadow on a transparent canvas
    pad, dy = 70 * s, 24 * s
    canvas = Image.new("RGBA", (win.size[0] + 2 * pad, win.size[1] + 2 * pad), (0, 0, 0, 0))
    sh = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shmask = Image.new("L", canvas.size, 0)
    ImageDraw.Draw(shmask).rounded_rectangle([pad, pad + dy, pad + win.size[0], pad + dy + win.size[1]], radius=radius, fill=110)
    shmask = shmask.filter(ImageFilter.GaussianBlur(30 * s))
    sh.putalpha(shmask)
    tight = Image.new("L", canvas.size, 0)
    ImageDraw.Draw(tight).rounded_rectangle([pad, pad + 2 * s, pad + win.size[0], pad + 2 * s + win.size[1]], radius=radius, fill=60)
    tight = tight.filter(ImageFilter.GaussianBlur(3 * s))
    sh2 = Image.new("RGBA", canvas.size, (0, 0, 0, 0)); sh2.putalpha(tight)
    canvas = Image.alpha_composite(canvas, sh)
    canvas = Image.alpha_composite(canvas, sh2)
    canvas.alpha_composite(win, (pad, pad))
    if not out_width:
        return canvas
    k = out_width / canvas.size[0]
    return canvas.resize((out_width, round(canvas.size[1] * k)), Image.LANCZOS)


def main():
    global SCALE
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8765/")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "img"))
    ap.add_argument("--chrome", default=shutil.which("google-chrome") or shutil.which("chromium") or "google-chrome")
    ap.add_argument("--scale", type=int, default=SCALE, help="device pixels per CSS pixel (default %(default)s)")
    a = ap.parse_args()
    SCALE = a.scale
    os.makedirs(a.out, exist_ok=True)
    shown = a.url.split("//", 1)[-1].rstrip("/")
    c = Chrome(a.chrome)
    try:
        c.call("Emulation.setDeviceMetricsOverride", width=W, height=H, deviceScaleFactor=SCALE, mobile=False)
        c.call("Page.enable")
        spec = SPECTRUM.replace("+", "%2B")

        # 1. a fit, with the read-out under the mouse
        c.goto(f"{a.url}#spectrum={spec}&window=NO2&tab=fit")
        c.wait(f"S.fit && S.fit.spectrum.endsWith('{SPECTRUM}') && !!document.querySelector('#odFig svg')")
        time.sleep(1.0)
        r = c.js("(() => { const b = document.querySelector('#odFig svg').getBoundingClientRect(); return [b.left, b.top, b.width, b.height]; })()")
        shots = {"gui_fit": c.shot(hover=(r[0] + 0.585 * r[2], r[1] + 0.30 * r[3]))}
        # the figure that Export > Figure (PNG) writes, rendered the same way as in the page
        png = c.js("const SC = %d; " % SCALE + """new Promise(res => { const svg = composeFigure(), m = svg.match(/width="(\\d+)" height="(\\d+)"/), img = new Image();
            img.onload = () => { const cv = document.createElement('canvas'); cv.width = SC * m[1]; cv.height = SC * m[2];
              const g = cv.getContext('2d'); g.scale(SC, SC); g.drawImage(img, 0, 0); res(cv.toDataURL('image/png').split(',')[1]); };
            img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg); })""")
        fig = Image.open(io.BytesIO(base64.b64decode(png))).convert("RGB")
        fig.save(os.path.join(a.out, "fit_figure.png"), optimize=True)
        with open(os.path.join(a.out, "fit_figure.svg"), "w") as io_:          # the same figure as vector graphics
            io_.write(c.js("composeFigure()"))

        # 2. the fit window map
        c.js("showTab('lab')")
        c.js("runMap(); 0")
        c.wait("S.map && S.mapJob && !S.mapJob.running", 120)
        c.js("S.mapQty = 'scd:NO2'; renderLab()")
        c.wait("!!document.querySelector('#mapFig svg')")
        time.sleep(0.5)
        r = c.js("(() => { const b = document.querySelector('#mapFig svg').getBoundingClientRect(); return [b.left, b.top, b.width, b.height]; })()")
        c.hover(r[0] + 0.45 * r[2], r[1] + 0.35 * r[3])
        c.click(r[0] + 0.45 * r[2], r[1] + 0.35 * r[3])
        shots["gui_map"] = c.shot(hover=(r[0] + 0.45 * r[2], r[1] + 0.35 * r[3]))

        # 3. results of all spectra
        c.js("runBatch(); 0")
        c.wait("S.batch === null && S.results && S.results.rows.length >= 144", 120)
        c.js("S.resultsCol = 'O4.SlCol(O4)'; S.colorBy = 'elevation'; showTab('results')")
        c.wait("!!document.querySelector('#resFig svg')")
        c.hover(5, 5)
        shots["gui_results"] = c.shot()

        # 4. the folder picker
        c.js("showTab('fit')")
        c.js("openFolderDialog(); 0")
        c.wait("document.querySelectorAll('#fdList .fd-row').length > 5")
        shots["gui_folder"] = c.shot()
        c.js("fdClose(null)")
    finally:
        c.close()
    for name, img in shots.items():
        out = os.path.join(a.out, name + ".png")
        frame(img, shown).save(out, optimize=True)
        print(out, os.path.getsize(out) // 1024, "KB")


if __name__ == "__main__":
    main()
