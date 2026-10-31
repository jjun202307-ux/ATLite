typedef void *id;
typedef void *SEL;
extern id objc_getClass(const char *);
extern SEL sel_registerName(const char *);
extern void objc_msgSend(void);
extern void *dlopen(const char *, int);
extern int printf(const char *, ...);
static id send0(id o,const char *s) { return ((id(*)(id,SEL))objc_msgSend)(o,sel_registerName(s)); }
static id send1(id o,const char *s,id a) { return ((id(*)(id,SEL,id))objc_msgSend)(o,sel_registerName(s),a); }
static id str(const char *s) { return send1(objc_getClass("NSString"),"stringWithUTF8String:",(id)s); }
int main(int argc,char **argv) {
 if(argc<3)return 64;
 dlopen("/System/Library/Frameworks/Foundation.framework/Foundation",2);
 dlopen("/System/Library/Frameworks/Vision.framework/Vision",2);
 id pool=send0(objc_getClass("NSAutoreleasePool"),"new");
 id url=send1(objc_getClass("NSURL"),"fileURLWithPath:",str(argv[2]));
 id handler=((id(*)(id,SEL,id,id))objc_msgSend)(send0(objc_getClass("VNImageRequestHandler"),"alloc"),sel_registerName("initWithURL:options:"),url,(id)0);
 id req=send0(objc_getClass("VNRecognizeTextRequest"),"new");
 ((void(*)(id,SEL,unsigned long))objc_msgSend)(req,sel_registerName("setRecognitionLevel:"),(argv[1][0]=='2'||argv[1][0]=='3')?1:0);
 id items[2]={str("zh-Hans"),str("en-US")};
 unsigned long languageCount=2;
 if(argc>3 && argv[3][0]=='e'){items[0]=str("en-US");languageCount=1;}
 if(argc>3 && argv[3][0]=='z'){languageCount=1;}
 id langs=((id(*)(id,SEL,const id*,unsigned long))objc_msgSend)(objc_getClass("NSArray"),sel_registerName("arrayWithObjects:count:"),items,languageCount);
 send1(req,"setRecognitionLanguages:",langs);
 ((void(*)(id,SEL,unsigned char))objc_msgSend)(req,sel_registerName("setUsesLanguageCorrection:"),0);
 if(argv[1][0]=='4'||argv[1][0]=='6')((void(*)(id,SEL,unsigned long))objc_msgSend)(req,sel_registerName("setRevision:"),2);
 if(argv[1][0]=='1' || argv[1][0]=='3'||argv[1][0]=='6')((void(*)(id,SEL,unsigned char))objc_msgSend)(req,sel_registerName("setUsesCPUOnly:"),1);
 id languageError=0; id supported=((id(*)(id,SEL,id*))objc_msgSend)(req,sel_registerName("supportedRecognitionLanguagesAndReturnError:"),&languageError);
 printf("revision=%lu supported=%s\n",((unsigned long(*)(id,SEL))objc_msgSend)(req,sel_registerName("revision")),supported ? (const char*)send0(send0(supported,"description"),"UTF8String") : "unavailable");
 id requests=send1(objc_getClass("NSArray"),"arrayWithObject:",req),error=0;
 unsigned char ok=((unsigned char(*)(id,SEL,id,id*))objc_msgSend)(handler,sel_registerName("performRequests:error:"),requests,&error);
 printf("cpu=%c ok=%u error=%s\n",argv[1][0],ok,error ? (const char*)send0(send0(error,"description"),"UTF8String") : "none");
 id results=send0(req,"results");
 unsigned long n=((unsigned long(*)(id,SEL))objc_msgSend)(results,sel_registerName("count"));
 for(unsigned long i=0;i<n;i++) {
  id ob=((id(*)(id,SEL,unsigned long))objc_msgSend)(results,sel_registerName("objectAtIndex:"),i);
  id cand=((id(*)(id,SEL,unsigned long))objc_msgSend)(ob,sel_registerName("topCandidates:"),1);
  id txt=send0(send0(cand,"firstObject"),"string");
  printf("text=%s\n",(const char*)send0(txt,"UTF8String"));
 }
 send0(pool,"drain");return ok?0:1;
}
