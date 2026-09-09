REPORT zabapmcp_log_view.
*&---------------------------------------------------------------------*
*& MCP request log viewer.
*&
*& The MCP server has no console and no traceback. When a client fails
*& to connect, or connects and shows no tools, this report is where the
*& answer is.
*&
*& The "problems only" flag is the one to use first - it surfaces the
*& three failure patterns that account for nearly everything:
*&
*&   NOTIFY-ANSWERED  a notification received a response body. This is
*&                    why a client hangs on connect and never finishes
*&                    its handshake. The single most common cause.
*&   RPC-ERROR        the response carried a JSON-RPC error object
*&   CAUGHT           an ABAP exception was caught during dispatch
*&   OPEN             the row was never closed, so the work process
*&                    died mid-request. Look in ST22.
*&
*& NW 7.02 syntax only.
*&---------------------------------------------------------------------*

TABLES zabapmcp_log.

TYPES: BEGIN OF ty_out,
         created_on TYPE zabapmcp_log-created_on,
         created_at TYPE zabapmcp_log-created_at,
         uname      TYPE zabapmcp_log-uname,
         method     TYPE zabapmcp_log-method,
         tool_name  TYPE zabapmcp_log-tool_name,
         has_id     TYPE zabapmcp_log-has_id,
         http_code  TYPE zabapmcp_log-http_code,
         duration   TYPE zabapmcp_log-duration,
         status     TYPE zabapmcp_log-status,
         problem    TYPE string,
         req_bytes  TYPE zabapmcp_log-req_bytes,
         resp_bytes TYPE zabapmcp_log-resp_bytes,
         err_text   TYPE zabapmcp_log-err_text,
         guid       TYPE zabapmcp_log-guid,
       END OF ty_out.

DATA gt_out  TYPE STANDARD TABLE OF ty_out.
DATA gs_out  TYPE ty_out.
DATA gt_log  TYPE STANDARD TABLE OF zabapmcp_log.
DATA gs_log  TYPE zabapmcp_log.
DATA gv_prob TYPE i.

SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE text-001.
SELECT-OPTIONS s_date FOR zabapmcp_log-created_on DEFAULT sy-datum.
SELECT-OPTIONS s_user FOR zabapmcp_log-uname.
SELECT-OPTIONS s_meth FOR zabapmcp_log-method.
PARAMETERS     p_prob AS CHECKBOX.
PARAMETERS     p_max  TYPE i DEFAULT 200.
SELECTION-SCREEN END OF BLOCK b1.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE text-002.
PARAMETERS p_guid TYPE zabapmcp_log-guid.
SELECTION-SCREEN END OF BLOCK b2.

*----------------------------------------------------------------------*
START-OF-SELECTION.

  IF p_guid IS NOT INITIAL.
    PERFORM show_one.
    RETURN.
  ENDIF.

  SELECT * FROM zabapmcp_log
    INTO TABLE gt_log
    UP TO p_max ROWS
    WHERE created_on IN s_date
      AND uname      IN s_user
      AND method     IN s_meth
    ORDER BY created_on DESCENDING created_at DESCENDING.

  IF gt_log IS INITIAL.
    WRITE: / 'No log entries for that selection.'.
    WRITE: / 'If the client never reached the server at all, check the ICF node is active in SICF.'.
    RETURN.
  ENDIF.

  LOOP AT gt_log INTO gs_log.

    CLEAR gs_out.
    MOVE-CORRESPONDING gs_log TO gs_out.

*   ---- classify -----------------------------------------------------
*   A notification that received a body is the bug worth shouting
*   about, so it is checked first.
    IF gs_log-has_id IS INITIAL
       AND gs_log-resp_body IS NOT INITIAL
       AND gs_log-resp_body <> '(body capture disabled)'.
      gs_out-problem = 'NOTIFY-ANSWERED'.
    ELSEIF gs_log-status = 'O'.
      gs_out-problem = 'OPEN'.
    ELSEIF gs_log-status = 'E'.
      gs_out-problem = 'CAUGHT'.
    ELSEIF gs_log-resp_body CS '"error"'.
      gs_out-problem = 'RPC-ERROR'.
    ENDIF.

    IF p_prob = abap_true AND gs_out-problem IS INITIAL.
      CONTINUE.
    ENDIF.

    IF gs_out-problem IS NOT INITIAL.
      gv_prob = gv_prob + 1.
    ENDIF.

    APPEND gs_out TO gt_out.

  ENDLOOP.

  PERFORM show_list.

*----------------------------------------------------------------------*
FORM show_list.

  DATA lv_n TYPE i.

  DESCRIBE TABLE gt_out LINES lv_n.

  WRITE: / 'MCP request log'.
  ULINE.
  WRITE: / 'Rows shown:', lv_n, '  Problems:', gv_prob.
  ULINE.

  WRITE: /(10) 'Date',
          (10) 'Time',
          (12) 'User',
          (26) 'Method',
          (22) 'Tool',
          (3)  'Id',
          (5)  'Code',
          (8)  'ms',
          (16) 'Problem',
          (34) 'GUID'.
  ULINE.

  LOOP AT gt_out INTO gs_out.

    IF gs_out-problem IS NOT INITIAL.
      FORMAT COLOR COL_NEGATIVE.
    ELSE.
      FORMAT COLOR COL_NORMAL.
    ENDIF.

    WRITE: /(10) gs_out-created_on,
            (10) gs_out-created_at,
            (12) gs_out-uname,
            (26) gs_out-method,
            (22) gs_out-tool_name,
            (3)  gs_out-has_id,
            (5)  gs_out-http_code,
            (8)  gs_out-duration,
            (16) gs_out-problem,
            (34) gs_out-guid.

    IF gs_out-err_text IS NOT INITIAL.
      WRITE: /12 gs_out-err_text.
    ENDIF.

  ENDLOOP.

  FORMAT COLOR COL_NORMAL.
  ULINE.
  WRITE: / 'Paste a GUID into the second selection block to see the full request and response.'.

ENDFORM.

*----------------------------------------------------------------------*
FORM show_one.

  DATA ls_log TYPE zabapmcp_log.

  SELECT SINGLE * FROM zabapmcp_log INTO ls_log
    WHERE guid = p_guid.

  IF sy-subrc <> 0.
    WRITE: / 'No entry with that GUID.'.
    RETURN.
  ENDIF.

  WRITE: / 'MCP request', ls_log-guid.
  ULINE.
  WRITE: / 'When     :', ls_log-created_on, ls_log-created_at.
  WRITE: / 'User     :', ls_log-uname.
  WRITE: / 'Method   :', ls_log-method.
  IF ls_log-tool_name IS NOT INITIAL.
    WRITE: / 'Tool     :', ls_log-tool_name.
  ENDIF.
  WRITE: / 'Has id   :', ls_log-has_id.
  WRITE: / 'HTTP     :', ls_log-http_code.
  WRITE: / 'Duration :', ls_log-duration, 'ms'.
  WRITE: / 'Status   :', ls_log-status.
  IF ls_log-err_text IS NOT INITIAL.
    WRITE: / 'Error    :', ls_log-err_text.
  ENDIF.

  IF ls_log-has_id IS INITIAL AND ls_log-resp_body IS NOT INITIAL.
    ULINE.
    FORMAT COLOR COL_NEGATIVE.
    WRITE: / 'PROBLEM: this was a notification and it received a response body.'.
    WRITE: / 'A JSON-RPC notification has no id and must get no response. The client'.
    WRITE: / 'is waiting for a handshake that will never complete. Return HTTP 202'.
    WRITE: / 'with an empty body when the request has no id.'.
    FORMAT COLOR COL_NORMAL.
  ENDIF.

  ULINE.
  WRITE: / 'REQUEST', ls_log-req_bytes, 'bytes'.
  ULINE.
  PERFORM wrap USING ls_log-req_body.

  ULINE.
  WRITE: / 'RESPONSE', ls_log-resp_bytes, 'bytes'.
  ULINE.
  PERFORM wrap USING ls_log-resp_body.

ENDFORM.

*----------------------------------------------------------------------*
FORM wrap USING iv_text TYPE string.

  DATA lv_rest TYPE string.
  DATA lv_line TYPE string.
  DATA lv_len  TYPE i.

  IF iv_text IS INITIAL.
    WRITE: / '(empty)'.
    RETURN.
  ENDIF.

  lv_rest = iv_text.

  WHILE lv_rest IS NOT INITIAL.
    lv_len = strlen( lv_rest ).
    IF lv_len > 110.
      lv_line = lv_rest(110).
      lv_rest = lv_rest+110.
    ELSE.
      lv_line = lv_rest.
      CLEAR lv_rest.
    ENDIF.
    WRITE: / lv_line.
  ENDWHILE.

ENDFORM.
