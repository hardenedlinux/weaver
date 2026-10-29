/* Verification-only observer. Every intercepted call invokes the real dyld API. */
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>
static uint64_t now_ns(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000000000+t.tv_nsec;}
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static uint64_t began;
static struct {char op;unsigned tracked; uint64_t start,duration;char path[1024];} events[8192];
static unsigned eventCount,eventOverflow;
__attribute__((constructor)) static void begin(void){began=now_ns();}
static void event(char op,unsigned tracked,uint64_t start,const char *path){
 uint64_t end=now_ns(); pthread_mutex_lock(&lock);
 unsigned i=eventCount++;if(i<8192){events[i].op=op;events[i].tracked=tracked;events[i].start=start-began;events[i].duration=end-start;if(path)snprintf(events[i].path,1024,"%s",path);}else eventOverflow++;pthread_mutex_unlock(&lock);
}

static struct { void *handle; unsigned refs; } slots[4096];
static unsigned opens,closes,errors,overflow,peakImages;
static int module_path(const char *p) {
  if(!p)return 0;
  const char *dot=strrchr(p,'.');
  if(!dot || dot[1]!='o' || dot[2]<'0' || dot[2]>'9')return 0;
  for(const char *s=dot+2;*s;s++)if(*s<'0'||*s>'9')return 0;
  return 1;
}
static void *observe_open(const char *path,int flags) {
  uint64_t start=now_ns();
  void *h=dlopen(path,flags);
  if(h && module_path(path)) {
    unsigned images=_dyld_image_count();
    pthread_mutex_lock(&lock);
    unsigned i;
    for(i=0;i<4096;i++)if(slots[i].handle==h || !slots[i].handle)break;
    if(i==4096)overflow++;
    else {slots[i].handle=h;slots[i].refs++;opens++;}
    if(images>peakImages)peakImages=images;
    pthread_mutex_unlock(&lock);
  }
  event('L',h && module_path(path),start,path);
  return h;
}
static int observe_close(void *h) {
  pthread_mutex_lock(&lock);
  unsigned i;
  for(i=0;i<4096;i++)if(slots[i].handle==h && slots[i].refs)break;
  int tracked=i<4096;
  pthread_mutex_unlock(&lock);
  uint64_t start=now_ns();
  int result=dlclose(h);
  if(tracked) {
    pthread_mutex_lock(&lock);
    if(result==0){slots[i].refs--;closes++;}else errors++;
    pthread_mutex_unlock(&lock);
  }
  event('U',tracked,start,NULL);
  return result;
}
__attribute__((used)) static struct {const void *replacement;const void *original;}
interpose[] __attribute__((section("__DATA,__interpose")))={
 {(const void*)observe_open,(const void*)dlopen},
 {(const void*)observe_close,(const void*)dlclose}
};
__attribute__((destructor)) static void report(void) {
  const char *path=getenv("WEAVER_MODULE_CLEANUP_TRACE");if(!path)return;
  unsigned outstanding=0;
  for(unsigned i=0;i<4096;i++)outstanding+=slots[i].refs;
  FILE *f=fopen(path,"w");if(!f)return;
  fprintf(f,"{\"moduleOpens\":%u,\"moduleCloses\":%u,\"outstandingModuleRefs\":%u,\"closeErrors\":%u,\"overflow\":%u,\"peakDyldImages\":%u}\n",opens,closes,outstanding,errors,overflow,peakImages);
  fclose(f);
  const char *timeline=getenv("WEAVER_DYLD_TIMELINE");if(!timeline)return;f=fopen(timeline,"w");if(!f)return;
  fprintf(f,"op\ttracked\tstart_ns\tduration_ns\tpath\n");
  for(unsigned i=0;i<eventCount && i<8192;i++)fprintf(f,"%c\t%u\t%llu\t%llu\t%s\n",events[i].op,events[i].tracked,(unsigned long long)events[i].start,(unsigned long long)events[i].duration,events[i].path);
  fprintf(f,"# eventOverflow=%u\n",eventOverflow);fclose(f);
}
