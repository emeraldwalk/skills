---
name: skill-authoring
description: Guides authoring, refining, and evaluating Claude agent skills. Use when creating a new skill, improving an existing skill, reviewing skill quality, or applying skill best practices. Extends skill-creator with evaluation-driven development, anti-patterns, feedback loops, and the full authoring checklist.
---

# Skill Authoring

This skill extends [skill-creator](../skill-creator/SKILL.md) with advanced authoring practices. Read skill-creator first for the foundational workflow (init, edit, package, iterate). This skill covers deeper authoring decisions and quality assurance.

## Core Principles (Supplement to skill-creator)

### Test Across Models

Skills behave differently depending on the model. Test with all models you plan to use:

- **Haiku**: Does the skill provide enough guidance?
- **Sonnet**: Is the skill clear and efficient?
- **Opus**: Does the skill avoid over-explaining?

### Naming Conventions

Use **gerund form** for skill names: `processing-pdfs`, `analyzing-spreadsheets`, `managing-databases`.

- Only lowercase letters, numbers, hyphens
- Max 64 characters
- No reserved words: `anthropic`, `claude`

### Descriptions: Write in Third Person

The description is injected into the system prompt. Inconsistent point-of-view causes discovery problems.

- **Good**: "Processes Excel files and generates reports"
- **Bad**: "I can help you process Excel files"
- **Bad**: "You can use this to process Excel files"

Max 1024 characters. Include both what the skill does and specific triggers/contexts.

## Evaluation-Driven Development

**Create evaluations BEFORE writing extensive documentation.**

1. **Identify gaps**: Run Claude on representative tasks without the skill. Document specific failures
2. **Create evaluations**: Build ≥3 scenarios testing those gaps
3. **Establish baseline**: Measure Claude's performance without the skill
4. **Write minimal instructions**: Just enough to address gaps and pass evaluations
5. **Iterate**: Execute evaluations, compare against baseline, refine

Evaluation structure:
```json
{
  "skills": ["my-skill"],
  "query": "Extract all text from this PDF and save to output.txt",
  "files": ["test-files/document.pdf"],
  "expected_behavior": [
    "Reads PDF using an appropriate library",
    "Extracts text from all pages",
    "Saves extracted text to output.txt"
  ]
}
```

## Developing Skills Iteratively with Claude

Use two Claude instances: **Claude A** (skill author/refiner) and **Claude B** (skill user/tester).

1. Complete a task with Claude A using normal prompting — note what context you repeatedly provide
2. Ask Claude A: "Create a skill capturing this pattern we just used"
3. Review for conciseness: "Remove the explanation about X — Claude already knows that"
4. Test with Claude B (fresh instance with skill loaded) on real tasks
5. Observe Claude B's behavior: Where does it struggle? What does it miss?
6. Return to Claude A with specifics: "Claude B forgot to filter test accounts — make this more prominent"

### What to Observe in Claude B

- **Unexpected file access order** → structure may not be intuitive
- **Missed file references** → links need to be more explicit or prominent
- **Overreliance on one section** → that content may belong in SKILL.md
- **Ignored files** → may be unnecessary or poorly signaled

## Workflows and Feedback Loops

### Checklist Pattern for Complex Tasks

For multi-step workflows, provide a progress checklist Claude copies into its response:

````markdown
## PDF form filling workflow

Copy this checklist and check off as you complete each step:

```
Task Progress:
- [ ] Step 1: Analyze form (run analyze_form.py)
- [ ] Step 2: Create field mapping (edit fields.json)
- [ ] Step 3: Validate mapping (run validate_fields.py)
- [ ] Step 4: Fill the form (run fill_form.py)
- [ ] Step 5: Verify output (run verify_output.py)
```
````

### Feedback Loop Pattern

**Run validator → fix errors → repeat** significantly improves output quality.

```markdown
## Document editing process

1. Make your edits to `word/document.xml`
2. **Validate immediately**: `python scripts/validate.py unpacked_dir/`
3. If validation fails: review error, fix XML, run validation again
4. **Only proceed when validation passes**
5. Rebuild: `python scripts/pack.py unpacked_dir/ output.docx`
```

### Plan-Validate-Execute Pattern

For high-stakes or batch operations, have Claude produce a structured plan first, validate it with a script, then execute:

Analyze → **create plan file** → **validate plan** → execute → verify

Make validation scripts verbose: `"Field 'signature_date' not found. Available fields: customer_name, order_total"` so Claude can self-correct.

## Content Guidelines

### Avoid Time-Sensitive Information

**Bad** (will become wrong):
```markdown
If you're doing this before [some date], use the old API.
After [some date], use the new API.
```

**Good** (use a collapsed "old patterns" section):
```markdown
## Current method
Use the v2 API: `api.example.com/v2/messages`

## Old patterns
<details>
<summary>Legacy v1 API (deprecated)</summary>
The v1 API used: `api.example.com/v1/messages` — no longer supported.
</details>
```

### Use Consistent Terminology

Choose one term and use it throughout. Don't mix "API endpoint" / "URL" / "path", or "field" / "box" / "element".

## Anti-Patterns to Avoid

| Anti-pattern | Problem | Fix |
|---|---|---|
| Windows-style paths (`scripts\helper.py`) | Breaks on Unix | Use forward slashes always |
| Too many options ("you can use X, Y, or Z...") | Confusing | Pick a default; mention alternatives only as escape hatches |
| Magic constants (`TIMEOUT = 47`) | Claude can't justify them | Document the reasoning |
| Punting errors to Claude (`return open(path).read()`) | Fragile | Handle errors explicitly in scripts |
| Assuming packages are installed | Runtime failures | Explicitly list and install dependencies |
| Nested references (SKILL.md → a.md → b.md) | Claude may partial-read and miss content | Keep all references one level deep |

## Scripts: Additional Guidance

### Solve, Don't Punt

Handle errors in scripts rather than letting them bubble to Claude:

```python
def process_file(path):
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        print(f"File {path} not found, using empty default")
        return ""
    except PermissionError:
        print(f"Cannot read {path}, using empty default")
        return ""
```

### Make Execution Intent Explicit

- "Run `analyze_form.py` to extract fields" → Claude executes it
- "See `analyze_form.py` for the extraction algorithm" → Claude reads it

### MCP Tool References

Always use fully qualified names to avoid "tool not found" errors:

```markdown
Use the BigQuery:bigquery_schema tool to retrieve table schemas.
```

Format: `ServerName:tool_name`

## Quality Checklist

Before packaging a skill, verify:

**Core quality**
- [ ] Description is specific, includes key terms, written in third person
- [ ] Description includes both what the skill does and when to use it
- [ ] SKILL.md body is under 500 lines
- [ ] No time-sensitive information (or placed in "old patterns" section)
- [ ] Consistent terminology throughout
- [ ] File references are one level deep from SKILL.md
- [ ] Longer reference files (>100 lines) have a table of contents

**Code and scripts**
- [ ] Scripts handle errors explicitly (no punting to Claude)
- [ ] No undocumented "magic" constants
- [ ] Required packages listed and verified available
- [ ] No Windows-style paths
- [ ] Validation/feedback loops included for critical operations

**Testing**
- [ ] At least three evaluations created
- [ ] Tested with Haiku, Sonnet, and Opus (or all target models)
- [ ] Tested with real usage scenarios
- [ ] Team feedback incorporated (if applicable)
