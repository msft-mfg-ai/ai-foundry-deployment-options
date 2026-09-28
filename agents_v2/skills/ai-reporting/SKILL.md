---
name: ai-reporting
description: Report AI research, products, policy, funding, benchmarks, and industry developments with technical context and charts.
---

# AI reporting

Use this skill for artificial intelligence research, model releases, products, policy, safety, funding, benchmarks, and industry developments.

## Reporting workflow

1. Use web search for the latest primary material: papers, model cards, system cards, repositories, official announcements, filings, and regulator publications.
2. Use independent reporting or expert analysis to test company claims and add context.
3. Record publication dates, model or product versions, benchmark settings, and access conditions.
4. Separate demonstrated capabilities from vendor claims, projections, rumors, and opinion.
5. Explain technical terms for a general news audience without overstating what a benchmark proves.
6. Cover material limitations, safety findings, licensing, data provenance, cost, and policy impact when relevant.
7. Cite time-sensitive claims and link to primary sources whenever available.

## Code Interpreter statistics and charts

Use Code Interpreter for every report to calculate or verify the statistics shown
in the Stats section. Create a chart whenever sufficient reliable data is
available.

- Create a dataframe that preserves model version, benchmark, metric direction, evaluation date, source, and methodology notes.
- Compare only like-for-like measurements. Do not place scores from different benchmark versions or evaluation protocols on the same scale without a clear warning.
- Use grouped bars for comparable benchmark scores, scatter plots for cost-latency-quality tradeoffs, and lines for time series.
- Mark missing values explicitly and annotate major methodology changes or release dates.
- Avoid composite rankings unless the weighting method is transparent and justified.
- Save the final chart as a PNG with a descriptive filename and explain both the visible trend and the chart's limitations in text.
- Useful computed statistics include absolute and percentage benchmark differences, price per million tokens, latency changes, funding growth, publication counts, and quality-cost tradeoffs.

## Required output format

Follow this structure exactly:

```markdown
# <Specific newspaper-style AI headline>
**AI | <Company, model, policy, or research topic> | <Month D, YYYY>**

## News
<Newspaper-style prose with a strong lead, what changed, why it matters, caveats, and inline citations. Do not use bullets.>

## Stats
*Calculated or verified with Code Interpreter.*

| Measure | Value | Context |
|---|---:|---|
| <Verified measure> | <Value and unit> | <Model, benchmark, or period> |

<Code Interpreter chart when supported by reliable data.>

<One or two sentences explaining the statistical pattern and limitations.>

## Sources
- [<Source name>](<URL>)

---
*News Editor | Skill used: `ai-reporting`*
```

The signature must be the final line. Do not add any content after it.
