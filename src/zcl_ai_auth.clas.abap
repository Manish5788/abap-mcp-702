CLASS zcl_ai_auth DEFINITION PUBLIC FINAL CREATE PRIVATE.

  PUBLIC SECTION.
*--------------------------------------------------------------------*
* Title       : ZCL_AI_AUTH - central authorization of the AI tools
* Type        : Class (authorization checks, read-only)
* Frequency   : On every MCP, abapsync and job entry
* Description : The one place that decides who may use the AI tools.
*               Every entry asks this class; no handler or tool writes
*               its own AUTHORITY-CHECK for the AI objects.
*                 Z_AI_CHAN   way in  (MCP, SYNC, JOB)
*                 Z_AI_TOOL   tool group (CONFIG DDIC SEARCH CODE
*                             TRANSP REVIEW DIAG BW); the tool ->
*                             group mapping is table ZAI_TOOL_GRP (SM30)
*                 Z_AI_SCOPE  whose work (OWN/ANY) and which packages
*                             may be read (DEVCLASS)
*                 Z_AI_ADM    administration (TOOLSW LOG)
*                 Z_AI_SYNC   abapsync push per package
*               Every object carries ZUSER, always checked against the
*               logged-on user (SY-UNAME); the new objects check
*               ACTVT 03 only.
*               ZABAPMCP_CFG key AUTH_MODE switches the rules:
*                 LEGACY  ZMCP_USE 03 decides (default, no row)
*                 DUAL    ZMCP_USE decides; a refusal by the new
*                         objects is logged with status W
*                 NEW     the new objects decide; refusals logged R
*               Refusals go to ZABAPMCP_LOG (method AUTH).
*               SAP's own checks (S_TABU_DIS, S_TRANSPRT, S_DEVELOP)
*               stay in the tools. Setup: docs/security.md.
*--------------------------------------------------------------------*
*& NW 7.02 syntax only: no inline DATA( ), no VALUE #( ), no NEW.
*&---------------------------------------------------------------------*

*   ways in (field Z_AICHAN of Z_AI_CHAN)
    CONSTANTS: BEGIN OF c_chan,
                 mcp     TYPE zai_chan VALUE 'MCP',
                 sync    TYPE zai_chan VALUE 'SYNC',
                 job     TYPE zai_chan VALUE 'JOB',
               END OF c_chan.

*   administration functions (field Z_AIADM of Z_AI_ADM)
    CONSTANTS: BEGIN OF c_adm,
                 toolsw TYPE zai_adm VALUE 'TOOLSW',
                 log    TYPE zai_adm VALUE 'LOG',
               END OF c_adm.

*   values of ZABAPMCP_CFG key AUTH_MODE
    CONSTANTS: BEGIN OF c_mode,
                 legacy TYPE string VALUE 'LEGACY',
                 dual   TYPE string VALUE 'DUAL',
                 new    TYPE string VALUE 'NEW',
               END OF c_mode.

*   May the user come in this way? First line of every ICF handler and
*   of every program that calls a tool directly.
    CLASS-METHODS check_channel
      IMPORTING im_channel   TYPE zai_chan
      RETURNING VALUE(ex_ok) TYPE abap_bool.

*   May the user call this tool? Looks up the tool group in
*   ZAI_TOOL_GRP; a tool without an active row is refused.
    CLASS-METHODS check_tool
      IMPORTING im_tool      TYPE csequence
      RETURNING VALUE(ex_ok) TYPE abap_bool.

*   Same decision as CHECK_TOOL without logging - for the tool list
*   sent to the MCP client, so it only sees the user's tools.
    CLASS-METHODS tool_visible
      IMPORTING im_tool      TYPE csequence
      RETURNING VALUE(ex_ok) TYPE abap_bool.

*   Tool group of a tool, initial if the tool is not mapped.
    CLASS-METHODS tool_group
      IMPORTING im_tool         TYPE csequence
      RETURNING VALUE(ex_group) TYPE zai_tgrp.

*   Another user's open requests or dumps need Z_AIOWN ANY, the
*   user's own need OWN. An initial owner means "all users" (ANY).
    CLASS-METHODS check_owner
      IMPORTING im_owner     TYPE csequence
      RETURNING VALUE(ex_ok) TYPE abap_bool.

*   May code of this package be read (Z_AI_SCOPE DEVCLASS)?
    CLASS-METHODS check_package
      IMPORTING im_devclass  TYPE csequence
      RETURNING VALUE(ex_ok) TYPE abap_bool.

*   May the code of this object be read? Resolves the object's package
*   (TADIR, class and function group includes, D010INC) first.
    CLASS-METHODS check_object
      IMPORTING im_name      TYPE csequence
      RETURNING VALUE(ex_ok) TYPE abap_bool.

*   Package of an object, program or include; initial if unknown.
    CLASS-METHODS object_package
      IMPORTING im_name            TYPE csequence
      RETURNING VALUE(ex_devclass) TYPE devclass.

*   Administration function (Z_AI_ADM), e.g. c_adm-log.
    CLASS-METHODS check_admin
      IMPORTING im_function  TYPE zai_adm
      RETURNING VALUE(ex_ok) TYPE abap_bool.

*   abapsync push into a package (Z_AI_SYNC). S_DEVELOP stays with the
*   writer, where SAP itself expects it.
    CLASS-METHODS check_sync
      IMPORTING im_devclass  TYPE csequence
      RETURNING VALUE(ex_ok) TYPE abap_bool.

*   LEGACY, DUAL or NEW, from ZABAPMCP_CFG key AUTH_MODE.
    CLASS-METHODS get_mode
      RETURNING VALUE(ex_mode) TYPE string.

*   Reason text of the last refusal, for the caller's error message.
    CLASS-METHODS last_reason
      RETURNING VALUE(ex_text) TYPE string.

  PROTECTED SECTION.

  PRIVATE SECTION.

*   one decision, buffered for the internal session (one HTTP request,
*   one program run), so six tool calls check each value once
    TYPES: BEGIN OF t_buf,
             object TYPE xuobject,
             value  TYPE c LENGTH 40,
             ok     TYPE abap_bool,
           END OF t_buf.

    TYPES: BEGIN OF t_map,
             tool_name  TYPE zai_tool,
             tool_group TYPE zai_tgrp,
           END OF t_map.

    CONSTANTS: c_actvt_display TYPE activ_auth VALUE '03',
*              legacy gate: fields ZUSER, ACTVT - create it in SU21 or
*              point this constant at an existing object
               c_legacy_object TYPE xuobject VALUE 'ZMCP_USE',
               c_own           TYPE zai_own VALUE 'OWN',
               c_any           TYPE zai_own VALUE 'ANY'.

    CLASS-DATA i_buf     TYPE HASHED TABLE OF t_buf WITH UNIQUE KEY object value.
    CLASS-DATA i_map     TYPE HASHED TABLE OF t_map WITH UNIQUE KEY tool_name.
    CLASS-DATA v_map_ok  TYPE abap_bool.
    CLASS-DATA v_mode    TYPE string.
    CLASS-DATA v_reason  TYPE string.

*   the simple rule: C_LEGACY_OBJECT, ZUSER = own user, ACTVT 03
    CLASS-METHODS legacy_ok
      RETURNING VALUE(ex_ok) TYPE abap_bool.

*   applies AUTH_MODE to the verdict of the new objects and logs it
    CLASS-METHODS decide
      IMPORTING im_new_ok    TYPE abap_bool
                im_what      TYPE csequence
                im_reason    TYPE csequence
                im_silent    TYPE abap_bool DEFAULT abap_false
      RETURNING VALUE(ex_ok) TYPE abap_bool.

*   one AUTHORITY-CHECK per object, buffered by object and value
    CLASS-METHODS auth_chan
      IMPORTING im_channel   TYPE zai_chan
      RETURNING VALUE(ex_ok) TYPE abap_bool.

    CLASS-METHODS auth_tool
      IMPORTING im_group     TYPE zai_tgrp
      RETURNING VALUE(ex_ok) TYPE abap_bool.

    CLASS-METHODS auth_own
      IMPORTING im_own       TYPE zai_own
      RETURNING VALUE(ex_ok) TYPE abap_bool.

    CLASS-METHODS auth_pkg
      IMPORTING im_devclass  TYPE devclass
      RETURNING VALUE(ex_ok) TYPE abap_bool.

    CLASS-METHODS auth_adm
      IMPORTING im_function  TYPE zai_adm
      RETURNING VALUE(ex_ok) TYPE abap_bool.

    CLASS-METHODS auth_sync
      IMPORTING im_devclass  TYPE devclass
      RETURNING VALUE(ex_ok) TYPE abap_bool.

    CLASS-METHODS buffered
      IMPORTING im_object    TYPE xuobject
                im_value     TYPE csequence
      EXPORTING ex_found     TYPE abap_bool
                ex_ok        TYPE abap_bool.

    CLASS-METHODS remember
      IMPORTING im_object TYPE xuobject
                im_value  TYPE csequence
                im_ok     TYPE abap_bool.

    CLASS-METHODS read_map.

    CLASS-METHODS log_refusal
      IMPORTING im_status TYPE c
                im_what   TYPE csequence
                im_reason TYPE csequence.

ENDCLASS.


CLASS zcl_ai_auth IMPLEMENTATION.

  METHOD auth_adm.

    DATA lv_found TYPE abap_bool.

    buffered( EXPORTING im_object = 'Z_AI_ADM'
                        im_value  = im_function
              IMPORTING ex_found  = lv_found
                        ex_ok     = ex_ok ).
    IF lv_found = abap_true.
      RETURN.
    ENDIF.

    AUTHORITY-CHECK OBJECT 'Z_AI_ADM'
      ID 'ZUSER'   FIELD sy-uname
      ID 'Z_AIADM' FIELD im_function
      ID 'ACTVT'   FIELD c_actvt_display.
    IF sy-subrc = 0.
      ex_ok = abap_true.
    ELSE.
      ex_ok = abap_false.
    ENDIF.

    remember( im_object = 'Z_AI_ADM'
              im_value  = im_function
              im_ok     = ex_ok ).

  ENDMETHOD.


  METHOD auth_chan.

    DATA lv_found TYPE abap_bool.

    buffered( EXPORTING im_object = 'Z_AI_CHAN'
                        im_value  = im_channel
              IMPORTING ex_found  = lv_found
                        ex_ok     = ex_ok ).
    IF lv_found = abap_true.
      RETURN.
    ENDIF.

    AUTHORITY-CHECK OBJECT 'Z_AI_CHAN'
      ID 'ZUSER'    FIELD sy-uname
      ID 'Z_AICHAN' FIELD im_channel
      ID 'ACTVT'    FIELD c_actvt_display.
    IF sy-subrc = 0.
      ex_ok = abap_true.
    ELSE.
      ex_ok = abap_false.
    ENDIF.

    remember( im_object = 'Z_AI_CHAN'
              im_value  = im_channel
              im_ok     = ex_ok ).

  ENDMETHOD.


  METHOD auth_own.

    DATA lv_found TYPE abap_bool.
    DATA lv_key   TYPE string.

    CONCATENATE 'OWN:' im_own INTO lv_key.
    buffered( EXPORTING im_object = 'Z_AI_SCOPE'
                        im_value  = lv_key
              IMPORTING ex_found  = lv_found
                        ex_ok     = ex_ok ).
    IF lv_found = abap_true.
      RETURN.
    ENDIF.

    AUTHORITY-CHECK OBJECT 'Z_AI_SCOPE'
      ID 'ZUSER'    FIELD sy-uname
      ID 'Z_AIOWN'  FIELD im_own
      ID 'DEVCLASS' DUMMY
      ID 'ACTVT'    FIELD c_actvt_display.
    IF sy-subrc = 0.
      ex_ok = abap_true.
    ELSE.
      ex_ok = abap_false.
    ENDIF.

    remember( im_object = 'Z_AI_SCOPE'
              im_value  = lv_key
              im_ok     = ex_ok ).

  ENDMETHOD.


  METHOD auth_pkg.

    DATA lv_found TYPE abap_bool.
    DATA lv_key   TYPE string.

    CONCATENATE 'PKG:' im_devclass INTO lv_key.
    buffered( EXPORTING im_object = 'Z_AI_SCOPE'
                        im_value  = lv_key
              IMPORTING ex_found  = lv_found
                        ex_ok     = ex_ok ).
    IF lv_found = abap_true.
      RETURN.
    ENDIF.

    AUTHORITY-CHECK OBJECT 'Z_AI_SCOPE'
      ID 'ZUSER'    FIELD sy-uname
      ID 'Z_AIOWN'  DUMMY
      ID 'DEVCLASS' FIELD im_devclass
      ID 'ACTVT'    FIELD c_actvt_display.
    IF sy-subrc = 0.
      ex_ok = abap_true.
    ELSE.
      ex_ok = abap_false.
    ENDIF.

    remember( im_object = 'Z_AI_SCOPE'
              im_value  = lv_key
              im_ok     = ex_ok ).

  ENDMETHOD.


  METHOD auth_sync.

    DATA lv_found TYPE abap_bool.

    buffered( EXPORTING im_object = 'Z_AI_SYNC'
                        im_value  = im_devclass
              IMPORTING ex_found  = lv_found
                        ex_ok     = ex_ok ).
    IF lv_found = abap_true.
      RETURN.
    ENDIF.

    AUTHORITY-CHECK OBJECT 'Z_AI_SYNC'
      ID 'ZUSER'    FIELD sy-uname
      ID 'DEVCLASS' FIELD im_devclass
      ID 'ACTVT'    FIELD c_actvt_display.
    IF sy-subrc = 0.
      ex_ok = abap_true.
    ELSE.
      ex_ok = abap_false.
    ENDIF.

    remember( im_object = 'Z_AI_SYNC'
              im_value  = im_devclass
              im_ok     = ex_ok ).

  ENDMETHOD.


  METHOD auth_tool.

    DATA lv_found TYPE abap_bool.

    buffered( EXPORTING im_object = 'Z_AI_TOOL'
                        im_value  = im_group
              IMPORTING ex_found  = lv_found
                        ex_ok     = ex_ok ).
    IF lv_found = abap_true.
      RETURN.
    ENDIF.

    AUTHORITY-CHECK OBJECT 'Z_AI_TOOL'
      ID 'ZUSER'    FIELD sy-uname
      ID 'Z_AITGRP' FIELD im_group
      ID 'ACTVT'    FIELD c_actvt_display.
    IF sy-subrc = 0.
      ex_ok = abap_true.
    ELSE.
      ex_ok = abap_false.
    ENDIF.

    remember( im_object = 'Z_AI_TOOL'
              im_value  = im_group
              im_ok     = ex_ok ).

  ENDMETHOD.


  METHOD buffered.

    DATA lw_buf TYPE t_buf.

    ex_found = abap_false.
    ex_ok    = abap_false.

    READ TABLE i_buf INTO lw_buf
      WITH TABLE KEY object = im_object value = im_value.
    IF sy-subrc = 0.
      ex_found = abap_true.
      ex_ok    = lw_buf-ok.
    ENDIF.

  ENDMETHOD.


  METHOD check_admin.

    DATA lv_what   TYPE string.
    DATA lv_reason TYPE string.
    DATA lv_new    TYPE abap_bool.

    CONCATENATE 'ADMIN' im_function INTO lv_what SEPARATED BY space.
    CONCATENATE 'Not authorised for administration function' im_function '(Z_AI_ADM).'
      INTO lv_reason SEPARATED BY space.

    lv_new = auth_adm( im_function ).
    ex_ok = decide( im_new_ok = lv_new
                    im_what   = lv_what
                    im_reason = lv_reason ).

  ENDMETHOD.


  METHOD check_channel.

    DATA lv_what   TYPE string.
    DATA lv_reason TYPE string.
    DATA lv_new    TYPE abap_bool.

    lv_new = auth_chan( im_channel ).
    CONCATENATE 'CHANNEL' im_channel INTO lv_what SEPARATED BY space.
    CONCATENATE 'Not authorised for channel' im_channel '(Z_AI_CHAN).'
      INTO lv_reason SEPARATED BY space.

    ex_ok = decide( im_new_ok = lv_new
                    im_what   = lv_what
                    im_reason = lv_reason ).

  ENDMETHOD.



  METHOD check_object.

    DATA lv_devc   TYPE devclass.
    DATA lv_name   TYPE string.
    DATA lv_what   TYPE string.
    DATA lv_reason TYPE string.
    DATA lv_new    TYPE abap_bool.

    lv_name = im_name.
    TRANSLATE lv_name TO UPPER CASE.
    lv_devc = object_package( lv_name ).

    CONCATENATE 'OBJECT' lv_name INTO lv_what SEPARATED BY space.
    IF lv_devc IS INITIAL.
*     no package found: refuse rather than guess
      lv_new = abap_false.
      CONCATENATE 'Package of' lv_name 'not found - code access refused (Z_AI_SCOPE).'
        INTO lv_reason SEPARATED BY space.
    ELSE.
      lv_new = auth_pkg( lv_devc ).
      CONCATENATE 'Not authorised to read code in package' lv_devc '(Z_AI_SCOPE DEVCLASS) -' lv_name
        INTO lv_reason SEPARATED BY space.
    ENDIF.

    ex_ok = decide( im_new_ok = lv_new
                    im_what   = lv_what
                    im_reason = lv_reason ).

  ENDMETHOD.


  METHOD check_owner.

    DATA lv_owner  TYPE syuname.
    DATA lv_own    TYPE zai_own.
    DATA lv_what   TYPE string.
    DATA lv_reason TYPE string.
    DATA lv_new    TYPE abap_bool.

    lv_owner = im_owner.
    TRANSLATE lv_owner TO UPPER CASE.

*   own work needs OWN; anyone else's - or everyone's - needs ANY.
*   ANY includes OWN: a role with ANY is not also asked for OWN.
    IF lv_owner = sy-uname.
      lv_own = c_own.
      IF auth_own( c_any ) = abap_true.
        lv_own = c_any.
      ENDIF.
    ELSE.
      lv_own = c_any.
    ENDIF.

    IF lv_owner IS INITIAL.
      lv_what = 'SCOPE all users'.
    ELSE.
      CONCATENATE 'SCOPE' lv_owner INTO lv_what SEPARATED BY space.
    ENDIF.
    IF lv_own = c_any.
      lv_reason = 'Not authorised for other users'' requests or dumps (Z_AI_SCOPE ANY).'.
    ELSE.
      lv_reason = 'Not authorised for your own requests or dumps (Z_AI_SCOPE OWN).'.
    ENDIF.

    lv_new = auth_own( lv_own ).
    ex_ok = decide( im_new_ok = lv_new
                    im_what   = lv_what
                    im_reason = lv_reason ).

  ENDMETHOD.


  METHOD check_package.

    DATA lv_devc   TYPE devclass.
    DATA lv_what   TYPE string.
    DATA lv_reason TYPE string.
    DATA lv_new    TYPE abap_bool.

    lv_devc = im_devclass.
    TRANSLATE lv_devc TO UPPER CASE.

    CONCATENATE 'PACKAGE' lv_devc INTO lv_what SEPARATED BY space.
    CONCATENATE 'Not authorised to read code in package' lv_devc '(Z_AI_SCOPE DEVCLASS).'
      INTO lv_reason SEPARATED BY space.

    lv_new = auth_pkg( lv_devc ).
    ex_ok = decide( im_new_ok = lv_new
                    im_what   = lv_what
                    im_reason = lv_reason ).

  ENDMETHOD.


  METHOD check_sync.

    DATA lv_devc   TYPE devclass.
    DATA lv_what   TYPE string.
    DATA lv_reason TYPE string.
    DATA lv_new    TYPE abap_bool.

    lv_devc = im_devclass.
    TRANSLATE lv_devc TO UPPER CASE.

    CONCATENATE 'SYNC' lv_devc INTO lv_what SEPARATED BY space.
    CONCATENATE 'Not authorised to push into package' lv_devc '(Z_AI_SYNC).'
      INTO lv_reason SEPARATED BY space.

    lv_new = auth_sync( lv_devc ).
    ex_ok = decide( im_new_ok = lv_new
                    im_what   = lv_what
                    im_reason = lv_reason ).

  ENDMETHOD.


  METHOD check_tool.

    DATA lv_group  TYPE zai_tgrp.
    DATA lv_new    TYPE abap_bool.
    DATA lv_what   TYPE string.
    DATA lv_reason TYPE string.
    DATA lv_tool   TYPE string.

    lv_tool = im_tool.
    lv_group = tool_group( lv_tool ).
    CONCATENATE 'TOOL' lv_tool INTO lv_what SEPARATED BY space.

*   deny by default: a tool without an active mapping row is refused
    IF lv_group IS INITIAL.
      lv_new = abap_false.
      CONCATENATE 'Tool' lv_tool 'is not assigned to a tool group (ZAI_TOOL_GRP).'
        INTO lv_reason SEPARATED BY space.
    ELSE.
      lv_new = auth_tool( lv_group ).
      CONCATENATE 'Not authorised for tool group' lv_group '(Z_AI_TOOL) - tool' lv_tool
        INTO lv_reason SEPARATED BY space.
    ENDIF.

    ex_ok = decide( im_new_ok = lv_new
                    im_what   = lv_what
                    im_reason = lv_reason ).

  ENDMETHOD.


  METHOD decide.
*&---------------------------------------------------------------------*
*& LEGACY  C_LEGACY_OBJECT decides; the new objects are not asked.
*& DUAL    C_LEGACY_OBJECT decides; when the new objects would refuse, the
*&         case is logged with status W so missing roles show up.
*& NEW     the new objects decide; a refusal is logged with status R.
*& IM_SILENT (tool list) never logs.
*&---------------------------------------------------------------------*

    CLEAR v_reason.

    CASE get_mode( ).

      WHEN c_mode-new.
        ex_ok = im_new_ok.
        IF ex_ok = abap_false.
          v_reason = im_reason.
          IF im_silent = abap_false.
            log_refusal( im_status = 'R'
                         im_what   = im_what
                         im_reason = im_reason ).
          ENDIF.
        ENDIF.

      WHEN c_mode-dual.
        ex_ok = legacy_ok( ).
        IF ex_ok = abap_false.
          CONCATENATE 'Not authorised for these tools (' c_legacy_object
                      ', activity 03).' INTO v_reason.
        ENDIF.
        IF im_new_ok = abap_false AND im_silent = abap_false.
          log_refusal( im_status = 'W'
                       im_what   = im_what
                       im_reason = im_reason ).
        ENDIF.

      WHEN OTHERS.
        ex_ok = legacy_ok( ).
        IF ex_ok = abap_false.
          CONCATENATE 'Not authorised for these tools (' c_legacy_object
                      ', activity 03).' INTO v_reason.
        ENDIF.

    ENDCASE.

  ENDMETHOD.


  METHOD get_mode.

    DATA lv_val TYPE zabapmcp_cfg-cfg_value.

    IF v_mode IS INITIAL.
      SELECT SINGLE cfg_value FROM zabapmcp_cfg INTO lv_val
        WHERE cfg_key = 'AUTH_MODE'.
      v_mode = lv_val.
      TRANSLATE v_mode TO UPPER CASE.
      CONDENSE v_mode NO-GAPS.
*     no row, or a value we do not know: keep today's rule
      IF v_mode <> c_mode-dual AND v_mode <> c_mode-new.
        v_mode = c_mode-legacy.
      ENDIF.
    ENDIF.

    ex_mode = v_mode.

  ENDMETHOD.


  METHOD last_reason.

    ex_text = v_reason.

  ENDMETHOD.


  METHOD legacy_ok.

    DATA lv_found TYPE abap_bool.

    buffered( EXPORTING im_object = c_legacy_object
                        im_value  = c_actvt_display
              IMPORTING ex_found  = lv_found
                        ex_ok     = ex_ok ).
    IF lv_found = abap_true.
      RETURN.
    ENDIF.

    AUTHORITY-CHECK OBJECT c_legacy_object
      ID 'ZUSER' FIELD sy-uname
      ID 'ACTVT' FIELD c_actvt_display.
    IF sy-subrc = 0.
      ex_ok = abap_true.
    ELSE.
      ex_ok = abap_false.
    ENDIF.

    remember( im_object = c_legacy_object
              im_value  = c_actvt_display
              im_ok     = ex_ok ).

  ENDMETHOD.


  METHOD log_refusal.
*&---------------------------------------------------------------------*
*& One row in ZABAPMCP_LOG per refusal: method AUTH, what was asked
*& in TOOL_NAME, status R (refused) or W (would be refused, DUAL),
*& the reason in ERR_TEXT. No COMMIT here - the caller's LUW (an HTTP
*& request, a program run) commits it; a refused call writes nothing
*& else. Logging must never break the caller.
*&---------------------------------------------------------------------*

    DATA lw_log  TYPE zabapmcp_log.
    DATA lv_guid TYPE guid_32.
    DATA lx      TYPE REF TO cx_root.

    TRY.
        CALL FUNCTION 'GUID_CREATE'
          IMPORTING
            ev_guid_32 = lv_guid.

        lw_log-guid       = lv_guid.
        lw_log-created_on = sy-datum.
        lw_log-erzet      = sy-uzeit.
        lw_log-ernam      = sy-uname.
        lw_log-method     = 'AUTH'.
        lw_log-tool_name  = im_what.
        lw_log-status     = im_status.
        lw_log-http_code  = '403'.
        lw_log-err_text   = im_reason.

        INSERT zabapmcp_log FROM lw_log.

      CATCH cx_root INTO lx.
        RETURN.
    ENDTRY.

  ENDMETHOD.


  METHOD object_package.
*&---------------------------------------------------------------------*
*& Package of an object, program or include:
*&   1. TADIR entry of that name (PROG, CLAS, INTF, FUGR, TABL ...)
*&   2. class pool include ZCL_X=====CU/CM001 -> class ZCL_X
*&   3. function group main program SAPLZFOO -> function group ZFOO
*&   4. any other include -> its main program (D010INC), then 1 and 3
*&---------------------------------------------------------------------*

    DATA lv_name   TYPE string.
    DATA lv_obj    TYPE sobj_name.
    DATA lv_cls    TYPE string.
    DATA lv_rest   TYPE string.
    DATA lv_incl   TYPE progname.
    DATA lv_master TYPE progname.

    lv_name = im_name.
    TRANSLATE lv_name TO UPPER CASE.
    CONDENSE lv_name NO-GAPS.
    IF lv_name IS INITIAL.
      RETURN.
    ENDIF.

    lv_obj = lv_name.
    SELECT SINGLE devclass FROM tadir INTO ex_devclass
      WHERE pgmid = 'R3TR' AND obj_name = lv_obj.
    IF sy-subrc = 0.
      RETURN.
    ENDIF.

*   class pool include: the class name is padded with '='
    IF lv_name CA '='.
      SPLIT lv_name AT '=' INTO lv_cls lv_rest.
      lv_obj = lv_cls.
      SELECT SINGLE devclass FROM tadir INTO ex_devclass
        WHERE pgmid = 'R3TR'
          AND ( object = 'CLAS' OR object = 'INTF' )
          AND obj_name = lv_obj.
      RETURN.
    ENDIF.

    IF strlen( lv_name ) > 4 AND lv_name(4) = 'SAPL'.
      lv_obj = lv_name+4.
      SELECT SINGLE devclass FROM tadir INTO ex_devclass
        WHERE pgmid = 'R3TR' AND object = 'FUGR' AND obj_name = lv_obj.
      RETURN.
    ENDIF.

*   any other include: its main program decides
    lv_incl = lv_name.
    SELECT SINGLE master FROM d010inc INTO lv_master
      WHERE include = lv_incl.
    IF sy-subrc <> 0 OR lv_master = lv_incl.
      RETURN.
    ENDIF.

    lv_obj = lv_master.
    SELECT SINGLE devclass FROM tadir INTO ex_devclass
      WHERE pgmid = 'R3TR' AND object = 'PROG' AND obj_name = lv_obj.
    IF sy-subrc = 0.
      RETURN.
    ENDIF.

    IF strlen( lv_master ) > 4 AND lv_master(4) = 'SAPL'.
      lv_obj = lv_master+4.
      SELECT SINGLE devclass FROM tadir INTO ex_devclass
        WHERE pgmid = 'R3TR' AND object = 'FUGR' AND obj_name = lv_obj.
    ENDIF.

  ENDMETHOD.


  METHOD read_map.

    DATA li_map TYPE STANDARD TABLE OF t_map.
    DATA lw_map TYPE t_map.

    IF v_map_ok = abap_true.
      RETURN.
    ENDIF.
    v_map_ok = abap_true.

    SELECT tool_name tool_group FROM zai_tool_grp INTO TABLE li_map
      WHERE active = abap_true.

    LOOP AT li_map INTO lw_map.
      TRANSLATE lw_map-tool_name TO LOWER CASE.
      INSERT lw_map INTO TABLE i_map.
    ENDLOOP.

  ENDMETHOD.


  METHOD remember.

    DATA lw_buf TYPE t_buf.

    lw_buf-object = im_object.
    lw_buf-value  = im_value.
    lw_buf-ok     = im_ok.
    INSERT lw_buf INTO TABLE i_buf.

  ENDMETHOD.


  METHOD tool_group.

    DATA lv_tool TYPE zai_tool.
    DATA lw_map  TYPE t_map.

    read_map( ).

*   tool names are lower case, as the MCP catalogue spells them
    lv_tool = im_tool.
    TRANSLATE lv_tool TO LOWER CASE.
    CONDENSE lv_tool NO-GAPS.

    READ TABLE i_map INTO lw_map WITH TABLE KEY tool_name = lv_tool.
    IF sy-subrc = 0.
      ex_group = lw_map-tool_group.
    ENDIF.

  ENDMETHOD.


  METHOD tool_visible.

    DATA lv_group TYPE zai_tgrp.
    DATA lv_new   TYPE abap_bool.

    lv_group = tool_group( im_tool ).
    IF lv_group IS INITIAL.
      lv_new = abap_false.
    ELSE.
      lv_new = auth_tool( lv_group ).
    ENDIF.

    ex_ok = decide( im_new_ok = lv_new
                    im_what   = im_tool
                    im_reason = space
                    im_silent = abap_true ).

  ENDMETHOD.


ENDCLASS.
