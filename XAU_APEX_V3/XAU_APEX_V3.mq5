//+------------------------------------------------------------------+
//| XAU_APEX_V3.mq5                                                  |
//| XAU APEX V3 - Adaptive Trend / Pullback / Momentum Engine        |
//+------------------------------------------------------------------+
#property strict
#property version   "3.00"
#property description "XAU APEX V3 - less restrictive, robust XAU trend engine"
#property description "No grid, no martingale, ATR risk management. Backtest before live use."

#include <Trade/Trade.mqh>
CTrade trade;

//---------- GENERAL
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M15;
input ulong InpMagicNumber = 26081603;
input string InpComment = "XAU APEX V3";
input bool InpAllowBuy = true;
input bool InpAllowSell = true;

//---------- TREND / REGIME
input int InpFastEMA = 50;
input int InpSlowEMA = 200;
input ENUM_TIMEFRAMES InpHTF = PERIOD_H1;
input int InpHTFEMA = 200;
input int InpADXPeriod = 14;
input double InpADXMin = 18.0;
input bool InpRequireADX = true;

//---------- VOLATILITY / ENTRY
input int InpATRPeriod = 14;
input double InpATRMinPrice = 1.00;
input double InpATRMaxPrice = 40.0;
input double InpPullbackATR = 0.45;
input double InpSL_ATR = 1.50;
input double InpTP_ATR = 2.50;
input double InpTrail_ATR = 1.20;
input double InpBreakEven_R = 1.00;
input double InpLockProfit_R = 1.50;
input double InpLockProfitAt_R = 0.50;
input bool InpUseVWAP = false;

//---------- RISK
input double InpRiskPercent = 0.50;
input double InpMaxDailyLossPct = 2.00;
input double InpMaxEquityDDPct = 10.0;
input int InpMaxTradesPerDay = 4;
input int InpMaxConsecutiveLoss = 3;
input int InpCooldownMinutes = 30;
input double InpMinRR = 1.80;

//---------- EXECUTION / SESSION
input double InpMaxSpreadPrice = 1.00;
input int InpSlippagePoints = 50;
input bool InpUseSessionFilter = true;
input int InpSessionStartHour = 7;
input int InpSessionEndHour = 23;
input bool InpBlockFridayLate = true;
input int InpFridayStopHour = 19;
input bool InpOnePositionOnly = true;

//---------- HANDLES / STATE
int hFastEMA = INVALID_HANDLE;
int hSlowEMA = INVALID_HANDLE;
int hADX = INVALID_HANDLE;
int hATR = INVALID_HANDLE;
int hHTFEMA = INVALID_HANDLE;
datetime g_lastBarTime = 0;
datetime g_cooldownUntil = 0;
double g_peakEquity = 0.0;
int g_consecutiveLosses = 0;
int g_dayKey = -1;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   hFastEMA = iMA(_Symbol, InpTimeframe, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlowEMA = iMA(_Symbol, InpTimeframe, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hADX = iADX(_Symbol, InpTimeframe, InpADXPeriod);
   hATR = iATR(_Symbol, InpTimeframe, InpATRPeriod);
   hHTFEMA = iMA(_Symbol, InpHTF, InpHTFEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(hFastEMA == INVALID_HANDLE || hSlowEMA == INVALID_HANDLE ||
      hADX == INVALID_HANDLE || hATR == INVALID_HANDLE || hHTFEMA == INVALID_HANDLE)
   {
      Print("XAU APEX V3: indicator initialization failed.");
      return INIT_FAILED;
   }

   g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   ResetDailyStateIfNeeded();
   Print("XAU APEX V3 initialized: ", _Symbol, " / ", EnumToString(InpTimeframe));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hFastEMA != INVALID_HANDLE) IndicatorRelease(hFastEMA);
   if(hSlowEMA != INVALID_HANDLE) IndicatorRelease(hSlowEMA);
   if(hADX != INVALID_HANDLE) IndicatorRelease(hADX);
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hHTFEMA != INVALID_HANDLE) IndicatorRelease(hHTFEMA);
}

//+------------------------------------------------------------------+
//| Main tick                                                         |
//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyStateIfNeeded();
   UpdatePeakEquity();
   ManageOpenPosition();

   if(!IsNewBar()) return;
   if(!TradingGuardsOK()) return;
   if(InpOnePositionOnly && CountOurPositions() > 0) return;
   if(CountTradesToday() >= InpMaxTradesPerDay) return;
   if(IsCooldownActive()) return;

   EvaluateEntry();
}

//+------------------------------------------------------------------+
//| FUNCTION: New bar                                                 |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t[1];
   if(CopyTime(_Symbol, InpTimeframe, 0, 1, t) != 1) return false;
   if(t[0] == g_lastBarTime) return false;
   g_lastBarTime = t[0];
   return true;
}

//+------------------------------------------------------------------+
//| FUNCTION: Indicator value                                        |
//+------------------------------------------------------------------+
bool GetBufferValue(const int handle,const int buffer,const int shift,double &value)
{
   double data[1];
   if(CopyBuffer(handle,buffer,shift,1,data) != 1) return false;
   value = data[0];
   return value != EMPTY_VALUE;
}

//+------------------------------------------------------------------+
//| FUNCTION: Session VWAP                                            |
//+------------------------------------------------------------------+
double GetSessionVWAP()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   datetime dayStart=StructToTime(dt);

   MqlRates rates[];
   int copied=CopyRates(_Symbol,InpTimeframe,dayStart,TimeCurrent(),rates);
   if(copied<=0) return 0.0;

   double pv=0.0,vol=0.0;
   for(int i=0;i<copied;i++)
   {
      double typical=(rates[i].high+rates[i].low+rates[i].close)/3.0;
      double v=(double)rates[i].tick_volume;
      if(v<=0.0) v=1.0;
      pv+=typical*v;
      vol+=v;
   }
   return vol>0.0 ? pv/vol : 0.0;
}

//+------------------------------------------------------------------+
//| FUNCTION: Entry engine                                            |
//+------------------------------------------------------------------+
void EvaluateEntry()
{
   double ema1,ema2,slow1,slow2,adx,atr,htfEma;
   if(!GetBufferValue(hFastEMA,0,1,ema1) || !GetBufferValue(hFastEMA,0,2,ema2) ||
      !GetBufferValue(hSlowEMA,0,1,slow1) || !GetBufferValue(hSlowEMA,0,2,slow2) ||
      !GetBufferValue(hADX,0,1,adx) || !GetBufferValue(hATR,0,1,atr) ||
      !GetBufferValue(hHTFEMA,0,1,htfEma)) return;

   if(atr<InpATRMinPrice || atr>InpATRMaxPrice) return;
   if(InpRequireADX && adx<InpADXMin) return;

   // Dynamic array is intentionally used here so series indexing is valid.
   MqlRates bars[];
   ArraySetAsSeries(bars,true);
   if(CopyRates(_Symbol,InpTimeframe,0,5,bars)<5) return;

   // bars[1] is the last CLOSED candle; bars[2] is the candle before it.
   double c1=bars[1].close, o1=bars[1].open, h1=bars[1].high, l1=bars[1].low;
   double c2=bars[2].close, h2=bars[2].high, l2=bars[2].low;
   double range1=h1-l1;
   if(range1<=0.0) return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;

   double vwap=GetSessionVWAP();
   bool buyVWAP=!InpUseVWAP || (vwap>0.0 && c1>vwap);
   bool sellVWAP=!InpUseVWAP || (vwap>0.0 && c1<vwap);

   // Regime: EMA slope + price location + H1 confirmation.
   bool buyTrend=(ema1>slow1 && ema1>=ema2 && slow1>=slow2 && c1>ema1 && c1>htfEma);
   bool sellTrend=(ema1<slow1 && ema1<=ema2 && slow1<=slow2 && c1<ema1 && c1<htfEma);

   // Setup A: pullback/reclaim of EMA50.
   double distLow=MathAbs(l1-ema1);
   double distHigh=MathAbs(h1-ema1);
   bool buyPullback=(l1<=ema1+atr*InpPullbackATR && c1>ema1 && c1>o1 && (c1-l1)>=range1*0.55);
   bool sellPullback=(h1>=ema1-atr*InpPullbackATR && c1<ema1 && c1<o1 && (h1-c1)>=range1*0.55);

   // Setup B: momentum continuation after a controlled breakout.
   bool buyMomentum=(c1>h2 && c1>o1 && (c1-l1)>=range1*0.65 && c1>ema1);
   bool sellMomentum=(c1<l2 && c1<o1 && (h1-c1)>=range1*0.65 && c1<ema1);

   // Avoid entries after an extreme candle that is already > 2 ATR.
   bool notExhausted=(range1<=atr*2.0);

   if(InpAllowBuy && buyTrend && buyVWAP && notExhausted && (buyPullback || buyMomentum))
   {
      OpenPosition(ORDER_TYPE_BUY,atr,tick.ask);
      return;
   }

   if(InpAllowSell && sellTrend && sellVWAP && notExhausted && (sellPullback || sellMomentum))
   {
      OpenPosition(ORDER_TYPE_SELL,atr,tick.bid);
      return;
   }
}

//+------------------------------------------------------------------+
//| FUNCTION: Open position                                           |
//+------------------------------------------------------------------+
void OpenPosition(const ENUM_ORDER_TYPE type,const double atr,const double entry)
{
   if(atr<=0.0 || entry<=0.0) return;

   double slDist=atr*InpSL_ATR;
   double tpDist=atr*InpTP_ATR;
   if(slDist<=0.0 || tpDist/slDist<InpMinRR) return;

   double sl,tp;
   if(type==ORDER_TYPE_BUY)
   {
      sl=entry-slDist;
      tp=entry+tpDist;
   }
   else
   {
      sl=entry+slDist;
      tp=entry-tpDist;
   }

   sl=NormalizePrice(sl); tp=NormalizePrice(tp);
   if(!IsInitialStopValid(type,sl,entry)) return;

   double lots=CalculateRiskLot(type,entry,sl);
   if(lots<=0.0) return;

   bool ok=(type==ORDER_TYPE_BUY)
           ? trade.Buy(lots,_Symbol,0.0,sl,tp,InpComment)
           : trade.Sell(lots,_Symbol,0.0,sl,tp,InpComment);

   if(!ok)
      Print("XAU APEX V3 order failed: ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
   else
      Print("XAU APEX V3 OPEN ",EnumToString(type)," lot=",DoubleToString(lots,2),
            " SL=",DoubleToString(sl,_Digits)," TP=",DoubleToString(tp,_Digits));
}

//+------------------------------------------------------------------+
//| FUNCTION: Risk lot using OrderCalcProfit                           |
//+------------------------------------------------------------------+
double CalculateRiskLot(const ENUM_ORDER_TYPE type,const double entry,const double sl)
{
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney=equity*InpRiskPercent/100.0;
   if(riskMoney<=0.0) return 0.0;

   double oneLotProfit=0.0;
   if(!OrderCalcProfit(type,_Symbol,1.0,entry,sl,oneLotProfit)) return 0.0;
   double lossPerLot=MathAbs(oneLotProfit);
   if(lossPerLot<=0.0) return 0.0;

   double raw=riskMoney/lossPerLot;
   return NormalizeVolume(raw);
}

//+------------------------------------------------------------------+
//| FUNCTION: Volume normalization                                    |
//+------------------------------------------------------------------+
double NormalizeVolume(double lots)
{
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(minLot<=0.0 || maxLot<=0.0 || step<=0.0) return 0.0;

   // Do not silently exceed requested risk when calculated size is below minimum.
   if(lots<minLot) return 0.0;
   lots=MathMin(maxLot,lots);
   lots=MathFloor(lots/step)*step;
   if(lots<minLot) return 0.0;

   int digits=2;
   if(step<0.01) digits=3;
   if(step<0.001) digits=4;
   return NormalizeDouble(lots,digits);
}

//+------------------------------------------------------------------+
//| FUNCTION: Position management                                     |
//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   if(!PositionSelect(_Symbol)) return;
   if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) return;

   ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL=PositionGetDouble(POSITION_SL);
   double currentTP=PositionGetDouble(POSITION_TP);
   double volume=PositionGetDouble(POSITION_VOLUME);
   if(volume<=0.0) return;

   double atr;
   if(!GetBufferValue(hATR,0,1,atr) || atr<=0.0) return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;
   double price=(type==POSITION_TYPE_BUY ? tick.bid : tick.ask);

   double initialRisk=0.0;
   if(currentTP>0.0 && InpTP_ATR>0.0)
      initialRisk=MathAbs(currentTP-openPrice)*(InpSL_ATR/InpTP_ATR);
   if(initialRisk<=0.0) initialRisk=atr*InpSL_ATR;

   double profitDist=(type==POSITION_TYPE_BUY ? price-openPrice : openPrice-price);
   if(profitDist<=0.0) return;

   double newSL=currentSL;
   bool modify=false;

   if(profitDist>=initialRisk*InpBreakEven_R)
   {
      double be=NormalizePrice(openPrice);
      if(type==POSITION_TYPE_BUY && (currentSL==0.0 || currentSL<be)) {newSL=be;modify=true;}
      if(type==POSITION_TYPE_SELL && (currentSL==0.0 || currentSL>be)) {newSL=be;modify=true;}
   }

   if(profitDist>=initialRisk*InpLockProfit_R)
   {
      double lock=(type==POSITION_TYPE_BUY)
                  ? openPrice+initialRisk*InpLockProfitAt_R
                  : openPrice-initialRisk*InpLockProfitAt_R;
      lock=NormalizePrice(lock);
      if(type==POSITION_TYPE_BUY && (newSL==0.0 || newSL<lock)) {newSL=lock;modify=true;}
      if(type==POSITION_TYPE_SELL && (newSL==0.0 || newSL>lock)) {newSL=lock;modify=true;}
   }

   if(profitDist>=initialRisk*1.50)
   {
      double trail=(type==POSITION_TYPE_BUY)
                   ? price-atr*InpTrail_ATR
                   : price+atr*InpTrail_ATR;
      trail=NormalizePrice(trail);
      if(type==POSITION_TYPE_BUY && trail<price && (newSL==0.0 || trail>newSL)) {newSL=trail;modify=true;}
      if(type==POSITION_TYPE_SELL && trail>price && (newSL==0.0 || trail<newSL)) {newSL=trail;modify=true;}
   }

   if(!modify || !IsValidStopLevel(type,newSL,price)) return;
   if(currentSL!=0.0 && MathAbs(newSL-currentSL)<_Point) return;

   if(!trade.PositionModify(_Symbol,newSL,currentTP))
      Print("XAU APEX V3 modify failed: ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| FUNCTION: Initial stop validation                                 |
//+------------------------------------------------------------------+
bool IsInitialStopValid(const ENUM_ORDER_TYPE type,const double sl,const double price)
{
   int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minDist=stops*_Point;
   if(minDist<=0.0) return true;
   if(type==ORDER_TYPE_BUY) return price-sl>=minDist;
   return sl-price>=minDist;
}

//+------------------------------------------------------------------+
//| FUNCTION: Stop validation                                          |
//+------------------------------------------------------------------+
bool IsValidStopLevel(const ENUM_POSITION_TYPE type,const double sl,const double price)
{
   int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minDist=stops*_Point;
   if(minDist<=0.0) return true;
   if(type==POSITION_TYPE_BUY) return price-sl>=minDist;
   return sl-price>=minDist;
}

//+------------------------------------------------------------------+
//| FUNCTION: Guards                                                   |
//+------------------------------------------------------------------+
bool TradingGuardsOK()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return false;
   if((tick.ask-tick.bid)>InpMaxSpreadPrice) return false;

   if(InpUseSessionFilter)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(),dt);
      if(dt.hour<InpSessionStartHour || dt.hour>=InpSessionEndHour) return false;
      if(InpBlockFridayLate && dt.day_of_week==5 && dt.hour>=InpFridayStopHour) return false;
   }

   if(DailyLossExceeded()) return false;
   if(EquityDDExceeded()) return false;
   if(g_consecutiveLosses>=InpMaxConsecutiveLoss) return false;
   return true;
}

//+------------------------------------------------------------------+
//| FUNCTION: Count positions                                         |
//+------------------------------------------------------------------+
int CountOurPositions()
{
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| FUNCTION: Trades today                                            |
//+------------------------------------------------------------------+
int CountTradesToday()
{
   datetime from,to; GetDayRange(from,to);
   if(!HistorySelect(from,to)) return 0;
   int count=0;
   uint total=HistoryDealsTotal();
   for(uint i=0;i<total;i++)
   {
      ulong ticket=HistoryDealGetTicket(i);
      if(ticket==0) continue;
      if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol) continue;
      if((ulong)HistoryDealGetInteger(ticket,DEAL_MAGIC)!=InpMagicNumber) continue;
      long entry=HistoryDealGetInteger(ticket,DEAL_ENTRY);
      if(entry==DEAL_ENTRY_IN) count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| FUNCTION: Today's closed PnL                                     |
//+------------------------------------------------------------------+
double GetTodayClosedPnL()
{
   datetime from,to; GetDayRange(from,to);
   if(!HistorySelect(from,to)) return 0.0;
   double pnl=0.0;
   uint total=HistoryDealsTotal();
   for(uint i=0;i<total;i++)
   {
      ulong ticket=HistoryDealGetTicket(i);
      if(ticket==0) continue;
      if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol) continue;
      if((ulong)HistoryDealGetInteger(ticket,DEAL_MAGIC)!=InpMagicNumber) continue;
      long entry=HistoryDealGetInteger(ticket,DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY) continue;
      pnl+=HistoryDealGetDouble(ticket,DEAL_PROFIT);
      pnl+=HistoryDealGetDouble(ticket,DEAL_SWAP);
      pnl+=HistoryDealGetDouble(ticket,DEAL_COMMISSION);
   }
   return pnl;
}

//+------------------------------------------------------------------+
//| FUNCTION: Daily loss                                               |
//+------------------------------------------------------------------+
bool DailyLossExceeded()
{
   if(InpMaxDailyLossPct<=0.0) return false;
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance<=0.0) return false;
   return ((-GetTodayClosedPnL()/balance)*100.0)>=InpMaxDailyLossPct;
}

//+------------------------------------------------------------------+
//| FUNCTION: Equity DD                                                |
//+------------------------------------------------------------------+
void UpdatePeakEquity()
{
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity>g_peakEquity) g_peakEquity=equity;
}

bool EquityDDExceeded()
{
   if(InpMaxEquityDDPct<=0.0 || g_peakEquity<=0.0) return false;
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   return ((g_peakEquity-equity)/g_peakEquity*100.0)>=InpMaxEquityDDPct;
}

//+------------------------------------------------------------------+
//| FUNCTION: Daily reset                                             |
//+------------------------------------------------------------------+
void ResetDailyStateIfNeeded()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   int key=dt.year*10000+dt.mon*100+dt.day;
   if(key==g_dayKey) return;
   g_dayKey=key;
   g_consecutiveLosses=0;
}

//+------------------------------------------------------------------+
//| FUNCTION: Cooldown                                                 |
//+------------------------------------------------------------------+
bool IsCooldownActive()
{
   return g_cooldownUntil>0 && TimeCurrent()<g_cooldownUntil;
}

//+------------------------------------------------------------------+
//| FUNCTION: Deal result tracking                                     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   ulong deal=trans.deal;
   if(deal==0) return;
   if(HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol) return;
   if((ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagicNumber) return;

   long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
   if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY) return;

   double pnl=HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_SWAP)+HistoryDealGetDouble(deal,DEAL_COMMISSION);
   if(pnl<0.0)
   {
      g_consecutiveLosses++;
      if(g_consecutiveLosses>=InpMaxConsecutiveLoss)
         g_cooldownUntil=TimeCurrent()+InpCooldownMinutes*60;
   }
   else if(pnl>0.0)
   {
      g_consecutiveLosses=0;
   }
}

//+------------------------------------------------------------------+
//| FUNCTION: Day range                                               |
//+------------------------------------------------------------------+
void GetDayRange(datetime &from,datetime &to)
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   dt.hour=0;dt.min=0;dt.sec=0;
   from=StructToTime(dt); to=TimeCurrent();
}

//+------------------------------------------------------------------+
//| FUNCTION: Price normalization                                      |
//+------------------------------------------------------------------+
double NormalizePrice(const double price)
{
   return NormalizeDouble(price,_Digits);
}
//+------------------------------------------------------------------+
