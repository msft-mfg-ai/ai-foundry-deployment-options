---
name: sports-reporting
description: Report sports scores, standings, schedules, performances, and trends with verified statistics and charts.
---

# Sports reporting

Use this skill for game recaps, live or recent scores, standings, schedules, player performance, and statistical comparisons.

## Reporting workflow

1. Use web search for current scores, schedules, standings, injuries, transactions, and official statements.
2. Prefer league, team, tournament, and official statistics sources. Use reputable reporting for context and reaction.
3. Verify the event date, competition, teams or athletes, final status, and score before calling a result final.
4. Clearly distinguish confirmed facts, reported information, analysis, and opinion.
5. Include the decisive sequence, leading performers, relevant records, and what the result changes.
6. Do not speculate about injuries, discipline, transfers, or private matters.
7. Cite time-sensitive facts and identify any statistics that use different definitions across sources.

## Code Interpreter statistics and charts

Use Code Interpreter for every report to calculate or verify the statistics shown
in the Stats section. Create a chart whenever sufficient reliable data is
available.

- Put verified statistics into a dataframe and retain source, season, competition, and date fields.
- Use a line or step chart for score progression, grouped bars for player or team comparisons, and a slope or line chart for standings or form over time.
- Normalize rates for unequal playing time when appropriate, but show both the raw total and the normalized measure.
- Sort categories deliberately, label every axis and unit, and identify small samples.
- Do not infer missing plays or fabricate split statistics. Exclude unavailable values and disclose the omission.
- Save the final chart as a PNG with a descriptive filename and provide a text summary of the result.
- Useful computed statistics include scoring margin, lead changes, shooting or conversion rates, per-minute or per-possession rates, recent form, and standings movement.

## Required output format

Follow this structure exactly:

```markdown
# <Specific newspaper-style sports headline>
**SPORTS | <Competition, team, or athlete> | <Month D, YYYY>**

## News
<Newspaper-style prose with a strong lead, decisive moments, context, and inline citations. Do not use bullets.>

## Stats
*Calculated or verified with Code Interpreter.*

| Measure | Value | Context |
|---|---:|---|
| <Verified measure> | <Value and unit> | <Game, season, or period> |

<Code Interpreter chart when supported by reliable data.>

<One or two sentences explaining the statistical pattern and limitations.>

## Sources
- [<Source name>](<URL>)

---
*News Editor | Skill used: `sports-reporting`*
```

The signature must be the final line. Do not add any content after it.
