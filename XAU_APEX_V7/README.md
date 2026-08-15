# XAU APEX V7

V7 is a research candidate derived from the positive XAU APEX V6 backtest. It focuses on improving expectancy without increasing base risk.

## Main changes from V6

- True pullback validation: the signal candle must actually touch/retest EMA20 and reject it.
- Breakout threshold increased from 0.05 ATR to 0.15 ATR by default.
- Breakout can require tick-volume confirmation.
- Pullback and breakout are explicitly classified as separate setup types.
- Asymmetric BUY/SELL regime thresholds.
- Regime quality score instead of a simple binary trend gate.
- Adaptive TP: normal trend 2.8R, strong regime 3.6R.
- Initial risk `R` is saved at entry and used for BE/lock thresholds instead of recalculating R from changing ATR.
- Existing risk controls are retained: 0.50% risk, daily loss limit, equity DD limit, trade/day limit, consecutive-loss protection, cooldown, one-position mode, spread and Friday filters.

## Important

V7 is **not claimed profitable until independently verified by MT5 Strategy Tester** using the same broker, symbol, spread model and test period as V6.

Recommended first test:

- XAUUSDm
- M15
- Every tick based on real ticks
- Same deposit and period as V6
- Default parameters unchanged

Compare PF, net profit, max equity DD, Sharpe, expected payoff, trade count, BUY/SELL expectancy, and MFE/MAE before optimizing any inputs.
