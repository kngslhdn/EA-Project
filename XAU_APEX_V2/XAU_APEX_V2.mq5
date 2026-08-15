//+------------------------------------------------------------------+
//|                                                XAU_APEX_V2.mq5   |
//| XAU APEX V2 - Compile Clean Revision                             |
//|                                                                  |
//| V2 correction:                                                   |
//| - Removed ArraySetAsSeries() on static MqlRates[3] array.        |
//| - Static arrays cannot be configured as series in MQL5.          |
//| - CopyRates() indexing is preserved: bars[1] = closed bar.       |
//+------------------------------------------------------------------+
#property strict
#property version   "2.00"
#property description "XAU APEX V2 - compile-clean revision of V1"
#property description "Risk-controlled; no martingale/grid. Backtest and validate before live use."

#include <Trade/Trade.mqh>

CTrade trade;

//---------- INPUTS: GENERAL
input ENUM_TIMEFRAMES InpTimeframe          = PERIOD_M15;
input ulong           InpMagicNumber        = 26081602;
input string          InpComment            = "XAU APEX V2";
input bool            InpAllowBuy           = true;
input bool            InpAllowSell          = true;

//---------- INPUTS: TREND / REGIME
input int             InpFastEMA            = 50;
input int             InpSlowEMA            = 200;
input ENUM_TIMEFRAMES InpHTF                = PERIOD_H1;
input int             InpHTFEMA             = 200;
input int             InpADXPeriod          = 14;
input double          InpADXMin             = 23.0;
input double          InpADXMax             = 55.0;

//---------- INPUTS: VOLATILITY
input int             InpATRPeriod          = 14;
input double          InpATRMinPrice        = 1.50;
input double          InpATRMaxPrice        = 35.0;
input double          InpSL_ATR             = 1.50;
input double          InpTP_ATR             = 2.50;
input double          InpTrail_ATR          = 1.20;
input double          InpBreakEven_R        = 1.00;
input double          InpLockProfit_R       = 1.50;
input double          InpLockProfitAt_R     = 0.50;

//---------- INPUTS: RISK
input double          InpRiskPercent        = 0.50;
input double          InpMaxDailyLossPct    = 2.00;
input double          InpMaxEquityDDPct     = 10.0;
input int             InpMaxTradesPerDay    = 3;
input int             InpMaxConsecutiveLoss = 3;
input int             InpCooldownMinutes    = 120;
input double          InpMinRR              = 1.80;

//---------- INPUTS: EXECUTION / FILTERS
input double          InpMaxSpreadPrice     = 0.80;
input int             InpSlippagePoints     = 50;
input bool            InpUseVWAP            = true;
input bool            InpUseSessionFilter   = true;
input int             InpSessionStartHour   = 8;
input int             InpSessionEndHour     = 23;
input bool            InpBlockFridayLate    = true;
input int             InpFridayStopHour     = 20;
input bool            InpOnePositionOnly    = true;

//---------- GLOBAL STATE
int      hFastEMA = INVALID_HANDLE;
int      hSlowEMA = INVALID_HANDLE;
int      hADX     = INVALID_HANDLE;
int      hATR     = INVALID_HANDLE;
int      hHTFEMA  = INVALID_HANDLE;
datetime g_lastBarTime = 0;
datetime g_cooldownUntil = 0;
double   g_peakEquity = 0.0;
int      g_consecutiveLosses = 0;
int      g_dayKey = -1;

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   hFastEMA = iMA(_Symbol, InpTimeframe, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlowEMA = iMA(_Symbol, InpTimeframe, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hADX     = iADX(_Symbol, InpTimeframe, InpADXPeriod);
   hATR     = iATR(_Symbol, InpTimeframe, InpATRPeriod);
   hHTFEMA  = iMA(_Symbol, InpHTF, InpHTFEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(hFastEMA == INVALID_HANDLE || hSlowEMA == INVALID_HANDLE ||
      hADX == INVALID_HANDLE || hATR == INVALID_HANDLE || hHTFEMA == INVALID_HANDLE)
   {
      Print("XAU APEX: indicator handle initialization failed.");
      return(INIT_FAILED);
   }

   g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   ResetDailyStateIfNeeded();

   Print("XAU APEX V2 initialized on ", _Symbol, ". Attach to M15 for intended operation.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hFastEMA != INVALID_HANDLE) IndicatorRelease(hFastEMA);
   if(hSlowEMA != INVALID_HANDLE) IndicatorRelease(hSlowEMA);
   if(hADX     != INVALID_HANDLE) IndicatorRelease(hADX);
   if(hATR     != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hHTFEMA  != INVALID_HANDLE) IndicatorRelease(hHTFEMA);
}

//+------------------------------------------------------------------+
//| Main tick                                                         |
//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyStateIfNeeded();
   UpdatePeakEquity();
   ManageOpenPosition();

   if(!IsNewBar())
      return;

   if(!TradingGuardsOK())
      return;

   if(InpOnePositionOnly && CountOurPositions() > 0)
      return;

   if(CountTradesToday() >= InpMaxTradesPerDay)
      return;

   if(IsCooldownActive())
      return;

   EvaluateEntry();
}

//+------------------------------------------------------------------+
//| FUNCTION: New bar detection                                       |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t[1];
   if(CopyTime(_Symbol, InpTimeframe, 0, 1, t) != 1)
      return false;

   if(t[0] == g_lastBarTime)
      return false;

   g_lastBarTime = t[0];
   return true;
}

//+------------------------------------------------------------------+
//| FUNCTION: Read indicator buffer                                   |
//+------------------------------------------------------------------+
bool GetBufferValue(const int handle, const int buffer, const int shift, double &value)
{
   double data[1];
   if(CopyBuffer(handle, buffer, shift, 1, data) != 1)
      return false;
   value = data[0];
   return (value != EMPTY_VALUE);
}

//+------------------------------------------------------------------+
//| FUNCTION: VWAP from start of broker trading day                   |
//+------------------------------------------------------------------+
double GetSessionVWAP()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   datetime dayStart = StructToTime(dt);

   MqlRates rates[];
   int copied = CopyRates(_Symbol, InpTimeframe, dayStart, TimeCurrent(), rates);
   if(copied <= 0)
      return 0.0;

   double pv = 0.0;
   double vol = 0.0;
   for(int i = 0; i < copied; i++)
   {
      double typical = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
      double v = (double)rates[i].tick_volume;
      if(v <= 0.0) v = 1.0;
      pv += typical * v;
      vol += v;
   }
   if(vol <= 0.0)
      return 0.0;
   return pv / vol;
}

//+------------------------------------------------------------------+
//| FUNCTION: Entry engine                                            |
//+------------------------------------------------------------------+
void EvaluateEntry()
{
   double emaFast1, emaFast2, emaSlow1, emaSlow2, adx1, atr1, htfEMA1;
   if(!GetBufferValue(hFastEMA, 0, 1, emaFast1) ||
      !GetBufferValue(hFastEMA, 0, 2, emaFast2) ||
      !GetBufferValue(hSlowEMA, 0, 1, emaSlow1) ||
      !GetBufferValue(hSlowEMA, 0, 2, emaSlow2) ||
      !GetBufferValue(hADX,     0, 1, adx1) ||
      !GetBufferValue(hATR,     0, 1, atr1) ||
      !GetBufferValue(hHTFEMA,  0, 1, htfEMA1))
      return;

   if(atr1 < InpATRMinPrice || atr1 > InpATRMaxPrice)
      return;

   // IMPORTANT: bars is a static array. MQL5 does not allow
   // ArraySetAsSeries() on static arrays, which caused the V1 warning.
   // CopyRates() fills this fixed array oldest -> newest. Therefore:
   // bars[1] = previous/closed candle, bars[2] = current candle.
   MqlRates bars[3];
   if(CopyRates(_Symbol, InpTimeframe, 0, 3, bars) < 3)
      return;

   double close1 = bars[1].close;
   double open1  = bars[1].open;
   double high1  = bars[1].high;
   double low1   = bars[1].low;
   double range1 = high1 - low1;
   if(range1 <= 0.0)
      return;

   double vwap = GetSessionVWAP();
   if(InpUseVWAP && vwap <= 0.0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   bool bullishTrend = emaFast1 > emaSlow1 && close1 > emaSlow1 && close1 > htfEMA1;
   bool bullishPullback = low1 <= emaFast1 && close1 > emaFast1 && close1 > open1;
   bool bullishVWAP = !InpUseVWAP || close1 > vwap;
   bool bullishCandle = (close1 - low1) >= range1 * 0.60;

   bool bearishTrend = emaFast1 < emaSlow1 && close1 < emaSlow1 && close1 < htfEMA1;
   bool bearishPullback = high1 >= emaFast1 && close1 < emaFast1 && close1 < open1;
   bool bearishVWAP = !InpUseVWAP || close1 < vwap;
   bool bearishCandle = (high1 - close1) >= range1 * 0.60;

   if(adx1 < InpADXMin || adx1 > InpADXMax)
      return;

   if(InpAllowBuy && bullishTrend && bullishPullback && bullishVWAP && bullishCandle)
   {
      OpenPosition(ORDER_TYPE_BUY, atr1, tick.ask);
      return;
   }

   if(InpAllowSell && bearishTrend && bearishPullback && bearishVWAP && bearishCandle)
   {
      OpenPosition(ORDER_TYPE_SELL, atr1, tick.bid);
      return;
   }
}

//+------------------------------------------------------------------+
//| FUNCTION: Position sizing + order placement                       |
//+------------------------------------------------------------------+
void OpenPosition(const ENUM_ORDER_TYPE type, const double atr, const double entry)
{
   if(atr <= 0.0 || entry <= 0.0)
      return;

   double slDistance = atr * InpSL_ATR;
   double tpDistance = atr * InpTP_ATR;
   if(slDistance <= 0.0 || tpDistance / slDistance < InpMinRR)
      return;

   double sl = 0.0;
   double tp = 0.0;
   if(type == ORDER_TYPE_BUY)
   {
      sl = entry - slDistance;
      tp = entry + tpDistance;
   }
   else
   {
      sl = entry + slDistance;
      tp = entry - tpDistance;
   }

   sl = NormalizePrice(sl);
   tp = NormalizePrice(tp);

   double lots = CalculateRiskLot(entry, sl);
   if(lots <= 0.0)
      return;

   bool ok = false;
   if(type == ORDER_TYPE_BUY)
      ok = trade.Buy(lots, _Symbol, 0.0, sl, tp, InpComment);
   else
      ok = trade.Sell(lots, _Symbol, 0.0, sl, tp, InpComment);

   if(!ok)
      Print("XAU APEX order failed. Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   else
      Print("XAU APEX opened ", EnumToString(type), " lots=", DoubleToString(lots, 2),
            " SL=", DoubleToString(sl, _Digits), " TP=", DoubleToString(tp, _Digits));
}

//+------------------------------------------------------------------+
//| FUNCTION: Risk-based lot calculation                              |
//+------------------------------------------------------------------+
double CalculateRiskLot(const double entry, const double sl)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;
   if(riskMoney <= 0.0)
      return 0.0;

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0.0)
      tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return 0.0;

   double distance = MathAbs(entry - sl);
   double lossPerLot = (distance / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return 0.0;

   double rawLots = riskMoney / lossPerLot;
   return NormalizeVolume(rawLots);
}

//+------------------------------------------------------------------+
//| FUNCTION: Volume normalization                                    |
//+------------------------------------------------------------------+
double NormalizeVolume(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minLot <= 0.0 || maxLot <= 0.0 || step <= 0.0)
      return 0.0;

   lots = MathMax(minLot, MathMin(maxLot, lots));
   lots = MathFloor(lots / step) * step;

   int digits = 2;
   if(step < 0.01) digits = 3;
   if(step < 0.001) digits = 4;
   return NormalizeDouble(lots, digits);
}

//+------------------------------------------------------------------+
//| FUNCTION: Open-position management                                |
//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   if(!PositionSelect(_Symbol))
      return;

   long magic = PositionGetInteger(POSITION_MAGIC);
   if((ulong)magic != InpMagicNumber)
      return;

   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   double volume    = PositionGetDouble(POSITION_VOLUME);
   if(volume <= 0.0)
      return;

   double atr;
   if(!GetBufferValue(hATR, 0, 1, atr) || atr <= 0.0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double price = (type == POSITION_TYPE_BUY ? tick.bid : tick.ask);
   double initialRisk = MathAbs(openPrice - currentTP) * (InpSL_ATR / InpTP_ATR);
   if(initialRisk <= 0.0)
      initialRisk = atr * InpSL_ATR;

   double profitDistance = (type == POSITION_TYPE_BUY ? price - openPrice : openPrice - price);
   if(profitDistance <= 0.0)
      return;

   double newSL = currentSL;
   bool modify = false;

   if(profitDistance >= initialRisk * InpBreakEven_R)
   {
      double be = NormalizePrice(openPrice);
      if(type == POSITION_TYPE_BUY)
      {
         if(currentSL < be || currentSL == 0.0)
         {
            newSL = be;
            modify = true;
         }
      }
      else
      {
         if(currentSL > be || currentSL == 0.0)
         {
            newSL = be;
            modify = true;
         }
      }
   }

   if(profitDistance >= initialRisk * InpLockProfit_R)
   {
      double lock = (type == POSITION_TYPE_BUY)
                    ? openPrice + initialRisk * InpLockProfitAt_R
                    : openPrice - initialRisk * InpLockProfitAt_R;
      lock = NormalizePrice(lock);

      if(type == POSITION_TYPE_BUY)
      {
         if(newSL < lock || newSL == 0.0)
         {
            newSL = lock;
            modify = true;
         }
      }
      else
      {
         if(newSL > lock || newSL == 0.0)
         {
            newSL = lock;
            modify = true;
         }
      }
   }

   if(profitDistance >= initialRisk * 1.50)
   {
      double trail = (type == POSITION_TYPE_BUY)
                     ? price - atr * InpTrail_ATR
                     : price + atr * InpTrail_ATR;
      trail = NormalizePrice(trail);

      if(type == POSITION_TYPE_BUY)
      {
         if(trail > newSL && trail < price)
         {
            newSL = trail;
            modify = true;
         }
      }
      else
      {
         if((newSL == 0.0 || trail < newSL) && trail > price)
         {
            newSL = trail;
            modify = true;
         }
      }
   }

   if(!modify || !IsValidStopLevel(type, newSL, price))
      return;

   if(MathAbs(newSL - currentSL) < _Point)
      return;

   if(!trade.PositionModify(_Symbol, newSL, currentTP))
      Print("XAU APEX modify failed. Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| FUNCTION: Stop-level validation                                   |
//+------------------------------------------------------------------+
bool IsValidStopLevel(const ENUM_POSITION_TYPE type, const double sl, const double price)
{
   int stops = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = stops * _Point;
   if(minDistance <= 0.0)
      return true;

   if(type == POSITION_TYPE_BUY)
      return (price - sl) >= minDistance;
   return (sl - price) >= minDistance;
}

//+------------------------------------------------------------------+
//| FUNCTION: Trading guards                                          |
//+------------------------------------------------------------------+
bool TradingGuardsOK()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double spread = tick.ask - tick.bid;
   if(spread > InpMaxSpreadPrice)
      return false;

   if(InpUseSessionFilter)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.hour < InpSessionStartHour || dt.hour >= InpSessionEndHour)
         return false;

      if(InpBlockFridayLate && dt.day_of_week == 5 && dt.hour >= InpFridayStopHour)
         return false;
   }

   if(DailyLossExceeded())
      return false;

   if(EquityDDExceeded())
      return false;

   if(g_consecutiveLosses >= InpMaxConsecutiveLoss)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| FUNCTION: Count our positions                                     |
//+------------------------------------------------------------------+
int CountOurPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| FUNCTION: Trades today                                            |
//+------------------------------------------------------------------+
int CountTradesToday()
{
   datetime from, to;
   GetDayRange(from, to);
   if(!HistorySelect(from, to))
      return 0;

   int count = 0;
   uint total = HistoryDealsTotal();
   for(uint i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagicNumber) continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| FUNCTION: Daily closed PnL                                        |
//+------------------------------------------------------------------+
double GetTodayClosedPnL()
{
   datetime from, to;
   GetDayRange(from, to);
   if(!HistorySelect(from, to))
      return 0.0;

   double pnl = 0.0;
   uint total = HistoryDealsTotal();
   for(uint i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagicNumber) continue;

      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue;

      pnl += HistoryDealGetDouble(ticket, DEAL_PROFIT);
      pnl += HistoryDealGetDouble(ticket, DEAL_SWAP);
      pnl += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }
   return pnl;
}

//+------------------------------------------------------------------+
//| FUNCTION: Daily loss guard                                        |
//+------------------------------------------------------------------+
bool DailyLossExceeded()
{
   if(InpMaxDailyLossPct <= 0.0)
      return false;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double pnl = GetTodayClosedPnL();
   if(balance <= 0.0)
      return false;

   double lossPct = (-pnl / balance) * 100.0;
   return (lossPct >= InpMaxDailyLossPct);
}

//+------------------------------------------------------------------+
//| FUNCTION: Equity peak / max DD guard                              |
//+------------------------------------------------------------------+
void UpdatePeakEquity()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_peakEquity)
      g_peakEquity = equity;
}

bool EquityDDExceeded()
{
   if(InpMaxEquityDDPct <= 0.0 || g_peakEquity <= 0.0)
      return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct = (g_peakEquity - equity) / g_peakEquity * 100.0;
   return (ddPct >= InpMaxEquityDDPct);
}

//+------------------------------------------------------------------+
//| FUNCTION: Daily state reset                                       |
//+------------------------------------------------------------------+
void ResetDailyStateIfNeeded()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int key = dt.year * 10000 + dt.mon * 100 + dt.day;

   if(key == g_dayKey)
      return;

   g_dayKey = key;
   g_consecutiveLosses = 0;
}

//+------------------------------------------------------------------+
//| FUNCTION: Cooldown                                                |
//+------------------------------------------------------------------+
bool IsCooldownActive()
{
   return (g_cooldownUntil > 0 && TimeCurrent() < g_cooldownUntil);
}

//+------------------------------------------------------------------+
//| FUNCTION: Trade transaction                                       |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong deal = trans.deal;
   if(deal == 0) return;
   if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) return;
   if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber) return;

   long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;

   double pnl = HistoryDealGetDouble(deal, DEAL_PROFIT)
              + HistoryDealGetDouble(deal, DEAL_SWAP)
              + HistoryDealGetDouble(deal, DEAL_COMMISSION);

   if(pnl < 0.0)
   {
      g_consecutiveLosses++;
      if(g_consecutiveLosses >= InpMaxConsecutiveLoss)
         g_cooldownUntil = TimeCurrent() + InpCooldownMinutes * 60;
   }
   else if(pnl > 0.0)
   {
      g_consecutiveLosses = 0;
   }
}

//+------------------------------------------------------------------+
//| FUNCTION: Day range                                               |
//+------------------------------------------------------------------+
void GetDayRange(datetime &from, datetime &to)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   from = StructToTime(dt);
   to = TimeCurrent();
}

//+------------------------------------------------------------------+
//| FUNCTION: Price normalization                                     |
//+------------------------------------------------------------------+
double NormalizePrice(const double price)
{
   return NormalizeDouble(price, _Digits);
}
//+------------------------------------------------------------------+
