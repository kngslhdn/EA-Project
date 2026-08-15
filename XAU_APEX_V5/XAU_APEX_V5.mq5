#property strict
#property version "5.00"
#property description "XAU APEX V5 - fixed signal engine, robust trade selection and diagnostic execution"
#include <Trade/Trade.mqh>
CTrade trade;

enum SignalDirection { SIG_NONE=0, SIG_BUY=1, SIG_SELL=-1 };

input ENUM_TIMEFRAMES InpTimeframe=PERIOD_M15;
input ulong InpMagicNumber=26081605;
input string InpComment="XAU APEX V5";
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
datetime g_lastBarTime=0,g_cooldownUntil=0; double g_peakEquity=0.0; int g_consecutiveLosses=0,g_dayKey=-1;

void Debug(string s){if(InpDebug)Print("XAU APEX V5 | ",s);}
double NormalizePrice(double p){return NormalizeDouble(p,_Digits);}
int VolumeDigits(){double x=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);int d=0;while(d<8&&MathAbs(x-MathRound(x))>1e-10){x*=10.0;d++;}return d;}
void GetDayRange(datetime &from,datetime &to){MqlDateTime dt;TimeToStruct(TimeCurrent(),dt);dt.hour=0;dt.min=0;dt.sec=0;from=StructToTime(dt);to=TimeCurrent();}
void ResetDailyStateIfNeeded(){MqlDateTime dt;TimeToStruct(TimeCurrent(),dt);int key=dt.year*10000+dt.mon*100+dt.day;if(key!=g_dayKey){g_dayKey=key;g_consecutiveLosses=0;g_cooldownUntil=0;Debug("NEW DAY RESET");}}
bool NewBar(){datetime t[1];if(CopyTime(_Symbol,InpTimeframe,0,1,t)!=1)return false;if(t[0]==g_lastBarTime)return false;g_lastBarTime=t[0];return true;}
bool GetBuf(int h,int buffer,int shift,double &v){double a[1];if(h==INVALID_HANDLE||CopyBuffer(h,buffer,shift,1,a)!=1)return false;v=a[0];return v!=EMPTY_VALUE;}
int CountOurPositions(){int n=0;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)==_Symbol&&(ulong)PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)n++;}return n;}
int CountTradesToday(){datetime from,to;GetDayRange(from,to);if(!HistorySelect(from,to))return 0;int n=0;uint total=HistoryDealsTotal();for(uint i=0;i<total;i++){ulong d=HistoryDealGetTicket(i);if(d==0)continue;if(HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol)continue;if((ulong)HistoryDealGetInteger(d,DEAL_MAGIC)!=InpMagicNumber)continue;if(HistoryDealGetInteger(d,DEAL_ENTRY)==DEAL_ENTRY_IN)n++;}return n;}
double TodayPnL(){datetime from,to;GetDayRange(from,to);if(!HistorySelect(from,to))return 0;double p=0;uint total=HistoryDealsTotal();for(uint i=0;i<total;i++){ulong d=HistoryDealGetTicket(i);if(d==0)continue;if(HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol)continue;if((ulong)HistoryDealGetInteger(d,DEAL_MAGIC)!=InpMagicNumber)continue;long e=HistoryDealGetInteger(d,DEAL_ENTRY);if(e==DEAL_ENTRY_OUT||e==DEAL_ENTRY_OUT_BY)p+=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_SWAP)+HistoryDealGetDouble(d,DEAL_COMMISSION);}return p;}
bool DailyLossExceeded(){if(InpMaxDailyLossPct<=0)return false;double bal=AccountInfoDouble(ACCOUNT_BALANCE);if(bal<=0)return false;return (-TodayPnL()/bal*100.0)>=InpMaxDailyLossPct;}
void UpdatePeakEquity(){double e=AccountInfoDouble(ACCOUNT_EQUITY);if(e>g_peakEquity)g_peakEquity=e;}
bool EquityDDExceeded(){if(InpMaxEquityDDPct<=0||g_peakEquity<=0)return false;double e=AccountInfoDouble(ACCOUNT_EQUITY);return ((g_peakEquity-e)/g_peakEquity*100.0)>=InpMaxEquityDDPct;}
bool Guards(){if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)||!MQLInfoInteger(MQL_TRADE_ALLOWED))return false;MqlTick t;if(!SymbolInfoTick(_Symbol,t))return false;if(t.ask-t.bid>InpMaxSpreadPrice)return false;if(InpUseSessionFilter){MqlDateTime d;TimeToStruct(TimeCurrent(),d);if(d.hour<InpSessionStartHour||d.hour>=InpSessionEndHour)return false;if(InpBlockFridayLate&&d.day_of_week==5&&d.hour>=InpFridayStopHour)return false;}if(DailyLossExceeded()||EquityDDExceeded())return false;if(g_consecutiveLosses>=InpMaxConsecutiveLoss)return false;if(g_cooldownUntil>TimeCurrent())return false;return true;}

SignalDirection BuildSignal(double &atrOut){double f1,f2,s1,s2,atr,adx,htf=0;if(!GetBuf(hFastEMA,0,1,f1)||!GetBuf(hFastEMA,0,2,f2)||!GetBuf(hSlowEMA,0,1,s1)||!GetBuf(hSlowEMA,0,2,s2)||!GetBuf(hATR,0,1,atr)||!GetBuf(hADX,0,1,adx)){Debug("BLOCK indicator data");return SIG_NONE;}atrOut=atr;if(atr<InpATRMinPrice||atr>InpATRMaxPrice){Debug("BLOCK ATR="+DoubleToString(atr,2));return SIG_NONE;}if(InpUseADXFilter&&adx<InpADXMin){Debug("BLOCK ADX="+DoubleToString(adx,1));return SIG_NONE;}if(InpUseHTFTrend&&!GetBuf(hHTFEMA,0,1,htf)){Debug("BLOCK HTF data");return SIG_NONE;}
 MqlRates r[4]; if(CopyRates(_Symbol,InpTimeframe,1,4,r)!=4){Debug("BLOCK CopyRates");return SIG_NONE;}
 double c=r[0].close,o=r[0].open,h=r[0].high,l=r[0].low,prevH=r[1].high,prevL=r[1].low,range=h-l; if(range<=0)return SIG_NONE;
 bool buyTrend=f1>s1 && f1>=f2 && c>f1; bool sellTrend=f1<s1 && f1<=f2 && c<f1;
 if(InpUseHTFTrend){buyTrend=buyTrend&&c>htf;sellTrend=sellTrend&&c<htf;}
 bool buyPull=l<=f1+atr*InpPullbackATR && c>f1 && c>o;
 bool sellPull=h>=f1-atr*InpPullbackATR && c<f1 && c<o;
 bool buyBreak=c>prevH+atr*InpBreakoutBufferATR && c>o && c>f1;
 bool sellBreak=c<prevL-atr*InpBreakoutBufferATR && c<o && c<f1;
 // A huge candle is only blocked when it exceeds 3 ATR; V4's 2.5 ATR filter was unnecessarily restrictive.
 if(range>atr*3.0){Debug("BLOCK exhausted range="+DoubleToString(range,2));return SIG_NONE;}
 if(InpAllowBuy && buyTrend && (buyPull||buyBreak)){Debug("BUY SIGNAL");return SIG_BUY;}
 if(InpAllowSell && sellTrend && (sellPull||sellBreak)){Debug("SELL SIGNAL");return SIG_SELL;}
 Debug("NO SIGNAL BT="+(string)buyTrend+" ST="+(string)sellTrend+" BP="+(string)buyPull+" SP="+(string)sellPull+" BB="+(string)buyBreak+" SB="+(string)sellBreak);
 return SIG_NONE;}

double CalcLot(ENUM_ORDER_TYPE type,double entry,double sl){double risk=AccountInfoDouble(ACCOUNT_EQUITY)*InpRiskPercent/100.0;if(risk<=0)return 0;double one=0;if(!OrderCalcProfit(type,_Symbol,1.0,entry,sl,one)){Debug("OrderCalcProfit failed");return 0;}one=MathAbs(one);if(one<=0)return 0;double raw=risk/one,minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);if(minLot<=0||maxLot<=0||step<=0)return 0;if(raw<minLot){if(!InpUseMinLotFallback)return 0;raw=minLot;}raw=MathMin(raw,maxLot);raw=MathFloor(raw/step)*step;if(raw<minLot)raw=minLot;return NormalizeDouble(raw,VolumeDigits());}
bool ValidSL(ENUM_ORDER_TYPE type,double sl,double entry){int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);double d=stops*_Point;if(d<=0)return true;return type==ORDER_TYPE_BUY?entry-sl>=d:sl-entry>=d;}
void OpenSignal(SignalDirection sig,double atr){MqlTick t;if(!SymbolInfoTick(_Symbol,t))return;ENUM_ORDER_TYPE type=sig==SIG_BUY?ORDER_TYPE_BUY:ORDER_TYPE_SELL;double entry=type==ORDER_TYPE_BUY?t.ask:t.bid;double slDist=atr*InpSL_ATR,tpDist=atr*InpTP_ATR;if(slDist<=0||tpDist<=slDist)return;double sl=NormalizePrice(type==ORDER_TYPE_BUY?entry-slDist:entry+slDist);double tp=NormalizePrice(type==ORDER_TYPE_BUY?entry+tpDist:entry-tpDist);if(!ValidSL(type,sl,entry)){Debug("ORDER BLOCK stop distance");return;}double lot=CalcLot(type,entry,sl);if(lot<=0){Debug("ORDER BLOCK lot=0");return;}trade.SetExpertMagicNumber(InpMagicNumber);trade.SetDeviationInPoints(InpSlippagePoints);trade.SetTypeFillingBySymbol(_Symbol);bool ok=type==ORDER_TYPE_BUY?trade.Buy(lot,_Symbol,0,sl,tp,InpComment):trade.Sell(lot,_Symbol,0,sl,tp,InpComment);if(!ok)Print("XAU APEX V5 ORDER FAILED ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());else Print("XAU APEX V5 OPEN ",sig==SIG_BUY?"BUY":"SELL"," lot=",DoubleToString(lot,VolumeDigits())," SL=",DoubleToString(sl,_Digits)," TP=",DoubleToString(tp,_Digits));}

void ManageOpenPosition(){if(!PositionSelect(_Symbol))return;if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber)return;ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);double open=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP),atr;if(!GetBuf(hATR,0,1,atr)||atr<=0)return;MqlTick t;if(!SymbolInfoTick(_Symbol,t))return;double price=type==POSITION_TYPE_BUY?t.bid:t.ask;double riskDist=tp>0?MathAbs(tp-open)*(InpSL_ATR/InpTP_ATR):atr*InpSL_ATR;double move=type==POSITION_TYPE_BUY?price-open:open-price;if(move<=0)return;double newSL=sl;bool mod=false;if(move>=riskDist*InpBreakEven_R){double be=NormalizePrice(open);if((type==POSITION_TYPE_BUY&&(sl==0||sl<be))||(type==POSITION_TYPE_SELL&&(sl==0||sl>be))){newSL=be;mod=true;}}if(move>=riskDist*InpLockProfit_R){double lock=NormalizePrice(type==POSITION_TYPE_BUY?open+riskDist*InpLockProfitAt_R:open-riskDist*InpLockProfitAt_R);if((type==POSITION_TYPE_BUY&&(sl==0||lock>sl))||(type==POSITION_TYPE_SELL&&(sl==0||lock<sl))){newSL=lock;mod=true;}double trail=NormalizePrice(type==POSITION_TYPE_BUY?price-atr*InpTrail_ATR:price+atr*InpTrail_ATR);if((type==POSITION_TYPE_BUY&&trail<price&&trail>newSL)||(type==POSITION_TYPE_SELL&&trail>price&&(newSL==0||trail<newSL))){newSL=trail;mod=true;}}if(!mod)return;int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);double md=stops*_Point;if(type==POSITION_TYPE_BUY&&newSL>=price-md)newSL=NormalizePrice(price-md);if(type==POSITION_TYPE_SELL&&newSL<=price+md)newSL=NormalizePrice(price+md);if(newSL<=0)return;if(sl!=0&&MathAbs(newSL-sl)<_Point)return;trade.PositionModify(_Symbol,newSL,tp);}

void OnInitDone(){trade.SetExpertMagicNumber(InpMagicNumber);trade.SetDeviationInPoints(InpSlippagePoints);trade.SetTypeFillingBySymbol(_Symbol);}
int OnInit(){OnInitDone();hFastEMA=iMA(_Symbol,InpTimeframe,InpFastEMA,0,MODE_EMA,PRICE_CLOSE);hSlowEMA=iMA(_Symbol,InpTimeframe,InpSlowEMA,0,MODE_EMA,PRICE_CLOSE);hADX=iADX(_Symbol,InpTimeframe,InpADXPeriod);hATR=iATR(_Symbol,InpTimeframe,14);hHTFEMA=iMA(_Symbol,InpHTF,InpHTFEMA,0,MODE_EMA,PRICE_CLOSE);if(hFastEMA==INVALID_HANDLE||hSlowEMA==INVALID_HANDLE||hADX==INVALID_HANDLE||hATR==INVALID_HANDLE||hHTFEMA==INVALID_HANDLE)return INIT_FAILED;g_peakEquity=AccountInfoDouble(ACCOUNT_EQUITY);ResetDailyStateIfNeeded();Print("XAU APEX V5 READY ",_Symbol);return INIT_SUCCEEDED;}
void OnDeinit(const int reason){if(hFastEMA!=INVALID_HANDLE)IndicatorRelease(hFastEMA);if(hSlowEMA!=INVALID_HANDLE)IndicatorRelease(hSlowEMA);if(hADX!=INVALID_HANDLE)IndicatorRelease(hADX);if(hATR!=INVALID_HANDLE)IndicatorRelease(hATR);if(hHTFEMA!=INVALID_HANDLE)IndicatorRelease(hHTFEMA);}
void OnTick(){ResetDailyStateIfNeeded();UpdatePeakEquity();ManageOpenPosition();if(!NewBar())return;if(!Guards())return;if(InpOnePositionOnly&&CountOurPositions()>0)return;if(CountTradesToday()>=InpMaxTradesPerDay)return;double atr;SignalDirection sig=BuildSignal(atr);if(sig!=SIG_NONE)OpenSignal(sig,atr);}
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &req,const MqlTradeResult &res){if(trans.type!=TRADE_TRANSACTION_DEAL_ADD||trans.deal==0)return;ulong d=trans.deal;if(HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol||(ulong)HistoryDealGetInteger(d,DEAL_MAGIC)!=InpMagicNumber)return;long e=HistoryDealGetInteger(d,DEAL_ENTRY);if(e!=DEAL_ENTRY_OUT&&e!=DEAL_ENTRY_OUT_BY)return;double p=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_SWAP)+HistoryDealGetDouble(d,DEAL_COMMISSION);if(p<0){g_consecutiveLosses++;if(g_consecutiveLosses>=InpMaxConsecutiveLoss)g_cooldownUntil=TimeCurrent()+InpCooldownMinutes*60;}else if(p>0)g_consecutiveLosses=0;}
