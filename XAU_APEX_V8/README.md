# XAU APEX V8.1

## Objective
V8.1 is a regime-adaptive XAUUSD/Gold EA designed to avoid dependence on one trading concept. It combines three independent entry engines and a shared risk/execution layer.

## Engines
1. Trend / Pullback — H1 EMA regime + ADX/DI direction + M15 EMA pullback/rejection + VWAP alignment + anti-chase filter.
2. Volatility Breakout — rolling M15 range breakout + ATR buffer + tick-volume confirmation + anti-exhaustion/anti-chase filter.
3. Range Mean Reversion — deliberately restricted to low-ADX conditions; uses VWAP distance + RSI extreme + reversal confirmation.

The engines are mutually regime-aware: mean reversion is restricted to low-ADX conditions, while breakout can initiate a new directional move when the H1 regime is not yet fully confirmed.

## Risk architecture
- ATR-normalized initial SL.
- Risk calculated with OrderCalcProfit() rather than assuming a fixed XAU contract value.
- Risk is reduced in unusually high volatility and adjusted by engine type and signal quality.
- Daily loss cap, equity drawdown cap, trade-count cap and consecutive-loss cooldown.
- One-position mode by default.
- Break-even, profit lock and ATR trailing based on initial risk R.
- Time-stop for trades that remain stagnant.

## Anti-overfitting controls
- No machine-learning model.
- No large indicator stack.
- No grid/martingale.
- No averaging down.
- No future-bar access in signal generation; entries use closed bars.
- Breakout lookback and ATR distances are structural rather than highly optimized.
- Live economic-calendar filter is optional and disabled by default because built-in MQL5 calendar data is not reliably reproducible in ordinary Strategy Tester runs.

## Research basis
The design deliberately goes beyond one EMA concept. Published research supports trend/momentum in commodity futures, volatility-aware risk control, and intraday return predictability in gold/commodity markets. At the same time, gold intraday research also shows that apparent technical edges can disappear after transaction costs and data-snooping controls. Therefore V8.1 must be validated out-of-sample rather than optimized against one backtest.

## Required validation
Do not call V8.1 profitable until it passes all of these:

### Test A — In-sample discovery
- XAUUSD, M15 entry / H1 regime.
- Every tick based on real ticks.
- At least 3 years where broker history permits.
- Realistic spread, commission and swap.

### Test B — Out-of-sample
- Chronological holdout of the latest 20–30% of data.
- Parameters frozen before the holdout run.

### Test C — Stress
Run the frozen EA with spread x1.5 and x2.0, execution/slippage stress, different broker XAU symbols where available, walk-forward windows, and Monte Carlo trade-order reshuffling.

### Minimum acceptance gates
Targets, not promises:
- Profit Factor >= 1.20 out-of-sample.
- Positive expectancy after costs.
- Max equity DD <= 10% at baseline risk.
- No single month responsible for most of total profit.
- No single engine responsible for nearly all profits.
- No parameter cliff where a one-step change destroys performance.

## Important
No EA can honestly be guaranteed to be the most profitable ever. The correct proof is repeatable out-of-sample performance after costs and execution stress. V8.1 is built to make that test meaningful instead of curve-fitting a single report.
