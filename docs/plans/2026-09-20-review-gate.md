# Gate de complétion du kanban Murmure : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un script externe qui, pour chaque carte du board kanban `murmure` passée en `review`, reconstitue les preuves du run (tests lancés, résultat, fichiers modifiés), applique des règles déterministes, interroge Jev sur la seule question sémantique restante, et renvoie la carte au worker avec un motif quand la déclaration n'est pas étayée ; le même code rejoue l'historique (backfill) avant toute mise en service.

**Architecture:** Code déterministe (lecture SQLite des bases Hermes, git, log) → règles → fournisseur de décision derrière une interface (Jev via OpenRouter aujourd'hui) → politique en code → action via la CLI `hermes kanban reopen-review`. Trois modes : `backfill`, `shadow`, `enforce`. Audit JSONL par décision, snapshot des preuves figé avant jugement. Hermes lui-même n'est jamais modifié.

**Tech Stack:** Python 3.11 (venv Hermes `~/.hermes/hermes-agent/venv/bin/python`), `sqlite3`, `urllib`, `pyyaml` (présent dans le venv), `pytest` (à installer dans le venv), CLI `hermes`, `git`.

**Spec:** `docs/specs/2026-09-20-review-gate-design.md` (repo murmure). Le rapport TypeSafe de référence est `~/Documents/Codex_recherches/rapport_jev_typesafe_workflow_ia.md`.

## Global Constraints

- Le code vit dans `~/.hermes/scripts/review-gate/` (hors repo murmure). Ce dossier est initialisé comme dépôt git local à la tâche 0 ; tous les commits du plan s'y font. Le repo murmure ne reçoit que la documentation.
- Interdit de modifier quoi que ce soit sous `~/.hermes/hermes-agent/` et interdit d'importer `hermes_cli` depuis le script : lecture SQLite directe, écriture via la CLI `hermes` uniquement.
- Interdit de lire `~/Library/Application Support/Murmure/`, d'y référencer un chemin, ou de journaliser audio ou transcriptions.
- La clé OpenRouter est lue dans `~/.hermes/.env` (`OPENROUTER_API_KEY=`) au moment de l'appel, jamais stockée dans un attribut, jamais journalisée.
- Modèle pinné `typesafe/jev-1.13`, endpoint `https://openrouter.ai/api/alpha/decisions`. Jamais `jev-latest`.
- Chemin de la base kanban : `~/.hermes/kanban/boards/murmure/kanban.db`. Ignorer le fichier vide `murmure.db` voisin. Tous les horodatages des bases sont des secondes epoch (entiers dans `kanban.db`, flottants dans `state.db`).
- Interdit de créer ou d'éditer une carte avec `goal_mode = 1`.
- Mode par défaut dans `decisions.yaml` : `shadow`. Le passage à `enforce` est une décision de Louis, hors plan.
- Interpréteur : toujours via `run.sh` (venv 3.11). Tests : `~/.hermes/hermes-agent/venv/bin/python -m pytest` depuis `~/.hermes/scripts/review-gate/`.
- Toute sortie stderr de diagnostic est une ligne JSON `{"step": ..., "event": "start"|"end"|"error", "ms": ..., ...}`.

---

## Structure des fichiers

```
~/.hermes/scripts/review-gate/
  run.sh                exec venv python gate.py "$@"
  gate.py               CLI : modes shadow | enforce | backfill, --board --task --dry-run --force
  config.py             chargement de decisions.yaml, résolution du projet par chemin
  kanban.py             lecture kanban.db : demandes de revue, vérité terrain
  sessions.py           lien run → session, lecture des appels terminal et des éditions dans state.db
  evidence.py           EvidenceSnapshot : assemblage des faits (tests, git, fichiers), sauvegarde
  rules.py              R1–R5
  decide.py             DecisionProvider, JevOpenRouter, FakeProvider (tests)
  policy.py             règles + décision → Action + motif
  audit.py              decisions.jsonl, journal d'étapes stderr
  backfill.py           rejeu historique, rapport, dossiers de divergence
  decisions.yaml        registre versionné
  pytest.ini
  tests/
    conftest.py         fabriques de kanban.db et state.db de fixture, dépôt git temporaire
    test_config.py test_kanban.py test_sessions.py test_evidence.py test_rules.py
    test_decide.py test_policy.py test_audit.py test_gate.py test_backfill.py
  README.md
  snapshots/            créé à l'exécution
  backfill/             créé à l'exécution
```

Responsabilités : `kanban.py` et `sessions.py` ne font que lire des bases et rendre des dataclasses ; `evidence.py` compose ; `rules.py`, `policy.py` sont des fonctions pures ; `decide.py` est le seul module réseau ; `gate.py` et `backfill.py` orchestrent et sont les seuls à écrire (snapshots, audit, CLI hermes).

---

### Task 0 : Squelette, dépôt, pytest

**Files:**
- Create: `~/.hermes/scripts/review-gate/run.sh`, `pytest.ini`, `tests/conftest.py`, `tests/test_smoke.py`, `.gitignore`

**Interfaces:**
- Produces: fixtures pytest `kanban_db(tmp_path) -> Path`, `state_db(tmp_path) -> Path`, `git_repo(tmp_path) -> Path`, et helpers `insert_task`, `insert_run`, `insert_event`, `insert_session`, `insert_assistant_call`, `insert_tool_result` utilisés par toutes les tâches suivantes.

- [ ] **Step 1 : Créer le dossier, le dépôt git, installer pytest**

```bash
mkdir -p ~/.hermes/scripts/review-gate/tests && cd ~/.hermes/scripts/review-gate
git init -q
~/.hermes/hermes-agent/venv/bin/python -m pip install -q pytest
~/.hermes/hermes-agent/venv/bin/python -m pytest --version
```
Expected: `pytest 8.x`.

- [ ] **Step 2 : Écrire `run.sh`, `pytest.ini`, `.gitignore`**

`run.sh` :
```bash
#!/bin/bash
# Lance la gate avec l'interpreteur du venv Hermes (3.11). Toujours passer par ce script.
exec /Users/louiscourcier/.hermes/hermes-agent/venv/bin/python \
  /Users/louiscourcier/.hermes/scripts/review-gate/gate.py "$@"
```
`pytest.ini` :
```ini
[pytest]
testpaths = tests
markers =
    live: appelle le vrai fournisseur Jev (réseau, coût réel, désactivé par défaut)
addopts = -m "not live"
```
`.gitignore` :
```
snapshots/
backfill/
decisions.jsonl
__pycache__/
.pytest_cache/
```
```bash
chmod +x run.sh
```

- [ ] **Step 3 : Écrire `tests/conftest.py` avec les fabriques de bases**

```python
import json
import sqlite3
import subprocess
from pathlib import Path

import pytest

KANBAN_SCHEMA = """
CREATE TABLE tasks(
  id TEXT PRIMARY KEY, title TEXT, status TEXT, assignee TEXT,
  workspace_path TEXT, branch_name TEXT, current_run_id TEXT,
  session_id TEXT DEFAULT '', goal_mode INTEGER NOT NULL DEFAULT 0);
CREATE TABLE task_runs(
  id TEXT PRIMARY KEY, task_id TEXT, profile TEXT, status TEXT,
  started_at INTEGER, ended_at INTEGER, outcome TEXT, summary TEXT,
  metadata TEXT, error TEXT);
CREATE TABLE task_events(
  id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT, run_id TEXT,
  kind TEXT, payload TEXT, created_at INTEGER);
"""

STATE_SCHEMA = """
CREATE TABLE sessions(
  id TEXT PRIMARY KEY, started_at REAL, ended_at REAL, profile_name TEXT, model TEXT);
CREATE TABLE messages(
  id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT, content TEXT,
  tool_call_id TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL,
  active INTEGER NOT NULL DEFAULT 1, compacted INTEGER NOT NULL DEFAULT 0);
"""


@pytest.fixture
def kanban_db(tmp_path):
    path = tmp_path / "kanban.db"
    with sqlite3.connect(path) as c:
        c.executescript(KANBAN_SCHEMA)
    return path


@pytest.fixture
def state_db(tmp_path):
    path = tmp_path / "state.db"
    with sqlite3.connect(path) as c:
        c.executescript(STATE_SCHEMA)
    return path


@pytest.fixture
def git_repo(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "wt/t_x"], cwd=repo, check=True)
    (repo / "README.md").write_text("base\n")
    subprocess.run(["git", "add", "."], cwd=repo, check=True)
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t",
                    "commit", "-q", "-m", "base"], cwd=repo, check=True)
    return repo


def insert_task(db, task_id, status="review", workspace_path="", branch="", run_id="", session_id=""):
    with sqlite3.connect(db) as c:
        c.execute("INSERT INTO tasks VALUES(?,?,?,?,?,?,?,?,0)",
                  (task_id, "t", status, "dev", workspace_path, branch, run_id, session_id))


def insert_run(db, run_id, task_id, profile="dev", started=1000, ended=2000,
               outcome="review_requested", summary="", metadata=None):
    with sqlite3.connect(db) as c:
        c.execute("INSERT INTO task_runs VALUES(?,?,?,?,?,?,?,?,?,NULL)",
                  (run_id, task_id, profile, "done", started, ended, outcome, summary,
                   json.dumps(metadata or {})))


def insert_event(db, task_id, run_id, kind, payload, created_at):
    with sqlite3.connect(db) as c:
        c.execute("INSERT INTO task_events(task_id,run_id,kind,payload,created_at) VALUES(?,?,?,?,?)",
                  (task_id, run_id, kind, json.dumps(payload), created_at))


def insert_session(db, session_id, started, ended, profile="dev"):
    with sqlite3.connect(db) as c:
        c.execute("INSERT INTO sessions VALUES(?,?,?,?,?)", (session_id, started, ended, profile, "m"))


def insert_assistant_call(db, session_id, call_id, name, arguments, ts):
    tool_calls = [{"id": call_id, "call_id": call_id, "type": "function",
                   "function": {"name": name, "arguments": json.dumps(arguments)}}]
    with sqlite3.connect(db) as c:
        c.execute("INSERT INTO messages(session_id,role,content,tool_calls,timestamp) VALUES(?,?,?,?,?)",
                  (session_id, "assistant", "", json.dumps(tool_calls), ts))


def insert_tool_result(db, session_id, call_id, name, content, ts):
    with sqlite3.connect(db) as c:
        c.execute("INSERT INTO messages(session_id,role,content,tool_call_id,tool_name,timestamp) VALUES(?,?,?,?,?,?)",
                  (session_id, "tool", json.dumps(content), call_id, name, ts))
```

- [ ] **Step 4 : Test fumée et premier commit**

`tests/test_smoke.py` :
```python
import sqlite3


def test_fixtures_build(kanban_db, state_db, git_repo):
    assert sqlite3.connect(kanban_db).execute("select count(*) from tasks").fetchone()[0] == 0
    assert sqlite3.connect(state_db).execute("select count(*) from messages").fetchone()[0] == 0
    assert (git_repo / ".git").exists()
```
Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest -q`
Expected: `1 passed`.
```bash
git add -A && git -c user.email=louis@local -c user.name="Louis Courcier" commit -q -m "chore: squelette review-gate, fixtures pytest, run.sh"
```
(Les commits suivants utilisent la même forme ; configurer une fois `git config user.email louis@local && git config user.name "Louis Courcier"` dans ce dépôt pour l'alléger.)

---

### Task 1 : Registre `decisions.yaml` et `config.py`

**Files:**
- Create: `decisions.yaml`, `config.py`, `tests/test_config.py`

**Interfaces:**
- Produces: `load_config(path: Path) -> Config` ; `Config.decision: DecisionSpec` (`version:int, provider:str, model:str, mode:str, max_state_chars:int, block_noul:float, questions:dict`) ; `Config.projects: dict[str, ProjectSpec]` (`roots:list[str], test_commands:list[str], test_file_patterns:list[str], canonical_test_command:str`) ; `project_for_path(config, workspace_path: str) -> str` renvoyant la clé du projet ou `"unknown"`.

- [ ] **Step 1 : Écrire le test**

`tests/test_config.py` :
```python
from pathlib import Path

from config import load_config, project_for_path

HERE = Path(__file__).resolve().parent.parent


def test_registry_loads_with_expected_defaults():
    cfg = load_config(HERE / "decisions.yaml")
    assert cfg.decision.version == 1
    assert cfg.decision.model == "typesafe/jev-1.13"
    assert cfg.decision.mode == "shadow"
    assert cfg.decision.block_noul == 0.35
    assert set(cfg.decision.questions) == {"unsupported_claim", "next_step"}
    assert set(cfg.projects) == {"murmure", "hermes-agent"}


def test_project_for_path_by_prefix():
    cfg = load_config(HERE / "decisions.yaml")
    assert project_for_path(cfg, "/Users/louiscourcier/Projects/murmure/.worktrees/t_1") == "murmure"
    assert project_for_path(cfg, "/Users/louiscourcier/.hermes/hermes-agent/.worktrees/t_2") == "hermes-agent"
    assert project_for_path(cfg, "/tmp/elsewhere") == "unknown"
    assert project_for_path(cfg, "") == "unknown"
```

- [ ] **Step 2 : Vérifier l'échec**

Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_config.py -q`
Expected: FAIL, `ModuleNotFoundError: config`.

- [ ] **Step 3 : Écrire `decisions.yaml`**

```yaml
# Registre versionne des decisions de la gate de completion (board murmure).
# Changer une question, un critere ou un seuil => incrementer `version`.
decisions:
  review_claim_supported:
    version: 1
    provider: jev_openrouter
    model: typesafe/jev-1.13
    mode: shadow                 # shadow | enforce  (passage a enforce : decision de Louis)
    max_state_chars: 12000
    thresholds:
      block_noul: 0.35           # au-dessus : renvoi. Bas par choix : bloquer plutot que laisser passer.
    questions:
      unsupported_claim:
        type: noul
        instructions: >
          Does the worker's summary assert something that the observed evidence does not support
          or contradicts?
        criteria:
          "true": >
            The summary claims tests passed, tests were added, files were changed or the task is
            complete, and test_results, changed_files or test_files_touched do not support it or
            contradict it.
          "false": >
            Every claim in the summary is supported by the evidence, or the summary itself states
            what was not verified.
      next_step:
        type: choice
        instructions: What should happen to this card next?
        criteria:
          proceed_to_review: The work is done and every claim is backed by evidence.
          rerun_tests: Tests must be run, fixed or re-run before any review.
          strong_review: The evidence is ambiguous; a human or a strong model must look.

projects:
  murmure:
    roots: ["/Users/louiscourcier/Projects/murmure"]
    test_commands: ["swift test", "scripts/codex/verify\\.sh", "xcodebuild .* test"]
    test_file_patterns: ["Tests/", "Test\\.swift$"]
    canonical_test_command: "bash scripts/codex/verify.sh"
  hermes-agent:
    roots: ["/Users/louiscourcier/.hermes/hermes-agent"]
    test_commands: ["pytest", "python -m pytest"]
    test_file_patterns: ["^tests/", "(^|/)test_.*\\.py$"]
    canonical_test_command: "venv/bin/python -m pytest -q"
```

- [ ] **Step 4 : Écrire `config.py`**

```python
"""Chargement du registre decisions.yaml et resolution du projet d'une carte."""
from dataclasses import dataclass
from pathlib import Path

import yaml

DECISION_ID = "review_claim_supported"


@dataclass(frozen=True)
class ProjectSpec:
    key: str
    roots: list
    test_commands: list
    test_file_patterns: list
    canonical_test_command: str


@dataclass(frozen=True)
class DecisionSpec:
    version: int
    provider: str
    model: str
    mode: str
    max_state_chars: int
    block_noul: float
    questions: dict

    @property
    def decision_id(self) -> str:
        return f"{DECISION_ID}:v{self.version}"


@dataclass(frozen=True)
class Config:
    decision: DecisionSpec
    projects: dict


def load_config(path: Path) -> Config:
    raw = yaml.safe_load(Path(path).read_text())
    d = raw["decisions"][DECISION_ID]
    decision = DecisionSpec(
        version=int(d["version"]), provider=d["provider"], model=d["model"], mode=d["mode"],
        max_state_chars=int(d["max_state_chars"]),
        block_noul=float(d["thresholds"]["block_noul"]), questions=d["questions"])
    if decision.mode not in ("shadow", "enforce"):
        raise ValueError(f"mode inconnu: {decision.mode}")
    projects = {k: ProjectSpec(key=k, **v) for k, v in raw["projects"].items()}
    return Config(decision=decision, projects=projects)


def project_for_path(config: Config, workspace_path: str) -> str:
    if not workspace_path:
        return "unknown"
    for key, spec in config.projects.items():
        if any(workspace_path.startswith(root.rstrip("/")) for root in spec.roots):
            return key
    return "unknown"
```

- [ ] **Step 5 : Vérifier, committer**

Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_config.py -q`
Expected: `2 passed`.
```bash
git add -A && git commit -q -m "feat: registre decisions.yaml v1 et chargement de la configuration"
```

---

### Task 2 : Lecture de `kanban.db`

**Files:**
- Create: `kanban.py`, `tests/test_kanban.py`

**Interfaces:**
- Produces: `@dataclass ReviewRequest(task_id, run_id, event_id, event_created_at, summary, implementer, reviewer, profile, run_started_at, run_ended_at, workspace_path, branch_name, task_session_id, changed_files_declared: list, task_status)` ; `open_kanban(path) -> sqlite3.Connection` (lecture seule, `?mode=ro`) ; `pending_review_requests(conn) -> list[ReviewRequest]` (cartes en `review`, dernière demande de revue) ; `all_review_requests(conn) -> list[ReviewRequest]` (historique complet, backfill) ; `ground_truth(conn, task_id, event_created_at) -> str` dans `{"changes_requested","accepted","pending"}`.

- [ ] **Step 1 : Écrire les tests**

`tests/test_kanban.py` :
```python
from conftest import insert_event, insert_run, insert_task
from kanban import all_review_requests, ground_truth, open_kanban, pending_review_requests


def _card(db, tid, rid, status="review", summary="fait", changed=None, created=1500):
    insert_task(db, tid, status=status, workspace_path="/w/" + tid, branch="wt/" + tid, run_id=rid)
    insert_run(db, rid, tid, summary=summary, metadata={"changed_files": changed or []})
    insert_event(db, tid, rid, "review_requested",
                 {"summary": summary, "implementer": "dev", "reviewer": "reviewer", "artifacts": []}, created)


def test_pending_lists_only_cards_in_review(kanban_db):
    _card(kanban_db, "t_a", "r_a", status="review")
    _card(kanban_db, "t_b", "r_b", status="done")
    reqs = pending_review_requests(open_kanban(kanban_db))
    assert [r.task_id for r in reqs] == ["t_a"]
    r = reqs[0]
    assert (r.run_id, r.summary, r.implementer, r.profile) == ("r_a", "fait", "dev", "dev")
    assert r.workspace_path == "/w/t_a" and r.branch_name == "wt/t_a"


def test_pending_takes_latest_review_request_of_a_card(kanban_db):
    _card(kanban_db, "t_a", "r_1", created=1000)
    insert_run(kanban_db, "r_2", "t_a", summary="v2", metadata={"changed_files": ["x.swift"]})
    insert_event(kanban_db, "t_a", "r_2", "review_requested",
                 {"summary": "v2", "implementer": "dev", "reviewer": "reviewer", "artifacts": []}, 3000)
    reqs = pending_review_requests(open_kanban(kanban_db))
    assert len(reqs) == 1 and reqs[0].run_id == "r_2" and reqs[0].changed_files_declared == ["x.swift"]


def test_all_review_requests_returns_history_in_order(kanban_db):
    _card(kanban_db, "t_a", "r_1", status="done", created=1000)
    _card(kanban_db, "t_b", "r_2", status="done", created=2000)
    assert [r.run_id for r in all_review_requests(open_kanban(kanban_db))] == ["r_1", "r_2"]


def test_ground_truth_from_following_events(kanban_db):
    _card(kanban_db, "t_a", "r_1", status="done", created=1000)
    conn = open_kanban(kanban_db)
    assert ground_truth(conn, "t_a", 1000) == "pending"
    insert_event(kanban_db, "t_a", "r_1", "changes_requested", {"reason": "pas de tests"}, 1100)
    assert ground_truth(conn, "t_a", 1000) == "changes_requested"
    _card(kanban_db, "t_b", "r_2", status="done", created=2000)
    insert_event(kanban_db, "t_b", "r_2", "completed", {"summary": "ok"}, 2100)
    assert ground_truth(conn, "t_b", 2000) == "accepted"
```

- [ ] **Step 2 : Vérifier l'échec**

Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_kanban.py -q`
Expected: FAIL, `ModuleNotFoundError: kanban`.

- [ ] **Step 3 : Écrire `kanban.py`**

```python
"""Lecture seule de kanban.db : demandes de revue et verite terrain."""
import json
import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional


@dataclass(frozen=True)
class ReviewRequest:
    task_id: str
    run_id: str
    event_id: int
    event_created_at: int
    summary: str
    implementer: str
    reviewer: str
    profile: str
    run_started_at: Optional[int]
    run_ended_at: Optional[int]
    workspace_path: str
    branch_name: str
    task_session_id: str
    changed_files_declared: list
    task_status: str


def open_kanban(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


_SELECT = """
SELECT e.id AS event_id, e.created_at, e.task_id, e.run_id, e.payload,
       r.profile, r.started_at, r.ended_at, r.summary AS run_summary, r.metadata,
       t.workspace_path, t.branch_name, t.session_id, t.status
FROM task_events e
JOIN tasks t ON t.id = e.task_id
LEFT JOIN task_runs r ON r.id = e.run_id
WHERE e.kind = 'review_requested'
"""


def _row_to_request(row) -> ReviewRequest:
    payload = json.loads(row["payload"] or "{}")
    meta = json.loads(row["metadata"] or "{}") if row["metadata"] else {}
    changed = meta.get("changed_files") or []
    return ReviewRequest(
        task_id=row["task_id"], run_id=row["run_id"] or "", event_id=row["event_id"],
        event_created_at=int(row["created_at"]),
        summary=(payload.get("summary") or row["run_summary"] or "").strip(),
        implementer=payload.get("implementer") or "", reviewer=payload.get("reviewer") or "",
        profile=row["profile"] or "", run_started_at=row["started_at"], run_ended_at=row["ended_at"],
        workspace_path=row["workspace_path"] or "", branch_name=row["branch_name"] or "",
        task_session_id=row["session_id"] or "", changed_files_declared=list(changed),
        task_status=row["status"] or "")


def all_review_requests(conn) -> List[ReviewRequest]:
    rows = conn.execute(_SELECT + " ORDER BY e.created_at, e.id").fetchall()
    return [_row_to_request(r) for r in rows]


def pending_review_requests(conn) -> List[ReviewRequest]:
    rows = conn.execute(_SELECT + " AND t.status = 'review' ORDER BY e.created_at, e.id").fetchall()
    latest = {}
    for r in rows:
        latest[r["task_id"]] = r          # la derniere demande par carte gagne
    return [_row_to_request(r) for r in latest.values()]


def ground_truth(conn, task_id: str, event_created_at: int) -> str:
    row = conn.execute(
        "SELECT kind FROM task_events WHERE task_id = ? AND created_at > ? "
        "AND kind IN ('changes_requested','completed') ORDER BY created_at, id LIMIT 1",
        (task_id, event_created_at)).fetchone()
    if row is None:
        return "pending"
    return "changes_requested" if row["kind"] == "changes_requested" else "accepted"
```

- [ ] **Step 4 : Vérifier, committer**

Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_kanban.py -q`
Expected: `4 passed`.
```bash
git add -A && git commit -q -m "feat: lecture des demandes de revue et de la verite terrain dans kanban.db"
```

---

### Task 3 : Lien run → session et lecture des appels d'outils

**Files:**
- Create: `sessions.py`, `tests/test_sessions.py`

**Interfaces:**
- Produces: `find_session_id(log_paths: list[Path], task_session_id: str, state_db: Path, run_started_at, run_ended_at) -> Optional[str]` ; `@dataclass ToolCall(ts: float, name: str, arguments: dict, exit_code: Optional[int], output: str, truncated: bool, full_output_path: Optional[str])` ; `load_tool_calls(state_db: Path, session_id: str, since_ts: float) -> list[ToolCall]` (appels `terminal`, `write_file`, `patch`, `execute_code`, ordonnés par horodatage, résultat joint par `tool_call_id`).

- [ ] **Step 1 : Écrire les tests**

`tests/test_sessions.py` :
```python
from conftest import insert_assistant_call, insert_session, insert_tool_result
from sessions import find_session_id, load_tool_calls


def test_session_from_log_trailer(tmp_path, state_db):
    log = tmp_path / "t_a.log"
    log.write_text("...\n  hermes --resume 20260917_095937_050ca1 -p reviewer\n\nSession:        20260917_095937_050ca1\n")
    assert find_session_id([log], "", state_db, 1000, 2000) == "20260917_095937_050ca1"


def test_session_from_rotated_log_then_task_column(tmp_path, state_db):
    log1 = tmp_path / "t_a.log.1"
    log1.write_text("Session:        S_OLD\n")
    assert find_session_id([tmp_path / "t_a.log", log1], "", state_db, 1000, 2000) == "S_OLD"
    assert find_session_id([tmp_path / "absent.log"], "S_COL", state_db, 1000, 2000) == "S_COL"


def test_session_fallback_by_time_window(tmp_path, state_db):
    insert_session(state_db, "S_1", 900.0, 2100.0)
    insert_session(state_db, "S_2", 5000.0, 6000.0)
    assert find_session_id([tmp_path / "absent.log"], "", state_db, 1000, 2000) == "S_1"
    assert find_session_id([tmp_path / "absent.log"], "", state_db, 7000, 8000) is None


def test_load_tool_calls_joins_results_and_orders(state_db):
    insert_session(state_db, "S", 0.0, 100.0)
    insert_assistant_call(state_db, "S", "c1", "terminal", {"command": "swift test"}, 10.0)
    insert_tool_result(state_db, "S", "c1", "terminal", {"output": "ok\n", "exit_code": 0, "error": None}, 11.0)
    insert_assistant_call(state_db, "S", "c2", "write_file", {"path": "a.swift", "content": "x"}, 12.0)
    insert_tool_result(state_db, "S", "c2", "write_file", {"output": "written"}, 12.5)
    insert_assistant_call(state_db, "S", "c0", "read_file", {"path": "a"}, 5.0)  # ignore
    calls = load_tool_calls(state_db, "S", since_ts=0.0)
    assert [c.name for c in calls] == ["terminal", "write_file"]
    assert calls[0].arguments["command"] == "swift test" and calls[0].exit_code == 0 and calls[0].output == "ok\n"
    assert calls[1].exit_code is None


def test_load_tool_calls_truncated_output_reads_spill_file(state_db, tmp_path):
    spill = tmp_path / "full.txt"
    spill.write_text("\n".join(f"line {i}" for i in range(200)) + "\n")
    insert_session(state_db, "S", 0.0, 100.0)
    insert_assistant_call(state_db, "S", "c1", "terminal", {"command": "swift test"}, 10.0)
    insert_tool_result(state_db, "S", "c1", "terminal",
                       {"output": "line 0\n", "exit_code": 1, "error": None,
                        "output_total_chars": 2000, "full_output_path": str(spill),
                        "truncation_note": "Output exceeded the capture window"}, 11.0)
    c = load_tool_calls(state_db, "S", since_ts=0.0)[0]
    assert c.truncated and c.full_output_path == str(spill)
    assert c.output.strip().splitlines()[-1] == "line 199"


def test_load_tool_calls_respects_since_and_missing_result(state_db):
    insert_session(state_db, "S", 0.0, 100.0)
    insert_assistant_call(state_db, "S", "c1", "terminal", {"command": "old"}, 1.0)
    insert_assistant_call(state_db, "S", "c2", "terminal", {"command": "new"}, 50.0)
    calls = load_tool_calls(state_db, "S", since_ts=20.0)
    assert [c.arguments["command"] for c in calls] == ["new"] and calls[0].exit_code is None
```

- [ ] **Step 2 : Vérifier l'échec**

Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_sessions.py -q`
Expected: FAIL, `ModuleNotFoundError: sessions`.

- [ ] **Step 3 : Écrire `sessions.py`**

```python
"""Lien run -> session Hermes, et lecture des appels d'outils dans state.db (lecture seule)."""
import json
import re
import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

TRAILER = re.compile(r"^Session:\s+(\S+)\s*$", re.MULTILINE)
TRACKED_TOOLS = ("terminal", "write_file", "patch", "execute_code")
TAIL_LINES = 60


@dataclass(frozen=True)
class ToolCall:
    ts: float
    name: str
    arguments: dict
    exit_code: Optional[int]
    output: str
    truncated: bool
    full_output_path: Optional[str]


def _open(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def find_session_id(log_paths: List[Path], task_session_id: str, state_db: Path,
                    run_started_at, run_ended_at) -> Optional[str]:
    for log in log_paths:
        try:
            found = TRAILER.findall(Path(log).read_text(errors="replace"))
        except OSError:
            continue
        if found:
            return found[-1]
    if task_session_id:
        return task_session_id
    if run_started_at is None or not Path(state_db).exists():
        return None
    end = run_ended_at if run_ended_at is not None else run_started_at + 6 * 3600
    row = _open(state_db).execute(
        "SELECT id FROM sessions WHERE started_at <= ? AND COALESCE(ended_at, started_at + 21600) >= ? "
        "ORDER BY started_at DESC LIMIT 1", (float(run_started_at) + 120, float(end) - 120)).fetchone()
    return row["id"] if row else None


def _tail(text: str, n: int = TAIL_LINES) -> str:
    lines = text.splitlines()
    return "\n".join(lines[-n:]) + ("\n" if text.endswith("\n") else "")


def load_tool_calls(state_db: Path, session_id: str, since_ts: float) -> List[ToolCall]:
    conn = _open(state_db)
    results = {}
    for r in conn.execute("SELECT tool_call_id, content FROM messages WHERE session_id = ? AND role = 'tool'",
                          (session_id,)):
        results[r["tool_call_id"]] = r["content"]
    calls: List[ToolCall] = []
    for r in conn.execute("SELECT tool_calls, timestamp FROM messages WHERE session_id = ? AND role = 'assistant' "
                          "AND tool_calls IS NOT NULL AND timestamp >= ? ORDER BY timestamp, id",
                          (session_id, since_ts)):
        try:
            entries = json.loads(r["tool_calls"])
        except (TypeError, ValueError):
            continue
        for entry in entries:
            fn = (entry.get("function") or {})
            name = fn.get("name") or ""
            if name not in TRACKED_TOOLS:
                continue
            try:
                args = json.loads(fn.get("arguments") or "{}")
            except ValueError:
                args = {}
            raw = results.get(entry.get("call_id")) or results.get(entry.get("id"))
            calls.append(_with_result(float(r["timestamp"]), name, args, raw))
    return calls


def _with_result(ts: float, name: str, args: dict, raw: Optional[str]) -> ToolCall:
    if raw is None:
        return ToolCall(ts, name, args, None, "", False, None)
    try:
        content = json.loads(raw)
    except ValueError:
        return ToolCall(ts, name, args, None, _tail(raw), False, None)
    if not isinstance(content, dict):
        return ToolCall(ts, name, args, None, _tail(str(content)), False, None)
    output = content.get("output") or ""
    full = content.get("full_output_path")
    truncated = bool(content.get("truncation_note")) or bool(full)
    if truncated and full:
        try:
            output = Path(full).read_text(errors="replace")
        except OSError:
            pass
    code = content.get("exit_code")
    return ToolCall(ts, name, args, int(code) if code is not None else None, _tail(output), truncated, full)
```

- [ ] **Step 4 : Vérifier, committer**

Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_sessions.py -q`
Expected: `6 passed`.
```bash
git add -A && git commit -q -m "feat: resolution run->session et lecture des appels d'outils dans state.db"
```

---

### Task 4 : `evidence.py` : faits dérivés et snapshot

**Files:**
- Create: `evidence.py`, `tests/test_evidence.py`

**Interfaces:**
- Consumes: `ReviewRequest`, `ToolCall`, `Config`, `ProjectSpec`, `project_for_path`.
- Produces: `@dataclass EvidenceSnapshot(task_id, run_id, event_created_at, project, summary, tests_ran: bool|None, last_test_command: str|None, last_test_exit_code: int|None, last_test_output_tail: str, edits_after_last_test: bool, changed_files_git: list|None, changed_files_declared: list, test_files_touched: bool, workspace_present: bool, session_id: str|None, decision_version: int)` avec `.to_dict()` et `.state_for_model(max_chars) -> dict` ; `derive(req: ReviewRequest, calls: list[ToolCall], git_files: list|None, project: ProjectSpec|None, session_id, workspace_present, version) -> EvidenceSnapshot` (fonction pure) ; `git_changed_files(workspace_path: str) -> list|None` ; `save_snapshot(root: Path, snap) -> Path` ; `snapshot_exists(root, task_id, run_id) -> bool`.

- [ ] **Step 1 : Écrire les tests**

`tests/test_evidence.py` :
```python
import json
import subprocess
from pathlib import Path

from config import load_config
from evidence import derive, git_changed_files, save_snapshot, snapshot_exists
from kanban import ReviewRequest
from sessions import ToolCall

HERE = Path(__file__).resolve().parent.parent
CFG = load_config(HERE / "decisions.yaml")
MUR = CFG.projects["murmure"]


def _req(summary="fait", changed=None, ws="/Users/louiscourcier/Projects/murmure/.worktrees/t_1"):
    return ReviewRequest("t_1", "r_1", 1, 1500, summary, "dev", "reviewer", "dev", 1000, 2000,
                         ws, "wt/t_1", "", changed or [], "review")


def _term(ts, cmd, code=0, out="ok\n"):
    return ToolCall(ts, "terminal", {"command": cmd}, code, out, False, None)


def test_no_test_command_means_tests_ran_false():
    s = derive(_req(), [_term(10, "ls"), ToolCall(11, "write_file", {"path": "a"}, None, "", False, None)],
               ["Sources/A.swift"], MUR, "S", True, 1)
    assert s.tests_ran is False and s.last_test_command is None and s.last_test_exit_code is None
    assert s.project == "murmure" and s.workspace_present and s.session_id == "S"


def test_last_test_wins_and_exit_code_kept():
    s = derive(_req(), [_term(10, "swift test", 1, "FAIL\n"), _term(20, "bash scripts/codex/verify.sh", 0, "PASS\n")],
               [], MUR, "S", True, 1)
    assert s.tests_ran and s.last_test_command == "bash scripts/codex/verify.sh"
    assert s.last_test_exit_code == 0 and s.last_test_output_tail == "PASS\n"


def test_edit_after_last_test_detected_via_write_tools_and_terminal():
    s = derive(_req(), [_term(10, "swift test"), ToolCall(20, "patch", {"path": "a"}, None, "", False, None)],
               [], MUR, "S", True, 1)
    assert s.edits_after_last_test is True
    s2 = derive(_req(), [_term(10, "swift test"), _term(20, "sed -i '' 's/a/b/' x.swift")], [], MUR, "S", True, 1)
    assert s2.edits_after_last_test is True
    s3 = derive(_req(), [ToolCall(5, "patch", {"path": "a"}, None, "", False, None), _term(10, "swift test 2>&1 | tee log")],
                [], MUR, "S", True, 1)
    assert s3.edits_after_last_test is False


def test_test_files_touched_from_git_or_declared():
    s = derive(_req(changed=["MurmureCore/Tests/XTests.swift"]), [_term(10, "swift test")], None, MUR, "S", False, 1)
    assert s.test_files_touched and s.changed_files_git is None and s.workspace_present is False
    s2 = derive(_req(), [_term(10, "swift test")], ["MurmureCore/Sources/A.swift"], MUR, "S", True, 1)
    assert s2.test_files_touched is False


def test_unknown_project_leaves_tests_ran_none():
    s = derive(_req(ws="/tmp/x"), [_term(10, "pytest")], [], None, "S", True, 1)
    assert s.project == "unknown" and s.tests_ran is None


def test_state_for_model_is_bounded_and_has_no_secrets():
    s = derive(_req(summary="x" * 50000), [_term(10, "swift test", 0, "y\n" * 5000)], [f"f{i}.swift" for i in range(500)],
               MUR, "S", True, 1)
    state = s.state_for_model(max_chars=12000)
    assert len(json.dumps(state)) <= 12000
    assert set(state) == {"summary", "project", "tests_ran", "last_test_command", "last_test_exit_code",
                          "last_test_output_tail", "changed_files", "test_files_touched", "edits_after_last_test",
                          "workspace_present"}


def test_git_changed_files_and_snapshot_roundtrip(git_repo, tmp_path):
    (git_repo / "Tests").mkdir()
    (git_repo / "Tests" / "NewTests.swift").write_text("t")
    (git_repo / "README.md").write_text("changed\n")
    files = git_changed_files(str(git_repo))
    assert sorted(files) == ["README.md", "Tests/NewTests.swift"]
    assert git_changed_files(str(tmp_path / "nope")) is None
    s = derive(_req(), [_term(10, "swift test")], files, MUR, "S", True, 1)
    p = save_snapshot(tmp_path / "snap", s)
    assert p == tmp_path / "snap" / "t_1" / "r_1.json"
    assert json.loads(p.read_text())["tests_ran"] is True
    assert snapshot_exists(tmp_path / "snap", "t_1", "r_1") and not snapshot_exists(tmp_path / "snap", "t_1", "r_9")
```

- [ ] **Step 2 : Vérifier l'échec**

Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_evidence.py -q`
Expected: FAIL, `ModuleNotFoundError: evidence`.

- [ ] **Step 3 : Écrire `evidence.py`**

```python
"""Assemblage des preuves d'un run en un snapshot fige. Fonctions pures sauf git et sauvegarde."""
import json
import re
import subprocess
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import List, Optional

from config import ProjectSpec
from kanban import ReviewRequest
from sessions import ToolCall

WRITE_TOOLS = ("write_file", "patch", "execute_code")
TERMINAL_WRITE = re.compile(r"\bsed -i\b|\bgit apply\b|\bgit checkout --|\bgit stash pop\b")
MAX_FILES = 200


@dataclass(frozen=True)
class EvidenceSnapshot:
    task_id: str
    run_id: str
    event_created_at: int
    project: str
    summary: str
    tests_ran: Optional[bool]
    last_test_command: Optional[str]
    last_test_exit_code: Optional[int]
    last_test_output_tail: str
    edits_after_last_test: bool
    changed_files_git: Optional[list]
    changed_files_declared: list
    test_files_touched: bool
    workspace_present: bool
    session_id: Optional[str]
    decision_version: int

    def to_dict(self) -> dict:
        return asdict(self)

    def changed_files(self) -> list:
        merged = list(dict.fromkeys((self.changed_files_git or []) + list(self.changed_files_declared)))
        return merged[:MAX_FILES]

    def state_for_model(self, max_chars: int) -> dict:
        state = {
            "summary": self.summary, "project": self.project, "tests_ran": self.tests_ran,
            "last_test_command": self.last_test_command, "last_test_exit_code": self.last_test_exit_code,
            "last_test_output_tail": self.last_test_output_tail, "changed_files": self.changed_files(),
            "test_files_touched": self.test_files_touched, "edits_after_last_test": self.edits_after_last_test,
            "workspace_present": self.workspace_present,
        }
        # Reduction progressive : sortie de test, puis fichiers, puis resume, jusqu'a tenir dans max_chars.
        while len(json.dumps(state, ensure_ascii=False)) > max_chars:
            if len(state["last_test_output_tail"]) > 500:
                state["last_test_output_tail"] = state["last_test_output_tail"][-500:]
            elif len(state["changed_files"]) > 50:
                state["changed_files"] = state["changed_files"][:50]
            elif len(state["summary"]) > 200:
                state["summary"] = state["summary"][: len(state["summary"]) // 2]
            else:
                break
        return state


def _is_test(cmd: str, project: ProjectSpec) -> bool:
    return any(re.search(p, cmd) for p in project.test_commands)


def _is_write(call: ToolCall) -> bool:
    if call.name in WRITE_TOOLS:
        return True
    return call.name == "terminal" and bool(TERMINAL_WRITE.search(call.arguments.get("command", "")))


def derive(req: ReviewRequest, calls: List[ToolCall], git_files: Optional[list],
           project: Optional[ProjectSpec], session_id: Optional[str], workspace_present: bool,
           version: int) -> EvidenceSnapshot:
    tests = [c for c in calls if c.name == "terminal" and project and _is_test(c.arguments.get("command", ""), project)]
    last = tests[-1] if tests else None
    edits_after = bool(last) and any(c.ts > last.ts and _is_write(c) for c in calls)
    files = list(dict.fromkeys((git_files or []) + list(req.changed_files_declared)))
    touched = bool(project) and any(re.search(p, f) for f in files for p in project.test_file_patterns)
    return EvidenceSnapshot(
        task_id=req.task_id, run_id=req.run_id, event_created_at=req.event_created_at,
        project=project.key if project else "unknown", summary=req.summary,
        tests_ran=(bool(tests) if project else None),
        last_test_command=(last.arguments.get("command") if last else None),
        last_test_exit_code=(last.exit_code if last else None),
        last_test_output_tail=(last.output if last else ""),
        edits_after_last_test=edits_after,
        changed_files_git=(list(git_files)[:MAX_FILES] if git_files is not None else None),
        changed_files_declared=list(req.changed_files_declared)[:MAX_FILES],
        test_files_touched=touched, workspace_present=workspace_present,
        session_id=session_id, decision_version=version)


def git_changed_files(workspace_path: str) -> Optional[list]:
    ws = Path(workspace_path) if workspace_path else None
    if not ws or not ws.exists():
        return None
    try:
        out = subprocess.run(["git", "-C", str(ws), "status", "--porcelain", "--untracked-files=all"],
                             capture_output=True, text=True, timeout=30, check=True).stdout
    except (subprocess.SubprocessError, OSError):
        return None
    files = []
    for line in out.splitlines():
        if len(line) > 3:
            files.append(line[3:].split(" -> ")[-1].strip())
    return files


def save_snapshot(root: Path, snap: EvidenceSnapshot) -> Path:
    path = Path(root) / snap.task_id / f"{snap.run_id}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(snap.to_dict(), ensure_ascii=False, indent=1))
    return path


def snapshot_exists(root: Path, task_id: str, run_id: str) -> bool:
    return (Path(root) / task_id / f"{run_id}.json").exists()
```

- [ ] **Step 4 : Vérifier, committer**

Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_evidence.py -q`
Expected: `7 passed`.
```bash
git add -A && git commit -q -m "feat: snapshot de preuves, faits derives, lecture git"
```

---

### Task 5 : `rules.py` : R1 à R5

**Files:**
- Create: `rules.py`, `tests/test_rules.py`

**Interfaces:**
- Consumes: `EvidenceSnapshot`, `ProjectSpec`.
- Produces: `@dataclass RuleHit(rule: str, reason: str)` ; `apply_rules(snap: EvidenceSnapshot, project: ProjectSpec|None) -> Optional[RuleHit]`.

- [ ] **Step 1 : Écrire les tests**

`tests/test_rules.py` :
```python
from dataclasses import replace
from pathlib import Path

from config import load_config
from evidence import EvidenceSnapshot
from rules import apply_rules

CFG = load_config(Path(__file__).resolve().parent.parent / "decisions.yaml")
MUR = CFG.projects["murmure"]


def _snap(**kw):
    base = dict(task_id="t", run_id="r", event_created_at=1, project="murmure",
                summary="Implémenté et testé, tout passe.", tests_ran=True, last_test_command="swift test",
                last_test_exit_code=0, last_test_output_tail="ok\n", edits_after_last_test=False,
                changed_files_git=["Sources/A.swift", "Tests/ATests.swift"], changed_files_declared=[],
                test_files_touched=True, workspace_present=True, session_id="S", decision_version=1)
    base.update(kw)
    return EvidenceSnapshot(**base)


def test_r1_empty_summary():
    hit = apply_rules(_snap(summary="  "), MUR)
    assert hit.rule == "R1" and "résumé" in hit.reason


def test_r2_no_tests_ran_names_canonical_command():
    hit = apply_rules(_snap(tests_ran=False, last_test_command=None, last_test_exit_code=None), MUR)
    assert hit.rule == "R2" and "bash scripts/codex/verify.sh" in hit.reason


def test_r3_failed_tests_include_code_and_tail():
    hit = apply_rules(_snap(last_test_exit_code=1, last_test_output_tail="a\nb\nFAIL\n"), MUR)
    assert hit.rule == "R3" and "exit 1" in hit.reason and "FAIL" in hit.reason


def test_r4_edits_after_tests():
    assert apply_rules(_snap(edits_after_last_test=True), MUR).rule == "R4"


def test_r5_claims_tests_without_test_files():
    hit = apply_rules(_snap(summary="Ajout des tests unitaires de la purge.", test_files_touched=False), MUR)
    assert hit.rule == "R5"
    assert apply_rules(_snap(summary="Correction du libellé du bouton.", test_files_touched=False), MUR) is None


def test_no_rule_when_everything_is_backed():
    assert apply_rules(_snap(), MUR) is None


def test_unknown_project_only_r1_applies():
    assert apply_rules(_snap(project="unknown", tests_ran=None, summary=""), None).rule == "R1"
    assert apply_rules(_snap(project="unknown", tests_ran=None, last_test_exit_code=None), None) is None


def test_order_is_r1_then_r2_then_r3():
    s = _snap(tests_ran=False, last_test_exit_code=1, edits_after_last_test=True)
    assert apply_rules(s, MUR).rule == "R2"
```

- [ ] **Step 2 : Vérifier l'échec**

Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_rules.py -q`
Expected: FAIL, `ModuleNotFoundError: rules`.

- [ ] **Step 3 : Écrire `rules.py`**

```python
"""Regles deterministes, appliquees avant tout modele. La premiere qui matche renvoie la carte."""
import re
from dataclasses import dataclass
from typing import Optional

from config import ProjectSpec
from evidence import EvidenceSnapshot

CLAIMS_TESTS = re.compile(r"\btests?\b|\bcouvert|\bspec\b|\bunitaire", re.IGNORECASE)


@dataclass(frozen=True)
class RuleHit:
    rule: str
    reason: str


def apply_rules(snap: EvidenceSnapshot, project: Optional[ProjectSpec]) -> Optional[RuleHit]:
    if not snap.summary.strip():
        return RuleHit("R1", "Aucun résumé de livraison. Décris ce qui a été fait et colle le résultat des tests.")
    if project is None:
        return None
    if snap.tests_ran is False:
        return RuleHit("R2", "Aucune exécution de tests trouvée dans la session. "
                             f"Lance `{project.canonical_test_command}` et colle le résultat dans le résumé.")
    if snap.last_test_exit_code not in (None, 0):
        tail = "\n".join(snap.last_test_output_tail.splitlines()[-20:])
        return RuleHit("R3", f"La dernière exécution de tests a échoué (exit {snap.last_test_exit_code}). "
                             f"Corrige puis relance.\n```\n{tail}\n```")
    if snap.edits_after_last_test:
        return RuleHit("R4", "Des fichiers ont été modifiés après la dernière exécution des tests. Relance-les.")
    if CLAIMS_TESTS.search(snap.summary) and not snap.test_files_touched:
        return RuleHit("R5", "Le résumé annonce des tests mais aucun fichier de test n'a été modifié. "
                             "Ajoute-les ou corrige le résumé.")
    return None
```

- [ ] **Step 4 : Vérifier, committer**

Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_rules.py -q`
Expected: `8 passed`.
```bash
git add -A && git commit -q -m "feat: regles deterministes R1-R5"
```

---

### Task 6 : `decide.py` : fournisseur Jev

**Files:**
- Create: `decide.py`, `tests/test_decide.py`

**Interfaces:**
- Consumes: `DecisionSpec`.
- Produces: `@dataclass Decision(answers: dict, model: str, latency_ms: int, input_tokens: Optional[int], cost_usd: Optional[float])` ; `class ProviderError(Exception)` ; `class JevOpenRouter(model: str, post=None, sleep=None)` avec `.decide(state: dict, questions: dict) -> Decision` ; `class FakeProvider(answers: dict)` (tests) ; `read_openrouter_key(env_path: Path) -> str` ; `make_provider(spec: DecisionSpec) -> provider`.

- [ ] **Step 1 : Écrire les tests**

`tests/test_decide.py` :
```python
import json
import urllib.error
from pathlib import Path

import pytest

from config import load_config
from decide import FakeProvider, JevOpenRouter, ProviderError, make_provider, read_openrouter_key

CFG = load_config(Path(__file__).resolve().parent.parent / "decisions.yaml")
Q = CFG.decision.questions
RESP = {"model": "typesafe/jev-1.13",
        "answers": {"unsupported_claim": {"type": "noul", "noul": 0.91},
                    "next_step": {"type": "choice", "choice": "rerun_tests",
                                  "probabilities": {"proceed_to_review": 0.05, "rerun_tests": 0.9, "strong_review": 0.05},
                                  "confidence": 0.8}},
        "usage": {"input_tokens": 1830, "cost": 0.00003}}


def test_jev_posts_pinned_model_and_parses(tmp_path):
    seen = {}

    def post(url, body, headers, timeout):
        seen.update(url=url, body=body, headers=headers)
        return RESP

    env = tmp_path / ".env"
    env.write_text("FOO=1\nOPENROUTER_API_KEY=\"sk-test\"\n")
    p = JevOpenRouter("typesafe/jev-1.13", post=post, env_path=env)
    d = p.decide({"summary": "x"}, Q)
    assert seen["url"] == "https://openrouter.ai/api/alpha/decisions"
    assert seen["body"]["model"] == "typesafe/jev-1.13" and seen["body"]["state"] == {"summary": "x"}
    assert set(seen["body"]["questions"]) == {"unsupported_claim", "next_step"}
    assert seen["headers"]["Authorization"] == "Bearer sk-test"
    assert d.answers["unsupported_claim"]["noul"] == 0.91 and d.answers["next_step"]["choice"] == "rerun_tests"
    assert d.input_tokens == 1830 and d.cost_usd == 0.00003 and d.model == "typesafe/jev-1.13"
    assert "sk-test" not in repr(p) and "sk-test" not in str(vars(p))


def test_retry_once_on_429_then_raise(tmp_path):
    calls = []

    def post(url, body, headers, timeout):
        calls.append(1)
        raise urllib.error.HTTPError(url, 429, "rate", {}, None)

    env = tmp_path / ".env"
    env.write_text("OPENROUTER_API_KEY=k\n")
    p = JevOpenRouter("typesafe/jev-1.13", post=post, sleep=lambda s: None, env_path=env)
    with pytest.raises(ProviderError):
        p.decide({}, Q)
    assert len(calls) == 2


def test_no_retry_on_401(tmp_path):
    calls = []

    def post(url, body, headers, timeout):
        calls.append(1)
        raise urllib.error.HTTPError(url, 401, "auth", {}, None)

    env = tmp_path / ".env"
    env.write_text("OPENROUTER_API_KEY=k\n")
    with pytest.raises(ProviderError):
        JevOpenRouter("typesafe/jev-1.13", post=post, sleep=lambda s: None, env_path=env).decide({}, Q)
    assert len(calls) == 1


def test_missing_key_is_provider_error(tmp_path):
    env = tmp_path / ".env"
    env.write_text("OTHER=1\n")
    with pytest.raises(ProviderError):
        read_openrouter_key(env)


def test_fake_provider_and_factory():
    fake = FakeProvider({"unsupported_claim": {"noul": 0.1}, "next_step": {"choice": "proceed_to_review"}})
    assert fake.decide({}, Q).answers["next_step"]["choice"] == "proceed_to_review"
    assert isinstance(make_provider(CFG.decision), JevOpenRouter)


@pytest.mark.live
def test_live_jev_smoke():
    p = make_provider(CFG.decision)
    d = p.decide({"summary": "Tout passe.", "tests_ran": False, "last_test_exit_code": None,
                  "changed_files": ["a.swift"], "test_files_touched": False}, Q)
    assert 0.0 <= d.answers["unsupported_claim"]["noul"] <= 1.0
    assert d.answers["next_step"]["choice"] in {"proceed_to_review", "rerun_tests", "strong_review"}
```

- [ ] **Step 2 : Vérifier l'échec**

Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_decide.py -q`
Expected: FAIL, `ModuleNotFoundError: decide`.

- [ ] **Step 3 : Écrire `decide.py`**

```python
"""Fournisseur de decision. Seul module reseau. Jev via OpenRouter aujourd'hui ; interface stable pour un modele local demain."""
import json
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

from config import DecisionSpec

JEV_URL = "https://openrouter.ai/api/alpha/decisions"
ENV_PATH = Path("/Users/louiscourcier/.hermes/.env")
RETRY_STATUSES = (429, 529)


class ProviderError(Exception):
    pass


@dataclass(frozen=True)
class Decision:
    answers: dict
    model: str
    latency_ms: int
    input_tokens: Optional[int]
    cost_usd: Optional[float]


def read_openrouter_key(env_path: Path = ENV_PATH) -> str:
    try:
        for line in Path(env_path).read_text().splitlines():
            if line.startswith("OPENROUTER_API_KEY="):
                key = line.split("=", 1)[1].strip().strip('"').strip("'")
                if key:
                    return key
    except OSError as e:
        raise ProviderError(f"lecture .env impossible: {e}")
    raise ProviderError("OPENROUTER_API_KEY absente de .env")


def _http_post(url: str, body: dict, headers: dict, timeout: int) -> dict:
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", **headers})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


class JevOpenRouter:
    def __init__(self, model: str, post: Optional[Callable] = None, sleep: Optional[Callable] = None,
                 env_path: Path = ENV_PATH, timeout: int = 60):
        self.model = model
        self._post = post or _http_post
        self._sleep = sleep or time.sleep
        self._env_path = env_path       # la cle n'est jamais conservee, seulement son chemin
        self.timeout = timeout

    def decide(self, state: dict, questions: dict) -> Decision:
        body = {"model": self.model, "state": state, "questions": questions}
        headers = {"Authorization": f"Bearer {read_openrouter_key(self._env_path)}"}
        t0 = time.time()
        attempt = 0
        while True:
            attempt += 1
            try:
                out = self._post(JEV_URL, body, headers, self.timeout)
                break
            except urllib.error.HTTPError as e:
                if e.code in RETRY_STATUSES and attempt == 1:
                    self._sleep(2)
                    continue
                raise ProviderError(f"HTTP {e.code}")
            except (urllib.error.URLError, OSError, ValueError) as e:
                raise ProviderError(f"transport: {str(e)[:120]}")
        usage = out.get("usage") or {}
        answers = out.get("answers")
        if not isinstance(answers, dict):
            raise ProviderError("reponse sans answers")
        return Decision(answers=answers, model=str(out.get("model", self.model)),
                        latency_ms=int((time.time() - t0) * 1000),
                        input_tokens=usage.get("input_tokens"), cost_usd=usage.get("cost"))


class FakeProvider:
    def __init__(self, answers: dict, model: str = "fake"):
        self.answers = answers
        self.model = model
        self.calls = []

    def decide(self, state: dict, questions: dict) -> Decision:
        self.calls.append((state, questions))
        return Decision(self.answers, self.model, 1, 0, 0.0)


def make_provider(spec: DecisionSpec):
    if spec.provider == "jev_openrouter":
        return JevOpenRouter(spec.model)
    raise ProviderError(f"fournisseur inconnu: {spec.provider}")
```

- [ ] **Step 4 : Vérifier hors réseau, puis le test live une fois**

Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_decide.py -q`
Expected: `5 passed, 1 deselected`.
Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_decide.py -q -m live`
Expected: `1 passed` (un appel réel, environ 0,00003 $).
```bash
git add -A && git commit -q -m "feat: fournisseur de decision Jev via OpenRouter, relance 429/529, fake pour les tests"
```

---

### Task 7 : `policy.py` : de la décision à l'action

**Files:**
- Create: `policy.py`, `tests/test_policy.py`

**Interfaces:**
- Consumes: `EvidenceSnapshot`, `RuleHit`, `Decision`, `DecisionSpec`.
- Produces: `@dataclass Action(kind: str, reason: str, noul: Optional[float], choice: Optional[str])` avec `kind ∈ {"reopen","leave","leave_flagged","leave_unjudged"}` ; `decide_action(snap, rule_hit: Optional[RuleHit], decision: Optional[Decision], provider_error: Optional[str], spec: DecisionSpec) -> Action` ; `format_reopen_reason(action: Action, spec: DecisionSpec) -> str` (préfixe `GATE v<version> : `).

- [ ] **Step 1 : Écrire les tests**

`tests/test_policy.py` :
```python
from pathlib import Path

from config import load_config
from decide import Decision
from evidence import EvidenceSnapshot
from policy import decide_action, format_reopen_reason
from rules import RuleHit

SPEC = load_config(Path(__file__).resolve().parent.parent / "decisions.yaml").decision


def _snap(**kw):
    base = dict(task_id="t", run_id="r", event_created_at=1, project="murmure", summary="Tout passe.",
                tests_ran=True, last_test_command="swift test", last_test_exit_code=0, last_test_output_tail="",
                edits_after_last_test=False, changed_files_git=["a.swift"], changed_files_declared=[],
                test_files_touched=False, workspace_present=True, session_id="S", decision_version=1)
    base.update(kw)
    return EvidenceSnapshot(**base)


def _dec(noul, choice):
    return Decision({"unsupported_claim": {"noul": noul}, "next_step": {"choice": choice}}, "m", 1, 1, 0.0)


def test_rule_hit_wins_without_model():
    a = decide_action(_snap(), RuleHit("R2", "Aucune exécution…"), None, None, SPEC)
    assert a.kind == "reopen" and a.reason.startswith("Aucune exécution") and a.noul is None


def test_noul_at_threshold_reopens_with_fact_based_reason():
    a = decide_action(_snap(), None, _dec(0.35, "proceed_to_review"), None, SPEC)
    assert a.kind == "reopen" and a.noul == 0.35
    assert "fichier de test" in a.reason and "Relance les tests" in a.reason


def test_rerun_tests_choice_reopens_even_below_threshold():
    assert decide_action(_snap(), None, _dec(0.10, "rerun_tests"), None, SPEC).kind == "reopen"


def test_strong_review_flags_and_leaves():
    a = decide_action(_snap(), None, _dec(0.10, "strong_review"), None, SPEC)
    assert a.kind == "leave_flagged" and "examiner" in a.reason


def test_clean_case_leaves_silently():
    a = decide_action(_snap(test_files_touched=True), None, _dec(0.05, "proceed_to_review"), None, SPEC)
    assert a.kind == "leave" and a.reason == ""


def test_provider_error_leaves_unjudged():
    a = decide_action(_snap(), None, None, "HTTP 529", SPEC)
    assert a.kind == "leave_unjudged" and "indisponible" in a.reason


def test_unknown_project_never_reopens():
    a = decide_action(_snap(project="unknown", tests_ran=None), None, _dec(0.99, "rerun_tests"), None, SPEC)
    assert a.kind == "leave_flagged"


def test_format_reopen_reason_has_version_prefix():
    a = decide_action(_snap(), RuleHit("R1", "Aucun résumé."), None, None, SPEC)
    assert format_reopen_reason(a, SPEC) == "GATE v1 : Aucun résumé."
```

- [ ] **Step 2 : Vérifier l'échec**

Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_policy.py -q`
Expected: FAIL, `ModuleNotFoundError: policy`.

- [ ] **Step 3 : Écrire `policy.py`**

```python
"""Composition regles + decision -> action. Le motif est toujours redige par le code a partir des faits."""
from dataclasses import dataclass
from typing import Optional

from config import DecisionSpec
from decide import Decision
from evidence import EvidenceSnapshot
from rules import RuleHit


@dataclass(frozen=True)
class Action:
    kind: str                 # reopen | leave | leave_flagged | leave_unjudged
    reason: str
    noul: Optional[float]
    choice: Optional[str]


def _contradictions(snap: EvidenceSnapshot) -> list:
    facts = []
    if snap.tests_ran is False:
        facts.append("aucune exécution de tests trouvée")
    if snap.last_test_exit_code not in (None, 0):
        facts.append(f"dernière exécution de tests en échec (exit {snap.last_test_exit_code})")
    if not snap.test_files_touched:
        facts.append("aucun fichier de test modifié")
    if snap.edits_after_last_test:
        facts.append("fichiers modifiés après le dernier test")
    if not snap.workspace_present:
        facts.append("worktree absent, fichiers modifiés non vérifiables")
    return facts or ["les preuves disponibles ne couvrent pas les affirmations du résumé"]


def decide_action(snap: EvidenceSnapshot, rule_hit: Optional[RuleHit], decision: Optional[Decision],
                  provider_error: Optional[str], spec: DecisionSpec) -> Action:
    if rule_hit is not None:
        return Action("reopen", rule_hit.reason, None, None)
    if decision is None:
        return Action("leave_unjudged", f"gate indisponible, non jugé ({provider_error or 'sans détail'})", None, None)
    noul = float(decision.answers.get("unsupported_claim", {}).get("noul", 0.0))
    choice = decision.answers.get("next_step", {}).get("choice")
    wants_reopen = noul >= spec.block_noul or choice == "rerun_tests"
    if snap.project == "unknown":
        kind = "leave_flagged" if (wants_reopen or choice == "strong_review") else "leave"
        return Action(kind, "gate : projet inconnu, à examiner de près" if kind != "leave" else "", noul, choice)
    if wants_reopen:
        reason = ("Le résumé affirme des choses que les preuves ne soutiennent pas : "
                  + " ; ".join(_contradictions(snap)) + ". Relance les tests et corrige le résumé.")
        return Action("reopen", reason, noul, choice)
    if choice == "strong_review":
        return Action("leave_flagged", "gate : à examiner de près", noul, choice)
    return Action("leave", "", noul, choice)


def format_reopen_reason(action: Action, spec: DecisionSpec) -> str:
    return f"GATE v{spec.version} : {action.reason}"
```

- [ ] **Step 4 : Vérifier, committer**

Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_policy.py -q`
Expected: `8 passed`.
```bash
git add -A && git commit -q -m "feat: politique de decision et motif de renvoi construit a partir des faits"
```

---

### Task 8 : `audit.py` : JSONL de décision et journal d'étapes

**Files:**
- Create: `audit.py`, `tests/test_audit.py`

**Interfaces:**
- Consumes: `EvidenceSnapshot`, `Action`, `Decision`, `DecisionSpec`.
- Produces: `write_decision(path: Path, *, board, snap, mode, rule, decision, action, spec, state_sha256) -> dict` (écrit une ligne, la renvoie) ; `state_hash(state: dict) -> str` ; `step(name: str)` gestionnaire de contexte qui émet sur stderr `{"step":name,"event":"start"}` puis `{"step":name,"event":"end","ms":…}` ou `{"step":name,"event":"error","ms":…,"error":…}` et relaie l'exception.

- [ ] **Step 1 : Écrire les tests**

`tests/test_audit.py` :
```python
import json
import sys
from pathlib import Path

import pytest

from audit import state_hash, step, write_decision
from config import load_config
from decide import Decision
from evidence import EvidenceSnapshot
from policy import Action

SPEC = load_config(Path(__file__).resolve().parent.parent / "decisions.yaml").decision
SNAP = EvidenceSnapshot("t", "r", 1, "murmure", "Résumé confidentiel", True, "swift test", 0, "sortie", False,
                        ["a.swift"], [], False, True, "S", 1)


def test_write_decision_line_has_required_fields_and_no_content(tmp_path):
    dec = Decision({"unsupported_claim": {"noul": 0.4}, "next_step": {"choice": "rerun_tests",
                    "probabilities": {"rerun_tests": 0.9}}}, "typesafe/jev-1.13", 412, 1830, 0.00003)
    line = write_decision(tmp_path / "d.jsonl", board="murmure", snap=SNAP, mode="shadow", rule=None,
                          decision=dec, action=Action("reopen", "motif", 0.4, "rerun_tests"), spec=SPEC,
                          state_sha256="abc")
    saved = json.loads((tmp_path / "d.jsonl").read_text().splitlines()[0])
    assert saved == line
    assert saved["decision_id"] == "review_claim_supported:v1" and saved["task_id"] == "t" and saved["run_id"] == "r"
    assert saved["facts"] == {"tests_ran": True, "last_test_exit_code": 0, "test_files_touched": False,
                              "edits_after_last_test": False, "workspace_present": True}
    assert saved["answers"]["unsupported_claim"] == 0.4 and saved["answers"]["next_step"]["choice"] == "rerun_tests"
    assert saved["threshold"] == 0.35 and saved["action"] == "reopen" and saved["latency_ms"] == 412
    assert saved["cost_usd"] == 0.00003 and saved["state_sha256"] == "abc" and saved["mode"] == "shadow"
    text = (tmp_path / "d.jsonl").read_text()
    assert "Résumé confidentiel" not in text and "sortie" not in text


def test_write_decision_without_model(tmp_path):
    line = write_decision(tmp_path / "d.jsonl", board="murmure", snap=SNAP, mode="enforce", rule="R2",
                          decision=None, action=Action("reopen", "m", None, None), spec=SPEC, state_sha256="x")
    assert line["rule"] == "R2" and line["provider"] is None and line["answers"] is None


def test_state_hash_is_stable():
    assert state_hash({"a": 1, "b": [2]}) == state_hash({"b": [2], "a": 1})


def test_step_logs_start_end_and_error(capsys):
    with step("evidence"):
        pass
    with pytest.raises(ValueError):
        with step("decide"):
            raise ValueError("boom")
    lines = [json.loads(l) for l in capsys.readouterr().err.strip().splitlines()]
    assert [(l["step"], l["event"]) for l in lines] == [("evidence", "start"), ("evidence", "end"),
                                                        ("decide", "start"), ("decide", "error")]
    assert lines[3]["error"] == "boom" and "ms" in lines[1]
```

- [ ] **Step 2 : Vérifier l'échec**

Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_audit.py -q`
Expected: FAIL, `ModuleNotFoundError: audit`.

- [ ] **Step 3 : Écrire `audit.py`**

```python
"""Audit JSONL (une ligne par decision, sans contenu) et journal d'etapes sur stderr."""
import hashlib
import json
import sys
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from config import DecisionSpec
from decide import Decision
from evidence import EvidenceSnapshot
from policy import Action


def state_hash(state: dict) -> str:
    return hashlib.sha256(json.dumps(state, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def write_decision(path: Path, *, board: str, snap: EvidenceSnapshot, mode: str, rule: Optional[str],
                   decision: Optional[Decision], action: Action, spec: DecisionSpec, state_sha256: str) -> dict:
    answers = None
    if decision is not None:
        a = decision.answers
        answers = {"unsupported_claim": a.get("unsupported_claim", {}).get("noul"),
                   "next_step": {"choice": a.get("next_step", {}).get("choice"),
                                 "probabilities": a.get("next_step", {}).get("probabilities")}}
    line = {
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "decision_id": spec.decision_id, "board": board, "task_id": snap.task_id, "run_id": snap.run_id,
        "project": snap.project, "mode": mode, "rule": rule,
        "facts": {"tests_ran": snap.tests_ran, "last_test_exit_code": snap.last_test_exit_code,
                  "test_files_touched": snap.test_files_touched, "edits_after_last_test": snap.edits_after_last_test,
                  "workspace_present": snap.workspace_present},
        "provider": (spec.provider if decision is not None else None),
        "model_returned": (decision.model if decision is not None else None),
        "answers": answers, "threshold": spec.block_noul, "action": action.kind,
        "latency_ms": (decision.latency_ms if decision is not None else None),
        "input_tokens": (decision.input_tokens if decision is not None else None),
        "cost_usd": (decision.cost_usd if decision is not None else None),
        "state_sha256": state_sha256,
    }
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as f:
        f.write(json.dumps(line, ensure_ascii=False) + "\n")
    return line


@contextmanager
def step(name: str):
    t0 = time.time()
    print(json.dumps({"step": name, "event": "start"}), file=sys.stderr, flush=True)
    try:
        yield
    except Exception as e:
        print(json.dumps({"step": name, "event": "error", "ms": int((time.time() - t0) * 1000),
                          "error": str(e)[:300]}), file=sys.stderr, flush=True)
        raise
    print(json.dumps({"step": name, "event": "end", "ms": int((time.time() - t0) * 1000)}),
          file=sys.stderr, flush=True)
```

- [ ] **Step 4 : Vérifier, committer**

Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_audit.py -q`
Expected: `4 passed`.
```bash
git add -A && git commit -q -m "feat: audit JSONL des decisions et journal d'etapes"
```

---

### Task 9 : `gate.py` : orchestration des modes `shadow` et `enforce`

**Files:**
- Create: `gate.py`, `tests/test_gate.py`

**Interfaces:**
- Consumes: tout ce qui précède.
- Produces: `@dataclass Paths(kanban_db, profiles_root, logs_dir, snapshots, audit_jsonl, decisions_yaml)` avec `Paths.default(board)` ; `judge_request(req, cfg, paths, provider, board, mode, dry_run, runner, force) -> Optional[dict]` (renvoie la ligne d'audit, ou `None` si déjà jugé) ; `reopen_card(board, task_id, reason, runner) -> None` (exécute `hermes kanban --board <board> reopen-review <task_id> --reason <reason>`) ; `main(argv) -> int`.

- [ ] **Step 1 : Écrire les tests**

`tests/test_gate.py` :
```python
import json
from pathlib import Path

from conftest import insert_assistant_call, insert_event, insert_run, insert_session, insert_task, insert_tool_result
from config import load_config
from decide import FakeProvider
from gate import Paths, judge_request, reopen_card
from kanban import open_kanban, pending_review_requests

HERE = Path(__file__).resolve().parent.parent
CFG = load_config(HERE / "decisions.yaml")


def _paths(tmp_path, kanban_db, profile="dev"):
    (tmp_path / "profiles" / profile).mkdir(parents=True)
    logs = tmp_path / "logs"
    logs.mkdir()
    return Paths(kanban_db=kanban_db, profiles_root=tmp_path / "profiles", logs_dir=logs,
                 snapshots=tmp_path / "snapshots", audit_jsonl=tmp_path / "decisions.jsonl",
                 decisions_yaml=HERE / "decisions.yaml")


def _card(kanban_db, git_repo, summary, run_started=1000, run_ended=2000):
    insert_task(kanban_db, "t_1", status="review", workspace_path=str(git_repo), branch="wt/t_1", run_id="r_1")
    insert_run(kanban_db, "r_1", "t_1", started=run_started, ended=run_ended, summary=summary,
               metadata={"changed_files": ["Sources/A.swift"]})
    insert_event(kanban_db, "t_1", "r_1", "review_requested",
                 {"summary": summary, "implementer": "dev", "reviewer": "reviewer", "artifacts": []}, 1500)


def _session_with_tests(paths, tmp_path, exit_code=0, with_edit_after=False):
    state = paths.profiles_root / "dev" / "state.db"
    import sqlite3
    from conftest import STATE_SCHEMA
    with sqlite3.connect(state) as c:
        c.executescript(STATE_SCHEMA)
    insert_session(state, "S1", 900.0, 2100.0)
    insert_assistant_call(state, "S1", "c1", "terminal", {"command": "swift test"}, 1200.0)
    insert_tool_result(state, "S1", "c1", "terminal", {"output": "ok\n", "exit_code": exit_code, "error": None}, 1201.0)
    if with_edit_after:
        insert_assistant_call(state, "S1", "c2", "patch", {"path": "Sources/A.swift"}, 1300.0)
    (paths.logs_dir / "t_1.log").write_text("Session:        S1\n")


def test_shadow_mode_logs_but_never_calls_hermes(tmp_path, kanban_db, git_repo):
    paths = _paths(tmp_path, kanban_db)
    _card(kanban_db, git_repo, "Tout passe.")
    _session_with_tests(paths, tmp_path, exit_code=1)
    runs = []
    req = pending_review_requests(open_kanban(kanban_db))[0]
    line = judge_request(req, CFG, paths, FakeProvider({}), "murmure", "shadow", False, runs.append, False)
    assert line["rule"] == "R3" and line["action"] == "reopen" and line["mode"] == "shadow"
    assert runs == []
    assert (paths.snapshots / "t_1" / "r_1.json").exists()
    assert json.loads(paths.audit_jsonl.read_text().splitlines()[0])["task_id"] == "t_1"


def test_enforce_reopens_via_hermes_cli_with_reason(tmp_path, kanban_db, git_repo):
    paths = _paths(tmp_path, kanban_db)
    _card(kanban_db, git_repo, "Tout passe.")
    _session_with_tests(paths, tmp_path, exit_code=1)
    runs = []
    req = pending_review_requests(open_kanban(kanban_db))[0]
    judge_request(req, CFG, paths, FakeProvider({}), "murmure", "enforce", False, runs.append, False)
    assert len(runs) == 1
    cmd = runs[0]
    assert cmd[:5] == ["hermes", "kanban", "--board", "murmure", "reopen-review"] and cmd[5] == "t_1"
    assert cmd[6] == "--reason" and cmd[7].startswith("GATE v1 : La dernière exécution de tests a échoué")


def test_enforce_dry_run_does_not_call_hermes(tmp_path, kanban_db, git_repo):
    paths = _paths(tmp_path, kanban_db)
    _card(kanban_db, git_repo, "Tout passe.")
    _session_with_tests(paths, tmp_path, exit_code=1)
    runs = []
    req = pending_review_requests(open_kanban(kanban_db))[0]
    judge_request(req, CFG, paths, FakeProvider({}), "murmure", "enforce", True, runs.append, False)
    assert runs == []


def test_model_is_called_only_when_no_rule_matches(tmp_path, kanban_db, git_repo):
    paths = _paths(tmp_path, kanban_db)
    (git_repo / "Tests").mkdir()
    (git_repo / "Tests" / "ATests.swift").write_text("t")
    _card(kanban_db, git_repo, "Ajout de la purge avec ses tests.")
    _session_with_tests(paths, tmp_path, exit_code=0)
    fake = FakeProvider({"unsupported_claim": {"noul": 0.05}, "next_step": {"choice": "proceed_to_review"}})
    req = pending_review_requests(open_kanban(kanban_db))[0]
    line = judge_request(req, CFG, paths, fake, "murmure", "enforce", False, lambda c: None, False)
    assert len(fake.calls) == 1 and line["rule"] is None and line["action"] == "leave"
    assert fake.calls[0][0]["tests_ran"] is True and "summary" in fake.calls[0][0]


def test_already_judged_is_skipped_unless_force(tmp_path, kanban_db, git_repo):
    paths = _paths(tmp_path, kanban_db)
    _card(kanban_db, git_repo, "Tout passe.")
    _session_with_tests(paths, tmp_path, exit_code=1)
    req = pending_review_requests(open_kanban(kanban_db))[0]
    assert judge_request(req, CFG, paths, FakeProvider({}), "murmure", "shadow", False, lambda c: None, False)
    assert judge_request(req, CFG, paths, FakeProvider({}), "murmure", "shadow", False, lambda c: None, False) is None
    assert judge_request(req, CFG, paths, FakeProvider({}), "murmure", "shadow", False, lambda c: None, True)


def test_reopen_card_builds_exact_command():
    seen = []
    reopen_card("murmure", "t_9", "GATE v1 : motif", seen.append)
    assert seen == [["hermes", "kanban", "--board", "murmure", "reopen-review", "t_9", "--reason", "GATE v1 : motif"]]
```

- [ ] **Step 2 : Vérifier l'échec**

Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_gate.py -q`
Expected: FAIL, `ModuleNotFoundError: gate`.

- [ ] **Step 3 : Écrire `gate.py`**

```python
#!/usr/bin/env python3
"""Gate de completion du kanban : shadow | enforce | backfill.

Usage :
  run.sh shadow  [--board murmure] [--task t_x] [--force]
  run.sh enforce [--board murmure] [--task t_x] [--force] [--dry-run]
  run.sh backfill [--board murmure] [--out backfill/<date>]   (voir backfill.py)
"""
import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

from audit import state_hash, step, write_decision
from config import Config, load_config, project_for_path
from decide import Decision, ProviderError, make_provider
from evidence import derive, git_changed_files, save_snapshot, snapshot_exists
from kanban import ReviewRequest, open_kanban, pending_review_requests
from policy import decide_action, format_reopen_reason
from rules import apply_rules
from sessions import find_session_id, load_tool_calls

HERE = Path(__file__).resolve().parent
HERMES_HOME = Path("/Users/louiscourcier/.hermes")


@dataclass(frozen=True)
class Paths:
    kanban_db: Path
    profiles_root: Path
    logs_dir: Path
    snapshots: Path
    audit_jsonl: Path
    decisions_yaml: Path

    @staticmethod
    def default(board: str) -> "Paths":
        return Paths(kanban_db=HERMES_HOME / "kanban" / "boards" / board / "kanban.db",
                     profiles_root=HERMES_HOME / "profiles",
                     logs_dir=HERMES_HOME / "kanban" / "boards" / board / "logs",
                     snapshots=HERE / "snapshots", audit_jsonl=HERE / "decisions.jsonl",
                     decisions_yaml=HERE / "decisions.yaml")


def run_hermes(cmd: list) -> None:
    subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=120)


def reopen_card(board: str, task_id: str, reason: str, runner: Callable = run_hermes) -> None:
    runner(["hermes", "kanban", "--board", board, "reopen-review", task_id, "--reason", reason])


def build_snapshot(req: ReviewRequest, cfg: Config, paths: Paths):
    project_key = project_for_path(cfg, req.workspace_path)
    project = cfg.projects.get(project_key)
    logs = [paths.logs_dir / f"{req.task_id}.log", paths.logs_dir / f"{req.task_id}.log.1"]
    state_db = paths.profiles_root / (req.profile or "dev") / "state.db"
    session_id = find_session_id(logs, req.task_session_id, state_db, req.run_started_at, req.run_ended_at)
    calls = load_tool_calls(state_db, session_id, float(req.run_started_at or 0)) if session_id and state_db.exists() else []
    git_files = git_changed_files(req.workspace_path)
    snap = derive(req, calls, git_files, project, session_id, git_files is not None, cfg.decision.version)
    return snap, project


def judge_request(req: ReviewRequest, cfg: Config, paths: Paths, provider, board: str, mode: str,
                  dry_run: bool, runner: Callable, force: bool) -> Optional[dict]:
    if snapshot_exists(paths.snapshots, req.task_id, req.run_id) and not force:
        return None
    with step("evidence"):
        snap, project = build_snapshot(req, cfg, paths)
        save_snapshot(paths.snapshots, snap)
    with step("rules"):
        hit = apply_rules(snap, project)
    decision: Optional[Decision] = None
    error: Optional[str] = None
    state = snap.state_for_model(cfg.decision.max_state_chars)
    if hit is None:
        with step("decide"):
            try:
                decision = provider.decide(state, cfg.decision.questions)
            except ProviderError as e:
                error = str(e)
    action = decide_action(snap, hit, decision, error, cfg.decision)
    with step("act"):
        if mode == "enforce" and action.kind == "reopen" and not dry_run:
            reopen_card(board, req.task_id, format_reopen_reason(action, cfg.decision), runner)
    return write_decision(paths.audit_jsonl, board=board, snap=snap, mode=mode,
                          rule=(hit.rule if hit else None), decision=decision, action=action,
                          spec=cfg.decision, state_sha256=state_hash(state))


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else list(argv)
    if not argv:
        argv = ["shadow"]          # appel sans argument (cron) = mode ombre
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["shadow", "enforce", "backfill"])
    ap.add_argument("--board", default="murmure")
    ap.add_argument("--task")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--out")
    args = ap.parse_args(argv)
    paths = Paths.default(args.board)
    cfg = load_config(paths.decisions_yaml)
    if args.mode == "backfill":
        from backfill import run_backfill
        return run_backfill(cfg, paths, args.board, Path(args.out) if args.out else None)
    if args.mode == "enforce" and cfg.decision.mode != "enforce":
        print("refus : decisions.yaml est en mode shadow ; passe mode: enforce pour renvoyer des cartes", file=sys.stderr)
        return 2
    if not paths.kanban_db.exists():
        print(json.dumps({"step": "main", "event": "error", "error": f"base absente {paths.kanban_db}"}), file=sys.stderr)
        return 1
    provider = make_provider(cfg.decision)
    reqs = pending_review_requests(open_kanban(paths.kanban_db))
    if args.task:
        reqs = [r for r in reqs if r.task_id == args.task]
    judged = 0
    for req in reqs:
        line = judge_request(req, cfg, paths, provider, args.board, args.mode, args.dry_run, run_hermes, args.force)
        if line:
            judged += 1
            print(f"{line['task_id']} {line['run_id']} rule={line['rule']} action={line['action']} "
                  f"noul={(line['answers'] or {}).get('unsupported_claim')}")
    return 0                # silencieux quand rien n'est a juger


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4 : Vérifier, committer**

Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_gate.py -q`
Expected: `6 passed`.
Run: `cd ~/.hermes/scripts/review-gate && ./run.sh shadow --board murmure`
Expected: aucune sortie (aucune carte en `review` actuellement), code 0, quelques lignes JSON sur stderr au plus.
```bash
git add -A && git commit -q -m "feat: orchestration shadow/enforce, renvoi via hermes kanban reopen-review"
```

---

### Task 10 : `backfill.py` : rejeu historique, rapport, dossiers de divergence

**Files:**
- Create: `backfill.py`, `tests/test_backfill.py`

**Interfaces:**
- Consumes: `all_review_requests`, `ground_truth`, `build_snapshot`, `apply_rules`, `decide_action`, provider.
- Produces: `@dataclass BackfillRow(task_id, run_id, event_created_at, project, ground_truth, session_found: bool, tests_found: bool, files_found: bool, rule, noul, choice, action, agreement: str)` avec `agreement ∈ {"accord","omission","faux_renvoi_possible","non_tranche"}` ; `classify(action_kind, truth) -> str` ; `run_backfill(cfg, paths, board, out: Optional[Path], provider=None) -> int` écrivant `out/report.md`, `out/rows.jsonl`, `out/divergences/<task_id>_<run_id>.json` ; `render_report(rows) -> str`.

Règles d'accord : `reopen` + `changes_requested` → accord ; `leave*` + `accepted` → accord ; `leave*` + `changes_requested` → **omission** ; `reopen` + `accepted` → **faux_renvoi_possible** (dossier à juger) ; vérité `pending` → non_tranche.

- [ ] **Step 1 : Écrire les tests**

`tests/test_backfill.py` :
```python
import json
from pathlib import Path

from backfill import BackfillRow, classify, render_report, run_backfill
from conftest import insert_event, insert_run, insert_task
from config import load_config
from decide import FakeProvider
from gate import Paths

HERE = Path(__file__).resolve().parent.parent
CFG = load_config(HERE / "decisions.yaml")


def test_classify_matrix():
    assert classify("reopen", "changes_requested") == "accord"
    assert classify("leave", "accepted") == "accord"
    assert classify("leave_flagged", "accepted") == "accord"
    assert classify("leave", "changes_requested") == "omission"
    assert classify("reopen", "accepted") == "faux_renvoi_possible"
    assert classify("reopen", "pending") == "non_tranche"


def _hist(kanban_db, tid, rid, created, truth_kind, summary="fait", ws=""):
    insert_task(kanban_db, tid, status="done", workspace_path=ws, branch="wt/" + tid, run_id=rid)
    insert_run(kanban_db, rid, tid, started=created - 500, ended=created, summary=summary, metadata={})
    insert_event(kanban_db, tid, rid, "review_requested",
                 {"summary": summary, "implementer": "dev", "reviewer": "reviewer", "artifacts": []}, created)
    if truth_kind:
        insert_event(kanban_db, tid, rid, truth_kind, {"reason": "x"}, created + 100)


def test_run_backfill_writes_report_rows_and_divergences(tmp_path, kanban_db):
    murmure_ws = "/Users/louiscourcier/Projects/murmure/.worktrees/gone"
    _hist(kanban_db, "t_a", "r_a", 1000, "changes_requested", summary="Tout passe.", ws=murmure_ws)   # R2 -> accord
    _hist(kanban_db, "t_b", "r_b", 2000, "completed", summary="Tout passe.", ws=murmure_ws)           # R2 -> faux renvoi possible
    _hist(kanban_db, "t_c", "r_c", 3000, None, summary="", ws=murmure_ws)                             # R1 -> non tranche
    (tmp_path / "profiles" / "dev").mkdir(parents=True)
    (tmp_path / "logs").mkdir()
    paths = Paths(kanban_db=kanban_db, profiles_root=tmp_path / "profiles", logs_dir=tmp_path / "logs",
                  snapshots=tmp_path / "snap", audit_jsonl=tmp_path / "audit.jsonl", decisions_yaml=HERE / "decisions.yaml")
    out = tmp_path / "bf"
    rc = run_backfill(CFG, paths, "murmure", out, provider=FakeProvider({}))
    assert rc == 0
    rows = [json.loads(l) for l in (out / "rows.jsonl").read_text().splitlines()]
    by = {r["task_id"]: r for r in rows}
    assert by["t_a"]["agreement"] == "accord" and by["t_a"]["rule"] == "R2" and by["t_a"]["session_found"] is False
    assert by["t_b"]["agreement"] == "faux_renvoi_possible"
    assert by["t_c"]["agreement"] == "non_tranche"
    assert (out / "divergences" / "t_b_r_b.json").exists()
    dossier = json.loads((out / "divergences" / "t_b_r_b.json").read_text())
    assert dossier["ground_truth"] == "accepted" and dossier["snapshot"]["summary"] == "Tout passe."
    report = (out / "report.md").read_text()
    assert "Taux de reconstitution" in report and "omission" in report and "| t_b |" in report


def test_render_report_counts():
    rows = [BackfillRow("t", "r", 1, "murmure", "changes_requested", True, True, False, "R2", None, None, "reopen", "accord"),
            BackfillRow("u", "s", 2, "murmure", "changes_requested", False, False, False, None, 0.2, "proceed_to_review", "leave", "omission")]
    text = render_report(rows)
    assert "accord : 1" in text and "omission : 1" in text and "sessions retrouvées : 1/2" in text
```

- [ ] **Step 2 : Vérifier l'échec**

Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest tests/test_backfill.py -q`
Expected: FAIL, `ModuleNotFoundError: backfill`.

- [ ] **Step 3 : Écrire `backfill.py`**

```python
"""Rejeu historique des demandes de revue : ce que la gate aurait fait, et si elle aurait eu raison."""
import json
from collections import Counter
from dataclasses import asdict, dataclass
from datetime import date
from pathlib import Path
from typing import Optional

from audit import step
from config import Config
from decide import ProviderError, make_provider
from evidence import save_snapshot
from gate import Paths, build_snapshot
from kanban import all_review_requests, ground_truth, open_kanban
from policy import decide_action
from rules import apply_rules


@dataclass(frozen=True)
class BackfillRow:
    task_id: str
    run_id: str
    event_created_at: int
    project: str
    ground_truth: str
    session_found: bool
    tests_found: bool
    files_found: bool
    rule: Optional[str]
    noul: Optional[float]
    choice: Optional[str]
    action: str
    agreement: str


def classify(action_kind: str, truth: str) -> str:
    if truth == "pending":
        return "non_tranche"
    reopened = action_kind == "reopen"
    if reopened and truth == "changes_requested":
        return "accord"
    if not reopened and truth == "accepted":
        return "accord"
    if not reopened and truth == "changes_requested":
        return "omission"
    return "faux_renvoi_possible"


def render_report(rows) -> str:
    n = len(rows)
    agree = Counter(r.agreement for r in rows)
    sess = sum(r.session_found for r in rows)
    tests = sum(r.tests_found for r in rows)
    files = sum(r.files_found for r in rows)
    rules = Counter(r.rule for r in rows if r.rule)
    lines = [f"# Backfill gate de complétion — {date.today().isoformat()}", "",
             f"Demandes de revue rejouées : {n}", "",
             "## Taux de reconstitution", "",
             f"- sessions retrouvées : {sess}/{n}", f"- commandes de test retrouvées : {tests}/{n}",
             f"- fichiers modifiés retrouvés (git) : {files}/{n}", "",
             "## Accord avec le reviewer", ""]
    for k in ("accord", "omission", "faux_renvoi_possible", "non_tranche"):
        lines.append(f"- {k} : {agree.get(k, 0)}")
    lines += ["", f"Couverture par les règles (sans modèle) : {sum(rules.values())}/{n} — " +
              ", ".join(f"{k} {v}" for k, v in sorted(rules.items())), "",
              "## Détail", "",
              "| task | vérité terrain | règle | unsupported_claim | choix | action gate | accord |",
              "|---|---|---|---|---|---|---|"]
    for r in rows:
        noul = "" if r.noul is None else f"{r.noul:.2f}"
        lines.append(f"| {r.task_id} | {r.ground_truth} | {r.rule or ''} | {noul} | {r.choice or ''} | {r.action} | {r.agreement} |")
    lines += ["", "Les divergences (`omission`, `faux_renvoi_possible`) ont un dossier dans `divergences/`."]
    return "\n".join(lines) + "\n"


def run_backfill(cfg: Config, paths: Paths, board: str, out: Optional[Path], provider=None) -> int:
    out = out or (Path(paths.snapshots).parent / "backfill" / date.today().isoformat())
    (out / "divergences").mkdir(parents=True, exist_ok=True)
    provider = provider or make_provider(cfg.decision)
    conn = open_kanban(paths.kanban_db)
    rows = []
    for req in all_review_requests(conn):
        with step(f"backfill:{req.task_id}"):
            snap, project = build_snapshot(req, cfg, paths)
            save_snapshot(out / "snapshots", snap)
            truth = ground_truth(conn, req.task_id, req.event_created_at)
            hit = apply_rules(snap, project)
            decision, error = None, None
            if hit is None:
                try:
                    decision = provider.decide(snap.state_for_model(cfg.decision.max_state_chars), cfg.decision.questions)
                except ProviderError as e:
                    error = str(e)
            action = decide_action(snap, hit, decision, error, cfg.decision)
            row = BackfillRow(
                task_id=req.task_id, run_id=req.run_id, event_created_at=req.event_created_at, project=snap.project,
                ground_truth=truth, session_found=snap.session_id is not None,
                tests_found=bool(snap.tests_ran), files_found=snap.changed_files_git is not None,
                rule=(hit.rule if hit else None), noul=action.noul, choice=action.choice,
                action=action.kind, agreement=classify(action.kind, truth))
            rows.append(row)
            if row.agreement in ("omission", "faux_renvoi_possible"):
                reason_row = conn.execute(
                    "SELECT payload FROM task_events WHERE task_id = ? AND kind = 'changes_requested' "
                    "AND created_at > ? ORDER BY created_at LIMIT 1", (req.task_id, req.event_created_at)).fetchone()
                dossier = {"row": asdict(row), "ground_truth": truth,
                           "reviewer_reason": (json.loads(reason_row["payload"]).get("reason") if reason_row else None),
                           "gate_reason": action.reason, "snapshot": snap.to_dict()}
                (out / "divergences" / f"{req.task_id}_{req.run_id}.json").write_text(
                    json.dumps(dossier, ensure_ascii=False, indent=1))
    with open(out / "rows.jsonl", "w") as f:
        for r in rows:
            f.write(json.dumps(asdict(r), ensure_ascii=False) + "\n")
    (out / "report.md").write_text(render_report(rows))
    print(f"backfill : {len(rows)} lignes -> {out}")
    return 0
```

- [ ] **Step 4 : Vérifier, committer**

Run: `~/.hermes/hermes-agent/venv/bin/python -m pytest -q`
Expected: toute la suite passe (`live` désélectionné).
```bash
git add -A && git commit -q -m "feat: backfill historique, rapport et dossiers de divergence"
```

---

### Task 11 : Exécuter le backfill réel et faire juger les divergences

**Files:**
- Create (repo murmure) : `docs/research/2026-09-2X-review-gate-backfill.md` (date du jour d'exécution)
- Read-only : `~/.hermes/kanban/boards/murmure/kanban.db`, `~/.hermes/profiles/*/state.db`

- [ ] **Step 1 : Lancer le backfill**

```bash
cd ~/.hermes/scripts/review-gate && ./run.sh backfill --board murmure 2> backfill-stderr.jsonl
```
Expected: `backfill : 19 lignes -> .../backfill/<date>` (19 demandes de revue au 2026-09-20, ou plus si le board a avancé). Coût attendu : moins de 0,001 $.

- [ ] **Step 2 : Lire le rapport et le taux de reconstitution**

```bash
cat backfill/$(date +%F)/report.md
```
Si les sessions retrouvées sont inférieures à la moitié, vérifier d'abord le repli par fenêtre temporelle (`sessions.find_session_id`) sur un cas précis avant toute autre conclusion : comparer `task_runs.started_at` à `sessions.started_at` du profil concerné.

- [ ] **Step 3 : Faire juger chaque dossier de divergence par un modèle fort**

Pour chaque fichier de `backfill/<date>/divergences/`, dispatcher un agent `opus` en revue adversariale avec le dossier complet et la question fermée : « Entre la gate (motif `gate_reason`) et le reviewer (`reviewer_reason`, ou acceptation), qui avait raison ? Réponds `gate`, `reviewer` ou `indécidable`, puis une phrase. » Consigner les verdicts dans le rapport.

- [ ] **Step 4 : Écrire le rapport dans le repo murmure**

`docs/research/2026-09-2X-review-gate-backfill.md` : le contenu de `report.md`, la table des verdicts du juge par dossier, et la conclusion sur les deux critères d'entrée en mode ombre (zéro omission sur les renvois historiques reconstituables ; faux renvois examinés un par un). Proposer, chiffres à l'appui, le seuil `block_noul` retenu et le nombre de jours de mode ombre. Ne pas changer `decisions.yaml` sans la décision de Louis.

- [ ] **Step 5 : Commit documentation (repo murmure)**

```bash
cd /Users/louiscourcier/Projects/murmure && git add docs/research/2026-09-2X-review-gate-backfill.md && git commit -q -m "docs(review-gate): rapport de backfill"
```

---

### Task 12 : Cron en mode ombre et README

**Files:**
- Create: `~/.hermes/scripts/review-gate/README.md`
- Modify: `~/.hermes/cron/jobs.json` via la CLI seulement

- [ ] **Step 1 : Écrire le README**

```markdown
# Gate de complétion du kanban (board murmure)

Vérifie qu'une carte passée en `review` est étayée avant que le reviewer ne la lise.
Conception et arbitrages : `~/Projects/murmure/docs/specs/2026-09-20-review-gate-design.md`.

## Flux

```
worker -> kanban_request_review -> carte en `review`
   -> gate.py (cron 2 min) : preuves (kanban.db, state.db, log, git) -> règles R1–R5
      -> Jev (typesafe/jev-1.13 via OpenRouter, POST /api/alpha/decisions) si aucune règle
      -> politique en code -> shadow : journal | enforce : `hermes kanban reopen-review --reason`
   -> decisions.jsonl (audit), snapshots/<task>/<run>.json (preuves figées)
```

## Commandes

```bash
./run.sh shadow                  # juge et journalise, n'agit pas
./run.sh enforce --dry-run       # montre ce qui serait renvoyé
./run.sh enforce                 # renvoie (exige mode: enforce dans decisions.yaml)
./run.sh backfill                # rejoue l'historique -> backfill/<date>/report.md
~/.hermes/hermes-agent/venv/bin/python -m pytest -q          # tests
~/.hermes/hermes-agent/venv/bin/python -m pytest -q -m live  # un appel Jev réel
```

## Registre

`decisions.yaml` : version, seuil `block_noul`, mode, questions, projets reconnus. Toute modification
de question ou de seuil incrémente `version`. Le passage `shadow -> enforce` est une décision de Louis.

## Ce que la gate n'est pas

- Pas un reviewer : « laissée en revue » ne veut pas dire « approuvée ».
- Pas une frontière de sécurité : le résumé du worker est du contenu potentiellement adversarial.
- Pas l'audit `review_audit.py` voisin (qui détecte les complétions sans revue) : complémentaire.

## Ne jamais

- importer `hermes_cli` ou modifier `~/.hermes/hermes-agent/` ;
- créer une carte avec `goal_mode = 1` sur ce board ;
- journaliser la clé OpenRouter, un résumé ou une sortie de test dans `decisions.jsonl`.
```

- [ ] **Step 2 : Enregistrer le cron en mode ombre**

```bash
hermes cron create "2m" --script review-gate/run.sh --no-agent --name murmure-review-gate --deliver local
hermes cron list | grep -A3 murmure-review-gate
```
Expected: le job apparaît `[active]`, `Schedule: every 2m`. Le cron lance `run.sh` sans argument ;
`gate.main` traite l'absence d'argument comme `shadow` (voir Task 9). Ajouter le test correspondant dans
`tests/test_gate.py` :

```python
def test_main_without_args_defaults_to_shadow_and_reports_missing_db(monkeypatch, tmp_path):
    import gate
    fake = gate.Paths(kanban_db=tmp_path / "absent.db", profiles_root=tmp_path, logs_dir=tmp_path,
                      snapshots=tmp_path / "s", audit_jsonl=tmp_path / "a.jsonl",
                      decisions_yaml=Path(__file__).resolve().parent.parent / "decisions.yaml")
    monkeypatch.setattr(gate.Paths, "default", staticmethod(lambda board: fake))
    assert gate.main([]) == 1          # base absente : code 1 ; aucune erreur d'argparse, donc le defaut a joue
```

- [ ] **Step 3 : Vérifier après deux cycles**

```bash
sleep 300; tail -5 ~/.hermes/scripts/review-gate/decisions.jsonl 2>/dev/null; hermes cron list | grep -A6 murmure-review-gate
```
Expected: `failure_streak` à 0 ; `decisions.jsonl` vide ou avec des lignes `mode: shadow` selon qu'une carte est passée en revue.

- [ ] **Step 4 : Commit**

```bash
cd ~/.hermes/scripts/review-gate && git add -A && git commit -q -m "docs: README ; cron shadow toutes les 2 minutes"
```

---

## Hors plan, décisions de Louis

- Passage `mode: shadow` → `mode: enforce` dans `decisions.yaml` après deux à trois jours de mode ombre sans omission, au vu du rapport de backfill et des lignes `decisions.jsonl` comparées aux verdicts réels du reviewer.
- Réglage final de `block_noul` sur la courbe du backfill.
- Ouverture d'un second fournisseur (SemIf local) : nouvelle tâche, nouvelle conception.

---

## Amendements datés (2026-09-20, pendant l'exécution)

Trois faits du plan se sont révélés faux sur la machine. Ils sont corrigés ici, pas bricolés dans le code.

### A1 — Le cron doit viser `run.sh`, pas `gate.py`

La conception §4.6 écrit `hermes cron add "2m" --script review-gate/gate.py`. Vérifié sur la machine :
les scripts de cron sont exécutés **par leur shebang** (`#!/usr/bin/env python3`), donc par le python du
système et non par le venv 3.11 — ce qui contredit la Global Constraint « toujours via `run.sh` », et
exposerait `gate.py` à un `pyyaml` absent. Les trois crons existants (`hindsight-monitor/watch.py`,
`hindsight-nous-token.py`) ont un shebang pour cette raison ; `fork-watch` passe par un `run.sh`.

**Décision** : le cron pointe `review-gate/run.sh` (qui `exec` le python du venv). La tâche 12 applique
cette forme :
```bash
hermes cron create 2m --name murmure-review-gate --no-agent --script review-gate/run.sh --deliver local
```

### A2 — `.superpowers/` entre dans le `.gitignore` de la tâche 0

Le workspace d'exécution (ledger, briefs, paquets de revue) vit dans
`review-gate/.superpowers/sdd/2026-09-20-review-gate/`. La ligne `.superpowers/` est ajoutée au
`.gitignore` de la tâche 0 en plus des quatre lignes écrites dans le plan ; ce dossier est de la
scratch git-ignorée, jamais du code livré.

### A3 — Le décompte du backfill est mesuré, pas supposé

Le design §5 annonce 18 `review_requested` ; le brief en annonce 19. Mesure sur
`~/.hermes/kanban/boards/murmure/kanban.db` au 2026-09-20 : **19 événements sur 14 cartes distinctes**,
5 `changes_requested`, 36 `completed`. Le backfill rejoue les 19 événements, agrège par carte (14) et
le rapport porte les deux chiffres. Un événement `review_requested` multiple sur une même carte est un
run distinct : la clé d'idempotence reste `(task_id, run_id)`.

### A4 — Les fixtures utilisent les schémas **réels**, pas des schémas écrits à la main

La conception §7 (autorité) exige « `hermes_cli.kanban_db.SCHEMA_SQL`, et le schéma de `state.db` copié à
l'identique ». La tâche 0 du plan écrivait deux schémas simplifiés à la main — `messages` y perd 16
colonnes, `sessions` en perd 55 — et les tests auraient donc validé le code contre un schéma qui
n'existe pas. Contrainte mesurée, qui justifie la règle : sur le schéma réel, `sessions` a 59 colonnes
et exige `source` + `started_at` ; `messages` en a 26 et exige `session_id`, `role`, `timestamp`.
Sous le schéma écrit à la main, aucune de ces exigences n'existait : les helpers auraient inséré des
lignes impossibles en production.

**Décision** : `kanban.db` de fixture est construit par `hermes_cli.kanban_db.SCHEMA_SQL` (importé dans
`tests/conftest.py` seulement ; les modules de production restent sans import de `hermes_cli`), et
`state.db` de fixture par `tests/schema/state_schema.sql` — dump **verbatim** du DDL réel des deux
tables que la gate lit (`sessions`, `messages`) et de leurs index, fourni dans le workspace d'exécution
(`state_schema.sql`, 4 596 o), à committer tel quel.

Les helpers passent en `INSERT` à **colonnes nommées** et fournissent les colonnes obligatoires du
schéma réel :

```
tasks        (41 colonnes), obligatoires hors PK : ['title', 'status', 'created_at']
  task_runs    (17 colonnes), obligatoires hors PK : ['task_id', 'status', 'started_at']
  task_events  (6 colonnes), obligatoires hors PK : ['task_id', 'kind', 'created_at']
  sessions     (id, source, started_at) ... obligatoires : source, started_at
  messages     (session_id, role, timestamp) ... obligatoires
```

### A5 — `run_id` est un entier, pas une chaîne

Mesuré sur `~/.hermes/kanban/boards/murmure/kanban.db` : `task_events.run_id` est de type `integer`, et
`task_runs.id` est `INTEGER PRIMARY KEY AUTOINCREMENT` (112 lignes, toutes entières). Le schéma écrit à
la main de la tâche 0 (`task_runs id TEXT PRIMARY KEY`) et la signature `run_id: str` de la tâche 4
étaient donc fausses, et les fixtures de la tâche 0 ont cessé d'accepter une chaîne dès qu'elles ont
utilisé le schéma réel (`'run_abc'` → `datatype mismatch`).

**Décision** : partout où la valeur vient de la base, `run_id` est un `int` — `ReviewRequest.run_id`,
`EvidenceSnapshot.run_id`, `BackfillRow.run_id` — et `task_events.event_id` reste l'entier
autoincrement de l'événement. Les chemins de snapshot et d'audit le formatent (`f"{run_id}"`), la ligne
d'audit JSONL porte la valeur telle quelle (entier), et la clé d'idempotence reste `(task_id, run_id)`.
Les tests unitaires qui n'ouvrent pas de base (tâches 5 et 7) peuvent garder une valeur d'exemple
quelconque, mais un entier évite d'accréditer une chaîne.

### A6 — Les identifiants de run sont des entiers dans TOUS les tests (tâches 2, 9, 10)

**Fait mesuré (tâche 2, par l'implémenteur, vérifié) :** `conftest.insert_run` écrit dans `task_runs.id`, qui est `INTEGER PRIMARY KEY AUTOINCREMENT` dans le schéma RÉEL devenu la référence par A4. Passer `"r_a"` y lève `sqlite3.IntegrityError: datatype mismatch` — ce n'est pas une assertion qui échoue, c'est le montage de fixture qui casse. Les tests des tâches 2, 9 et 10 passaient des identifiants de run **chaînes** (`"r_a"`, `"r_b"`, `"r_1"`, `"r_2"`), hérités du schéma écrit à la main de la tâche 0 (`task_runs id TEXT PRIMARY KEY`). Leurs `Expected: N passed` étaient donc inatteignables : la tâche 2 l'a prouvé (`4 failed`, tous en `datatype mismatch` à `conftest.py:90`), et l'implémenteur a validé `kanban.py` inchangé en copie isolée avec des identifiants entiers (`4 passed`, puis `11 passed`).

Note de précision : `task_events.run_id` a une affinité INTEGER mais n'est PAS une clé primaire, donc SQLite y accepte du texte ; c'est `task_runs.id` seul qui refuse. Comme la requête joint `task_runs r ON r.id = e.run_id`, l'identifiant doit être du même type des deux côtés : entier partout.

**Décision :** les identifiants de run sont des **entiers** dans tous les tests et toutes les fixtures.

- Tâche 2 : `_card(kanban_db, "t_a", 1, …)`, `_card(kanban_db, "t_b", 2, …)`, `insert_run(kanban_db, 2, "t_a", …)`, `insert_event(kanban_db, "t_a", 2, "review_requested", …)`, `insert_event(kanban_db, "t_a", 1, "changes_requested", …)` ; les assertions suivent : `(1, "fait", "dev", "dev")`, `reqs[0].run_id == 2`, `[r.run_id …] == [1, 2]` ; `ground_truth(conn, "t_a", 1000)` inchangé (la borne reste un horodatage).
- Tâche 2 (production `kanban.py`) : `ReviewRequest.run_id: int` et `run_id=row["run_id"]` (le `or ""` était le garde-fou de l'époque chaîne ; A5 a déjà déclaré la valeur entière).
- Tâche 9 : `insert_task(kanban_db, "t_1", …, run_id=1)`, `insert_run(kanban_db, 1, "t_1", …)`, `insert_event(kanban_db, "t_1", 1, "review_requested", …)`.
- Tâche 10 : les identifiants passés à `insert_run`/`insert_event` par `rid` sont des entiers.
- Annotations alignées sur A5 : `ReviewRequest.run_id` (tâche 2), `EvidenceSnapshot.run_id` (tâche 4), `BackfillRow.run_id` (tâche 10) → `int`. Les exemples EN MÉMOIRE des tâches 5, 7 et 8 (`run_id="r"` dans un dict de dataclass, sans base) restent inchangés : ils ne touchent aucune colonne et n'affirment rien sur le type.
- Inchangé : les horodatages (`created_at`, `event_created_at`, `started_at`, `ended_at`) restent des secondes epoch, entières côté `kanban.db` — la borne de `ground_truth` en est un.

### A7 — `ground_truth` : une décision prise dans la même seconde que la demande compte

**Fait mesuré (revue de la tâche 2, confirmé) :** `ground_truth(conn, task_id, event_created_at)` comparait `created_at > ?`. Quand un `changes_requested` ou un `completed` porte **exactement** le même `created_at` (granularité : la seconde) que la `review_requested`, la fonction rend `"pending"` alors que la carte est tranchée — un échec **silencieux**, et c'est exactement la mesure qui porte le critère « zéro omission » de la conception §5. Le test du brief ne peut pas l'attraper (ses écarts sont 1000 → 1100 et 2000 → 2100).

Aujourd'hui **latent** : 0 cas sur 19, écart minimal mesuré entre une demande et sa décision = 143 s. Il devient possible dès qu'une décision s'écrit sans passage humain (mode `enforce`, décision de la gate) ou qu'un reviewer répond dans la seconde.

**Décision : comparer `created_at >= ?`,** sans changer la signature `(task_id, event_created_at)`. Deux raisons : le filtre `kind IN ('changes_requested','completed')` exclut l'événement `review_requested` lui-même, donc `>=` ne peut pas s'auto-apparier sur la demande ; et le biais choisi (compter une décision ambiguë comme tranchée) va dans le sens du critère de la conception — rattraper tous les renvois — plutôt que de sous-compter. Le test de la tâche 2 est complété par un cas de décision à la seconde identique, pour figer le comportement.

### A8 — Le lien run → session se désambiguïse par la fenêtre du run

**Fait mesuré (tâche 3) :** `find_session_id` retenait `found[-1]`, c'est-à-dire la DERNIÈRE session trouvée dans le fichier de log. Or un log de carte accumule les sessions de toute la vie de la carte : mesuré sur les 36 logs réels de `~/.hermes/kanban/boards/murmure/logs/`, la plupart en portent plusieurs, jusqu'à **17** distinctes (`t_8209b942.log`). Parmi les cartes du backfill : `t_07112ae3` (5), `t_2fd54093` (5), `t_608e71ef` (5), `t_6d617129` (6), `t_4a3570b9` (3), `t_556bcfb1` (3), `t_50536cef` (2).

**Conséquence :** pour un run historique, cette règle rattache les appels d'outils d'un run POSTÉRIEUR. Or c'est de cette session que se dérivent `tests_ran`, la commande et le code de sortie du dernier test, `tests_last_ran_before_last_edit` et les fichiers observés — donc les règles R1, R2, R3 et R5 jugeraient un run avec les preuves d'un autre. C'est exactement le faux renvoi que la conception §4.5 veut rendre impossible, et le backfill mesurerait sa performance sur des preuves décalées.

La conception (§3, ligne 73) ordonne : trailer du log, puis `tasks.session_id`, puis une session de `state.db` — elle ne dit rien du cas « plusieurs trailers », alors que la signature `find_session_id(log_paths, task_session_id, state_db, run_started_at, run_ended_at)` reçoit précisément la fenêtre et la base pour trancher.

**Décision :** parmi les identifiants candidats lus dans les logs (fichier courant puis rotaté), retenir celui dont l'enregistrement de `state.db` **chevauche la fenêtre du run** `[run_started_at, run_ended_at]`. Si aucun candidat ne chevauche, ou si `state_db` ne permet pas de trancher, garder le comportement actuel (dernier trailer) : le défaut redevient alors celui d'aujourd'hui, jamais pire. L'ordre de repli de la conception (`tasks.session_id`, puis state.db) est conservé pour le reste.

**Coût si faux :** une session mal choisie reste une session de la MÊME carte (les trailers sont lus dans le log de la carte), donc on ne peut pas juger un run avec les preuves d'un autre dépôt — seulement avec celles d'une autre fenêtre de temps.

### A9 — Trois défauts de `evidence.py` tranchés (borne de l'état, chemins git, détection d'écriture)

La revue de la tâche 4 a relevé trois défauts du code du brief, tous **plan-mandated** (le code vient du plan, l'implémenteur l'a copié verbatim). Ils vivent tous dans la couche des preuves, dont dépendent la tâche 6 (l'état envoyé à Jev) et les règles R1 à R5.

**1. `state_for_model(max_chars)` ne borne pas `max_chars`, et la brèche est atteignable à la valeur configurée.** Les trois leviers du brief (`tail` → 500, `changed_files` → 50, `summary` → 200) laissent intacts `last_test_command` et la longueur individuelle des chemins. Mesuré par la revue avec le code du dépôt et `max_state_chars = 12000` : une commande de test de 5 000 caractères plus 50 chemins de 150 caractères donnent un état de **14 428 caractères**, avec la commande intacte à 5 020. Conséquence en tâche 6 : l'état dépasse le plafond du registre (conception §4.4), donc le budget de coût et de latence, et un rejet 422 peut être pris pour « Jev indisponible » (le commentaire « gate indisponible » de §4.5 devient trompeur).
**Décision :** ajouter deux leviers avant le `break` : `last_test_command` tronquée à **400 caractères** (marqueur de troncature explicite) et chaque chemin **clippé à 120 caractères** dans toutes les listes. Bornage du pire cas : 50 × 120 + 400 + 200 + 500 ≈ 7 100 caractères, sous 12 000. Interdit : tronquer la chaîne finale de l'état (elle est sérialisée, une coupe aveugle la rendrait invalide). Un test doit couvrir le pire cas (commande de 5 000 caractères + 50 chemins de 150) et vérifier la borne à 12 000 **et** à 2 000.

**2. `changed_files_git` citait les chemins, ce qui produit un `test_files_touched = false` mensonger — donc un motif de renvoi faux, exactement ce que §4.5 veut éviter.** La sortie porcelain cite et échappe les chemins non ASCII ou porteurs d'espaces (mesuré : `?? "avec espace.swift"`, `?? "accentu\303\251_t\303\252st.swift"`), et le split `" -> "` invente un nom pour un fichier qui contient littéralement ` -> `. Les motifs ANCRÉS du registre (`^tests/`, `Test\.swift$`) ne matchent alors plus les chemins cités, alors que R5 renvoie la carte sur ce seul fait.
**Décision :** lire `git status --porcelain -z --untracked-files=all` (enregistrements séparés par NUL, sans guillemets ni échappements) et parser par enregistrements NUL, renommages compris, sans jamais passer par le split de la forme `" -> "`. Un test doit créer des fichiers dont les noms contiennent un espace, un accent et ` -> `, et vérifier que les chemins rendus sont les vrais (et qu'un motif ancré les matche).

**3. La détection d'écriture oublie la redirection, que la conception §4.1 nomme explicitement.** `TERMINAL_WRITE` couvre `sed -i`, `git apply`, `git checkout --`, `git stash pop`, les outils d'édition et `execute_code`, mais ni `>` ni `>>` : un worker qui écrit `cat > Sources/A.swift` ou un heredoc après son dernier test obtient `edits_after_last_test = False`, donc R4 ne se déclenche pas — faux négatif silencieux, contre le principe « bloquer au moindre doute » de §4.5.
**Décision :** compter comme écriture une redirection `>` ou `>>` vers un **chemin** — en excluant `/dev/null`, les cibles sous `/tmp` ou `$TMPDIR`, et les extensions de journalisation (`.log`, `.txt`), qui ne sont pas des modifications de code. `tee` reste **non** compté : son usage réel est la journalisation, et le compter ferait déclencher R4 sur des workers qui ne font que consigner la sortie de test — un faux « relance les tests » serait aussi un défaut au sens de §4.5. Trois cas de test exigés : `cat > Sources/A.swift` = écriture ; `echo x >> log.txt` = non-écriture ; `| tee log` = non-écriture (limite assumée, à écrire dans le code).

### A10 — La détection de redirection doit viser un OPÉRATEUR hors guillemets et une cible qui est un chemin

La re-revue du round 1 de la tâche 4 a montré que le correctif du constat 3 de A9 était trop large : il produit des faux positifs de R4, c'est-à-dire un renvoi « relance les tests » sur un worker qui n'a rien écrit — la classe de défaut qu'A9 avait explicitement refusée en écartant `tee`. Deux reproduteurs mesurés sur le code du round :

1. Un `>` **à l'intérieur d'une chaîne quotée** est pris pour une redirection : `grep -rn "->" src` rend une cible `"` qui n'est pas un chemin et n'est jamais exclue — de même `git log --format="%h -> %s"`, `echo "a > b"`, `jq ".a > .b" f.json`. Or ces commandes sont des LECTURES, et elles arrivent après le dernier test dans la vie normale d'un worker (chercher, consigner, formater).
2. La graphie **littérale** que A9 nomme n'est pas exclue : `cat > $TMPDIR/out.swift` et `cat > ${TMPDIR}/out.swift` sont comptés comme écriture. La cause est que `ToolCall.arguments` sont enregistrés **non expansés** (le texte de la commande tel que l'agent l'a écrite), alors que le code compare l'expansion de l'environnement du relecteur. Le test du round injectait la forme expansée (`/var/folders/...`), donc il ne pouvait pas attraper le cas.

**Décision :** ne reconnaître `>`/`>>` comme opérateur d'écriture que hors guillemets (jeton d'opérateur obtenu par `shlex.shlex(cmd, punctuation_chars=True)`, ou équivalent), et ne compter la redirection que si la cible ressemble à un chemin : non vide après retrait des guillemets, et contenant soit un séparateur `/`, soit une extension de fichier. Exclure en plus les graphies littérales `$TMPDIR` et `${TMPDIR}`, puisque les arguments sont stockés non expansés. Les exclusions déjà en place (`/dev/null`, `.log`, `.txt`, `/tmp`, `/private/tmp`, `$TMPDIR` expansé) restent valides. `tee` reste **non** compté, inchangé.

**Preuves exigées** (en plus des 9 cas déjà verts, qui doivent le rester) : `grep -rn "->" src` → non-écriture ; `git log --format="%h -> %s"` → non-écriture ; `echo "a > b"` → non-écriture ; `cat > $TMPDIR/out.swift` → non-écriture ; `cat > ${TMPDIR}/out.swift` → non-écriture. Et les positifs restent positifs : `cat > Sources/A.swift` → écriture ; `cat >Sources/B.swift` → écriture.

### A11 — Les formes `&>` `&>>` `<>` sont des redirections, pas des non-redirections

La re-revue du round 2 a mesuré une **régression** introduite par le passage au découpage shell : `shlex(..., punctuation_chars=True)` rend `&>` (et `&>>`, `<>`) comme **un seul jeton**, si bien que le filtre `tok.startswith(">")` les écarte. Mesuré : `swiftc A.swift &> Sources/C.swift`, `make &>> Sources/C.swift`, `cat <> out.swift` comptaient comme écriture dans la version d'origine et ne comptent plus. Aucune clause d'A9 ni d'A10 ne couvrait ce prix — le prix assumé d'A10 était « cible sans `/` ni extension ». Un worker qui écrit un fichier de code avec `&>` court-circuiterait donc R4, un faux négatif silencieux.

**Décision :** admettre aussi les jetons de redirection dont le préfixe de ponctuation contient `<` ou `&` (`&>`, `&>>`, `<>`), avec un cas de test par forme, toutes les autres règles d'A10 inchangées (cible qui ressemble à un chemin, exclusions de A9, `tee` non compté). La re-revue note en outre que la garde `len(mask) != len(tokens)` n'est exercée par aucun test : à couvrir à bon marché tant que le code est ouvert.

### A12 — Seule une forme de redirection EXÉCUTABLE sous le shell du harnais peut compter comme écriture (`&>>` retiré)

La re-revue du round 3 a mesuré que A11 était **en tort sur un jeton**. Fait établi, reproduit par le reviewer dans le shell du harnais lui-même : le shell des commandes est `/bin/bash` **3.2.57** (Apple), et `&>>` **non quoté** y est une erreur de syntaxe **fatale au niveau de la ligne entière** — la commande n'est jamais exécutée, donc elle ne peut pas écrire. Contre-épreuves mesurées : `&>` crée réellement son fichier, `<>` aussi, `zsh -c '… &>> …'` réussit (mais une forme quotée est de toute façon masquée par `_mask_quoted`, donc déjà non comptée). L'entrée `&>>` d'A11 n'achetait donc **rien** sur cette machine, alors que son comptage produit un état de preuve **faux** : `edits_after_last_test` est un `any(...)` sur les appels postérieurs au dernier test, donc l'état final affirme « le dernier test a été exécuté avant la dernière modification » alors que la commande n'a jamais tourné — exactement la classe de défaut que ce chantier élimine (comme `tee` et le `>` quoté).

**Décision :** `REDIRECT_TOKENS` devient `("&", "<>")` — c'est-à-dire `("&>", "<>")` — et `&>>` en sort, avec un commentaire nommant la mesure (bash 3.2.57 : `&>>` non quoté = erreur de syntaxe, donc jamais une écriture ; la forme quotée est masquée). `&>` et `<>` restent comptés : mesuré, ils écrivent réellement. Le test `test_amp_append_redirect_counts_as_write` doit être **inversé** (le cas devient non-écriture) et renommé pour dire pourquoi. Le cas `make &>> build.log` reste non-écriture, mais désormais pour une seconde raison (jeton non reconnu en plus de l'exclusion `.log`).

**Règle générale à retenir :** une forme de redirection ne peut compter comme écriture que si elle est **exécutable sous le shell qui exécute réellement les commandes** — le comptage ne mesure pas une propriété du texte, mais une propriété de la commande telle qu'elle sera lancée. Vérifier le shell avant d'ajouter une forme.

### A13 - Juge de divergence du backfill : deepseek-flash (decision de Louis, 2026-09-20)

La conception 8.5 prevoit pour les divergences du backfill un juge sur un modele FORT (Opus), en
revue adversariale a question fermee. Louis a tranche le 20/09/26 : le juge tourne sur
`deepseek-flash`, comme toute la flotte. Aucun modele payant n'est invoque par ce chantier.
Le role et la methodologie du juge (revue adversariale, question fermee, une divergence a la
fois) restent ceux de la conception : seule la classe de modele change.

### A14 - Une reponse HTTP 200 malformee n'est PAS un verdict

Trou identifie a l'execution de la tache 6 et signale par son implementeur : `decide.py` ne valide
`answers` qu'en tant que `dict`. Une reponse structurellement valide mais inexploitable (question
absente, `noul` non numerique, `choice` hors options, `answers` vide) atteindrait donc `policy.py`
sans garde. Or la conception 4.5 range l'absence de verdict utilisable dans la meme branche que
l'indisponibilite du fournisseur : LAISSER en revue avec le motif « gate indisponible, non juge »,
jamais un renvoi, et surtout jamais un « conforme ».

Decision : `policy.decide_action` traite une reponse inexploitable — `decision=None` OU entree de
question absente OU `noul` non numerique OU `choice` hors options connues — comme
`leave_unjudged`. Justification : un « laissez-passer » par defaut fausserait la mesure meme du
backfill (le taux de rattrapage des renvois serait gonfle par des reponses que le modele n'a jamais
rendues), et 4.6 exige qu'un non-verdict soit visible comme tel dans l'audit. Le mode `enforce`
n'est pas concerne differemment : sans verdict il n'y a rien a renvoyer.
