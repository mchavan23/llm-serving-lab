# Build log

Running record of what was done, what broke, and why. Written as I go —
this is the raw material for the benchmark report in week 6.

Format: date, what I was trying to do, what happened, what fixed it.

---

## 2026-09-13 — Repo bootstrap

- WSL2 Ubuntu 24.04 confirmed. Canonical working copy is `~/aify/llm-serving-lab`
  inside the WSL filesystem, *not* on `/mnt/c` (drvfs is slow, mangles permission
  bits, and inotify doesn't fire there).
- Repo skeleton, .gitignore, .env.example created.
- Open: Docker Desktop WSL integration not yet enabled for this distro.
