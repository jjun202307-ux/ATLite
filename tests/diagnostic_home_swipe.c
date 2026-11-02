/* Isolated down/move/up diagnostic; does not open applications. */
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <dlfcn.h>
typedef void *Ref;
extern uint64_t mach_absolute_time(void);
int main(int argc,char **argv){
 if(argc!=2)return 64;int mode=atoi(argv[1]);if(mode<0||mode>2)return 64;
 void *io=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",2);
 void *cf=dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",2);if(!io||!cf)return 65;
 Ref(*create)(Ref)=dlsym(io,"IOHIDEventSystemClientCreate");
 Ref(*hand)(Ref,uint64_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,int,int,uint32_t)=dlsym(io,"IOHIDEventCreateDigitizerEvent");
 Ref(*finger)(Ref,uint64_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,int,int,uint32_t)=dlsym(io,"IOHIDEventCreateDigitizerFingerEvent");
 void(*append)(Ref,Ref,uint32_t)=dlsym(io,"IOHIDEventAppendEvent");void(*setInt)(Ref,uint32_t,long)=dlsym(io,"IOHIDEventSetIntegerValue");
 void(*sender)(Ref,uint64_t)=dlsym(io,"IOHIDEventSetSenderID");void(*dispatch)(Ref,Ref)=dlsym(io,"IOHIDEventSystemClientDispatchEvent");void(*release)(Ref)=dlsym(cf,"CFRelease");
 Ref(*matching)(const char *)=dlsym(io,"IOServiceMatching");uint32_t(*getService)(uint32_t,Ref)=dlsym(io,"IOServiceGetMatchingService");
 int(*registry)(uint32_t,uint64_t *)=dlsym(io,"IORegistryEntryGetRegistryEntryID");int(*releaseService)(uint32_t)=dlsym(io,"IOObjectRelease");
 if(!create||!hand||!finger||!append||!setInt||!sender||!dispatch||!release||!matching||!getService||!registry||!releaseService)return 66;
 uint64_t sid=0;Ref query=matching("AppleMultitouchDevice");uint32_t service=query?getService(0,query):0;
 if(!service||registry(service,&sid)||!sid)return 67;releaseService(service);
 Ref client=create(0);if(!client)return 68;
 for(int i=0;i<=26;i++){
  int down=i==0,up=i==26,touch=!up;double y=down?884.0/896.0:(up?0.48:(884.0/896.0+(0.48-884.0/896.0)*i/25.0));
  uint32_t cmask=down||up?3:(mode==2?4:6);
  uint32_t pmask=mode==0?2:(down||up?35:4);
  uint64_t stamp=mach_absolute_time();
  Ref p=hand(0,stamp,3,0,0,pmask,0,0,0,0,0,0,touch,touch,0);
  Ref f=finger(0,stamp,1,2,cmask,0.5,y,0,0,0,touch,touch,0);if(!p||!f)return 69;
  append(p,f,0);setInt(p,0xB0019,1);setInt(f,0xB0019,1);sender(p,sid);dispatch(client,p);release(f);release(p);
  usleep(down?80000:12000);
 }
 release(client);puts("TOUCH_DIAGNOSTIC_DISPATCHED");return 0;
}
