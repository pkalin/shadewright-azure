# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

## Claude Code specifics

- `.claude/settings.json` asks before `terraform apply`, `destroy`, `import`, `state` changes and any `az` write. `fmt`, `validate` and `plan` are allowed.
- Your subscription, tenant and IP go in git-ignored `CLAUDE.local.md`, never here.
