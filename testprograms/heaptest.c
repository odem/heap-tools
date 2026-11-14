#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(void) {
    void *a = malloc(0x20);
    void *b = malloc(0x100);
    void *c = malloc(0x20);
    fprintf(stderr, "a=%p b=%p c=%p\n", a, b, c);
    free(b);
    free(a);
    free(c);
    return 0;
}
