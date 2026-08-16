#property strict
#property version   "9.20"
#property description "XAU APEX V9.2 - asymmetric regime, selective pullback, disciplined exits"
#include <Trade/Trade.mqh>
CTrade trade;

enum Direction { DIR_NONE=0, DIR_BUY=1, DIR_SELL=-1 };

//---------- CORE
input ENUM_TIMEFRAMES EntryTF=PERIOD_M15;
input ENUM_TIMEFRAMES RegimeTF=PERIOD_H1;
input ulong Magic=26081920;
input string CommentText="XAU APEX V9.2";
input bool AllowBuy=true;
input bool AllowSell=true;
input bool OnePositionOnly=true;

//---------- REGIME ENGINE
input int RegimeFastEMA=50;
input int RegimeSlowEMA=200;
input int RegimeADXPeriod=14;
input double BuyADXMin=22.0;
input double SellADXMin=18.0;
input double BuyMinSeparationATR=0.12;
input double SellMinSeparationATR=0.08;
input double MinRegimeSlopeATR=0.015;

//---------- ENTRY ENGINE
input int EntryFastEMA=20;
input int EntrySlowEMA=50;
input int EntryADXPeriod=14;
input double EntryADXMin=18.0;
input int ATRPeriod=14;
input double ATRMin=0.80;
input double ATRMax=40.0;
input double PullbackTouchATR=0.25;
input double PullbackMaxDistanceATR=0.75;
input double MinBodyFraction=0.40;
input double MinCloseLocation=0.55;
input double MaxChaseATR=0.80;
input bool UseVWAP=true;
input double VWAPToleranceATR=0.50;

//---------- SESSION
input int SessionStartHour=8;
input int SessionEndHour=17;
input bool BlockFriday=true;
input int FridayStopHour=0;

//---------- EXIT ENGINE
input double SL_ATR=1.60;
input double TP_R=2.20;
input double BE_R=1.00;
input double BE_Offset_R=0.05;
input double LockStart_R=1.50;
input double LockProfit_R=0.50;
input double TrailStart_R=2.00;
input double TrailATR=1.50;
input int SoftTimeStopBars=16;
input double SoftTimeStopMinR=0.10;
input int HardMaxBars=24;

//---------- MONEY / SAFETY
input double RiskPercent=0.50;
input double MaxDailyLossPercent=2.0;
input double MaxEquityDDPercent=10.0;
input int MaxTradesPerDay=4;
input int MaxConsecutiveLosses=3;
input int CooldownMinutes=45;

//---------- EXECUTION
input double MaxSpreadPrice=1.50;
input int SlippagePoints=80;
input bool DebugMode=true;

int hEFast=-1,hESlow=-1,hRFast=-1,hRSlow=-1,hADXEntry=-1,hADXRegime=-1,hATR=-1;
datetime g_lastBar=0,g_cooldownUntil=0;
double g_peakEquity=0.0;
int g_dayKey=-1,g_consecutiveLosses=0;

void Log(string s){if(DebugMode)Print("XAU APEX V9.2 | ",s);}
int VolDigits(){double s=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);int d=0;while(d<8&&MathAbs(s-MathRound(s))>1e-10){s*=10.0;d++;}return d;}
double NP(double p){return NormalizeDouble(p,_Digits);}
double NV(double v){double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);if(mn<=0||mx<=0||st<=0)return 0;v=MathMax(mn,MathMin(mx,v));v=MathFloor(v/st+1e-9)*st;if(v<mn)v=mn;return NormalizeDouble(v,VolDigits());}
bool Buf(int h,int b,int sh,double &v){double a[1];if(h<0||CopyBuffer(h,b,sh,1,a)!=1)return false;v=a[0];return v!=EMPTY_VALUE;}
bool NewBar(){datetime t[1];if(CopyTime(_Symbol,EntryTF,0,1,t)!=1)return false;if(t[0]==g_lastBar)return false;g_lastBar=t[0];return true;}
int DayKey(){MqlDateTime d;TimeToStruct(TimeCurrent(),d);return d.year*10000+d.mon*100+d.day;}
void DailyReset(){int k=DayKey();if(k!=g_dayKey){g_dayKey=k;g_consecutiveLosses=0;g_cooldownUntil=0;}}
int MyPositions(){int n=0;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t>0&&PositionSelectByTicket(t)&&PositionGetString(POSITION_SYMBOL)==_Symbol&&(ulong)PositionGetInteger(POSITION_MAGIC)==Magic)n++;}return n;}
void UpdatePeak(){double e=AccountInfoDouble(ACCOUNT_EQUITY);if(e>g_peakEquity)g_peakEquity=e;}
void DayWindow(datetime &a,datetime &b){MqlDateTime d;TimeToStruct(TimeCurrent(),d);d.hour=0;d.min=0;d.sec=0;a=StructToTime(d);b=TimeCurrent();}
double TodayPnL(){datetime a,b;DayWindow(a,b);if(!HistorySelect(a,b))return 0;double p=0;uint n=HistoryDealsTotal();for(uint i=0;i<n;i++){ulong t=HistoryDealGetTicket(i);if(!t)continue;if(HistoryDealGetString(t,DEAL_SYMBOL)!=_Symbol||(ulong)HistoryDealGetInteger(t,DEAL_MAGIC)!=Magic)continue;long e=HistoryDealGetInteger(t,DEAL_ENTRY);if(e==DEAL_ENTRY_OUT||e==DEAL_ENTRY_OUT_BY)p+=HistoryDealGetDouble(t,DEAL_PROFIT)+HistoryDealGetDouble(t,DEAL_SWAP)+HistoryDealGetDouble(t,DEAL_COMMISSION);}return p;}
int TradesToday(){datetime a,b;DayWindow(a,b);if(!HistorySelect(a,b))return 0;int n=0;uint total=HistoryDealsTotal();for(uint i=0;i<total;i++){ulong t=HistoryDealGetTicket(i);if(!t)continue;if(HistoryDealGetString(t,DEAL_SYMBOL)!=_Symbol||(ulong)HistoryDealGetInteger(t,DEAL_MAGIC)!=Magic)continue;if(HistoryDealGetInteger(t,DEAL_ENTRY)==DEAL_ENTRY_IN)n++;}return n;}
bool RiskBlocked(){double bal=AccountInfoDouble(ACCOUNT_BALANCE),eq=AccountInfoDouble(ACCOUNT_EQUITY);if(bal<=0)return true;if(MaxDailyLossPercent>0&&TodayPnL()<=-bal*MaxDailyLossPercent/100.0)return true;if(MaxEquityDDPercent>0&&g_peakEquity>0&&(g_peakEquity-eq)>=g_peakEquity*MaxEquityDDPercent/100.0)return true;if(MaxTradesPerDay>0&&TradesToday()>=MaxTradesPerDay)return true;if(MaxConsecutiveLosses>0&&g_consecutiveLosses>=MaxConsecutiveLosses)return true;return g_cooldownUntil>TimeCurrent();}
bool SessionOK(){MqlDateTime d;TimeToStruct(TimeCurrent(),d);if(d.day_of_week==0||d.day_of_week==6)return false;if(BlockFriday&&d.day_of_week==5)return false;if(SessionStartHour==SessionEndHour)return true;if(SessionStartHour<SessionEndHour)return d.hour>=SessionStartHour&&d.hour<SessionEndHour;return d.hour>=SessionStartHour||d.hour<SessionEndHour;}
bool SpreadOK(){MqlTick t;if(!SymbolInfoTick(_Symbol,t))return false;return MaxSpreadPrice<=0||(t.ask-t.bid)<=MaxSpreadPrice;}

bool SessionVWAP(double &vwap){if(!UseVWAP){vwap=0;return true;}MqlDateTime d;TimeToStruct(TimeCurrent(),d);d.hour=SessionStartHour;d.min=0;d.sec=0;datetime from=StructToTime(d);if(TimeCurrent()<from)from-=86400;MqlRates r[];int n=CopyRates(_Symbol,EntryTF,from,TimeCurrent()-1,r);if(n<3)return false;double pv=0,vol=0;for(int i=0;i<n;i++){double v=(double)r[i].tick_volume;if(v<=0)continue;double typical=(r[i].high+r[i].low+r[i].close)/3.0;pv+=typical*v;vol+=v;}if(vol<=0)return false;vwap=pv/vol;return true;}
bool ATRValue(double &atr){return Buf(hATR,0,1,atr)&&atr>0;}

//---------- FUNCTION: REGIME ENGINE
bool Regime(Direction &dir,double &atr,double &sep,double &adx){
 double rf,rs,rfPrev,rsPrev,plus,minus;
 if(!Buf(hRFast,0,1,rf)||!Buf(hRSlow,0,1,rs)||!Buf(hRFast,0,2,rfPrev)||!Buf(hRSlow,0,2,rsPrev))return false;
 if(!Buf(hADXRegime,0,1,adx)||!Buf(hADXRegime,1,1,plus)||!Buf(hADXRegime,2,1,minus))return false;
 if(!ATRValue(atr)||atr<ATRMin||atr>ATRMax)return false;
 double c=iClose(_Symbol,RegimeTF,1);if(c<=0)return false;
 sep=MathAbs(rf-rs)/atr;dir=DIR_NONE;
 double slopeFast=MathAbs(rf-rfPrev)/atr;
 if(rf>rs && rf>rfPrev && rs>=rsPrev && c>rf && plus>minus && adx>=BuyADXMin && sep>=BuyMinSeparationATR && slopeFast>=MinRegimeSlopeATR){dir=DIR_BUY;return true;}
 if(rf<rs && rf<rfPrev && rs<=rsPrev && c<rf && minus>plus && adx>=SellADXMin && sep>=SellMinSeparationATR && slopeFast>=MinRegimeSlopeATR){dir=DIR_SELL;return true;}
 return false;
}

bool CandleQuality(MqlRates &s,double atr,Direction dir){double range=s.high-s.low;if(range<=0||range>atr*2.8)return false;double body=MathAbs(s.close-s.open);if(body/range<MinBodyFraction)return false;double loc=(s.close-s.low)/range;if(dir==DIR_BUY)return s.close>s.open&&loc>=MinCloseLocation;return s.close<s.open&&loc<=(1.0-MinCloseLocation);}

//---------- FUNCTION: PULLBACK ENTRY
bool PullbackSignal(Direction dir,double atr,double vwap){
 double ef,es,efPrev,adx;if(!Buf(hEFast,0,1,ef)||!Buf(hESlow,0,1,es)||!Buf(hEFast,0,2,efPrev)||!Buf(hADXEntry,0,1,adx))return false;
 if(adx<EntryADXMin)return false;
 MqlRates r[3];if(CopyRates(_Symbol,EntryTF,1,3,r)!=3)return false;MqlRates s=r[0];
 if(!CandleQuality(s,atr,dir))return false;
 double dist=MathAbs(s.close-ef)/atr;if(dist>MaxChaseATR)return false;
 double slope=ef-efPrev;
 if(dir==DIR_BUY){
   if(!(ef>es&&s.close>ef&&slope>0))return false;
   if(!(s.low<=ef+atr*PullbackTouchATR&&s.low>=ef-atr*PullbackMaxDistanceATR))return false;
   if(UseVWAP&&s.close<vwap-atr*VWAPToleranceATR)return false;
   return true;
 }
 if(!(ef<es&&s.close<ef&&slope<0))return false;
 if(!(s.high>=ef-atr*PullbackTouchATR&&s.high<=ef+atr*PullbackMaxDistanceATR))return false;
 if(UseVWAP&&s.close>vwap+atr*VWAPToleranceATR)return false;
 return true;
}

string RKey(ulong ticket){return "XAU_APEX_V92_R_"+(string)ticket;}
string BKey(ulong ticket){return "XAU_APEX_V92_BAR_"+(string)ticket;}
void SaveRisk(ulong ticket,double r){if(ticket>0&&r>0)GlobalVariableSet(RKey(ticket),r);}
double LoadRisk(ulong ticket){if(ticket>0&&GlobalVariableCheck(RKey(ticket)))return GlobalVariableGet(RKey(ticket));return 0;}
void SaveEntryBar(ulong ticket,datetime t){if(ticket>0&&t>0)GlobalVariableSet(BKey(ticket),(double)t);}
datetime LoadEntryBar(ulong ticket){if(ticket>0&&GlobalVariableCheck(BKey(ticket)))return (datetime)GlobalVariableGet(BKey(ticket));return 0;}

bool StopOK(ENUM_ORDER_TYPE type,double entry,double sl){double minDist=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;if(minDist<=0)return true;return type==ORDER_TYPE_BUY?(entry-sl)>=minDist:(sl-entry)>=minDist;}
double LotForRisk(ENUM_ORDER_TYPE type,double entry,double sl){double money=AccountInfoDouble(ACCOUNT_EQUITY)*RiskPercent/100.0;if(money<=0)return 0;double pnl=0;if(!OrderCalcProfit(type,_Symbol,1.0,entry,sl,pnl))return 0;double one=MathAbs(pnl);if(one<=0)return 0;return NV(money/one);}

//---------- FUNCTION: ENTER TRADE
void Enter(Direction dir,double atr){
 MqlTick t;if(!SymbolInfoTick(_Symbol,t))return;ENUM_ORDER_TYPE type=dir==DIR_BUY?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
 double entry=type==ORDER_TYPE_BUY?t.ask:t.bid;double riskDist=atr*SL_ATR;if(riskDist<=0)return;
 double sl=NP(type==ORDER_TYPE_BUY?entry-riskDist:entry+riskDist);double tp=NP(type==ORDER_TYPE_BUY?entry+riskDist*TP_R:entry-riskDist*TP_R);
 if(!StopOK(type,entry,sl))return;double lot=LotForRisk(type,entry,sl);if(lot<=0)return;
 trade.SetExpertMagicNumber(Magic);trade.SetDeviationInPoints(SlippagePoints);trade.SetTypeFillingBySymbol(_Symbol);
 string c=CommentText+(dir==DIR_BUY?" PULLBACK BUY":" PULLBACK SELL");
 bool ok=type==ORDER_TYPE_BUY?trade.Buy(lot,_Symbol,0,sl,tp,c):trade.Sell(lot,_Symbol,0,sl,tp,c);
 if(!ok){Print("XAU APEX V9.2 ORDER FAIL ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());return;}
 for(int i=PositionsTotal()-1;i>=0;i--){ulong ticket=PositionGetTicket(i);if(ticket==0||!PositionSelectByTicket(ticket))continue;if(PositionGetString(POSITION_SYMBOL)==_Symbol&&(ulong)PositionGetInteger(POSITION_MAGIC)==Magic){SaveRisk(ticket,riskDist);SaveEntryBar(ticket,iTime(_Symbol,EntryTF,0));break;}}
 Log("OPEN "+(dir==DIR_BUY?"BUY":"SELL")+" lot="+DoubleToString(lot,VolDigits()));
}

bool ModifySL(ulong ticket,double newSL,double tp){if(!PositionSelectByTicket(ticket))return false;long type=PositionGetInteger(POSITION_TYPE);double price=type==POSITION_TYPE_BUY?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);double minDist=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;if(type==POSITION_TYPE_BUY)newSL=MathMin(newSL,NP(price-minDist));else newSL=MathMax(newSL,NP(price+minDist));newSL=NP(newSL);double old=PositionGetDouble(POSITION_SL);if(type==POSITION_TYPE_BUY&&old>0&&newSL<=old+_Point)return false;if(type==POSITION_TYPE_SELL&&old>0&&newSL>=old-_Point)return false;trade.SetExpertMagicNumber(Magic);return trade.PositionModify(ticket,newSL,tp);}

//---------- FUNCTION: POSITION MANAGEMENT
void ManagePositions(){
 double atr;if(!ATRValue(atr))return;
 for(int i=PositionsTotal()-1;i>=0;i--){
  ulong ticket=PositionGetTicket(i);if(ticket==0||!PositionSelectByTicket(ticket))continue;
  if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(ulong)PositionGetInteger(POSITION_MAGIC)!=Magic)continue;
  long type=PositionGetInteger(POSITION_TYPE);double open=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP);
  double price=type==POSITION_TYPE_BUY?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);double riskDist=LoadRisk(ticket);if(riskDist<=0){riskDist=atr*SL_ATR;SaveRisk(ticket,riskDist);}if(riskDist<=0)continue;
  double R=(type==POSITION_TYPE_BUY?price-open:open-price)/riskDist;
  datetime entryBar=LoadEntryBar(ticket);int age=0;if(entryBar>0){int sh=iBarShift(_Symbol,EntryTF,entryBar,false);if(sh>=0)age=sh;}
  if(HardMaxBars>0&&age>=HardMaxBars){trade.PositionClose(ticket);continue;}
  if(SoftTimeStopBars>0&&age>=SoftTimeStopBars&&R<SoftTimeStopMinR){trade.PositionClose(ticket);continue;}
  double newSL=sl;bool modify=false;
  if(R>=BE_R){double be=type==POSITION_TYPE_BUY?open+riskDist*BE_Offset_R:open-riskDist*BE_Offset_R;if(type==POSITION_TYPE_BUY){if(sl==0||be>newSL+_Point){newSL=be;modify=true;}}else{if(sl==0||be<newSL-_Point){newSL=be;modify=true;}}}
  if(R>=LockStart_R){double lk=type==POSITION_TYPE_BUY?open+riskDist*LockProfit_R:open-riskDist*LockProfit_R;if(type==POSITION_TYPE_BUY){if(lk>newSL+_Point){newSL=lk;modify=true;}}else{if(newSL==0||lk<newSL-_Point){newSL=lk;modify=true;}}}
  if(R>=TrailStart_R){double tr=type==POSITION_TYPE_BUY?price-atr*TrailATR:price+atr*TrailATR;if(type==POSITION_TYPE_BUY){if(tr>newSL+_Point&&tr<price){newSL=tr;modify=true;}}else{if((newSL==0||tr<newSL-_Point)&&tr>price){newSL=tr;modify=true;}}}
  if(modify)ModifySL(ticket,newSL,tp);
 }
}

int OnInit(){
 trade.SetExpertMagicNumber(Magic);trade.SetDeviationInPoints(SlippagePoints);trade.SetTypeFillingBySymbol(_Symbol);
 hEFast=iMA(_Symbol,EntryTF,EntryFastEMA,0,MODE_EMA,PRICE_CLOSE);hESlow=iMA(_Symbol,EntryTF,EntrySlowEMA,0,MODE_EMA,PRICE_CLOSE);
 hRFast=iMA(_Symbol,RegimeTF,RegimeFastEMA,0,MODE_EMA,PRICE_CLOSE);hRSlow=iMA(_Symbol,RegimeTF,RegimeSlowEMA,0,MODE_EMA,PRICE_CLOSE);
 hADXEntry=iADX(_Symbol,EntryTF,EntryADXPeriod);hADXRegime=iADX(_Symbol,RegimeTF,RegimeADXPeriod);hATR=iATR(_Symbol,EntryTF,ATRPeriod);
 if(hEFast<0||hESlow<0||hRFast<0||hRSlow<0||hADXEntry<0||hADXRegime<0||hATR<0)return INIT_FAILED;
 g_peakEquity=AccountInfoDouble(ACCOUNT_EQUITY);DailyReset();Print("XAU APEX V9.2 READY ",_Symbol);return INIT_SUCCEEDED;
}
void OnDeinit(const int reason){if(hEFast>=0)IndicatorRelease(hEFast);if(hESlow>=0)IndicatorRelease(hESlow);if(hRFast>=0)IndicatorRelease(hRFast);if(hRSlow>=0)IndicatorRelease(hRSlow);if(hADXEntry>=0)IndicatorRelease(hADXEntry);if(hADXRegime>=0)IndicatorRelease(hADXRegime);if(hATR>=0)IndicatorRelease(hATR);}

void OnTick(){
 DailyReset();UpdatePeak();ManagePositions();if(!NewBar())return;
 if(!SessionOK()||!SpreadOK()||RiskBlocked())return;if(OnePositionOnly&&MyPositions()>0)return;
 Direction regime;double atr,sep,adx;if(!Regime(regime,atr,sep,adx))return;
 if(regime==DIR_BUY&&!AllowBuy)return;if(regime==DIR_SELL&&!AllowSell)return;
 double vwap=0;if(UseVWAP&&!SessionVWAP(vwap))return;
 if(PullbackSignal(regime,atr,vwap))Enter(regime,atr);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &req,const MqlTradeResult &res){
 if(trans.type!=TRADE_TRANSACTION_DEAL_ADD||trans.deal==0)return;ulong d=trans.deal;
 if(HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol||(ulong)HistoryDealGetInteger(d,DEAL_MAGIC)!=Magic)return;
 long e=HistoryDealGetInteger(d,DEAL_ENTRY);if(e==DEAL_ENTRY_OUT||e==DEAL_ENTRY_OUT_BY){double p=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_SWAP)+HistoryDealGetDouble(d,DEAL_COMMISSION);if(p<0){g_consecutiveLosses++;g_cooldownUntil=TimeCurrent()+CooldownMinutes*60;}else if(p>0){g_consecutiveLosses=0;g_cooldownUntil=TimeCurrent()+900;}}
}
