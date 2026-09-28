# Foresight

Foresight is a Ruby gem for probabilistic demand forecasting. It is written for Ruby and Rails developers who forecast demand, such as orders, stock or capacity, and who need more than one number per period: the quantiles of demand for each period and for the whole horizon, so that the forecast answers how many units cover the next N periods with a chosen probability.

Relative to prophet-rb, the established in-process forecasting gem for Ruby, which provides a single Stan-based model, Foresight provides the intermittent-demand methods CrostonClassic, CrostonSBA and TSB, demand classification with automatic model selection, and quantiles as the default output of every method, through a simple API modeled on the simple API of prophet-rb: `Foresight.forecast(series, count: 7)` takes the Hash that groupdate returns and keys the forecasts the same way.

The thesis behind the library is that decisions about how much to stock, staff or provision need calibrated demand distributions, and that point forecasts mislead for intermittent demand, meaning series in the intermittent and lumpy demand classes, where most periods have no demand at all. On such a series the point forecast that minimizes the absolute error is the median of the predictive distribution, which is zero whenever the chance of a period without demand is at least one half, so on its own it gives no basis for a stock level. Calibration is a measured property: the quantiles at a level q are calibrated when they cover a proportion q of the observed outcomes. Foresight treats calibration as something to measure and publish rather than to assume.

Foresight is a prototype. It implements the architecture and measures the calibration problem on synthetic series and on one real dataset. The planned work listed under the Roadmap heading below is not implemented.

## Installation

Foresight is not published on rubygems.org yet. Install it from the GitHub source, either through Bundler:

```ruby
gem "foresight", git: "https://github.com/ojuschugh1/foresight"
```

or by building the gem locally:

```sh
git clone https://github.com/ojuschugh1/foresight
cd foresight
gem build foresight.gemspec
gem install ./foresight-0.1.0.gem
```

Then `require "foresight"`. Foresight needs Ruby 3.1 or newer, runs on Linux and macOS, and has zero runtime dependencies: it is pure Ruby and loads nothing beyond the standard library.

Two notes on input. Use Date keys for daily and coarser data, which is what groupdate's `group_by_day` returns; Time keys one day apart in a zone that changes its UTC offset during the year are 23 or 25 hours apart across the change, and Foresight rejects such a series because its keys do not follow one frequency. Values must be finite, non-negative numbers of at most 10^15; exactly 1e15 is accepted and anything above it is rejected.

## Quickstart

Six weeks of daily unit sales for one slow-moving product, in the shape that `Order.group_by_day(:created_at).count` returns (a Hash of Date keys and Integer values, with a zero on every day without an order), forecast seven days ahead without choosing a model:

```ruby
require "date"
require "foresight"

start = Date.new(2026, 1, 5)
units = [0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 0, 3, 0, 0, 1, 0, 0, 0, 0, 0, 2,
         0, 0, 0, 4, 0, 0, 0, 0, 1, 0, 0, 2, 0, 0, 0, 0, 1, 0, 0, 3, 0]
series = units.each_with_index.to_h { |demand, day| [start + day, demand] }

result = Foresight.forecast(series, count: 7)

puts "#{result.model}: #{result.reason}"
labels = result.levels.map { |level| "q#{level}".rjust(5) }
puts ["date".ljust(10), "point", *labels].join("  ")
result.forecast.each do |date, point|
  quantiles = result.levels.map { |level| result.quantiles[level][date].round(2).to_s.rjust(5) }
  puts [date.to_s, point.round(2).to_s.rjust(5), *quantiles].join("  ")
end
result.lead_time_quantiles.each do |level, total|
  puts "7-day total at q#{level}: #{total.round(2)}"
end
```

```
croston_sba: auto-selected croston_sba for intermittent demand (ADI 4.20, CV squared 0.25)
date        point   q0.5   q0.8   q0.9  q0.95
2026-02-16   0.52    0.0    1.0    2.0    3.0
2026-02-17   0.52    0.0    1.0    2.0    3.0
2026-02-18   0.52    0.0    1.0    2.0    3.0
2026-02-19   0.52    0.0    1.0    2.0    3.0
2026-02-20   0.52    0.0    1.0    2.0    3.0
2026-02-21   0.52    0.0    1.0    2.0    3.0
2026-02-22   0.52    0.0    1.0    2.0    3.0
7-day total at q0.5: 3.0
7-day total at q0.8: 6.0
7-day total at q0.9: 7.0
7-day total at q0.95: 8.0
```

Foresight classified the series as intermittent (an order every 4.2 days on average, with order sizes whose squared coefficient of variation is 0.25) and picked CrostonSBA. The point forecast of 0.52 units a day is the smoothed demand rate and the least useful line of the output: on any single day the chance of no demand is above one half, which is why the 0.5 quantile is zero. The per-step quantiles say that, under the fitted model, 1 unit covers the demand of a single day with probability 0.8, 2 units with probability 0.9 and 3 units with probability 0.95. The lead-time quantiles answer the replenishment question directly: 6 units cover the total demand of the next 7 days with probability 0.8, 7 units with probability 0.9 and 8 units with probability 0.95.

## Usage

### Series input

Every entry point takes a series in one of two shapes:

- a Hash whose keys are all Date values or all Time values (any object for which `is_a?(Time)` holds, including `ActiveSupport::TimeWithZone`) and whose values are numbers, which is what groupdate returns;
- an Array of numbers, one per period, in time order.

Values must be finite real numbers from 0 to 10^15. Foresight sorts a Hash by key, never modifies the input, and detects the frequency from the keys: daily, weekly, monthly or yearly for Date keys, or a fixed number of seconds for Time keys. Every period must be present, with a value of zero for periods without demand; a gap or an irregular key raises `Foresight::InputError` naming the first pair of keys that breaks the frequency. `Foresight.forecast` and `Foresight.backtest` need at least two keys to detect the frequency; `Foresight.classify` also accepts a Hash with one key.

### Foresight.forecast(series, **options)

Fits a model, produces the point forecasts and the quantiles, and returns a `Foresight::Result`.

| Option | Accepted values | Default | Read by |
|---|---|---|---|
| `count` | Integer of at least 1 | 10 | the forecast horizon |
| `model` | `:naive`, `:seasonal_naive`, `:ses`, `:croston_classic`, `:croston_sba`, `:tsb` | automatic selection | model choice |
| `levels` | non-empty Array of numbers strictly between 0 and 1 | `[0.5, 0.8, 0.9, 0.95]` | both strategies |
| `strategy` | `:distribution`, `:conformal` | `:distribution` | quantiles |
| `seed` | Integer of at least 0 | 0 | compound quantiles |
| `season_length` | Integer of at least 1 | none, required by `:seasonal_naive` | SeasonalNaive |
| `paths` | Integer of at least 1 | 10,000 | compound quantiles |
| `windows` | Integer of at least 2 | 2 | conformal quantiles |
| `alpha` | number strictly between 0 and 1 | 0.1 | CrostonClassic and CrostonSBA |
| `alpha_d` | number strictly between 0 and 1 | 0.1 | TSB, demand sizes |
| `alpha_p` | number strictly between 0 and 1 | 0.1 | TSB, demand occurrence |

Passing `nil` for an option is the same as omitting it. Duplicate levels count once and the result lists the levels in ascending order. An accepted option that the model or strategy in use does not read, such as `seed` under a smooth model, leaves the result unchanged. An unknown option name, or a value outside the accepted values, raises `Foresight::InputError` rather than `ArgumentError`.

`Foresight::Result` is a Struct with these fields:

| Field | Value |
|---|---|
| `forecast` | the point forecasts: a Hash from each future key to its value for a keyed series (the shape prophet-rb returns), an Array for an Array series |
| `quantiles` | a Hash from each quantile level to the per-step quantiles, in the shape of `forecast` |
| `lead_time_quantiles` | a Hash from each quantile level to one number, the quantile of total demand over the whole horizon |
| `model` | the Symbol of the model that produced the forecasts |
| `demand_class` | `:smooth`, `:erratic`, `:intermittent` or `:lumpy` for the complete series, or `nil` when a model was specified for a series without a non-zero value |
| `reason` | a String stating how the model was chosen, with the ADI and the CV squared when it was chosen automatically |
| `strategy` | `:distribution` or `:conformal` |
| `levels` | the quantile levels in ascending order |

Future keys continue the detected frequency from the last key: k days, 7k days, k calendar months on the same day of the month, k calendar years on the same month and day, or k times the spacing in seconds, in the class and time zone of the last key. A monthly series whose day of the month is missing from one of the forecast months raises `Foresight::InputError`.

Every quantile is a finite number of at least zero, and quantiles never decrease with the level. Under the default strategy a compound per-step quantile is always zero or a demand size seen in the history, and a compound lead-time quantile is a sum of such sizes, as the quickstart shows.

Automatic selection needs at least one non-zero observation; a series of zeros needs an explicit `model`. Each model and strategy declares the number of observations it needs: Naive, SES and the three intermittent models fit on a single observation and SeasonalNaive needs `season_length` observations; Gaussian quantiles need one observation more than the model, so that there is at least one residual, and conformal quantiles need `windows` times `count` more. A shorter series raises `Foresight::InputError` naming the component and both numbers.

### Foresight.classify(series)

Returns a `Foresight::Classification` Struct with `demand_class`, `adi` and `cv_squared`. The ADI is the number of observations divided by the number of non-zero observations; the CV squared is the population variance of the non-zero observations divided by the square of their mean. Both are compared exactly with the cutoffs 1.32 and 0.49 of Syntetos, Boylan and Croston (2005): an ADI of at least 1.32 makes the series intermittent or lumpy, and a CV squared of at least 0.49 makes it erratic or lumpy. The series needs at least one non-zero observation.

```ruby
classification = Foresight.classify([0, 0, 2, 0, 1, 0, 0, 3])
classification.demand_class # => :intermittent
classification.adi.round(2) # => 2.67
```

### Foresight.backtest(series, horizon:, origins:, step: nil, **options)

Rolling-origin evaluation of the forecasts on the history of one series. The last held-out window ends at the last observation, consecutive origins are `step` periods apart (`step` defaults to `horizon`), and at each origin the model and the quantile strategy are fitted on the observations before the origin alone; without a `model`, automatic selection runs at every origin. All the options of `forecast` other than `count` apply. Returns a `Foresight::Backtest` Struct:

| Field | Value |
|---|---|
| `origins` | one `Foresight::OriginResult` per origin that was not excluded, in order |
| `excluded_origins` | the number of origins skipped because no model was given and the history before them had no non-zero value |
| `zero_scale_origins` | the number of origins whose MASE scale is zero |
| `held_out`, `zero_held_out`, `nonzero_held_out` | the number of held-out observations, and how many of them are zero and non-zero |
| `mae`, `rmse`, `mase` | the means over the origins of the per-origin point metrics |
| `scaled_pinball`, `scaled_pinball_zero`, `scaled_pinball_nonzero` | Hashes from each level to the mean scaled pinball loss over the origins, and to the parts of it from zero and from non-zero held-out observations |
| `coverage` | a Hash from each level to the proportion of held-out observations at most their per-step quantile, pooled over the origins |
| `lead_time_coverage` | a Hash from each level to the proportion of origins whose held-out total is at most the lead-time quantile |
| `covered`, `lead_time_hits` | the counts behind the two proportions |

Each `Foresight::OriginResult` holds `start` (the key, or the position for an Array series, of the first held-out observation), `model`, `mase_scale`, `mae`, `rmse`, `mase`, the Hashes by level `scaled_pinball`, `scaled_pinball_zero`, `scaled_pinball_nonzero`, `coverage` and `covered`, the counts `zero_held_out` and `nonzero_held_out`, and `lead_time_hit`, a Hash from each level to true or false.

The MASE scale is the mean absolute difference between consecutive observations before the origin, the in-sample one-step naive error; the MASE divides the MAE by it and the scaled pinball loss divides the mean pinball loss by it. When the scale is zero, the MASE and the scaled pinball losses of that origin are `nil`, are left out of every mean, and the origin is counted in `zero_scale_origins`. A mean or proportion with nothing to aggregate is `nil`. A series too short for the requested horizon, origins and step raises `Foresight::InputError` stating the length it needs.

### Foresight.evaluate(collection, **options)

Backtests every series of a non-empty Array with the options of `backtest` and returns a `Foresight::EvaluationReport` that groups the results by the demand class of each complete series:

| Field | Value |
|---|---|
| `classes` | a Hash from each of `:smooth`, `:erratic`, `:intermittent` and `:lumpy` to a `Foresight::ClassSummary`, including classes with no series |
| `series` | one `Foresight::SeriesEntry` per backtested series, in input order, with `index`, `demand_class` and `backtest` |
| `excluded_series` | the number of series left out because they had no non-zero value |
| `levels` | the quantile levels |

A `Foresight::ClassSummary` holds `demand_class`, `series_count`, `excluded_origins`, `zero_scale_origins`, `held_out`, `zero_held_out` and `nonzero_held_out`; `mae`, `rmse`, `mase` and the three scaled pinball fields as means over the series of the per-series means; and `coverage` and `lead_time_coverage` pooled over the held-out observations and the origins of every series of the class. A `Foresight::InputError` for one series is reported with the index of that series in the collection.

### Foresight::Backtester

`Foresight::Backtester.new(**options)` validates the backtest options once and exposes `run(series)`, which is what `Foresight.backtest` calls, and `evaluate(collection)`, which is what `Foresight.evaluate` calls:

```ruby
backtester = Foresight::Backtester.new(horizon: 7, origins: 10, strategy: :conformal, windows: 10)
backtest = backtester.run(series)
report = backtester.evaluate([series, other_series])
```

### Foresight::EvaluationReport.aggregate(entries, horizon:, levels:)

Builds a `Foresight::EvaluationReport` from `Foresight::SeriesEntry` values (`index`, `demand_class`, `backtest`) that the caller assembled, aggregating exactly as `evaluate` does. This is how the calibration study backtests series one at a time, sets aside the series that raise `Foresight::InputError` and still reports per-class summaries. The returned report has `excluded_series` set to 0.

### Foresight::InputError

The only exception Foresight raises for an input that violates a documented precondition. It is a subclass of `StandardError` whose message names the offending option, key, value or position. Every input check runs before any model is fitted or any random number is drawn. `Foresight::VERSION` is the gem version.

### Determinism

Every random draw comes from a generator seeded with the `seed` option, 0 by default; Foresight never reads or reseeds Ruby's global random number generator. The same series, options and seed give identical output, in one process or across processes, on the same platform and Ruby version.

## Methodology

Foresight has six point forecasting methods: Naive, SeasonalNaive and SES for smooth demand, and CrostonClassic, CrostonSBA and TSB for intermittent demand, following the conventions of statsforecast 2.1.1 wherever it defines them, so that the point forecasts can be checked against an independent implementation.

The classifier computes the ADI and the CV squared of a series and assigns one of the four demand classes with the cutoffs of Syntetos, Boylan and Croston (2005), an ADI of 1.32 and a CV squared of 0.49. The automatic selector maps the class to a method with a fixed rule, SES for smooth series and CrostonSBA for erratic, intermittent and lumpy series, and reports the choice in the reason of the result.

Quantiles come from one of two strategies. The distribution strategy, the default, shapes the quantiles after the model: for the smooth models a Gaussian distribution around the point forecast, with the residual variance scaled over the horizon by the error structure of the model and censored at zero; for the intermittent models a compound distribution in which each period has demand with the occurrence probability implied by the fitted model and a size drawn from the non-zero values of the history, with exact per-step quantiles and lead-time quantiles taken from 10,000 seeded sample paths. The conformal strategy is the generic residual-based baseline that statsforecast offers for any model: it refits the model before each of K calibration windows at the end of the history, records the absolute errors and places them symmetrically around the point forecast, clamped at zero.

The backtester performs rolling-origin evaluation and reports the MAE, the RMSE, the MASE, the scaled pinball loss at each level split into its parts from zero and from non-zero outcomes, the empirical coverage of the per-step quantiles and the coverage of the lead-time quantiles.

Two kinds of validation back the library. The point forecasts of all six methods are compared with outputs that statsforecast 2.1.1 produced on committed fixture series, within 1e-9 for the five deterministic methods and 1e-5 for SES, whose smoothing parameter comes from a numerical search. The calibration study backtests both quantile strategies on seeded synthetic series whose true quantiles are known and on a subset of the Online Retail II dataset, and reports coverage, lead-time coverage and scaled pinball loss per demand class with bootstrap intervals. The reference comparison runs in the test suite from committed files, and the study results are regenerated from committed files with Ruby alone.

The full account of the methods, every modeling choice with its source and the assumptions of each strategy are in [docs/methodology.md](docs/methodology.md). The reference comparison, the study results and the commands that regenerate them are in [docs/validation.md](docs/validation.md).

## Prior work

Foresight builds on the R package smooth by Ivan Svetunkov, which implements the intermittent state-space model iETS among its exponential smoothing models, and on the published intermittent-demand literature, in particular:

- Croston, J. D. (1972). Forecasting and stock control for intermittent demands. Operational Research Quarterly, 23(3), 289-303.
- Syntetos, A. A. and Boylan, J. E. (2005). The accuracy of intermittent demand estimates. International Journal of Forecasting, 21(2), 303-314.
- Syntetos, A. A., Boylan, J. E. and Croston, J. D. (2005). On the categorization of demand patterns. Journal of the Operational Research Society, 56(5), 495-503.
- Teunter, R. H., Syntetos, A. A. and Babai, M. Z. (2011). Intermittent demand: Linking forecasting to inventory obsolescence. European Journal of Operational Research, 214(3), 606-615.
- Kolassa, S. (2016). Evaluating predictive count data distributions in retail sales forecasting. International Journal of Forecasting, 32(3), 788-803.
- Svetunkov, I. and Boylan, J. E. (2023). iETS: State space model for intermittent demand forecasting. International Journal of Production Economics, 265, 109013.

CrostonClassic, CrostonSBA and TSB follow the first, the second and the fourth of these works. The classification cutoffs come from the third. The case for distributions over point forecasts on intermittent series comes from Kolassa (2016) and from Svetunkov and Boylan (2023). iETS-style models are planned and not implemented in Foresight.

## Roadmap

Each item below is planned and not built. Nothing on this list exists in the current gem.

- The ETS family: trend, damped trend, additive and multiplicative seasonality, likelihood-based fitting and information-criterion model selection. Planned, not built.
- Theta, CrostonOptimized, ADIDA and IMAPA. Planned, not built.
- iETS-style intermittent state-space models. Planned, not built.
- Distribution-aware conformal recalibration of quantiles, the central research item of this roadmap. Planned, not built.
- Validation-driven (data-driven) model selection. Planned, not built.
- The inventory decision layer: service-level policies and simulated inventory evaluation of the achieved fill rate against the target service level. Planned, not built.
- The multi-dataset calibration benchmark. Planned, not built.
- Randomized PIT diagnostics for discrete predictive distributions. Planned, not built.
- Numo, Apache Arrow and Rover data adapters, and charting helpers. Planned, not built.

## Excluded from the prototype

ARIMA, neural and foundation models, and multivariate and hierarchical forecasting are excluded from the prototype. So are any hosted service and Windows support: the prototype targets Linux and macOS with Ruby 3.1 or newer.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
