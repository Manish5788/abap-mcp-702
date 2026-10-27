*--------------------------------------------------------------------*
* Title       : MCP server request log - display
* Type        : Report (Online)
* Frequency   : On demand
* Description : Lists ZABAPMCP_LOG - every request to the MCP server
*               /sap/bc/mcp, all tools and protocol methods: who, when,
*               which method and tool, how it ended (HTTP code, error,
*               duration, sizes). Double-click a line to read its full
*               request and response bodies. A request that never got
*               its answer recorded (status O, e.g. a dump) shows a
*               yellow light - the place to start when the server
*               misbehaves. Configuration tool calls are also logged,
*               without bodies, in ZMCP_CUST_LOG (transaction
*               ZXM_MCP_LOG).
*--------------------------------------------------------------------*
REPORT zabapmcp_log_view.

TYPE-POOLS icon.

*--------------------------------------------------------------------*
* Global Types (T_)
*--------------------------------------------------------------------*
TYPES: BEGIN OF t_out,
         light      TYPE c LENGTH 4,
         created_on TYPE zabapmcp_log-created_on,
         erzet      TYPE zabapmcp_log-erzet,
         ernam      TYPE zabapmcp_log-ernam,
         method     TYPE zabapmcp_log-method,
         tool_name  TYPE zabapmcp_log-tool_name,
         status     TYPE zabapmcp_log-status,
         http_code  TYPE zabapmcp_log-http_code,
         duration   TYPE zabapmcp_log-duration,
         req_bytes  TYPE zabapmcp_log-req_bytes,
         resp_bytes TYPE zabapmcp_log-resp_bytes,
         err_text   TYPE zabapmcp_log-err_text,
         guid       TYPE zabapmcp_log-guid,
       END OF t_out.

TYPES: BEGIN OF t_line,
         part TYPE c LENGTH 20,
         line TYPE i,
         text TYPE c LENGTH 200,
       END OF t_line.

*--------------------------------------------------------------------*
* Global Internal Tables (I_) / Work Areas (W_) / Variables (V_)
*--------------------------------------------------------------------*
DATA: i_out TYPE STANDARD TABLE OF t_out,
      w_log TYPE zabapmcp_log,
      v_ok  TYPE abap_bool.

*--------------------------------------------------------------------*
* Selection screen
*--------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE text-001.
SELECT-OPTIONS: s_date FOR w_log-created_on OBLIGATORY,
                s_user FOR w_log-ernam,
                s_meth FOR w_log-method LOWER CASE,
                s_tool FOR w_log-tool_name LOWER CASE,
                s_stat FOR w_log-status.
PARAMETERS: p_calls AS CHECKBOX,
            p_max   TYPE i DEFAULT 2000.
SELECTION-SCREEN END OF BLOCK b1.

*----------------------------------------------------------------------*
*       CLASS lcl_view DEFINITION
*----------------------------------------------------------------------*
* The double-click on a list line and the popup with that request's
* full bodies.
*----------------------------------------------------------------------*
CLASS lcl_view DEFINITION FINAL.
  PUBLIC SECTION.
    CLASS-METHODS on_double_click
      FOR EVENT double_click OF cl_salv_events_table
      IMPORTING row column.
    CLASS-METHODS show_bodies
      IMPORTING im_guid TYPE zabapmcp_log-guid.
  PRIVATE SECTION.
    CLASS-METHODS add_chunks
      IMPORTING im_part TYPE csequence
                im_text TYPE string
      CHANGING  ch_lines TYPE STANDARD TABLE.
ENDCLASS.                    "lcl_view DEFINITION

*--------------------------------------------------------------------*
INITIALIZATION.
*--------------------------------------------------------------------*
* the last seven days unless the user picks otherwise
  s_date-sign   = 'I'.
  s_date-option = 'BT'.
  s_date-low    = sy-datum - 7.
  s_date-high   = sy-datum.
  APPEND s_date.

*--------------------------------------------------------------------*
AT SELECTION-SCREEN.
*--------------------------------------------------------------------*
  IF p_max <= 0 OR p_max > 99999.
    MESSAGE text-006 TYPE 'E'.
  ENDIF.

*--------------------------------------------------------------------*
START-OF-SELECTION.
*--------------------------------------------------------------------*
  PERFORM check_authority CHANGING v_ok.
  IF v_ok = abap_false.
    MESSAGE text-003 TYPE 'S' DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.

  PERFORM read_log.
  IF i_out IS INITIAL.
    MESSAGE text-004 TYPE 'S'.
    RETURN.
  ENDIF.

  PERFORM build_output.
  PERFORM display_output.

*&---------------------------------------------------------------------*
*&      Form  CHECK_AUTHORITY
*&---------------------------------------------------------------------*
* The log holds whole requests and answers - source code and
* configuration that was read - so it gets the protection of the table
* itself in SE16: S_TABU_DIS for its authorization group (TDDAT, &NC&
* when it has none), or else S_TABU_NAM for the table. Display (03).
*----------------------------------------------------------------------*
FORM check_authority CHANGING pr_ok TYPE abap_bool.

  DATA lv_group TYPE brgru.

  pr_ok = abap_false.

* AI tools administration function LOG (Z_AI_ADM through ZCL_AI_AUTH,
* 23.10.2026), on top of the table's own display authorization
  IF zcl_ai_auth=>check_admin( zcl_ai_auth=>c_adm-log ) = abap_false.
    RETURN.
  ENDIF.

  SELECT SINGLE cclass FROM tddat INTO lv_group
    WHERE tabname = 'ZABAPMCP_LOG'.
  IF lv_group IS INITIAL.
    lv_group = '&NC&'.
  ENDIF.

  AUTHORITY-CHECK OBJECT 'S_TABU_DIS'
    ID 'ACTVT'     FIELD '03'
    ID 'DICBERCLS' FIELD lv_group.
  IF sy-subrc = 0.
    pr_ok = abap_true.
    RETURN.
  ENDIF.

  AUTHORITY-CHECK OBJECT 'S_TABU_NAM'
    ID 'ACTVT' FIELD '03'
    ID 'TABLE' FIELD 'ZABAPMCP_LOG'.
  IF sy-subrc = 0.
    pr_ok = abap_true.
  ENDIF.

ENDFORM.                    "check_authority

*&---------------------------------------------------------------------*
*&      Form  READ_LOG
*&---------------------------------------------------------------------*
* The selected requests, newest first - without the bodies, which can
* hold 20,000 characters each and are read only when a line is opened.
* Dates and times are as the server wrote them (server time).
*----------------------------------------------------------------------*
FORM read_log.

  DATA lr_calls TYPE RANGE OF zabapmcp_log-method.
  DATA lw_call  LIKE LINE OF lr_calls.

* only tool calls: hides the handshake, list and ping traffic
  IF p_calls = abap_true.
    lw_call-sign   = 'I'.
    lw_call-option = 'EQ'.
    lw_call-low    = 'tools/call'.
    APPEND lw_call TO lr_calls.
  ENDIF.

  SELECT guid created_on erzet ernam method tool_name status
         http_code duration req_bytes resp_bytes err_text
    FROM zabapmcp_log
    INTO CORRESPONDING FIELDS OF TABLE i_out
    UP TO p_max ROWS
    WHERE created_on IN s_date
      AND ernam      IN s_user
      AND method     IN s_meth
      AND method     IN lr_calls
      AND tool_name  IN s_tool
      AND status     IN s_stat
    ORDER BY created_on DESCENDING erzet DESCENDING.

ENDFORM.                    "read_log

*&---------------------------------------------------------------------*
*&      Form  BUILD_OUTPUT
*&---------------------------------------------------------------------*
* A light per line: green answered, red error, yellow no answer
* recorded - the request ended before the log was closed, e.g. by a
* dump. Ends with a count per status in the status bar.
*----------------------------------------------------------------------*
FORM build_output.

  DATA lv_ok    TYPE i.
  DATA lv_err   TYPE i.
  DATA lv_open  TYPE i.
  DATA lv_all   TYPE i.
  DATA lv_c_all TYPE c LENGTH 10.
  DATA lv_c_ok  TYPE c LENGTH 10.
  DATA lv_c_err TYPE c LENGTH 10.
  DATA lv_c_opn TYPE c LENGTH 10.
  DATA lv_msg   TYPE string.

  FIELD-SYMBOLS <lf_out> TYPE t_out.

  LOOP AT i_out ASSIGNING <lf_out>.
    CASE <lf_out>-status.
      WHEN 'S'.
        <lf_out>-light = icon_green_light.
        lv_ok = lv_ok + 1.
      WHEN 'E'.
        <lf_out>-light = icon_red_light.
        lv_err = lv_err + 1.
      WHEN OTHERS.
        <lf_out>-light = icon_yellow_light.
        lv_open = lv_open + 1.
    ENDCASE.
  ENDLOOP.

* numbers move into text right-aligned - CONDENSE before joining
  DESCRIBE TABLE i_out LINES lv_all.
  lv_c_all = lv_all.
  lv_c_ok  = lv_ok.
  lv_c_err = lv_err.
  lv_c_opn = lv_open.
  CONDENSE: lv_c_all, lv_c_ok, lv_c_err, lv_c_opn.
  CONCATENATE lv_c_all text-007 lv_c_ok text-008 lv_c_err text-009 lv_c_opn text-010
    INTO lv_msg SEPARATED BY space.
  MESSAGE lv_msg TYPE 'S'.

ENDFORM.                    "build_output

*&---------------------------------------------------------------------*
*&      Form  DISPLAY_OUTPUT
*&---------------------------------------------------------------------*
* ALV list with the standard toolbar. The log's data elements are
* generic (CHAR40, INT4 ...), so the columns get their own titles; the
* technical key is hidden. Double-click opens the bodies.
*----------------------------------------------------------------------*
FORM display_output.

  DATA lo_salv    TYPE REF TO cl_salv_table.
  DATA lo_funcs   TYPE REF TO cl_salv_functions_list.
  DATA lo_columns TYPE REF TO cl_salv_columns_table.
  DATA lo_column  TYPE REF TO cl_salv_column_table.
  DATA lo_events  TYPE REF TO cl_salv_events_table.

  TRY.
      cl_salv_table=>factory(
        IMPORTING r_salv_table = lo_salv
        CHANGING  t_table      = i_out ).

      lo_funcs = lo_salv->get_functions( ).
      lo_funcs->set_all( abap_true ).

      lo_columns = lo_salv->get_columns( ).
      lo_columns->set_optimize( abap_true ).

      lo_column ?= lo_columns->get_column( 'LIGHT' ).
      lo_column->set_icon( if_salv_c_bool_sap=>true ).
      PERFORM set_title USING lo_column text-011.
      lo_column ?= lo_columns->get_column( 'METHOD' ).
      PERFORM set_title USING lo_column text-012.
      lo_column ?= lo_columns->get_column( 'TOOL_NAME' ).
      PERFORM set_title USING lo_column text-013.
      lo_column ?= lo_columns->get_column( 'STATUS' ).
      PERFORM set_title USING lo_column text-014.
      lo_column ?= lo_columns->get_column( 'HTTP_CODE' ).
      PERFORM set_title USING lo_column text-015.
      lo_column ?= lo_columns->get_column( 'DURATION' ).
      PERFORM set_title USING lo_column text-016.
      lo_column ?= lo_columns->get_column( 'REQ_BYTES' ).
      PERFORM set_title USING lo_column text-017.
      lo_column ?= lo_columns->get_column( 'RESP_BYTES' ).
      PERFORM set_title USING lo_column text-018.
      lo_column ?= lo_columns->get_column( 'ERR_TEXT' ).
      PERFORM set_title USING lo_column text-019.
      lo_column ?= lo_columns->get_column( 'GUID' ).
      lo_column->set_visible( abap_false ).

      lo_events = lo_salv->get_event( ).
      SET HANDLER lcl_view=>on_double_click FOR lo_events.

      lo_salv->display( ).

    CATCH cx_salv_msg cx_salv_not_found.
      MESSAGE text-005 TYPE 'S' DISPLAY LIKE 'E'.
  ENDTRY.

ENDFORM.                    "display_output

*&---------------------------------------------------------------------*
*&      Form  SET_TITLE
*&---------------------------------------------------------------------*
* One title for all three column-heading lengths.
*----------------------------------------------------------------------*
FORM set_title USING pr_column TYPE REF TO cl_salv_column_table
                     pv_text   TYPE csequence.

  DATA lv_s TYPE scrtext_s.
  DATA lv_m TYPE scrtext_m.
  DATA lv_l TYPE scrtext_l.

  lv_s = pv_text.
  lv_m = pv_text.
  lv_l = pv_text.
  pr_column->set_short_text( lv_s ).
  pr_column->set_medium_text( lv_m ).
  pr_column->set_long_text( lv_l ).

ENDFORM.                    "set_title

*----------------------------------------------------------------------*
*       CLASS lcl_view IMPLEMENTATION
*----------------------------------------------------------------------*
CLASS lcl_view IMPLEMENTATION.

  METHOD on_double_click.
*   the line the user double-clicked - its bodies in a popup
    DATA lw_out TYPE t_out.

    READ TABLE i_out INTO lw_out INDEX row.
    IF sy-subrc = 0.
      show_bodies( lw_out-guid ).
    ENDIF.
  ENDMETHOD.                    "on_double_click

  METHOD show_bodies.
*   request and response of one log row, 200 characters per line, in an
*   ALV popup - read here, not with the list, as they can be large
    DATA lv_req   TYPE string.
    DATA lv_resp  TYPE string.
    DATA li_lines TYPE STANDARD TABLE OF t_line.
    DATA lo_pop   TYPE REF TO cl_salv_table.
    DATA lo_cols  TYPE REF TO cl_salv_columns_table.

    SELECT SINGLE req_body resp_body FROM zabapmcp_log
      INTO (lv_req, lv_resp)
      WHERE guid = im_guid.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    add_chunks( EXPORTING im_part  = text-020
                          im_text  = lv_req
                CHANGING  ch_lines = li_lines ).
    add_chunks( EXPORTING im_part  = text-021
                          im_text  = lv_resp
                CHANGING  ch_lines = li_lines ).

    TRY.
        cl_salv_table=>factory(
          IMPORTING r_salv_table = lo_pop
          CHANGING  t_table      = li_lines ).
        lo_cols = lo_pop->get_columns( ).
        lo_cols->set_optimize( abap_true ).
        lo_pop->set_screen_popup(
          start_column = 5  end_column = 170
          start_line   = 3  end_line   = 25 ).
        lo_pop->display( ).
      CATCH cx_salv_msg.
        MESSAGE text-005 TYPE 'S' DISPLAY LIKE 'E'.
    ENDTRY.
  ENDMETHOD.                    "show_bodies

  METHOD add_chunks.
*   im_text cut into 200-character lines under the label im_part; an
*   empty body still gets one line, so the popup shows it was empty
    DATA lw_line TYPE t_line.
    DATA lv_len  TYPE i.
    DATA lv_off  TYPE i.
    DATA lv_n    TYPE i.

    lw_line-part = im_part.
    lv_len = strlen( im_text ).
    IF lv_len = 0.
      lw_line-line = 1.
      lw_line-text = text-022.
      APPEND lw_line TO ch_lines.
      RETURN.
    ENDIF.

    WHILE lv_off < lv_len.
      lv_n = lv_len - lv_off.
      IF lv_n > 200.
        lv_n = 200.
      ENDIF.
      lw_line-line = lw_line-line + 1.
      lw_line-text = im_text+lv_off(lv_n).
      APPEND lw_line TO ch_lines.
      lv_off = lv_off + lv_n.
    ENDWHILE.
  ENDMETHOD.                    "add_chunks

ENDCLASS.                    "lcl_view IMPLEMENTATION
