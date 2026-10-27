CLASS zcl_abapmcp_structure DEFINITION PUBLIC FINAL CREATE PUBLIC.
*&---------------------------------------------------------------------*
*& Static analysis and compression of ABAP source.
*&
*& PURPOSE
*& A 2842 line program is roughly 40,000 tokens. Sending its first 250
*& lines produces a review of the declarations - worse than useless,
*& because it looks complete. This class reads the WHOLE source and
*& produces something the model can hold entirely:
*&
*&   skeleton   ~60 lines describing all 2842
*&   + routines selected by relevance, stripped of noise
*&   = 3,000-5,000 tokens instead of 40,000
*&
*& Roughly 90 percent saved, and it fits in ONE round trip.
*&
*& HOW IT COMPRESSES - five mechanisms, all deterministic
*&   1. STATEMENT JOINING  wrapped statements rejoined before scanning,
*&                         otherwise a SELECT with FROM on the next line
*&                         is invisible. Older ABAP wraps constantly.
*&   2. STRIPPING          comments, blank lines, WRITE formatting and
*&                         ALV field catalogue building removed. 30-40
*&                         percent of a typical report, almost none of
*&                         the meaning.
*&   3. ROUTINE PAGING     cut on FORM and METHOD boundaries, never mid
*&                         statement. The model asks for a routine BY
*&                         NAME instead of guessing a line number.
*&   4. COMPLEXITY SCORE   nesting, DB statements, calls and length per
*&                         routine, so the caller can send only what
*&                         matters.
*&   5. BOILERPLATE FLAG   routines that are pure screen or ALV setup
*&                         marked, so they can be summarised not sent.
*&
*& WHAT IT CANNOT DO
*& It describes MECHANISM, never PURPOSE. "Reads EKKO and EKPO, calls
*& BAPI_PO_CHANGE in a loop" - yes. "Posts RFQ confirmations" - no.
*& Intent is not recoverable from syntax. That is what the model is for.
*&
*& NW 7.02 syntax only: no inline DATA( ), no VALUE #( ), no NEW.
*&---------------------------------------------------------------------*
  PUBLIC SECTION.

    CONSTANTS c_kind_form   TYPE string VALUE 'FORM'.
    CONSTANTS c_kind_method TYPE string VALUE 'METHOD'.
    CONSTANTS c_kind_event  TYPE string VALUE 'EVENT'.
    CONSTANTS c_kind_module TYPE string VALUE 'MODULE'.

*   one logical statement, with the physical lines it spanned
    TYPES: BEGIN OF ty_stmt,
             text TYPE string,      "joined, upper case, comments gone
             from TYPE i,
             to   TYPE i,
           END OF ty_stmt.
    TYPES ty_t_stmt TYPE STANDARD TABLE OF ty_stmt WITH DEFAULT KEY.

    TYPES: BEGIN OF ty_ref,
             kind  TYPE string,     "READ WRITE CALLFM CALLBAPI CALLMTH CREATE PERFORM SUBMIT
             name  TYPE string,
             count TYPE i,
             line  TYPE i,
           END OF ty_ref.
    TYPES ty_t_ref TYPE STANDARD TABLE OF ty_ref WITH DEFAULT KEY.

    TYPES: BEGIN OF ty_block,
             kind        TYPE string,
             name        TYPE string,
             from        TYPE i,
             to          TYPE i,
             lines       TYPE i,
             net_lines   TYPE i,   "after stripping
             nesting     TYPE i,
             db_stmts    TYPE i,
             calls       TYPE i,
             score       TYPE i,   "complexity, higher = more worth reading
             boilerplate TYPE abap_bool,
           END OF ty_block.
    TYPES ty_t_block TYPE STANDARD TABLE OF ty_block WITH DEFAULT KEY.

    TYPES: BEGIN OF ty_result,
             object       TYPE string,
             lines_total  TYPE i,
             lines_net    TYPE i,   "after stripping
             stmts_total  TYPE i,
             refs         TYPE ty_t_ref,
             blocks       TYPE ty_t_block,
             params       TYPE string_table,
             includes     TYPE string_table,
             has_auth     TYPE abap_bool,
             has_commit   TYPE abap_bool,
             has_enqueue  TYPE abap_bool,
             has_dataset  TYPE abap_bool,
             has_submit   TYPE abap_bool,
             has_native   TYPE abap_bool,
             max_nesting  TYPE i,
             confidence   TYPE i,   "0-100, see CONFIDENCE below
             conf_note    TYPE string,
           END OF ty_result.

*   ---- analysis -----------------------------------------------------
    CLASS-METHODS analyse
      IMPORTING it_source        TYPE string_table
                iv_object        TYPE string
      RETURNING VALUE(rs_result) TYPE ty_result.

*   ---- output shapes ------------------------------------------------

*   Deterministic prose summary. No model, no cost. Answers a fair
*   number of questions on its own.
    CLASS-METHODS to_text
      IMPORTING is_result      TYPE ty_result
      RETURNING VALUE(rv_text) TYPE string.

*   Compact skeleton for a model prompt. Replaces sending the source.
    CLASS-METHODS to_prompt
      IMPORTING is_result      TYPE ty_result
      RETURNING VALUE(rv_text) TYPE string.

*   Source of one named routine, stripped. This is what the model asks
*   for by name after reading the skeleton.
    CLASS-METHODS get_routine
      IMPORTING it_source       TYPE string_table
                is_result       TYPE ty_result
                iv_name         TYPE string
      RETURNING VALUE(rv_source) TYPE string.

*   The n most complex non-boilerplate routines, stripped and
*   concatenated. Use when the model should see "the parts that matter"
*   without naming them.
    CLASS-METHODS get_hot_routines
      IMPORTING it_source        TYPE string_table
                is_result        TYPE ty_result
                iv_count         TYPE i DEFAULT 3
                iv_max_lines     TYPE i DEFAULT 400
      RETURNING VALUE(rv_source) TYPE string.

*   Strip a source range of comments, blanks, WRITE formatting and ALV
*   field catalogue lines.
    CLASS-METHODS strip
      IMPORTING it_source        TYPE string_table
                iv_from          TYPE i DEFAULT 1
                iv_to            TYPE i DEFAULT 0
      RETURNING VALUE(rt_out)    TYPE string_table.

PROTECTED SECTION.

  PRIVATE SECTION.

    CLASS-METHODS build_statements
      IMPORTING it_source        TYPE string_table
      RETURNING VALUE(rt_stmt)   TYPE ty_t_stmt.

    CLASS-METHODS clean_line
      IMPORTING iv_line        TYPE string
      RETURNING VALUE(rv_out)  TYPE string.

    CLASS-METHODS token_after
      IMPORTING iv_text        TYPE string
                iv_keyword     TYPE string
      RETURNING VALUE(rv_out)  TYPE string.

    CLASS-METHODS first_token
      IMPORTING iv_text        TYPE string
      RETURNING VALUE(rv_out)  TYPE string.

    CLASS-METHODS add_ref
      IMPORTING iv_kind  TYPE string
                iv_name  TYPE string
                iv_line  TYPE i
      CHANGING  ct_refs  TYPE ty_t_ref.

    CLASS-METHODS is_noise
      IMPORTING iv_line        TYPE string
      RETURNING VALUE(rv_ok)   TYPE abap_bool.

ENDCLASS.


CLASS zcl_abapmcp_structure IMPLEMENTATION.

  METHOD add_ref.

    DATA ls_ref TYPE ty_ref.
    DATA lv_idx TYPE i.

    IF iv_name IS INITIAL.
      RETURN.
    ENDIF.

    READ TABLE ct_refs INTO ls_ref
      WITH KEY kind = iv_kind name = iv_name.
    IF sy-subrc = 0.
      lv_idx = sy-tabix.
      ls_ref-count = ls_ref-count + 1.
      MODIFY ct_refs FROM ls_ref INDEX lv_idx.
    ELSE.
      CLEAR ls_ref.
      ls_ref-kind  = iv_kind.
      ls_ref-name  = iv_name.
      ls_ref-count = 1.
      ls_ref-line  = iv_line.
      APPEND ls_ref TO ct_refs.
    ENDIF.

  ENDMETHOD.


  METHOD analyse.

    DATA lt_stmt   TYPE ty_t_stmt.
    DATA ls_stmt   TYPE ty_stmt.
    DATA lv_txt    TYPE string.
    DATA lv_first  TYPE string.
    DATA lv_name   TYPE string.
    DATA lv_depth  TYPE i.
    DATA ls_block  TYPE ty_block.
    DATA lt_open   TYPE ty_t_block.
    DATA lv_top    TYPE i.
    DATA lv_idx    TYPE i.
    DATA ls_b      TYPE ty_block.
    DATA lt_net    TYPE string_table.
    DATA lv_dbstmt TYPE abap_bool.
    DATA lv_call   TYPE abap_bool.

    rs_result-object = iv_object.
    DESCRIBE TABLE it_source LINES rs_result-lines_total.

*   ---- 1. join wrapped statements -----------------------------------
    lt_stmt = build_statements( it_source ).
    DESCRIBE TABLE lt_stmt LINES rs_result-stmts_total.

*   ---- 2. net line count after stripping ----------------------------
    lt_net = strip( it_source ).
    DESCRIBE TABLE lt_net LINES rs_result-lines_net.

*   ---- walk the statements ------------------------------------------
    LOOP AT lt_stmt INTO ls_stmt.

      lv_txt   = ls_stmt-text.
      lv_first = first_token( lv_txt ).
      CLEAR: lv_dbstmt, lv_call.

*     ---- includes ---------------------------------------------------
      IF lv_first = 'INCLUDE'.
        lv_name = token_after( iv_text = lv_txt iv_keyword = 'INCLUDE' ).
        IF lv_name IS NOT INITIAL.
          APPEND lv_name TO rs_result-includes.
        ENDIF.
      ENDIF.

*     ---- selection screen -------------------------------------------
      IF lv_first = 'PARAMETERS' OR lv_first = 'SELECT-OPTIONS'.
        APPEND lv_txt TO rs_result-params.
      ENDIF.

*     ---- database ---------------------------------------------------
      IF lv_first = 'SELECT'.
        lv_name = token_after( iv_text = lv_txt iv_keyword = 'FROM' ).
        IF lv_name IS NOT INITIAL.
          add_ref( EXPORTING iv_kind = 'READ' iv_name = lv_name iv_line = ls_stmt-from
                   CHANGING  ct_refs = rs_result-refs ).
          lv_dbstmt = abap_true.
        ENDIF.
      ENDIF.

      IF lv_first = 'INSERT' OR lv_first = 'UPDATE' OR lv_first = 'MODIFY'
      OR lv_first = 'DELETE'.
*       these also work on internal tables. Only treat as a DB write
*       when the target names a table straight after the keyword and
*       carries no work area or field symbol syntax.
        CLEAR lv_name.
        IF lv_txt CS ' FROM TABLE ' OR lv_first = 'DELETE'.
          lv_name = token_after( iv_text = lv_txt iv_keyword = 'FROM' ).
        ENDIF.
        IF lv_name IS INITIAL.
          lv_name = token_after( iv_text = lv_txt iv_keyword = lv_first ).
        ENDIF.
        IF lv_name IS NOT INITIAL AND lv_name NA '-<>'
           AND lv_name <> 'TABLE' AND lv_name <> 'ADJACENT'.
          add_ref( EXPORTING iv_kind = 'WRITE' iv_name = lv_name iv_line = ls_stmt-from
                   CHANGING  ct_refs = rs_result-refs ).
          lv_dbstmt = abap_true.
        ENDIF.
      ENDIF.

      IF lv_txt CS 'EXEC SQL'.
        rs_result-has_native = abap_true.
        lv_dbstmt = abap_true.
      ENDIF.

*     ---- calls ------------------------------------------------------
      IF lv_txt CS 'CALL FUNCTION'.
        lv_name = token_after( iv_text = lv_txt iv_keyword = 'FUNCTION' ).
        IF lv_name CP 'BAPI*'.
          add_ref( EXPORTING iv_kind = 'CALLBAPI' iv_name = lv_name iv_line = ls_stmt-from
                   CHANGING  ct_refs = rs_result-refs ).
        ELSE.
          add_ref( EXPORTING iv_kind = 'CALLFM' iv_name = lv_name iv_line = ls_stmt-from
                   CHANGING  ct_refs = rs_result-refs ).
        ENDIF.
        lv_call = abap_true.
        IF lv_name CP 'ENQUEUE*'.
          rs_result-has_enqueue = abap_true.
        ENDIF.
      ENDIF.

      IF lv_txt CS 'CALL METHOD'.
        lv_name = token_after( iv_text = lv_txt iv_keyword = 'METHOD' ).
        add_ref( EXPORTING iv_kind = 'CALLMTH' iv_name = lv_name iv_line = ls_stmt-from
                 CHANGING  ct_refs = rs_result-refs ).
        lv_call = abap_true.
      ENDIF.

      IF lv_txt CS 'CREATE OBJECT'.
        lv_name = token_after( iv_text = lv_txt iv_keyword = 'TYPE' ).
        IF lv_name IS NOT INITIAL.
          add_ref( EXPORTING iv_kind = 'CREATE' iv_name = lv_name iv_line = ls_stmt-from
                   CHANGING  ct_refs = rs_result-refs ).
        ENDIF.
        lv_call = abap_true.
      ENDIF.

      IF lv_first = 'PERFORM'.
        lv_name = token_after( iv_text = lv_txt iv_keyword = 'PERFORM' ).
        add_ref( EXPORTING iv_kind = 'PERFORM' iv_name = lv_name iv_line = ls_stmt-from
                 CHANGING  ct_refs = rs_result-refs ).
        lv_call = abap_true.
      ENDIF.

      IF lv_first = 'SUBMIT'.
        lv_name = token_after( iv_text = lv_txt iv_keyword = 'SUBMIT' ).
        add_ref( EXPORTING iv_kind = 'SUBMIT' iv_name = lv_name iv_line = ls_stmt-from
                 CHANGING  ct_refs = rs_result-refs ).
        rs_result-has_submit = abap_true.
      ENDIF.

*     ---- flags ------------------------------------------------------
      IF lv_first = 'AUTHORITY-CHECK'.
        rs_result-has_auth = abap_true.
      ENDIF.
      IF lv_txt CS 'COMMIT WORK'.
        rs_result-has_commit = abap_true.
      ENDIF.
      IF lv_first = 'OPEN' AND lv_txt CS 'DATASET'.
        rs_result-has_dataset = abap_true.
      ENDIF.

*     ---- nesting ----------------------------------------------------
      IF lv_first = 'LOOP' OR lv_first = 'DO' OR lv_first = 'WHILE'
      OR lv_first = 'IF'   OR lv_first = 'CASE'.
        lv_depth = lv_depth + 1.
        IF lv_depth > rs_result-max_nesting.
          rs_result-max_nesting = lv_depth.
        ENDIF.
      ENDIF.
      IF lv_first = 'ENDLOOP' OR lv_first = 'ENDDO' OR lv_first = 'ENDWHILE'
      OR lv_first = 'ENDIF'   OR lv_first = 'ENDCASE'.
        IF lv_depth > 0.
          lv_depth = lv_depth - 1.
        ENDIF.
      ENDIF.

*     ---- block open -------------------------------------------------
      CLEAR ls_block.
      IF lv_first = 'FORM'.
        ls_block-kind = c_kind_form.
        ls_block-name = token_after( iv_text = lv_txt iv_keyword = 'FORM' ).
      ELSEIF lv_first = 'METHOD'.
        ls_block-kind = c_kind_method.
        ls_block-name = token_after( iv_text = lv_txt iv_keyword = 'METHOD' ).
      ELSEIF lv_first = 'MODULE'.
        ls_block-kind = c_kind_module.
        ls_block-name = token_after( iv_text = lv_txt iv_keyword = 'MODULE' ).
      ELSEIF lv_first = 'START-OF-SELECTION' OR lv_first = 'END-OF-SELECTION'
          OR lv_first = 'INITIALIZATION'     OR lv_first = 'TOP-OF-PAGE'
          OR ( lv_first = 'AT' AND lv_txt CS 'SELECTION-SCREEN' ).
        ls_block-kind = c_kind_event.
        ls_block-name = lv_first.
      ENDIF.

      IF ls_block-kind IS NOT INITIAL.
*       an event closes any open event
        IF ls_block-kind = c_kind_event.
          lv_top = lines( lt_open ).
          IF lv_top > 0.
            READ TABLE lt_open INTO ls_b INDEX lv_top.
            IF sy-subrc = 0 AND ls_b-kind = c_kind_event.
              ls_b-to    = ls_stmt-from - 1.
              ls_b-lines = ls_b-to - ls_b-from + 1.
              APPEND ls_b TO rs_result-blocks.
              DELETE lt_open INDEX lv_top.
            ENDIF.
          ENDIF.
        ENDIF.
        ls_block-from = ls_stmt-from.
        APPEND ls_block TO lt_open.
      ENDIF.

*     ---- attribute the statement to the innermost open block --------
      lv_top = lines( lt_open ).
      IF lv_top > 0.
        READ TABLE lt_open INTO ls_b INDEX lv_top.
        IF sy-subrc = 0.
          IF lv_dbstmt = abap_true.
            ls_b-db_stmts = ls_b-db_stmts + 1.
          ENDIF.
          IF lv_call = abap_true.
            ls_b-calls = ls_b-calls + 1.
          ENDIF.
          IF lv_depth > ls_b-nesting.
            ls_b-nesting = lv_depth.
          ENDIF.
          MODIFY lt_open FROM ls_b INDEX lv_top.
        ENDIF.
      ENDIF.

*     ---- block close ------------------------------------------------
      IF lv_first = 'ENDFORM' OR lv_first = 'ENDMETHOD' OR lv_first = 'ENDMODULE'.
        lv_top = lines( lt_open ).
        READ TABLE lt_open INTO ls_block INDEX lv_top.
        IF sy-subrc = 0.
          ls_block-to    = ls_stmt-to.
          ls_block-lines = ls_block-to - ls_block-from + 1.
          APPEND ls_block TO rs_result-blocks.
          DELETE lt_open INDEX lv_top.
        ENDIF.
      ENDIF.

    ENDLOOP.

*   ---- close anything still open ------------------------------------
    LOOP AT lt_open INTO ls_block.
      ls_block-to    = rs_result-lines_total.
      ls_block-lines = ls_block-to - ls_block-from + 1.
      APPEND ls_block TO rs_result-blocks.
    ENDLOOP.

*   ---- 4 and 5. score and flag boilerplate --------------------------
    LOOP AT rs_result-blocks INTO ls_b.
      lv_idx = sy-tabix.

      CLEAR lt_net.
      lt_net = strip( it_source = it_source
                      iv_from   = ls_b-from
                      iv_to     = ls_b-to ).
      DESCRIBE TABLE lt_net LINES ls_b-net_lines.

*     complexity: nesting weighs most, then DB work, then calls, then
*     sheer length. Deliberately crude - it only has to rank.
      ls_b-score = ls_b-nesting * 10
                 + ls_b-db_stmts * 6
                 + ls_b-calls * 2
                 + ls_b-net_lines / 10.

*     boilerplate: screen and ALV plumbing carries little meaning
      IF ls_b-name CS 'ALV'      OR ls_b-name CS 'FIELDCAT'
      OR ls_b-name CS 'LAYOUT'   OR ls_b-name CS 'CATALOG'
      OR ls_b-name CS 'SELECTION_TEXT' OR ls_b-name CS 'INIT_SCREEN'
      OR ls_b-name CS 'STATUS'   OR ls_b-name CS 'TOP_OF_PAGE'.
        ls_b-boilerplate = abap_true.
        ls_b-score = ls_b-score / 4.
      ENDIF.

      MODIFY rs_result-blocks FROM ls_b INDEX lv_idx.
    ENDLOOP.

*   ---- confidence ---------------------------------------------------
*   Say so when the parse looks wrong. A confident wrong skeleton is
*   worse than none, because the caller stops checking.
    rs_result-confidence = 100.

    IF rs_result-lines_total > 200 AND lines( rs_result-blocks ) = 0.
      rs_result-confidence = 20.
      rs_result-conf_note  = 'No routines found in a long object. Likely an include, a module pool with screen logic, or generated code. Treat the skeleton as partial.'.
    ELSEIF rs_result-stmts_total = 0.
      rs_result-confidence = 0.
      rs_result-conf_note  = 'No statements parsed. Source may be empty or in an unexpected format.'.
    ELSEIF rs_result-refs IS INITIAL AND rs_result-lines_total > 300.
      rs_result-confidence = 50.
      rs_result-conf_note  = 'No database access or calls detected in a long object. Verify before relying on this.'.
    ENDIF.

    SORT rs_result-refs BY kind name.
    SORT rs_result-blocks BY from.

  ENDMETHOD.


  METHOD build_statements.
*   Rejoin wrapped statements. Without this a SELECT whose FROM sits on
*   the next line is invisible, and older ABAP wraps constantly. This is
*   the fix that makes everything else trustworthy.

    DATA lv_raw   TYPE string.
    DATA lv_clean TYPE string.
    DATA ls_stmt  TYPE ty_stmt.
    DATA lv_idx   TYPE i.
    DATA lv_open  TYPE abap_bool.

    LOOP AT it_source INTO lv_raw.

      lv_idx   = sy-tabix.
      lv_clean = clean_line( lv_raw ).

      IF lv_clean IS INITIAL.
        CONTINUE.
      ENDIF.

      IF lv_open = abap_false.
        CLEAR ls_stmt.
        ls_stmt-from = lv_idx.
        ls_stmt-text = lv_clean.
        lv_open = abap_true.
      ELSE.
        CONCATENATE ls_stmt-text lv_clean INTO ls_stmt-text SEPARATED BY space.
      ENDIF.

*     a period ends the statement. Chained colon statements are joined
*     as one - crude, but they are declarations more often than logic.
      IF lv_clean CS '.'.
        ls_stmt-to = lv_idx.
        CONDENSE ls_stmt-text.
        APPEND ls_stmt TO rt_stmt.
        lv_open = abap_false.
      ENDIF.

    ENDLOOP.

*   unterminated tail
    IF lv_open = abap_true.
      ls_stmt-to = lines( it_source ).
      CONDENSE ls_stmt-text.
      APPEND ls_stmt TO rt_stmt.
    ENDIF.

  ENDMETHOD.


  METHOD clean_line.

    DATA lv_pos TYPE i.

    rv_out = iv_line.

*   full line comment
    SHIFT rv_out LEFT DELETING LEADING space.
    IF rv_out IS NOT INITIAL AND rv_out(1) = '*'.
      CLEAR rv_out.
      RETURN.
    ENDIF.

*   trailing comment. Naive on a quote inside a literal, accepted.
    FIND FIRST OCCURRENCE OF '"' IN rv_out MATCH OFFSET lv_pos.
    IF sy-subrc = 0.
      rv_out = rv_out(lv_pos).
    ENDIF.

    TRANSLATE rv_out TO UPPER CASE.
    CONDENSE rv_out.

  ENDMETHOD.


  METHOD first_token.

    DATA lt_tok TYPE string_table.
    DATA lv_tok TYPE string.

    SPLIT iv_text AT space INTO TABLE lt_tok.
    READ TABLE lt_tok INTO lv_tok INDEX 1.
    IF sy-subrc = 0.
      rv_out = lv_tok.
      REPLACE ALL OCCURRENCES OF '.' IN rv_out WITH ''.
      REPLACE ALL OCCURRENCES OF ':' IN rv_out WITH ''.
      CONDENSE rv_out.
    ENDIF.

  ENDMETHOD.


  METHOD get_hot_routines.

    DATA lt_rank TYPE ty_t_block.
    DATA ls_b    TYPE ty_block.
    DATA lt_out  TYPE string_table.
    DATA lt_part TYPE string_table.
    DATA lv_hdr  TYPE string.
    DATA lv_n    TYPE i.
    DATA lv_used TYPE i.
    DATA lv_c    TYPE string.

    lt_rank = is_result-blocks.
    DELETE lt_rank WHERE boilerplate = abap_true.
    SORT lt_rank BY score DESCENDING.

    LOOP AT lt_rank INTO ls_b.

      lv_n = lv_n + 1.
      IF lv_n > iv_count.
        EXIT.
      ENDIF.

      IF lv_used + ls_b-net_lines > iv_max_lines AND lv_used > 0.
        EXIT.
      ENDIF.

      CLEAR lt_part.
      lt_part = strip( it_source = it_source
                       iv_from   = ls_b-from
                       iv_to     = ls_b-to ).

      lv_c = ls_b-from. CONDENSE lv_c.
      CONCATENATE '*--- ' ls_b-kind ' ' ls_b-name ' (line ' lv_c ') ---*'
        INTO lv_hdr.
      APPEND lv_hdr TO lt_out.
      APPEND LINES OF lt_part TO lt_out.

      lv_used = lv_used + ls_b-net_lines.

    ENDLOOP.

    CONCATENATE LINES OF lt_out INTO rv_source
      SEPARATED BY cl_abap_char_utilities=>newline.

  ENDMETHOD.


  METHOD get_routine.

    DATA ls_b     TYPE ty_block.
    DATA lt_out   TYPE string_table.
    DATA lv_line  TYPE string.
    DATA lv_up    TYPE string.

    lv_up = iv_name.
    TRANSLATE lv_up TO UPPER CASE.
    CONDENSE lv_up.

    READ TABLE is_result-blocks INTO ls_b WITH KEY name = lv_up.
    IF sy-subrc <> 0.
      rv_source = 'Routine not found. Use the names given in the skeleton.'.
      RETURN.
    ENDIF.

    lt_out = strip( it_source = it_source
                    iv_from   = ls_b-from
                    iv_to     = ls_b-to ).

    CONCATENATE LINES OF lt_out INTO rv_source
      SEPARATED BY cl_abap_char_utilities=>newline.

  ENDMETHOD.


  METHOD is_noise.
*   Lines that carry formatting rather than meaning.

    DATA lv_up TYPE string.

    lv_up = iv_line.
    SHIFT lv_up LEFT DELETING LEADING space.

    IF lv_up IS INITIAL.
      rv_ok = abap_true.
      RETURN.
    ENDIF.

    IF lv_up(1) = '*'.
      rv_ok = abap_true.
      RETURN.
    ENDIF.

    TRANSLATE lv_up TO UPPER CASE.

    IF lv_up CP 'WRITE:*' OR lv_up CP 'WRITE /*' OR lv_up CP 'ULINE*'
    OR lv_up CP 'SKIP*'   OR lv_up CP 'FORMAT *'
    OR lv_up CP 'LS_FIELDCAT-*' OR lv_up CP 'LS_FCAT-*'
    OR lv_up CP 'GS_LAYOUT-*'   OR lv_up CP 'LS_LAYOUT-*'
    OR lv_up CP 'APPEND LS_FIELDCAT*' OR lv_up CP 'APPEND LS_FCAT*'.
      rv_ok = abap_true.
    ENDIF.

  ENDMETHOD.


  METHOD strip.

    DATA lv_line TYPE string.
    DATA lv_idx  TYPE i.
    DATA lv_to   TYPE i.

    lv_to = iv_to.
    IF lv_to <= 0.
      lv_to = lines( it_source ).
    ENDIF.

    LOOP AT it_source INTO lv_line.
      lv_idx = sy-tabix.
      IF lv_idx < iv_from OR lv_idx > lv_to.
        CONTINUE.
      ENDIF.
      IF is_noise( lv_line ) = abap_true.
        CONTINUE.
      ENDIF.
      APPEND lv_line TO rt_out.
    ENDLOOP.

  ENDMETHOD.


  METHOD to_prompt.

    DATA ls_ref TYPE ty_ref.
    DATA ls_b   TYPE ty_block.
    DATA lv_nl  TYPE string.
    DATA lv_n   TYPE string.
    DATA lv_c   TYPE string.
    DATA lv_s   TYPE string.

    lv_nl = cl_abap_char_utilities=>newline.

    lv_n = is_result-lines_total. CONDENSE lv_n.
    lv_c = is_result-lines_net.   CONDENSE lv_c.
    CONCATENATE 'STRUCTURE OF' is_result-object '- static analysis of ALL' lv_n
                'lines (' lv_c 'after removing comments and formatting).'
                'This skeleton covers the WHOLE object. Source of individual'
                'routines can be requested BY NAME.'
      INTO rv_text SEPARATED BY space.

    IF is_result-confidence < 100.
      lv_n = is_result-confidence. CONDENSE lv_n.
      CONCATENATE rv_text lv_nl 'PARSE CONFIDENCE ' lv_n '% - ' is_result-conf_note
        INTO rv_text.
    ENDIF.

*   a program's logic often sits in its includes: name them, so they
*   are read by name instead of guessed (12.10.2026)
    IF is_result-includes IS NOT INITIAL.
      CONCATENATE rv_text lv_nl 'INCLUDES - the logic may sit here; read each by name:' INTO rv_text.
      LOOP AT is_result-includes INTO lv_s.
        CONCATENATE rv_text lv_nl `  ` lv_s INTO rv_text.
      ENDLOOP.
    ENDIF.

    CONCATENATE rv_text lv_nl 'TABLES READ:' INTO rv_text.
    LOOP AT is_result-refs INTO ls_ref WHERE kind = 'READ'.
      lv_c = ls_ref-count. CONDENSE lv_c.
      CONCATENATE rv_text lv_nl `  ` ls_ref-name ` x` lv_c INTO rv_text.
    ENDLOOP.

    CONCATENATE rv_text lv_nl 'TABLES WRITTEN:' INTO rv_text.
    LOOP AT is_result-refs INTO ls_ref WHERE kind = 'WRITE'.
      lv_c = ls_ref-count. CONDENSE lv_c.
      CONCATENATE rv_text lv_nl `  ` ls_ref-name ` x` lv_c INTO rv_text.
    ENDLOOP.

    CONCATENATE rv_text lv_nl 'CALLS:' INTO rv_text.
    LOOP AT is_result-refs INTO ls_ref
      WHERE kind = 'CALLBAPI' OR kind = 'CALLFM'
         OR kind = 'CALLMTH'  OR kind = 'CREATE' OR kind = 'SUBMIT'.
      lv_c = ls_ref-count. CONDENSE lv_c.
      CONCATENATE rv_text lv_nl `  ` ls_ref-kind ` ` ls_ref-name ` x` lv_c INTO rv_text.
    ENDLOOP.

    CONCATENATE rv_text lv_nl
      'ROUTINES - name, lines, complexity score, flags.'
      ' Higher score means more logic. Ask for these by name.'
      INTO rv_text.
    LOOP AT is_result-blocks INTO ls_b.
      lv_n = ls_b-net_lines. CONDENSE lv_n.
      lv_c = ls_b-score.     CONDENSE lv_c.
      lv_s = ls_b-from.      CONDENSE lv_s.
*     name first and blanks as backquote literals: '  ' is empty in
*     CONCATENATE, which glued "EVENTINITIALIZATION" (12.10.2026)
      CONCATENATE rv_text lv_nl `  ` ls_b-name ` (` ls_b-kind `)`
                  ` line ` lv_s ` lines ` lv_n ` score ` lv_c INTO rv_text.
      IF ls_b-boilerplate = abap_true.
        CONCATENATE rv_text ` [screen or ALV setup - skip unless asked]` INTO rv_text.
      ENDIF.
      IF ls_b-db_stmts > 0.
        lv_c = ls_b-db_stmts. CONDENSE lv_c.
        CONCATENATE rv_text ` [` lv_c ` DB statements]` INTO rv_text.
      ENDIF.
    ENDLOOP.

    CONCATENATE rv_text lv_nl 'SELECTION SCREEN:' INTO rv_text.
    LOOP AT is_result-params INTO lv_n.
      CONCATENATE rv_text lv_nl `  ` lv_n INTO rv_text.
    ENDLOOP.

    CONCATENATE rv_text lv_nl 'FLAGS:' INTO rv_text.
    IF is_result-has_native = abap_true.
      CONCATENATE rv_text lv_nl '  uses Native SQL' INTO rv_text.
    ENDIF.
    IF is_result-has_auth = abap_false.
      CONCATENATE rv_text lv_nl '  no AUTHORITY-CHECK anywhere in the object' INTO rv_text.
    ENDIF.
    IF is_result-has_commit = abap_true.
      CONCATENATE rv_text lv_nl '  issues COMMIT WORK' INTO rv_text.
    ENDIF.
    IF is_result-has_enqueue = abap_true.
      CONCATENATE rv_text lv_nl '  uses ENQUEUE' INTO rv_text.
    ENDIF.
    IF is_result-has_dataset = abap_true.
      CONCATENATE rv_text lv_nl '  uses OPEN DATASET' INTO rv_text.
    ENDIF.
    IF is_result-has_submit = abap_true.
      CONCATENATE rv_text lv_nl '  submits another program' INTO rv_text.
    ENDIF.
    lv_n = is_result-max_nesting. CONDENSE lv_n.
    CONCATENATE rv_text lv_nl '  deepest nesting ' lv_n INTO rv_text.

    CONCATENATE rv_text lv_nl
      `The source of the highest scoring routines follows. `
      `Everything else is summarised above - do not ask for it unless `
      'the summary is genuinely insufficient for the question.'
      INTO rv_text.

  ENDMETHOD.


  METHOD to_text.

    DATA ls_ref  TYPE ty_ref.
    DATA lv_list TYPE string.
    DATA lv_n    TYPE string.
    DATA lv_cnt  TYPE i.
    DATA lv_nl   TYPE string.

    lv_nl = cl_abap_char_utilities=>newline.

    lv_n = is_result-lines_total. CONDENSE lv_n.
    CONCATENATE is_result-object 'has' lv_n 'lines'
      INTO rv_text SEPARATED BY space.
    lv_n = is_result-lines_net. CONDENSE lv_n.
    CONCATENATE rv_text '(' lv_n 'after removing comments and formatting).'
      INTO rv_text SEPARATED BY space.

    lv_cnt = lines( is_result-params ).
    IF lv_cnt > 0.
      lv_n = lv_cnt. CONDENSE lv_n.
      CONCATENATE rv_text lv_nl 'Selection screen:' lv_n 'parameters or select-options.'
        INTO rv_text.
    ENDIF.

    CLEAR lv_list.
    LOOP AT is_result-refs INTO ls_ref WHERE kind = 'READ'.
      IF lv_list IS INITIAL.
        lv_list = ls_ref-name.
      ELSE.
        CONCATENATE lv_list ls_ref-name INTO lv_list SEPARATED BY ', '.
      ENDIF.
    ENDLOOP.
    IF lv_list IS NOT INITIAL.
      CONCATENATE rv_text lv_nl 'Reads:' lv_list INTO rv_text SEPARATED BY space.
    ENDIF.

    CLEAR lv_list.
    LOOP AT is_result-refs INTO ls_ref WHERE kind = 'WRITE'.
      IF lv_list IS INITIAL.
        lv_list = ls_ref-name.
      ELSE.
        CONCATENATE lv_list ls_ref-name INTO lv_list SEPARATED BY ', '.
      ENDIF.
    ENDLOOP.
    IF lv_list IS INITIAL.
      CONCATENATE rv_text lv_nl 'Writes: nothing - this object only reads.' INTO rv_text.
    ELSE.
      CONCATENATE rv_text lv_nl 'Writes:' lv_list INTO rv_text SEPARATED BY space.
    ENDIF.

    CLEAR lv_list.
    LOOP AT is_result-refs INTO ls_ref WHERE kind = 'CALLBAPI'.
      IF lv_list IS INITIAL.
        lv_list = ls_ref-name.
      ELSE.
        CONCATENATE lv_list ls_ref-name INTO lv_list SEPARATED BY ', '.
      ENDIF.
    ENDLOOP.
    IF lv_list IS NOT INITIAL.
      CONCATENATE rv_text lv_nl 'Calls BAPIs:' lv_list INTO rv_text SEPARATED BY space.
    ENDIF.

    lv_cnt = lines( is_result-blocks ).
    lv_n = lv_cnt. CONDENSE lv_n.
    CONCATENATE rv_text lv_nl 'Structure:' lv_n 'routines.'
      INTO rv_text SEPARATED BY space.

    lv_n = is_result-max_nesting. CONDENSE lv_n.
    CONCATENATE rv_text lv_nl 'Deepest nesting:' lv_n 'levels.'
      INTO rv_text SEPARATED BY space.

    IF is_result-has_native = abap_true.
      CONCATENATE rv_text lv_nl 'Uses Native SQL.' INTO rv_text.
    ENDIF.
    IF is_result-has_auth = abap_false.
      CONCATENATE rv_text lv_nl 'No AUTHORITY-CHECK found.' INTO rv_text.
    ENDIF.
    IF is_result-has_commit = abap_true.
      CONCATENATE rv_text lv_nl 'Issues COMMIT WORK.' INTO rv_text.
    ENDIF.
    IF is_result-has_enqueue = abap_true.
      CONCATENATE rv_text lv_nl 'Uses the lock mechanism.' INTO rv_text.
    ENDIF.
    IF is_result-has_dataset = abap_true.
      CONCATENATE rv_text lv_nl 'Reads or writes application server files.' INTO rv_text.
    ENDIF.
    IF is_result-has_submit = abap_true.
      CONCATENATE rv_text lv_nl 'Submits another program.' INTO rv_text.
    ENDIF.

    IF is_result-confidence < 100.
      lv_n = is_result-confidence. CONDENSE lv_n.
      CONCATENATE rv_text lv_nl 'Parse confidence' lv_n 'percent:' is_result-conf_note
        INTO rv_text SEPARATED BY space.
    ENDIF.

  ENDMETHOD.


  METHOD token_after.

    DATA lt_tok TYPE string_table.
    DATA lv_tok TYPE string.
    DATA lv_hit TYPE abap_bool.

    SPLIT iv_text AT space INTO TABLE lt_tok.

    LOOP AT lt_tok INTO lv_tok.
      IF lv_hit = abap_true.
        rv_out = lv_tok.
        REPLACE ALL OCCURRENCES OF '.'  IN rv_out WITH ''.
        REPLACE ALL OCCURRENCES OF ','  IN rv_out WITH ''.
        REPLACE ALL OCCURRENCES OF '''' IN rv_out WITH ''.
        CONDENSE rv_out.
        RETURN.
      ENDIF.
      IF lv_tok = iv_keyword.
        lv_hit = abap_true.
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


ENDCLASS.
