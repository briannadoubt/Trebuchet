# Trebuchet Skills

Custom slash commands for common Trebuchet development workflows.

## Available Skills

| Command | Description |
|---------|-------------|
| `/rebuild` | Rebuild the trebuchet CLI binary in release mode |
| `/dev-test` | Run the complete dev server test workflow for Aura |
| `/test` | Run Trebuchet test suites (asks which suite) |
| `/test-aws` | Run AWS integration tests with LocalStack |
| `/verify-streaming` | Verify streaming fix implementation is correct |
| `/ci` | Run full CI checks locally (build + test + warnings) |
| `/changelog` | Update CHANGELOG.md with categorized entries |
| `/release` | Create a new semantic version release tag |

## Usage

In Claude Code chat, type the slash command:

```
/rebuild
```

Claude will execute the skill's instructions automatically.

## Skill Structure

Each skill is in its own directory:

```
.claude/skills/
├── rebuild/
│   └── SKILL.md
├── dev-test/
│   └── SKILL.md
└── ...
```

Each `SKILL.md` has YAML frontmatter with metadata:

```yaml
---
name: rebuild
description: Rebuild the trebuchet CLI binary
---

Instructions for Claude to execute...
```

## Adding New Skills

1. Create a new directory: `.claude/skills/<skill-name>/`
2. Create `SKILL.md` with YAML frontmatter
3. Add instructions for Claude to follow
4. The skill becomes available as `/<skill-name>`

## Skill Scope

These skills are **project-specific** (in `.claude/skills/`).

For personal skills across all projects, use: `~/.claude/skills/<skill-name>/SKILL.md`

## Documentation

For more about skills, see: https://docs.anthropic.com/claude-code/skills
