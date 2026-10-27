CLASS zcl_abapmcp_tools DEFINITION PUBLIC FINAL CREATE PUBLIC.
*&---------------------------------------------------------------------*
*& The tools. Read-only access to the ABAP repository.
*&
*& Every method here is a SELECT or a READ REPORT. There is no write
*& path in this class and adding one would defeat the purpose - see
*& CONTRIBUTING.md.
*&
*& NAMESPACE GUARD
*& Only Z and Y objects can be read. Enforced here, in ABAP, before any
*& tool body runs. A prompt instruction is advice; this is a gate.
*& One exception: SAP_GET_DDIC also reads SAP standard tables and
*& structures - a field list is metadata, not data or source, and
*& functional consultants need it to verify table names.
*&
*& SOURCE PAGING
*& A 2800 line program does not fit in a model's context, and its first
*& 300 lines are declarations - an answer based on those looks complete
*& and is not. GET_SOURCE therefore returns a structural skeleton
*& covering the WHOLE object plus the source of the routines carrying
*& the most logic, and the caller asks for further routines by name.
*&
*& NW 7.02 syntax only: no inline DATA( ), no VALUE #( ), no NEW.
*&---------------------------------------------------------------------*

  PUBLIC SECTION.

    CONSTANTS c_max_chars TYPE i VALUE 14000.
    CONSTANTS c_max_rows  TYPE i VALUE 100.
    CONSTANTS c_window    TYPE i VALUE 400.

    CLASS-METHODS get_tool_defs
      RETURNING VALUE(ro_json) TYPE REF TO zif_ajson
      RAISING   zcx_ajson_error.

*   May the caller come in this way? Wrapper for ZCL_AI_AUTH=>
*   CHECK_CHANNEL.
    CLASS-METHODS is_authorised
      IMPORTING im_channel   TYPE zai_chan DEFAULT 'MCP'
      RETURNING VALUE(rv_ok) TYPE abap_bool.

    CLASS-METHODS execute
      IMPORTING iv_name          TYPE string
                iv_input         TYPE string
      RETURNING VALUE(rv_result) TYPE string.

    CLASS-METHODS check_custom
      IMPORTING iv_name      TYPE string
      RETURNING VALUE(rv_ok) TYPE abap_bool.

*   Is a tool exposed in this system? Controlled by ZABAPMCP_CFG key
*   TOOLS_DISABLED - a comma separated list of tool names. Absent or
*   empty means everything is on.
*
*   Why: a site may be comfortable exposing DDIC metadata and
*   where-used but not full source, or may want to switch one tool off
*   after an incident without a transport. Hardcoding the catalogue
*   makes that a code change.
    CLASS-METHODS is_enabled
      IMPORTING iv_tool      TYPE string
      RETURNING VALUE(rv_ok) TYPE abap_bool.

PROTECTED SECTION.

  PRIVATE SECTION.

    CLASS-METHODS get_source
      IMPORTING iv_name        TYPE string
                iv_routine     TYPE string OPTIONAL
                iv_from        TYPE i OPTIONAL
                iv_to          TYPE i OPTIONAL
      RETURNING VALUE(rv_json) TYPE string
      RAISING   zcx_ajson_error.

    CLASS-METHODS get_ddic
      IMPORTING iv_name        TYPE string
      RETURNING VALUE(rv_json) TYPE string
      RAISING   zcx_ajson_error.

*   Name check of the read tools: CHECK_CUSTOM plus the main program and
*   includes of custom function groups (SAPLZ*, SAPLY*, LZ*, LY*).
*   Write paths keep CHECK_CUSTOM.
    CLASS-METHODS check_custom_read
      IMPORTING iv_name      TYPE string
      RETURNING VALUE(rv_ok) TYPE abap_bool.

    CLASS-METHODS search_objects
      IMPORTING iv_pattern     TYPE string
                iv_max         TYPE i
      RETURNING VALUE(rv_json) TYPE string
      RAISING   zcx_ajson_error.

    CLASS-METHODS where_used
      IMPORTING iv_name        TYPE string
      RETURNING VALUE(rv_json) TYPE string
      RAISING   zcx_ajson_error.

    CLASS-METHODS read_class_source
      IMPORTING iv_class  TYPE string
      EXPORTING et_source TYPE string_table.

    CLASS-METHODS append_report
      IMPORTING iv_prog   TYPE string
      CHANGING  ct_source TYPE string_table.

    CLASS-METHODS error_json
      IMPORTING iv_msg         TYPE string
      RETURNING VALUE(rv_json) TYPE string.

ENDCLASS.


CLASS zcl_abapmcp_tools IMPLEMENTATION.

  METHOD append_report.

    DATA lv_prog TYPE program.
    DATA lt_tmp  TYPE string_table.
    DATA lv_hdr  TYPE string.

    lv_prog = iv_prog.

    READ REPORT lv_prog INTO lt_tmp.
    IF sy-subrc <> 0 OR lt_tmp IS INITIAL.
      RETURN.
    ENDIF.

    CONCATENATE '*--- ' iv_prog ' ---*' INTO lv_hdr.
    APPEND lv_hdr TO ct_source.
    APPEND LINES OF lt_tmp TO ct_source.

  ENDMETHOD.


  METHOD check_custom.

    DATA lv_up TYPE string.

    lv_up = iv_name.
    TRANSLATE lv_up TO UPPER CASE.
    SHIFT lv_up LEFT DELETING LEADING space.

    IF lv_up IS INITIAL.
      rv_ok = abap_false.
      RETURN.
    ENDIF.

    IF lv_up(1) = 'Z' OR lv_up(1) = 'Y'.
      rv_ok = abap_true.
    ELSE.
      rv_ok = abap_false.
    ENDIF.

  ENDMETHOD.


  METHOD check_custom_read.
*&---------------------------------------------------------------------*
*& A custom function group's main program is SAPL<group> and its
*& includes are L<group><suffix>, so a group named Z... or Y... has
*& source names starting SAPLZ, SAPLY, LZ or LY. SAP's own groups never
*& start with Z or Y, so these four prefixes are always customer code.
*& Only the read tools use this; abapsync's write checks keep
*& CHECK_CUSTOM, so nothing new becomes writable.
*&---------------------------------------------------------------------*

    DATA lv_up TYPE string.

    rv_ok = check_custom( iv_name ).
    IF rv_ok = abap_true.
      RETURN.
    ENDIF.

    lv_up = iv_name.
    TRANSLATE lv_up TO UPPER CASE.
    SHIFT lv_up LEFT DELETING LEADING space.

    IF lv_up CP 'SAPLZ*' OR lv_up CP 'SAPLY*' OR lv_up CP 'LZ*' OR lv_up CP 'LY*'.
      rv_ok = abap_true.
    ENDIF.

  ENDMETHOD.


  METHOD error_json.

    DATA lo_out TYPE REF TO zcl_ajson.
    DATA lx     TYPE REF TO cx_root.

    TRY.
        lo_out = zcl_ajson=>create_empty( ).
        lo_out->set( iv_path = '/error' iv_val = iv_msg ).
        rv_json = lo_out->stringify( ).
      CATCH cx_root INTO lx.
        rv_json = '{"error":"internal"}'.
    ENDTRY.

  ENDMETHOD.


  METHOD execute.

    CONSTANTS lc_refuse TYPE string
      VALUE 'Refused. This server is restricted to custom objects - names must start with Z or Y. SAP standard objects are out of scope.'.

    DATA lo_in  TYPE REF TO zif_ajson.
    DATA lv_nam TYPE string.
    DATA lv_pat TYPE string.
    DATA lv_rtn TYPE string.
    DATA lv_max TYPE i.
    DATA lv_frm TYPE i.
    DATA lv_to  TYPE i.
    DATA lx     TYPE REF TO cx_root.

*   no authorization for the tool's group, no tool - also for programs
*   that call a tool directly instead of over /sap/bc/mcp. ZCL_AI_AUTH
*   decides (Z_AI_TOOL, or ZMCP_USE in AUTH_MODE LEGACY/DUAL).
    IF zcl_ai_auth=>check_tool( iv_name ) = abap_false.
      lv_nam = zcl_ai_auth=>last_reason( ).
      rv_result = error_json( lv_nam ).
      RETURN.
    ENDIF.

*   A tool switched off must also refuse to RUN, not merely vanish from
*   the catalogue. A client with a cached tool list would otherwise
*   still reach it.
    IF is_enabled( iv_name ) = abap_false.
      rv_result = error_json( 'This tool is switched off in this system.' ).
      RETURN.
    ENDIF.

    IF zcl_abapmcp_sync=>handles( iv_name ) = abap_true.
      rv_result = zcl_abapmcp_sync=>execute( iv_name  = iv_name
                                             iv_input = iv_input ).
      RETURN.
    ENDIF.

*   spec search and short dumps: take a question or a date, not an
*   object name, so CHECK_CUSTOM does not apply - see ZCL_ABAPMCP_DIAG
    IF zcl_abapmcp_diag=>handles( iv_name ) = abap_true.
      rv_result = zcl_abapmcp_diag=>execute( im_name  = iv_name
                                             im_input = iv_input ).
      RETURN.
    ENDIF.

*   configuration lookups: about SAP standard objects by design, with
*   their own guards for table rows - see ZCL_ABAPMCP_CUST
    IF zcl_abapmcp_cust=>handles( iv_name ) = abap_true.
      rv_result = zcl_abapmcp_cust=>execute( im_name  = iv_name
                                             im_input = iv_input ).
      RETURN.
    ENDIF.

*   transport and change history: take a word or one object name and
*   guard Z/Y and S_TRANSPRT themselves - see ZCL_ABAPMCP_CTS
    IF zcl_abapmcp_cts=>handles( iv_name ) = abap_true.
      rv_result = zcl_abapmcp_cts=>execute( im_name  = iv_name
                                            im_input = iv_input ).
      RETURN.
    ENDIF.

*   BW extractors (DataSources): metadata, exits, BAdIs - see
*   ZCL_ABAPMCP_BW
    IF zcl_abapmcp_bw=>handles( iv_name ) = abap_true.
      rv_result = zcl_abapmcp_bw=>execute( im_name  = iv_name
                                           im_input = iv_input ).
      RETURN.
    ENDIF.

*   session check: system, client, user, own authorizations - see
*   ZCL_ABAPMCP_WHOAMI
    IF zcl_abapmcp_whoami=>handles( iv_name ) = abap_true.
      rv_result = zcl_abapmcp_whoami=>execute( im_name  = iv_name
                                               im_input = iv_input ).
      RETURN.
    ENDIF.

    TRY.
        lo_in = zcl_ajson=>parse( iv_input ).

        CASE iv_name.

          WHEN 'sap_get_source'.
            lv_nam = lo_in->get( '/name' ).
            IF check_custom_read( lv_nam ) = abap_false.
              rv_result = error_json( lc_refuse ).
              RETURN.
            ENDIF.
*           the package of the code must be readable (Z_AI_SCOPE)
            IF zcl_ai_auth=>check_object( lv_nam ) = abap_false.
              lv_pat = zcl_ai_auth=>last_reason( ).
              rv_result = error_json( lv_pat ).
              RETURN.
            ENDIF.
            lv_rtn = lo_in->get( '/routine' ).
            lv_frm = lo_in->get_integer( '/from_line' ).
            lv_to  = lo_in->get_integer( '/to_line' ).
            rv_result = get_source( iv_name    = lv_nam
                                    iv_routine = lv_rtn
                                    iv_from    = lv_frm
                                    iv_to      = lv_to ).

*         a field list is metadata - standard tables are allowed too
          WHEN 'sap_get_ddic'.
            lv_nam = lo_in->get( '/name' ).
            IF lv_nam IS INITIAL.
              rv_result = error_json( 'Give a table or structure name.' ).
              RETURN.
            ENDIF.
            rv_result = get_ddic( lv_nam ).

          WHEN 'sap_where_used'.
            lv_nam = lo_in->get( '/name' ).
            IF check_custom_read( lv_nam ) = abap_false.
              rv_result = error_json( lc_refuse ).
              RETURN.
            ENDIF.
            rv_result = where_used( lv_nam ).

          WHEN 'sap_search_objects'.
            lv_pat = lo_in->get( '/pattern' ).
            IF check_custom( lv_pat ) = abap_false.
              rv_result = error_json( 'Refused. Search patterns must begin with Z or Y, for example Z* or ZFI*.' ).
              RETURN.
            ENDIF.
            lv_max = lo_in->get_integer( '/max_results' ).
            IF lv_max <= 0 OR lv_max > c_max_rows.
              lv_max = 50.
            ENDIF.
            rv_result = search_objects( iv_pattern = lv_pat
                                        iv_max     = lv_max ).

          WHEN OTHERS.
            CONCATENATE 'Unknown tool:' iv_name INTO lv_nam SEPARATED BY space.
            rv_result = error_json( lv_nam ).

        ENDCASE.

      CATCH cx_root INTO lx.
        rv_result = error_json( lx->get_text( ) ).
    ENDTRY.

  ENDMETHOD.


  METHOD get_ddic.

    DATA lo_out   TYPE REF TO zcl_ajson.
    DATA lv_name  TYPE ddobjname.
    DATA lt_dfies TYPE STANDARD TABLE OF dfies.
    DATA ls_dfies TYPE dfies.
    DATA lv_idx   TYPE i.
    DATA lv_i     TYPE string.
    DATA lv_path  TYPE string.
    DATA lv_up    TYPE string.
    DATA lv_key   TYPE abap_bool.
    DATA lv_leng  TYPE i.
    DATA lv_dec   TYPE i.

    lv_up = iv_name.
    TRANSLATE lv_up TO UPPER CASE.
    CONDENSE lv_up.
    lv_name = lv_up.

    CALL FUNCTION 'DDIF_FIELDINFO_GET'
      EXPORTING
        tabname        = lv_name
      TABLES
        dfies_tab      = lt_dfies
      EXCEPTIONS
        not_found      = 1
        internal_error = 2
        OTHERS         = 3.

    IF sy-subrc <> 0 OR lt_dfies IS INITIAL.
      rv_json = error_json( 'Table or structure not found' ).
      RETURN.
    ENDIF.

    lo_out = zcl_ajson=>create_empty( ).
    lo_out->set( iv_path = '/object' iv_val = lv_up ).
    lo_out->touch_array( '/fields' ).

    LOOP AT lt_dfies INTO ls_dfies.
      lv_idx = sy-tabix.
      lv_i = lv_idx.
      CONDENSE lv_i.

      CONCATENATE '/fields/' lv_i '/name' INTO lv_path.
      lo_out->set( iv_path = lv_path iv_val = ls_dfies-fieldname ).

      CONCATENATE '/fields/' lv_i '/type' INTO lv_path.
      lo_out->set( iv_path = lv_path iv_val = ls_dfies-datatype ).

      lv_leng = ls_dfies-leng.
      CONCATENATE '/fields/' lv_i '/length' INTO lv_path.
      lo_out->set_integer( iv_path = lv_path iv_val = lv_leng ).

      lv_dec = ls_dfies-decimals.
      CONCATENATE '/fields/' lv_i '/decimals' INTO lv_path.
      lo_out->set_integer( iv_path = lv_path iv_val = lv_dec ).

      IF ls_dfies-keyflag = abap_true.
        lv_key = abap_true.
      ELSE.
        lv_key = abap_false.
      ENDIF.
      CONCATENATE '/fields/' lv_i '/key' INTO lv_path.
      lo_out->set_boolean( iv_path = lv_path iv_val = lv_key ).

      CONCATENATE '/fields/' lv_i '/rollname' INTO lv_path.
      lo_out->set( iv_path = lv_path iv_val = ls_dfies-rollname ).

      CONCATENATE '/fields/' lv_i '/text' INTO lv_path.
      lo_out->set( iv_path = lv_path iv_val = ls_dfies-fieldtext ).
    ENDLOOP.

    rv_json = lo_out->stringify( ).

  ENDMETHOD.


  METHOD get_source.

    DATA lo_out      TYPE REF TO zcl_ajson.
    DATA lt_source   TYPE string_table.
    DATA lt_window   TYPE string_table.
    DATA ls_struct   TYPE zcl_abapmcp_structure=>ty_result.
    DATA ls_blk      TYPE zcl_abapmcp_structure=>ty_block.
    DATA lv_line     TYPE string.
    DATA lv_name     TYPE string.
    DATA lv_rtn      TYPE string.
    DATA lv_text     TYPE string.
    DATA lv_skel     TYPE string.
    DATA lv_hot      TYPE string.
    DATA lv_total    TYPE i.
    DATA lv_from     TYPE i.
    DATA lv_to       TYPE i.
    DATA lv_idx      TYPE i.
    DATA lv_ret      TYPE i.
    DATA lv_budget   TYPE i.
    DATA lv_len      TYPE i.
    DATA lv_seoclass TYPE seoclsname.
    DATA lv_clstype  TYPE seoclass-clstype.
    DATA lv_root     TYPE c LENGTH 30.
    DATA lv_inc      TYPE string.

    lv_name = iv_name.
    TRANSLATE lv_name TO UPPER CASE.
    CONDENSE lv_name.

    lo_out = zcl_ajson=>create_empty( ).
    lo_out->set( iv_path = '/object' iv_val = lv_name ).

*   ---- read the whole object ----------------------------------------
    lv_seoclass = lv_name.
    SELECT SINGLE clsname clstype FROM seoclass INTO (lv_seoclass, lv_clstype)
      WHERE clsname = lv_seoclass.
    IF sy-subrc = 0 AND lv_clstype = '1'.
*     SEOCLASS holds interfaces too. An interface has one include, the
*     name padded with = to 30 characters plus IU - the class path asked
*     for method includes and dumped with CLASS_NOT_EXISTING.
      lv_root = lv_name.
      TRANSLATE lv_root USING ' ='.
      CONCATENATE lv_root 'IU' INTO lv_inc.
      append_report( EXPORTING iv_prog   = lv_inc
                     CHANGING  ct_source = lt_source ).
      lo_out->set( iv_path = '/type' iv_val = 'INTF' ).
    ELSEIF sy-subrc = 0.
      read_class_source( EXPORTING iv_class  = lv_name
                         IMPORTING et_source = lt_source ).
      lo_out->set( iv_path = '/type' iv_val = 'CLAS' ).
    ELSE.
      append_report( EXPORTING iv_prog   = lv_name
                     CHANGING  ct_source = lt_source ).
      lo_out->set( iv_path = '/type' iv_val = 'PROG' ).
    ENDIF.

    IF lt_source IS INITIAL.
      rv_json = error_json( 'Object not found or has no source' ).
      RETURN.
    ENDIF.

    DESCRIBE TABLE lt_source LINES lv_total.
    lo_out->set_integer( iv_path = '/lines_total' iv_val = lv_total ).

    ls_struct = zcl_abapmcp_structure=>analyse( it_source = lt_source
                                                iv_object = lv_name ).

    lo_out->set_integer( iv_path = '/lines_net'  iv_val = ls_struct-lines_net ).
    lo_out->set_integer( iv_path = '/confidence' iv_val = ls_struct-confidence ).
    IF ls_struct-conf_note IS NOT INITIAL.
      lo_out->set( iv_path = '/confidence_note' iv_val = ls_struct-conf_note ).
    ENDIF.

*   ---- mode 2: one named routine ------------------------------------
    lv_rtn = iv_routine.
    TRANSLATE lv_rtn TO UPPER CASE.
    CONDENSE lv_rtn.

    IF lv_rtn IS NOT INITIAL.

      READ TABLE ls_struct-blocks INTO ls_blk WITH KEY name = lv_rtn.
      IF sy-subrc <> 0.
        lo_out->set( iv_path = '/error'
                     iv_val  = 'Routine not found. Use a name from the routines list in the skeleton.' ).
        rv_json = lo_out->stringify( ).
        RETURN.
      ENDIF.

      lv_text = zcl_abapmcp_structure=>get_routine( it_source = lt_source
                                                    is_result = ls_struct
                                                    iv_name   = lv_rtn ).

      IF strlen( lv_text ) > c_max_chars.
        lv_text = lv_text(c_max_chars).
        lo_out->set( iv_path = '/note' iv_val = 'Routine truncated - it is unusually long.' ).
      ENDIF.

      lo_out->set( iv_path = '/mode'    iv_val = 'ROUTINE' ).
      lo_out->set( iv_path = '/routine' iv_val = lv_rtn ).
      lo_out->set( iv_path = '/source'  iv_val = lv_text ).
      lo_out->set_integer( iv_path = '/routine_from' iv_val = ls_blk-from ).
      lo_out->set_integer( iv_path = '/routine_to'   iv_val = ls_blk-to ).

      rv_json = lo_out->stringify( ).
      RETURN.

    ENDIF.

*   ---- mode 3: explicit line window ---------------------------------
    IF iv_from > 0 OR iv_to > 0.

      lv_from = iv_from.
      IF lv_from <= 0.
        lv_from = 1.
      ENDIF.
      IF lv_from > lv_total.
        lv_from = lv_total.
      ENDIF.

      lv_to = iv_to.
      IF lv_to <= 0 OR lv_to > lv_total.
        lv_to = lv_total.
      ENDIF.
      IF lv_to < lv_from.
        lv_to = lv_from.
      ENDIF.
      IF ( lv_to - lv_from ) >= c_window.
        lv_to = lv_from + c_window - 1.
      ENDIF.

      lv_budget = c_max_chars - 800.
      lv_idx = lv_from.
      WHILE lv_idx <= lv_to.
        READ TABLE lt_source INTO lv_line INDEX lv_idx.
        IF sy-subrc <> 0.
          EXIT.
        ENDIF.
        lv_len = strlen( lv_line ) + 1.
        IF lv_budget - lv_len < 0 AND lt_window IS NOT INITIAL.
          lv_to = lv_idx - 1.
          EXIT.
        ENDIF.
        APPEND lv_line TO lt_window.
        lv_budget = lv_budget - lv_len.
        lv_idx = lv_idx + 1.
      ENDWHILE.

      DESCRIBE TABLE lt_window LINES lv_ret.
      CONCATENATE LINES OF lt_window INTO lv_text
        SEPARATED BY cl_abap_char_utilities=>newline.

      lo_out->set( iv_path = '/mode'   iv_val = 'WINDOW' ).
      lo_out->set( iv_path = '/source' iv_val = lv_text ).
      lo_out->set_integer( iv_path = '/from_line'      iv_val = lv_from ).
      lo_out->set_integer( iv_path = '/to_line'        iv_val = lv_to ).
      lo_out->set_integer( iv_path = '/lines_returned' iv_val = lv_ret ).

      IF lv_to < lv_total.
        lv_idx  = lv_to + 1.
        lv_line = lv_idx.
        CONDENSE lv_line.
        CONCATENATE 'More source follows. Call again with from_line ='
                    lv_line 'or ask for a routine by name.'
               INTO lv_line SEPARATED BY space.
        lo_out->set( iv_path = '/note' iv_val = lv_line ).
      ENDIF.

      rv_json = lo_out->stringify( ).
      RETURN.

    ENDIF.

*   ---- mode 1: skeleton plus the routines that matter ---------------
    lv_skel = zcl_abapmcp_structure=>to_prompt( ls_struct ).

    lv_budget = c_max_chars - strlen( lv_skel ) - 800.
    IF lv_budget < 1000.
      lv_budget = 1000.
    ENDIF.
    lv_idx = lv_budget / 60.

    lv_hot = zcl_abapmcp_structure=>get_hot_routines(
               it_source    = lt_source
               is_result    = ls_struct
               iv_count     = 3
               iv_max_lines = lv_idx ).

    IF lv_hot IS INITIAL.
      lv_to = 150.
      IF lv_to > lv_total.
        lv_to = lv_total.
      ENDIF.
      lt_window = zcl_abapmcp_structure=>strip( it_source = lt_source
                                                iv_from   = 1
                                                iv_to     = lv_to ).
      CONCATENATE LINES OF lt_window INTO lv_hot
        SEPARATED BY cl_abap_char_utilities=>newline.
      lo_out->set( iv_path = '/note'
                   iv_val  = 'No routines detected. First 150 stripped lines returned. Use from_line and to_line to read further.' ).
    ENDIF.

    CONCATENATE lv_skel
                cl_abap_char_utilities=>newline
                cl_abap_char_utilities=>newline
                lv_hot
           INTO lv_text.

    IF strlen( lv_text ) > c_max_chars.
      lv_text = lv_text(c_max_chars).
    ENDIF.

    lo_out->set( iv_path = '/mode' iv_val = 'STRUCTURE' ).
    lo_out->set( iv_path = '/structure_and_source' iv_val = lv_text ).
    lo_out->set_integer( iv_path = '/routines' iv_val = lines( ls_struct-blocks ) ).

    rv_json = lo_out->stringify( ).

  ENDMETHOD.


  METHOD get_tool_defs.

    DATA lv_json TYPE string.
    DATA lt_mem  TYPE string_table.
    DATA lv_mem  TYPE string.
    DATA lv_path TYPE string.
    DATA lv_tool TYPE string.
    DATA lv_sync TYPE string.
    DATA lv_diag TYPE string.
    DATA lv_cust TYPE string.
    DATA lv_cts  TYPE string.
    DATA lv_bw   TYPE string.
    DATA lv_who  TYPE string.

    lv_sync = zcl_abapmcp_sync=>get_tool_defs_json( ).
*   sap_get_dumps
    lv_diag = zcl_abapmcp_diag=>get_tool_defs_json( ).
*   sap_tcode_info, sap_find_config, sap_read_config
    lv_cust = zcl_abapmcp_cust=>get_tool_defs_json( ).
*   sap_transport_search, sap_object_transports, sap_search_source
    lv_cts = zcl_abapmcp_cts=>get_tool_defs_json( ).
*   sap_bw_datasources, sap_bw_datasource_info, sap_bw_table_datasources
    lv_bw = zcl_abapmcp_bw=>get_tool_defs_json( ).
*   sap_whoami
    lv_who = zcl_abapmcp_whoami=>get_tool_defs_json( ).


    CONCATENATE
      `[`
      `{"name":"sap_get_source",`
      ` "description":"Read ABAP source of a custom program, include or class. Over 400 lines, the first `
      `call returns a skeleton of the WHOLE object - tables read and written, FMs and BAPIs called, every `
      `routine with a complexity score - plus the routines with the most logic. Then call again with `
      `routine set to read one in full; prefer that over line ranges.",`
      ` "input_schema":{"type":"object","properties":{`
      `   "name":{"type":"string","description":"Program, include or class, e.g. ZCL_FOO."},`
      `   "routine":{"type":"string","description":"One routine from the skeleton's list."},`
      `   "from_line":{"type":"integer","description":"Only for includes without routines."},`
      `   "to_line":{"type":"integer","description":"Only for includes without routines."}},`
      `   "required":["name"]}},`
      `{"name":"sap_get_ddic",`
      ` "description":"Read the field list of a DDIC table or structure - custom or SAP standard: field `
      `names, data types, lengths, decimals, key flags, data elements and descriptions. Call this before `
      `writing a SELECT or declaring a work area, or before naming a configuration table, so names and `
      `types match the real system rather than being guessed. Returns the structure only, never rows.",`
      ` "input_schema":{"type":"object","properties":{`
      `   "name":{"type":"string","description":"Table or structure name, e.g. ZABAPMCP_LOG or T001W."}},`
      `   "required":["name"]}},`
      `{"name":"sap_search_objects",`
      ` "description":"Search the repository directory for custom objects matching a NAME pattern. `
      `This matches object names only - it cannot find which programs use an object. For that use `
      `sap_where_used.",`
      ` "input_schema":{"type":"object","properties":{`
      `   "pattern":{"type":"string","description":"Pattern with * wildcards, must start with Z or Y, e.g. ZFI*."},`
      `   "max_results":{"type":"integer","description":"Maximum hits, 1-100. Default 50."}},`
      `   "required":["pattern"]}},`
      `{"name":"sap_where_used",`
      ` "description":"Where-used list for any custom object: tables, structures, data elements, function `
      `modules, programs, classes, interfaces, methods, transactions and FORM routines. Reads the same `
      `cross-reference indexes as SE11 and SE80. Each hit gives the include, the owning object where the `
      `include belongs to a class, and how it is used. Use this whenever asked where something is used - `
      `never guess candidates and read their source one by one.",`
      ` "input_schema":{"type":"object","properties":{`
      `   "name":{"type":"string","description":"Any custom object name, e.g. ZABAPMCP_LOG."}},`
      `   "required":["name"]}}`
      `,`
       lv_sync
      `,`
       lv_diag
      `,`
       lv_cust
      `,`
       lv_cts
      `,`
       lv_bw
      `,`
       lv_who
      `]`
      INTO lv_json.

    ro_json = zcl_ajson=>parse( lv_json ).

*   ---- drop anything switched off, or not the caller's -------------
*   Deleting from the parsed array keeps one catalogue definition and
*   avoids building the JSON conditionally, which would be far easier
*   to get wrong. ZCL_AI_AUTH=>TOOL_VISIBLE keeps only the tool groups
*   the caller holds (Z_AI_TOOL), so the model never tries a tool that
*   would be refused (23.10.2026).
    lt_mem = ro_json->members( '' ).

    LOOP AT lt_mem INTO lv_mem.
      CONCATENATE '/' lv_mem '/name' INTO lv_path.
      lv_tool = ro_json->get( lv_path ).
      IF is_enabled( lv_tool ) = abap_false
        OR zcl_ai_auth=>tool_visible( lv_tool ) = abap_false.
        CONCATENATE '/' lv_mem INTO lv_path.
        ro_json->delete( lv_path ).
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD is_authorised.
*&---------------------------------------------------------------------*
*& The access check of the MCP tools, for the ICF handler and for any
*& program that calls a tool directly - not over HTTP. A thin wrapper:
*& ZCL_AI_AUTH checks the channel the caller names (Z_AI_CHAN), or
*& ZMCP_USE (ZUSER = own user, ACTVT 03) while AUTH_MODE is LEGACY or
*& DUAL. New code calls ZCL_AI_AUTH directly.
*&---------------------------------------------------------------------*

    rv_ok = zcl_ai_auth=>check_channel( im_channel ).

  ENDMETHOD.


  METHOD is_enabled.

    DATA lv_list TYPE zabapmcp_cfg-cfg_value.
    DATA lv_up   TYPE string.
    DATA lv_hit  TYPE string.

    rv_ok = abap_true.

    SELECT SINGLE cfg_value FROM zabapmcp_cfg INTO lv_list
      WHERE cfg_key = 'TOOLS_DISABLED'.

    IF sy-subrc <> 0 OR lv_list IS INITIAL.
      RETURN.
    ENDIF.

    lv_up = lv_list.
    TRANSLATE lv_up TO UPPER CASE.

    lv_hit = iv_tool.
    TRANSLATE lv_hit TO UPPER CASE.
    CONDENSE lv_hit.

*   substring match is enough - tool names are distinct and none is a
*   prefix of another
    IF lv_up CS lv_hit.
      rv_ok = abap_false.
    ENDIF.

  ENDMETHOD.


  METHOD read_class_source.

    DATA lv_inc    TYPE string.
    DATA lv_cls    TYPE seoclsname.
    DATA lt_cmp    TYPE STANDARD TABLE OF seocompo.
    DATA ls_cmp    TYPE seocompo.
    DATA ls_mtdkey TYPE seocpdkey.
    DATA lv_prog   TYPE program.

    lv_cls = iv_class.

    lv_prog = cl_oo_classname_service=>get_pubsec_name( lv_cls ).
    lv_inc = lv_prog.
    append_report( EXPORTING iv_prog = lv_inc CHANGING ct_source = et_source ).

    lv_prog = cl_oo_classname_service=>get_prosec_name( lv_cls ).
    lv_inc = lv_prog.
    append_report( EXPORTING iv_prog = lv_inc CHANGING ct_source = et_source ).

    lv_prog = cl_oo_classname_service=>get_prisec_name( lv_cls ).
    lv_inc = lv_prog.
    append_report( EXPORTING iv_prog = lv_inc CHANGING ct_source = et_source ).

    lv_prog = cl_oo_classname_service=>get_ccimp_name( lv_cls ).
    lv_inc = lv_prog.
    append_report( EXPORTING iv_prog = lv_inc CHANGING ct_source = et_source ).

    SELECT * FROM seocompo INTO TABLE lt_cmp
      WHERE clsname = lv_cls
        AND cmptype = 1.

    LOOP AT lt_cmp INTO ls_cmp.
      CLEAR ls_mtdkey.
      ls_mtdkey-clsname = ls_cmp-clsname.
      ls_mtdkey-cpdname = ls_cmp-cmpname.
      lv_prog = cl_oo_classname_service=>get_method_include( ls_mtdkey ).
      IF lv_prog IS NOT INITIAL.
        lv_inc = lv_prog.
        append_report( EXPORTING iv_prog = lv_inc CHANGING ct_source = et_source ).
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD search_objects.

    TYPES: BEGIN OF ty_hit,
             obj_name TYPE tadir-obj_name,
             object   TYPE tadir-object,
             devclass TYPE tadir-devclass,
           END OF ty_hit.

    DATA lo_out  TYPE REF TO zcl_ajson.
    DATA lt_hit  TYPE STANDARD TABLE OF ty_hit.
    DATA ls_hit  TYPE ty_hit.
    DATA lv_like TYPE tadir-obj_name.
    DATA lv_pat  TYPE string.
    DATA lv_idx  TYPE i.
    DATA lv_i    TYPE string.
    DATA lv_path TYPE string.
    DATA lv_rows TYPE i.
    DATA lv_more TYPE abap_bool.

    lv_pat = iv_pattern.
    TRANSLATE lv_pat TO UPPER CASE.
    CONDENSE lv_pat.
    REPLACE ALL OCCURRENCES OF '*' IN lv_pat WITH '%'.
    lv_like = lv_pat.

*   one row more than asked for tells whether the list is cut off, so
*   the answer can say so instead of looking complete
    lv_rows = iv_max + 1.
    SELECT obj_name object devclass
      FROM tadir
      INTO TABLE lt_hit
      UP TO lv_rows ROWS
      WHERE pgmid    = 'R3TR'
        AND obj_name LIKE lv_like
        AND ( obj_name LIKE 'Z%' OR obj_name LIKE 'Y%' )
        AND delflag  = space.
    IF lines( lt_hit ) > iv_max.
      DELETE lt_hit INDEX lv_rows.
      lv_more = abap_true.
    ENDIF.

    lo_out = zcl_ajson=>create_empty( ).
    lo_out->touch_array( '/results' ).

    LOOP AT lt_hit INTO ls_hit.
      lv_idx = sy-tabix.
      lv_i = lv_idx.
      CONDENSE lv_i.

      CONCATENATE '/results/' lv_i '/name' INTO lv_path.
      lo_out->set( iv_path = lv_path iv_val = ls_hit-obj_name ).

      CONCATENATE '/results/' lv_i '/type' INTO lv_path.
      lo_out->set( iv_path = lv_path iv_val = ls_hit-object ).

      CONCATENATE '/results/' lv_i '/package' INTO lv_path.
      lo_out->set( iv_path = lv_path iv_val = ls_hit-devclass ).
    ENDLOOP.

    lo_out->set_integer( iv_path = '/count' iv_val = lv_idx ).
    IF lv_more = abap_true.
      lo_out->set_boolean( iv_path = '/truncated' iv_val = abap_true ).
      lo_out->set( iv_path = '/note'
                   iv_val  = 'More objects match than were returned. Raise max_results (at most 100) or narrow the pattern - the list is not complete.' ).
    ENDIF.

    rv_json = lo_out->stringify( ).

  ENDMETHOD.


  METHOD where_used.

    TYPES: BEGIN OF ty_hit,
             include TYPE progname,
             via     TYPE string,
           END OF ty_hit.

    DATA lo_out   TYPE REF TO zcl_ajson.
    DATA lt_hit   TYPE STANDARD TABLE OF ty_hit.
    DATA ls_hit   TYPE ty_hit.
    DATA lt_gt    TYPE STANDARD TABLE OF wbcrossgt.
    DATA ls_gt    TYPE wbcrossgt.
    DATA lt_cr    TYPE STANDARD TABLE OF cross.
    DATA ls_cr    TYPE cross.
    DATA lv_gtnam TYPE eu_lname.
    DATA lv_crnam TYPE seu_name.
    DATA lv_up    TYPE string.
    DATA lv_idx   TYPE i.
    DATA lv_i     TYPE string.
    DATA lv_path  TYPE string.
    DATA lv_pos   TYPE i.

    lv_up = iv_name.
    TRANSLATE lv_up TO UPPER CASE.
    CONDENSE lv_up.

    lv_gtnam = lv_up.
    lv_crnam = lv_up.

*   WBCROSSGT - types, DDIC objects, classes, interfaces, methods
    SELECT * FROM wbcrossgt
      INTO TABLE lt_gt
      UP TO c_max_rows ROWS
      WHERE name = lv_gtnam.

    LOOP AT lt_gt INTO ls_gt.
      CLEAR ls_hit.
      ls_hit-include = ls_gt-include.
      CASE ls_gt-otype.
        WHEN 'TY'.   ls_hit-via = 'Type / DDIC reference'.
        WHEN 'ME'.   ls_hit-via = 'Method'.
        WHEN 'DA'.   ls_hit-via = 'Data'.
        WHEN OTHERS. ls_hit-via = ls_gt-otype.
      ENDCASE.
      APPEND ls_hit TO lt_hit.
    ENDLOOP.

*   CROSS - function modules, programs, transactions, FORM routines
    SELECT * FROM cross
      INTO TABLE lt_cr
      UP TO c_max_rows ROWS
      WHERE name = lv_crnam.

    LOOP AT lt_cr INTO ls_cr.
      CLEAR ls_hit.
      ls_hit-include = ls_cr-include.
      CASE ls_cr-type.
        WHEN 'F'.    ls_hit-via = 'Function module call'.
        WHEN 'P'.    ls_hit-via = 'Program'.
        WHEN 'R'.    ls_hit-via = 'Report'.
        WHEN 'T'.    ls_hit-via = 'Transaction'.
        WHEN 'U'.    ls_hit-via = 'FORM routine'.
        WHEN 'K'.    ls_hit-via = 'Class'.
        WHEN OTHERS. ls_hit-via = ls_cr-type.
      ENDCASE.
      APPEND ls_hit TO lt_hit.
    ENDLOOP.

    SORT lt_hit BY include via.
    DELETE ADJACENT DUPLICATES FROM lt_hit COMPARING include via.

    lo_out = zcl_ajson=>create_empty( ).
    lo_out->set( iv_path = '/object' iv_val = lv_up ).
    lo_out->touch_array( '/used_in' ).

    LOOP AT lt_hit INTO ls_hit.
      lv_idx = sy-tabix.
      lv_i = lv_idx.
      CONDENSE lv_i.

      CONCATENATE '/used_in/' lv_i '/include' INTO lv_path.
      lo_out->set( iv_path = lv_path iv_val = ls_hit-include ).

*     method includes look like ZCL_FOO=====CM001 - give the owning
*     object too, so the answer names something a human recognises
      FIND FIRST OCCURRENCE OF '=' IN ls_hit-include MATCH OFFSET lv_pos.
      IF sy-subrc = 0 AND lv_pos > 0.
        CONCATENATE '/used_in/' lv_i '/object' INTO lv_path.
        lo_out->set( iv_path = lv_path iv_val = ls_hit-include(lv_pos) ).
      ENDIF.

      CONCATENATE '/used_in/' lv_i '/via' INTO lv_path.
      lo_out->set( iv_path = lv_path iv_val = ls_hit-via ).
    ENDLOOP.

    lo_out->set_integer( iv_path = '/count' iv_val = lv_idx ).

    IF lv_idx = 0.
      lo_out->set( iv_path = '/note'
                   iv_val  = 'Nothing found in the cross-reference index. Recently created or never activated objects may not be indexed yet.' ).
    ENDIF.

    rv_json = lo_out->stringify( ).

  ENDMETHOD.


ENDCLASS.
