'Attribute VB_Name = "PackingPlan"
'======================================================================
' Module : PackingPlan
' Purpose: Two-stage packing-list automation for CustomerPacking.xlsm.
'   Stage 1 -- PalletizePlan (per generator sheet):
'     Reads inputs, packs pairs into pallets, writes the PalletPlan
'     matrix + Pairs column + Layers column on the active sheet.
'   Stage 2 -- GeneratePackingList (workbook-wide):
'     Iterates every "generator sheet" (any sheet where PalletPlan
'     resolves), recomputes the plan in memory, and emits one block
'     per sheet on Concat+Rename, formatted like the Example sheet.
'
' Named ranges per generator sheet (workbook-scoped or sheet-scoped):
'   PO?           : PO# (single cell) -- optional; if missing, blank
'   Brand         : Brand (single cell)
'   StyleNo       : Style # (single cell)
'   StyleName     : Description / style name (single cell)
'   Width         : Width (single cell)
'   PairCtn       : pairs per carton
'   CtnLayer      : cartons per layer
'   MaxLayer      : max layers per pallet
'   MaxPal        : max pallets allowed
'   Sizes         : size identifiers row (1 row x N cols, e.g. 3..16)
'   SizeLabels    : per-size order TOTAL PAIRS (1 row x N cols)
'   PalletPlan    : size-by-pallet allocation matrix (P rows x N cols)
'                   -- written by PalletizePlan, read by both subs.
'
' "Generator sheet" detection: any worksheet where PalletPlan resolves
' against it via ResolveName. (Log, SizeCarton, PackingPalletDetail,
' Concat+Rename, Dropdown, Carton, Example are skipped.)
'
' Sheet-duplication safety: ResolveName tries sheet-scoped name first,
' falls back to workbook-scoped, and projects the address onto ws if
' the workbook-scoped name lives on a different sheet. So duplicates
' only ever read/write their own data.
'
' Public entry points:
'   - PalletizePlan
'   - GeneratePackingList
'   - LayersForCartons
'   - InstallPalletizeButton
'   - InstallGeneratePackingListButton
'======================================================================
Option Explicit

' Bundle of all per-sheet plan data so PalletizePlan (writes back) and
' GeneratePackingList (read-only consumer) share one algorithm.
Private Type PlanResult
    success As Boolean
    errorMsg As String
    overflow As Boolean
    sizeCount As Long
    palletSlots As Long
    palletsUsed As Long
    pairsPerCarton As Long
    cartonsPerLayer As Long
    layersPerPallet As Long
    maxPallets As Long
    totalCartons As Long
    sizeIds() As Variant      ' from Sizes range  (e.g. 3, 3.5, ...)
    pairs() As Long           ' from SizeLabels   (per-size order pairs)
    cartonsForSize() As Long
    partialPairs() As Long    ' >0 means last carton of size i is partial
    alloc() As Long           ' (palletSlot, sizeIdx) -> carton count
    palletCartons() As Long
    palletPairs() As Long
    partialOnPallet() As Long ' for size i, the pallet idx holding the partial; 0 if none
End Type


'======================================================================
' Sub: PalletizePlan
' Computes a packing plan for the active generator sheet and writes
' the matrix + Pairs col + Layers col back to that sheet.
'======================================================================
Public Sub PalletizePlan()

    Dim ws As Worksheet
    Set ws = ActiveSheet

    Dim plan As PlanResult
    plan = ComputePlan(ws)

    If Not plan.success Then
        If Len(plan.errorMsg) > 0 Then MsgBox plan.errorMsg, vbExclamation
        Exit Sub
    End If

    WritePlanToSheet ws, plan

    Dim msg As String
    msg = "Plan written for sheet '" & ws.Name & "'." & vbCrLf & _
          plan.palletsUsed & " pallet(s) used of " & plan.maxPallets & " max." & vbCrLf & _
          plan.totalCartons & " carton(s) total."
    If plan.overflow Then
        msg = msg & vbCrLf & vbCrLf & _
              "WARNING: PalletPlan only has " & plan.palletSlots & " rows; " & _
              "some cartons could not be placed. Increase PalletPlan size " & _
              "or raise pallet capacity (CtnLayer or MaxLayer)."
    End If

    MsgBox msg, IIf(plan.overflow, vbExclamation, vbInformation), "Palletization Plan"

End Sub


'======================================================================
' Sub: GeneratePackingList
' Iterates all generator sheets in tab order, recomputes each plan,
' and emits a block on the Concat+Rename sheet.
'======================================================================
Public Sub GeneratePackingList()

    Const OUT_SHEET As String = "PackingPalletDetail"

    Dim outWs As Worksheet
    On Error Resume Next
    Set outWs = ThisWorkbook.Worksheets(OUT_SHEET)
    On Error GoTo 0
    If outWs Is Nothing Then
        MsgBox "Sheet '" & OUT_SHEET & "' not found.", vbExclamation
        Exit Sub
    End If

    Dim gens As Collection
    Set gens = New Collection
    Dim ws As Worksheet
    For Each ws In ThisWorkbook.Worksheets
        If IsGeneratorSheet(ws) Then gens.Add ws
    Next ws

    If gens.Count = 0 Then
        MsgBox "No generator sheets found (no sheet has a PalletPlan named range).", vbExclamation
        Exit Sub
    End If

    Application.ScreenUpdating = False
    Application.DisplayAlerts = False
    Application.Calculation = xlCalculationManual

    ' --- Wipe destination -------------------------------------------
    outWs.Cells.UnMerge
    outWs.Cells.Clear

    ' --- Title row --------------------------------------------------
    outWs.Range("B1").Value = "PACKING LIST"
    With outWs.Range("B1:M1")
        .Font.Bold = True
        .Font.Size = 16
        .HorizontalAlignment = xlCenterAcrossSelection
        .VerticalAlignment = xlCenter
    End With
    outWs.Rows(1).RowHeight = 24

    ' --- Per-block emit ---------------------------------------------
    Dim curRow As Long: curRow = 3      ' first header row
    Dim blockTotalRows As Collection
    Set blockTotalRows = New Collection

    Dim emittedBlocks As Long: emittedBlocks = 0
    Dim skippedSheets As String: skippedSheets = ""

    For Each ws In gens
        Dim plan As PlanResult
        plan = ComputePlan(ws)

        If Not plan.success Then
            ' Quietly skip; we'll list these in the summary.
            skippedSheets = skippedSheets & vbCrLf & "  - " & ws.Name & _
                            IIf(Len(plan.errorMsg) > 0, ": " & plan.errorMsg, "")
        Else
            ' Header row for this block
            WriteHeaderRow outWs, curRow
            curRow = curRow + 1
            Dim blockStart As Long: blockStart = curRow

            ' Resolve generator-sheet header values
            Dim po As Variant, styleNo As Variant, descr As Variant
            Dim brandVal As Variant, widthVal As Variant
            po = TryReadName(ws, "PO")
            styleNo = TryReadName(ws, "StyleNo")
            descr = TryReadName(ws, "StyleName")
            brandVal = TryReadName(ws, "Brand")
            widthVal = TryReadName(ws, "Width")

            ' Walk pallets x sizes in display order (smallest size first,
            ' pallet-major). Each style block restarts pallet numbering
            ' at 1 (per spec).
            Dim p As Long, sIdx As Long
            For p = 1 To plan.palletsUsed
                For sIdx = 1 To plan.sizeCount
                    If plan.alloc(p, sIdx) > 0 Then
                        Dim qty As Long
                        Dim isPartialRow As Boolean
                        isPartialRow = (plan.partialOnPallet(sIdx) = p And plan.partialPairs(sIdx) > 0)

                        If isPartialRow Then
                            qty = (plan.alloc(p, sIdx) - 1) * plan.pairsPerCarton + plan.partialPairs(sIdx)
                        Else
                            qty = plan.alloc(p, sIdx) * plan.pairsPerCarton
                        End If

                        WriteDataRow outWs, curRow, po, styleNo, descr, _
                                     p, plan.sizeIds(sIdx), qty, _
                                     plan.pairsPerCarton, brandVal, widthVal, _
                                     isPartialRow
                        curRow = curRow + 1
                    End If
                Next sIdx
            Next p

            Dim blockEnd As Long: blockEnd = curRow - 1

            ' Block total row
            WriteBlockTotal outWs, curRow, blockStart, blockEnd
            blockTotalRows.Add curRow
            curRow = curRow + 1

            ' Merge A:C across the block's data rows (excludes total)
            outWs.Range(outWs.Cells(blockStart, 1), outWs.Cells(blockEnd, 1)).Merge
            outWs.Range(outWs.Cells(blockStart, 2), outWs.Cells(blockEnd, 2)).Merge
            outWs.Range(outWs.Cells(blockStart, 3), outWs.Cells(blockEnd, 3)).Merge

            ' Merge col D on consecutive rows sharing same Pallet#
            MergePalletColumn outWs, blockStart, blockEnd

            ' Two-row gap before the next block
            curRow = curRow + 2
            emittedBlocks = emittedBlocks + 1
        End If
    Next ws

    ' --- Final TOTAL across all block totals ------------------------
    If blockTotalRows.Count > 1 Then
        WriteFinalTotal outWs, curRow, blockTotalRows
    End If

    ' Set the Brand/Width helper cols slightly grayed and narrow so
    ' they're visible but obviously "out-of-print" helpers.
    With outWs.Columns("N:O")
        .Font.Color = RGB(140, 140, 140)
        .Font.Italic = True
        .ColumnWidth = 10
    End With

    Application.Calculation = xlCalculationAutomatic
    Application.Calculate
    Application.DisplayAlerts = True
    Application.ScreenUpdating = True

    Dim summary As String
    summary = "Packing list generated. " & emittedBlocks & " block(s) emitted."
    If Len(skippedSheets) > 0 Then
        summary = summary & vbCrLf & vbCrLf & "Skipped sheets:" & skippedSheets
    End If
    MsgBox summary, vbInformation, "Generate Packing List"

End Sub


'======================================================================
' Function: LayersForCartons
' Ceiling division. Returns 0 for empty pallets so unused rows render
' blank rather than "0".
'======================================================================
Public Function LayersForCartons(cartons As Long, ctnPerLayer As Long) As Long
    If cartons <= 0 Or ctnPerLayer <= 0 Then
        LayersForCartons = 0
    Else
        LayersForCartons = (cartons + ctnPerLayer - 1) \ ctnPerLayer
    End If
End Function


'======================================================================
' Sub: InstallPalletizeButton
' Adds (or replaces) a "Plan Palletization" button on the ACTIVE
' generator sheet. Excel copies it onto duplicates automatically.
'======================================================================
Public Sub InstallPalletizeButton()

    Dim ws As Worksheet
    Set ws = ActiveSheet

    Dim toDelete As Collection: Set toDelete = New Collection
    Dim btn As Button
    For Each btn In ws.Buttons
        If InStr(btn.OnAction, "PalletizePlan") > 0 Then toDelete.Add btn
    Next btn
    Dim deadBtn As Variant
    For Each deadBtn In toDelete: deadBtn.Delete: Next deadBtn

    Dim anchor As Range
    Set anchor = ws.Range(ws.Cells(23, 2), ws.Cells(24, 3))
    Dim newBtn As Button
    Set newBtn = ws.Buttons.Add(anchor.Left + 46, anchor.Top + 5, 120, 30)
    With newBtn
        .Caption = "Plan Palletization"
        .Name = "PlanPalletizationButton"
        .OnAction = "PalletizePlan"
        With .Font
            .Name = "Aptos Narrow": .Size = 12: .Bold = True
        End With
    End With

    MsgBox "Button installed on '" & ws.Name & "'.", vbInformation
End Sub




'----------------------------------------------------------------------
' Function: ComputePlan
' Reads named ranges from ws and runs the packing algorithm.
' Returns a PlanResult with success=True and full data on success;
' success=False with errorMsg on failure. Does NOT show MsgBox or
' write to ws.
'----------------------------------------------------------------------
Private Function ComputePlan(ws As Worksheet) As PlanResult

    Dim plan As PlanResult
    plan.success = False

    ' Read inputs -- all required.
    Dim pairCtnRng As Range, ctnLayerRng As Range
    Dim maxLayerRng As Range, maxPalRng As Range
    Set pairCtnRng = TryResolveName(ws, "PairCtn")
    Set ctnLayerRng = TryResolveName(ws, "CtnLayer")
    Set maxLayerRng = TryResolveName(ws, "MaxLayer")
    Set maxPalRng = TryResolveName(ws, "MaxPal")
    If pairCtnRng Is Nothing Or ctnLayerRng Is Nothing Or _
       maxLayerRng Is Nothing Or maxPalRng Is Nothing Then
        plan.errorMsg = "Missing one of: PairCtn / CtnLayer / MaxLayer / MaxPal."
        ComputePlan = plan
        Exit Function
    End If

    plan.pairsPerCarton = NzLong(pairCtnRng.Value)
    plan.cartonsPerLayer = NzLong(ctnLayerRng.Value)
    plan.layersPerPallet = NzLong(maxLayerRng.Value)
    plan.maxPallets = NzLong(maxPalRng.Value)

    If plan.pairsPerCarton <= 0 Or plan.cartonsPerLayer <= 0 _
       Or plan.layersPerPallet <= 0 Or plan.maxPallets <= 0 Then
        plan.errorMsg = "PairCtn / CtnLayer / MaxLayer / MaxPal must be positive whole numbers."
        ComputePlan = plan
        Exit Function
    End If

    Dim capacity As Long
    capacity = plan.layersPerPallet * plan.cartonsPerLayer

    ' Read range definitions
    Dim totalsRange As Range, sizesRange As Range, palletPlan As Range
    Set totalsRange = TryResolveName(ws, "SizeLabels")
    Set sizesRange = TryResolveName(ws, "Sizes")
    Set palletPlan = TryResolveName(ws, "PalletPlan")
    If totalsRange Is Nothing Or sizesRange Is Nothing Or palletPlan Is Nothing Then
        plan.errorMsg = "Missing one of: SizeLabels / Sizes / PalletPlan."
        ComputePlan = plan
        Exit Function
    End If

    plan.sizeCount = totalsRange.Columns.Count
    plan.palletSlots = palletPlan.Rows.Count

    If sizesRange.Columns.Count <> plan.sizeCount _
       Or palletPlan.Columns.Count <> plan.sizeCount Then
        plan.errorMsg = "Sizes / SizeLabels / PalletPlan column counts must match."
        ComputePlan = plan
        Exit Function
    End If

    ReDim plan.sizeIds(1 To plan.sizeCount)
    ReDim plan.pairs(1 To plan.sizeCount)
    Dim i As Long
    For i = 1 To plan.sizeCount
        plan.sizeIds(i) = sizesRange.Cells(1, i).Value
        plan.pairs(i) = NzLong(totalsRange.Cells(1, i).Value)
    Next i

    ' Cartons per size + partials
    ReDim plan.cartonsForSize(1 To plan.sizeCount)
    ReDim plan.partialPairs(1 To plan.sizeCount)

    For i = 1 To plan.sizeCount
        If plan.pairs(i) > 0 Then
            Dim full As Long, remPairs As Long
            full = plan.pairs(i) \ plan.pairsPerCarton
            remPairs = plan.pairs(i) Mod plan.pairsPerCarton
            plan.cartonsForSize(i) = full + IIf(remPairs > 0, 1, 0)
            plan.partialPairs(i) = remPairs
            plan.totalCartons = plan.totalCartons + plan.cartonsForSize(i)
        End If
    Next i

    If plan.totalCartons = 0 Then
        plan.errorMsg = "no positive pair totals in SizeLabels"
        ComputePlan = plan
        Exit Function
    End If

    ' Greedy pack
    ReDim plan.alloc(1 To plan.palletSlots, 1 To plan.sizeCount)
    ReDim plan.palletCartons(1 To plan.palletSlots)
    ReDim plan.palletPairs(1 To plan.palletSlots)
    ReDim plan.partialOnPallet(1 To plan.sizeCount)

    Dim curPallet As Long: curPallet = 1
    Dim curRem As Long: curRem = capacity
    Dim overflow As Boolean: overflow = False

    For i = 1 To plan.sizeCount
        Dim cartonIdx As Long
        For cartonIdx = 1 To plan.cartonsForSize(i)
            If curRem = 0 Then
                If curPallet >= plan.palletSlots Then
                    overflow = True
                    Exit For
                End If
                curPallet = curPallet + 1
                curRem = capacity
            End If

            ' The LAST carton of size i is the partial when
            ' partialPairs(i) > 0; record which pallet it landed on.
            Dim pairsInCarton As Long
            If cartonIdx = plan.cartonsForSize(i) And plan.partialPairs(i) > 0 Then
                pairsInCarton = plan.partialPairs(i)
                plan.partialOnPallet(i) = curPallet
            Else
                pairsInCarton = plan.pairsPerCarton
            End If

            plan.alloc(curPallet, i) = plan.alloc(curPallet, i) + 1
            plan.palletCartons(curPallet) = plan.palletCartons(curPallet) + 1
            plan.palletPairs(curPallet) = plan.palletPairs(curPallet) + pairsInCarton
            curRem = curRem - 1
        Next cartonIdx
        If overflow Then Exit For
    Next i

    plan.palletsUsed = curPallet
    plan.overflow = overflow
    plan.success = True
    ComputePlan = plan

End Function


'----------------------------------------------------------------------
' Sub: WritePlanToSheet
' Bulk-writes the matrix + Pairs col + Layers col back to ws.
'----------------------------------------------------------------------
Private Sub WritePlanToSheet(ws As Worksheet, ByRef plan As PlanResult)

    Dim palletPlan As Range
    Set palletPlan = ResolveName(ws, "PalletPlan")

    Application.ScreenUpdating = False

    ' Allocation matrix
    Dim out() As Variant
    ReDim out(1 To plan.palletSlots, 1 To plan.sizeCount)
    Dim p As Long, i As Long
    For p = 1 To plan.palletSlots
        For i = 1 To plan.sizeCount
            If plan.alloc(p, i) > 0 Then out(p, i) = plan.alloc(p, i) Else out(p, i) = Empty
        Next i
    Next p
    palletPlan.ClearContents
    palletPlan.Value = out

    ' Pairs col (matrix.LastCol + 2). Override the user's =Cartons*PairCtn
    ' formula because it over-counts on pallets containing a partial.
    Dim pairsColIdx As Long: pairsColIdx = palletPlan.Column + palletPlan.Columns.Count + 1
    Dim layersColIdx As Long: layersColIdx = palletPlan.Column + palletPlan.Columns.Count + 2

    Dim pairsRange As Range
    Set pairsRange = ws.Range(ws.Cells(palletPlan.Row, pairsColIdx), _
                              ws.Cells(palletPlan.Row + plan.palletSlots - 1, pairsColIdx))
    Dim layersRange As Range
    Set layersRange = ws.Range(ws.Cells(palletPlan.Row, layersColIdx), _
                               ws.Cells(palletPlan.Row + plan.palletSlots - 1, layersColIdx))

    Dim pairsOut() As Variant: ReDim pairsOut(1 To plan.palletSlots, 1 To 1)
    Dim layersOut() As Variant: ReDim layersOut(1 To plan.palletSlots, 1 To 1)
    For p = 1 To plan.palletSlots
        If plan.palletCartons(p) > 0 Then
            pairsOut(p, 1) = plan.palletPairs(p)
            layersOut(p, 1) = LayersForCartons(plan.palletCartons(p), plan.cartonsPerLayer)
        Else
            pairsOut(p, 1) = Empty
            layersOut(p, 1) = Empty
        End If
    Next p
    pairsRange.ClearContents: pairsRange.Value = pairsOut
    layersRange.ClearContents: layersRange.Value = layersOut

    Application.ScreenUpdating = True

End Sub


'----------------------------------------------------------------------
' Function: IsGeneratorSheet
' True ONLY when PalletPlan is genuinely anchored on ws -- either
' sheet-scoped on ws, or workbook-scoped pointing at ws. We must NOT
' use TryResolveName here, because its projection fallback always
' returns a non-Nothing range; that would mark every sheet as a
' generator and emit phantom blocks driven by unrelated cells (e.g.
' carton dimensions read through projected coordinates).
'----------------------------------------------------------------------
Private Function IsGeneratorSheet(ws As Worksheet) As Boolean
    Dim r As Range

    ' 1. Sheet-scoped name on ws -> genuine generator.
    On Error Resume Next
    Set r = ws.Names("PalletPlan").RefersToRange
    On Error GoTo 0
    If Not r Is Nothing Then
        IsGeneratorSheet = True
        Exit Function
    End If

    ' 2. Workbook-scoped name -> only counts if it actually points at ws.
    On Error Resume Next
    Set r = ThisWorkbook.Names("PalletPlan").RefersToRange
    On Error GoTo 0
    If r Is Nothing Then Exit Function

    IsGeneratorSheet = (r.Worksheet.Name = ws.Name)
End Function


'----------------------------------------------------------------------
' Sub: WriteHeaderRow
' Writes the column headers for one block (matches Example layout).
'----------------------------------------------------------------------
Private Sub WriteHeaderRow(ws As Worksheet, r As Long)
    ws.Cells(r-1, 10).Value = "Carton Dimensions (CM)"
    ws.Cells(r, 1).Value = "PO#"
    ws.Cells(r, 2).Value = "ITEM#"
    ws.Cells(r, 3).Value = "DESCRIPTION"
    ws.Cells(r, 4).Value = "Pallet"
    ws.Cells(r, 5).Value = "SIZE#"
    ws.Cells(r, 6).Value = "Q'TY"
    ws.Cells(r, 7).Value = "CTNS"
    ws.Cells(r, 8).Value = "G.W./CTN"
    ws.Cells(r, 9).Value = "G.W./TOTAL"
    ws.Cells(r, 10).Value = "Length"
    ws.Cells(r, 11).Value = "Width"
    ws.Cells(r, 12).Value = "HEIGHT"
    ws.Cells(r, 13).Value = "CBM"
    ws.Cells(r, 14).Value = "Brand"
    ws.Cells(r, 15).Value = "Width"

    With ws.Range(ws.Cells(r, 1), ws.Cells(r, 13))
        .Font.Bold = True
        .HorizontalAlignment = xlCenter
        .Borders.LineStyle = xlContinuous
        .Interior.Color = RGB(217, 225, 242)   ' light blue header band
    End With

    With ws.Range(ws.Cells(r-1, 10), ws.Cells(r, 12))
        .Font.Bold = True
        .HorizontalAlignment = xlCenterAcrossSelection
        .Borders.LineStyle = xlContinuous
        .Interior.Color = RGB(217, 225, 242)   ' light blue header band
    End With


End Sub


'----------------------------------------------------------------------
' Sub: WriteDataRow
' Writes a single (pallet, size) row. Formulas reference the row's
' own helper cells (N=Brand, O=Width) so SizeCarton lookups stay
' self-contained per row.
'----------------------------------------------------------------------
Private Sub WriteDataRow(ws As Worksheet, r As Long, _
                         po As Variant, styleNo As Variant, descr As Variant, _
                         palletNum As Long, sizeId As Variant, qty As Long, _
                         pairsPerCarton As Long, _
                         brandVal As Variant, widthVal As Variant, _
                         isPartial As Boolean)

    ws.Cells(r, 1).Value = po
    ws.Cells(r, 2).Value = styleNo
    ws.Cells(r, 3).Value = descr
    ws.Cells(r, 4).Value = palletNum
    ws.Cells(r, 5).Value = sizeId
    ws.Cells(r, 6).Value = qty

    ' CTNS = Q'ty / pairsPerCarton (hardcoded, since PairCtn varies per generator sheet)
    ws.Cells(r, 7).Formula = "=F" & r & "/" & pairsPerCarton

    ' FILTER lookups against SizeCarton table, keyed on (Brand, Size, Width).
    Dim filterBase As String
    filterBase = "(SizeCarton[Brand]=$N" & r & ")*(SizeCarton[Size]=$E" & r & ")*(SizeCarton[Width]=$O" & r & ")"

    ws.Cells(r, 8).Formula = "=IFERROR(FILTER(SizeCarton[G.W./CTN]," & filterBase & ",""""),"""")"
    ws.Cells(r, 9).Formula = "=G" & r & "*H" & r
    ws.Cells(r, 10).Formula = "=IFERROR(FILTER(SizeCarton[L (CM)]," & filterBase & ",""""),"""")"
    ws.Cells(r, 11).Formula = "=IFERROR(FILTER(SizeCarton[W (CM)]," & filterBase & ",""""),"""")"
    ws.Cells(r, 12).Formula = "=IFERROR(FILTER(SizeCarton[H (CM)]," & filterBase & ",""""),"""")"
    ws.Cells(r, 13).Formula = "=J" & r & "*K" & r & "*L" & r & "/1000000*G" & r

    ws.Cells(r, 14).Value = brandVal
    ws.Cells(r, 15).Value = widthVal

    With ws.Range(ws.Cells(r, 1), ws.Cells(r, 13))
        .Borders.LineStyle = xlContinuous
        .HorizontalAlignment = xlCenter
        .VerticalAlignment = xlCenter
    End With

    ' Highlight Q'ty cell: bold red font when this row contains a partial carton.
    If isPartial Then
        With ws.Cells(r, 6).Font
            .Color = RGB(192, 0, 0)
            .Bold = True
        End With
    End If
End Sub


'----------------------------------------------------------------------
' Sub: WriteBlockTotal
' Per-block summary row. Bold + light blue fill (Office accent 1).
'----------------------------------------------------------------------
Private Sub WriteBlockTotal(ws As Worksheet, r As Long, blockStart As Long, blockEnd As Long)
    ws.Cells(r, 4).Value = "Total"
    ws.Cells(r, 6).Formula = "=SUM(F" & blockStart & ":F" & blockEnd & ")"
    ws.Cells(r, 7).Formula = "=SUM(G" & blockStart & ":G" & blockEnd & ")"
    ws.Cells(r, 8).Formula = "=SUM(H" & blockStart & ":H" & blockEnd & ")"
    ws.Cells(r, 9).Formula = "=SUM(I" & blockStart & ":I" & blockEnd & ")"
    ws.Cells(r, 13).Formula = "=SUM(M" & blockStart & ":M" & blockEnd & ")"

    With ws.Range(ws.Cells(r, 4), ws.Cells(r, 13))
        .Font.Bold = True
        .Interior.Color = RGB(217, 225, 242)
        .Borders.LineStyle = xlContinuous
        .HorizontalAlignment = xlCenter
    End With
End Sub


'----------------------------------------------------------------------
' Sub: WriteFinalTotal
' Final TOTAL row -- sums each block's total (not raw rows) so the
' formula stays compact and ignores partial-carton math repetition.
'----------------------------------------------------------------------
Private Sub WriteFinalTotal(ws As Worksheet, r As Long, blockTotalRows As Collection)
    ws.Cells(r, 4).Value = "GRAND TOTAL"

    Dim refsF As String, refsG As String, refsH As String, refsI As String, refsM As String
    Dim x As Variant
    For Each x In blockTotalRows
        If Len(refsF) > 0 Then refsF = refsF & ",": refsG = refsG & ",": refsH = refsH & ","
        If Len(refsI) > 0 Then refsI = refsI & ",": refsM = refsM & ","
        refsF = refsF & "F" & x
        refsG = refsG & "G" & x
        refsH = refsH & "H" & x
        refsI = refsI & "I" & x
        refsM = refsM & "M" & x
    Next x

    ws.Cells(r, 6).Formula = "=SUM(" & refsF & ")"
    ws.Cells(r, 7).Formula = "=SUM(" & refsG & ")"
    ws.Cells(r, 8).Formula = "=SUM(" & refsH & ")"
    ws.Cells(r, 9).Formula = "=SUM(" & refsI & ")"
    ws.Cells(r, 13).Formula = "=SUM(" & refsM & ")"

    With ws.Range(ws.Cells(r, 4), ws.Cells(r, 13))
        .Font.Bold = True
        .Interior.Color = RGB(217, 225, 242)
        .Borders.LineStyle = xlContinuous
        .HorizontalAlignment = xlCenter
    End With
End Sub


'----------------------------------------------------------------------
' Sub: MergePalletColumn
' Scans col D between blockStart..blockEnd and merges runs of equal
' Pallet#. DisplayAlerts off so Excel doesn't prompt about losing
' "all but the upper-left value" -- the values are already identical.
'----------------------------------------------------------------------
Private Sub MergePalletColumn(ws As Worksheet, blockStart As Long, blockEnd As Long)
    Dim r As Long: r = blockStart
    Application.DisplayAlerts = False
    Do While r <= blockEnd
        Dim startR As Long: startR = r
        Dim val As Variant: val = ws.Cells(r, 4).Value
        Do While r < blockEnd
            If ws.Cells(r + 1, 4).Value <> val Then Exit Do
            r = r + 1
        Loop
        If r > startR Then
            ws.Range(ws.Cells(startR, 4), ws.Cells(r, 4)).Merge
            ws.Range(ws.Cells(startR, 4), ws.Cells(r, 4)).VerticalAlignment = xlCenter
        End If
        r = r + 1
    Loop
    Application.DisplayAlerts = True
End Sub


'----------------------------------------------------------------------
' Helper: ResolveName (and its non-throwing twin TryResolveName)
'
' Resolves a named range against `ws` with these priorities:
'   1. Sheet-scoped name on ws
'   2. Workbook-scoped name pointing at ws
'   3. Workbook-scoped name on a different sheet -> project address onto ws
'
' ResolveName: raises a runtime error if the name doesn't exist anywhere.
' TryResolveName: returns Nothing instead.
'----------------------------------------------------------------------
Private Function ResolveName(ws As Worksheet, nm As String) As Range
    Dim r As Range
    Set r = TryResolveName(ws, nm)
    If r Is Nothing Then
        Err.Raise vbObjectError + 1001, , _
            "Named range '" & nm & "' is not defined for sheet '" & ws.Name & "'."
    End If
    Set ResolveName = r
End Function


Private Function TryResolveName(ws As Worksheet, nm As String) As Range
    Dim r As Range

    ' Sheet-scoped first
    On Error Resume Next
    Set r = ws.Names(nm).RefersToRange
    On Error GoTo 0
    If Not r Is Nothing Then
        Set TryResolveName = r
        Exit Function
    End If

    ' Workbook-scoped fallback
    On Error Resume Next
    Set r = ThisWorkbook.Names(nm).RefersToRange
    On Error GoTo 0
    If r Is Nothing Then Exit Function

    If r.Worksheet.Name = ws.Name Then
        Set TryResolveName = r
    Else
        ' Different sheet -> project address onto ws (defensive case)
        Set TryResolveName = ws.Range(r.Address)
    End If
End Function


'----------------------------------------------------------------------
' Helper: TryReadName -- value-or-empty wrapper around TryResolveName.
'----------------------------------------------------------------------
Private Function TryReadName(ws As Worksheet, nm As String) As Variant
    Dim r As Range
    Set r = TryResolveName(ws, nm)
    If r Is Nothing Then
        TryReadName = ""
    Else
        TryReadName = r.Value
    End If
End Function


'----------------------------------------------------------------------
' Helper: NzLong - coerce a possibly-empty / formula / variant cell
' value to Long. Empty/blank/error/non-numeric strings -> 0.
'----------------------------------------------------------------------
Private Function NzLong(v As Variant) As Long
    If IsError(v) Or IsNull(v) Or IsEmpty(v) Then
        NzLong = 0
    ElseIf VarType(v) = vbString Then
        If Len(Trim$(v)) = 0 Then
            NzLong = 0
        ElseIf IsNumeric(v) Then
            NzLong = CLng(CDbl(v))
        Else
            NzLong = 0
        End If
    Else
        NzLong = CLng(v)
    End If
End Function
