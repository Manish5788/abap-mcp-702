CLASS zcl_abapmcp_whoami DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.
*--------------------------------------------------------------------*
* Title       : ZCL_ABAPMCP_WHOAMI - sap_whoami MCP tool
* Type        : Class (MCP tool plug-in, read-only)
* Frequency   : On demand (called per MCP tools/call)
* Description : One call that tells a session where it is and as whom:
*               system, client and its role (T000), release, the SAP
*               user and its type (USR02), the server and protocol
*               version, the AI authorization mode, and probes of the
*               caller's own authorizations:
*                 S_DEVELOP ACTVT 01/02/06  expected to FAIL
*                 S_DEVELOP ACTVT 03        may pass
*                 S_TCODE   SE38, SE80      reported only
*               A write authorization that passes is flagged RED in a
*               production client and INFO elsewhere - a developer in
*               a DEV system holds S_DEVELOP 02 by design, and the MCP has no
*               write path either way.
*               Limit: checks the running user, not the role design.
*--------------------------------------------------------------------*
*& Plug-in class, same contract as ZCL_ABAPMCP_DIAG:
*&   ZCL_ABAPMCP_TOOLS=>GET_TOOL_DEFS splices GET_TOOL_DEFS_JSON into
*&   its catalogue, and ZCL_ABAPMCP_TOOLS=>EXECUTE hands any tool for
*&   which HANDLES is true to EXECUTE here.
*&
*& READ-ONLY. Two SELECT SINGLEs (T000, USR02 - own row only) and
*& AUTHORITY-CHECKs. Takes no argument naming an object, so
*& CHECK_CUSTOM does not apply. Needs a ZAI_TOOL_GRP row
*& (sap_whoami -> DIAG) once AUTH_MODE is NEW.
*&
*& NW 7.02 syntax only: no inline DATA( ), no VALUE #( ), no NEW.
*&---------------------------------------------------------------------*

    CONSTANTS c_tool TYPE string VALUE 'sap_whoami'.

*   Tool definition in Anthropic Messages API shape (input_schema),
*   WITHOUT brackets, to splice into ZCL_ABAPMCP_TOOLS=>GET_TOOL_DEFS.
    CLASS-METHODS get_tool_defs_json
      RETURNING VALUE(ex_json) TYPE string.

*   True if im_name is this class's tool.
    CLASS-METHODS handles
      IMPORTING im_name       TYPE string
      RETURNING VALUE(ex_yes) TYPE abap_bool.

*   Same contract as ZCL_ABAPMCP_TOOLS=>EXECUTE: JSON arguments in,
*   JSON result out, {"error":"..."} on failure.
    CLASS-METHODS execute
      IMPORTING im_name          TYPE string
                im_input         TYPE string
      RETURNING VALUE(ex_result) TYPE string.

PROTECTED SECTION.

  PRIVATE SECTION.

    CLASS-METHODS whoami
      RETURNING VALUE(ex_json) TYPE string
      RAISING   zcx_ajson_error.

*   One authorization probe, written as element im_index of /probes.
*   im_expect is FAIL or ANY; ch_worst carries the worst flag so far.
    CLASS-METHODS probe
      IMPORTING im_out    TYPE REF TO zcl_ajson
                im_index  TYPE i
                im_object TYPE string
                im_value  TYPE string
                im_text   TYPE string
                im_expect TYPE string
                im_prod   TYPE abap_bool
      CHANGING  ch_worst  TYPE string
      RAISING   zcx_ajson_error.

    CLASS-METHODS error_json
      IMPORTING im_msg         TYPE string
      RETURNING VALUE(ex_json) TYPE string.

ENDCLASS.


CLASS zcl_abapmcp_whoami IMPLEMENTATION.

  METHOD error_json.
*&---------------------------------------------------------------------*

    DATA lo_out  TYPE REF TO zif_ajson.
    DATA lx_json TYPE REF TO zcx_ajson_error.

    TRY.
        lo_out = zcl_ajson=>create_empty( ).
        lo_out->set( iv_path = '/error' iv_val = im_msg ).
        ex_json = lo_out->stringify( ).
      CATCH zcx_ajson_error INTO lx_json.
        ex_json = '{"error":"internal error building error message"}'.
    ENDTRY.

  ENDMETHOD.


  METHOD execute.
*&---------------------------------------------------------------------*
*& Route one tool call. A tool failure is a normal result carrying an
*& error text the model can act on, never an exception to the server.
*& The tool takes no arguments, so im_input is not read.
*&---------------------------------------------------------------------*

    DATA lx_root TYPE REF TO cx_root.
    DATA lv_msg  TYPE string.

    TRY.
        IF im_name = c_tool.
          ex_result = whoami( ).
        ELSE.
          CONCATENATE 'Unknown tool:' im_name INTO lv_msg SEPARATED BY space.
          ex_result = error_json( lv_msg ).
        ENDIF.
      CATCH cx_root INTO lx_root.
        lv_msg = lx_root->get_text( ).
        ex_result = error_json( lv_msg ).
    ENDTRY.

  ENDMETHOD.


  METHOD get_tool_defs_json.
*&---------------------------------------------------------------------*
*& Tool catalogue. Keywords first, so a client that loads tools on
*& demand finds it by system, client, user or authorization.
*&---------------------------------------------------------------------*

    CONCATENATE
      `{"name":"sap_whoami",`
      ` "description":"System, client, user and authorization check of this MCP session: system, client `
      `role, release, the SAP user and its type, server version, AI auth mode, and probes of the user's `
      `S_DEVELOP and S_TCODE SE38/SE80 (write passes are RED in production). Call it at session start or `
      `when a tool is refused.",`
      ` "input_schema":{"type":"object","properties":{},"required":[]}}`
      INTO ex_json.

  ENDMETHOD.


  METHOD handles.
*&---------------------------------------------------------------------*

    IF im_name = c_tool.
      ex_yes = abap_true.
    ENDIF.

  ENDMETHOD.


  METHOD probe.
*&---------------------------------------------------------------------*
*& One AUTHORITY-CHECK on the caller. S_DEVELOP is checked with DUMMY
*& for package, type, name and group, so it passes if the user holds
*& the activity for ANY object. sy-subrc 0 = pass; 4, 12 = fail.
*&---------------------------------------------------------------------*

    DATA lv_act  TYPE activ_auth.
    DATA lv_tcd  TYPE tcode.
    DATA lv_rc   TYPE sysubrc.
    DATA lv_res  TYPE string.
    DATA lv_flag TYPE string.
    DATA lv_n    TYPE string.
    DATA lv_base TYPE string.
    DATA lv_path TYPE string.

    CASE im_object.
      WHEN 'S_DEVELOP'.
        lv_act = im_value.
        AUTHORITY-CHECK OBJECT 'S_DEVELOP'
          ID 'DEVCLASS' DUMMY
          ID 'OBJTYPE'  DUMMY
          ID 'OBJNAME'  DUMMY
          ID 'P_GROUP'  DUMMY
          ID 'ACTVT'    FIELD lv_act.
        lv_rc = sy-subrc.
      WHEN 'S_TCODE'.
        lv_tcd = im_value.
        AUTHORITY-CHECK OBJECT 'S_TCODE'
          ID 'TCD' FIELD lv_tcd.
        lv_rc = sy-subrc.
      WHEN OTHERS.
        lv_rc = 99.
    ENDCASE.

    IF lv_rc = 0.
      lv_res = 'PASS'.
    ELSE.
      lv_res = 'FAIL'.
    ENDIF.

*   a write authorization only matters where data is real
    lv_flag = 'OK'.
    IF lv_res = 'PASS' AND im_expect = 'FAIL'.
      IF im_prod = abap_true.
        lv_flag = 'RED'.
      ELSE.
        lv_flag = 'INFO'.
      ENDIF.
    ENDIF.

    IF lv_flag = 'RED'.
      ch_worst = 'RED'.
    ELSEIF lv_flag = 'INFO' AND ch_worst = 'OK'.
      ch_worst = 'INFO'.
    ENDIF.

    lv_n = im_index.
    CONDENSE lv_n.
    CONCATENATE '/probes/' lv_n INTO lv_base.

    CONCATENATE lv_base '/object' INTO lv_path.
    im_out->set( iv_path = lv_path iv_val = im_object ).
    CONCATENATE lv_base '/value' INTO lv_path.
    im_out->set( iv_path = lv_path iv_val = im_value ).
    CONCATENATE lv_base '/meaning' INTO lv_path.
    im_out->set( iv_path = lv_path iv_val = im_text ).
    CONCATENATE lv_base '/result' INTO lv_path.
    im_out->set( iv_path = lv_path iv_val = lv_res ).
    CONCATENATE lv_base '/expected' INTO lv_path.
    im_out->set( iv_path = lv_path iv_val = im_expect ).
    CONCATENATE lv_base '/flag' INTO lv_path.
    im_out->set( iv_path = lv_path iv_val = lv_flag ).

  ENDMETHOD.


  METHOD whoami.
*&---------------------------------------------------------------------*
*& Build the answer. Only the caller's own USR02 row and the logon
*& client's T000 row are read; no host name or address is returned.
*&---------------------------------------------------------------------*

    DATA lo_out   TYPE REF TO zcl_ajson.
    DATA lv_cat   TYPE t000-cccategory.
    DATA lv_ustyp TYPE usr02-ustyp.
    DATA lv_text  TYPE string.
    DATA lv_prod  TYPE abap_bool.
    DATA lv_worst TYPE string.
    DATA lv_ts    TYPE string.

    SELECT SINGLE cccategory FROM t000 INTO lv_cat
      WHERE mandt = sy-mandt.

    SELECT SINGLE ustyp FROM usr02 INTO lv_ustyp
      WHERE bname = sy-uname.

    lo_out = zcl_ajson=>create_empty( ).

    lo_out->set( iv_path = '/system'  iv_val = sy-sysid ).
    lo_out->set( iv_path = '/client'  iv_val = sy-mandt ).
    lo_out->set( iv_path = '/release' iv_val = sy-saprl ).

*   ---- client role ----------------------------------------------------
    CASE lv_cat.
      WHEN 'P'.
        lv_text = 'Production'.
        lv_prod = abap_true.
      WHEN 'T'.
        lv_text = 'Test'.
      WHEN 'C'.
        lv_text = 'Customizing'.
      WHEN 'D'.
        lv_text = 'Demo'.
      WHEN 'E'.
        lv_text = 'Training/Education'.
      WHEN 'S'.
        lv_text = 'SAP reference'.
      WHEN OTHERS.
        lv_text = 'Unknown'.
    ENDCASE.
    lo_out->set( iv_path = '/client_role/code' iv_val = lv_cat ).
    lo_out->set( iv_path = '/client_role/text' iv_val = lv_text ).

*   ---- user -----------------------------------------------------------
    lo_out->set( iv_path = '/user' iv_val = sy-uname ).
    CASE lv_ustyp.
      WHEN 'A'.
        lv_text = 'Dialog'.
      WHEN 'B'.
        lv_text = 'System'.
      WHEN 'C'.
        lv_text = 'Communication'.
      WHEN 'L'.
        lv_text = 'Reference'.
      WHEN 'S'.
        lv_text = 'Service'.
      WHEN OTHERS.
        lv_text = 'Unknown'.
    ENDCASE.
    lo_out->set( iv_path = '/user_type/code' iv_val = lv_ustyp ).
    lo_out->set( iv_path = '/user_type/text' iv_val = lv_text ).

*   ---- server ---------------------------------------------------------
    lo_out->set( iv_path = '/server/name'     iv_val = zcl_abapmcp_server=>c_server_name ).
    lo_out->set( iv_path = '/server/version'  iv_val = zcl_abapmcp_server=>c_server_version ).
    lo_out->set( iv_path = '/server/protocol' iv_val = zcl_abapmcp_server=>c_protocol_version ).
    lv_text = zcl_ai_auth=>get_mode( ).
    lo_out->set( iv_path = '/auth_mode'       iv_val = lv_text ).
    lo_out->set_boolean( iv_path = '/read_only' iv_val = abap_true ).
    lo_out->set( iv_path = '/write_paths'
                 iv_val  = 'none - every tool is a SELECT or a READ REPORT' ).

*   ---- authorization probes -------------------------------------------
    lv_worst = 'OK'.
    lo_out->touch_array( '/probes' ).

    probe( EXPORTING im_out = lo_out im_index = 1 im_object = 'S_DEVELOP'
                     im_value = '01' im_text = 'create'  im_expect = 'FAIL'
                     im_prod = lv_prod
           CHANGING  ch_worst = lv_worst ).
    probe( EXPORTING im_out = lo_out im_index = 2 im_object = 'S_DEVELOP'
                     im_value = '02' im_text = 'change'  im_expect = 'FAIL'
                     im_prod = lv_prod
           CHANGING  ch_worst = lv_worst ).
    probe( EXPORTING im_out = lo_out im_index = 3 im_object = 'S_DEVELOP'
                     im_value = '06' im_text = 'delete'  im_expect = 'FAIL'
                     im_prod = lv_prod
           CHANGING  ch_worst = lv_worst ).
    probe( EXPORTING im_out = lo_out im_index = 4 im_object = 'S_DEVELOP'
                     im_value = '03' im_text = 'display' im_expect = 'ANY'
                     im_prod = lv_prod
           CHANGING  ch_worst = lv_worst ).
    probe( EXPORTING im_out = lo_out im_index = 5 im_object = 'S_TCODE'
                     im_value = 'SE38' im_text = 'ABAP editor' im_expect = 'ANY'
                     im_prod = lv_prod
           CHANGING  ch_worst = lv_worst ).
    probe( EXPORTING im_out = lo_out im_index = 6 im_object = 'S_TCODE'
                     im_value = 'SE80' im_text = 'Object navigator' im_expect = 'ANY'
                     im_prod = lv_prod
           CHANGING  ch_worst = lv_worst ).

    lo_out->set( iv_path = '/summary' iv_val = lv_worst ).

    CASE lv_worst.
      WHEN 'RED'.
        lv_text = `This user can change repository objects in a PRODUCTION client. The MCP has no write path, but the user should not hold S_DEVELOP 01/02/06 here - check the role.`.
      WHEN 'INFO'.
        lv_text = `This user holds developer authorizations, which is normal outside production. The MCP itself has no write path.`.
      WHEN OTHERS.
        lv_text = `No write authorization found for this user.`.
    ENDCASE.
    lo_out->set( iv_path = '/note' iv_val = lv_text ).

    CONCATENATE sy-datum(4) '-' sy-datum+4(2) '-' sy-datum+6(2) 'T'
                sy-uzeit(2) ':' sy-uzeit+2(2) ':' sy-uzeit+4(2)
      INTO lv_ts.
    lo_out->set( iv_path = '/generated_at' iv_val = lv_ts ).

    ex_json = lo_out->stringify( ).

  ENDMETHOD.


ENDCLASS.
