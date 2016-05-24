#include <stdio.h>

int main () {
  int *p = 0;
  fprintf(stdout, "output\n");
  fprintf(stderr, "errput\n");
  *p = 1;
  return 0;
}
