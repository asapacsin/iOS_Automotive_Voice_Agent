#!/usr/bin/env python3
"""F-07 §14 item 1 (T-020a): check Qwen-Audio TTS on the owner's workspace host, from a PC.

Reads DASHSCOPE_API_KEY and DASHSCOPE_API_HOST from the environment only; the key is never printed or written.
Sends the item 3 request (no `instruction`) over one kept-open HTTPS connection, writes WAVs to a scratch folder
and prints, per run: chunk count, bytes, duration at 24 kHz 16-bit mono, time to first chunk, total time and the
worst wait between pieces measured against playback.

Runs: (a) the same short sentence 10 times; (b) a 1,200-character text, to find the length limit;
(c) each 龙安 voice once.

Usage: python3 scripts/tts_eval/qwen_tts_check.py [--out DIR] [--runs a,b,c]
"""
import argparse
import base64
import http.client
import json
import os
import sys
import tempfile
import time
import wave

MODEL = "qwen-audio-3.1-tts-flash"
PATH = "/api/v1/services/audio/tts/SpeechSynthesizer"
RATE = 24000
BYTES_PER_SECOND = RATE * 2
SHORT = "你好，我是小诺。现在是下午五点四十九分。"
VOICES = ["longanhuan_v3.1", "longanlingxin_v3.1", "longanfengyue_v3.1"]
DEFAULT_VOICE = VOICES[0]


def body(text, voice):
    """Exactly the item 3 body; no `instruction`."""
    return json.dumps({"model": MODEL, "input": {"text": text, "voice": voice, "format": "pcm", "sample_rate": RATE}},
                      ensure_ascii=False).encode("utf-8")


class SSE:
    """Splits on the blank line and joins an event's `data:` lines before JSON parsing."""

    def __init__(self):
        self.buf = b""

    def feed(self, data):
        self.buf += data.replace(b"\r\n", b"\n")
        events = []
        while b"\n\n" in self.buf:
            block, self.buf = self.buf.split(b"\n\n", 1)
            ev = self._event(block)
            if ev is not None:
                events.append(ev)
        return events

    def finish(self):
        ev = self._event(self.buf)
        self.buf = b""
        return [] if ev is None else [ev]

    @staticmethod
    def _event(block):
        lines = [l[5:].lstrip(b" ") if l[5:6] == b" " else l[5:]
                 for l in block.split(b"\n") if l.startswith(b"data:")]
        return b"\n".join(lines).decode("utf-8") if lines else None


def worst_wait(arrivals, t0):
    """Worst gap the player would hear: each piece is due when the audio before it has played out."""
    worst, played_until = 0.0, None
    for t, nbytes in arrivals:
        if played_until is None:
            played_until = t
        elif t > played_until:
            worst = max(worst, t - played_until)
            played_until = t
        played_until += nbytes / BYTES_PER_SECOND
    return worst * 1000


def run_once(conn, key, host, text, voice):
    headers = {"Authorization": "Bearer " + key, "Content-Type": "application/json", "X-DashScope-SSE": "enable",
               "Host": host, "Connection": "keep-alive"}
    t0 = time.monotonic()
    conn.request("POST", PATH, body=body(text, voice), headers=headers)
    resp = conn.getresponse()
    if resp.status // 100 != 2:
        raw = resp.read().decode("utf-8", "replace")
        try:
            obj = json.loads(raw)
            code = obj.get("code", "")
            msg = obj.get("message", "")
        except ValueError:
            code, msg = "", raw
        return {"status": resp.status, "error": code or "-", "engine": "Engine error" in msg}
    sse, pcm, arrivals, chunks, bad = SSE(), bytearray(), [], 0, None

    def take(events):
        nonlocal chunks, bad
        for ev in events:
            try:
                obj = json.loads(ev)
            except ValueError:
                bad = "not json"
                continue
            if obj.get("code"):
                bad = obj.get("code")
            out = obj.get("output") or {}
            if out.get("type") == "sentence-synthesis":
                data = base64.b64decode(((out.get("audio") or {}).get("data")) or "")
                if data:
                    chunks += 1
                    pcm.extend(data)
                    arrivals.append((time.monotonic(), len(data)))

    while True:
        piece = resp.read1(4096) if hasattr(resp, "read1") else resp.read(4096)
        if not piece:
            break
        take(sse.feed(piece))
    take(sse.finish())
    total = (time.monotonic() - t0) * 1000
    return {"status": resp.status, "chunks": chunks, "bytes": len(pcm), "seconds": len(pcm) / BYTES_PER_SECOND,
            "first_ms": (arrivals[0][0] - t0) * 1000 if arrivals else None, "total_ms": total,
            "worst_wait_ms": worst_wait(arrivals, t0), "bad": bad, "pcm": bytes(pcm)}


def write_wav(path, pcm):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm)


def show(label, r):
    if "error" in r:
        print(f"{label}: status={r['status']} code={r['error']}{' engine-error' if r['engine'] else ''}")
        return
    first = "-" if r["first_ms"] is None else f"{r['first_ms']:.0f}"
    print(f"{label}: chunks={r['chunks']} bytes={r['bytes']} duration={r['seconds']:.2f}s first_ms={first} "
          f"total_ms={r['total_ms']:.0f} worst_wait_ms={r['worst_wait_ms']:.0f}" + (f" bad_stream={r['bad']}" if r["bad"] else ""))


def long_text(n=1200):
    unit = "今天天气不错，我们沿着海边开车，看看远处的山和近处的桥。"
    return (unit * (n // len(unit) + 1))[:n]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=None, help="scratch folder for the WAVs (default: a new temp folder)")
    ap.add_argument("--runs", default="a,b,c")
    args = ap.parse_args(argv)
    key = os.environ.get("DASHSCOPE_API_KEY", "")
    host = os.environ.get("DASHSCOPE_API_HOST", "")
    if not key or not host:
        print("set DASHSCOPE_API_KEY and DASHSCOPE_API_HOST in the environment", file=sys.stderr)
        return 2
    out = args.out or tempfile.mkdtemp(prefix="qwen_tts_check_")
    os.makedirs(out, exist_ok=True)
    runs = set(args.runs.split(","))
    conn = http.client.HTTPSConnection(host, timeout=60)
    print(f"host={host} model={MODEL} out={out}")
    if "a" in runs:
        for i in range(1, 11):
            r = run_once(conn, key, host, SHORT, DEFAULT_VOICE)
            show(f"(a) run {i}", r)
            if r.get("pcm"):
                write_wav(os.path.join(out, f"a_{i:02d}.wav"), r["pcm"])
    if "b" in runs:
        lo, hi, limit = 1, 1200, None
        r = run_once(conn, key, host, long_text(1200), DEFAULT_VOICE)
        show("(b) 1200 chars", r)
        if "error" not in r and not r["bad"]:
            limit = 1200
            write_wav(os.path.join(out, "b_1200.wav"), r["pcm"])
        else:
            while lo < hi:  # the longest length that still synthesizes
                mid = (lo + hi + 1) // 2
                ok = "error" not in (m := run_once(conn, key, host, long_text(mid), DEFAULT_VOICE)) and not m["bad"]
                lo, hi = (mid, hi) if ok else (lo, mid - 1)
            limit = lo
        print(f"(b) length limit: {'none found up to 1200' if limit == 1200 else limit} characters")
    if "c" in runs:
        for v in VOICES:
            r = run_once(conn, key, host, SHORT, v)
            show(f"(c) {v}", r)
            print(f"(c) {v}: {'works' if 'error' not in r and r['bytes'] else 'fails'}")
            if r.get("pcm"):
                write_wav(os.path.join(out, f"c_{v}.wav"), r["pcm"])
    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
