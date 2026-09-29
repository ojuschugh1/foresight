# Methodology

This document explains how Foresight produces its forecasts and how it evaluates them: the six point forecasting methods, the demand classification and the selection rule, the two quantile strategies with their assumptions, the rolling-origin backtest and its metrics, and the defaults. The last two sections list every modeling and evaluation choice with its published source, or mark it as Foresight's own choice, and give the references. The measured results, the comparison with statsforecast and the commands that regenerate them are in [docs/validation.md](validation.md).

Notation, used throughout: a series is `x[0], ..., x[n-1]` with `n` observations, in time order; the horizon is `H` and the forecast periods are `h = 1, ..., H`; a quantile level is `q`, a probability strictly between 0 and 1; `f_h` is the point forecast for period `h`; `floor` and `ceil` round down and up to an integer; `#{...}` counts the elements of a set. A quantile at level `q` of a distribution with cumulative distribution function `F` is the smallest attainable value `y` with `F(y) >= q`. That definition is used everywhere, with no interpolation between attainable values: for a discrete demand distribution the quantile is a demand quantity that can occur, and for a finite collection of values it is one of the values.

## Why distributions, and why calibration

The point forecast that minimizes the expected absolute error is the median of the predictive distribution, and for intermittent demand that median is zero in every period in which the probability of zero demand is at least 0.5 (Kolassa 2016). A point forecast on its own therefore says nothing about how much to stock for a slow-moving product. Replenishment decisions depend on quantiles of demand (Svetunkov and Boylan 2023): the quantile at level `q` of the demand of one period, and the quantile at level `q` of the total demand over the next `H` periods, which is the number of units that covers those periods with probability `q`. Foresight reports both kinds of quantile for every method and treats the point forecast as one summary of the distribution rather than as the output.

A quantile is only useful when it is calibrated: a stock level set at the quantile for level `q` achieves the target service level `q` only when the quantiles at level `q` cover a proportion `q` of the outcomes. Calibration is not guaranteed by either strategy below, whose assumptions are simple and stated, so Foresight measures it instead of assuming it. The backtester therefore reports the coverage, the proportion of held-out observations at or below their per-period quantile, and the lead-time coverage, the proportion of origins at which the held-out total is at or below the lead-time quantile, and the calibration study in [docs/validation.md](validation.md) publishes both for every demand class and level. Methods that would correct a measured miscalibration are planned and not built.

## Point forecasting methods

Foresight has six point forecasting methods. Each is fitted on the whole history supplied to it and produces one point forecast per period of the horizon. Their initialization, default smoothing parameters and optimization bounds follow statsforecast 2.1.1 (Garza et al. 2022) wherever that version defines them, so that the point forecasts can be checked against an independent implementation; the comparison is in [docs/validation.md](validation.md). The minimum history is the smallest number of observations the method fits on; the quantile strategies add their own requirements, stated in their sections.

| Method | Initialization | Smoothing parameters and defaults | Optimization bounds | Minimum history | Point forecast for period `h` |
|---|---|---|---|---|---|
| Naive | not applicable | not applicable | not applicable | 1 | `x[n-1]` |
| SeasonalNaive | not applicable | not applicable; the season length `m` is required and is not a smoothing parameter | not applicable | `m` | `x[n - m + ((h - 1) mod m)]` |
| SES | level at `x[0]` | `alpha`, no default: chosen by the search below | `[0.01, 0.99]` | 1 | the smoothed level after `x[n-1]` |
| CrostonClassic | size level at the first size, interval level at the first interval | `alpha` for the sizes and the intervals, default 0.1 | not applicable | 1 | `z_S / z_I` |
| CrostonSBA | as CrostonClassic | `alpha`, default 0.1 | not applicable | 1 | `(1 - alpha / 2) * z_S / z_I` |
| TSB | occurrence level at the first indicator, size level at the first size | `alpha_d` for the sizes, default 0.1; `alpha_p` for the occurrence, default 0.1 | not applicable | 1 | `z_P * z_S` |

All smoothing uses one recurrence, the `ses_sse`, `ses_forecast` and `golden_section_ses` routines of statsforecast reproduced operation by operation in double precision. For values `v[0], ..., v[k-1]` and a parameter `a`, the level starts at `v[0]` and is updated as `level = a * v[i-1] + (1 - a) * level` for `i = 1, ..., k-1`, where each updated level is the one-step fitted value of `v[i]`; the forecast after the last value is `a * v[k-1] + (1 - a) * level`. A single value is returned unchanged.

SES applies the recurrence to the observations. Its `alpha` is chosen by a golden-section search for a minimum of the in-sample sum of squared one-step errors over `[0.01, 0.99]`: the search starts from the two interior points that divide the interval at the golden ratio, narrows the interval toward the point with the smaller sum, stops when the interval is narrower than 1e-12 or when the sums at the two interior points are exactly equal, and returns the midpoint of the final interval. The search is a local method: when the sum of squared errors has more than one local minimum on the search interval, it returns a local minimizer, which need not be the global one. With a single observation SES forecasts that observation.

CrostonClassic smooths two sequences with the same `alpha`: the demand sizes, which are the non-zero observations in order, and the intervals, the first of which is the one-based position of the first non-zero observation and each later one the difference between the one-based positions of consecutive non-zero observations. `z_S` and `z_I` are the smoothed size after the last size and the smoothed interval after the last interval, and the forecast is `z_S / z_I` (Croston 1972). CrostonSBA multiplies that forecast by `1 - alpha / 2`, the bias correction of Syntetos and Boylan (2005), which is 0.95 at the default `alpha` of 0.1. TSB (Teunter, Syntetos and Babai 2011) smooths the occurrence indicator of every observation, 1 for a non-zero and 0 for a zero observation, with `alpha_p`, and the sizes with `alpha_d`; `z_P` and `z_S` are the smoothed values after the last observation and after the last size, and the forecast is `z_P * z_S`. statsforecast sets no default for the two TSB parameters; Foresight uses 0.1 for both, the Croston default, so that the three intermittent methods smooth at the same rate unless the caller says otherwise. Naive, SES and the three intermittent methods forecast the same value for every period of the horizon; only SeasonalNaive varies over it. When every observation is zero, the three intermittent methods forecast 0, report an occurrence probability of 0 and have no sizes, and statsforecast forecasts 0 as well.

SeasonalNaive repeats the last `m` observations in order. With fewer than `m` observations it raises an input error that names the season length as the required number of observations; statsforecast instead fills the first `m - n` forecast positions with NaN and cycles the `n` observations after them.

Every entry point accepts series values from 0 to 10^15. The bound keeps every sum, square and quantile computed below finite in double precision and converts every accepted Integer to a Float exactly.

## Demand classification and model selection

### ADI, CV squared and the four demand classes

With `n` observations of which `k` are non-zero, the demand sizes `s_1, ..., s_k`:

```
ADI        = n / k
mean       = (s_1 + ... + s_k) / k
CV squared = ((s_1 - mean)^2 + ... + (s_k - mean)^2) / k / mean^2
```

The ADI is the average inter-demand interval: every observation counts, including the zeros before the first and after the last non-zero observation. The alternative estimator, the mean of the Croston intervals, ignores the zeros after the last non-zero observation. The CV squared is the squared coefficient of variation of the sizes, with the population variance (divided by `k`); the alternative is the sample variance. Both estimators are Foresight's own choices, listed in the choices table. Both ratios are computed exactly, in rational arithmetic on the exact observations, and compared exactly with the cutoffs of Syntetos, Boylan and Croston (2005), an ADI of 1.32 and a CV squared of 0.49:

| ADI | CV squared | Demand class |
|---|---|---|
| below 1.32 | below 0.49 | smooth |
| below 1.32 | at least 0.49 | erratic |
| at least 1.32 | below 0.49 | intermittent |
| at least 1.32 | at least 0.49 | lumpy |

A value exactly at a cutoff falls on the "at least" side, whatever the rounding of the returned values, which are the exact ratios converted to floating point. Classification needs at least one non-zero observation.

Demand is classified for two reasons. The class determines the forecasting method through the selection rule below, is reported in every result and is named in the reason whenever the method was selected automatically, so that a user can see what kind of demand a series has and why a method was chosen. And the class groups the results of evaluation reports and of the calibration study, so that accuracy and calibration are read per kind of demand rather than averaged over series that behave differently.

### Selection rule

When the caller specifies no model, Foresight classifies the complete series and applies a fixed mapping from the demand class to a method:

| Demand class | Method | Support |
|---|---|---|
| smooth | SES | Hyndman and Athanasopoulos (2021, section 8.1) recommend SES for data with no clear trend or seasonal pattern; Petropoulos and Kourentzes (2015) classify series without zero periods separately and forecast them with SES |
| erratic | CrostonSBA | Syntetos, Boylan and Croston (2005) derive the cutoffs from the theoretical mean squared errors of Croston's method and SBA and assign SBA to every class but smooth |
| intermittent | CrostonSBA | Syntetos, Boylan and Croston (2005), as above |
| lumpy | CrostonSBA | Syntetos, Boylan and Croston (2005), as above |

Automatic selection has a minimum history of one observation, and it needs at least one non-zero observation because the classifier does; a series of zeros needs an explicit model. It never selects SeasonalNaive, so it never needs a season length. The reason of the result names the class and the method and states the two ratios rounded to two decimals, for example `auto-selected croston_sba for intermittent demand (ADI 4.20, CV squared 0.25)`; when the caller specifies a model, the reason says that the caller specified it.

A note on the literature. The rule departs from Syntetos, Boylan and Croston (2005) in the smooth quadrant, to which they assign Croston's method rather than SES. Foresight assigns a smooth model to smooth demand by design, so Croston's method is not a candidate there, and SES is the supported choice. For a series without zeros every interval is 1 and Croston's forecast reduces to SES of the sizes with a fixed `alpha` of 0.1, so SES with an optimized `alpha` is the natural counterpart, and it is how Petropoulos and Kourentzes (2015) treat such series. For smooth series with some zeros, an ADI between 1 and 1.32, Syntetos, Boylan and Croston (2005) assign Croston's method to the whole quadrant, while Kostenko and Hyndman (2006), who derive the exact boundary between the regions in which Croston's method and SBA have the smaller theoretical mean squared error and approximate it by a straight line, prefer SBA when the CV squared exceeds `2 - 1.5 * ADI`, which splits that quadrant; Foresight uses SES there. The same derivation shows that the boundary is not the SBC rectangle, so near the cutoffs every rectangular rule is an approximation.

## Quantile strategies

Two strategies turn a fitted method into per-period quantiles `Q_h(q)` and a lead-time quantile `L(q)`, the quantile of the total demand over the horizon. The distribution strategy, the default, shapes the quantiles after the fitted method: Gaussian quantiles for the smooth models Naive, SeasonalNaive and SES, and compound quantiles for the intermittent models CrostonClassic, CrostonSBA and TSB. The conformal strategy is the generic residual-based baseline that statsforecast offers for any model, kept inside Foresight so that the comparison in the calibration study reproduces with the library alone. Under both strategies the point forecasts are those of the method; every quantile is a finite number of at least zero; and quantiles do not decrease with the level. Quantiles are reported at the levels 0.5, 0.8, 0.9 and 0.95 unless the caller supplies others.

### Gaussian quantiles for the smooth models

Assumptions: the predictive distribution of each period is Gaussian, centered on the point forecast and censored at zero; the residual variance is constant over time; and that variance is scaled over the horizon by the error structure of the fitted model, a random walk for Naive, a seasonal random walk for SeasonalNaive and a local level model for SES, which also fixes the covariances between the forecast errors of different periods.

The residuals are the in-sample one-step errors of the fitted model, the residual variance is their mean square, and the variance of the forecast error of period `h` is the residual variance times a per-step factor `v_h`; the variance of the summed forecast error over the horizon, covariances included, is the residual variance times a total factor `V_H`:

| Model | Residuals `e_t` | Number of residuals `r` | Per-step factor `v_h` | Total factor `V_H` |
|---|---|---|---|---|
| Naive | `x[t] - x[t-1]` for `t = 1, ..., n-1` | `n - 1` | `h` | `H (H + 1) (2H + 1) / 6` |
| SeasonalNaive | `x[t] - x[t-m]` for `t = m, ..., n-1` | `n - m` | `1 + floor((h - 1) / m)` | the sum over `s = 1, ..., min(m, H)` of `c (c + 1) (2c + 1) / 6` with `c = floor((H - s) / m) + 1` |
| SES | `x[t] - fitted[t]` for `t = 1, ..., n-1`, under the fitted `alpha` | `n - 1` | `1 + (h - 1) alpha^2` | the sum over `j = 0, ..., H-1` of `(1 + j alpha)^2` |

```
variance = (e_1^2 + ... + e_r^2) / r                       no mean subtracted
sigma    = sqrt(variance)
Q_h(q)   = max(0, f_h + z(q) * sigma * sqrt(v_h))
L(q)     = max(0, (f_1 + ... + f_H) + z(q) * sigma * sqrt(V_H))
```

`z(q)` is the standard normal quantile, computed with algorithm AS 241 (Wichura 1988), which is accurate to about 16 significant digits over the whole open interval; over the sorted levels it is made non-decreasing with a running maximum, which only absorbs a last-bit disagreement between two of the algorithm's three rational approximations where their regions meet and never moves a value by more than one unit in the last place.

The factors follow from the error structures. For the random walk, the error of period `h` is `eps_1 + ... + eps_h`, a sum of `h` innovations, so `v_h = h`; summing the errors over the horizon gives the innovation of period `j` the coefficient `H - j + 1`, so `V_H` is the sum of the squares of the integers from 1 to `H`. For the seasonal random walk, the error of period `h` sums the innovations of the periods `h, h - m, h - 2m, ...` down to the first season, so `v_h = 1 + floor((h - 1) / m)`; the periods of the horizon that share a residue `s` modulo `m` form a chain of `c` periods whose summed errors contribute `c (c + 1) (2c + 1) / 6`, and the chains are independent of each other. For the local level model behind SES, the error of period `h` is `eps_h + alpha (eps_1 + ... + eps_(h-1))`, so `v_h = 1 + (h - 1) alpha^2`, and in the sum over the horizon the innovation of period `j` has the coefficient `1 + alpha (H - j)`. The per-step factors agree with Hyndman and Athanasopoulos (2021), Table 5.2 for Naive and SeasonalNaive and Table 8.8 in section 8.7 for the ETS(A,N,N) variance behind SES; the total factors are derived here from the same error structures.

Hyndman and Athanasopoulos (2021) divide the sum of squared residuals by `T - K - M`, with `K` the number of fitted parameters and `M` the number of missing residuals. For Naive (`K = 0`, `M = 1`) and SeasonalNaive (`K = 0`, `M = m`) that equals the number of residuals, so Foresight matches them. For SES Foresight divides by the `n - 1` residuals without subtracting the one fitted parameter, which is what statsforecast 2.1.1 does in `_calculate_sigma` for the intervals of its own SES model, instead of using `K = 1`.

When the residual variance is exactly zero the formulas reduce to `Q_h(q) = max(0, f_h)` and `L(q) = max(0, f_1 + ... + f_H)` with no special case. The censoring is applied to the quantile: the quantile of a Gaussian censored at zero is the larger of zero and the uncensored quantile, and the lead-time quantile is the censored quantile of the uncensored total, so the per-period censoring is not propagated into the distribution of the total. No random number is drawn, so the seed and the number of sample paths have no effect. The minimum history is one observation more than the model's, the fewest that yield one residual: 2 for Naive and SES, and the season length plus 1 for SeasonalNaive.

### Compound quantiles for the intermittent models

Assumptions: the demand of each period of the horizon is zero with probability `1 - p`, where `p` is the occurrence probability, and otherwise a demand size drawn from the empirical size distribution, which gives equal probability to each non-zero observation of the fitted history; the periods are independent of each other; `p` is constant over the horizon; and the sizes are drawn independently of the occurrence, from the empirical size distribution alone, so that no size absent from the fitted history can occur. The model with Bernoulli occurrence and independent sizes is Croston's (1972); resampling the observed sizes follows Willemain, Smart and Schwarz (2004), without their jittering of the sizes and without their Markov model of occurrence.

The occurrence probability is derived from the fitted model:

| Model | Occurrence probability `p` |
|---|---|
| CrostonClassic | `min(1, 1 / z_I)` |
| CrostonSBA | `min(1, (1 - alpha / 2) / z_I)` |
| TSB | `z_P`, clamped to `[0, 1]` |
| any of the three, on an all-zero history | 0, with no sizes |

For CrostonClassic, `1 / z_I` is the plug-in reciprocal of the smoothed interval: Croston (1972) models occurrence as Bernoulli but proposes no predictive distribution, and by Jensen's inequality the plug-in reciprocal overstates the probability slightly. The `min` absorbs rounding, since a smoothed interval of values that are all at least 1 can round to just below 1. For TSB the smoothed occurrence indicator is the probability estimate the method defines (Teunter, Syntetos and Babai 2011). Applying the SBA factor `1 - alpha / 2` to the occurrence probability of CrostonSBA is Foresight's own extension: the published correction of Syntetos and Boylan (2005) concerns the point forecast only. The factor is the large-interval limit of the exact bias factor of that paper, so near an interval of 1 it under-states the occurrence probability, to 0.95 for a history without zeros; the formula is kept as stated, and the results for the erratic class, whose series sit at an ADI below 1.32, are read with that in mind.

The mean of the compound distribution in one period is `p * mean(sizes)`, the occurrence probability times the average of the observed sizes, while the point forecast of each intermittent method uses the smoothed size `z_S` instead. The two differ whenever the recent sizes differ from the historical average, so the point forecast of a result is not the mean of the distribution whose quantiles the result reports.

The per-period quantile is exact and involves no simulation. With the sizes sorted as `s_(1) <= ... <= s_(k)`, the cumulative distribution function at `y >= 0` is `1 - p + p * #{i : s_(i) <= y} / k`, and

```
Q(q) = 0                                          if k = 0 or q <= 1 - p
Q(q) = s_(i) with i = ceil((q - (1 - p)) * k / p)    otherwise
```

The index is computed in exact rational arithmetic, so it is exact for every level. The quantile is the same for every period of the horizon, is always zero or an observed size, and does not depend on the seed or on the number of sample paths.

The lead-time quantile comes from simulation. One generator, seeded with the seed of the operation, produces `N` sample paths, 10,000 by default; on each path and for each of the `H` periods it draws a uniform number and, when that number is below `p`, draws one of the sizes with equal probability (the occurrence draw first, then the size draw, both from the same generator). `L(q)` is the quantile at level `q` of the `N` path totals: the smallest total whose empirical cumulative distribution function is at least `q`. The same paths serve every level, which keeps the lead-time quantiles monotone in the level. Every total is zero or a sum of between one and `H` observed sizes, and `L(q)` is one of the totals.

The number of paths bounds the simulation error. By the Dvoretzky-Kiefer-Wolfowitz inequality with Massart's constant (Massart 1990), the empirical cumulative distribution function of `N` independent draws stays within `lambda / sqrt(N)` of the true one everywhere with probability at least `1 - 2 exp(-2 lambda^2)`, for every `lambda` with `lambda^2 >= ln(2) / 2`, that is, for every deviation of at least `sqrt(ln(2) / (2N))`; `lambda = 3` satisfies that condition for every `N`. Hence, with probability at least `1 - 2 exp(-18)`, about `1 - 3.0e-8`, over the sample paths of one forecast, every reported `L(q)` is a value `y` at which the probability of a total at most `y` is at least `q - 3 / sqrt(N)` and the probability of a total below `y` is at most `q + 3 / sqrt(N)`. With the default of 10,000 paths the bound `3 / sqrt(N)` is 0.03. The inequality treats the `N` totals as independent draws from the compound distribution, which the seeded generator is taken to provide.

The minimum history is the model's own, one observation. Compound quantiles are the only place where Foresight draws random numbers.

### Conformal quantiles, the baseline

The conformal strategy follows the `conformal_distribution` method of statsforecast: it measures absolute forecast errors on calibration windows at the end of the fitted history and places them symmetrically around the point forecast. With `K` windows, 2 by default, the last `K * H` observations are split into `K` consecutive windows of `H` observations. For the window `j = 0, ..., K-1`, starting at position `start = n - K * H + j * H`, the same method with the same caller options is refitted on `x[0], ..., x[start-1]`, with no reselection of the model and with every quantity it estimates from data, including the SES `alpha`, re-estimated from those observations alone; the refit's forecasts `g_1, ..., g_H` give the absolute errors `e[j][h] = |x[start + h - 1] - g_h|` for each period and the absolute total error `E[j] = |(x[start] + ... + x[start + H - 1]) - (g_1 + ... + g_H)|`. With `f` the forecasts of the method fitted on the whole history and `F = f_1 + ... + f_H`:

```
Q_h(q) = max(0, quantile at q of the 2K values f_h - e[j][h] and f_h + e[j][h] over j)
L(q)   = max(0, quantile at q of the 2K values F - E[j] and F + E[j] over j)
```

Assumptions: the absolute forecast errors of future periods follow the distribution of the absolute errors recorded on the calibration windows, and they are symmetric around the point forecast. Nothing is assumed about the shape of demand, which is why this strategy serves as the baseline: a zero-inflated series and a smooth series receive the same treatment. No random number is drawn, so the seed has no effect. The minimum history is the model's minimum plus `K * H`.

One consequence of the quantile definition is worth stating. Write `e_(1)` for the smallest of the `K` absolute errors recorded for period `h` and `E_(1)` for the smallest absolute total error. For every `K`, the quantile at level 0.5 of the `2K` symmetric values is the `K`-th smallest, `f_h - e_(1)`, the point forecast minus the smallest absolute window error, because the definition takes the smallest attainable value (with `K = 2` that is the second smallest of four values); statsforecast's linear interpolation at the same level returns the point forecast `f_h`, the mean of the `K`-th and `(K + 1)`-th values. The same holds for the lead-time quantile, `F - E_(1)`. The two strategies are therefore not compared at the same object at the 0.5 level, and the comparisons at that level in the calibration study are read with this in mind.

The differences from `conformal_distribution` in statsforecast 2.1.1:

| Aspect | statsforecast 2.1.1 | Foresight |
|---|---|---|
| Window placement | the last `K * H` observations, `K` consecutive windows, refit on everything before each window | same |
| Default and minimum windows | default 2, minimum 2 | same; the calibration study uses 10 |
| History too short | silently lowers `K` to `(n - 1) // H`, raises only when fewer than 2 windows remain | raises an input error whenever `n` is below the model's minimum history plus `K * H`; `K` is never lowered |
| Clamping | none | every quantile is at least 0 |
| Lead-time quantile | not provided | the quantile of the sum of the point forecasts plus or minus the absolute total error of each window |
| Quantile rule | each interval level `lv`, a percentage, mapped to the two quantile levels `(100 - lv) / 200` and `1 - (100 - lv) / 200`, taken with `np.quantile` and its default linear interpolation | one quantile per level, the smallest collection value whose empirical cumulative distribution function is at least `q`, no interpolation |
| Level 0.5 | linear interpolation between the `K`-th and `(K + 1)`-th of the `2K` values returns the point forecast | `f_h - e_(1)`, the point forecast minus the smallest absolute window error, for every `K`, and `F - E_(1)` for the lead-time quantile |

The calibration study uses 10 windows instead of the library default of 2. With 2 windows the collection has four values, so its 0.8, 0.9 and 0.95 quantiles are all the largest of the four and its 0.5 quantile sits below the point forecast, which would make the baseline look worse for reasons unrelated to the question the study asks. Ten windows give twenty values per period.

## Rolling-origin evaluation and metrics

The backtester performs rolling-origin evaluation (Tashman 2000). With `n` observations, a horizon `H`, `R` origins and a step `S`, equal to `H` unless the caller supplies one, the zero-based position of the first held-out observation at origin `r = 0, ..., R-1` is `t_r = n - H - S * (R - 1 - r)`, so that the last held-out window ends at the last observation and consecutive origins are `S` periods apart. At each origin the method and the quantile strategy are fitted on the observations before the origin alone, with the same options and the same seed as the caller supplied, so that the forecast at an origin is exactly what `Foresight.forecast` returns for that prefix of the series. Without a specified model, automatic selection runs at every origin on the history before it, and an origin whose history contains no non-zero observation is excluded and counted. The series must have at least `max(2, the strategy's minimum history, the model's or the selector's minimum history)` observations before the first origin, where the strategy's minimum is computed for SES when the model is selected automatically; a series that is too short raises an input error naming the required and the supplied numbers of observations.

With `x_0, ..., x_(o-1)` the history before an origin and `y_1, ..., y_H` the held-out observations, the metrics of that origin are:

```
scale             = (|x_1 - x_0| + ... + |x_(o-1) - x_(o-2)|) / (o - 1)
MAE               = (1/H) * sum over h of |y_h - f_h|
RMSE              = sqrt((1/H) * sum over h of (y_h - f_h)^2)
MASE              = MAE / scale
pinball(q, Q, y)  = q * (y - Q) if y >= Q, else (1 - q) * (Q - y)
scaled pinball(q) = ((1/H) * sum over h of pinball(q, Q_h(q), y_h)) / scale
zero part(q)      = (sum over the h with y_h = 0 of pinball(q, Q_h(q), y_h)) / H / scale
non-zero part(q)  = (sum over the h with y_h > 0 of pinball(q, Q_h(q), y_h)) / H / scale
coverage(q)       = #{h : y_h <= Q_h(q)} / H
lead-time hit(q)  = whether y_1 + ... + y_H <= L(q)
```

Each metric measures one property of the forecast:

- The MAE is the average size of the point forecast error in units of demand, and the RMSE the same with squared errors, so that large misses weigh more. Both are in the units of the series and are not comparable across series of different volume.
- The MASE (Hyndman and Koehler 2006) divides the MAE by the scale, the mean absolute change between consecutive observations of the history before the origin, which is the in-sample one-step error of the Naive forecast. It is unit-free: a MASE below 1 means that the method beat the in-sample Naive error, and MASE values can be averaged over series of different volume.
- The pinball loss (Koenker and Bassett 1978) is the scoring function of a quantile: its expectation is minimized by the true quantile at level `q`, and it charges `q` per unit for an outcome above the quantile and `1 - q` per unit for an outcome below it, so a 0.95 quantile is penalized far more for falling short of the outcome than for exceeding it. Averaged over the window and divided by the same scale as the MASE, it becomes the scaled pinball loss, which is unit-free and can be averaged over series, as in the M5 uncertainty competition (Makridakis, Spiliotis and Assimakopoulos 2022), which scaled its pinball losses by the in-sample one-step Naive error.
- The scaled pinball loss is split into the part contributed by held-out observations equal to zero and the part contributed by non-zero held-out observations, each the sum of the pinball losses over those observations divided by `H` and by the scale, so that the two parts add up to the whole up to floating-point rounding. On intermittent demand the zero part is the cost of quantiles that sit above zero in periods without demand, and the non-zero part the cost of quantiles that fall short of the demand that occurred. The numbers of zero and of non-zero held-out observations are reported next to the parts.
- The coverage is the proportion of held-out observations at or below their per-period quantile. Compared with `q`, it measures the calibration of the per-period quantiles (Gneiting, Balabdaoui and Raftery 2007). The lead-time coverage is the proportion of origins at which the held-out total is at or below the lead-time quantile, the calibration of the quantity a replenishment decision uses (Svetunkov and Boylan 2023). A tie, an outcome equal to the quantile, counts as covered, which is consistent with the quantile being the smallest value whose distribution function reaches the level and matters on discrete demand, where ties are common.

The MASE and the scaled pinball loss are divided by the scale so that series of different volume contribute comparably to a mean and so that the results of one demand class can be compared with those of another. The scale is computed over the whole history before the origin, not from the first non-zero observation as in the M5 competition, so that one scale serves both metrics, and it is the non-seasonal one-step Naive error on daily data, as in the M5 competition, which also scaled its daily series by the one-step Naive error. When the scale is zero, because the history before the origin is constant, the MASE, the scaled pinball loss and its two parts are undefined at that origin; they are reported as nil, left out of every mean, and the origin is counted.

Per series, the point metrics and the losses are means over the origins that are not excluded, leaving undefined values out; the coverage is pooled over the held-out observations of those origins, the number covered divided by the number held out, and the lead-time coverage over the origins, the number of hits divided by the number of origins. Per demand class, the point metrics and the losses are means over the series of the per-series means, with equal weight for every series; the coverages are pooled over every held-out observation and every origin of the class, from the summed counts. The report also states the number of series, of excluded origins, of origins with a zero scale, and of held-out, zero and non-zero held-out observations per class, and the number of series of the collection set aside before any backtest because they contain no non-zero observation, which no class can hold.

Two evaluation conventions are Foresight's own. The same seed is used at every origin, so that each origin reproduces with `Foresight.forecast` on its prefix; the simulation error of the lead-time quantile, a standard error of at most 0.005 in probability with 10,000 paths, is then shared across the origins of a series rather than averaging out, which is small next to the sampling error of the pooled coverages. And the calibration study, which backtests every series under both strategies, sets aside a series that raises an input error under either strategy from both, so that the two strategies are compared on the same series.

## Defaults

The table below is generated from the library's constants by `validation/render.rb`.

<!-- generated:defaults -->
| Setting | Default |
|---|---|
| sample paths (`paths`) | 10000 |
| calibration windows (`windows`) | 2 |
| seed (`seed`) | 0 |
| TSB size smoothing parameter (`alpha_d`) | 0.1 |
| TSB occurrence smoothing parameter (`alpha_p`) | 0.1 |

The operations that take a seed are `Foresight.forecast`, `Foresight.backtest`, `Foresight.evaluate` and `Foresight::Backtester.new`, all through the `seed` option.
<!-- /generated:defaults -->

The seed is used only by the compound quantiles. Any fixed value gives reproducibility; 0 is the smallest accepted seed and carries no meaning of its own, and the calibration study records its own seeds instead of relying on it.

## Modeling and evaluation choices

Every modeling and evaluation choice in the library and in the calibration study is listed here with its source. A source either cites a work of the reference list or reads "Foresight's own choice", followed by the reason in one line.

| Choice | Source |
|---|---|
| CrostonSBA occurrence probability multiplied by the SBA factor `1 - alpha / 2` | Foresight's own choice: the published correction concerns the point forecast only (Syntetos and Boylan 2005), and `1 - alpha / 2` is the large-interval limit of the exact bias factor, so near an interval of 1 it under-states the occurrence probability (0.95 for a history without zeros); the formula is kept as stated |
| CrostonClassic occurrence probability `1 / z_I`, the plug-in reciprocal of the smoothed interval | Foresight's own choice: Croston (1972) models Bernoulli occurrence but proposes no predictive distribution, and `1 / z_I` overstates the probability slightly by Jensen's inequality |
| TSB occurrence probability as the smoothed occurrence indicator | Teunter, Syntetos and Babai (2011) |
| Compound model: independent periods, one occurrence probability over the horizon, sizes independent of occurrence | Croston (1972) |
| ADI as the number of observations divided by the number of non-zero observations | Foresight's own choice: the alternative, the mean Croston interval, ignores the zeros after the last non-zero observation |
| CV squared with the population variance of the non-zero sizes | Foresight's own choice: the alternative is the sample variance |
| Sizes resampled from the observed non-zero values | Willemain, Smart and Schwarz (2004), without their jittering and Markov occurrence model |
| One set of sample paths shared by every quantile level | Foresight's own choice: keeps the lead-time quantiles monotone in the level |
| 10,000 sample paths by default | Foresight's own choice: the Dvoretzky-Kiefer-Wolfowitz bound with Massart's (1990) constant gives `3 / sqrt(N) = 0.03` |
| Gaussian predictive distribution around the point forecast, per-step variance factors | Hyndman and Athanasopoulos (2021), Table 5.2 for Naive and SeasonalNaive and Table 8.8 in section 8.7 for the ETS(A,N,N) variance behind SES |
| Variance of the horizon total, covariances included | derived in this document from the same error structures (Hyndman and Athanasopoulos 2021) |
| Gaussian lead-time quantile taken as the censored quantile of the uncensored total | Foresight's own choice: the per-period censoring is not propagated into the distribution of the total |
| Residual variance divided by the number of residuals, no mean subtracted | Hyndman and Athanasopoulos (2021) for Naive and SeasonalNaive, whose `T - K - M` with `K = 0` fitted parameters and `M = 1` or `M = m` initial values equals the number of residuals; statsforecast 2.1.1 (Garza et al. 2022) for SES, which divides by the `n - 1` residuals without subtracting the one fitted parameter (`K = 1`) that Hyndman and Athanasopoulos would subtract |
| Gaussian quantiles censored at zero | Foresight's own choice: demand is non-negative |
| SeasonalNaive raising an error for a history shorter than the season length | Foresight's own choice: statsforecast fills the leading forecast positions with NaN instead |
| Series values above 10^15 rejected | Foresight's own choice: keeps every sum, square and quantile finite in double precision, and every Integer value exact as a Float |
| Standard normal quantile | Wichura (1988) |
| Point-method conventions: initializations, interval counting, default smoothing parameter 0.1, SES search on `[0.01, 0.99]` | statsforecast 2.1.1 (Garza et al. 2022); Croston (1972); Syntetos and Boylan (2005); Hyndman and Athanasopoulos (2021) |
| TSB default smoothing parameters 0.1 and 0.1 | Foresight's own choice: statsforecast sets no default, and 0.1 matches the Croston default |
| Classification cutoffs 1.32 and 0.49 | Syntetos, Boylan and Croston (2005) |
| A value exactly at a cutoff falls in the higher class, compared without rounding | Foresight's own choice: the cutoffs are read as "at least", and exact rational comparison keeps rounding out of the decision |
| Selection rule | Syntetos, Boylan and Croston (2005); Hyndman and Athanasopoulos (2021); Petropoulos and Kourentzes (2015); Kostenko and Hyndman (2006) for the boundary note |
| Conformal baseline: windows at the end of the history, refits before each window, symmetric absolute errors, 2 windows by default | statsforecast 2.1.1 (Garza et al. 2022) |
| Conformal differences: clamping at zero, a lead-time quantile from total errors, an error instead of fewer windows | Foresight's own choice: demand is non-negative, the lead-time quantile is the quantity the study compares, and a silently lowered number of windows would hide a change of method |
| Empirical quantile without interpolation | Hyndman and Fan (1996), definition 1 |
| Default quantile levels 0.5, 0.8, 0.9 and 0.95; default seed 0 | Foresight's own choice: the median and three upper levels in the range of service levels that stock decisions target, and the smallest accepted seed |
| Rolling-origin evaluation, refitting on every earlier observation | Tashman (2000) |
| MASE and its scale | Hyndman and Koehler (2006) |
| Pinball loss scaled by the in-sample one-step Naive error | Koenker and Bassett (1978); Makridakis, Spiliotis and Assimakopoulos (2022) |
| Scale taken over the whole history before the origin, not from the first non-zero observation as in the M5 competition | Foresight's own choice: one scale for the MASE and the pinball loss |
| Non-seasonal MASE scale on daily data | Foresight's own choice, as in the M5 competition (Makridakis, Spiliotis and Assimakopoulos 2022), which also scaled daily series by the one-step Naive error |
| MASE and scaled pinball loss undefined at a zero scale and left out of means | Foresight's own choice: a constant history gives no scale to divide by |
| Pinball loss split into zero and non-zero outcomes | Foresight's own choice: shows how much of the loss comes from periods without demand |
| Coverage of the per-period and lead-time quantiles as the calibration measure | Gneiting, Balabdaoui and Raftery (2007); Svetunkov and Boylan (2023) for lead-time demand |
| Coverage counted with the outcome at most the quantile | Foresight's own choice: a tie counts as covered, consistent with the quantile being the smallest value whose distribution function reaches the level, which matters on discrete demand |
| Coverage pooled over held-out observations; point metrics and losses averaged over series with equal weights; results grouped by the class of the complete series | Foresight's own choice: pooling weights every held-out observation once, equal weights keep a high-volume series from dominating a class, and the complete series gives one class per series |
| Automatic selection repeated at every origin, origins with an all-zero history excluded, the same seed at every origin | Foresight's own choice: each origin sees only its own history and reproduces with `Foresight.forecast` on that prefix |
| A series whose backtest raises an input error under one strategy excluded from both strategies | Foresight's own choice: keeps the two strategies on the same series |
| Study horizon 7, 10 origins, step 7 | Foresight's own choice: one week of trading days, non-overlapping |
| Ten calibration windows in the study | Foresight's own choice: twenty values per period, so the upper levels are not all the largest error |
| Synthetic processes, their parameters, and 50 series of 200 observations | Foresight's own choice: one process per demand class with known quantiles, and enough series for at least 1,000 pooled held-out observations and 200 pooled origins per process |
| True quantile of the Gaussian process total taken from the uncensored Gaussian | Foresight's own choice, with the error bound stated in [docs/validation.md](validation.md) |
| Online Retail II as the only real dataset | Foresight's own choice: a public dataset of per-product transactions under an open license; the data are cited as Chen (2012) |
| Trading-calendar days, the product-code rule, dropped cancellations and non-positive quantities, copies across worksheets counted once, series starting at the first positive demand | Foresight's own choice: days without any transaction are closed days rather than days of zero demand, and only product sales count as demand |
| At least 200 trading dates, 25 series per class, ranked by hash with seed 2026 | Foresight's own choice: 200 exceeds what the backtest needs under both strategies, and the hash ranking selects without looking at any forecast |
| Bootstrap percentile intervals | Efron and Tibshirani (1993) |
| Series resampled as independent units, paired across strategies; 2,000 resamples, seed 20260926 | Foresight's own choice: the series is the unit the study samples, pairing shows how the difference varies over series, and 2,000 resamples put the bounds of a 95 percent interval at the 50th and the 1,950th of the sorted resample values |
| Reference tolerances 1e-9 and 1e-5 | Foresight's own choice, with the reasons in [docs/validation.md](validation.md) |

## References

- Chen, D. (2012). Online Retail II [Dataset]. UCI Machine Learning Repository. https://doi.org/10.24432/C5CG6D
- Croston, J. D. (1972). Forecasting and stock control for intermittent demands. Operational Research Quarterly (now the Journal of the Operational Research Society), 23(3), 289-303.
- Efron, B. and Tibshirani, R. J. (1993). An Introduction to the Bootstrap. Chapman and Hall, New York. Chapter 13, confidence intervals based on bootstrap percentiles.
- Garza, A., Mergenthaler Canseco, M., Challú, C. and Olivares, K. G. (2022). StatsForecast: Lightning fast forecasting with statistical and econometric models. PyCon Salt Lake City, Utah, US 2022. https://github.com/Nixtla/statsforecast
- Gneiting, T., Balabdaoui, F. and Raftery, A. E. (2007). Probabilistic forecasts, calibration and sharpness. Journal of the Royal Statistical Society Series B, 69(2), 243-268.
- Hyndman, R. J. and Athanasopoulos, G. (2021). Forecasting: Principles and Practice, 3rd edition. OTexts, Melbourne. Section 8.1 for simple exponential smoothing, Table 5.2 in section 5.5 for the Naive and SeasonalNaive forecast standard deviations and the `T - K - M` divisor, and Table 8.8 in section 8.7 for the ETS(A,N,N) forecast variance. https://otexts.com/fpp3/
- Hyndman, R. J. and Fan, Y. (1996). Sample quantiles in statistical packages. The American Statistician, 50(4), 361-365.
- Hyndman, R. J. and Koehler, A. B. (2006). Another look at measures of forecast accuracy. International Journal of Forecasting, 22(4), 679-688.
- Koenker, R. and Bassett, G. (1978). Regression quantiles. Econometrica, 46(1), 33-50.
- Kolassa, S. (2016). Evaluating predictive count data distributions in retail sales forecasting. International Journal of Forecasting, 32(3), 788-803.
- Kostenko, A. V. and Hyndman, R. J. (2006). A note on the categorization of demand patterns. Journal of the Operational Research Society, 57(10), 1256-1257.
- Makridakis, S., Spiliotis, E., Assimakopoulos, V., Chen, Z., Gaba, A., Tsetlin, I. and Winkler, R. L. (2022). The M5 uncertainty competition: Results, findings and conclusions. International Journal of Forecasting, 38(4), 1365-1385.
- Massart, P. (1990). The tight constant in the Dvoretzky-Kiefer-Wolfowitz inequality. The Annals of Probability, 18(3), 1269-1283. The constant 2 holds for every deviation of at least `sqrt(ln(2) / (2N))`, which `3 / sqrt(N)` is for every `N`.
- Petropoulos, F. and Kourentzes, N. (2015). Forecast combinations for intermittent demand. Journal of the Operational Research Society, 66(6), 914-924.
- Svetunkov, I. and Boylan, J. E. (2023). iETS: State space model for intermittent demand forecasting. International Journal of Production Economics, 265, 109013.
- Syntetos, A. A. and Boylan, J. E. (2005). The accuracy of intermittent demand estimates. International Journal of Forecasting, 21(2), 303-314.
- Syntetos, A. A., Boylan, J. E. and Croston, J. D. (2005). On the categorization of demand patterns. Journal of the Operational Research Society, 56(5), 495-503.
- Tashman, L. J. (2000). Out-of-sample tests of forecasting accuracy: an analysis and review. International Journal of Forecasting, 16(4), 437-450.
- Teunter, R. H., Syntetos, A. A. and Babai, M. Z. (2011). Intermittent demand: Linking forecasting to inventory obsolescence. European Journal of Operational Research, 214(3), 606-615.
- Wichura, M. J. (1988). Algorithm AS 241: The percentage points of the normal distribution. Applied Statistics, 37(3), 477-484.
- Willemain, T. R., Smart, C. N. and Schwarz, H. F. (2004). A new approach to forecasting intermittent demand for service parts inventories. International Journal of Forecasting, 20(3), 375-387.
