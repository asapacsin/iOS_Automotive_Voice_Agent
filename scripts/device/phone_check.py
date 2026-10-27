#!/usr/bin/env python3
"""Local device check on the plugged-in iPhone (replaces the GitHub `simulator` job; owner rule 2026-10-27).

Steps: optional install (xtool in WSL) -> WebDriverAgent + port forward -> launch NovaDrive -> walk the screens
(驾驶, 设置 位置来源/声音, 音频测试, camera) -> labels + screenshots -> PASS/FAIL report.

Needs: iPhone plugged in, unlocked, trusted; the elevated `pymobiledevice3 remote tunneld` running (UAC once
per boot); WebDriverAgentRunner installed on the phone. No GitHub, no network except the phone tunnel.

Usage: python scripts/device/phone_check.py [--ipa D:\\path\\NovaDrive.ipa] [--out D:\\ndipa\\check]
"""
import argparse
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.request

PHONE = os.environ.get("NOVA_PMD3", r"C:\Users\Administrator\AppData\Local\novadrive-tools\venv312\Scripts\pymobiledevice3.exe")
UDID = os.environ.get("NOVA_UDID", "00008150-00066DA21AC0C01C")
WDA = os.environ.get("NOVA_WDA", "XTL-Y6YT9YM42U.com.facebook.WebDriverAgentRunner.xctrunner")
APP = os.environ.get("NOVA_APP", "XTL-Y6YT9YM42U.com.asapacsin.novadrive")
BASE = "http://127.0.0.1:8100"

# Coordinates for iPhone 17 (WDA element lookup returns HTTP 500 on this device, so taps go by position).
DRIVE_TAB, SETTINGS_TAB, AUDIO_TAB = (40, 830), (362, 816), (201, 816)
CAMERA_ICON = (161, 85)


def call(method, path, body=None, timeout=60):
    req = urllib.request.Request(BASE + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def wda_up():
    try:
        call("GET", "/status", timeout=3)
        return True
    except Exception:
        return False


def to_wsl(path):
    p = pathlib.PureWindowsPath(os.path.abspath(path))
    return "/mnt/" + p.drive[0].lower() + "/" + "/".join(p.parts[1:])


def install(ipa):
    ipa = str(ipa)
    if not ipa.isascii():
        raise SystemExit(f"ipa path must be ASCII for WSL: {ipa}")
    r = subprocess.run(["wsl", "-d", "Ubuntu-22.04", "-u", "root", "--", "env",
                        "USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015", "xtool", "install", to_wsl(ipa)],
                       capture_output=True, text=True, timeout=2700)  # xtool installs can take 20+ min
    ok = "Successfully installed" in r.stdout + r.stderr
    return ok, (r.stdout + r.stderr)[-400:]


def start_wda(procs):
    if wda_up():
        return True
    procs.append(subprocess.Popen([PHONE, "developer", "dvt", "xcuitest", WDA, "--tunnel", UDID], cwd="C:\\",
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    procs.append(subprocess.Popen([PHONE, "usbmux", "forward", "8100", "8100"], cwd="C:\\",
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    for _ in range(60):
        if wda_up():
            return True
        time.sleep(2)
    return False


class AppNotInFront(Exception):
    pass


class Run:
    def __init__(self, out):
        self.out = pathlib.Path(out)
        self.out.mkdir(parents=True, exist_ok=True)
        self.checks = []
        self.sid = call("POST", "/session", {"capabilities": {"alwaysMatch": {"bundleId": APP}}})["sessionId"]

    def tap(self, xy, wait=2.0):
        call("POST", f"/session/{self.sid}/wda/tap", {"x": xy[0], "y": xy[1]})
        time.sleep(wait)

    def swipe_up(self):
        call("POST", f"/session/{self.sid}/wda/dragfromtoforduration",
             {"fromX": 200, "fromY": 650, "toX": 200, "toY": 250, "duration": 0.2})
        time.sleep(1)

    def labels(self):
        # The accessibility snapshot can take long while the mic or camera is live; retry once.
        try:
            src = call("GET", f"/session/{self.sid}/source?format=description", timeout=150)["value"]
        except TimeoutError:
            time.sleep(3)
            src = call("GET", f"/session/{self.sid}/source?format=description", timeout=150)["value"]
        return [l.split("label: ", 1)[1].strip("'") for l in src.splitlines()
                if "label: " in l and ("StaticText" in l or "Button" in l or "Segment" in l)]

    def in_app(self):
        """NovaDrive is in front (its tab bar is visible). Screenshots are taken only then, so nothing private
        from another app the owner opened is ever recorded."""
        seen = self.labels()
        return any(t in s for s in seen for t in ("驾驶", "设置"))

    def shot(self, name):
        if not self.in_app():
            raise AppNotInFront(name)
        for _ in range(3):
            r = subprocess.run([PHONE, "developer", "dvt", "screenshot", "--tunnel", UDID,
                                str(self.out / f"{name}.png")], cwd="C:\\", capture_output=True, text=True)
            if (self.out / f"{name}.png").exists():
                return
            time.sleep(2)
        print(f"note: screenshot {name} failed: {(r.stderr or '')[-200:]}", flush=True)

    def expect(self, name, seen, wanted):
        missing = [w for w in wanted if not any(w in s for s in seen)]
        self.checks.append({"check": name, "pass": not missing, "missing": missing})
        print(("PASS " if not missing else "FAIL ") + name + (f" missing={missing}" if missing else ""), flush=True)


def walk(run):
    run.tap(DRIVE_TAB)
    run.expect("drive screen", run.labels(), ["开始对话"])
    run.shot("01_drive")

    run.tap(SETTINGS_TAB, 3)
    run.tap(SETTINGS_TAB, 2)
    seen = set()
    for _ in range(8):
        seen.update(run.labels())
        run.swipe_up()
    run.expect("settings: 位置来源 + 抗噪 (F-16a, F-04a)", seen, ["位置来源", "手机定位", "演示起点", "定位权限", "抗噪"])
    run.shot("02_settings")

    run.tap(AUDIO_TAB, 3)
    run.expect("音频测试 screen", run.labels(), ["抗噪"])
    run.shot("03_audio")

    run.tap(DRIVE_TAB)
    run.tap(CAMERA_ICON, 4)
    run.expect("camera opens with lens label (F-20b)", run.labels(), ["前方"])
    run.shot("04_camera")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipa", help="install this .ipa first")
    ap.add_argument("--out", default=r"D:\ndipa\check\\" + time.strftime("%Y%m%d-%H%M%S"))
    args = ap.parse_args()
    report = {"time": time.strftime("%Y-%m-%d %H:%M:%S"), "ipa": args.ipa, "checks": []}
    procs = []
    try:
        if args.ipa:
            ok, tail = install(args.ipa)
            report["install"] = {"pass": ok, "log": tail}
            print(("PASS" if ok else "FAIL") + " install", flush=True)
            if not ok:
                return finish(report, args.out, 1)
        if not start_wda(procs):
            report["wda"] = "WebDriverAgent did not answer: is the phone unlocked and the elevated tunneld running?"
            print("FAIL " + report["wda"], flush=True)
            return finish(report, args.out, 2)
        run = Run(args.out)
        try:
            walk(run)
        except AppNotInFront as e:
            report["aborted"] = f"NovaDrive left the screen before '{e}' (phone in use?); rerun with the phone untouched"
            print("FAIL " + report["aborted"], flush=True)
            report["checks"] = run.checks
            return finish(report, args.out, 3)
        report["checks"] = run.checks
        return finish(report, args.out, 0 if all(c["pass"] for c in run.checks) else 1)
    finally:
        for p in procs:
            p.terminate()


def finish(report, out, code):
    pathlib.Path(out).mkdir(parents=True, exist_ok=True)
    (pathlib.Path(out) / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"phone check: {'PASS' if code == 0 else 'FAIL'} -> {out}\\report.json", flush=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
