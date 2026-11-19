#include <stdio.h>
#include "iec_types_all.h"
TIME __CURRENT_TIME;
BOOL __DEBUG;
#define __LOCATED_VAR(type, name, ...) type __v##name;
#include "LOCATED_VARIABLES.h"
#undef __LOCATED_VAR
#define __LOCATED_VAR(type, name, ...) type* name = &__v##name;
#include "LOCATED_VARIABLES.h"
#undef __LOCATED_VAR
void config_init__(void); void config_run__(unsigned long tick);
static unsigned long T = 0;
static void tick(int n) { while (n--) { __CURRENT_TIME.tv_nsec += 20000000; if (__CURRENT_TIME.tv_nsec >= 1000000000) { __CURRENT_TIME.tv_nsec -= 1000000000; __CURRENT_TIME.tv_sec++; } config_run__(T++); } }
#define IN(a) (*a)
#define PULSE(a) do { *a = 1; tick(1); *a = 0; tick(1); } while (0)
static int fails = 0;
#define CHECK(name, cond) do { int ok = (cond); printf("%-58s %s\n", name, ok ? "PASS" : "FAIL"); if (!ok) fails++; } while (0)
int main(void) {
  config_init__();
  *__IX0_3 = 1;          /* E-stop healthy */
  *__IW4 = 323;          /* today = day 323 (Nov 19) */
  tick(2);
  CHECK("Stopped at power-up, amber light", !*__QX0_0 && *__QX3_6);
  PULSE(__IX0_0);        /* Start */
  CHECK("Start PB: line A motor + green stack light on", *__QX0_0 && *__QX3_5);
  tick(5); CHECK("Seal-in keeps it running after Start is released", *__QX0_0);

  /* ---- good package, line A, route door 1 ---- */
  PULSE(__IX0_4);
  CHECK("Tunnel A lights on while scanning", *__QX0_7);
  *__IX1_0 = 1; *__IW0 = 1; *__IW1 = 323; PULSE(__IX0_6);
  CHECK("Tunnel A lights off after scan done", !*__QX0_7);
  PULSE(__IX1_2); tick(3);
  CHECK("Good label: gate does NOT divert", !*__QX1_1);
  *__IX1_4 = 1; tick(5); *__IX1_4 = 0; tick(2);   /* crosses the merge */
  PULSE(__IX1_6);                                   /* enters sorter */
  int fired = 0, at = 0;
  for (int p = 1; p <= 200 && !fired; p++) { PULSE(__IX1_7); if (*__QX1_3) { fired = 1; at = p; } }
  CHECK("Encoder tracking fires Shoe_D1 at 950 cm (190 pulses)", fired && at == 190);
  tick(20); CHECK("Shoe retracts after ~0.36 s", !*__QX1_3);
  *__IW5 = 1; *__IX2_0 = 1; tick(1);
  CHECK("Door 1 scanner, route 1: green lamp", *__QX2_1);
  CHECK("Count_D1 = 1 and Count_Total = 1", *__MW0 == 1 && *__MW6 == 1);
  *__IX2_0 = 0; tick(2);

  /* ---- old label on line A ---- */
  PULSE(__IX0_4); *__IW1 = 322; PULSE(__IX0_6);
  CHECK("Old label (day 322 vs 323): Count_Stale = 1", *__MW7 == 1);
  PULSE(__IX1_2);
  CHECK("Gate A diverter fires for the old label", *__QX1_1);
  tick(30); CHECK("Diverter drops after ~0.5 s", !*__QX1_1);

  /* ---- no read ---- */
  PULSE(__IX0_4); *__IX1_0 = 0; PULSE(__IX0_6); PULSE(__IX1_2);
  CHECK("No read: Count_NoRead = 1 and diverter fires", *__MW8 == 1 && *__QX1_1);
  *__IX1_0 = 1; tick(30);

  /* ---- wrong truck at door 1 ---- */
  *__IW5 = 4; *__IX2_0 = 1; tick(1);
  CHECK("Door 1 scanner reads route 4: Count_WrongDoor = 1", *__MW9 == 1 && !*__QX2_1);
  int red_on = 0, red_off = 0; for (int t = 0; t < 60; t++) { tick(1); if (*__QX2_7) red_on++; else red_off++; }
  CHECK("Red door lamp flashes while held", red_on > 10 && red_off > 10);
  *__IX2_0 = 0; tick(3); CHECK("Operator pulls it: red lamp clears", !*__QX2_7);

  /* ---- relabel station A ---- */
  *__IX2_6 = 1; tick(2);
  CHECK("Package at relabel station: belt waits", !*__QX0_3);
  PULSE(__IX3_0);
  CHECK("Operator Done PB: belt moves, Count_Relabeled = 1", *__QX0_3 && *__MW10 == 1);
  *__IX2_6 = 0; tick(2);

  /* ---- return belt re-induct ---- */
  *__IX3_2 = 1; *__IX3_4 = 1; tick(5);
  CHECK("Return belt waits while line A join eye is blocked", !*__QX0_5);
  *__IX3_4 = 0; tick(20);
  CHECK("Still waits until the gap is 0.6 s", !*__QX0_5);
  tick(15);
  CHECK("Gap found: return belt slides package back on", *__QX0_5);
  *__IX3_2 = 0; tick(2);
  CHECK("Count_Reinducted = 1", *__MW11 == 1);

  /* ---- jam at merge A ---- */
  *__IX1_4 = 1; tick(140);
  CHECK("Merge eye blocked 2.8 s: still running", *__QX0_0);
  tick(20);
  CHECK("Blocked 3 s: jam fault stops the line, Jam_Zone = 1", !*__QX0_0 && *__MW14 == 1);
  PULSE(__IX0_0);
  CHECK("Start PB ignored while jam fault is active", !*__QX0_0);
  int sr = 0; for (int t = 0; t < 60; t++) { tick(1); if (*__QX3_7) sr++; } CHECK("Red stack light flashing", sr > 10 && sr < 50);
  *__IX1_4 = 0; PULSE(__IX0_2); PULSE(__IX0_0);
  CHECK("Clear jam, Reset, Start: running again", *__QX0_0 && *__MW14 == 0);

  /* ---- E-stop ---- */
  *__IX0_3 = 0; tick(1);
  CHECK("E-stop opened: everything stops", !*__QX0_0 && !*__QX0_2);
  *__IX0_3 = 1; tick(2);
  CHECK("E-stop reset: stays stopped until Start (no auto-restart)", !*__QX0_0);
  printf("\n%d failed\n", fails);
  return fails;
}
