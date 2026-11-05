#!/usr/bin/env python3
"""F-04b §5 item 5, §8 row 10 (T-013e): false accept / false reject rates and score spread of the speaker model on
a folder of labelled clips, with the same model the app bundles, through the sherpa-onnx Python package.

Layout: <clips>/<speaker>/*.wav, the folder name is the label. Clips must be 16 kHz mono PCM WAV (8/16/24/32-bit).
Anything else is rejected, not resampled, so the scores come from the same audio format the app feeds the model;
convert first, e.g. `ffmpeg -i in.wav -ar 16000 -ac 1 out.wav`.

Per speaker, the first --enroll clips (sorted by name) are enrollment: their embeddings are unit-normalised,
averaged and unit-normalised again (as SpeakerScore.average in NovaPorts). For each enrolled speaker (target), its
other clips are genuine trials and every other speaker's non-enrollment clips are impostor trials. A trial's score
is the cosine of the target profile and the clip's embedding; it is accepted when score >= threshold (as the app).

Without --threshold it prints the 0.01-grid table the app's 校准 shows and the lowest threshold with no false
accepts. --trial-seconds N scores only the first N s of each trial clip (the app scores at minVerifySpeech, 1.0 s).

Usage: python3 scripts/speaker_eval.py --model <campplus.onnx> --clips <dir> [--enroll 3] [--threshold 0.5]
       [--trial-seconds 1.0] [--out result.json]
Needs: pip install sherpa-onnx (imported only when scoring). No audio belongs in this repo (F-04b §5 item 5).
"""
from __future__ import annotations

import argparse
import json
import math
import pathlib
import statistics
import sys
import wave
from dataclasses import dataclass

SAMPLE_RATE = 16000
STEP = 0.01          # SpeakerCalibration.step
CONFIDENCE = 0.95


# ---- pure scoring math (unit-tested without the model) ----

def cosine(a: list[float], b: list[float]) -> float | None:
    """Cosine similarity; None when the lengths differ or a vector is zero (as SpeakerScore.cosine)."""
    if len(a) != len(b) or not a:
        return None
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0 or nb == 0:
        return None
    return dot / (na * nb)


def unit_average(vectors: list[list[float]]) -> list[float] | None:
    """Unit-length average of unit-normalised vectors; None when empty, mismatched or zero (SpeakerScore.average)."""
    if not vectors or not vectors[0] or any(len(v) != len(vectors[0]) for v in vectors):
        return None
    total = [0.0] * len(vectors[0])
    for v in vectors:
        norm = math.sqrt(sum(x * x for x in v))
        if norm == 0:
            return None
        for i, x in enumerate(v):
            total[i] += x / norm
    norm = math.sqrt(sum(x * x for x in total))
    if norm == 0:
        return None
    return [x / norm for x in total]


def split_enroll(clips: dict[str, list[str]], n: int) -> tuple[dict[str, list[str]], dict[str, list[str]]]:
    """First n clips per speaker (sorted) are enrollment, the rest are trials. Speakers with fewer than n are errors."""
    if n < 1:
        raise ValueError("--enroll must be at least 1")
    short = sorted(s for s, c in clips.items() if len(c) < n)
    if short:
        raise ValueError(f"fewer than {n} clips for: {', '.join(short)}")
    enroll, test = {}, {}
    for speaker, names in clips.items():
        ordered = sorted(names)
        enroll[speaker], test[speaker] = ordered[:n], ordered[n:]
    return enroll, test


@dataclass(frozen=True)
class Trial:
    target: str
    speaker: str
    clip: str
    score: float

    @property
    def genuine(self) -> bool:
        return self.target == self.speaker


def build_trials(profiles: dict[str, list[float]], test: dict[str, list[str]],
                 embeddings: dict[str, list[float]]) -> list[Trial]:
    """Every enrolled target against every non-enrollment clip: same speaker genuine, other speakers impostor."""
    trials = []
    for target in sorted(profiles):
        for speaker in sorted(test):
            for clip in test[speaker]:
                score = cosine(profiles[target], embeddings[clip])
                if score is None:
                    raise ValueError(f"no score for {clip} against {target}")
                trials.append(Trial(target, speaker, clip, score))
    return trials


def grid(v: float) -> float:
    return round(round(v / STEP) * STEP, 10)


def counts_at(genuine: list[float], impostor: list[float], t: float) -> tuple[int, int]:
    """(false rejects, false accepts) at threshold t; accepted when score >= t."""
    return sum(1 for s in genuine if s < t), sum(1 for s in impostor if s >= t)


def threshold_rows(genuine: list[float], impostor: list[float]) -> list[tuple[float, int, int]]:
    """(threshold, FR, FA) from the lowest score to one step above the highest, on the grid (SpeakerCalibration.rows)."""
    scores = genuine + impostor
    if not scores:
        return []
    t, hi, rows = grid(math.floor(min(scores) / STEP) * STEP), max(scores), []
    while t <= hi + STEP + 1e-9:
        rows.append((t, *counts_at(genuine, impostor, t)))
        t = grid(t + STEP)
    return rows


def suggested_threshold(impostor: list[float]) -> float | None:
    """The lowest grid point strictly above every impostor score (SpeakerCalibration.suggested)."""
    if not impostor:
        return None
    hi = max(impostor)
    t = grid(math.floor(hi / STEP) * STEP)
    while t <= hi:
        t = grid(t + STEP)
    return t


def upper_bound_zero(n: int) -> float:
    """95% upper bound of the true rate when 0 of n happened: 1 - 0.05^(1/n)."""
    return 1 - (1 - CONFIDENCE) ** (1 / n) if n > 0 else 1.0


def _binom_cdf(k: int, n: int, p: float) -> float:
    if p <= 0:
        return 1.0
    if p >= 1:
        return 1.0 if k >= n else 0.0
    lp, lq = math.log(p), math.log1p(-p)
    return min(1.0, sum(math.exp(math.lgamma(n + 1) - math.lgamma(i + 1) - math.lgamma(n - i + 1) + i * lp
                                 + (n - i) * lq) for i in range(k + 1)))


def upper_bound(k: int, n: int) -> float:
    """One-sided 95% exact (Clopper-Pearson) upper bound of the true rate when k of n happened."""
    if n <= 0 or k >= n:
        return 1.0
    if k == 0:
        return upper_bound_zero(n)
    lo, hi = k / n, 1.0
    for _ in range(100):
        mid = (lo + hi) / 2
        if _binom_cdf(k, n, mid) > 1 - CONFIDENCE:
            lo = mid
        else:
            hi = mid
    return hi


def spread(scores: list[float]) -> dict:
    if not scores:
        return {"n": 0}
    return {"n": len(scores), "mean": statistics.fmean(scores),
            "std": statistics.stdev(scores) if len(scores) > 1 else 0.0, "min": min(scores), "max": max(scores)}


def equal_error(genuine: list[float], impostor: list[float]) -> tuple[float, float] | None:
    """(threshold, rate) on the grid where FR rate and FA rate are closest; their mean is the rate."""
    if not genuine or not impostor:
        return None
    best = None
    for t, fr, fa in threshold_rows(genuine, impostor):
        frr, far = fr / len(genuine), fa / len(impostor)
        if best is None or abs(frr - far) < best[0]:
            best = (abs(frr - far), t, (frr + far) / 2)
    return best[1], best[2]


def summarize(trials: list[Trial], threshold: float | None) -> dict:
    genuine = [t.score for t in trials if t.genuine]
    impostor = [t.score for t in trials if not t.genuine]
    chosen = threshold if threshold is not None else suggested_threshold(impostor)
    out = {"genuine": spread(genuine), "impostor": spread(impostor),
           "threshold": chosen, "threshold_source": "given" if threshold is not None else "lowest with 0 false accepts"}
    if chosen is not None:
        fr, fa = counts_at(genuine, impostor, chosen)
        out["false_rejects"] = {"count": fr, "n": len(genuine), "rate": fr / len(genuine) if genuine else None,
                                "upper95": upper_bound(fr, len(genuine))}
        out["false_accepts"] = {"count": fa, "n": len(impostor), "rate": fa / len(impostor) if impostor else None,
                                "upper95": upper_bound(fa, len(impostor))}
    eer = equal_error(genuine, impostor)
    out["equal_error"] = {"threshold": eer[0], "rate": eer[1]} if eer else None
    per_target = {}
    for target in sorted({t.target for t in trials}):
        g = [t.score for t in trials if t.target == target and t.genuine]
        i = [t.score for t in trials if t.target == target and not t.genuine]
        per_target[target] = {"genuine_n": len(g), "genuine_min": min(g) if g else None,
                              "impostor_n": len(i), "impostor_max": max(i) if i else None}
    out["per_target"] = per_target
    return out


def _f(v: float | None, digits: int = 3) -> str:
    return "-" if v is None else f"{v:.{digits}f}"


def format_report(summary: dict, rows: list[tuple[float, int, int]] | None) -> str:
    lines = []
    for name in ("genuine", "impostor"):
        s = summary[name]
        lines.append(f"{name:8s} trials n={s['n']}" + ("" if not s["n"] else
                     f"  mean={_f(s['mean'])} std={_f(s['std'])} min={_f(s['min'])} max={_f(s['max'])}"))
    lines.append("")
    lines.append("per target: genuine n / lowest genuine score | impostor n / highest impostor score")
    for target, p in summary["per_target"].items():
        lines.append(f"  {target}: {p['genuine_n']} / {_f(p['genuine_min'])} | {p['impostor_n']} / {_f(p['impostor_max'])}")
    if rows is not None:
        lines.append("")
        lines.append("threshold  false-rejects  false-accepts   (accepted when score >= threshold)")
        for t, fr, fa in rows:
            lines.append(f"  {t:6.2f}   {fr:6d}        {fa:6d}")
    lines.append("")
    if summary["threshold"] is None:
        lines.append("no impostor trials: no threshold can be suggested")
    else:
        lines.append(f"threshold {summary['threshold']:.2f} ({summary['threshold_source']})")
        for key, label in (("false_rejects", "false reject"), ("false_accepts", "false accept")):
            c = summary[key]
            rate = "-" if c["rate"] is None else f"{c['rate'] * 100:.2f}%"
            bound = f"{c['upper95'] * 100:.2f}%"
            note = f" (0 of {c['n']}: true rate could still be up to 1-0.05^(1/n) = {bound})" if c["count"] == 0 \
                else f" (95% upper bound {bound})"
            lines.append(f"  {label}: {c['count']} of {c['n']} = {rate}{note}")
    if summary["equal_error"]:
        e = summary["equal_error"]
        lines.append(f"equal error rate about {e['rate'] * 100:.2f}% at threshold {e['threshold']:.2f}")
    lines.append("note: trials share clips and profiles, so they are not independent; the bounds assume they are and "
                 "are optimistic." + (" The threshold is chosen on these same trials."
                                      if summary["threshold_source"] != "given" else ""))
    return "\n".join(lines)


# ---- audio and model (not needed by the unit tests) ----

class WavError(ValueError):
    pass


def read_wav(path: pathlib.Path, max_seconds: float | None = None) -> list[float]:
    """16 kHz mono PCM WAV as floats in [-1, 1); anything else raises WavError (no resampling)."""
    try:
        with wave.open(str(path), "rb") as w:
            rate, channels, width, frames = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
            if rate != SAMPLE_RATE or channels != 1:
                raise WavError(f"{path}: {rate} Hz, {channels} channel(s); need {SAMPLE_RATE} Hz mono")
            if max_seconds is not None:
                frames = min(frames, int(round(max_seconds * SAMPLE_RATE)))
            data = w.readframes(frames)
    except wave.Error as e:
        raise WavError(f"{path}: not a PCM WAV ({e})") from e
    if width == 1:
        return [(b - 128) / 128.0 for b in data]
    if width not in (2, 3, 4):
        raise WavError(f"{path}: {width * 8}-bit samples not supported")
    scale = float(1 << (8 * width - 1))
    return [int.from_bytes(data[i:i + width], "little", signed=True) / scale for i in range(0, len(data), width)]


def list_clips(root: pathlib.Path) -> dict[str, list[str]]:
    """{speaker: [clip paths relative to root]} from <root>/<speaker>/*.wav."""
    clips = {}
    for d in sorted(p for p in root.iterdir() if p.is_dir()):
        wavs = sorted(str(p.relative_to(root)) for p in d.iterdir() if p.is_file() and p.suffix.lower() == ".wav")
        if wavs:
            clips[d.name] = wavs
    return clips


def make_embedder(model: pathlib.Path, threads: int):
    import sherpa_onnx  # lazy: the unit tests and --help need no sherpa-onnx

    config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(model), num_threads=threads, provider="cpu")
    if not config.validate():
        raise SystemExit(f"speaker_eval: invalid model config for {model}")
    extractor = sherpa_onnx.SpeakerEmbeddingExtractor(config)

    def embed(samples: list[float]) -> list[float] | None:
        stream = extractor.create_stream()
        stream.accept_waveform(SAMPLE_RATE, samples)
        stream.input_finished()
        if not extractor.is_ready(stream):
            return None
        return list(extractor.compute(stream))

    return embed, extractor.dim


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--model", required=True, type=pathlib.Path, help="speaker embedding .onnx (the bundled CAM++)")
    ap.add_argument("--clips", required=True, type=pathlib.Path, help="folder of <speaker>/*.wav")
    ap.add_argument("--enroll", type=int, default=3, help="enrollment clips per speaker, first N by name (default 3)")
    ap.add_argument("--threshold", type=float, help="report at this threshold; else the table and the suggestion")
    ap.add_argument("--trial-seconds", type=float, help="score only the first N s of each trial clip")
    ap.add_argument("--threads", type=int, default=1)
    ap.add_argument("--out", type=pathlib.Path, help="write the summary and every trial score as JSON")
    args = ap.parse_args(argv)

    clips = list_clips(args.clips)
    if len(clips) < 2:
        print(f"speaker_eval: need at least 2 speaker folders in {args.clips}, found {len(clips)}", file=sys.stderr)
        return 2
    try:
        enroll, test = split_enroll(clips, args.enroll)
    except ValueError as e:
        print(f"speaker_eval: {e}", file=sys.stderr)
        return 2
    audio, bad = {}, []
    for speaker in clips:
        for clip in enroll[speaker] + test[speaker]:
            try:
                limit = args.trial_seconds if clip in test[speaker] else None
                audio[clip] = read_wav(args.clips / clip, limit)
            except WavError as e:
                bad.append(str(e))
    if bad:
        print("speaker_eval: rejected (not resampled; convert to 16 kHz mono PCM WAV):\n  " + "\n  ".join(bad),
              file=sys.stderr)
        return 2

    embed, dim = make_embedder(args.model, args.threads)
    embeddings = {}
    for clip, samples in audio.items():
        vector = embed(samples)
        if vector is None:
            print(f"speaker_eval: model not ready on {clip} (too short?)", file=sys.stderr)
            return 2
        embeddings[clip] = vector
    profiles = {}
    for speaker, names in enroll.items():
        profile = unit_average([embeddings[c] for c in names])
        if profile is None:
            print(f"speaker_eval: no profile for {speaker}", file=sys.stderr)
            return 2
        profiles[speaker] = profile
    trials = build_trials(profiles, test, embeddings)
    summary = summarize(trials, args.threshold)
    genuine = [t.score for t in trials if t.genuine]
    impostor = [t.score for t in trials if not t.genuine]
    rows = threshold_rows(genuine, impostor) if args.threshold is None else None

    seconds = lambda names: sum(len(audio[c]) for c in names) / SAMPLE_RATE  # noqa: E731
    print(f"model {args.model.name} (dim {dim}); clips {args.clips}")
    print(f"speakers {len(clips)}; enrollment {args.enroll} clips each; trial audio "
          + (f"first {args.trial_seconds:g} s" if args.trial_seconds else "whole clip"))
    for speaker in clips:
        print(f"  {speaker}: enroll {len(enroll[speaker])} ({seconds(enroll[speaker]):.1f} s), "
              f"trials {len(test[speaker])} ({seconds(test[speaker]):.1f} s)")
    print()
    print(format_report(summary, rows))
    if args.out:
        record = {"model": args.model.name, "clips": str(args.clips), "enroll": args.enroll,
                  "trial_seconds": args.trial_seconds, "enrollment": enroll, "summary": summary,
                  "trials": [{"target": t.target, "clip": t.clip, "genuine": t.genuine, "score": t.score}
                             for t in trials]}
        args.out.write_text(json.dumps(record, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(f"\nwrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
