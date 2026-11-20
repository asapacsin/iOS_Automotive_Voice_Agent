# F-09b §14 eval inputs

- `before.json`: the app's instruction, tools and session-start notes at 265c989 (before the T-031q rewrite).
- `after.json`: the same at T-031q (four-part base instruction).

Both were written by `EVAL_EXPORT=<file> swift test --filter EvalExportTests` and hold the AskOrActEval and
complaint cases. Run on the PC (key with billing; the free tier allows 20 calls per model per day):

    python scripts\eval\ask_or_act.py specs\eval\before.json --model gemini-3.8-flash --yes --max-calls 400 --out before-out.json
    python scripts\eval\ask_or_act.py specs\eval\after.json  --model gemini-3.8-flash --yes --max-calls 400 --out after-out.json
