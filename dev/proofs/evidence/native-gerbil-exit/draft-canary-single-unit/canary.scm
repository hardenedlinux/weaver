(c-declare #<<END_C
#include <stdio.h>
#include <stdlib.h>
static void weaver_canary_event(char event) {
  const char *path = getenv("WEAVER_NATIVE_CANARY_LOG");
  if (path != NULL) {
    FILE *file = fopen(path, "a");
    if (file != NULL) { fputc(event, file); fclose(file); }
  }
}
__attribute__((constructor)) static void weaver_canary_load(void) { weaver_canary_event('L'); }
__attribute__((destructor)) static void weaver_canary_unload(void) { weaver_canary_event('U'); }
END_C
)
(display "NATIVE-DYNAMIC-CANARY-LOADED\n")
