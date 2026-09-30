# Validation

This document records what has been verified about Foresight and how each result is reproduced: the comparison of the six point forecasting methods with statsforecast 2.1.1 on committed fixture series, the calibration check on synthetic series whose true quantiles are known, the preparation of the Online Retail II subset, the calibration study that compares the distribution quantiles with the conformal baseline on both kinds of series, and the commands that regenerate every committed artifact. The methods, the metrics and every modeling choice are explained in [docs/methodology.md](methodology.md).

The tables and lists between `<!-- generated:... -->` markers are written by `validation/render.rb` from committed files alone: `data/fixture_series.json`, `data/reference_outputs.json`, `data/online_retail_ii_subset.json`, `validation/study_results.json`, the two requirements files and the gem's own constants. The text around them is written by hand. In the generated tables, counts print as integers and every other number is rounded to three decimals, except the floating-point differences of the reference comparison, which are far below a thousandth and print in scientific notation; a value that does not exist, such as a metric of a demand class without series or a MASE at a zero scale, prints as `undefined`; a bootstrap interval prints right after its value in square brackets, as in `0.884 [0.871, 0.897]`, or as `undefined` when the class has fewer than two series or the statistic is undefined in at least one resample.

The calibration study is a first study. Its only real dataset is Online Retail II, and the multi-dataset calibration benchmark that would put the same question to other datasets is planned and not built; it is listed in the README roadmap.

## Reference comparison with statsforecast

The point forecasts of the six methods are compared with statsforecast 2.1.1, an independent implementation of the same methods in Python. `dev/reference/generate.py` reads the committed fixture series, passes each one to statsforecast as 64-bit floating-point values and records the point forecasts of Naive, SeasonalNaive, SimpleExponentialSmoothingOptimized, CrostonClassic, CrostonSBA and TSB over a horizon of 14 periods, which exceeds every recorded season length (at most 7). SeasonalNaive receives the season length recorded with each fixture, and TSB receives 0.1 for both of its smoothing parameters, which are Foresight's defaults; the other models take no parameter. The script pins statsforecast to exactly 2.1.1 through `dev/reference/requirements.txt`, refuses to run against a missing or different installed version, records the installed version, the Python and numpy versions and the platform in `data/reference_outputs.json`, and stops without writing when any forecast is not finite. Each forecast is written with enough digits to parse back to the identical double.

`test/reference_test.rb` reads both committed files, fits every method on every fixture with Foresight's default smoothing parameters and the recorded season length, and asserts that Foresight returns exactly 14 forecasts, each within the tolerance of the recorded value: 1e-9 for the five deterministic methods, Naive, SeasonalNaive, CrostonClassic, CrostonSBA and TSB, and 1e-5 for SES, whose smoothing parameter comes from a numerical search. One tolerance applies to every fixture of a method, and no fixture is excluded from any comparison. The test runs without Python or statsforecast; it also checks that the fixture file has the SHA-256 recorded in the reference outputs, that the recorded statsforecast version equals the pin, that the values were passed as `float64`, and that every forecast period of every model on every fixture is present.

<!-- generated:parity -->
The reference outputs were produced by statsforecast 2.1.1 under Python 3.12.12 with numpy 2.5.3 on macOS (arm64), over a horizon of 14 periods; the differences below were measured at Foresight 0.1.0.

| Method | statsforecast model | Tolerance | Maximum absolute difference |
|---|---|---|---|
| Naive | Naive | 1e-9 | 0 |
| SeasonalNaive | SeasonalNaive | 1e-9 | 0 |
| SES | SimpleExponentialSmoothingOptimized | 1e-5 | 2.07e-7 |
| CrostonClassic | CrostonClassic | 1e-9 | 7.11e-15 |
| CrostonSBA | CrostonSBA | 1e-9 | 7.11e-15 |
| TSB | TSB | 1e-9 | 7.11e-15 |

Maximum absolute difference per fixture over the 14 forecast periods of each method, and the absolute difference of the SES smoothing parameter:

| Fixture | Naive | SeasonalNaive | SES | CrostonClassic | CrostonSBA | TSB | SES `alpha` |
|---|---|---|---|---|---|---|---|
| weekly_pattern | 0 | 0 | 2.07e-7 | 7.11e-15 | 7.11e-15 | 7.11e-15 | 1.39e-8 |
| upward_trend | 0 | 0 | 8.75e-9 | 0 | 0 | 0 | 9.58e-9 |
| level_shift | 0 | 0 | 7.11e-15 | 7.11e-15 | 7.11e-15 | 7.11e-15 | 0 |
| decimal_amounts | 0 | 0 | 2.88e-9 | 1.78e-15 | 1.78e-15 | 1.78e-15 | 3.75e-10 |
| erratic_demand | 0 | 0 | 1.11e-9 | 0 | 0 | 0 | 2.15e-9 |
| intermittent_demand | 0 | 0 | 3.86e-9 | 0 | 0 | 0 | 3.27e-9 |
| lumpy_demand | 0 | 0 | 1.73e-10 | 0 | 0 | 0 | 2.83e-11 |
| leading_zeros | 0 | 0 | 0 | 4.44e-16 | 4.44e-16 | 8.88e-16 | 0 |
| trailing_zeros | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| constant_level | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| all_zeros | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
<!-- /generated:parity -->

The two tolerances were fixed before the reference outputs were generated and are not loosened afterwards; a measured difference above a tolerance is investigated as a defect, not absorbed into the tolerance. The deterministic methods repeat a fixed sequence of additions, multiplications and divisions, so the only source of difference is a compiler contracting a multiply and an add into a fused multiply-add on one side and not on the other, which moves a Croston or TSB update by a few units in the last place; with values of at most 100 the accumulated difference stays orders of magnitude below 1e-9. SES needs a wider tolerance because its smoothing parameter comes from a golden-section search over the in-sample sum of squared errors: near the minimizer the sums at the two interior points of the bracket differ by less than the rounding noise, so a contracted operation can flip one comparison near convergence and end the search on a slightly different parameter. An experiment during design ran the search with the exact recurrence and with a mathematically equivalent but differently rounded one on 900 random level series of 20 to 219 observations: the chosen parameters differed by at most 4.3e-8 and the forecasts by at most 7.2e-9 relative, which is 6.1e-8 absolute for values near 10 and 4.4e-7 for values near 100. Fixture values are kept at most 100, so 1e-5 is more than twenty times that effect, which leaves margin for contraction patterns the experiment did not reproduce while staying far below the size of a change in the search itself. The fixture set has no series of two observations with different values, whose sum of squared errors does not depend on the smoothing parameter, because there the search would be steered by rounding alone.

Foresight follows the conventions of statsforecast 2.1.1 wherever that version defines them: the initialization of every method (the level at the first observation for SES, the first size and the first interval for Croston's methods, the first occurrence indicator and the first size for TSB), the counting of intervals from the one-based position of the first non-zero observation, the default smoothing parameter of 0.1 for CrostonClassic and CrostonSBA, and, for SES, the golden-section search on `[0.01, 0.99]` that stops when the bracket is narrower than 1e-12 or the two interior sums are exactly equal and returns the midpoint of the final bracket, reproduced operation by operation from `ses.cpp`. Two conventions differ, and neither affects a fixture:

- TSB has no default smoothing parameters in statsforecast; Foresight defaults both to 0.1. The reference script passes 0.1 and 0.1 explicitly, so TSB is compared at the same parameters on every fixture.
- SeasonalNaive with fewer observations than the season length raises an input error in Foresight, where statsforecast fills the leading forecast positions with NaN. Every fixture has at least 24 observations and a season length of at most 7, so no fixture reaches this case.

Since no fixture is affected by a differing convention, the maximum absolute differences in the tables above measure floating-point rounding alone.

## Fixture series

`data/fixture_series.json` holds the fixture series and is written by `ruby dev/fixtures.rb`; the test suite checks that rerunning the generator reproduces the file byte for byte. Each fixture records its name, a season length from 1 to 7, its values (24 to 60 numbers from 0 to 100, integers or amounts with at most two decimals) and its provenance: the series was either written by hand or generated by `dev/fixtures.rb` from the seed stated in the table, which feeds `Random.new`. No fixture is derived from Online Retail II. Together the fixtures cover every demand class, a series that starts with zeros, a series that ends with two zeros, a weekly pattern of season length 7 with six complete cycles whose last week is not constant, a constant series and an all-zero series. The demand class column shows the class the classifier assigns to the complete series.

<!-- generated:fixtures -->
| Fixture | Observations | Season length | Demand class | Provenance |
|---|---|---|---|---|
| weekly_pattern | 42 | 7 | smooth | generated by `dev/fixtures.rb weekly_pattern` from seed 107 |
| upward_trend | 36 | 1 | smooth | generated by `dev/fixtures.rb upward_trend` from seed 109 |
| level_shift | 30 | 3 | smooth | written by hand |
| decimal_amounts | 32 | 4 | smooth | generated by `dev/fixtures.rb decimal_amounts` from seed 113 |
| erratic_demand | 40 | 5 | erratic | generated by `dev/fixtures.rb erratic_demand` from seed 127 |
| intermittent_demand | 56 | 7 | intermittent | generated by `dev/fixtures.rb intermittent_demand` from seed 131 |
| lumpy_demand | 60 | 6 | lumpy | generated by `dev/fixtures.rb lumpy_demand` from seed 137 |
| leading_zeros | 28 | 4 | intermittent | written by hand |
| trailing_zeros | 30 | 2 | intermittent | written by hand |
| constant_level | 24 | 3 | smooth | written by hand |
| all_zeros | 24 | 7 | none, every value is zero | written by hand |
<!-- /generated:fixtures -->

## Synthetic calibration check

The synthetic check separates implementation errors from model misfit: on series generated from a known process the true quantiles are known, so the coverage of Foresight's quantiles can be compared with the coverage that the true quantiles achieve on the same held-out observations. The calibration study (`validation/study.rb`) generates the series from four processes, one per demand class, listed in the table below with the parameters read back from the study results. Every series is drawn from its own `Random.new(seed)`, the seeds of a process run consecutively from its first seed, and the seed of each series is recorded with its results. The Gaussian process draws with the Box-Muller transform from the series' own generator and censors at zero; the Bernoulli processes draw one uniform number per period for the occurrence and, when demand occurs, one integer draw against the cumulative weights for the size. The occurrence probabilities are dyadic (0.875 and 0.25), so their floating-point values are exact.

<!-- generated:processes -->
| Process | Demand in each period | Series | Observations per series | Seeds |
|---|---|---|---|---|
| smooth-gaussian | an independent Gaussian draw with mean 50.0 and standard deviation 10.0, censored at zero | 50 | 200 | 10001 to 10050 |
| erratic-bernoulli | non-zero with probability 0.875, independently of every other period; a non-zero demand has size 1, 3 and 10 with weights 2, 1 and 1 | 50 | 200 | 20001 to 20050 |
| intermittent-bernoulli | non-zero with probability 0.25, independently of every other period; a non-zero demand has size 1, 2, 3, 4 and 5 with weights 1, 1, 1, 1 and 1 | 50 | 200 | 30001 to 30050 |
| lumpy-bernoulli | non-zero with probability 0.25, independently of every other period; a non-zero demand has size 1, 3 and 10 with weights 2, 1 and 1 | 50 | 200 | 40001 to 40050 |
<!-- /generated:processes -->

The true quantiles are computed in `validation/truth.rb`, which loads no Foresight code. For a Bernoulli process the per-period distribution is an exact rational probability mass function on zero and the sizes, the distribution of the 7-period total is its 7-fold convolution in rational arithmetic, and each quantile is the smallest value whose cumulative probability reaches the level; both are exact. For the Gaussian process the per-period quantile is `max(0, 50 + 10 z_q)`, and the total over the horizon is taken as Gaussian with mean 350 and variance 700, with `z_q` found by bisection on `0.5 * erfc(-x / sqrt(2))` to a width of 1e-12. Treating the total as an uncensored Gaussian is an approximation with a stated bound: censoring changes the total only when some period would have been negative, an event of probability at most `7 * Phi(-5)`, about 2.0e-6, so the two cumulative distribution functions differ by at most 2.0e-6 everywhere; dividing by the density of the total near its 0.5 to 0.95 quantiles, at least 0.0038, bounds the shift of any of those quantiles by 5.3e-4, a relative error below 1.6e-6.

The coverage of a true quantile of a discrete distribution can exceed the level. The quantile at level `q` is the smallest demand value whose cumulative probability reaches `q`, so the probability of demand at or below it is at least `q` and, unless the cumulative probability lands exactly on `q`, above it. The tables below therefore state, for each Bernoulli process and level, the exact probability that the demand of one period is at most its true quantile and the exact probability that the 7-period total is at most its true quantile; the coverage of the true quantiles is expected to sit near those probabilities, not near the level. For the Gaussian process the distribution is continuous, the probability equals the level and the column is omitted.

Each table pools the same origins and held-out observations for the true quantiles and for both strategies, leaving out any origin that the backtester excludes. With 50 series of 200 observations under the study configuration, each process pools 500 origins and 3,500 held-out observations. The differences are the coverage of a strategy minus the coverage of the true quantiles. The study stops without writing results if automatic selection chooses a smooth model at any origin of a Bernoulli series or an intermittent model at any origin of a Gaussian series, so every strategy row was produced by the model family the process was designed for.

<!-- generated:coverage -->
smooth-gaussian: 50 series, 500 pooled origins and 3500 pooled held-out observations.

Per-period quantiles:

| Level | True quantile | Coverage of the true quantiles | Coverage of the distribution quantiles | Difference | Coverage of the conformal quantiles | Difference |
|---|---|---|---|---|---|---|
| 0.5 | 50.0 | 0.513 | 0.505 | -0.008 | 0.458 | -0.055 |
| 0.8 | 58.416 | 0.803 | 0.802 | -0.001 | 0.812 | 0.008 |
| 0.9 | 62.816 | 0.902 | 0.906 | 0.004 | 0.911 | 0.009 |
| 0.95 | 66.449 | 0.949 | 0.951 | 0.002 | 0.911 | -0.038 |

Lead-time quantiles:

| Level | True quantile of the 7-period total | Lead-time coverage of the true quantiles | Lead-time coverage of the distribution quantiles | Difference | Lead-time coverage of the conformal quantiles | Difference |
|---|---|---|---|---|---|---|
| 0.5 | 350.0 | 0.514 | 0.494 | -0.02 | 0.452 | -0.062 |
| 0.8 | 372.267 | 0.824 | 0.846 | 0.022 | 0.83 | 0.006 |
| 0.9 | 383.907 | 0.932 | 0.938 | 0.006 | 0.924 | -0.008 |
| 0.95 | 393.519 | 0.962 | 0.976 | 0.014 | 0.924 | -0.038 |

erratic-bernoulli: 50 series, 500 pooled origins and 3500 pooled held-out observations.

Per-period quantiles:

| Level | True quantile | Probability at or below it | Coverage of the true quantiles | Coverage of the distribution quantiles | Difference | Coverage of the conformal quantiles | Difference |
|---|---|---|---|---|---|---|---|
| 0.5 | 1.0 | 0.563 | 0.572 | 0.575 | 0.004 | 0.626 | 0.054 |
| 0.8 | 10.0 | 1.0 | 1.0 | 0.91 | -0.09 | 0.8 | -0.2 |
| 0.9 | 10.0 | 1.0 | 1.0 | 1.0 | 0.0 | 0.863 | -0.137 |
| 0.95 | 10.0 | 1.0 | 1.0 | 1.0 | 0.0 | 0.863 | -0.137 |

Lead-time quantiles:

| Level | True quantile of the 7-period total | Probability at or below it | Lead-time coverage of the true quantiles | Lead-time coverage of the distribution quantiles | Difference | Lead-time coverage of the conformal quantiles | Difference |
|---|---|---|---|---|---|---|---|
| 0.5 | 22.0 | 0.512 | 0.512 | 0.47 | -0.042 | 0.426 | -0.086 |
| 0.8 | 31.0 | 0.813 | 0.836 | 0.792 | -0.044 | 0.798 | -0.038 |
| 0.9 | 36.0 | 0.914 | 0.94 | 0.908 | -0.032 | 0.892 | -0.048 |
| 0.95 | 40.0 | 0.954 | 0.972 | 0.956 | -0.016 | 0.892 | -0.08 |

intermittent-bernoulli: 50 series, 500 pooled origins and 3500 pooled held-out observations.

Per-period quantiles:

| Level | True quantile | Probability at or below it | Coverage of the true quantiles | Coverage of the distribution quantiles | Difference | Coverage of the conformal quantiles | Difference |
|---|---|---|---|---|---|---|---|
| 0.5 | 0.0 | 0.75 | 0.747 | 0.747 | 0.0 | 0.748 | 0.0 |
| 0.8 | 2.0 | 0.85 | 0.849 | 0.82 | -0.029 | 0.809 | -0.04 |
| 0.9 | 4.0 | 0.95 | 0.947 | 0.923 | -0.023 | 0.858 | -0.088 |
| 0.95 | 4.0 | 0.95 | 0.947 | 0.972 | 0.025 | 0.858 | -0.088 |

Lead-time quantiles:

| Level | True quantile of the 7-period total | Probability at or below it | Lead-time coverage of the true quantiles | Lead-time coverage of the distribution quantiles | Difference | Lead-time coverage of the conformal quantiles | Difference |
|---|---|---|---|---|---|---|---|
| 0.5 | 5.0 | 0.584 | 0.586 | 0.56 | -0.026 | 0.516 | -0.07 |
| 0.8 | 9.0 | 0.855 | 0.842 | 0.81 | -0.032 | 0.836 | -0.006 |
| 0.9 | 11.0 | 0.928 | 0.916 | 0.9 | -0.016 | 0.882 | -0.034 |
| 0.95 | 12.0 | 0.951 | 0.936 | 0.944 | 0.008 | 0.882 | -0.054 |

lumpy-bernoulli: 50 series, 500 pooled origins and 3500 pooled held-out observations.

Per-period quantiles:

| Level | True quantile | Probability at or below it | Coverage of the true quantiles | Coverage of the distribution quantiles | Difference | Coverage of the conformal quantiles | Difference |
|---|---|---|---|---|---|---|---|
| 0.5 | 0.0 | 0.75 | 0.755 | 0.755 | 0.0 | 0.773 | 0.018 |
| 0.8 | 1.0 | 0.875 | 0.876 | 0.855 | -0.02 | 0.877 | 0.001 |
| 0.9 | 3.0 | 0.938 | 0.943 | 0.939 | -0.003 | 0.897 | -0.046 |
| 0.95 | 10.0 | 1.0 | 1.0 | 0.983 | -0.017 | 0.897 | -0.103 |

Lead-time quantiles:

| Level | True quantile of the 7-period total | Probability at or below it | Lead-time coverage of the true quantiles | Lead-time coverage of the distribution quantiles | Difference | Lead-time coverage of the conformal quantiles | Difference |
|---|---|---|---|---|---|---|---|
| 0.5 | 4.0 | 0.548 | 0.554 | 0.562 | 0.008 | 0.546 | -0.008 |
| 0.8 | 12.0 | 0.825 | 0.83 | 0.816 | -0.014 | 0.812 | -0.018 |
| 0.9 | 14.0 | 0.904 | 0.916 | 0.916 | 0.0 | 0.882 | -0.034 |
| 0.95 | 20.0 | 0.953 | 0.968 | 0.956 | -0.012 | 0.882 | -0.086 |
<!-- /generated:coverage -->

## Online Retail II subset

The real series come from Online Retail II, created by Daqing Chen and published by the UCI Machine Learning Repository under the Creative Commons Attribution 4.0 International license (CC BY 4.0, https://creativecommons.org/licenses/by/4.0/). Citation: Chen, D. (2012). Online Retail II [Dataset]. UCI Machine Learning Repository. https://doi.org/10.24432/C5CG6D. The committed subset, `data/online_retail_ii_subset.json`, carries this attribution and lists the modifications made to the source data:

- lines copied across the two worksheets are counted once; repeated identical lines within one worksheet are kept;
- cancellation lines, lines with a quantity of zero or less, and lines whose stock code is not a product code are dropped;
- quantities are summed per stock code and trading date over the trading calendar, the dates with at least one transaction;
- each series starts at its first trading date with positive demand;
- the subset is a deterministic selection, described below.

The preparation has two stages. The Python stage, `dev/retail/extract.py`, downloads the zip file from the UCI repository, records the SHA-256 of the zip and of the workbook inside it, reads both worksheets, checks that the header row of each names the columns `Invoice`, `StockCode`, `Quantity` and `InvoiceDate` exactly once, and selects those four columns by name; nothing from any other column is read into the output, so the subset holds no customer identifier, country, description or unit price. It keeps the lines dated from 1 December 2009 to 9 December 2011 inclusive and counts each distinct line, compared on every cell with empty cells equal to each other, as many times as it occurs in the worksheet where it occurs most often: repeats within one worksheet are all kept, and the copies in the other worksheet are not counted again. It reports the first and last transaction date of each worksheet, the number of lines read from it in that date range and the number of copies left uncounted. The trading calendar is the set of transaction dates of every line read, built before any line is dropped, so that days without any transaction are treated as closed days rather than as days of zero demand. The stage then drops cancellation lines, whose transaction number starts with `C` or `c`, lines with a quantity of zero or less, and lines whose stock code is not a product code under this rule: the stock code text, or the decimal digits of an integer-valued numeric cell, must fully match `[0-9]{5}[A-Za-z]*`, five digits followed by optional letters (the Ruby stage and the tests write the same pattern as `\A[0-9]{5}[A-Za-z]*\z`). The dataset description gives a product code as a five-digit number assigned to each distinct product; the pattern admits the letter suffixes that variants of a product carry, such as `17091F`, and rejects the codes of lines that are not product sales. The remaining quantities are summed per stock code, compared as exact text, and per trading date, and written to `tmp/retail_intermediate.json`, which is not committed.

The Ruby stage, `ruby -Ilib dev/retail/select.rb`, builds one series per stock code from its first trading date with positive demand to the last date of the calendar, with a zero on every trading date without a line for that code and no value for any date outside the calendar, classifies each complete series with `Foresight.classify`, and selects the subset with a deterministic rule that uses no forecast or backtest result: a series is eligible when it spans at least 200 trading dates, which exceeds the 141 observations the backtester needs under the study configuration with both strategies (the stage checks this against `validation/study_config.json` before it runs); within each demand class the eligible series are ranked by the SHA-256 hex digest of the text `2026:` followed by the stock code, with 2026 the selection seed, and the first 25 are taken. A class with fewer than 25 eligible series contributes all of them, and the shortfall is recorded in the file and shown below. The stage writes the file with sorted collections through a temporary file and a rename, so a rerun on the same downloaded file writes an identical subset, and either stage stops with a message naming the failed step and leaves the committed subset untouched. The test suite checks that every stock code matches the product-code pattern, that every series aligns with the calendar from its start to the last date and begins with positive demand, that the recorded demand class of every series is the class the classifier assigns, and that the file is the pretty-printed form of its own content.

<!-- generated:worksheets -->
The zip file at https://archive.ics.uci.edu/static/public/502/online+retail+ii.zip has SHA-256 `572e36277c2390fbfde10664750731e0a86f55e33470d91919085f0408e67bfb`; the workbook inside it has SHA-256 `bcbe73b35f5b7babf197fb0cb983a11f5d9ff929078d4aa53d171b1f2df2e980` and holds 2 worksheets:

| Worksheet | First transaction date | Last transaction date | Lines read |
|---|---|---|---|
| Year 2009-2010 | 2009-12-01 | 2010-12-09 | 525461 |
| Year 2010-2011 | 2010-12-01 | 2011-12-09 | 541910 |

Lines left uncounted because they copy lines of another worksheet: 22523. The trading calendar holds 604 dates from 2009-12-01 to 2011-12-09. The selection used seed 2026, a minimum length of 200 trading dates, a target of 25 series per demand class and the product-code pattern `\A[0-9]{5}[A-Za-z]*\z`. The subset holds 75 series: 0 smooth, 25 erratic, 25 intermittent and 25 lumpy. Shortfalls: smooth with 0 eligible series, below the target of 25.
<!-- /generated:worksheets -->

## Calibration study

`ruby -Ilib validation/study.rb` backtests every synthetic series and every series of the subset with `Foresight.backtest` under both quantile strategies, the distribution quantiles and the conformal baseline, at the same origins and with the same seed, using automatic model selection at every origin, and writes `validation/study_results.json`. It reads only `validation/study_config.json` and the committed subset, loads nothing beyond the gem and Ruby's standard library, and needs no network access. The configuration below is read back from the committed results.

<!-- generated:configuration -->
| Setting | Value |
|---|---|
| horizon | 7 |
| origins | 10 |
| step | 7 |
| quantile levels | 0.5, 0.8, 0.9 and 0.95 |
| sample paths | 10000 |
| calibration windows | 10 |
| backtest seed | 20260925 |
| bootstrap resamples | 2000 |
| bootstrap seed | 20260926 |

The study results were written by Foresight 0.1.0 under Ruby 3.4.7 on macOS (arm64); the SHA-256 of the Online Retail II subset they were computed from is `54f9a0b90fb9c8e9e77c107a52b1cfdec81040bb60c259cc521a20b52918530c`.
<!-- /generated:configuration -->

Three choices of the configuration deserve a note. The horizon of 7 with 10 origins and a step of 7 gives ten non-overlapping windows of one week of trading days; a series needs 141 observations under this configuration (71 before the first origin), and every study series has at least 200. The same seed is used at every origin, for both strategies and for every series, so that each origin reproduces with `Foresight.forecast` on its prefix; the seed only matters for the compound quantiles, whose lead-time quantile comes from 10,000 sample paths. And the conformal baseline runs with 10 calibration windows instead of the library default of 2: with 2 windows the conformal collection has four values per period, so its 0.8, 0.9 and 0.95 quantiles are all the largest of the four and its 0.5 quantile sits below the point forecast, which would make the baseline look worse for reasons unrelated to the question the study asks. Ten windows give twenty values per period, which the histories allow.

Two rules keep the two strategies on the same series. A series without a non-zero observation is set aside before any backtest and counted. A series for which the backtester raises an input error under either strategy is set aside from both strategies, and its identifier, the strategy and the message are recorded in the results and listed above the tables. Any other error stops the study with a message naming the series, and an existing results file is left untouched: the results are written through a temporary file and a rename only after every series has been backtested under both strategies.

### Bootstrap intervals

Every per-class coverage, lead-time coverage and scaled pinball loss, and every difference between the strategies, carries a 95 percent percentile interval from a seeded bootstrap over the series of the class (Efron and Tibshirani 1993, chapter 13). The eight classes, synthetic smooth, erratic, intermittent and lumpy, then the same four for the subset, are numbered 0 to 7, and class `k` draws from `Random.new(20260926 + k)`, so the resamples of one class depend only on its own series; each class record stores its seed. A resample draws as many series as the class has, with replacement, and the same draw serves both strategies, every level and every statistic: the pooled coverages are recomputed from the summed per-series counts of covered observations and lead-time hits over the drawn series, repeats included, and the loss is the mean of the per-series mean losses that are defined. From the values of the two strategies the resample also forms, at each level, the five differences of the difference tables: the absolute distance of the coverage from the level under the distribution quantiles minus the same distance under the conformal quantiles, the same for the lead-time coverage, the difference of the scaled pinball losses, and the signed differences of the coverage and of the lead-time coverage. After 2,000 resamples, the interval of a statistic is bounded by the 50th and the 1,950th smallest of its 2,000 values, the `ceil(0.025 B)`-th and the `ceil(0.975 B)`-th with `B = 2000`. An interval is undefined when the class has fewer than two series or when the statistic is undefined in at least one resample, so that no interval rests on fewer than 2,000 values. Using one draw for both strategies pairs the intervals of the differences: they show how the difference varies over series, not how each strategy varies on its own.

### Results on the synthetic series

<!-- generated:summary-synthetic -->
Series set aside because they had no non-zero observation: 0. Series set aside because the backtester raised an input error under one strategy: 0.

Counts per demand class:

| Demand class | Series | Origins | Held-out observations | Zero held-out observations | Non-zero held-out observations | Excluded origins | Origins with an undefined MASE |
|---|---|---|---|---|---|---|---|
| smooth | 50 | 500 | 3500 | 0 | 3500 | 0 | 0 |
| erratic | 50 | 500 | 3500 | 432 | 3068 | 0 | 0 |
| intermittent | 50 | 500 | 3500 | 2616 | 884 | 0 | 0 |
| lumpy | 50 | 500 | 3500 | 2643 | 857 | 0 | 0 |

Point accuracy per demand class and strategy:

| Demand class | Strategy | MAE | RMSE | MASE |
|---|---|---|---|---|
| smooth | distribution | 8.218 | 9.903 | 0.726 |
| smooth | conformal | 8.218 | 9.903 | 0.726 |
| erratic | distribution | 2.905 | 3.563 | 0.813 |
| erratic | conformal | 2.905 | 3.563 | 0.813 |
| intermittent | distribution | 1.14 | 1.4 | 0.929 |
| intermittent | conformal | 1.14 | 1.4 | 0.929 |
| lumpy | distribution | 1.386 | 1.94 | 0.842 |
| lumpy | conformal | 1.386 | 1.94 | 0.842 |

Quantile level 0.5, with the bootstrap interval after each value:

| Demand class | Strategy | Coverage | Lead-time coverage | Scaled pinball loss | Zero part | Non-zero part |
|---|---|---|---|---|---|---|
| smooth | distribution | 0.505 [0.493, 0.517] | 0.494 [0.458, 0.534] | 0.363 [0.352, 0.375] | 0.0 | 0.363 |
| smooth | conformal | 0.458 [0.447, 0.469] | 0.452 [0.416, 0.49] | 0.367 [0.355, 0.379] | 0.0 | 0.367 |
| erratic | distribution | 0.575 [0.56, 0.591] | 0.47 [0.428, 0.512] | 0.345 [0.327, 0.361] | 0.018 | 0.327 |
| erratic | conformal | 0.626 [0.615, 0.637] | 0.426 [0.396, 0.456] | 0.39 [0.372, 0.408] | 0.047 | 0.344 |
| intermittent | distribution | 0.747 [0.732, 0.761] | 0.56 [0.526, 0.598] | 0.313 [0.29, 0.34] | 0.0 | 0.313 |
| intermittent | conformal | 0.748 [0.733, 0.761] | 0.516 [0.48, 0.554] | 0.37 [0.346, 0.398] | 0.085 | 0.286 |
| lumpy | distribution | 0.755 [0.739, 0.77] | 0.562 [0.52, 0.606] | 0.276 [0.252, 0.303] | 0.0 | 0.276 |
| lumpy | conformal | 0.773 [0.761, 0.785] | 0.546 [0.51, 0.582] | 0.368 [0.341, 0.396] | 0.133 | 0.235 |

Quantile level 0.8, with the bootstrap interval after each value:

| Demand class | Strategy | Coverage | Lead-time coverage | Scaled pinball loss | Zero part | Non-zero part |
|---|---|---|---|---|---|---|
| smooth | distribution | 0.802 [0.791, 0.813] | 0.846 [0.816, 0.876] | 0.254 [0.246, 0.262] | 0.0 | 0.254 |
| smooth | conformal | 0.812 [0.801, 0.823] | 0.83 [0.802, 0.858] | 0.263 [0.254, 0.273] | 0.0 | 0.263 |
| erratic | distribution | 0.91 [0.887, 0.932] | 0.792 [0.752, 0.826] | 0.396 [0.377, 0.416] | 0.049 | 0.347 |
| erratic | conformal | 0.8 [0.789, 0.811] | 0.798 [0.772, 0.822] | 0.392 [0.378, 0.406] | 0.045 | 0.347 |
| intermittent | distribution | 0.82 [0.808, 0.831] | 0.81 [0.778, 0.84] | 0.472 [0.443, 0.509] | 0.167 | 0.305 |
| intermittent | conformal | 0.809 [0.797, 0.82] | 0.836 [0.8, 0.87] | 0.459 [0.435, 0.489] | 0.205 | 0.254 |
| lumpy | distribution | 0.855 [0.844, 0.867] | 0.816 [0.788, 0.846] | 0.421 [0.386, 0.456] | 0.076 | 0.344 |
| lumpy | conformal | 0.877 [0.866, 0.888] | 0.812 [0.782, 0.842] | 0.458 [0.427, 0.489] | 0.181 | 0.277 |

Quantile level 0.9, with the bootstrap interval after each value:

| Demand class | Strategy | Coverage | Lead-time coverage | Scaled pinball loss | Zero part | Non-zero part |
|---|---|---|---|---|---|---|
| smooth | distribution | 0.906 [0.897, 0.915] | 0.938 [0.918, 0.956] | 0.159 [0.153, 0.164] | 0.0 | 0.159 |
| smooth | conformal | 0.911 [0.903, 0.92] | 0.924 [0.902, 0.944] | 0.169 [0.162, 0.175] | 0.0 | 0.169 |
| erratic | distribution | 1.0 [0.999, 1.0] | 0.908 [0.878, 0.934] | 0.19 [0.184, 0.197] | 0.034 | 0.156 |
| erratic | conformal | 0.863 [0.855, 0.872] | 0.892 [0.868, 0.914] | 0.244 [0.233, 0.255] | 0.03 | 0.214 |
| intermittent | distribution | 0.923 [0.913, 0.933] | 0.9 [0.872, 0.926] | 0.318 [0.299, 0.342] | 0.211 | 0.107 |
| intermittent | conformal | 0.858 [0.851, 0.866] | 0.882 [0.854, 0.91] | 0.356 [0.333, 0.385] | 0.166 | 0.19 |
| lumpy | distribution | 0.939 [0.931, 0.948] | 0.916 [0.892, 0.938] | 0.382 [0.354, 0.411] | 0.138 | 0.244 |
| lumpy | conformal | 0.897 [0.887, 0.907] | 0.882 [0.858, 0.906] | 0.406 [0.373, 0.441] | 0.145 | 0.261 |

Quantile level 0.95, with the bootstrap interval after each value:

| Demand class | Strategy | Coverage | Lead-time coverage | Scaled pinball loss | Zero part | Non-zero part |
|---|---|---|---|---|---|---|
| smooth | distribution | 0.951 [0.945, 0.957] | 0.976 [0.962, 0.988] | 0.093 [0.09, 0.096] | 0.0 | 0.093 |
| smooth | conformal | 0.911 [0.903, 0.92] | 0.924 [0.902, 0.944] | 0.105 [0.099, 0.11] | 0.0 | 0.105 |
| erratic | distribution | 1.0 [1.0, 1.0] | 0.956 [0.94, 0.97] | 0.095 [0.092, 0.098] | 0.017 | 0.078 |
| erratic | conformal | 0.863 [0.855, 0.872] | 0.892 [0.868, 0.914] | 0.167 [0.157, 0.179] | 0.015 | 0.152 |
| intermittent | distribution | 0.972 [0.965, 0.979] | 0.944 [0.92, 0.964] | 0.176 [0.166, 0.186] | 0.135 | 0.041 |
| intermittent | conformal | 0.858 [0.851, 0.866] | 0.882 [0.854, 0.91] | 0.276 [0.253, 0.305] | 0.083 | 0.193 |
| lumpy | distribution | 0.983 [0.977, 0.988] | 0.956 [0.94, 0.972] | 0.278 [0.26, 0.296] | 0.165 | 0.113 |
| lumpy | conformal | 0.897 [0.887, 0.907] | 0.882 [0.858, 0.906] | 0.337 [0.304, 0.371] | 0.072 | 0.265 |

Differences at level 0.5, the value under the distribution quantiles minus the value under the conformal quantiles, with the bootstrap interval after each difference:

| Demand class | Coverage error | Lead-time coverage error | Scaled pinball loss | Coverage | Lead-time coverage |
|---|---|---|---|---|---|
| smooth | -0.037 [-0.05, -0.014] | -0.042 [-0.058, 0.022] | -0.004 [-0.006, -0.002] | 0.047 [0.041, 0.053] | 0.042 [0.026, 0.06] |
| erratic | -0.051 [-0.064, -0.037] | -0.044 [-0.074, -0.006] | -0.046 [-0.052, -0.039] | -0.051 [-0.064, -0.037] | 0.044 [0.006, 0.08] |
| intermittent | 0.0 [-0.001, 0.0] | 0.044 [0.006, 0.062] | -0.058 [-0.064, -0.052] | 0.0 [-0.001, 0.0] | 0.044 [0.026, 0.064] |
| lumpy | -0.018 [-0.027, -0.011] | 0.016 [-0.014, 0.048] | -0.091 [-0.099, -0.084] | -0.018 [-0.027, -0.011] | 0.016 [-0.014, 0.048] |

Differences at level 0.8, the value under the distribution quantiles minus the value under the conformal quantiles, with the bootstrap interval after each difference:

| Demand class | Coverage error | Lead-time coverage error | Scaled pinball loss | Coverage | Lead-time coverage |
|---|---|---|---|---|---|
| smooth | -0.01 [-0.017, 0.005] | 0.016 [-0.012, 0.044] | -0.01 [-0.013, -0.007] | -0.01 [-0.02, -0.001] | 0.016 [-0.012, 0.044] |
| erratic | 0.11 [0.082, 0.128] | 0.006 [-0.018, 0.038] | 0.004 [-0.01, 0.017] | 0.11 [0.088, 0.132] | -0.006 [-0.046, 0.028] |
| intermittent | 0.011 [0.001, 0.021] | -0.026 [-0.048, 0.014] | 0.013 [0.006, 0.022] | 0.011 [0.001, 0.021] | -0.026 [-0.052, 0.0] |
| lumpy | -0.021 [-0.029, -0.014] | 0.004 [-0.018, 0.024] | -0.037 [-0.046, -0.028] | -0.021 [-0.029, -0.014] | 0.004 [-0.02, 0.028] |

Differences at level 0.9, the value under the distribution quantiles minus the value under the conformal quantiles, with the bootstrap interval after each difference:

| Demand class | Coverage error | Lead-time coverage error | Scaled pinball loss | Coverage | Lead-time coverage |
|---|---|---|---|---|---|
| smooth | -0.005 [-0.013, 0.003] | 0.014 [-0.006, 0.032] | -0.01 [-0.013, -0.007] | -0.005 [-0.013, 0.003] | 0.014 [-0.006, 0.032] |
| erratic | 0.063 [0.054, 0.072] | 0.0 [-0.024, 0.028] | -0.054 [-0.062, -0.046] | 0.136 [0.127, 0.145] | 0.016 [-0.012, 0.046] |
| intermittent | -0.019 [-0.035, -0.003] | -0.018 [-0.034, 0.018] | -0.038 [-0.048, -0.028] | 0.065 [0.057, 0.073] | 0.018 [0.0, 0.038] |
| lumpy | 0.036 [0.019, 0.046] | -0.002 [-0.036, 0.034] | -0.024 [-0.038, -0.009] | 0.043 [0.033, 0.051] | 0.034 [0.016, 0.054] |

Differences at level 0.95, the value under the distribution quantiles minus the value under the conformal quantiles, with the bootstrap interval after each difference:

| Demand class | Coverage error | Lead-time coverage error | Scaled pinball loss | Coverage | Lead-time coverage |
|---|---|---|---|---|---|
| smooth | -0.038 [-0.045, -0.025] | 0.0 [-0.03, 0.028] | -0.012 [-0.015, -0.008] | 0.039 [0.033, 0.047] | 0.052 [0.032, 0.072] |
| erratic | -0.037 [-0.045, -0.028] | -0.052 [-0.076, -0.022] | -0.072 [-0.082, -0.063] | 0.137 [0.128, 0.145] | 0.064 [0.04, 0.09] |
| intermittent | -0.07 [-0.081, -0.059] | -0.062 [-0.084, -0.032] | -0.101 [-0.12, -0.084] | 0.114 [0.105, 0.123] | 0.062 [0.042, 0.086] |
| lumpy | -0.02 [-0.033, -0.009] | -0.062 [-0.088, -0.028] | -0.059 [-0.087, -0.034] | 0.087 [0.075, 0.097] | 0.074 [0.054, 0.096] |
<!-- /generated:summary-synthetic -->

A note on reading the difference tables. The first three columns compare the two strategies on how far each is from its target: a positive coverage error or lead-time coverage error means that the distribution quantiles are further from the level than the conformal quantiles, and a positive scaled pinball loss means that they have the larger loss. A percentile interval of such an absolute-difference statistic is unreliable when both strategies are close to calibrated, because the absolute value has a kink at zero: resamples that fall on either side of the level fold onto the same side, and the interval no longer brackets the difference the way it does for a smooth statistic. The last two columns, the signed differences of the coverage and of the lead-time coverage, have no kink and show which strategy covers more, that is, which one over- or under-covers relative to the other; they are the columns to read when both coverages sit near the level.

### Results on the Online Retail II series

Two caveats apply to the intervals of this section and not to the synthetic ones. First, the bootstrap treats the series as independent units and does not account for demand shocks shared across the products of one retailer; for the synthetic series independence holds by construction, since every series is drawn from its own generator. Second, every series of the subset ends on the same date, 9 December 2011, so with ten origins and a step of 7 every held-out window of every series covers the same 70 trading dates, from 20 September 2011 to 9 December 2011, the retailer's pre-Christmas peak. The series therefore share both the retailer's demand shocks and the period over which they are measured, and this cross-sectional dependence makes the intervals below anti-conservative: they are narrower than the sampling variation they claim to measure. A bootstrap over blocks of dates rather than over series is the natural extension. The number of series behind each interval is printed next to it.

<!-- generated:summary-real -->
Series set aside because they had no non-zero observation: 0. Series set aside because the backtester raised an input error under one strategy: 0.

Counts per demand class:

| Demand class | Series | Origins | Held-out observations | Zero held-out observations | Non-zero held-out observations | Excluded origins | Origins with an undefined MASE |
|---|---|---|---|---|---|---|---|
| smooth | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| erratic | 25 | 250 | 1750 | 263 | 1487 | 0 | 0 |
| intermittent | 25 | 250 | 1750 | 1687 | 63 | 0 | 0 |
| lumpy | 25 | 250 | 1750 | 1352 | 398 | 0 | 0 |

Point accuracy per demand class and strategy:

| Demand class | Strategy | MAE | RMSE | MASE |
|---|---|---|---|---|
| smooth | distribution | undefined | undefined | undefined |
| smooth | conformal | undefined | undefined | undefined |
| erratic | distribution | 42.667 | 63.484 | 0.849 |
| erratic | conformal | 42.667 | 63.484 | 0.849 |
| intermittent | distribution | 1.668 | 1.732 | 108.185 |
| intermittent | conformal | 1.668 | 1.732 | 108.185 |
| lumpy | distribution | 11.613 | 13.727 | 1.434 |
| lumpy | conformal | 11.613 | 13.727 | 1.434 |

Quantile level 0.5, with the bootstrap interval after each value:

| Demand class | Strategy | Coverage | Lead-time coverage | Scaled pinball loss | Zero part | Non-zero part |
|---|---|---|---|---|---|---|
| smooth | distribution | undefined | undefined | undefined | undefined | undefined |
| smooth | conformal | undefined | undefined | undefined | undefined | undefined |
| erratic | distribution | 0.456 [0.395, 0.513] (25 series) | 0.46 [0.364, 0.552] (25 series) | 0.375 [0.299, 0.459] (25 series) | 0.022 | 0.353 |
| erratic | conformal | 0.619 [0.583, 0.654] (25 series) | 0.52 [0.46, 0.584] (25 series) | 0.412 [0.328, 0.52] (25 series) | 0.059 | 0.353 |
| intermittent | distribution | 0.964 [0.925, 0.993] (25 series) | 0.872 [0.76, 0.96] (25 series) | 55.107 [11.203, 99.443] (25 series) | 54.91 | 0.197 |
| intermittent | conformal | 0.964 [0.925, 0.993] (25 series) | 0.872 [0.76, 0.96] (25 series) | 0.208 [0.09, 0.34] (25 series) | 0.015 | 0.193 |
| lumpy | distribution | 0.815 [0.727, 0.898] (25 series) | 0.716 [0.604, 0.824] (25 series) | 0.225 [0.116, 0.35] (25 series) | 0.072 | 0.153 |
| lumpy | conformal | 0.845 [0.777, 0.91] (25 series) | 0.744 [0.64, 0.844] (25 series) | 0.177 [0.092, 0.277] (25 series) | 0.034 | 0.143 |

Quantile level 0.8, with the bootstrap interval after each value:

| Demand class | Strategy | Coverage | Lead-time coverage | Scaled pinball loss | Zero part | Non-zero part |
|---|---|---|---|---|---|---|
| smooth | distribution | undefined | undefined | undefined | undefined | undefined |
| smooth | conformal | undefined | undefined | undefined | undefined | undefined |
| erratic | distribution | 0.781 [0.725, 0.831] (25 series) | 0.784 [0.696, 0.86] (25 series) | 0.433 [0.336, 0.544] (25 series) | 0.028 | 0.405 |
| erratic | conformal | 0.855 [0.837, 0.875] (25 series) | 0.792 [0.744, 0.836] (25 series) | 0.439 [0.344, 0.558] (25 series) | 0.05 | 0.389 |
| intermittent | distribution | 0.969 [0.936, 0.993] (25 series) | 0.912 [0.84, 0.972] (25 series) | 22.64 [5.247, 40.281] (25 series) | 22.345 | 0.296 |
| intermittent | conformal | 0.97 [0.938, 0.993] (25 series) | 0.904 [0.832, 0.964] (25 series) | 43.408 [10.518, 76.813] (25 series) | 43.141 | 0.267 |
| lumpy | distribution | 0.901 [0.857, 0.941] (25 series) | 0.912 [0.864, 0.956] (25 series) | 0.316 [0.156, 0.502] (25 series) | 0.139 | 0.177 |
| lumpy | conformal | 0.917 [0.878, 0.953] (25 series) | 0.908 [0.86, 0.952] (25 series) | 0.632 [0.401, 0.903] (25 series) | 0.469 | 0.163 |

Quantile level 0.9, with the bootstrap interval after each value:

| Demand class | Strategy | Coverage | Lead-time coverage | Scaled pinball loss | Zero part | Non-zero part |
|---|---|---|---|---|---|---|
| smooth | distribution | undefined | undefined | undefined | undefined | undefined |
| smooth | conformal | undefined | undefined | undefined | undefined | undefined |
| erratic | distribution | 0.894 [0.863, 0.923] (25 series) | 0.864 [0.792, 0.928] (25 series) | 0.376 [0.286, 0.48] (25 series) | 0.023 | 0.353 |
| erratic | conformal | 0.895 [0.879, 0.911] (25 series) | 0.872 [0.836, 0.908] (25 series) | 0.381 [0.29, 0.49] (25 series) | 0.035 | 0.346 |
| intermittent | distribution | 0.975 [0.951, 0.993] (25 series) | 0.952 [0.904, 0.988] (25 series) | 12.618 [4.445, 21.584] (25 series) | 12.312 | 0.306 |
| intermittent | conformal | 0.977 [0.955, 0.994] (25 series) | 0.924 [0.872, 0.972] (25 series) | 21.863 [5.44, 38.557] (25 series) | 21.583 | 0.28 |
| lumpy | distribution | 0.95 [0.928, 0.97] (25 series) | 0.956 [0.924, 0.984] (25 series) | 0.422 [0.228, 0.659] (25 series) | 0.28 | 0.142 |
| lumpy | conformal | 0.934 [0.903, 0.962] (25 series) | 0.944 [0.904, 0.98] (25 series) | 0.402 [0.273, 0.543] (25 series) | 0.248 | 0.154 |

Quantile level 0.95, with the bootstrap interval after each value:

| Demand class | Strategy | Coverage | Lead-time coverage | Scaled pinball loss | Zero part | Non-zero part |
|---|---|---|---|---|---|---|
| smooth | distribution | undefined | undefined | undefined | undefined | undefined |
| smooth | conformal | undefined | undefined | undefined | undefined | undefined |
| erratic | distribution | 0.946 [0.93, 0.96] (25 series) | 0.892 [0.828, 0.948] (25 series) | 0.3 [0.217, 0.392] (25 series) | 0.019 | 0.282 |
| erratic | conformal | 0.895 [0.879, 0.911] (25 series) | 0.872 [0.836, 0.908] (25 series) | 0.324 [0.236, 0.423] (25 series) | 0.018 | 0.306 |
| intermittent | distribution | 0.982 [0.967, 0.994] (25 series) | 0.98 [0.956, 1.0] (25 series) | 7.107 [3.129, 11.513] (25 series) | 6.807 | 0.3 |
| intermittent | conformal | 0.977 [0.955, 0.994] (25 series) | 0.924 [0.872, 0.972] (25 series) | 11.086 [2.919, 19.438] (25 series) | 10.791 | 0.294 |
| lumpy | distribution | 0.983 [0.973, 0.991] (25 series) | 0.968 [0.94, 0.992] (25 series) | 0.369 [0.194, 0.592] (25 series) | 0.266 | 0.103 |
| lumpy | conformal | 0.934 [0.903, 0.962] (25 series) | 0.944 [0.904, 0.98] (25 series) | 0.275 [0.181, 0.378] (25 series) | 0.124 | 0.151 |

Differences at level 0.5, the value under the distribution quantiles minus the value under the conformal quantiles, with the bootstrap interval after each difference:

| Demand class | Coverage error | Lead-time coverage error | Scaled pinball loss | Coverage | Lead-time coverage |
|---|---|---|---|---|---|
| smooth | undefined | undefined | undefined | undefined | undefined |
| erratic | -0.075 [-0.138, -0.003] (25 series) | 0.02 [-0.064, 0.116] (25 series) | -0.037 [-0.1, 0.007] (25 series) | -0.163 [-0.224, -0.106] (25 series) | -0.06 [-0.144, 0.024] (25 series) |
| intermittent | 0.0 [0.0, 0.0] (25 series) | 0.0 [0.0, 0.0] (25 series) | 54.9 [10.901, 99.279] (25 series) | 0.0 [0.0, 0.0] (25 series) | 0.0 [0.0, 0.0] (25 series) |
| lumpy | -0.029 [-0.053, -0.01] (25 series) | -0.028 [-0.084, 0.024] (25 series) | 0.049 [-0.023, 0.157] (25 series) | -0.029 [-0.053, -0.01] (25 series) | -0.028 [-0.084, 0.024] (25 series) |

Differences at level 0.8, the value under the distribution quantiles minus the value under the conformal quantiles, with the bootstrap interval after each difference:

| Demand class | Coverage error | Lead-time coverage error | Scaled pinball loss | Coverage | Lead-time coverage |
|---|---|---|---|---|---|
| smooth | undefined | undefined | undefined | undefined | undefined |
| erratic | -0.037 [-0.066, 0.03] (25 series) | 0.008 [-0.032, 0.076] (25 series) | -0.006 [-0.055, 0.037] (25 series) | -0.074 [-0.126, -0.03] (25 series) | -0.008 [-0.08, 0.064] (25 series) |
| intermittent | -0.001 [-0.005, 0.002] (25 series) | 0.008 [-0.008, 0.024] (25 series) | -20.767 [-36.799, -5.428] (25 series) | -0.001 [-0.005, 0.002] (25 series) | 0.008 [-0.008, 0.024] (25 series) |
| lumpy | -0.016 [-0.035, 0.003] (25 series) | 0.004 [-0.028, 0.04] (25 series) | -0.316 [-0.544, -0.123] (25 series) | -0.016 [-0.035, 0.003] (25 series) | 0.004 [-0.028, 0.04] (25 series) |

Differences at level 0.9, the value under the distribution quantiles minus the value under the conformal quantiles, with the bootstrap interval after each difference:

| Demand class | Coverage error | Lead-time coverage error | Scaled pinball loss | Coverage | Lead-time coverage |
|---|---|---|---|---|---|
| smooth | undefined | undefined | undefined | undefined | undefined |
| erratic | 0.001 [-0.011, 0.028] (25 series) | 0.008 [-0.036, 0.072] (25 series) | -0.005 [-0.04, 0.029] (25 series) | -0.001 [-0.029, 0.023] (25 series) | -0.008 [-0.076, 0.052] (25 series) |
| intermittent | -0.002 [-0.006, 0.0] (25 series) | 0.028 [-0.016, 0.048] (25 series) | -9.244 [-17.5, -1.491] (25 series) | -0.002 [-0.006, 0.0] (25 series) | 0.028 [0.008, 0.052] (25 series) |
| lumpy | 0.016 [0.0, 0.033] (25 series) | 0.012 [-0.012, 0.04] (25 series) | 0.02 [-0.091, 0.15] (25 series) | 0.016 [0.0, 0.034] (25 series) | 0.012 [-0.012, 0.044] (25 series) |

Differences at level 0.95, the value under the distribution quantiles minus the value under the conformal quantiles, with the bootstrap interval after each difference:

| Demand class | Coverage error | Lead-time coverage error | Scaled pinball loss | Coverage | Lead-time coverage |
|---|---|---|---|---|---|
| smooth | undefined | undefined | undefined | undefined | undefined |
| erratic | -0.05 [-0.062, -0.031] (25 series) | -0.02 [-0.076, 0.04] (25 series) | -0.023 [-0.043, -0.004] (25 series) | 0.05 [0.034, 0.066] (25 series) | 0.02 [-0.04, 0.08] (25 series) |
| intermittent | 0.005 [-0.001, 0.014] (25 series) | 0.004 [-0.068, 0.04] (25 series) | -3.979 [-8.363, 0.081] (25 series) | 0.005 [-0.001, 0.014] (25 series) | 0.056 [0.024, 0.092] (25 series) |
| lumpy | 0.017 [-0.021, 0.038] (25 series) | 0.012 [-0.036, 0.032] (25 series) | 0.095 [-0.049, 0.28] (25 series) | 0.049 [0.027, 0.074] (25 series) | 0.024 [-0.004, 0.06] (25 series) |
<!-- /generated:summary-real -->

The note on the difference tables under the synthetic results applies here as well: the coverage error and lead-time coverage error intervals are unreliable where both strategies are close to the level, and the signed differences in the last two columns show which strategy covers more.

## Interpretation

The list below is generated from the committed study results. Separately for the synthetic series and for the Online Retail II series, it names every demand class and quantile level at which the distribution quantiles do worse than the conformal baseline on one of three measures, considering only comparisons in which both values are defined: a larger absolute difference between the coverage and the level, a larger absolute difference between the lead-time coverage and the level, or a larger scaled pinball loss. Each entry shows the measured values under both strategies and the difference with its bootstrap interval. The two subsections after the list read the entries class by class, with the per-process tables of the synthetic check, the per-series records of the study results and the two parts of the loss as the supporting evidence, and state next to each group of comparisons the caveat that applies to it.

<!-- generated:worse -->
Synthetic series:

- smooth at level 0.8, lead-time coverage: 0.846 under the distribution quantiles against 0.83 under the conformal quantiles, further from the level by 0.016 [-0.012, 0.044]
- smooth at level 0.9, lead-time coverage: 0.938 under the distribution quantiles against 0.924 under the conformal quantiles, further from the level by 0.014 [-0.006, 0.032]
- smooth at level 0.95, lead-time coverage: 0.976 under the distribution quantiles against 0.924 under the conformal quantiles, further from the level by 0.0 [-0.03, 0.028]
- erratic at level 0.8, coverage: 0.91 under the distribution quantiles against 0.8 under the conformal quantiles, further from the level by 0.11 [0.082, 0.128]
- erratic at level 0.8, lead-time coverage: 0.792 under the distribution quantiles against 0.798 under the conformal quantiles, further from the level by 0.006 [-0.018, 0.038]
- erratic at level 0.8, scaled pinball loss: 0.396 under the distribution quantiles against 0.392 under the conformal quantiles, larger by 0.004 [-0.01, 0.017]
- erratic at level 0.9, coverage: 1.0 under the distribution quantiles against 0.863 under the conformal quantiles, further from the level by 0.063 [0.054, 0.072]
- intermittent at level 0.5, lead-time coverage: 0.56 under the distribution quantiles against 0.516 under the conformal quantiles, further from the level by 0.044 [0.006, 0.062]
- intermittent at level 0.8, coverage: 0.82 under the distribution quantiles against 0.809 under the conformal quantiles, further from the level by 0.011 [0.001, 0.021]
- intermittent at level 0.8, scaled pinball loss: 0.472 under the distribution quantiles against 0.459 under the conformal quantiles, larger by 0.013 [0.006, 0.022]
- lumpy at level 0.5, lead-time coverage: 0.562 under the distribution quantiles against 0.546 under the conformal quantiles, further from the level by 0.016 [-0.014, 0.048]
- lumpy at level 0.8, lead-time coverage: 0.816 under the distribution quantiles against 0.812 under the conformal quantiles, further from the level by 0.004 [-0.018, 0.024]
- lumpy at level 0.9, coverage: 0.939 under the distribution quantiles against 0.897 under the conformal quantiles, further from the level by 0.036 [0.019, 0.046]

Online Retail II series:

- erratic at level 0.5, lead-time coverage: 0.46 under the distribution quantiles against 0.52 under the conformal quantiles, further from the level by 0.02 [-0.064, 0.116]
- erratic at level 0.8, lead-time coverage: 0.784 under the distribution quantiles against 0.792 under the conformal quantiles, further from the level by 0.008 [-0.032, 0.076]
- erratic at level 0.9, coverage: 0.894 under the distribution quantiles against 0.895 under the conformal quantiles, further from the level by 0.001 [-0.011, 0.028]
- erratic at level 0.9, lead-time coverage: 0.864 under the distribution quantiles against 0.872 under the conformal quantiles, further from the level by 0.008 [-0.036, 0.072]
- intermittent at level 0.5, scaled pinball loss: 55.107 under the distribution quantiles against 0.208 under the conformal quantiles, larger by 54.9 [10.901, 99.279]
- intermittent at level 0.8, lead-time coverage: 0.912 under the distribution quantiles against 0.904 under the conformal quantiles, further from the level by 0.008 [-0.008, 0.024]
- intermittent at level 0.9, lead-time coverage: 0.952 under the distribution quantiles against 0.924 under the conformal quantiles, further from the level by 0.028 [-0.016, 0.048]
- intermittent at level 0.95, coverage: 0.982 under the distribution quantiles against 0.977 under the conformal quantiles, further from the level by 0.005 [-0.001, 0.014]
- intermittent at level 0.95, lead-time coverage: 0.98 under the distribution quantiles against 0.924 under the conformal quantiles, further from the level by 0.004 [-0.068, 0.04]
- lumpy at level 0.5, scaled pinball loss: 0.225 under the distribution quantiles against 0.177 under the conformal quantiles, larger by 0.049 [-0.023, 0.157]
- lumpy at level 0.8, lead-time coverage: 0.912 under the distribution quantiles against 0.908 under the conformal quantiles, further from the level by 0.004 [-0.028, 0.04]
- lumpy at level 0.9, coverage: 0.95 under the distribution quantiles against 0.934 under the conformal quantiles, further from the level by 0.016 [0.0, 0.033]
- lumpy at level 0.9, lead-time coverage: 0.956 under the distribution quantiles against 0.944 under the conformal quantiles, further from the level by 0.012 [-0.012, 0.04]
- lumpy at level 0.9, scaled pinball loss: 0.422 under the distribution quantiles against 0.402 under the conformal quantiles, larger by 0.02 [-0.091, 0.15]
- lumpy at level 0.95, coverage: 0.983 under the distribution quantiles against 0.934 under the conformal quantiles, further from the level by 0.017 [-0.021, 0.038]
- lumpy at level 0.95, lead-time coverage: 0.968 under the distribution quantiles against 0.944 under the conformal quantiles, further from the level by 0.012 [-0.036, 0.032]
- lumpy at level 0.95, scaled pinball loss: 0.369 under the distribution quantiles against 0.275 under the conformal quantiles, larger by 0.095 [-0.049, 0.28]
<!-- /generated:worse -->

### Synthetic series

The synthetic results hold 48 comparisons, four demand classes at four levels on three measures. In 13 of them, the entries above, the distribution quantiles do worse; in 34 they are closer to the level or have the smaller loss; and one is an exact tie, the erratic lead-time coverage at 0.9, where 0.908 under the distribution quantiles and 0.892 under the conformal quantiles are both 0.008 from the level. One property of the baseline shapes many of the rows at 0.9 and 0.95. Ten windows give twenty collection values per period, and the quantile rule takes the smallest value whose share of the collection reaches the level: at 0.9 that is the 19th smallest, because the floating-point value 0.9 is slightly larger than 9/10 and 18 of the 20 values fall short of it, and at 0.95 it is the 19th smallest too. The conformal baseline therefore reports the same quantile at 0.9 and at 0.95, and its coverage at the two levels is identical in every class of both results sections, 0.911, 0.863, 0.858 and 0.897 per period for the four synthetic classes; where it is close to the level at 0.9 it falls short at 0.95.

For the smooth series the three entries are the lead-time coverages at 0.8, 0.9 and 0.95: 0.846, 0.938 and 0.976 under the distribution quantiles against 0.83, 0.924 and 0.924 under the conformal quantiles. The true quantiles cover 0.824, 0.932 and 0.962 of the same 500 totals (the smooth-gaussian table above), so the distribution quantiles lie 0.022, 0.006 and 0.014 above the coverage of the true quantiles and the conformal quantiles 0.006 above, 0.008 below and 0.038 below it. At 0.95 the two strategies are equally far from the level, 0.026 above and 0.026 below; the entry appears because the two distances differ by a floating-point rounding error of about 1e-16, which prints as 0.0, and its interval [-0.03, 0.028] is centered on zero. The intervals of all three entries include zero. In every other comparison on the smooth series the distribution quantiles are the closer ones or have the smaller loss: per-period coverage 0.505, 0.802, 0.906 and 0.951 against 0.458, 0.812, 0.911 and 0.911, and scaled pinball loss 0.363, 0.254, 0.159 and 0.093 against 0.367, 0.263, 0.169 and 0.105.

The erratic series carry the largest synthetic entries, both in per-period coverage: 0.91 against 0.8 at 0.8, further from the level by 0.11 [0.082, 0.128], and 1.0 against 0.863 at 0.9, further by 0.063 [0.054, 0.072]. The erratic-bernoulli table shows the shape of the problem. The sizes are 1, 3 and 10, and a quantile of 3 covers a demand of 0, 1 or 3, which the process produces with probability 0.781, while a quantile of 10 covers every demand; the true quantile at 0.8, 0.9 and 0.95 is 10, so the true quantiles themselves cover 1.0 at those levels, 0.2, 0.1 and 0.05 above the level. The distribution quantile at 0.8 is 3 at some origins and 10 at others, depending on the estimated occurrence probability and on the share of sizes at most 3 in the fitted history, which is how it covers 0.91; at 0.9 and 0.95 it is 10 and covers everything, like the true quantile, while the conformal quantile covers 0.863 at both levels, which makes the distribution quantiles the further ones at 0.9 (0.1 above against 0.037 below) and the closer ones at 0.95 (0.05 above against 0.087 below). The other two erratic entries are small and their intervals include zero: lead-time coverage 0.792 against 0.798 at 0.8 (0.006 [-0.018, 0.038]) and scaled pinball loss 0.396 against 0.392 at 0.8 (0.004 [-0.01, 0.017]). At 0.9 and 0.95 the distribution quantiles have the smaller loss by a wide margin, 0.19 and 0.095 against 0.244 and 0.167. These erratic results are read knowing that the SBA factor on the occurrence probability, `1 - alpha / 2` or 0.95 at the default smoothing parameter, is the large-interval limit of the exact bias factor and under-states the occurrence probability most where the smoothed interval is close to 1, which is where erratic series sit: demand occurs in 0.875 of the periods of this process, so the smoothed interval is near 1.14 and the estimated probability is 5 percent below the plug-in value `1 / interval`. An under-stated occurrence probability raises the estimated probability of a zero demand, which can only lower the per-period quantiles and the simulated totals. It does not produce the over-coverage at 0.8 and 0.9, which comes from the size 10 that the true quantile picks as well, but it pulls the lead-time quantiles down, and the erratic lead-time coverage under the distribution quantiles is below that of the true quantiles at every level: 0.47, 0.792, 0.908 and 0.956 against 0.512, 0.836, 0.94 and 0.972.

For the intermittent series the entries are the lead-time coverage at 0.5, 0.56 against 0.516 (0.044 [0.006, 0.062]), the per-period coverage at 0.8, 0.82 against 0.809 (0.011 [0.001, 0.021]), and the scaled pinball loss at 0.8, 0.472 against 0.459 (0.013 [0.006, 0.022]); all three intervals exclude zero. At 0.8 the true quantile is 2 and covers 0.849 of the same held-out observations (the probability of a demand at most 2 is 0.85), so both strategies under-cover relative to the true quantile, and the distribution quantiles, at 0.82, are closer to that coverage while being further from the level. The two parts of the loss show where the extra 0.013 comes from: the distribution quantiles lose less on the zero outcomes, 0.167 against 0.205, and more on the non-zero ones, 0.305 against 0.254, so at 0.8 they sit below the outcome more often than the conformal quantiles do. At 0.5 the per-period coverages are 0.747 and 0.748, the coverage of the true quantile, which is zero because a period has no demand with probability 0.75; the lead-time coverage compares 0.56 under the distribution quantiles and 0.516 under the conformal quantiles with 0.586 for the true quantile of the total, so here too the distribution quantiles are closer to the true coverage and further from the level. That lead-time entry is a comparison at the 0.5 level, which is read knowing that the conformal 0.5 quantile is the point forecast minus the smallest window error rather than the point forecast, for the lead time the sum of the point forecasts minus the smallest absolute total error over the ten windows, so the two strategies are not compared at the same object there: the conformal 0.5 quantile is lower by construction, which lowers its coverage toward the level on these series and away from it on the smooth series, where the conformal quantiles cover 0.458 per period and 0.452 for the lead time against 0.505 and 0.494 under the distribution quantiles. At 0.9 and 0.95 the distribution quantiles are closer to the level and have the smaller loss: coverage 0.923 and 0.972 against 0.858 and 0.858, lead-time coverage 0.9 and 0.944 against 0.882 and 0.882, loss 0.318 and 0.176 against 0.356 and 0.276.

For the lumpy series the entries are the lead-time coverage at 0.5, 0.562 against 0.546 (0.016 [-0.014, 0.048]), the lead-time coverage at 0.8, 0.816 against 0.812 (0.004 [-0.018, 0.024]), and the per-period coverage at 0.9, 0.939 against 0.897 (0.036 [0.019, 0.046]); the first two intervals include zero. At 0.9 the true quantile is 3, the probability of a demand at most 3 is 0.938 and the true quantile covers 0.943 of these observations: the distribution quantiles cover 0.939, within 0.004 of the true quantile, and the conformal quantiles 0.897, so the entry records that the level 0.9 lies below the coverage the true quantile of this discrete distribution attains, not that the distribution quantiles miss it. The 0.5 lead-time entry is read with the same 0.5 caveat as above; the true total quantile covers 0.554 there, the distribution quantiles 0.562 and the conformal quantiles 0.546. At 0.95 the distribution quantiles cover 0.983 against 0.897 with a loss of 0.278 against 0.337, and the true quantile is 10, which covers every observation; at every level the distribution quantiles have the smaller loss, 0.276, 0.421, 0.382 and 0.278 against 0.368, 0.458, 0.406 and 0.337.

### Online Retail II series

The subset has no smooth series, so the smooth rows are undefined and enter no comparison; the 36 comparisons of the other three classes give the 17 entries above, 17 comparisons in which the distribution quantiles do better and two exact ties, the per-period and lead-time coverage of the intermittent class at 0.5, where both strategies cover 0.964 and 0.872. Every interval in this section is read with the caveat stated above the real-data tables: all 75 series end on 9 December 2011, so every held-out window of every series covers the same 70 trading dates before the retailer's pre-Christmas peak, and the bootstrap over series, which treats them as independent units, understates the uncertainty of every value and difference below. An interval that excludes zero here is weaker evidence than the same interval on the synthetic series, whose series are independent by construction. The conformal quantiles coincide at 0.9 and 0.95 here as well, with per-period coverages of 0.895, 0.977 and 0.934 in the erratic, intermittent and lumpy classes at both levels.

For the erratic series the four entries are small and every interval includes zero: lead-time coverage 0.46 against 0.52 at 0.5 (0.02 [-0.064, 0.116]), 0.784 against 0.792 at 0.8 (0.008 [-0.032, 0.076]) and 0.864 against 0.872 at 0.9 (0.008 [-0.036, 0.072]), and per-period coverage 0.894 against 0.895 at 0.9 (0.001 [-0.011, 0.028]). In the other comparisons the distribution quantiles are the closer ones, most clearly per period at 0.5, 0.456 against 0.619, and at 0.95, 0.946 against 0.895 per period and 0.892 against 0.872 for the lead time, and their scaled pinball loss is smaller at every level: 0.375, 0.433, 0.376 and 0.3 against 0.412, 0.439, 0.381 and 0.324. The erratic caveat applies here as on the synthetic series: demand occurs in 1487 of the 1750 held-out observations of these series, so their smoothed intervals are close to 1, where the SBA factor under-states the occurrence probability most, which can only lower the distribution quantiles. The lead-time entry at 0.5 is also a comparison at the 0.5 level, where the conformal quantile is the sum of the point forecasts minus the smallest absolute total error rather than the point forecast, so the two strategies are not compared at the same object there.

The intermittent series produce the largest entry of the study, the scaled pinball loss at 0.5: 55.107 under the distribution quantiles against 0.208 under the conformal quantiles, larger by 54.9 [10.901, 99.279], with 54.91 of the 55.107 in the zero part of the loss. The per-series records show where it comes from. Five of the 25 series, the stock codes 21290, 37494a, 47347A, 79069A and 85164b, were sold once, on their first trading date, and never again: one positive value followed by 583 to 603 zeros. On such a history Croston's method sees one size and one interval of length 1, so the smoothed interval is 1, the occurrence probability is 0.95 (the SBA factor over an interval of 1) and every distribution quantile at every level is that one size; the conformal baseline records ten window errors that all equal the point forecast, so its 0.5 quantile, the point forecast minus the smallest error, is zero, and its quantiles at 0.8, 0.9 and 0.95 are twice the point forecast. The scale of these series is the one non-zero one-step difference, the sale itself, divided by the number of one-step differences before the origin, so a quantile equal to the sale on a zero outcome costs, at level 0.5, half the length of the history in scale units: the five series have a scaled pinball loss at 0.5 between 272 and 283 under the distribution quantiles and exactly zero under the conformal quantiles, and their MASE, 0.95 times the same length, lies between 517 and 537, which is why the class MASE of 108.185 is far above the mean of 4.82 over the other 20 series. On those 20 series the mean loss at 0.5 is 0.247 under the distribution quantiles and 0.26 under the conformal quantiles. At 0.8, 0.9 and 0.95 the same five series turn the comparison around, because the conformal quantile there is twice the distribution quantile: the class loss is 22.64, 12.618 and 7.107 under the distribution quantiles against 43.408, 21.863 and 11.086 under the conformal quantiles. The 0.5 entry is exactly the comparison the 0.5 caveat addresses: the conformal quantile at 0.5 is not the point forecast but the point forecast minus the smallest window error, which is zero on these five series, so the two strategies are not compared at the same object. The other intermittent entries are coverage differences whose intervals all include zero: lead-time coverage 0.912 against 0.904 at 0.8 (0.008 [-0.008, 0.024]), 0.952 against 0.924 at 0.9 (0.028 [-0.016, 0.048]) and 0.98 against 0.924 at 0.95 (0.004 [-0.068, 0.04]), and per-period coverage 0.982 against 0.977 at 0.95 (0.005 [-0.001, 0.014]). Only 63 of the 1750 held-out observations of this class are non-zero, and 17 of its 25 series have no non-zero held-out observation at all, so a quantile of zero already covers 0.964 of the observations and every per-period coverage of both strategies lies between 0.964 and 0.982 at every level; the coverage comparisons in this class say little about either strategy.

The lumpy series have eight entries, and every interval includes zero, one of them only at its lower bound: the per-period coverage at level 0.9, where 0.95 under the distribution quantiles stands against 0.934 under the conformal quantiles (0.016 [0.0, 0.033]). That entry and the per-period coverage at level 0.95, 0.983 against 0.934 (0.017 [-0.021, 0.038]), come from a baseline that reports the same quantile at both levels: 0.934 is 0.034 above 0.9 and 0.016 below 0.95, while the distribution quantiles cover 0.95 at 0.9 and 0.983 at 0.95, above the level at both. The lead-time coverages over-cover under both strategies with intervals that include zero: 0.912 against 0.908 at 0.8 (0.004 [-0.028, 0.04]), 0.956 against 0.944 at 0.9 (0.012 [-0.012, 0.04]) and 0.968 against 0.944 at 0.95 (0.012 [-0.036, 0.032]). The three loss entries have intervals that include zero as well: 0.225 against 0.177 at 0.5 (0.049 [-0.023, 0.157]), 0.422 against 0.402 at 0.9 (0.02 [-0.091, 0.15]) and 0.369 against 0.275 at 0.95 (0.095 [-0.049, 0.28]). The two parts of the loss show the trade behind them. At 0.95 the distribution quantiles lose 0.266 on the zero outcomes against 0.124 and 0.103 on the non-zero outcomes against 0.151: they sit higher, cover more (0.983 against 0.934) and pay for it on the 1352 zero held-out observations of the class; at 0.9 the split is 0.28 and 0.142 against 0.248 and 0.154, in the same direction. At 0.8 the direction reverses and the distribution quantiles have half the loss, 0.316 against 0.632, with 0.139 against 0.469 in the zero part. The 0.5 loss entry is a comparison at the 0.5 level, where the conformal quantile is the point forecast minus the smallest window error rather than the point forecast, so the two strategies are not compared at the same object; the zero part of the loss, 0.034 under the conformal quantiles against 0.072 under the distribution quantiles, shows that the lower conformal 0.5 quantiles are what saves the loss on the zero outcomes.

## Regeneration

Every committed artifact is regenerated by one of the commands below, run from the repository root. The two Python scripts need the packages listed at the end of this section, installed from PyPI into a virtual environment with `pip install -r <file>`; the study and the documents need Ruby alone.

- `data/reference_outputs.json`: `python dev/reference/generate.py`, under Python 3.12.12, the version recorded in the file, with the packages of `dev/reference/requirements.txt`. The script reads `data/fixture_series.json` and needs no network access itself; installing the packages does. It refuses to run when statsforecast is missing or is not version 2.1.1, writes nothing unless every forecast is finite, and runs in about two seconds on the platform recorded above.
- `data/online_retail_ii_subset.json`: `python dev/retail/extract.py` and then `ruby -Ilib dev/retail/select.rb`. The first stage runs under Python 3.12.12 with the packages of `dev/retail/requirements.txt`, downloads the zip file from the UCI Machine Learning Repository, so it needs network access, and takes about a minute on the platform recorded above, most of it reading the two worksheets. The second stage runs under Ruby 3.1 or newer with the gem's own code and Ruby's standard library, needs no network access and takes about a second. A rerun on a download with the same checksums writes a byte-identical subset.
- `validation/study_results.json` and the generated regions of this document and of `docs/methodology.md`: `bundle exec rake reproduce`, which runs `ruby -Ilib validation/study.rb` and then `ruby -Ilib validation/render.rb` and stops at the first failure. It needs Ruby 3.1 or newer, the gem's own code, Ruby's standard library and, for the task itself, the development gems pinned in the Gemfile (rake 13.4.2 and minitest 5.27.0, installed with `bundle install`); no Python and no network access. The study runs in about 20 seconds on the platform recorded above and the rendering in under a second. On the platform and Ruby version recorded in the results the task rewrites the results and both documents byte for byte, so `git status --porcelain` prints nothing afterwards. On another platform the synthetic Gaussian series, which are drawn with `Math.log` and `Math.cos`, can differ in their last bits, and with them the numbers of the smooth class and of the smooth-gaussian process; the other classes use only basic floating-point operations and seeded integer draws, which do not depend on the platform.

The pinned packages of the two Python scripts, read from the requirements files:

<!-- generated:packages -->
`dev/reference/requirements.txt`:

| Package | Version |
|---|---|
| adagio | 0.2.6 |
| cloudpickle | 3.1.2 |
| coreforecast | 0.0.18 |
| formulaic | 1.2.2 |
| fsspec | 2026.9.0 |
| fugue | 0.9.7 |
| interface_meta | 2.0.1 |
| narwhals | 2.26.0 |
| numpy | 2.5.3 |
| packaging | 26.3 |
| pandas | 2.3.3 |
| patsy | 1.0.3 |
| pyarrow | 25.0.1 |
| python-dateutil | 2.9.0.post0 |
| pytz | 2026.4 |
| scipy | 1.18.1 |
| six | 1.17.0 |
| statsforecast | 2.1.1 |
| statsmodels | 0.15.0 |
| threadpoolctl | 3.7.0 |
| tqdm | 4.70.1 |
| triad | 1.0.2 |
| typing_extensions | 4.16.0 |
| tzdata | 2026.4 |
| utilsforecast | 0.2.16 |
| wrapt | 2.4.1 |

`dev/retail/requirements.txt`:

| Package | Version |
|---|---|
| et_xmlfile | 2.0.0 |
| numpy | 2.5.3 |
| openpyxl | 3.1.5 |
| pandas | 3.0.6 |
| python-dateutil | 2.9.0.post0 |
| six | 1.17.0 |
<!-- /generated:packages -->

## Revisions

No revisions.
