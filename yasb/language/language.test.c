/*
 * Tests for language.c's formatting. Run by scripts\Test-Windots.ps1, or by
 * hand:
 *   gcc -Wall -o language.test.exe language.test.c && language.test.exe
 */
#define main language_main
#include "language.c"
#undef main

static int failures;

#define CHECK_LAYOUT(layout, expected) check_layout(__LINE__, (HKL)(ULONG_PTR)(layout), expected)
static void check_layout(int line, HKL layout, const char *expected) {
    char json[192];
    describe(layout, json, sizeof json);
    if (strcmp(json, expected) == 0) return;
    printf("language.test.c:%d: got  %s\n                   want %s\n", line, json, expected);
    failures++;
}

int main(void) {
    /* Low word is the language; the high word (device/layout) is ignored. */
    CHECK_LAYOUT(0x04090409, "{\"code\": \"en\", \"name\": \"English (United States)\"}");
    CHECK_LAYOUT(0x04190419, "{\"code\": \"ru\", \"name\": \"Russian (Russia)\"}");
    CHECK_LAYOUT(0xF0020409, "{\"code\": \"en\", \"name\": \"English (United States)\"}");
    return failures != 0;
}
