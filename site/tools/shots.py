#!/usr/bin/env python3 -I
"""Takes the website screenshots by driving the real app with UI scenarios.

    swift build -c release && scripts/bundle.sh release --bundle-id com.macexplorer.app.scenarios \
        --output .build/macExplorer-scenarios.app
    swiftc -O site/tools/winid.swift -o /tmp/macx-site-winid
    python3 -I site/tools/shots.py [name ...]

Each shot is a scenario: a demo fixture, steps that put the window in the state we want, then a write to the
hidden marker `.m/ready.bin` and a long sleep. When the marker appears the window is captured with
`screencapture -l` into site/assets/shots/<name>.png. Everything runs inside a fresh
${TMPDIR}/macx-site-shots-<UUID> directory that is deleted afterwards; nothing else is touched.
Needs keyboard focus: only one scenario app may run on the Mac at a time.
"""
import json, os, shutil, subprocess, sys, tempfile, time, uuid

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = os.path.join(REPO, ".build/macExplorer-scenarios.app/Contents/MacOS/macExplorer")
OUT = os.path.join(REPO, "site/assets/shots")
WINID = "/tmp/macx-site-winid"

MB = 1_000_000
A = ""  # the sandbox root itself displays as "alex"
FIXTURE = {
    "dirs": [A + d for d in ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures",
                             "Documents/Invoices 2026", "Documents/Taxes", "Documents/Projects",
                             "Documents/Projects/Website", "Documents/Projects/Garden plan",
                             "Documents/Projects/Kitchen remodel", "Pictures/Lisbon 2026", "Pictures/Screenshots"]],
    "files": [A + f for f in [
        "Documents/Invoices 2026/2026-01 Northwind.pdf", "Documents/Invoices 2026/2026-02 Northwind.pdf",
        "Documents/Invoices 2026/2026-03 Contoso.pdf", "Documents/Taxes/2025 Return.pdf", "Documents/Taxes/W-2 2025.pdf",
        "Documents/Budget 2027.xlsx", "Documents/Lease agreement.pdf", "Documents/Packing list.txt",
        "Documents/Meeting notes.md", "Documents/Projects/Website/hero.sketch", "Documents/Projects/Website/index.html",
        "Documents/Projects/Garden plan/layout.pdf", "Documents/Projects/Kitchen remodel/quote-v3.pdf",
        "Downloads/Xcode_27.2.xip", "Downloads/MacExplorer-0.3.0.dmg", "Downloads/statement-oct.pdf",
        "Downloads/font-pack.zip", "Downloads/install-notes.txt", "Downloads/IMG_0412.heic",
        "Downloads/boarding-pass.pdf", "Downloads/receipt-4471.pdf",
        "Movies/Lisbon timelapse.mov", "Music/Demo take 4.m4a", "Desktop/todo.txt"]],
    "sizes": {A + k: v for k, v in {
        "Documents/Invoices 2026/2026-01 Northwind.pdf": 182_000, "Documents/Invoices 2026/2026-02 Northwind.pdf": 179_000,
        "Documents/Invoices 2026/2026-03 Contoso.pdf": 240_000, "Documents/Taxes/2025 Return.pdf": 1_830_000,
        "Documents/Taxes/W-2 2025.pdf": 96_000, "Documents/Budget 2027.xlsx": 64_000,
        "Documents/Lease agreement.pdf": 412_000, "Documents/Packing list.txt": 820,
        "Documents/Projects/Website/hero.sketch": 5_400_000, "Documents/Projects/Website/index.html": 9_000,
        "Documents/Projects/Garden plan/layout.pdf": 830_000, "Documents/Projects/Kitchen remodel/quote-v3.pdf": 310_000,
        "Downloads/Xcode_27.2.xip": 9_800_000, "Downloads/MacExplorer-0.3.0.dmg": 7_200_000,
        "Downloads/statement-oct.pdf": 220_000, "Downloads/font-pack.zip": 3_100_000, "Downloads/IMG_0412.heic": 2_900_000,
        "Downloads/boarding-pass.pdf": 140_000, "Downloads/receipt-4471.pdf": 61_000,
        "Movies/Lisbon timelapse.mov": 48_000_000, "Music/Demo take 4.m4a": 6_400_000}.items()},
    "images": [A + f"Pictures/Lisbon 2026/IMG_04{n}.png" for n in (12, 13, 15, 16, 18, 20, 21, 23)],
    "mtimeDays": {A + k: v for k, v in {
        "Downloads/Xcode_27.2.xip": 0, "Downloads/MacExplorer-0.3.0.dmg": 0, "Downloads/boarding-pass.pdf": -1,
        "Downloads/statement-oct.pdf": -3, "Downloads/receipt-4471.pdf": -4, "Downloads/font-pack.zip": -12,
        "Downloads/install-notes.txt": -12, "Downloads/IMG_0412.heic": -40,
        "Documents/Budget 2027.xlsx": -1, "Documents/Lease agreement.pdf": -30, "Documents/Packing list.txt": -6,
        "Documents/Meeting notes.md": 0}.items()},
    "contents": {A + "Documents/Meeting notes.md":
                 "# Kitchen remodel\n\n- Quote v3 is in Projects/Kitchen remodel\n- Ask about the window above the sink\n"
                 "- Countertops: quartz or oak?\n- Start date: after the holidays\n"},
    "tags": {A + "Documents/Budget 2027.xlsx": ["Green"], A + "Documents/Lease agreement.pdf": ["Red"],
             A + "Documents/Taxes": ["Orange"]},
}

# The first window of a launch isn't key. Opening and closing a tab once the state is set makes it key
# (blue selection, coloured traffic lights), as in normal use.
KEY = [{"key": "cmd+t"}, {"sleepMs": 500}, {"key": "cmd+w"}, {"sleepMs": 700}]

def into(path):
    """Steps that open alex/<path> through the address bar."""
    return [{"key": "cmd+l"}, {"waitFor": {"editingAddress": True}}, {"type": A + path}, {"key": "return"},
            {"waitFor": {"folder": A + path, "editingAddress": False, "state": "complete"}, "timeoutMs": 5000},
            ]

SIZES = [{"menu": ["View", "Calculate Folder Sizes"]}, {"sleepMs": 1500}]

# name -> (steps, which window: "main" | "properties")
SHOTS = {
    "tree": (into("Documents/Projects/Website") + [{"click": "index.html"}] + KEY, "main"),
    "sizes": (into("Documents/Projects") + SIZES + [{"sleepMs": 800}, {"click": "Website"}] + KEY, "main"),
    "details": (into("Documents") + SIZES + [{"click": "Budget 2027.xlsx"}] + KEY, "main"),
    "cut": (into("Documents") + [{"click": "Lease agreement.pdf"}, {"click": "Budget 2027.xlsx", "modifiers": ["cmd"]},
             {"key": "cmd+x"}, {"waitFor": {"cut": ["Budget 2027.xlsx", "Lease agreement.pdf"]}}] + KEY, "main"),
    "address": (into("Documents") + KEY + [{"key": "cmd+l"}, {"waitFor": {"editingAddress": True}},
                 {"type": A + "Documents/Projects/Website"}, {"sleepMs": 500}], "main"),
    "group-by-date": (into("Downloads") + [{"menu": ["View", "Group By", "Date Modified"]}, {"sleepMs": 1500}]
                      + KEY, "main"),
    "columns": (into("Documents/Projects") + [{"key": "cmd+3"}, {"waitFor": {"viewMode": "columns"}},
                 {"click": "Website"}, {"sleepMs": 600}] + KEY, "main"),
    "icons": (into("Pictures/Lisbon 2026") + [{"key": "cmd+2"}, {"sleepMs": 1500}] + KEY, "main"),
    "properties": (into("Documents") + SIZES + KEY + [{"click": "Projects"}, {"key": "cmd+i"},
                    {"waitFor": {"propertiesWindows": 1}}, {"sleepMs": 1500}], "properties"),
    "search": (into("Documents") + [{"key": "cmd+f"}, {"waitFor": {"focus": "fieldEditor"}}, {"type": "kind:pdf"},
                {"setSearchScope": "subfolders"}, {"waitFor": {"searchState": "complete"}, "timeoutMs": 8000},
                {"sleepMs": 600}], "main"),
    "preview": (into("Documents") + [{"menu": ["View", "Show Preview Pane"]}, {"waitFor": {"previewState": "nothing"}},
                 {"click": "Meeting notes.md"}, {"waitFor": {"previewState": "text"}}, {"sleepMs": 600}] + KEY, "main"),
    "settings": (into("Documents") + KEY + [{"key": "cmd+,"}, {"sleepMs": 1500}], "settings"),
    "tabs": (into("Documents") + [{"key": "cmd+t"}, {"sleepMs": 600}] + into("Downloads")
             + [{"key": "cmd+t"}, {"sleepMs": 600}] + into("Pictures") + [{"selectTab": 0}, {"sleepMs": 600}], "main"),
}

# User-guide snippets: guide/<name>.png = (source shot, x, y, w, h) in points of the 1x capture
# (scaled when the capture is 2x). Run `shots.py --crop` to redo them without retaking the shots.
CROPS = {
    "tabs": ("tabs", 226, 40, 830, 90),
    "columns": ("columns", 224, 118, 450, 92),
    "group-by-date": ("group-by-date", 224, 128, 700, 274),
    "sizes": ("details", 224, 128, 700, 96),
    "search": ("search", 226, 40, 830, 340),
    "preview": ("preview", 224, 92, 1052, 586),
    "properties": ("properties", 56, 38, 440, 180),
    "settings": ("settings", 56, 38, 500, 432),
}
BASE_WIDTH = {"properties": 552, "settings": 612, "preview": 1332}

def crop(names):
    for out, (src, x, y, w, h) in CROPS.items():
        if src not in names: continue
        path = os.path.join(OUT, src + ".png")
        width = int(subprocess.run(["sips", "-g", "pixelWidth", path], capture_output=True, text=True)
                    .stdout.split()[-1])
        k = width / BASE_WIDTH.get(src, 1112)
        os.makedirs(os.path.join(OUT, "guide"), exist_ok=True)
        subprocess.run(["sips", "-c", str(round(h * k)), str(round(w * k)), "--cropOffset", str(round(y * k)),
                        str(round(x * k)), path, "--out", os.path.join(OUT, "guide", out + ".png")],
                       check=True, capture_output=True)
        print(f"guide/{out}.png from {src}")

def windows(pid):
    out = subprocess.run([WINID, "macExplorer"], capture_output=True, text=True).stdout.splitlines()
    out += subprocess.run([WINID, "MacExplorer"], capture_output=True, text=True).stdout.splitlines()
    wins = []
    for line in out:
        parts = line.split(" ", 4)
        if len(parts) >= 4 and parts[2] == str(pid):
            w, h = parts[3].split("x")
            wins.append((int(parts[0]), float(w) * float(h), parts[4] if len(parts) > 4 else ""))
    return wins

class App:
    """The app process started by `open`, found by its unique scenario path."""
    def __init__(self, scenario):
        self.scenario, self.pid = scenario, None
        for _ in range(50):
            ps = subprocess.run(["ps", "-axo", "pid=,args="], capture_output=True, text=True, errors="replace").stdout
            hits = [l.split(None, 1)[0] for l in ps.splitlines() if scenario in l and "MacOS/macExplorer" in l]
            if hits:
                self.pid = int(hits[0]); break
            time.sleep(0.1)
    def poll(self):
        if self.pid is None: return -1
        try: os.kill(self.pid, 0); return None
        except ProcessLookupError: return 0
    def terminate(self):
        if self.poll() is None: os.kill(self.pid, 15)
    def kill(self):
        if self.poll() is None: os.kill(self.pid, 9)
    def wait(self, timeout):
        end = time.time() + timeout
        while self.poll() is None:
            if time.time() > end: raise subprocess.TimeoutExpired("app", timeout)
            time.sleep(0.1)

def shoot(name, run):
    steps, which = SHOTS[name]
    d = os.path.join(run, name)
    # The fixture root must be an empty macx-scenario-* folder; the app is pointed at it through a
    # Users/alex symlink so the window shows a plausible name.
    real = os.path.join(d, "macx-scenario-root")
    users = os.path.join(d, "Macintosh HD", "Users")
    root = os.path.join(users, "alex")
    for sub in (real, users, d + "/state", d + "/trash"):
        os.makedirs(sub)
    os.symlink(real, root)
    scen = {"name": "site-" + name, "fixture": FIXTURE,
            "steps": steps + [{"fsWrite": {"path": ".m/ready.bin", "bytes": 1}}, {"sleepMs": 8000}]}
    path = os.path.join(d, "scenario.json")
    with open(path, "w") as fh:
        json.dump(scen, fh)
    # `open` activates the app, so its window is key (blue selection) like in normal use.
    bundle = APP.split("/Contents/")[0]
    subprocess.run(["open", "-n", "-o", d + "/app.log", "--stderr", d + "/app.log", bundle, "--args", "--root", root, "--state-dir", d + "/state", "--sandbox-trash", d + "/trash",
                             "--pasteboard", "macx-site-" + uuid.uuid4().hex, "--fake-launch-services",
                             "--skip-onboarding", "--scenario", path, "--scenario-output", d + "/result.json"], check=True)
    proc = App(path)
    try:
        deadline = time.time() + 40
        while not os.path.exists(os.path.join(root, ".m/ready.bin")):
            if proc.poll() is not None or time.time() > deadline:
                print(f"{name}: no marker (exit {proc.poll()}); see {d}/app.log and result.json")
                print(open(d + "/app.log").read()[-1500:])
                if os.path.exists(d + "/result.json"):
                    print(open(d + "/result.json").read()[-1500:])
                return False
            time.sleep(0.2)
        time.sleep(0.5)
        wins = windows(proc.pid)
        if which == "settings":
            wins = sorted(wins, key=lambda w: w[1])[:1]
        if which == "properties":
            wins = [w for w in wins if "Properties" in w[2] or "Info" in w[2]] or sorted(wins, key=lambda w: w[1])[:1]
        wins.sort(key=lambda w: -w[1])
        if not wins:
            print(f"{name}: no window found"); return False
        os.makedirs(OUT, exist_ok=True)
        subprocess.run(["screencapture", "-x", "-l", str(wins[0][0]), os.path.join(OUT, name + ".png")], check=True)
        print(f"{name}: ok ({wins[0][2]})")
        return True
    finally:
        proc.terminate()
        try: proc.wait(5)
        except subprocess.TimeoutExpired: proc.kill()

def main():
    if sys.argv[1:2] == ["--crop"]:
        crop(sys.argv[2:] or list(SHOTS)); return
    names = sys.argv[1:] or list(SHOTS)
    if subprocess.run(["pgrep", "-f", "macExplorer-scenarios.app/Contents/MacOS"], capture_output=True,
                      env={"LC_ALL": "C"}).returncode == 0:
        sys.exit("another scenario app is running; wait for it to finish")
    tmp = os.path.realpath(tempfile.gettempdir())
    run = os.path.join(tmp, "macx-site-shots-" + str(uuid.uuid4()).upper())
    os.makedirs(run)
    ok = True
    try:
        for n in names:
            ok = shoot(n, run) and ok
        crop(names)
    finally:
        if ok and os.path.basename(run).startswith("macx-site-shots-"):
            shutil.rmtree(run)
        elif not ok:
            print("kept", run)
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
