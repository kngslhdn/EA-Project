# XAU APEX V6

XAUUSD M15 systematic trend-following EA.

## Design
- H1 EMA50/EMA200 regime
- H1 ADX regime strength
- M15 EMA20/EMA50 execution trend
- Session VWAP location filter
- M15 pullback and breakout entries
- ATR-based SL/TP
- Risk-based lot sizing using OrderCalcProfit()
- Break-even, profit lock and ATR trailing
- Daily loss / equity drawdown protection
- Consecutive-loss cooldown
- Spread/session/Friday protection
- No grid
- No martingale
- No averaging down

## Baseline
Risk 0.50%, M15 entry, H1 regime, London/NY-focused session.

This version is a research baseline, not a guarantee of profitability. Validate with real-tick backtests, out-of-sample testing, walk-forward testing and forward demo before live use.
