#!/usr/bin/env python3
"""F-04b §16 item 1 (T-013j): the AS-norm cohort and the EER threshold for the speaker lock, from CN-Celeb1.

Cohort: every CN-Celeb1 dev speaker's utterances are embedded with the app's model, each embedding unit-normalised,
averaged per speaker and unit-normalised again (one averaged embedding per training speaker, as the WeSpeaker CNSRC
2022 system). Threshold: the equal error rate point of the AS-norm score (§16 item 2, top_n 300 as the WeSpeaker
recipe) over the CN-Celeb1 test trials.

Writes <out>/speaker_cohort.f32 (speakers x dim float32 little-endian, sorted speaker id) and
<out>/speaker_cohort.json. Refuses and writes nothing when the model sha256 is not the pinned one or fewer than
--min-speakers dev speakers are found.

Usage: python3 scripts/speaker_cohort.py --data <CN-Celeb_flac dir> --model <campplus.onnx> --out <dir>
       [--threads 8] [--top-n 300] [--min-speakers 300] [--cache <dir>]
Needs: pip install sherpa-onnx numpy soundfile. Audio (CC BY-SA 4.0, OpenSLR 82) never goes in the repo.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys
import time

import numpy as np

SAMPLE_RATE = 16000
REPO = pathlib.Path(__file__).resolve().parent.parent
PIN_FILE = REPO / "scripts" / "sherpa" / "models.sha256"
MODEL_NAME = "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced"


# ---- pure math (unit-tested without the model) ----

def unit(v: np.ndarray) -> np.ndarray:
    n = np.linalg.norm(v, axis=-1, keepdims=True)
    return v / np.where(n == 0, 1, n)


def speaker_mean(embeddings: np.ndarray) -> np.ndarray:
    """Unit-length average of unit-normalised embeddings (as SpeakerScore.average)."""
    return unit(unit(embeddings).mean(axis=0))


def cohort_stats(x: np.ndarray, cohort: np.ndarray, top_n: int) -> tuple[np.ndarray, np.ndarray]:
    """Mean and population std of the top_n largest cosines of each row of x against the cohort."""
    s = unit(x) @ unit(cohort).T
    k = min(top_n, cohort.shape[0])
    top = -np.sort(-s, axis=1)[:, :k]
    return top.mean(axis=1), top.std(axis=1)


def as_norm(e: np.ndarray, t: np.ndarray, cohort: np.ndarray, top_n: int) -> float:
    """§16 item 2: 0.5*((s-mu_e)/sd_e + (s-mu_t)/sd_t), s = cos(e, t)."""
    s = float(unit(e) @ unit(t))
    me, se = cohort_stats(e[None, :], cohort, top_n)
    mt, st = cohort_stats(t[None, :], cohort, top_n)
    return 0.5 * ((s - me[0]) / se[0] + (s - mt[0]) / st[0])


def eer(scores: np.ndarray, labels: np.ndarray) -> tuple[float, float]:
    """Equal error rate and the threshold where false accept and false reject cross (accept when score >= t)."""
    order = np.argsort(-scores)
    s, y = scores[order], labels[order].astype(bool)
    tp = np.cumsum(y)
    fp = np.cumsum(~y)
    n_t, n_n = y.sum(), (~y).sum()
    frr = 1 - tp / n_t
    far = fp / n_n
    i = int(np.argmin(np.abs(frr - far)))
    return float((frr[i] + far[i]) / 2), float(s[i])


def pinned_sha() -> str:
    for line in PIN_FILE.read_text().splitlines():
        if line.strip().endswith(f"speaker/{MODEL_NAME}.onnx"):
            return line.split()[0]
    raise SystemExit("speaker_cohort: model not listed in scripts/sherpa/models.sha256")


def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---- model ----

def make_embedder(model: pathlib.Path, threads: int):
    import sherpa_onnx
    import soundfile

    config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(model), num_threads=threads, provider="cpu")
    if not config.validate():
        raise SystemExit(f"speaker_cohort: invalid model config for {model}")
    extractor = sherpa_onnx.SpeakerEmbeddingExtractor(config)

    def embed(path: pathlib.Path) -> np.ndarray | None:
        audio, sr = soundfile.read(str(path), dtype="float32", always_2d=True)
        if sr != SAMPLE_RATE:
            raise SystemExit(f"speaker_cohort: {path} is {sr} Hz, expected {SAMPLE_RATE}")
        stream = extractor.create_stream()
        stream.accept_waveform(SAMPLE_RATE, audio[:, 0])
        stream.input_finished()
        if not extractor.is_ready(stream):
            return None
        return np.asarray(extractor.compute(stream), dtype=np.float32)

    return embed, extractor.dim


_EMBED = None


def _init_worker(model: str, threads: int) -> None:
    global _EMBED
    _EMBED, _ = make_embedder(pathlib.Path(model), threads)


def _work(path: str):
    return path, _EMBED(pathlib.Path(path))


def embed_all(paths: list[pathlib.Path], model: pathlib.Path, cache: pathlib.Path | None, tag: str,
              workers: int, threads: int) -> dict[str, np.ndarray]:
    import multiprocessing as mp

    store = cache / f"{tag}.npz" if cache else None
    done: dict[str, np.ndarray] = dict(np.load(store)) if store and store.exists() else {}
    t0, todo = time.time(), [p.as_posix() for p in paths if p.as_posix() not in done]
    if todo:
        with mp.Pool(workers, initializer=_init_worker, initargs=(str(model), threads)) as pool:
            for i, (p, v) in enumerate(pool.imap_unordered(_work, todo, chunksize=16), 1):
                if v is not None:
                    done[p] = v
                if i % 5000 == 0 or i == len(todo):
                    print(f"{tag}: {i}/{len(todo)} {time.time() - t0:.0f}s", flush=True)
                    if store:
                        np.savez(store, **done)
    return done


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--data", type=pathlib.Path, required=True)
    ap.add_argument("--model", type=pathlib.Path, required=True)
    ap.add_argument("--out", type=pathlib.Path, required=True)
    ap.add_argument("--threads", type=int, default=1)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--top-n", type=int, default=300)
    ap.add_argument("--min-speakers", type=int, default=300)
    ap.add_argument("--cache", type=pathlib.Path)
    a = ap.parse_args(argv)

    sha = sha256(a.model)
    if sha != pinned_sha():
        print(f"speaker_cohort: model sha256 {sha} is not the pinned one; nothing written", file=sys.stderr)
        return 1
    dev_list = (a.data / "dev" / "dev.lst").read_text().split()
    speakers = sorted(set(dev_list))
    if len(speakers) < a.min_speakers:
        print(f"speaker_cohort: {len(speakers)} dev speakers < {a.min_speakers}; nothing written", file=sys.stderr)
        return 1
    if a.cache:
        a.cache.mkdir(parents=True, exist_ok=True)
    _, dim = make_embedder(a.model, 1)

    dev_paths = {s: sorted((a.data / "data" / s).glob("*.flac")) + sorted((a.data / "data" / s).glob("*.wav"))
                 for s in speakers}
    dev = embed_all([p for ps in dev_paths.values() for p in ps], a.model, a.cache, "dev", a.workers, a.threads)
    cohort = np.stack([speaker_mean(np.stack([dev[p.as_posix()] for p in dev_paths[s] if p.as_posix() in dev]))
                       for s in speakers]).astype(np.float32)

    ev = a.data / "eval"
    trials = [line.split() for line in (ev / "lists" / "trials.lst").read_text().splitlines() if line.strip()]
    enroll_ids = sorted({t[0] for t in trials})
    test_ids = sorted({t[1] for t in trials})

    def enroll_path(i: str) -> pathlib.Path:
        stem = pathlib.Path(i).stem
        for ext in (".flac", ".wav"):
            p = ev / "enroll" / (stem + ext)
            if p.exists():
                return p
        raise SystemExit(f"speaker_cohort: enrollment audio for {i} not found")

    def test_path(i: str) -> pathlib.Path:
        p = ev / i
        if p.exists():
            return p
        alt = p.with_suffix(".flac")
        if alt.exists():
            return alt
        raise SystemExit(f"speaker_cohort: test audio {i} not found")

    enr = embed_all([enroll_path(i) for i in enroll_ids], a.model, a.cache, "enroll", a.workers, a.threads)
    tst = embed_all([test_path(i) for i in test_ids], a.model, a.cache, "test", a.workers, a.threads)
    e_ok = [i for i in enroll_ids if enroll_path(i).as_posix() in enr]
    t_ok = [i for i in test_ids if test_path(i).as_posix() in tst]
    E = unit(np.stack([enr[enroll_path(i).as_posix()] for i in e_ok]))
    T = unit(np.stack([tst[test_path(i).as_posix()] for i in t_ok]))
    me, se = cohort_stats(E, cohort, a.top_n)
    mt, st = cohort_stats(T, cohort, a.top_n)
    ei = {i: k for k, i in enumerate(e_ok)}
    ti = {i: k for k, i in enumerate(t_ok)}
    kept = [t for t in trials if t[0] in ei and t[1] in ti]
    a_idx = np.array([ei[t[0]] for t in kept])
    b_idx = np.array([ti[t[1]] for t in kept])
    labels = np.array([t[2] in ("1", "target") for t in kept])
    raw = np.einsum("ij,ij->i", E[a_idx], T[b_idx])
    norm = 0.5 * ((raw - me[a_idx]) / se[a_idx] + (raw - mt[b_idx]) / st[b_idx])
    rate, threshold = eer(norm, labels)
    raw_rate, raw_threshold = eer(raw, labels)

    a.out.mkdir(parents=True, exist_ok=True)
    (a.out / "speaker_cohort.f32").write_bytes(cohort.astype("<f4").tobytes())
    meta = {
        "source": "CN-Celeb1 dev (OpenSLR 82)", "license": "CC BY-SA 4.0", "model": MODEL_NAME,
        "modelSha256": sha, "speakers": len(speakers), "dimension": int(dim), "topN": a.top_n,
        "threshold": round(threshold, 4), "eer": round(rate, 4), "trials": len(kept),
        "skippedTrials": len(trials) - len(kept), "rawCosineEer": round(raw_rate, 4),
        "rawCosineEerThreshold": round(raw_threshold, 4),
    }
    (a.out / "speaker_cohort.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
