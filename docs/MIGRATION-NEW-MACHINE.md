# Karen: migrate to a new Mac

Audited 2026-10-06 on the old machine. Order matters.

## 0. Before you wipe the old Mac

```bash
cd ~/projects/agent-scaffold
git status --short          # 7 modified files at audit time
git add -A && git commit -m "wip: pre-migration checkpoint"
git push                    # was 5 commits ahead of origin/main
```
The global `agent-karen` package is an `npm link` into this repo, NOT a registry
install. Unpushed work here = Karen's actual source.

Also back up (none of this is in git):
- `~/.karen/` entirely — `config.yaml` (project registry), `fleet.env` (SENTRY_API_TOKEN,
  SENTRY_ORG), `hub/` (communications.md, inbox/, memory/, knowledge/, state/)
- any project with uncommitted work (`~/projects/*`)

```bash
tar czf ~/karen-backup-$(date +%Y%m%d).tgz -C ~ .karen
```

## 1. Prerequisites on the new Mac

| Thing | Install | Notes |
|---|---|---|
| Homebrew | https://brew.sh | puts node under /opt/homebrew |
| Node 22 | `brew install node` | old machine ran v22.22.0 |
| jq | preinstalled on macOS | /usr/bin/jq |
| cmux | https://cmux.io (cmux.app) | ships its own `claude` binary at `/Applications/cmux.app/Contents/Resources/bin/` |
| Claude Code | comes with cmux, or `npm i -g @anthropic-ai/claude-code` | v2.1.292 |
| beads (`bd`) | `npm i -g @beads/bd` | v0.60.0; lands in ~/.local/bin or /opt/homebrew/bin |

Then `claude` once and `/login`.

## 2. Install Karen

Dev mode (what the old machine did — pick this if you still hack on Karen):
```bash
git clone https://github.com/sivaranjansahu/agent-karen.git ~/projects/agent-scaffold
cd ~/projects/agent-scaffold && npm link
```

Plain mode (if you just want to use it):
```bash
npm i -g agent-karen
```

Verify: `karen --help` and `ls -la /opt/homebrew/lib/node_modules/agent-karen`.

## 3. Restore the hub

```bash
tar xzf ~/karen-backup-YYYYMMDD.tgz -C ~
ls ~/.karen/hub/{inbox,memory,knowledge,state} ~/.karen/hub/communications.md
chmod 600 ~/.karen/fleet.env
```

`~/.karen/config.yaml` lists ~26 projects by path (`~/projects/...`). Every path must
exist on the new machine or that project's manager won't boot. Prune the dead entries
rather than cloning repos you no longer use.

## 4. Re-create the project checkouts

Clone each repo listed in `config.yaml` back to the same path. Per-project Karen state
lives inside the repo and travels with git:
- `<project>/.agent/` — role CLAUDE.md, context/, decisions.md
- `<project>/.beads/` — issues ride in `interactions.jsonl` (tracked); the `dolt/`
  directory is gitignored and rebuilds locally on first `bd` command

Do not copy `.beads/dolt/`, `dolt-server.pid`, `dolt-server.lock`, `bd.sock`, or
`~/.cmux/cmux.sock` — all machine-local runtime files.

## 5. Smoke test

```bash
karen init                    # in a project dir, if it's a fresh project
bd quickstart                 # issues restored?
$AGENT_SCAFFOLD_ROOT/scripts/spawn.sh pm "smoke test: reply with OK and exit"
sleep 25 && $AGENT_SCAFFOLD_ROOT/scripts/health.sh
tail -20 $KAREN_HUB_DIR/communications.md
```

Green = spawn.sh opened a cmux workspace, health.sh shows the agent alive, and the
reply landed in communications.md.

## Known gotchas

- `KAREN_HUB_DIR` / `AGENT_SCAFFOLD_ROOT` are not in `~/.zshrc` — cmux/spawn.sh inject
  them. If they're empty in a plain terminal, that's expected.
- `~/projects/agent-karen` is a symlink to `~/projects/.agent`. Recreate with
  `ln -s .agent ~/projects/agent-karen`.
- `~/.claude/skills` was 1.2 GB. Copy it only if you want the installed skill set;
  plugins (90 MB) reinstall themselves.
- Other global npm tools in use: claude-jarvis, agent-browser, pi-coding-agent,
  repomix, vercel, firecrawl-cli.
