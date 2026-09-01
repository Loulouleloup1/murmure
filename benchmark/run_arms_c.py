"""Run each candidate over the prompt-mode corpus. One model resident at a time, never two.

Wire shapes are copied from production, not approximated: OllamaS1 for the s1 dialect
(/api/generate, raw, prefilled empty <think>, temp 0, repeat_penalty 1.1, num_ctx 4096,
truncate false) and OllamaChat for the chat dialect (/api/chat, think:false, temp 0,
num_ctx 8192). A latency measured under different options is a latency for a different app.
"""
import json, subprocess, sys, time, urllib.request

BASE = "http://localhost:11434"
SEED = 20_260_901
S1_SYSTEM = (
    "You are a text normalizer for speech-to-text transcripts. The input begins with a "
    "control line specifying the styling, structure, and context settings; clean the "
    "transcript to match those settings and output only the cleaned text."
)
STRUCT = open("benchmark/struct_prompt_c.txt").read().strip()

ARMS = {
    "s1-control": dict(model="hf.co/superwhisper/s1-mini-GGUF:Q4_K_M", api="s1",
                       instructions="[Context: general]"),
    "e2b-struct": dict(model="gemma4:e2b-it-qat", api="chat", instructions=STRUCT),
    "12b-struct": dict(model="gemma4:12b-it-qat", api="chat", instructions=STRUCT),
}


def post(path, body, timeout=600):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, json.loads(r.read())


def call(arm, transcript):
    a = ARMS[arm]
    if a["api"] == "s1":
        prompt = (f"<|im_start|>system\n{S1_SYSTEM}<|im_end|>\n"
                  f"<|im_start|>user\n{a['instructions']}\n{transcript}<|im_end|>\n"
                  "<|im_start|>assistant\n<think>\n\n</think>\n\n")
        body = dict(model=a["model"], prompt=prompt, raw=True, stream=False, truncate=False,
                    options=dict(temperature=0.0, repeat_penalty=1.1, seed=SEED,
                                 num_predict=2048, num_ctx=4096,
                                 stop=["<|im_end|>", "<|im_start|>"]))
        st, js = post("/api/generate", body)
        return st, js.get("response", ""), js
    body = dict(model=a["model"], stream=False, think=False,
                messages=[dict(role="system", content=a["instructions"]),
                          dict(role="user", content=transcript)],
                options=dict(temperature=0.0, seed=SEED, num_predict=2048, num_ctx=8192))
    st, js = post("/api/chat", body)
    return st, js.get("message", {}).get("content", ""), js


def rss_gb():
    out = subprocess.run(["bash", "-c", "ps -eo rss,comm | grep -i 'llama\\|ollama' | awk '{s+=$1} END {print s}'"],
                         capture_output=True, text=True).stdout.strip()
    return round(int(out or 0) / 1024 / 1024, 3)


def unload(model):
    try:
        post("/api/generate", dict(model=model, keep_alive=0), timeout=60)
    except Exception:
        pass
    time.sleep(3)


fixtures = [json.loads(l) for l in open("benchmark/fixtures-promptmode.local.jsonl")]
arm = sys.argv[1]
out = open(f"benchmark/results-promptmodeC-{arm}.local.jsonl", "w")
peak = 0.0
for i, fx in enumerate(fixtures):
    t0 = time.time()
    try:
        st, text, js = call(arm, fx["raw"])
        err = None
    except Exception as e:
        st, text, js, err = 0, "", {}, repr(e)
    dt = round(time.time() - t0, 3)
    peak = max(peak, rss_gb())
    out.write(json.dumps(dict(
        arm=arm, id=fx["id"], stratum=fx["stratum"], chars=fx["chars"], status=st,
        latency_s=dt, error=err, raw=fx["raw"], output=text,
        prompt_tokens=js.get("prompt_eval_count"), out_tokens=js.get("eval_count"),
        done_reason=js.get("done_reason")), ensure_ascii=False) + "\n")
    out.flush()
    print(f"{arm} {i+1}/{len(fixtures)} {fx['id']} {fx['stratum']} {dt}s status={st}", flush=True)
out.close()
print(f"PEAK_RSS_GB {peak}")
unload(ARMS[arm]["model"])
