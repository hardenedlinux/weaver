/* Verification-only observer. Every intercepted call invokes the real dyld API. */
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
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
  return h;
}
static int observe_close(void *h) {
  pthread_mutex_lock(&lock);
  unsigned i;
  for(i=0;i<4096;i++)if(slots[i].handle==h && slots[i].refs)break;
  int tracked=i<4096;
  pthread_mutex_unlock(&lock);
  int result=dlclose(h);
  if(tracked) {
    pthread_mutex_lock(&lock);
    if(result==0){slots[i].refs--;closes++;}else errors++;
    pthread_mutex_unlock(&lock);
  }
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
}
