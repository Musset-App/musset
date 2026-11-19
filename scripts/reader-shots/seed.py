"""A fuller world for the pictures: three authors, three books, a second milestone, notes and a conversation."""
import json, sys, time, uuid, sqlite3, pathlib, urllib.request, urllib.error
from base64 import b64encode
S = pathlib.Path(sys.argv[1]); FORGEJO = "http://127.0.0.1:3939/api/v1"; API = "http://127.0.0.1:3941"
def call(method, url, body=None, token=None, basic=None):
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Content-Type", "application/json")
    if token: req.add_header("Authorization", "token " + token)
    if basic: req.add_header("Authorization", "Basic " + b64encode(f"{basic[0]}:{basic[1]}".encode()).decode())
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            t = r.read(); return r.status, (json.loads(t) if t[:1] in b"[{" else t)
    except urllib.error.HTTPError as e:
        t = e.read()
        try: return e.code, json.loads(t)
        except ValueError: return e.code, t
def ok(r, *codes):
    assert r[0] in (codes or (200, 201)), r; return r[1]
admin = (S / "secrets" / "admin-token").read_text().strip()
def token(user, password):
    return ok(call("POST", f"{FORGEJO}/users/{user}/tokens", {"name": "seed-%d" % time.time_ns(), "scopes": ["all"]}, basic=(user, password)))["sha1"]
def account(email, password, name, guess):
    st, out = call("POST", API + "/signup", {"email": email, "password": password, "name": name, "device": "Mac", "lang": "en_US"})
    if st == 201: return out["username"], out["token"]
    return guess, token(guess, password)
def b64(s): return b64encode(s.encode()).decode()
def put(repo, tok, path, text, message, branch="main"):
    st, cur = call("GET", f"{FORGEJO}/repos/{repo}/contents/{path}?ref={branch}", token=tok)
    body = {"content": b64(text), "branch": branch, "message": message}
    if st == 200: body["sha"] = cur["sha"]
    ok(call("PUT" if st == 200 else "POST", f"{FORGEJO}/repos/{repo}/contents/{path}", body, token=tok))

mara, mtok = "mara", token("mara", "author-pass-1234")
claire, ctok = "claire", token("claire", "reader-pass-1234")
ok(call("PATCH", f"{FORGEJO}/admin/users/{mara}", {"login_name": mara, "source_id": 0, "full_name": "Mara Lindqvist"}, token=admin))
ok(call("PATCH", f"{FORGEJO}/admin/users/{claire}", {"login_name": claire, "source_id": 0, "full_name": "Claire Morel"}, token=admin))
repo = "mara/the-salt-road"
demo = json.load(open("MussetTests/SiteDemo/en.json", encoding="utf-8"))
first = demo["chapters"][0]["text"]

# Two more authors, each with a book and a milestone, shared with Claire.
others = [
 ("tomas@example.test", "Tomás Ferreira", "tomas", "the-glassblowers-daughter", "The Glassblower’s Daughter", "beta-reader", "reader",
  "You said you wanted the Lisbon chapters first. Here they are.",
  "# The Furnace\n\nMy father never let the furnace go out. Not on Sundays, not the week my mother died, not during the strike, when he carried the coal up from the river himself, two sacks at a time, so that nobody could say he had crossed a line.\n\nGlass forgives nothing, he used to say. He meant it kindly.\n"),
 ("ines@example.test", "Ines Auclair", "ines", "small-hours", "Small Hours", "publisher", "reader",
  "The whole manuscript, as promised. No hurry.",
  "# Night Shift\n\nAt three in the morning the hospital belongs to the people who clean it. Odile knew every corridor by the sound her trolley made on its floor.\n\nShe was not supposed to read the charts. She read the charts.\n"),
]
names = {}
for email, name, guess, slug, title, relation, role, message, text in others:
    user, tok = account(email, "author-pass-1234", name, guess)
    names[user] = name
    comp = S / "secrets" / "comp-users"
    if user not in comp.read_text().split(): comp.write_text(comp.read_text().rstrip("\n") + "\n" + user + "\n")
    ok(call("PATCH", f"{FORGEJO}/admin/users/{user}", {"login_name": user, "source_id": 0, "max_repo_creation": -1}, token=admin))
    r = f"{user}/{slug}"
    st, out = call("POST", FORGEJO + "/user/repos", {"name": slug, "description": title, "private": True, "auto_init": True, "default_branch": "main"}, token=tok)
    if st == 201:
        put(r, tok, "01.md", text, "musset: chapter")
        put(r, tok, ".musset/book.json", json.dumps({"title": title, "author": name, "lang": "en", "chapters": [{"id": "01", "file": "01.md", "title": text.split("\n")[0][2:]}]}, ensure_ascii=False, indent=1), "musset: new book")
        ok(call("POST", f"{FORGEJO}/repos/{r}/tags", {"tag_name": "jalon/first-draft", "message": "First draft", "target": "main"}, token=tok))
        ok(call("POST", API + "/invite", {"username": claire, "repo": r, "role": role, "relation": relation, "book": title, "lang": "en", "tag": "jalon/first-draft", "message": message}, token=tok))

# The Salt Road gets a second milestone, without the sentence only the author's desk has.
st, tags = call("GET", f"{FORGEJO}/repos/{repo}/tags", token=mtok)
if not any(t["name"] == "jalon/second-draft" for t in tags):
    put(repo, mtok, "01.md", first, "musset: edit 01")
    ok(call("POST", f"{FORGEJO}/repos/{repo}/tags", {"tag_name": "jalon/second-draft", "message": "Second draft", "target": "main"}, token=mtok))
    put(repo, mtok, "01.md", first.rstrip() + "\n\nONLY ON THE AUTHOR'S DESK: this sentence was written after the milestone.\n", "musset: edit 01")
    ok(call("POST", API + "/reading", {"repo": repo, "username": claire, "tag": "jalon/second-draft"}, token=mtok))
    ok(call("POST", API + "/notify", {"repo": repo, "kind": "milestone", "recipients": [claire], "tag": "Second draft", "book": demo["title"], "message": "I rewrote the crossing. Tell me if Tom is still too cold."}, token=mtok))

# Claire's notes on chapter one, on her branch; the author's answer, on main.
u16 = lambda s: len(s.encode("utf-16-le")) // 2
def anchor(quote):
    i = first.index(quote); start = u16(first[:i])
    return {"quote": quote, "prefix": first[max(0, i - 32):i], "suffix": first[i + len(quote):i + len(quote) + 32], "start": start}
def entry(id, thread, kind, by, at, body="", quote=None, mark=None):
    e = {"id": id, "thread": thread, "kind": kind, "by": by, "at": at, "body": body, "chapter": "01"}
    if quote: e.update(anchor=anchor(quote), mark=mark, color=0, milestone="jalon/second-draft")
    return e
U = lambda n: str(uuid.uuid5(uuid.NAMESPACE_URL, "musset-shots-%d" % n)).upper()
now = int(time.time())
iso = lambda ago: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - ago))
H = 3600
mine = [
 entry(U(1), U(1), "note", claire, iso(26 * H), "This is where I understood he was gone. Don’t touch it.", "as if he might still ask for it", "margin"),
 entry(U(2), U(2), "note", claire, iso(26 * H - 300), "", "none of them survived the wind", "highlight"),
 entry(U(3), U(3), "note", claire, iso(26 * H - 600), "→ their mother’s funeral", "the funeral of their mother", "strike"),
 entry(U(5), U(1), "reply", claire, iso(20 * H), "Then it stays. It does more than the whole first page of the old draft."),
]
theirs = [
 entry(U(4), U(1), "reply", mara, iso(22 * H), "It came last, and I nearly cut it. I was afraid it explained too much."),
 entry(U(6), U(1), "reply", mara, iso(2 * H), "Staying. Does the brother need a line this early, or do we wait for the island?"),
]
st, branches = call("GET", f"{FORGEJO}/repos/{repo}/branches", token=ctok)
if not any(b["name"] == "relecture/claire" for b in branches):
    ok(call("POST", f"{FORGEJO}/repos/{repo}/branches", {"new_branch_name": "relecture/claire", "old_branch_name": "main"}, token=ctok))
dump = lambda l: json.dumps(l, ensure_ascii=False, indent=2, sort_keys=True)
put(repo, ctok, ".musset/talk/claire/01.json", dump(mine), "musset: notes by claire", branch="relecture/claire")
put(repo, mtok, ".musset/talk/mara/01.json", dump(theirs), "musset: notes by mara")

# What happened, spread over a few days, the newest unread.
con = sqlite3.connect(S / "state" / "musset.db")
con.execute("DELETE FROM activity WHERE username = ? AND kind = 'reply'", (claire,))
con.execute("INSERT INTO activity (username, actor, kind, repo, thread, chapter, title, message, at) VALUES (?,?,?,?,?,?,?,?,?)",
            (claire, mara, "reply", repo, U(1), "01", demo["title"], theirs[1]["body"], now - 2 * H))
when = {("shared", repo): 9 * 86400, ("milestone", repo): 27 * H}
for i, (user, name) in enumerate(names.items()):
    con.execute("UPDATE activity SET at = ?, read = ? WHERE username = ? AND actor = ? AND kind = 'shared'", (now - (5 * H if i else 3 * 86400), 0 if i else 1, claire, user))
    con.execute("UPDATE circle SET name = ? WHERE owner = ? AND member = ?", (name, claire, user))
for (kind, r), ago in when.items():
    con.execute("UPDATE activity SET at = ?, read = 1 WHERE username = ? AND kind = ? AND repo = ?", (now - ago, claire, kind, r))
con.commit()
print(con.execute("SELECT actor, kind, title, tag, read, at FROM activity WHERE username = ? ORDER BY at DESC", (claire,)).fetchall())
print(con.execute("SELECT * FROM circle WHERE owner = ?", (claire,)).fetchall())
print(con.execute("SELECT * FROM reading").fetchall())
