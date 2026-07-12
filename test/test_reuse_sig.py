import json, pathlib, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
cfg = json.loads((ROOT / "tabbit_config.json").read_text(encoding="utf-8"))
cap = json.loads((ROOT / "fresh_capture.json").read_text(encoding="utf-8"))
from curl_cffi import requests as cureq

questions = ["What is 7*6?", "Capital of France?", "Say hello in Japanese (one word)"]
for q in questions:
    body = json.dumps({
        "chat_session_id": "a37d55c4-aecf-47bc-a386-14a0a1078df8",
        "message_id": None, "content": q,
        "selected_model": "Claude-Opus-4.8", "parallel_group_id": None,
        "task_name": "chat", "agent_mode": False,
        "metadatas": {"html_content": f"<p>{q}</p>"}, "references": [],
        "entity": {"key": "d41d8cd98f00b204e9800998ecf8427e", "extras": {"type": "tab", "url": ""}},
    }, separators=(",", ":"))
    r = cureq.post(cap["url"], data=body.encode("utf-8"),
                   headers=dict(cap["headers"]), cookies=cfg["cookies"],
                   impersonate="chrome124", stream=True, timeout=30)
    print(f"Q: {q}")
    text = ""
    err = None
    for line in r.iter_lines():
        if isinstance(line, bytes):
            line = line.decode("utf-8", errors="replace")
        if line.startswith('data: {"content":'):
            try: text += json.loads(line[6:])["content"]
            except: pass
        if '"code": 492' in line or '"code": 493' in line:
            err = line[:200]
    if err:
        print(f"  ERR: {err}")
    else:
        print(f"  A: {text[:150]}")
    print()
