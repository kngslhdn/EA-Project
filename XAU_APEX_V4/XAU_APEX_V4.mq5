//+------------------------------------------------------------------+
//| XAU_APEX_V4.mq5                                                  |
//| XAU APEX V4 - Adaptive Signal Engine                             |
//+------------------------------------------------------------------+
#property strict
#property version "4.00"
#property description "XAU APEX V4 - practical XAU trend/pullback/breakout EA"
#property description "Risk controlled. No grid. No martingale. Backtest before live use."
#include <Trade/Trade.mqh>
CTrade trade;

input ENUM_TIMEFRAMES InpTimeframe=PERIOD_M15;
input ulong InpMagicNumber=26081604;
input string InpComment="XAU APEX V4";
input bool InpAllowBuy=true;
input bool InpAllowSell=true;
input int InpFastEMA=50;
input int InpSlowEMA=200;
input ENUM_TIMEFRAMES InpHTF=PERIOD_H1;
input int InpHTFEMA=200;
input bool InpUseHTFTrend=false;
input int InpADXPeriod=14;
input double InpADXMin=15.0;
input bool InpUseADXFilter=false;
input double InpATRMinPrice=0.80;
input double InpATRMaxPrice=50.0;
input double InpPullbackATR=0.75;
input double InpBreakoutBufferATR=0.05;
input double InpSL_ATR=1.40;
input double InpTP_ATR=2.40;
input double InpTrail_ATR=1.20;
input double InpBreakEven_R=1.00;
input double InpLockProfit_R=1.50;
input double InpLockProfitAt_R=0.50;
input double InpRiskPercent=0.50;
input double InpMaxDailyLossPct=2.00;
input double InpMaxEquityDDPct=10.0;
input int InpMaxTradesPerDay=5;
input int InpMaxConsecutiveLoss=3;
input int InpCooldownMinutes=30;
input double InpMaxSpreadPrice=1.50;
input int InpSlippagePoints=80;
input bool InpUseSessionFilter=true;
input int InpSessionStartHour=7;
input int InpSessionEndHour=23;
input bool InpBlockFridayLate=true;
input int InpFridayStopHour=19;
input bool InpOnePositionOnly=true;
input bool InpUseMinLotFallback=true;
input bool InpDebug=true;

int hFastEMA=INVALID_HANDLE,hSlowEMA=INVALID_HANDLE,hADX=INVALID_HANDLE,hATR=INVALID_HANDLE,hHTFEMA=INVALID_HANDLE;
datetime g_lastBarTime=0,g_cooldownUntil=0;
double g_peakEquity=0.0;
int g_consecutiveLosses=0,g_dayKey=-1;

int OnInit()
{
 trade.SetExpertMagicNumber(InpMagicNumber); trade.SetDeviationInPoints(InpSlippagePoints); trade.SetTypeFillingBySymbol(_Symbol);
 hFastEMA=iMA(_Symbol,InpTimeframe,InpFastEMA,0,MODE_EMA,PRICE_CLOSE);
 hSlowEMA=iMA(_Symbol,InpTimeframe,InpSlowEMA,0,MODE_EMA,PRICE_CLOSE);
 hADX=iADX(_Symbol,InpTimeframe,InpADXPeriod);
 hATR=iATR(_Symbol,InpTimeframe,14);
 hHTFEMA=iMA(_Symbol,InpHTF,InpHTFEMA,0,MODE_EMA,PRICE_CLOSE);
 if(hFastEMA==INVALID_HANDLE||hSlowEMA==INVALID_HANDLE||hADX==INVALID_HANDLE||hATR==INVALID_HANDLE||hHTFEMA==INVALID_HANDLE)
 { Print("XAU APEX V4: indicator initialization failed. Error=",GetLastError()); return INIT_FAILED; }
 g_peakEquity=AccountInfoDouble(ACCOUNT_EQUITY); ResetDailyStateIfNeeded();
 Print("XAU APEX V4 READY: ",_Symbol," / ",EnumToString(InpTimeframe)); return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
 if(hFastEMA!=INVALID_HANDLE) IndicatorRelease(hFastEMA); if(hSlowEMA!=INVALID_HANDLE) IndicatorRelease(hSlowEMA);
 if(hADX!=INVALID_HANDLE) IndicatorRelease(hADX); if(hATR!=INVALID_HANDLE) IndicatorRelease(hATR); if(hHTFEMA!=INVALID_HANDLE) IndicatorRelease(hHTFEMA);
}

void OnTick()
{
 ResetDailyStateIfNeeded(); UpdatePeakEquity(); ManageOpenPosition();
 if(!IsNewBar()) return;
 if(!TradingGuardsOK()) return;
 if(InpOnePositionOnly && CountOurPositions()>0) return;
 if(CountTradesToday()>=InpMaxTradesPerDay) return;
 if(IsCooldownActive()) return;
 EvaluateEntry();
}

bool IsNewBar()
{
 datetime t[1]; if(CopyTime(_Symbol,InpTimeframe,0,1,t)!=1) return false;
 if(t[0]==g_lastBarTime) return false; g_lastBarTime=t[0]; return true;
}

bool GetBufferValue(const int handle,const int buffer,const int shift,double &value)
{
 double data[1]; if(CopyBuffer(handle,buffer,shift,1,data)!=1) return false;
 value=data[0]; return value!=EMPTY_VALUE;
}

void EvaluateEntry()
{
 double ema1,ema2,slow1,slow2,adx,atr,htfEMA;
 if(!GetBufferValue(hFastEMA,0,1,ema1)||!GetBufferValue(hFastEMA,0,2,ema2)||
    !GetBufferValue(hSlowEMA,0,1,slow1)||!GetBufferValue(hSlowEMA,0,2,slow2)||
    !GetBufferValue(hADX,0,1,adx)||!GetBufferValue(hATR,0,1,atr))
 { Debug("ENTRY BLOCK: indicator data unavailable"); return; }
 if(InpUseHTFTrend && !GetBufferValue(hHTFEMA,0,1,htfEMA)) { Debug("ENTRY BLOCK: H1 EMA unavailable"); return; }
 if(atr<InpATRMinPrice || atr>InpATRMaxPrice) { Debug("ENTRY BLOCK: ATR="+DoubleToString(atr,2)); return; }
 if(InpUseADXFilter && adx<InpADXMin) { Debug("ENTRY BLOCK: ADX="+DoubleToString(adx,1)); return; }

 MqlRates bars[]; ArraySetAsSeries(bars,true);
 if(CopyRates(_Symbol,InpTimeframe,0,4,bars)!=4) { Debug("ENTRY BLOCK: CopyRates failed"); return; }
 double c1=bars[1].close,o1=bars[1].open,h1=bars[1].high,l1=bars[1].low,h2=bars[2].high,l2=bars[2].low;
 double range1=h1-l1; if(range1<=0.0) return;

 bool buyTrend=(ema1>slow1 && ema1>=ema2 && c1>ema1);
 bool sellTrend=(ema1<slow1 && ema1<=ema2 && c1<ema1);
 if(InpUseHTFTrend) { buyTrend=buyTrend&&c1>htfEMA; sellTrend=sellTrend&&c1<htfEMA; }

 bool buyPullback=(l1<=ema1+atr*InpPullbackATR && c1>ema1 && c1>o1);
 bool sellPullback=(h1>=ema1-atr*InpPullbackATR && c1<ema1 && c1<o1);
 bool buyBreakout=(c1>h2+atr*InpBreakoutBufferATR && c1>o1 && c1>ema1);
 bool sellBreakout=(c1<l2-atr*InpBreakoutBufferATR && c1<o1 && c1<ema1);
 if(range1>atr*2.50) { Debug("ENTRY BLOCK: exhausted candle"); return; }

 MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;
 if(InpAllowBuy && buyTrend && (buyPullback||buyBreakout)) { Debug("BUY SIGNAL"); OpenPosition(ORDER_TYPE_BUY,atr,tick.ask); return; }
 if(InpAllowSell && sellTrend && (sellPullback||sellBreakout)) { Debug("SELL SIGNAL"); OpenPosition(ORDER_TYPE_SELL,atr,tick.bid); return; }
 Debug("NO SIGNAL BT="+(string)buyTrend+" ST="+(string)sellTrend+" BP="+(string)buyPullback+" SP="+(string)sellPullback+" BB="+(string)buyBreakout+" SB="+(string)sellBreakout);
}

void OpenPosition(const ENUM_ORDER_TYPE type,const double atr,const double entry)
{
 double slDist=atr*InpSL_ATR,tpDist=atr*InpTP_ATR; if(slDist<=0.0||tpDist<=slDist) return;
 double sl,tp; if(type==ORDER_TYPE_BUY){sl=entry-slDist;tp=entry+tpDist;}else{sl=entry+slDist;tp=entry-tpDist;}
 sl=NormalizePrice(sl); tp=NormalizePrice(tp);
 if(!IsInitialStopValid(type,sl,entry)){Debug("ORDER BLOCK: stop distance");return;}
 double lots=CalculateRiskLot(type,entry,sl); if(lots<=0.0){Debug("ORDER BLOCK: calculated lot is zero");return;}
 bool ok=(type==ORDER_TYPE_BUY)?trade.Buy(lots,_Symbol,0.0,sl,tp,InpComment):trade.Sell(lots,_Symbol,0.0,sl,tp,InpComment);
 if(!ok) Print("XAU APEX V4 ORDER FAILED retcode=",trade.ResultRetcode()," ",trade.ResultRetcodeDescription()," lot=",DoubleToString(lots,2));
 else Print("XAU APEX V4 OPEN ",EnumToString(type)," lot=",DoubleToString(lots,2)," SL=",DoubleToString(sl,_Digits)," TP=",DoubleToString(tp,_Digits));
}

double CalculateRiskLot(const ENUM_ORDER_TYPE type,const double entry,const double sl)
{
 double riskMoney=AccountInfoDouble(ACCOUNT_EQUITY)*InpRiskPercent/100.0; if(riskMoney<=0.0) return 0.0;
 double lossOneLot=0.0; if(!OrderCalcProfit(type,_Symbol,1.0,entry,sl,lossOneLot)){Print("OrderCalcProfit failed. Error=",GetLastError());return 0.0;}
 lossOneLot=MathAbs(lossOneLot); if(lossOneLot<=0.0) return 0.0;
 double rawLots=riskMoney/lossOneLot;
 double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
 if(minLot<=0.0||maxLot<=0.0||step<=0.0) return 0.0;
 if(rawLots<minLot){if(!InpUseMinLotFallback)return 0.0;rawLots=minLot;}
 rawLots=MathMin(rawLots,maxLot); rawLots=MathFloor(rawLots/step)*step; if(rawLots<minLot)rawLots=minLot;
 int digits=2;if(step<0.01)digits=3;if(step<0.001)digits=4;return NormalizeDouble(rawLots,digits);
}

void ManageOpenPosition()
{
 if(!PositionSelect(_Symbol))return;if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber)return;
 ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
 double openPrice=PositionGetDouble(POSITION_PRICE_OPEN),currentSL=PositionGetDouble(POSITION_SL),currentTP=PositionGetDouble(POSITION_TP),atr;
 if(!GetBufferValue(hATR,0,1,atr)||atr<=0.0)return; MqlTick tick;if(!SymbolInfoTick(_Symbol,tick))return;
 double price=(type==POSITION_TYPE_BUY?tick.bid:tick.ask),initialRisk=0.0;
 if(currentTP>0.0)initialRisk=MathAbs(currentTP-openPrice)*(InpSL_ATR/InpTP_ATR);if(initialRisk<=0.0)initialRisk=atr*InpSL_ATR;
 double profitDist=(type==POSITION_TYPE_BUY?price-openPrice:openPrice-price);if(profitDist<=0.0)return;double newSL=currentSL;bool modify=false;
 if(profitDist>=initialRisk*InpBreakEven_R){double be=NormalizePrice(openPrice);if(type==POSITION_TYPE_BUY&&(newSL==0.0||newSL<be)){newSL=be;modify=true;}if(type==POSITION_TYPE_SELL&&(newSL==0.0||newSL>be)){newSL=be;modify=true;}}
 if(profitDist>=initialRisk*InpLockProfit_R){double lock=(type==POSITION_TYPE_BUY?openPrice+initialRisk*InpLockProfitAt_R:openPrice-initialRisk*InpLockProfitAt_R);lock=NormalizePrice(lock);if(type==POSITION_TYPE_BUY&&(newSL==0.0||newSL<lock)){newSL=lock;modify=true;}if(type==POSITION_TYPE_SELL&&(newSL==0.0||newSL>lock)){newSL=lock;modify=true;}double trail=(type==POSITION_TYPE_BUY?price-atr*InpTrail_ATR:price+atr*InpTrail_ATR);trail=NormalizePrice(trail);if(type==POSITION_TYPE_BUY&&trail<price&&(newSL==0.0||trail>newSL)){newSL=trail;modify=true;}if(type==POSITION_TYPE_SELL&&trail>price&&(newSL==0.0||trail<newSL)){newSL=trail;modify=true;}}
 if(!modify||!IsValidStopLevel(type,newSL,price))return;if(currentSL!=0.0&&MathAbs(newSL-currentSL)<_Point)return;trade.PositionModify(_Symbol,newSL,currentTP);
}

bool TradingGuardsOK()
{
 if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)||!MQLInfoInteger(MQL_TRADE_ALLOWED)){Debug("GUARD: trading not allowed");return false;}
 MqlTick tick;if(!SymbolInfoTick(_Symbol,tick))return false;double spread=tick.ask-tick.bid;if(spread>InpMaxSpreadPrice){Debug("GUARD: spread="+DoubleToString(spread,2));return false;}
 if(InpUseSessionFilter){MqlDateTime dt;TimeToStruct(TimeCurrent(),dt);if(dt.hour<InpSessionStartHour||dt.hour>=InpSessionEndHour){Debug("GUARD: outside session hour="+(string)dt.hour);return false;}if(InpBlockFridayLate&&dt.day_of_week==5&&dt.hour>=InpFridayStopHour){Debug("GUARD: Friday late");return false;}}
 if(DailyLossExceeded()||EquityDDExceeded()||g_consecutiveLosses>=InpMaxConsecutiveLoss)return false;return true;
}

bool IsInitialStopValid(const ENUM_ORDER_TYPE type,const double sl,const double price){int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);double minDist=stops*_Point;if(minDist<=0.0)return true;return type==ORDER_TYPE_BUY?price-sl>=minDist:sl-price>=minDist;}
bool IsValidStopLevel(const ENUM_POSITION_TYPE type,const double sl,const double price){int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);double minDist=stops*_Point;if(minDist<=0.0)return true;return type==POSITION_TYPE_BUY?price-sl>=minDist:sl-price>=minDist;}
int CountOurPositions(){int count=0;for(int i=PositionsTotal()-1;i>=0;i--){ulong ticket=PositionGetTicket(i);if(ticket==0)continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber)continue;count++;}return count;}
int CountTradesToday(){datetime from,to;GetDayRange(from,to);if(!HistorySelect(from,to))return 0;int count=0;uint total=HistoryDealsTotal();for(uint i=0;i<total;i++){ulong ticket=HistoryDealGetTicket(i);if(ticket==0)continue;if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol)continue;if((ulong)HistoryDealGetInteger(ticket,DEAL_MAGIC)!=InpMagicNumber)continue;if(HistoryDealGetInteger(ticket,DEAL_ENTRY)==DEAL_ENTRY_IN)count++;}return count;}
double GetTodayClosedPnL(){datetime from,to;GetDayRange(from,to);if(!HistorySelect(from,to))return 0.0;double pnl=0.0;uint total=HistoryDealsTotal();for(uint i=0;i<total;i++){ulong ticket=HistoryDealGetTicket(i);if(ticket==0)continue;if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol)continue;if((ulong)HistoryDealGetInteger(ticket,DEAL_MAGIC)!=InpMagicNumber)continue;long entry=HistoryDealGetInteger(ticket,DEAL_ENTRY);if(entry!=DEAL_ENTRY_OUT&&entry!=DEAL_ENTRY_OUT_BY)continue;pnl+=HistoryDealGetDouble(ticket,DEAL_PROFIT)+HistoryDealGetDouble(ticket,DEAL_SWAP)+HistoryDealGetDouble(ticket,DEAL_COMMISSION);}return pnl;}
bool DailyLossExceeded(){if(InpMaxDailyLossPct<=0.0)return false;double balance=AccountInfoDouble(ACCOUNT_BALANCE);if(balance<=0.0)return false;return((-GetTodayClosedPnL()/balance)*100.0)>=InpMaxDailyLossPct;}
void UpdatePeakEquity(){double equity=AccountInfoDouble(ACCOUNT_EQUITY);if(equity>g_peakEquity)g_peakEquity=equity;}
bool EquityDDExceeded(){if(InpMaxEquityDDPct<=0.0||g_peakEquity<=0.0)return false;double equity=AccountInfoDouble(ACCOUNT_EQUITY);return((g_peakEquity-equity)/g_peakEquity*100.0)>=InpMaxEquityDDPct;}
void ResetDailyStateIfNeeded(){MqlDateTime dt;TimeToStruct(TimeCurrent(),dt);int key=dt.year*10000+dt.mon*100+dt.day;if(key==g_dayKey)return;g_dayKey=key;g_consecutiveLosses=0;}
bool IsCooldownActive(){return g_cooldownUntil>0&&TimeCurrent()<g_cooldownUntil;}
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result){if(trans.type!=TRADE_TRANSACTION_DEAL_ADD)return;ulong deal=trans.deal;if(deal==0)return;if(HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol)return;if((ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagicNumber)return;long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);if(entry!=DEAL_ENTRY_OUT&&entry!=DEAL_ENTRY_OUT_BY)return;double pnl=HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_SWAP)+HistoryDealGetDouble(deal,DEAL_COMMISSION);if(pnl<0.0){g_consecutiveLosses++;if(g_consecutiveLosses>=InpMaxConsecutiveLoss)g_cooldownUntil=TimeCurrent()+InpCooldownMinutes*60;}else if(pnl>0.0)g_consecutiveLosses=0;}
void GetDayRange(datetime &from,datetime &to){MqlDateTime dt;TimeToStruct(TimeCurrent(),dt);dt.hour=0;dt.min=0;dt.sec=0;from=StructToTime(dt);to=TimeCurrent();}
double NormalizePrice(const double price){return NormalizeDouble(price,_Digits);}
void Debug(const string msg){if(InpDebug)Print("XAU APEX V4 | ",msg);}
//+------------------------------------------------------------------+
