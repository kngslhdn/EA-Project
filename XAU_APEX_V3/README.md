# XAU APEX V3

Adaptive XAUUSD trend engine for MT5.

## Why V3 exists

V2 could compile cleanly but the entry confluence was too restrictive for practical testing. V3 adds two independent entry paths:

1. **EMA50 pullback/reclaim**
2. **Momentum continuation breakout**

The regime still requires M15 EMA50/EMA200 alignment, EMA slope, H1 EMA200 confirmation and ATR sanity. ADX minimum is reduced to 18 by default and the VWAP filter is optional/off by default so the strategy can generate a statistically useful sample.

## Risk

- 0.50% equity risk per trade
- 1.50 ATR initial SL
- 2.50 ATR initial TP
- Break-even at +1R
- Profit lock at +1.5R
- ATR trailing after +1.5R
- 2% daily closed-loss limit
- 10% peak-equity drawdown guard
- 4 entries/day maximum
- 3 consecutive losses trigger 30-minute cooldown
- No grid
- No martingale
- No averaging down

## Recommended first test

Use **XAUUSDm M15**, Every Tick based on Real Ticks, with the broker's realistic spread/commission. Do not optimize yet.

Test at least **12 months**, preferably 2024-2026, before judging the strategy. The 2-day test shown during development is not statistically meaningful.

## Version policy

V1 and V2 remain untouched. V3 is a separate version and should be treated as a new baseline. Future corrections should create V4, V5, etc., rather than overwriting a tested version.
