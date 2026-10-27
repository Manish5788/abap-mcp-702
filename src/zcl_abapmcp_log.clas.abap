CLASS zcl_abapmcp_log DEFINITION PUBLIC FINAL CREATE PUBLIC.
*&---------------------------------------------------------------------*
*& Request log for the MCP server.
*&
*& WHY THIS EXISTS
*& A Python MCP server fails loudly - you get a stack trace. This one
*& fails as a client that connects and then does nothing, because a
*& notification got a response body or an id came back as the wrong
*& type. There is no traceback and no console.
*&
*& So the log is not optional infrastructure here, it is the only
*& debugging surface. Written on entry with the raw request, updated
*& before the response is sent. A failed handshake leaves a row showing
*& exactly what the client sent and what we returned.
*&
*& PRIVACY
*& Raw bodies contain whatever was asked - object names, and in a
*& tools/call the arguments. Body capture is controlled by ZABAPMCP_CFG
*& and should be switched off once a deployment is stable. Retention is
*& the caller's responsibility; see the housekeeping note in README.
*&
*& NEVER LET LOGGING BREAK THE REQUEST
*& Every method here swallows its own errors. A logging failure must
*& not turn a working tool call into an error response.
*&
*& NW 7.02 syntax only.
*&---------------------------------------------------------------------*
  PUBLIC SECTION.

    CONSTANTS c_max_body TYPE i VALUE 20000.

*   Opens a row and returns its key. Call this FIRST, before parsing,
*   so a body that fails to parse is still recorded.
    CLASS-METHODS open
      IMPORTING iv_body        TYPE string
      RETURNING VALUE(rv_guid) TYPE string.

*   Fills in what parsing revealed. Safe to skip if parsing failed.
    CLASS-METHODS set_method
      IMPORTING iv_guid   TYPE string
                iv_method TYPE string
                iv_has_id TYPE abap_bool
                iv_tool   TYPE string OPTIONAL.

*   Closes the row with the response and duration.
    CLASS-METHODS close
      IMPORTING iv_guid     TYPE string
                iv_response TYPE string
                iv_code     TYPE i
                iv_error    TYPE string OPTIONAL.

*   Is body capture switched on? Read from ZABAPMCP_CFG, default on.
    CLASS-METHODS capture_bodies
      RETURNING VALUE(rv_on) TYPE abap_bool.

PROTECTED SECTION.

  PRIVATE SECTION.

    CLASS-DATA gv_t0 TYPE i.

    CLASS-METHODS truncate
      IMPORTING iv_in         TYPE string
      RETURNING VALUE(rv_out) TYPE string.

ENDCLASS.


CLASS zcl_abapmcp_log IMPLEMENTATION.

  METHOD capture_bodies.

    DATA lv_val TYPE zabapmcp_cfg-cfg_value.

    rv_on = abap_true.

    SELECT SINGLE cfg_value FROM zabapmcp_cfg INTO lv_val
      WHERE cfg_key = 'CAPTURE_BODIES'.

    IF sy-subrc = 0 AND lv_val = 'OFF'.
      rv_on = abap_false.
    ENDIF.

  ENDMETHOD.


  METHOD close.

    DATA lv_guid TYPE zabapmcp_log-guid.
    DATA lv_resp TYPE string.
    DATA lv_code TYPE zabapmcp_log-http_code.
    DATA lv_err  TYPE zabapmcp_log-err_text.
    DATA lv_stat TYPE zabapmcp_log-status.
    DATA lv_dur  TYPE i.
    DATA lv_t1   TYPE i.
    DATA lx      TYPE REF TO cx_root.
    DATA lv_bytes TYPE i. " <-- 1. Declare a new variable for the length

    IF iv_guid IS INITIAL.
      RETURN.
    ENDIF.

    TRY.
        GET RUN TIME FIELD lv_t1.
        lv_dur = ( lv_t1 - gv_t0 ) / 1000.       "microseconds to ms

        lv_guid = iv_guid.
        lv_code = iv_code.
        lv_err  = iv_error.

        IF iv_error IS NOT INITIAL.
          lv_stat = 'E'.
        ELSE.
          lv_stat = 'S'.
        ENDIF.

        IF capture_bodies( ) = abap_true.
          lv_resp = truncate( iv_response ).
        ELSE.
          lv_resp = '(body capture disabled)'.
        ENDIF.
     lv_bytes = strlen( iv_response ). " <-- 2. Calculate the length here
        UPDATE zabapmcp_log
          SET resp_body  = lv_resp
              resp_bytes = lv_bytes
              http_code  = lv_code
              duration   = lv_dur
              status     = lv_stat
              err_text   = lv_err
          WHERE guid = lv_guid.
        COMMIT WORK.

      CATCH cx_root INTO lx.
    ENDTRY.

  ENDMETHOD.


  METHOD open.

    DATA ls_log  TYPE zabapmcp_log.
    DATA lv_guid TYPE guid_32.
    DATA lx      TYPE REF TO cx_root.

    TRY.

        CALL FUNCTION 'GUID_CREATE'
          IMPORTING
            ev_guid_32 = lv_guid.

        rv_guid = lv_guid.

        GET RUN TIME FIELD gv_t0.

        CLEAR ls_log.
        ls_log-guid       = lv_guid.
        ls_log-created_on = sy-datum.
        ls_log-erzet      = sy-uzeit.
        ls_log-ernam      = sy-uname.
        ls_log-status     = 'O'.          "open

        IF capture_bodies( ) = abap_true.
          ls_log-req_body = truncate( iv_body ).
        ELSE.
          ls_log-req_body = '(body capture disabled)'.
        ENDIF.

        ls_log-req_bytes = strlen( iv_body ).

        INSERT zabapmcp_log FROM ls_log.
        COMMIT WORK.

      CATCH cx_root INTO lx.
*       logging must never break the request
        CLEAR rv_guid.
    ENDTRY.

  ENDMETHOD.


  METHOD set_method.

    DATA lv_guid TYPE zabapmcp_log-guid.
    DATA lv_meth TYPE zabapmcp_log-method.
    DATA lv_tool TYPE zabapmcp_log-tool_name.
    DATA lv_hid  TYPE zabapmcp_log-has_id.
    DATA lx      TYPE REF TO cx_root.

    IF iv_guid IS INITIAL.
      RETURN.
    ENDIF.

    TRY.
        lv_guid = iv_guid.
        lv_meth = iv_method.
        lv_tool = iv_tool.

        IF iv_has_id = abap_true.
          lv_hid = 'X'.
        ELSE.
          lv_hid = space.
        ENDIF.

        UPDATE zabapmcp_log
          SET method    = lv_meth
              tool_name = lv_tool
              has_id    = lv_hid
          WHERE guid = lv_guid.
        COMMIT WORK.

      CATCH cx_root INTO lx.
    ENDTRY.

  ENDMETHOD.


  METHOD truncate.

    rv_out = iv_in.

    IF strlen( rv_out ) > c_max_body.
      rv_out = rv_out(c_max_body).
      CONCATENATE rv_out '...(truncated)' INTO rv_out.
    ENDIF.

  ENDMETHOD.


ENDCLASS.
