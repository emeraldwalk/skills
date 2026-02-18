---
name: skill-authoring
description: Guides authoring, refining, and evaluating Claude agent skills. Use when creating a new skill, improving an existing skill, reviewing skill quality, or applying skill best practices. Use when the user mentions SKILL.md, skill descriptions, skill naming, skill evaluation, or asks how to write or improve a skill.
---

# Skill Authoring

Extends [skill-creator](../skill-creator/SKILL.md) — read that first for the foundational workflow. This skill covers authoring quality, evaluation, and iteration.

## Naming and Description Rules

**Names**: Use gerund form — `processing-pdfs`, `analyzing-spreadsheets`. Only lowercase letters, numbers, hyphens. Max 64 characters. No reserved words: `anthropic`, `claude`.

**Descriptions**: Always third person. Injected into system prompt — inconsistent POV causes discovery failures.
- Good: `"Processes Excel files and generates reports"`
- Bad: `"I can help you..."` / `"You can use this to..."`

Include: what the skill does + specific keyword triggers for when to use it. Max 1024 characters.

## Evaluation-Driven Development

Create evaluations **before** writing extensive documentation — ensures you're solving real gaps, not imagined ones.

1. Run Claude on representative tasks without the skill — document specific failures
2. Build ≥3 evaluation scenarios targeting those gaps
3. Write minimal instructions to pass them
4. Iterate based on results

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

## Iterating with Two Claude Instances

**Claude A** authors/refines the skill. **Claude B** tests it on real tasks.

1. Complete a task with Claude A via normal prompting — note what context you repeatedly provide
2. Ask Claude A to create a skill capturing that pattern
3. Challenge each addition: "Does Claude really need this? Can I assume Claude knows this?"
4. Test with Claude B (fresh instance, skill loaded) on real tasks
5. Observe: where does Claude B struggle or miss something?
6. Return to Claude A with specifics: "Claude B forgot to filter test accounts — make this more prominent"

**What to watch in Claude B:**
- Unexpected file access order → structure isn't intuitive
- Missed references → links need to be more explicit
- Overreliance on one section → move that content into SKILL.md
- Ignored files → unnecessary or poorly signaled

## Workflow Patterns for Complex Skills

When a skill involves multi-step processes, use these patterns explicitly in the skill body:

- **Checklist pattern**: Provide a `- [ ]` checklist Claude copies into its response and checks off
- **Feedback loop**: Run validator → fix errors → repeat. Make validation scripts verbose so Claude can self-correct
- **Plan-validate-execute**: For batch/destructive ops — Claude creates a plan file, validates it with a script, then executes

## Scripts

**Execution vs. read intent** — be explicit:
- "Run `analyze_form.py` to extract fields" → Claude executes (output only, no context cost)
- "See `analyze_form.py` for the algorithm" → Claude reads into context

**MCP tools** — always use fully qualified names: `BigQuery:bigquery_schema`, not `bigquery_schema`

**Error handling** — scripts should handle errors explicitly and print informative messages; don't let failures bubble silently to Claude

## Anti-Patterns

| Anti-pattern | Fix |
|---|---|
| Windows-style paths (`scripts\helper.py`) | Always use forward slashes |
| Too many options offered | Pick a default; escape hatches only |
| Undocumented constants (`TIMEOUT = 47`) | Document the reasoning |
| Nested references (SKILL.md → a.md → b.md) | Keep all refs one level deep from SKILL.md |
| Assuming packages are installed | Explicitly list and install dependencies |
| Time-sensitive phrasing ("before [date]...") | Use "current method" + collapsed "old patterns" section |

## Quality Checklist

**Description**
- [ ] Third person, active verb form
- [ ] States what the skill does and when to use it
- [ ] Includes keyword triggers

**Structure**
- [ ] SKILL.md body under 500 lines
- [ ] All references one level deep; files >100 lines have a table of contents
- [ ] No time-sensitive information

**Scripts**
- [ ] Errors handled explicitly with informative messages
- [ ] No undocumented constants
- [ ] Required packages listed
- [ ] Forward slashes only

**Testing**
- [ ] ≥3 evaluations created and passing
- [ ] Tested across all target models
