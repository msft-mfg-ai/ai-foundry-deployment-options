---
name: weather-reporting
description: Report current weather, forecasts, hazards, and climate context with clear sourcing and charts.
---

# Weather reporting

Use this skill for weather conditions, forecasts, severe-weather coverage, or climate comparisons.

## Reporting workflow

1. Use web search for current observations, forecasts, watches, warnings, and advisories.
2. Prefer official meteorological agencies, then reputable local weather services.
3. State the location, observation or forecast time, time zone, units, and source.
4. Separate observed conditions from forecasts and longer-range uncertainty.
5. Lead with safety-critical alerts. Do not sensationalize uncertain model guidance.
6. For multi-day forecasts, summarize temperature, precipitation, wind, and notable hazards.
7. Cite every time-sensitive claim and note when sources disagree.

## Code Interpreter statistics and charts

Use Code Interpreter for every report to calculate or verify the statistics shown
in the Stats section. Create a chart whenever sufficient reliable data is
available.

- Build a tidy table with one row per timestamp and columns for temperature, precipitation probability, wind, or other reported measures.
- Normalize timestamps and units before plotting. Never mix Fahrenheit and Celsius, mph and km/h, or local and UTC times without conversion.
- Use a line chart for temperature or wind trends, bars for precipitation probability or accumulation, and an annotated timeline for alerts.
- Label location, time zone, units, source, and data retrieval time on or directly below the chart.
- Do not interpolate missing observations or invent hourly values. Show gaps and explain them.
- Save the final chart as a PNG with a descriptive filename and summarize the main pattern in text for accessibility.
- Useful computed statistics include forecast high and low, temperature range, peak precipitation probability, expected accumulation, maximum wind, and changes from the previous period.

## Required output format

Follow this structure exactly:

```markdown
# <Specific newspaper-style weather headline>
**WEATHER | <Location> | <Month D, YYYY>**

## News
<Newspaper-style prose with a strong lead, forecast context, hazards, and inline citations. Do not use bullets.>

## Stats
*Calculated or verified with Code Interpreter.*

| Measure | Value | Period |
|---|---:|---|
| <Verified measure> | <Value and unit> | <Time range> |

<Code Interpreter chart when supported by reliable data.>

<One or two sentences explaining the statistical pattern and limitations.>

## Sources
- [<Source name>](<URL>)

---
*News Editor | Skill used: `weather-reporting`*
```

The signature must be the final line. Do not add any content after it.
