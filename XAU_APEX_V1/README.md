# XAU APEX V1

Systematic XAUUSD trend-pullback EA for MetaTrader 5.

## Strategy

- Execution timeframe: M15
- Higher-timeframe regime: H1 EMA200
- M15 trend: EMA50 / EMA200
- Trend strength: ADX
- Location filter: session VWAP
- Entry: pullback into EMA50 + directional rejection candle
- Volatility: ATR14 minimum/maximum gate
- Stop: 1.50 x ATR
- Target: 2.50 x ATR
- Risk: 0.50% of equity per trade by default
- Break-even: +1R
- Profit lock: +1.5R, lock +0.5R
- ATR trailing: 1.20 x ATR after sufficient profit

## Risk Controls

- No grid
- No martingale
- No averaging down
- One position at a time by default
- Maximum 3 entries/day
- Daily loss guard: 2%
- Equity peak drawdown guard: 10%
- Consecutive loss guard: 3 losses
- Cooldown after loss streak
- Spread filter
- London/New York style session window via broker server hour
- Friday late-session block

## Important

This is **V1 research code**, not a claim of guaranteed profitability. The EA must be tested on the exact broker/symbol specification used for trading.

Recommended validation sequence:

1. MT5 compile with zero errors and zero warnings.
2. XAUUSD M15 tick-data backtest using realistic spread/commission.
3. Separate in-sample and out-of-sample periods.
4. Walk-forward testing.
5. Monte Carlo trade-order / spread / slippage perturbation.
6. Forward demo for at least several weeks.
7. Small live deployment before scaling.

## Baseline Parameters

| Parameter | Default |
|---|---:|
| Risk | 0.50% |
| EMA Fast | 50 |
| EMA Slow | 200 |
| HTF EMA | 200 |
| ADX Min | 23 |
| ADX Max | 55 |
| ATR Period | 14 |
| SL ATR | 1.50 |
| TP ATR | 2.50 |
| Min RR | 1.80 |
| Daily Loss | 2.00% |
| Max Equity DD | 10.00% |
| Max Trades/Day | 3 |

## Versioning Policy

Each material strategy correction should be preserved as a new version rather than silently overwriting a tested version. For this workspace, versions are stored under `XAU_APEX_V1`, `XAU_APEX_V2`, etc. When repository creation is available, each major version should additionally receive its own repository.
