/*
 * Tests for brightness.c's transition rule. Needs no brightness hardware. Run
 * by scripts\Test-Windots.ps1, or by hand:
 *   gcc -Wall -o brightness.test.exe brightness.test.c && brightness.test.exe
 */
#include <stdio.h>
#define main brightness_main
#include "brightness.c"
#undef main

static int failures;

static void check(int line, int ok) {
    if (ok) return;
    printf("brightness.test.c:%d: failed\n", line);
    failures++;
}

int main(void) {
    check(__LINE__, should_turn_off(60, 0));
    check(__LINE__, should_turn_off(1, 0));
    check(__LINE__, !should_turn_off(0, 0));
    check(__LINE__, !should_turn_off(-1, 0));
    check(__LINE__, !should_turn_off(0, 30));
    check(__LINE__, !should_turn_off(60, 1));
    /* First reading after start (previous = -1) only sets the baseline. */
    check(__LINE__, !should_turn_off(-1, 0));

    check(__LINE__, should_turn_on(0, 1));
    check(__LINE__, should_turn_on(0, 60));
    check(__LINE__, !should_turn_on(0, 0));
    check(__LINE__, !should_turn_on(30, 60));
    check(__LINE__, !should_turn_on(60, 0));
    /* Starting at a nonzero level must not wake or blank anything. */
    check(__LINE__, !should_turn_on(-1, 50));

    check(__LINE__, should_sleep_again(0, 1));
    check(__LINE__, should_sleep_again(0, 2));
    check(__LINE__, !should_sleep_again(0, 0));  /* already off */
    check(__LINE__, !should_sleep_again(30, 1)); /* normal wake */
    check(__LINE__, !should_sleep_again(-1, 1)); /* brightness not known yet */
    return failures != 0;
}
