# XAU APEX V2

Compile-clean correction of XAU APEX V1.

## V2 correction

MetaEditor reported:

`cannot be used for static allocated array`

The cause was `ArraySetAsSeries(bars, true)` applied to a fixed-size `MqlRates bars[3]` array.

V2 removes that call. The fixed array is intentionally used with `CopyRates()`, where `bars[1]` is the previous closed candle for the 3-bar copy used by the entry engine.

## Strategy

- XAUUSD
- M15 execution
- H1 EMA200 regime confirmation
- EMA50/EMA200 trend filter
- ADX filter
- Session VWAP
- Pullback/rejection entry
- ATR SL/TP
- Risk-based position sizing
- Break-even, profit lock and ATR trailing
- Daily loss and equity drawdown protection
- Consecutive-loss cooldown
- Spread/session/Friday filters
- No grid
- No martingale
- No averaging down

## Validation

Compile in MetaEditor first. Then run Strategy Tester using real ticks and realistic spread/commission before any live deployment.
