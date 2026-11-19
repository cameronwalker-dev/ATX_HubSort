(* =====================================================================
   ATX HubSort - PLC program (IEC 61131-3 Structured Text, OpenPLC)
   Version 3.0  -  upgrade of PackageSorterV2

   What this program runs:
     - 2 induction lines (A and B), each with a 6-sided scan tunnel
     - Label check gate on each line: old label or no read -> relabel loop
     - Relabel station + return belt that re-inducts packages so they
       get scanned again before they can reach a truck
     - Merge with a 3 s jam watchdog (fault, stop, reset)
     - Shoe sorter with encoder position tracking to 6 doors
     - Door confirm scanner: right truck = green, wrong truck = red hold
     - E-stop, start/stop seal-in, stack light
     - Counters in %MW for the edge gateway (Modbus TCP -> MQTT -> AWS)

   Scan time: 20 ms task. Counts like "25 scans" = 25 x 20 ms = 0.5 s.
   Line B mirrors line A. Doors 2-6 mirror door 1.
   Tag names use Allen-Bradley style so they port to Studio 5000.
   ===================================================================== *)

PROGRAM ATX_HubSort
  VAR
    (* ---------------- INPUTS: buttons + safety ---------------- *)
    Start_PB          AT %IX0.0 : BOOL;
    Stop_PB           AT %IX0.1 : BOOL;
    Reset_PB          AT %IX0.2 : BOOL;
    EStop_OK          AT %IX0.3 : BOOL;   (* 1 = E-stop circuit healthy *)

    (* ---------------- INPUTS: scan tunnels ---------------- *)
    PE_A_TunnelEntry  AT %IX0.4 : BOOL;
    PE_B_TunnelEntry  AT %IX0.5 : BOOL;
    Scan_A_Done       AT %IX0.6 : BOOL;   (* tunnel finished reading *)
    Scan_B_Done       AT %IX0.7 : BOOL;
    Scan_A_ReadOK     AT %IX1.0 : BOOL;   (* 1 = barcode was read *)
    Scan_B_ReadOK     AT %IX1.1 : BOOL;

    (* ---------------- INPUTS: gates, merge, sorter ---------------- *)
    PE_A_Gate         AT %IX1.2 : BOOL;   (* photo-eye at label check gate *)
    PE_B_Gate         AT %IX1.3 : BOOL;
    PE_A_Merge        AT %IX1.4 : BOOL;   (* photo-eye at the merge *)
    PE_B_Merge        AT %IX1.5 : BOOL;
    PE_Sort_Induct    AT %IX1.6 : BOOL;   (* package enters the sorter *)
    Enc_Pulse         AT %IX1.7 : BOOL;   (* 1 pulse = 5 cm of sorter travel *)

    (* ---------------- INPUTS: door confirm scanners ---------------- *)
    PE_D1_LoadScan    AT %IX2.0 : BOOL;   (* eye under the door scanner *)
    PE_D2_LoadScan    AT %IX2.1 : BOOL;
    PE_D3_LoadScan    AT %IX2.2 : BOOL;
    PE_D4_LoadScan    AT %IX2.3 : BOOL;
    PE_D5_LoadScan    AT %IX2.4 : BOOL;
    PE_D6_LoadScan    AT %IX2.5 : BOOL;

    (* ---------------- INPUTS: relabel loop ---------------- *)
    PE_A_Station      AT %IX2.6 : BOOL;   (* package waiting at relabel station *)
    PE_B_Station      AT %IX2.7 : BOOL;
    Relabel_A_Done_PB AT %IX3.0 : BOOL;   (* operator: new label is on *)
    Relabel_B_Done_PB AT %IX3.1 : BOOL;
    PE_A_RetEnd       AT %IX3.2 : BOOL;   (* end of the return belt *)
    PE_B_RetEnd       AT %IX3.3 : BOOL;
    PE_A_Join         AT %IX3.4 : BOOL;   (* line A eye where packages re-join *)
    PE_B_Join         AT %IX3.5 : BOOL;

    (* ---------------- INPUT WORDS: scanner data ---------------- *)
    Scan_A_Route      AT %IW0 : INT;      (* door 1-6 for the route on the label *)
    Scan_A_LabelDay   AT %IW1 : INT;      (* day of year printed on the label *)
    Scan_B_Route      AT %IW2 : INT;
    Scan_B_LabelDay   AT %IW3 : INT;
    Today_Day         AT %IW4 : INT;      (* day of year, written by the edge gateway *)
    LoadScan_D1_Route AT %IW5 : INT;      (* route read by the door scanner *)
    LoadScan_D2_Route AT %IW6 : INT;
    LoadScan_D3_Route AT %IW7 : INT;
    LoadScan_D4_Route AT %IW8 : INT;
    LoadScan_D5_Route AT %IW9 : INT;
    LoadScan_D6_Route AT %IW10 : INT;

    (* ---------------- OUTPUTS: motors ---------------- *)
    Conv_A_Motor      AT %QX0.0 : BOOL;
    Conv_B_Motor      AT %QX0.1 : BOOL;
    Sorter_Motor      AT %QX0.2 : BOOL;
    Relabel_A_Motor   AT %QX0.3 : BOOL;
    Relabel_B_Motor   AT %QX0.4 : BOOL;
    Return_A_Motor    AT %QX0.5 : BOOL;
    Return_B_Motor    AT %QX0.6 : BOOL;

    (* ---------------- OUTPUTS: tunnels + diverters ---------------- *)
    Tunnel_A_Lights   AT %QX0.7 : BOOL;
    Tunnel_B_Lights   AT %QX1.0 : BOOL;
    Div_A_Exception   AT %QX1.1 : BOOL;   (* pop-up diverter to relabel loop *)
    Div_B_Exception   AT %QX1.2 : BOOL;

    (* ---------------- OUTPUTS: sorter shoes ---------------- *)
    Shoe_D1           AT %QX1.3 : BOOL;
    Shoe_D2           AT %QX1.4 : BOOL;
    Shoe_D3           AT %QX1.5 : BOOL;
    Shoe_D4           AT %QX1.6 : BOOL;
    Shoe_D5           AT %QX1.7 : BOOL;
    Shoe_D6           AT %QX2.0 : BOOL;

    (* ---------------- OUTPUTS: door lamps ---------------- *)
    Lamp_Green_D1     AT %QX2.1 : BOOL;
    Lamp_Green_D2     AT %QX2.2 : BOOL;
    Lamp_Green_D3     AT %QX2.3 : BOOL;
    Lamp_Green_D4     AT %QX2.4 : BOOL;
    Lamp_Green_D5     AT %QX2.5 : BOOL;
    Lamp_Green_D6     AT %QX2.6 : BOOL;
    Lamp_Red_D1       AT %QX2.7 : BOOL;
    Lamp_Red_D2       AT %QX3.0 : BOOL;
    Lamp_Red_D3       AT %QX3.1 : BOOL;
    Lamp_Red_D4       AT %QX3.2 : BOOL;
    Lamp_Red_D5       AT %QX3.3 : BOOL;
    Lamp_Red_D6       AT %QX3.4 : BOOL;

    (* ---------------- OUTPUTS: stack light + beacons ---------------- *)
    Stack_Green       AT %QX3.5 : BOOL;
    Stack_Amber       AT %QX3.6 : BOOL;
    Stack_Red         AT %QX3.7 : BOOL;
    Gate_Beacon_A     AT %QX4.0 : BOOL;
    Gate_Beacon_B     AT %QX4.1 : BOOL;

    (* ---------------- MEMORY: read by the edge gateway ---------------- *)
    Count_D1          AT %MW0 : INT;
    Count_D2          AT %MW1 : INT;
    Count_D3          AT %MW2 : INT;
    Count_D4          AT %MW3 : INT;
    Count_D5          AT %MW4 : INT;
    Count_D6          AT %MW5 : INT;
    Count_Total       AT %MW6 : INT;      (* loaded on the right truck *)
    Count_Stale       AT %MW7 : INT;      (* old labels caught *)
    Count_NoRead      AT %MW8 : INT;
    Count_WrongDoor   AT %MW9 : INT;      (* wrong truck caught at the door *)
    Count_Relabeled   AT %MW10 : INT;
    Count_Reinducted  AT %MW11 : INT;
    Count_NoSort      AT %MW12 : INT;
    Status_Word       AT %MW13 : INT;     (* bit0 run, bit1 jam, bit2 E-stop, bit3 relabel busy *)
    Jam_Zone          AT %MW14 : INT;     (* 1 = merge A, 2 = merge B *)
  END_VAR

  VAR
    System_Run         : BOOL;
    Jam_Fault          : BOOL;
    Blink              : BOOL;
    Scanning_A         : BOOL;
    Scanning_B         : BOOL;
    Label_A_Stale      : BOOL;
    Label_B_Stale      : BOOL;
    Exc_Route_A        : BOOL;
    Exc_Route_B        : BOOL;
    Merge_A_Hold       : BOOL;
    Merge_B_Hold       : BOOL;
    Relabel_A_Released : BOOL;
    Relabel_B_Released : BOOL;
    Placed             : BOOL;

    (* FIFOs remember each package between two photo-eyes.
       Code 1-6 = door number, -1 = send to relabel loop, 0 = unknown *)
    FifoA_Gate    : ARRAY[0..7] OF INT;
    FifoA_Gate_N  : INT;
    FifoB_Gate    : ARRAY[0..7] OF INT;
    FifoB_Gate_N  : INT;
    FifoA_Merge   : ARRAY[0..7] OF INT;
    FifoA_Merge_N : INT;
    FifoB_Merge   : ARRAY[0..7] OF INT;
    FifoB_Merge_N : INT;
    Fifo_Sort     : ARRAY[0..15] OF INT;
    Fifo_Sort_N   : INT;

    (* sorter tracking table: up to 12 packages on the sorter at once *)
    Trk_Active : ARRAY[1..12] OF BOOL;
    Trk_Door   : ARRAY[1..12] OF INT;
    Trk_Pos    : ARRAY[1..12] OF INT;     (* cm from the induct eye *)
    Door_Pos   : ARRAY[1..6] OF INT := [950, 1850, 2750, 950, 1850, 2750];
    End_Pos    : INT := 4150;

    Door_Hit   : ARRAY[1..6] OF BOOL;
    Shoe_Cnt   : ARRAY[1..6] OF INT;
    Green_Cnt  : ARRAY[1..6] OF INT;
    WrongHold  : ARRAY[1..6] OF BOOL;
    LS_Eye     : ARRAY[1..6] OF BOOL;
    LS_Rise    : ARRAY[1..6] OF BOOL;
    LS_Route   : ARRAY[1..6] OF INT;
    DivA_Cnt   : INT;
    DivB_Cnt   : INT;
    Code       : INT;
    i          : INT;
    k          : INT;

    (* edge detectors (R_TRIG = ONS in Allen-Bradley) and timers *)
    EntryA_OS  : R_TRIG;
    EntryB_OS  : R_TRIG;
    ScanA_OS   : R_TRIG;
    ScanB_OS   : R_TRIG;
    GateA_OS   : R_TRIG;
    GateB_OS   : R_TRIG;
    Induct_OS  : R_TRIG;
    Enc_OS     : R_TRIG;
    RelA_OS    : R_TRIG;
    RelB_OS    : R_TRIG;
    LS1_OS     : R_TRIG;
    LS2_OS     : R_TRIG;
    LS3_OS     : R_TRIG;
    LS4_OS     : R_TRIG;
    LS5_OS     : R_TRIG;
    LS6_OS     : R_TRIG;
    MergeA_FT  : F_TRIG;
    MergeB_FT  : F_TRIG;
    RetA_FT    : F_TRIG;
    RetB_FT    : F_TRIG;
    Jam_Tmr_A    : TON;
    Jam_Tmr_B    : TON;
    Join_A_Clear : TON;
    Join_B_Clear : TON;
    Blink_TON    : TON;
  END_VAR

  (* ===== Rung 1 - Reset clears faults (only while stopped) ===== *)
  IF Reset_PB AND NOT System_Run THEN
    Jam_Fault := FALSE;
    Jam_Zone := 0;
    FOR i := 1 TO 6 DO
      WrongHold[i] := FALSE;
    END_FOR;
  END_IF;

  (* ===== Rung 2 - Start/stop seal-in: runs only if E-stop is OK and no jam ===== *)
  System_Run := (Start_PB OR System_Run) AND NOT Stop_PB AND EStop_OK AND NOT Jam_Fault;

  (* blink bit for flashing lamps (0.4 s on / 0.4 s off) *)
  Blink_TON(IN := NOT Blink_TON.Q, PT := T#400ms);
  IF Blink_TON.Q THEN
    Blink := NOT Blink;
  END_IF;

  (* ===== Rungs 3-5 - Scan tunnel A: lights, old-label check, decision ===== *)
  EntryA_OS(CLK := PE_A_TunnelEntry);
  IF EntryA_OS.Q THEN
    Scanning_A := TRUE;
  END_IF;
  ScanA_OS(CLK := Scan_A_Done);
  IF ScanA_OS.Q THEN
    Scanning_A := FALSE;
    (* old label: it read fine, but the day on the label is not today *)
    Label_A_Stale := Scan_A_ReadOK AND (Scan_A_LabelDay <> Today_Day);
    Exc_Route_A := (NOT Scan_A_ReadOK) OR Label_A_Stale;
    IF NOT Scan_A_ReadOK THEN
      Count_NoRead := Count_NoRead + 1;
    END_IF;
    IF Label_A_Stale THEN
      Count_Stale := Count_Stale + 1;
    END_IF;
    IF Exc_Route_A OR (Scan_A_Route < 1) OR (Scan_A_Route > 6) THEN
      Code := -1;
    ELSE
      Code := Scan_A_Route;
    END_IF;
    IF FifoA_Gate_N < 8 THEN
      FifoA_Gate[FifoA_Gate_N] := Code;
      FifoA_Gate_N := FifoA_Gate_N + 1;
    END_IF;
  END_IF;
  Tunnel_A_Lights := System_Run AND Scanning_A;

  (* ===== Scan tunnel B (mirrors A) ===== *)
  EntryB_OS(CLK := PE_B_TunnelEntry);
  IF EntryB_OS.Q THEN
    Scanning_B := TRUE;
  END_IF;
  ScanB_OS(CLK := Scan_B_Done);
  IF ScanB_OS.Q THEN
    Scanning_B := FALSE;
    Label_B_Stale := Scan_B_ReadOK AND (Scan_B_LabelDay <> Today_Day);
    Exc_Route_B := (NOT Scan_B_ReadOK) OR Label_B_Stale;
    IF NOT Scan_B_ReadOK THEN
      Count_NoRead := Count_NoRead + 1;
    END_IF;
    IF Label_B_Stale THEN
      Count_Stale := Count_Stale + 1;
    END_IF;
    IF Exc_Route_B OR (Scan_B_Route < 1) OR (Scan_B_Route > 6) THEN
      Code := -1;
    ELSE
      Code := Scan_B_Route;
    END_IF;
    IF FifoB_Gate_N < 8 THEN
      FifoB_Gate[FifoB_Gate_N] := Code;
      FifoB_Gate_N := FifoB_Gate_N + 1;
    END_IF;
  END_IF;
  Tunnel_B_Lights := System_Run AND Scanning_B;

  (* ===== Rungs 6-7 - Label check gate A: exceptions go to the relabel loop ===== *)
  GateA_OS(CLK := PE_A_Gate);
  IF GateA_OS.Q AND (FifoA_Gate_N > 0) THEN
    Code := FifoA_Gate[0];
    FOR k := 0 TO 6 DO
      FifoA_Gate[k] := FifoA_Gate[k + 1];
    END_FOR;
    FifoA_Gate_N := FifoA_Gate_N - 1;
    IF Code < 0 THEN
      DivA_Cnt := 25;                        (* fire diverter 0.5 s *)
    ELSIF FifoA_Merge_N < 8 THEN
      FifoA_Merge[FifoA_Merge_N] := Code;    (* good package rides on to the merge *)
      FifoA_Merge_N := FifoA_Merge_N + 1;
    END_IF;
  END_IF;
  IF DivA_Cnt > 0 THEN
    DivA_Cnt := DivA_Cnt - 1;
  END_IF;
  Div_A_Exception := DivA_Cnt > 0;
  Gate_Beacon_A := Div_A_Exception;

  (* ===== Label check gate B (mirrors A) ===== *)
  GateB_OS(CLK := PE_B_Gate);
  IF GateB_OS.Q AND (FifoB_Gate_N > 0) THEN
    Code := FifoB_Gate[0];
    FOR k := 0 TO 6 DO
      FifoB_Gate[k] := FifoB_Gate[k + 1];
    END_FOR;
    FifoB_Gate_N := FifoB_Gate_N - 1;
    IF Code < 0 THEN
      DivB_Cnt := 25;
    ELSIF FifoB_Merge_N < 8 THEN
      FifoB_Merge[FifoB_Merge_N] := Code;
      FifoB_Merge_N := FifoB_Merge_N + 1;
    END_IF;
  END_IF;
  IF DivB_Cnt > 0 THEN
    DivB_Cnt := DivB_Cnt - 1;
  END_IF;
  Div_B_Exception := DivB_Cnt > 0;
  Gate_Beacon_B := Div_B_Exception;

  (* ===== Merge: line A has priority, line B waits if both arrive ===== *)
  Merge_A_Hold := FALSE;
  Merge_B_Hold := PE_A_Merge AND PE_B_Merge;
  Conv_A_Motor := System_Run AND NOT Merge_A_Hold;
  Conv_B_Motor := System_Run AND NOT Merge_B_Hold;

  (* package clears the merge eye: pass its door number to the sorter *)
  MergeA_FT(CLK := PE_A_Merge);
  IF MergeA_FT.Q AND (FifoA_Merge_N > 0) THEN
    Code := FifoA_Merge[0];
    FOR k := 0 TO 6 DO
      FifoA_Merge[k] := FifoA_Merge[k + 1];
    END_FOR;
    FifoA_Merge_N := FifoA_Merge_N - 1;
    IF Fifo_Sort_N < 16 THEN
      Fifo_Sort[Fifo_Sort_N] := Code;
      Fifo_Sort_N := Fifo_Sort_N + 1;
    END_IF;
  END_IF;
  MergeB_FT(CLK := PE_B_Merge);
  IF MergeB_FT.Q AND (FifoB_Merge_N > 0) THEN
    Code := FifoB_Merge[0];
    FOR k := 0 TO 6 DO
      FifoB_Merge[k] := FifoB_Merge[k + 1];
    END_FOR;
    FifoB_Merge_N := FifoB_Merge_N - 1;
    IF Fifo_Sort_N < 16 THEN
      Fifo_Sort[Fifo_Sort_N] := Code;
      Fifo_Sort_N := Fifo_Sort_N + 1;
    END_IF;
  END_IF;

  (* ===== Rungs 8-9 - Jam watchdog: merge eye blocked 3 s while running ===== *)
  Jam_Tmr_A(IN := System_Run AND PE_A_Merge AND NOT Merge_A_Hold, PT := T#3s);
  Jam_Tmr_B(IN := System_Run AND PE_B_Merge AND NOT Merge_B_Hold, PT := T#3s);
  IF Jam_Tmr_A.Q THEN
    Jam_Fault := TRUE;
    Jam_Zone := 1;
  END_IF;
  IF Jam_Tmr_B.Q THEN
    Jam_Fault := TRUE;
    Jam_Zone := 2;
  END_IF;

  (* ===== Sorter: start tracking each package at the induct eye ===== *)
  Sorter_Motor := System_Run;
  Induct_OS(CLK := PE_Sort_Induct);
  IF Induct_OS.Q AND System_Run THEN
    IF Fifo_Sort_N > 0 THEN
      Code := Fifo_Sort[0];
      FOR k := 0 TO 14 DO
        Fifo_Sort[k] := Fifo_Sort[k + 1];
      END_FOR;
      Fifo_Sort_N := Fifo_Sort_N - 1;
    ELSE
      Code := 0;                             (* unknown: rides to no-sort *)
    END_IF;
    Placed := FALSE;
    FOR i := 1 TO 12 DO
      IF NOT Placed AND NOT Trk_Active[i] THEN
        Trk_Active[i] := TRUE;
        Trk_Door[i] := Code;
        Trk_Pos[i] := 0;
        Placed := TRUE;
      END_IF;
    END_FOR;
  END_IF;

  (* ===== Rung 10 - Encoder moves every package; fire shoes at its door ===== *)
  FOR i := 1 TO 6 DO
    Door_Hit[i] := FALSE;
  END_FOR;
  Enc_OS(CLK := Enc_Pulse);
  IF Enc_OS.Q THEN
    FOR i := 1 TO 12 DO
      IF Trk_Active[i] THEN
        Trk_Pos[i] := Trk_Pos[i] + 5;
        IF (Trk_Door[i] >= 1) AND (Trk_Door[i] <= 6) THEN
          IF Trk_Pos[i] >= Door_Pos[Trk_Door[i]] THEN
            Door_Hit[Trk_Door[i]] := TRUE;
            Trk_Active[i] := FALSE;
          END_IF;
        ELSIF Trk_Pos[i] >= End_Pos THEN
          Count_NoSort := Count_NoSort + 1;
          Trk_Active[i] := FALSE;
        END_IF;
      END_IF;
    END_FOR;
  END_IF;
  FOR i := 1 TO 6 DO
    IF Door_Hit[i] AND System_Run THEN
      Shoe_Cnt[i] := 18;                     (* 18 scans = 0.36 s shoe stroke *)
    END_IF;
    IF Shoe_Cnt[i] > 0 THEN
      Shoe_Cnt[i] := Shoe_Cnt[i] - 1;
    END_IF;
  END_FOR;

  (* ===== Rung 11 - Door confirm scanner: right truck or wrong truck ===== *)
  LS_Eye[1] := PE_D1_LoadScan;  LS_Route[1] := LoadScan_D1_Route;
  LS_Eye[2] := PE_D2_LoadScan;  LS_Route[2] := LoadScan_D2_Route;
  LS_Eye[3] := PE_D3_LoadScan;  LS_Route[3] := LoadScan_D3_Route;
  LS_Eye[4] := PE_D4_LoadScan;  LS_Route[4] := LoadScan_D4_Route;
  LS_Eye[5] := PE_D5_LoadScan;  LS_Route[5] := LoadScan_D5_Route;
  LS_Eye[6] := PE_D6_LoadScan;  LS_Route[6] := LoadScan_D6_Route;
  LS1_OS(CLK := LS_Eye[1]);  LS_Rise[1] := LS1_OS.Q;
  LS2_OS(CLK := LS_Eye[2]);  LS_Rise[2] := LS2_OS.Q;
  LS3_OS(CLK := LS_Eye[3]);  LS_Rise[3] := LS3_OS.Q;
  LS4_OS(CLK := LS_Eye[4]);  LS_Rise[4] := LS4_OS.Q;
  LS5_OS(CLK := LS_Eye[5]);  LS_Rise[5] := LS5_OS.Q;
  LS6_OS(CLK := LS_Eye[6]);  LS_Rise[6] := LS6_OS.Q;
  FOR i := 1 TO 6 DO
    IF LS_Rise[i] THEN
      IF LS_Route[i] = i THEN
        Green_Cnt[i] := 25;                  (* right truck: green 0.5 s, count it *)
        Count_Total := Count_Total + 1;
        CASE i OF
          1: Count_D1 := Count_D1 + 1;
          2: Count_D2 := Count_D2 + 1;
          3: Count_D3 := Count_D3 + 1;
          4: Count_D4 := Count_D4 + 1;
          5: Count_D5 := Count_D5 + 1;
          6: Count_D6 := Count_D6 + 1;
        END_CASE;
      ELSE
        WrongHold[i] := TRUE;                (* wrong truck: hold it, flash red *)
        Count_WrongDoor := Count_WrongDoor + 1;
      END_IF;
    END_IF;
    IF NOT LS_Eye[i] THEN
      WrongHold[i] := FALSE;                 (* operator pulled it for re-sort *)
    END_IF;
    IF Green_Cnt[i] > 0 THEN
      Green_Cnt[i] := Green_Cnt[i] - 1;
    END_IF;
  END_FOR;

  (* ===== Rung 12 - Relabel station A: belt waits until the operator is done ===== *)
  RelA_OS(CLK := Relabel_A_Done_PB);
  IF RelA_OS.Q AND PE_A_Station THEN
    Relabel_A_Released := TRUE;
    Count_Relabeled := Count_Relabeled + 1;
  END_IF;
  IF NOT PE_A_Station THEN
    Relabel_A_Released := FALSE;
  END_IF;
  Relabel_A_Motor := System_Run AND ((NOT PE_A_Station) OR Relabel_A_Released);

  (* ===== Rungs 13-14 - Return belt A: re-join line A only into a 0.6 s gap ===== *)
  Join_A_Clear(IN := NOT PE_A_Join, PT := T#600ms);
  Return_A_Motor := System_Run AND ((NOT PE_A_RetEnd) OR Join_A_Clear.Q);
  RetA_FT(CLK := PE_A_RetEnd);
  IF RetA_FT.Q THEN
    Count_Reinducted := Count_Reinducted + 1;
  END_IF;

  (* ===== Relabel station + return belt B (mirrors A) ===== *)
  RelB_OS(CLK := Relabel_B_Done_PB);
  IF RelB_OS.Q AND PE_B_Station THEN
    Relabel_B_Released := TRUE;
    Count_Relabeled := Count_Relabeled + 1;
  END_IF;
  IF NOT PE_B_Station THEN
    Relabel_B_Released := FALSE;
  END_IF;
  Relabel_B_Motor := System_Run AND ((NOT PE_B_Station) OR Relabel_B_Released);
  Join_B_Clear(IN := NOT PE_B_Join, PT := T#600ms);
  Return_B_Motor := System_Run AND ((NOT PE_B_RetEnd) OR Join_B_Clear.Q);
  RetB_FT(CLK := PE_B_RetEnd);
  IF RetB_FT.Q THEN
    Count_Reinducted := Count_Reinducted + 1;
  END_IF;

  (* ===== Rung 15 - Stack light ===== *)
  Stack_Green := System_Run;
  Stack_Amber := (NOT System_Run) AND (NOT Jam_Fault) AND EStop_OK;
  Stack_Red := (Jam_Fault OR (NOT EStop_OK)) AND Blink;

  (* ===== Map arrays to real outputs ===== *)
  Shoe_D1 := Shoe_Cnt[1] > 0;   Shoe_D2 := Shoe_Cnt[2] > 0;   Shoe_D3 := Shoe_Cnt[3] > 0;
  Shoe_D4 := Shoe_Cnt[4] > 0;   Shoe_D5 := Shoe_Cnt[5] > 0;   Shoe_D6 := Shoe_Cnt[6] > 0;
  Lamp_Green_D1 := Green_Cnt[1] > 0;  Lamp_Green_D2 := Green_Cnt[2] > 0;  Lamp_Green_D3 := Green_Cnt[3] > 0;
  Lamp_Green_D4 := Green_Cnt[4] > 0;  Lamp_Green_D5 := Green_Cnt[5] > 0;  Lamp_Green_D6 := Green_Cnt[6] > 0;
  Lamp_Red_D1 := WrongHold[1] AND Blink;  Lamp_Red_D2 := WrongHold[2] AND Blink;  Lamp_Red_D3 := WrongHold[3] AND Blink;
  Lamp_Red_D4 := WrongHold[4] AND Blink;  Lamp_Red_D5 := WrongHold[5] AND Blink;  Lamp_Red_D6 := WrongHold[6] AND Blink;

  (* ===== Status word for the edge gateway ===== *)
  Status_Word := BOOL_TO_INT(System_Run)
               + 2 * BOOL_TO_INT(Jam_Fault)
               + 4 * BOOL_TO_INT(NOT EStop_OK)
               + 8 * BOOL_TO_INT(PE_A_Station OR PE_B_Station);
END_PROGRAM


CONFIGURATION Config0
  RESOURCE Res0 ON PLC
    TASK MainTask(INTERVAL := T#20ms, PRIORITY := 0);
    PROGRAM Inst0 WITH MainTask : ATX_HubSort;
  END_RESOURCE
END_CONFIGURATION
