#property strict
#property version   "9.10"
#property description "XAU APEX V9.1 - V6-core trend/pullback with evidence-led exits"
#include <Trade/Trade.mqh>
CTrade trade;

enum Direction { DIR_NONE=0, DIR_BUY=1, DIR_SELL=-1 };

//---------- CORE
input ENUM_TIMEFRAMES EntryTF=PERIOD_M15;
input ENUM_TIMEFRAMES RegimeTF=PERIOD_H1;
input ulong Magic=26081910;
input string CommentText="XAU APEX V9.1";
input bool AllowBuy=true;
input bool AllowSell=true;
input bool OnePositionOnly=true;

//---------- REGIME
input int RegimeFastEMA=50;
input int RegimeSlowEMA=200;
input int RegimeADXPeriod=14;
input double RegimeADXMin=18.0;
input double MinTrendSeparationATR=0.08;
input double StrongADX=25.0;
input double StrongSeparationATR=0.50;

//---------- ENTRY
input int EntryFastEMA=20;
input int EntrySlowEMA=50;
input int ADXPeriod=14;
input int RSIPeriod=14;
input int ATRPeriod=14;
input double EntryADXMin=18.0;
input double PullbackTouchATR=0.15;
input double PullbackMaxDistanceATR=0.35;
input double MinBodyFraction=0.50;
input double MinCloseLocation=0.65;
input double MaxChaseATR=0.65;
input double RSI_Buy_Min=52.0;
input double RSI_Buy_Max=68.0;
input double RSI_Sell_Min=32.0;
input double RSI_Sell_Max=48.0;
input double ATRMin=0.80;
input double ATRMax=40.0;
input double ExhaustionATR=3.00;

//---------- SESSION / VWAP
input bool UseSessionVWAP=true;
input int SessionStartHour=7;
input int SessionEndHour=22;
input double VWAPToleranceATR=0.35;

//---------- EXIT
input double SL_ATR=1.60;
input double NormalTP_R=2.80;
input double StrongTP_R=3.60;
input double BE_R=1.00;
input double BE_Offset_R=0.05;
input double LockStart_R=1.50;
input double LockProfit_R=0.50;
input double TrailStart_R=2.00;
input double TrailATR=1.20;
input int MaxBarsInTrade=24;
input double TimeStopMinR=0.20;
input bool UseAdaptiveTP=true;

//---------- MONEY MANAGEMENT
input double RiskPercent=0.50;
input double MaxDailyLossPercent=2.0;
input double MaxEquityDDPercent=10.0;
input int MaxTradesPerDay=5;
input int MaxConsecutiveLosses=3;
input int CooldownMinutes=45;

//---------- EXECUTION
input double MaxSpreadPrice=1.50;
input int SlippagePoints=80;
input bool BlockFridayLate=true;
input int FridayStopHour=19;
input bool DebugMode=true;

int hEFast=-1,hESlow=-1,hRFast=-1,hRSlow=-1,hADXEntry=-1,hADXRegime=-1,hATR=-1,hRSI=-1;
datetime g_lastBar=0,g_cooldownUntil=0;
double g_peakEquity=0.0;
int g_dayKey=-1,g_consecutiveLosses=0;

void Log(string s){if(DebugMode)Print("XAU APEX V9.1 | ",s);}
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
bool SessionOK(){MqlDateTime d;TimeToStruct(TimeCurrent(),d);if(d.day_of_week==0||d.day_of_week==6)return false;if(BlockFridayLate&&d.day_of_week==5&&d.hour>=FridayStopHour)return false;if(SessionStartHour==SessionEndHour)return true;if(SessionStartHour<SessionEndHour)return d.hour>=SessionStartHour&&d.hour<SessionEndHour;return d.hour>=SessionStartHour||d.hour<SessionEndHour;}
bool SpreadOK(){MqlTick t;if(!SymbolInfoTick(_Symbol,t))return false;return MaxSpreadPrice<=0||(t.ask-t.bid)<=MaxSpreadPrice;}
bool RiskBlocked(){double bal=AccountInfoDouble(ACCOUNT_BALANCE),eq=AccountInfoDouble(ACCOUNT_EQUITY);if(bal<=0)return true;if(MaxDailyLossPercent>0&&TodayPnL()<=-bal*MaxDailyLossPercent/100.0)return true;if(MaxEquityDDPercent>0&&g_peakEquity>0&&(g_peakEquity-eq)>=g_peakEquity*MaxEquityDDPercent/100.0)return true;if(MaxTradesPerDay>0&&TradesToday()>=MaxTradesPerDay)return true;if(MaxConsecutiveLosses>0&&g_consecutiveLosses>=MaxConsecutiveLosses)return true;return g_cooldownUntil>TimeCurrent();}

bool SessionVWAP(double &vwap){if(!UseSessionVWAP){vwap=0;return true;}MqlDateTime d;TimeToStruct(TimeCurrent(),d);d.hour=SessionStartHour;d.min=0;d.sec=0;datetime from=StructToTime(d);if(TimeCurrent()<from)from-=86400;MqlRates r[];int n=CopyRates(_Symbol,EntryTF,from,TimeCurrent()-1,r);if(n<3)return false;double pv=0,vol=0;for(int i=0;i<n;i++){double v=(double)r[i].tick_volume;if(v<=0)continue;pv+=((r[i].high+r[i].low+r[i].close)/3.0)*v;vol+=v;}if(vol<=0)return false;vwap=pv/vol;return true;}
bool ATRValue(double &atr){return Buf(hATR,0,1,atr)&&atr>0;}

bool Regime(Direction &dir,double &atr,double &sep,double &adx){double rf,rs,c,plus,minus;if(!Buf(hRFast,0,1,rf)||!Buf(hRSlow,0,1,rs)||!Buf(hADXRegime,0,1,adx)||!Buf(hADXRegime,1,1,plus)||!Buf(hADXRegime,2,1,minus))return false;if(!ATRValue(atr)||atr<ATRMin||atr>ATRMax)return false;c=iClose(_Symbol,RegimeTF,1);if(c<=0)return false;sep=MathAbs(rf-rs)/atr;dir=DIR_NONE;if(sep<MinTrendSeparationATR||adx<RegimeADXMin)return true;if(rf>rs&&c>rf&&plus>minus)dir=DIR_BUY;else if(rf<rs&&c<rf&&minus>plus)dir=DIR_SELL;return true;}

bool CandleQuality(MqlRates &s,double atr,Direction dir){double range=s.high-s.low;if(range<=0||range>atr*ExhaustionATR)return false;double body=MathAbs(s.close-s.open);if(body/range<MinBodyFraction)return false;double loc=(s.close-s.low)/range;if(dir==DIR_BUY)return s.close>s.open&&loc>=MinCloseLocation;return s.close<s.open&&loc<=(1.0-MinCloseLocation);}

bool PullbackSignal(Direction dir,double atr,double vwap,double &quality){quality=0;double ef,es,efPrev,adx,rsi;if(!Buf(hEFast,0,1,ef)||!Buf(hEFast,0,2,efPrev)||!Buf(hESlow,0,1,es)||!Buf(hADXEntry,0,1,adx)||!Buf(hRSI,0,1,rsi))return false;MqlRates r[3];if(CopyRates(_Symbol,EntryTF,1,3,r)!=3)return false;MqlRates s=r[0];if(adx<EntryADXMin||!CandleQuality(s,atr,dir))return false;double dist=MathAbs(s.close-ef)/atr;if(dist>MaxChaseATR)return false;double slope=ef-efPrev;if(dir==DIR_BUY){if(!(ef>es&&s.close>ef&&slope>0))return false;if(rsi<RSI_Buy_Min||rsi>RSI_Buy_Max)return false;if(!(s.low<=ef+atr*PullbackTouchATR&&s.low>=ef-atr*PullbackMaxDistanceATR))return false;if(UseSessionVWAP&&s.close<vwap-atr*VWAPToleranceATR)return false;quality=60.0+MathMin(20.0,slope/atr*200.0)+MathMin(20.0,(1.0-dist/MaxChaseATR)*20.0);return quality>=65.0;}else{if(!(ef<es&&s.close<ef&&slope<0))return false;if(rsi<RSI_Sell_Min||rsi>RSI_Sell_Max)return false;if(!(s.high>=ef-atr*PullbackTouchATR&&s.high<=ef+atr*PullbackMaxDistanceATR))return false;if(UseSessionVWAP&&s.close>vwap+atr*VWAPToleranceATR)return false;quality=60.0+MathMin(20.0,-slope/atr*200.0)+MathMin(20.0,(1.0-dist/MaxChaseATR)*20.0);return quality>=65.0;}}

string RKey(ulong ticket){return "XAU_APEX_V91_R_"+(string)ticket;}
void SaveR(ulong ticket,double r){if(ticket>0&&r>0)GlobalVariableSet(RKey(ticket),r);}
double LoadR(ulong ticket){if(ticket>0&&GlobalVariableCheck(RKey(ticket)))return GlobalVariableGet(RKey(ticket));return 0;}

bool StopOK(ENUM_ORDER_TYPE type,double entry,double sl){double minDist=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;if(minDist<=0)return true;return type==ORDER_TYPE_BUY?(entry-sl)>=minDist:(sl-entry)>=minDist;}
double LotForRisk(ENUM_ORDER_TYPE type,double entry,double sl){double money=AccountInfoDouble(ACCOUNT_EQUITY)*RiskPercent/100.0;if(money<=0)return 0;double pnl=0;if(!OrderCalcProfit(type,_Symbol,1.0,entry,sl,pnl))return 0;double one=MathAbs(pnl);if(one<=0)return 0;return NV(money/one);}

void Enter(Direction dir,double atr,double regimeADX,double regimeSep,double quality){MqlTick t;if(!SymbolInfoTick(_Symbol,t))return;ENUM_ORDER_TYPE type=dir==DIR_BUY?ORDER_TYPE_BUY:ORDER_TYPE_SELL;double entry=type==ORDER_TYPE_BUY?t.ask:t.bid;double riskDist=atr*SL_ATR;if(riskDist<=0)return;double tpR=NormalTP_R;if(UseAdaptiveTP&&regimeADX>=StrongADX&&regimeSep>=StrongSeparationATR&&quality>=80)tpR=StrongTP_R;double sl=NP(type==ORDER_TYPE_BUY?entry-riskDist:entry+riskDist);double tp=NP(type==ORDER_TYPE_BUY?entry+riskDist*tpR:entry-riskDist*tpR);if(!StopOK(type,entry,sl))return;double lot=LotForRisk(type,entry,sl);if(lot<=0)return;trade.SetExpertMagicNumber(Magic);trade.SetDeviationInPoints(SlippagePoints);trade.SetTypeFillingBySymbol(_Symbol);string c=CommentText+(dir==DIR_BUY?" PULLBACK BUY":" PULLBACK SELL");bool ok=type==ORDER_TYPE_BUY?trade.Buy(lot,_Symbol,0,sl,tp,c):trade.Sell(lot,_Symbol,0,sl,tp,c);if(!ok){Print("XAU APEX V9.1 ORDER FAIL ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());return;}for(int i=PositionsTotal()-1;i>=0;i--){ulong ticket=PositionGetTicket(i);if(ticket==0||!PositionSelectByTicket(ticket))continue;if(PositionGetString(POSITION_SYMBOL)==_Symbol&&(ulong)PositionGetInteger(POSITION_MAGIC)==Magic){SaveR(ticket,riskDist);break;}}Log("OPEN "+(dir==DIR_BUY?"BUY":"SELL")+" lot="+DoubleToString(lot,VolDigits())+" TP_R="+DoubleToString(tpR,2));}

void ManagePositions(){double atr;if(!ATRValue(atr))return;for(int i=PositionsTotal()-1;i>=0;i--){ulong ticket=PositionGetTicket(i);if(ticket==0||!PositionSelectByTicket(ticket))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(ulong)PositionGetInteger(POSITION_MAGIC)!=Magic)continue;long type=PositionGetInteger(POSITION_TYPE);double open=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP);double price=type==POSITION_TYPE_BUY?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);double riskDist=LoadR(ticket);if(riskDist<=0){riskDist=atr*SL_ATR;SaveR(ticket,riskDist);}double R=(type==POSITION_TYPE_BUY?price-open:open-price)/riskDist;double newSL=sl;bool modify=false;if(R>=BE_R){double be=type==POSITION_TYPE_BUY?open+riskDist*BE_Offset_R:open-riskDist*BE_Offset_R;if(type==POSITION_TYPE_BUY){if(sl==0||be>sl+_Point){newSL=be;modify=true;}}else if(sl==0||be<sl-_Point){newSL=be;modify=true;}}if(R>=LockStart_R){double lk=type==POSITION_TYPE_BUY?open+riskDist*LockProfit_R:open-riskDist*LockProfit_R;if(type==POSITION_TYPE_BUY){if(lk>newSL+_Point){newSL=lk;modify=true;}}else if(newSL==0||lk<newSL-_Point){newSL=lk;modify=true;}}if(R>=TrailStart_R){double tr=type==POSITION_TYPE_BUY?price-atr*TrailATR:price+atr*TrailATR;if(type==POSITION_TYPE_BUY){if(tr>newSL+_Point){newSL=tr;modify=true;}}else if(newSL==0||tr<newSL-_Point){newSL=tr;modify=true;}}if(modify){newSL=NP(newSL);if((type==POSITION_TYPE_BUY&&newSL<price)||(type==POSITION_TYPE_SELL&&newSL>price))trade.PositionModify(ticket,newSL,tp);}datetime opent=(datetime)PositionGetInteger(POSITION_TIME);if(MaxBarsInTrade>0&&opent>0&&iBarShift(_Symbol,EntryTF,opent,false)>=MaxBarsInTrade&&R<TimeStopMinR){trade.PositionClose(ticket);Log("TIME STOP");}}}

int OnInit(){trade.SetExpertMagicNumber(Magic);g_peakEquity=AccountInfoDouble(ACCOUNT_EQUITY);g_dayKey=DayKey();hEFast=iMA(_Symbol,EntryTF,EntryFastEMA,0,MODE_EMA,PRICE_CLOSE);hESlow=iMA(_Symbol,EntryTF,EntrySlowEMA,0,MODE_EMA,PRICE_CLOSE);hRFast=iMA(_Symbol,RegimeTF,RegimeFastEMA,0,MODE_EMA,PRICE_CLOSE);hRSlow=iMA(_Symbol,RegimeTF,RegimeSlowEMA,0,MODE_EMA,PRICE_CLOSE);hADXEntry=iADX(_Symbol,EntryTF,ADXPeriod);hADXRegime=iADX(_Symbol,RegimeTF,RegimeADXPeriod);hATR=iATR(_Symbol,EntryTF,ATRPeriod);hRSI=iRSI(_Symbol,EntryTF,RSIPeriod,PRICE_CLOSE);if(hEFast<0||hESlow<0||hRFast<0||hRSlow<0||hADXEntry<0||hADXRegime<0||hATR<0||hRSI<0)return INIT_FAILED;return INIT_SUCCEEDED;}
void OnDeinit(const int reason){if(hEFast>=0)IndicatorRelease(hEFast);if(hESlow>=0)IndicatorRelease(hESlow);if(hRFast>=0)IndicatorRelease(hRFast);if(hRSlow>=0)IndicatorRelease(hRSlow);if(hADXEntry>=0)IndicatorRelease(hADXEntry);if(hADXRegime>=0)IndicatorRelease(hADXRegime);if(hATR>=0)IndicatorRelease(hATR);if(hRSI>=0)IndicatorRelease(hRSI);}
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result){if(trans.type!=TRADE_TRANSACTION_DEAL_ADD)return;ulong deal=trans.deal;if(!deal)return;if(HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol||(ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=Magic)return;long e=HistoryDealGetInteger(deal,DEAL_ENTRY);if(e!=DEAL_ENTRY_OUT&&e!=DEAL_ENTRY_OUT_BY)return;double p=HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_SWAP)+HistoryDealGetDouble(deal,DEAL_COMMISSION);if(p<0){g_consecutiveLosses++;g_cooldownUntil=TimeCurrent()+CooldownMinutes*60;}else if(p>0){g_consecutiveLosses=0;g_cooldownUntil=0;}}
void OnTick(){DailyReset();UpdatePeak();ManagePositions();if(!NewBar())return;if(MyPositions()>0&&OnePositionOnly)return;if(RiskBlocked()||!SessionOK()||!SpreadOK())return;double atr,sep,radx,vwap=0,quality=0;Direction dir=DIR_NONE;if(!Regime(dir,atr,sep,radx)||dir==DIR_NONE)return;if(!SessionVWAP(vwap))return;bool sig=false;if(dir==DIR_BUY&&AllowBuy)sig=PullbackSignal(dir,atr,vwap,quality);else if(dir==DIR_SELL&&AllowSell)sig=PullbackSignal(dir,atr,vwap,quality);if(!sig)return;Enter(dir,atr,radx,sep,quality);}
