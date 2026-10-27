*--------------------------------------------------------------------*
* Title       : MCP configuration tool call log - display
* Type        : Report (Online)
* Frequency   : On demand
* Description : Lists ZMCP_CUST_LOG - every call of the configuration
*               tools on /sap/bc/mcp (sap_tcode_info, sap_find_config,
*               sap_read_config): who asked for which table,
*               transaction or search, and whether it was answered,
*               refused (policy or authorization) or failed. Times are
*               shown in the user's own time zone, newest first.
*--------------------------------------------------------------------*
REPORT zabapmcp_custlog_view.

TYPE-POOLS icon.

*--------------------------------------------------------------------*
* Global Types (T_)
*--------------------------------------------------------------------*
TYPES: BEGIN OF t_out,
         light      TYPE c LENGTH 4,
         log_date   TYPE sydatum,
         log_time   TYPE syuzeit,
         uname      TYPE syuname,
         tool       TYPE zmcp_cl_tool,
         status     TYPE zmcp_cl_status,
         target     TYPE zmcp_cl_target,
         rows_ret   TYPE zmcp_cl_rows,
         rows_total TYPE zmcp_cl_total,
         duration   TYPE zmcp_cl_duration,
         message    TYPE zmcp_cl_message,
         args       TYPE zmcp_cl_args,
       END OF t_out.

*--------------------------------------------------------------------*
* Global Internal Tables (I_) / Work Areas (W_) / Variables (V_)
*--------------------------------------------------------------------*
DATA: i_log   TYPE STANDARD TABLE OF zmcp_cust_log,
      i_out   TYPE STANDARD TABLE OF t_out,
      w_log   TYPE zmcp_cust_log,
      v_ok    TYPE abap_bool,
      v_ts_lo TYPE timestampl,
      v_ts_hi TYPE timestampl.

*--------------------------------------------------------------------*
* Selection screen
*--------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE text-001.
PARAMETERS: p_from TYPE sydatum OBLIGATORY,
            p_to   TYPE sydatum OBLIGATORY.
SELECT-OPTIONS: s_uname FOR w_log-uname,
                s_tool  FOR w_log-tool LOWER CASE,
                s_stat  FOR w_log-status,
                s_targ  FOR w_log-target LOWER CASE.
PARAMETERS: p_max TYPE i DEFAULT 5000.
SELECTION-SCREEN END OF BLOCK b1.

*--------------------------------------------------------------------*
INITIALIZATION.
*--------------------------------------------------------------------*
* the last seven days unless the user picks otherwise
  p_to   = sy-datum.
  p_from = sy-datum - 7.

*--------------------------------------------------------------------*
AT SELECTION-SCREEN.
*--------------------------------------------------------------------*
  IF p_from > p_to.
    MESSAGE text-002 TYPE 'E'.
  ENDIF.
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
  IF i_log IS INITIAL.
    MESSAGE text-004 TYPE 'S'.
    RETURN.
  ENDIF.

  PERFORM build_output.
  PERFORM display_output.

*&---------------------------------------------------------------------*
*&      Form  CHECK_AUTHORITY
*&---------------------------------------------------------------------*
* The log shows who read which configuration, so it gets the same
* protection as the table itself in SE16: S_TABU_DIS for its
* authorization group (TDDAT, &NC& when it has none), or else
* S_TABU_NAM for the table by name. Display (03) in both.
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
    WHERE tabname = 'ZMCP_CUST_LOG'.
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
    ID 'TABLE' FIELD 'ZMCP_CUST_LOG'.
  IF sy-subrc = 0.
    pr_ok = abap_true.
  ENDIF.

ENDFORM.                    "check_authority

*&---------------------------------------------------------------------*
*&      Form  READ_LOG
*&---------------------------------------------------------------------*
* Calls in the selected days, newest first. The log stores UTC time
* stamps, so the user's days are turned into UTC bounds first: from
* the start of P_FROM to the last moment of P_TO in the user's zone.
*----------------------------------------------------------------------*
FORM read_log.

  DATA lv_time TYPE syuzeit.

  lv_time = '000000'.
  CONVERT DATE p_from TIME lv_time INTO TIME STAMP v_ts_lo TIME ZONE sy-zonlo.
  lv_time = '235959'.
  CONVERT DATE p_to TIME lv_time INTO TIME STAMP v_ts_hi TIME ZONE sy-zonlo.
* the whole last second of P_TO
  v_ts_hi = v_ts_hi + '0.9999999'.

  SELECT * FROM zmcp_cust_log INTO TABLE i_log
    UP TO p_max ROWS
    WHERE tstamp BETWEEN v_ts_lo AND v_ts_hi
      AND uname  IN s_uname
      AND tool   IN s_tool
      AND status IN s_stat
      AND target IN s_targ
    ORDER BY tstamp DESCENDING.

ENDFORM.                    "read_log

*&---------------------------------------------------------------------*
*&      Form  BUILD_OUTPUT
*&---------------------------------------------------------------------*
* One list line per call: local date and time, and a traffic light for
* how the call ended - green answered, yellow refused, red failed.
* Ends with a count per status in the status bar.
*----------------------------------------------------------------------*
FORM build_output.

  DATA lw_out    TYPE t_out.
  DATA lv_ok     TYPE i.
  DATA lv_refuse TYPE i.
  DATA lv_err    TYPE i.
  DATA lv_all    TYPE i.
  DATA lv_c_all  TYPE c LENGTH 10.
  DATA lv_c_ok   TYPE c LENGTH 10.
  DATA lv_c_ref  TYPE c LENGTH 10.
  DATA lv_c_err  TYPE c LENGTH 10.
  DATA lv_msg    TYPE string.

  LOOP AT i_log INTO w_log.
    CLEAR lw_out.
    MOVE-CORRESPONDING w_log TO lw_out.
    CONVERT TIME STAMP w_log-tstamp TIME ZONE sy-zonlo
      INTO DATE lw_out-log_date TIME lw_out-log_time.

    CASE w_log-status.
      WHEN 'O'.
        lw_out-light = icon_green_light.
        lv_ok = lv_ok + 1.
      WHEN 'R'.
        lw_out-light = icon_yellow_light.
        lv_refuse = lv_refuse + 1.
      WHEN OTHERS.
        lw_out-light = icon_red_light.
        lv_err = lv_err + 1.
    ENDCASE.

    APPEND lw_out TO i_out.
  ENDLOOP.

* numbers move into text right-aligned - CONDENSE before joining
  DESCRIBE TABLE i_out LINES lv_all.
  lv_c_all = lv_all.
  lv_c_ok  = lv_ok.
  lv_c_ref = lv_refuse.
  lv_c_err = lv_err.
  CONDENSE: lv_c_all, lv_c_ok, lv_c_ref, lv_c_err.
  CONCATENATE lv_c_all text-007 lv_c_ok text-008 lv_c_ref text-009 lv_c_err text-010
    INTO lv_msg SEPARATED BY space.
  MESSAGE lv_msg TYPE 'S'.

ENDFORM.                    "build_output

*&---------------------------------------------------------------------*
*&      Form  DISPLAY_OUTPUT
*&---------------------------------------------------------------------*
* ALV list with the standard toolbar (sort, filter, export). Column
* titles come from the ZMCP_CL_* data elements; only the traffic light
* and the converted date/time columns get their own titles.
*----------------------------------------------------------------------*
FORM display_output.

  DATA lo_salv    TYPE REF TO cl_salv_table.
  DATA lo_funcs   TYPE REF TO cl_salv_functions_list.
  DATA lo_columns TYPE REF TO cl_salv_columns_table.
  DATA lo_column  TYPE REF TO cl_salv_column_table.
  DATA lv_text_s  TYPE scrtext_s.
  DATA lv_text_m  TYPE scrtext_m.

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
      lv_text_s = text-005.
      lo_column->set_short_text( lv_text_s ).

      lo_column ?= lo_columns->get_column( 'LOG_DATE' ).
      lv_text_s = text-011.
      lv_text_m = text-011.
      lo_column->set_short_text( lv_text_s ).
      lo_column->set_medium_text( lv_text_m ).

      lo_column ?= lo_columns->get_column( 'LOG_TIME' ).
      lv_text_s = text-012.
      lv_text_m = text-012.
      lo_column->set_short_text( lv_text_s ).
      lo_column->set_medium_text( lv_text_m ).

      lo_salv->display( ).

    CATCH cx_salv_msg cx_salv_not_found.
      MESSAGE text-013 TYPE 'S' DISPLAY LIKE 'E'.
  ENDTRY.

ENDFORM.                    "display_output
