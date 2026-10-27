CLASS zcl_abapmcp_diag DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.
*--------------------------------------------------------------------*
* Title       : ZCL_ABAPMCP_DIAG - short-dump MCP tool
* Type        : Class (MCP tool plug-in, read-only)
* Frequency   : On demand (called per MCP tools/call)
* Description : Adds one read-only tool to the /sap/bc/mcp node:
*                 sap_get_dumps    list ST22 short dumps for one day
*--------------------------------------------------------------------*
*& Plug-in class, same contract as ZCL_ABAPMCP_SYNC:
*&   ZCL_ABAPMCP_TOOLS=>GET_TOOL_DEFS splices GET_TOOL_DEFS_JSON into
*&   its catalogue, and ZCL_ABAPMCP_TOOLS=>EXECUTE hands any tool for
*&   which HANDLES is true to EXECUTE here.
*&
*& READ-ONLY. SELECTs and one call to CL_ABAP_SNAP=>GET_RAW_CONTENT. There is no write statement and adding
*& one defeats the purpose of this server - see CONTRIBUTING.md.
*&
*& NAMESPACE GUARD - why the tool does not call CHECK_CUSTOM
*& The guard exists because an argument names a repository object and
*& the server is restricted to Z/Y. sap_get_dumps takes a date, not an
*& object name. The caller is still gated by the logon, by ZCL_AI_AUTH
*& in the server and by the owner check (Z_AI_SCOPE) for other users'
*& dumps.
*&
*& NW 7.02 syntax only: no inline DATA( ), no VALUE #( ), no NEW.
*&---------------------------------------------------------------------*

*   Dump rows per call. Attributes make a row large, so the cap drops
*   when the caller asks for them.
    CONSTANTS c_def_dumps      TYPE i VALUE 20.
    CONSTANTS c_max_dumps      TYPE i VALUE 100.
    CONSTANTS c_max_dumps_attr TYPE i VALUE 20.

*   Tool definitions in Anthropic Messages API shape (input_schema),
*   comma separated and WITHOUT brackets, to splice into the array
*   built by ZCL_ABAPMCP_TOOLS=>GET_TOOL_DEFS.
    CLASS-METHODS get_tool_defs_json
      RETURNING VALUE(ex_json) TYPE string.

*   True if im_name is one of this class's tools.
    CLASS-METHODS handles
      IMPORTING im_name       TYPE string
      RETURNING VALUE(ex_yes) TYPE abap_bool.

*   Same contract as ZCL_ABAPMCP_TOOLS=>EXECUTE: JSON arguments in,
*   JSON result out, {"error":"..."} on failure.
    CLASS-METHODS execute
      IMPORTING im_name          TYPE string
                im_input         TYPE string
      RETURNING VALUE(ex_result) TYPE string.

protected section.
*"* protected components of class ZCL_ABAPMCP_DIAG
*"* do not include other source files here!!!

  PRIVATE SECTION.

    CLASS-METHODS get_dumps
      IMPORTING im_input       TYPE string
      RETURNING VALUE(ex_json) TYPE string
      RAISING   zcx_ajson_error.

    CLASS-METHODS add_field
      IMPORTING im_out   TYPE REF TO zcl_ajson
                im_base  TYPE string
                im_field TYPE string
                im_val   TYPE string
      RAISING   zcx_ajson_error.

    CLASS-METHODS error_json
      IMPORTING im_msg         TYPE string
      RETURNING VALUE(ex_json) TYPE string.

ENDCLASS.


CLASS zcl_abapmcp_diag IMPLEMENTATION.

  METHOD add_field.
*&---------------------------------------------------------------------*
*& Set one string field of one array element: <base>/<field>.
*&---------------------------------------------------------------------*

    DATA lv_path TYPE string.

    CONCATENATE im_base '/' im_field INTO lv_path.
    im_out->set( iv_path = lv_path iv_val = im_val ).

  ENDMETHOD.


  METHOD error_json.
*&---------------------------------------------------------------------*

    DATA lo_out TYPE REF TO zif_ajson.
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
*&---------------------------------------------------------------------*

    DATA lx_root TYPE REF TO cx_root.
    DATA lv_msg  TYPE string.

    TRY.
        CASE im_name.
          WHEN 'sap_get_dumps'.
            ex_result = get_dumps( im_input = im_input ).
          WHEN OTHERS.
            CONCATENATE 'Unknown tool:' im_name INTO lv_msg SEPARATED BY space.
            ex_result = error_json( im_msg = lv_msg ).
        ENDCASE.
      CATCH cx_root INTO lx_root.
        lv_msg = lx_root->get_text( ).
        ex_result = error_json( im_msg = lv_msg ).
    ENDTRY.

  ENDMETHOD.


  METHOD get_dumps.
*&---------------------------------------------------------------------*
*& Short dump list. SNAP holds each dump packed into CHAR 200 rows,
*& so the table is not read directly - CL_ABAP_SNAP unpacks it using the
*& same selection ranges the ST22 screen offers.
*&
*& DATE IS COMPULSORY. Without it the call would unpack every dump the
*& system has kept. Client defaults to the logon client because dumps in
*& client 000 are basis noise when investigating a development client.
*&---------------------------------------------------------------------*

    DATA lo_in     TYPE REF TO zif_ajson.
    DATA lo_out    TYPE REF TO zcl_ajson.
    DATA lv_date   TYPE string.
    DATA lv_errid  TYPE string.
    DATA lv_user   TYPE string.
    DATA lv_client TYPE string.
    DATA lv_attrs  TYPE abap_bool.
    DATA lv_max    TYPE i.
    DATA lv_cap    TYPE i.
    DATA lv_total  TYPE i.
    DATA lv_ret    TYPE i.
    DATA lv_idx    TYPE i.
    DATA lv_aidx   TYPE i.
    DATA lv_i      TYPE string.
    DATA lv_j      TYPE string.
    DATA lv_base   TYPE string.
    DATA lv_abase  TYPE string.
    DATA lv_aelem  TYPE string.
    DATA lv_text   TYPE string.
    DATA lv_note   TYPE string.
    DATA lv_custom TYPE abap_bool.
    DATA lv_prog   TYPE string.
    DATA lv_incl   TYPE string.
    DATA lv_line   TYPE string.
    DATA lv_zprog  TYPE string.
    DATA lv_zincl  TYPE string.
    DATA lv_frame  TYPE string.
    DATA lv_dummy  TYPE string.
    DATA lv_rest   TYPE string.
    DATA lv_out    TYPE i.

    DATA lr_date     TYPE snap_r_date.
    DATA lr_time     TYPE snap_r_time.
    DATA lr_host     TYPE snap_r_host.
    DATA lr_uname    TYPE snap_r_uname.
    DATA lr_client   TYPE snap_r_client.
    DATA lr_errid    TYPE snap_r_errid.
    DATA lr_category TYPE snap_r_category.
    DATA lr_tag_attr TYPE snap_r_tag_attr.

    DATA lw_date   LIKE LINE OF lr_date.
    DATA lw_uname  LIKE LINE OF lr_uname.
    DATA lw_client LIKE LINE OF lr_client.
    DATA lw_errid  LIKE LINE OF lr_errid.

    DATA li_dumps TYPE snap_t_decoded.
    DATA lw_dump  LIKE LINE OF li_dumps.
    DATA lw_attr  LIKE LINE OF lw_dump-attributes.

    lo_in = zcl_ajson=>parse( im_input ).

    lv_date = lo_in->get( '/date' ).
    CONDENSE lv_date.
*   Digits only, before it reaches the date field - a stray letter
*   would cause the very kind of conversion dump this tool looks for.
    IF strlen( lv_date ) <> 8 OR lv_date CN '0123456789'.
      ex_json = error_json( im_msg = 'date is required, 8 digits as YYYYMMDD, for example 20261008.' ).
      RETURN.
    ENDIF.

    lv_errid  = lo_in->get( '/errid' ).
    lv_user   = lo_in->get( '/user' ).
    lv_client = lo_in->get( '/client' ).
    CONDENSE lv_errid.
    CONDENSE lv_user.
    CONDENSE lv_client.
    TRANSLATE lv_errid TO UPPER CASE.
    TRANSLATE lv_user  TO UPPER CASE.

*   whose dumps: one's own needs Z_AI_SCOPE OWN, another user's - or
*   all users' (no user given) - ANY (ZCL_AI_AUTH, 23.10.2026)
    IF zcl_ai_auth=>check_owner( lv_user ) = abap_false.
      lv_errid = zcl_ai_auth=>last_reason( ).
      ex_json = error_json( im_msg = lv_errid ).
      RETURN.
    ENDIF.

    IF lv_client IS INITIAL.
      lv_client = sy-mandt.
    ENDIF.
    IF strlen( lv_client ) <> 3 OR lv_client CN '0123456789'.
      ex_json = error_json( im_msg = 'client must be 3 digits, for example 310. Leave it out for the logon client.' ).
      RETURN.
    ENDIF.

    lv_attrs = abap_false.
    IF lo_in->exists( '/include_attributes' ) = abap_true.
      lv_attrs = lo_in->get_boolean( '/include_attributes' ).
    ENDIF.

*   custom_only: keep only dumps that involve customer code - the
*   program where it broke, or any call-stack frame, is Z/Y (11.10.2026)
    lv_custom = abap_false.
    IF lo_in->exists( '/custom_only' ) = abap_true.
      lv_custom = lo_in->get_boolean( '/custom_only' ).
    ENDIF.

    IF lv_attrs = abap_true.
      lv_cap = c_max_dumps_attr.
    ELSE.
      lv_cap = c_max_dumps.
    ENDIF.
    lv_max = lo_in->get_integer( '/max_results' ).
    IF lv_max <= 0.
      lv_max = c_def_dumps.
    ENDIF.
    IF lv_max > lv_cap.
      lv_max = lv_cap.
    ENDIF.

*   'I' + 'EQ' reads as "include exactly this value", which is what a
*   single entry on the ST22 selection screen means. Ranges left empty
*   (time, host, category, tag attributes) mean "any value".
    lw_date-sign   = 'I'.
    lw_date-option = 'EQ'.
    lw_date-low    = lv_date.
    APPEND lw_date TO lr_date.

    lw_client-sign   = 'I'.
    lw_client-option = 'EQ'.
    lw_client-low    = lv_client.
    APPEND lw_client TO lr_client.

    IF lv_errid IS NOT INITIAL.
      lw_errid-sign   = 'I'.
      lw_errid-option = 'EQ'.
      lw_errid-low    = lv_errid.
      APPEND lw_errid TO lr_errid.
    ENDIF.

    IF lv_user IS NOT INITIAL.
      lw_uname-sign   = 'I'.
      lw_uname-option = 'EQ'.
      lw_uname-low    = lv_user.
      APPEND lw_uname TO lr_uname.
    ENDIF.

    CALL METHOD cl_abap_snap=>get_raw_content
      EXPORTING
        p_r_date         = lr_date
        p_r_time         = lr_time
        p_r_host         = lr_host
        p_r_uname        = lr_uname
        p_r_client       = lr_client
        p_r_errid        = lr_errid
        p_r_category     = lr_category
        p_r_tag_attr     = lr_tag_attr
      IMPORTING
        p_snap_t_decoded = li_dumps.

    DESCRIBE TABLE li_dumps LINES lv_total.

    lo_out = zcl_ajson=>create_empty( ).
    lo_out->set( iv_path = '/date' iv_val = lv_date ).
    lo_out->set( iv_path = '/client' iv_val = lv_client ).
    lo_out->set_integer( iv_path = '/count' iv_val = lv_total ).
    lo_out->touch_array( '/dumps' ).

    lv_out = 0.
    LOOP AT li_dumps INTO lw_dump.

*     Where it broke (ST22 "Program", "Include", line) and the deepest
*     custom frame of the call stack: a dump in standard code (POPUP_TO_
*     DECIDE, say) is often caused by the Z program that called it.
*     Attribute ids of CL_ABAP_SNAP: AP program, AI include, AL line,
*     ES one call-stack line (level, program, include, ...). 11.10.2026
      CLEAR: lv_prog, lv_incl, lv_line, lv_zprog, lv_zincl.
      LOOP AT lw_dump-attributes INTO lw_attr.
        CASE lw_attr-id.
          WHEN 'AP'.
            lv_prog = lw_attr-value.
          WHEN 'AI'.
            lv_incl = lw_attr-value.
          WHEN 'AL'.
            lv_line = lw_attr-value.
          WHEN 'ES'.
            lv_frame = lw_attr-value.
            CONDENSE lv_frame.
            SHIFT lv_frame LEFT DELETING LEADING '0123456789'.
            SPLIT lv_frame AT space INTO lv_frame lv_rest.
            IF lv_frame CP 'Z*' OR lv_frame CP 'Y*' OR lv_frame CP 'SAPLZ*' OR lv_frame CP 'SAPLY*'.
              lv_zprog = lv_frame.
*             class pool ZCL_X=====CP -> class name ZCL_X
              IF lv_zprog CS '='.
                SPLIT lv_zprog AT '=' INTO lv_zprog lv_dummy.
              ENDIF.
              SPLIT lv_rest AT space INTO lv_zincl lv_dummy.
            ENDIF.
        ENDCASE.
      ENDLOOP.
      CONDENSE: lv_prog, lv_incl, lv_line.
      IF lv_zprog IS INITIAL
         AND ( lv_prog CP 'Z*' OR lv_prog CP 'Y*' OR lv_prog CP 'SAPLZ*' OR lv_prog CP 'SAPLY*' ).
        lv_zprog = lv_prog.
        lv_zincl = lv_incl.
      ENDIF.
      IF lv_custom = abap_true AND lv_zprog IS INITIAL.
        CONTINUE.
      ENDIF.

      lv_out = lv_out + 1.
      lv_idx = lv_out.
      IF lv_idx > lv_max.
        CONTINUE.
      ENDIF.
      lv_ret = lv_idx.

      lv_i = lv_idx.
      CONDENSE lv_i.
      CONCATENATE '/dumps/' lv_i INTO lv_base.

      lv_text = lw_dump-date.
      add_field( im_out = lo_out im_base = lv_base im_field = 'date' im_val = lv_text ).
      lv_text = lw_dump-time.
      add_field( im_out = lo_out im_base = lv_base im_field = 'time' im_val = lv_text ).
      lv_text = lw_dump-host.
      add_field( im_out = lo_out im_base = lv_base im_field = 'host' im_val = lv_text ).
      lv_text = lw_dump-uname.
      add_field( im_out = lo_out im_base = lv_base im_field = 'user' im_val = lv_text ).
      lv_text = lw_dump-client.
      add_field( im_out = lo_out im_base = lv_base im_field = 'client' im_val = lv_text ).
*     WPID is numeric: moved into text it is left-padded with blanks
      lv_text = lw_dump-wpid.
      CONDENSE lv_text.
      add_field( im_out = lo_out im_base = lv_base im_field = 'wpid' im_val = lv_text ).
      lv_text = lw_dump-errid.
      add_field( im_out = lo_out im_base = lv_base im_field = 'errid' im_val = lv_text ).
      add_field( im_out = lo_out im_base = lv_base im_field = 'program' im_val = lv_prog ).
      add_field( im_out = lo_out im_base = lv_base im_field = 'include' im_val = lv_incl ).
      add_field( im_out = lo_out im_base = lv_base im_field = 'line' im_val = lv_line ).
      add_field( im_out = lo_out im_base = lv_base im_field = 'custom_program' im_val = lv_zprog ).
      add_field( im_out = lo_out im_base = lv_base im_field = 'custom_include' im_val = lv_zincl ).

      IF lv_attrs = abap_true.
        CONCATENATE lv_base '/attributes' INTO lv_abase.
        lo_out->touch_array( lv_abase ).
        lv_aidx = 0.
        LOOP AT lw_dump-attributes INTO lw_attr.
          lv_aidx = lv_aidx + 1.
          lv_j = lv_aidx.
          CONDENSE lv_j.
          CONCATENATE lv_abase '/' lv_j INTO lv_aelem.
          lv_text = lw_attr-id.
          add_field( im_out = lo_out im_base = lv_aelem im_field = 'id' im_val = lv_text ).
          lv_text = lw_attr-value.
          add_field( im_out = lo_out im_base = lv_aelem im_field = 'value' im_val = lv_text ).
        ENDLOOP.
      ENDIF.

    ENDLOOP.

*   with custom_only the count is the number of custom dumps
    IF lv_custom = abap_true.
      lv_total = lv_out.
      lo_out->set_integer( iv_path = '/count' iv_val = lv_total ).
      lo_out->set_boolean( iv_path = '/custom_only' iv_val = abap_true ).
    ENDIF.
    lo_out->set_integer( iv_path = '/returned' iv_val = lv_ret ).

    IF lv_total = 0.
      lo_out->set( iv_path = '/note'
                   iv_val  = 'No short dumps for that day and client. Check the date, or pass client explicitly if the dump was in another client.' ).
    ELSEIF lv_total > lv_ret.
      lv_note = 'More dumps matched than were returned. Narrow with errid or user rather than raising max_results.'.
      lo_out->set( iv_path = '/note' iv_val = lv_note ).
    ENDIF.

    ex_json = lo_out->stringify( ).

  ENDMETHOD.


  METHOD get_tool_defs_json.
*&---------------------------------------------------------------------*
*& Tool catalogue. Each description says what the tool returns AND what
*& it does not, because overlapping descriptions hurt tool selection
*& more than tool count does.
*&---------------------------------------------------------------------*

    CONCATENATE
      `{"name":"sap_get_dumps",`
      ` "description":"ABAP short dumps (ST22 list) of one day: time, user, client, runtime error, program, `
      `include and line, and custom_program / custom_include - the deepest Z/Y frame of the call stack, `
      `often the cause when the dump is in standard code. No error analysis or source extract - open the `
      `dump in ST22 for that. Narrow with errid or user before asking for attributes.",`
      ` "input_schema":{"type":"object","properties":{`
      `   "date":{"type":"string","description":"YYYYMMDD, e.g. 20261008."},`
      `   "errid":{"type":"string","description":"Runtime error, e.g. DBIF_RSQL_INVALID_RSQL."},`
      `   "user":{"type":"string","description":"SAP user."},`
      `   "client":{"type":"string","description":"Default: logon client."},`
      `   "custom_only":{"type":"boolean","description":"Only dumps involving Z/Y code. Default false."},`
      `   "max_results":{"type":"integer","description":"Default 20, max 100 (20 with attributes)."},`
      `   "include_attributes":{"type":"boolean","description":"Add SAP's attribute list. Large. Default false."}},`
      `   "required":["date"]}}`
      INTO ex_json.

  ENDMETHOD.


  METHOD handles.
*&---------------------------------------------------------------------*

    IF im_name = 'sap_get_dumps'.
      ex_yes = abap_true.
    ENDIF.

  ENDMETHOD.



ENDCLASS.
