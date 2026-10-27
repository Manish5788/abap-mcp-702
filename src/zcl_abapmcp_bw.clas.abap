CLASS zcl_abapmcp_bw DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.
*--------------------------------------------------------------------*
* Title       : ZCL_ABAPMCP_BW - BW extractor (DataSource) MCP tools
* Type        : Class (MCP tool plug-in, read-only)
* Frequency   : On demand (called per MCP tools/call)
* Description : Three read-only tools on /sap/bc/mcp about the BW
*               extraction side of this ECC system:
*                 sap_bw_datasources       find DataSources
*                 sap_bw_datasource_info   explain one DataSource:
*                                          source (view tables + joins,
*                                          function module, LO), fields,
*                                          delta, BW systems, custom
*                                          exit code and BAdIs
*                 sap_bw_table_datasources which DataSources read a table
*               Metadata only - no business data, no extraction run.
*               Code itself is read with sap_get_source (custom only).
*--------------------------------------------------------------------*
*& Plug-in class, same contract as ZCL_ABAPMCP_CUST:
*&   ZCL_ABAPMCP_TOOLS=>GET_TOOL_DEFS splices GET_TOOL_DEFS_JSON into
*&   its catalogue, and ZCL_ABAPMCP_TOOLS=>EXECUTE hands a tool to
*&   EXECUTE here when HANDLES is true (after the ZCL_AI_AUTH gate and the
*&   TOOLS_DISABLED switch).
*&
*& NW 7.02 syntax only: no inline DATA( ), no VALUE #( ), no NEW.
*&---------------------------------------------------------------------*

*   Tool definitions in Anthropic Messages API shape, comma separated
*   and WITHOUT brackets, to splice into ZCL_ABAPMCP_TOOLS=>GET_TOOL_DEFS.
    CLASS-METHODS get_tool_defs_json
      RETURNING VALUE(ex_json) TYPE string.

*   True if im_name is one of this class's tools.
    CLASS-METHODS handles
      IMPORTING im_name       TYPE string
      RETURNING VALUE(ex_yes) TYPE abap_bool.

*   JSON arguments in, JSON result out, {"error":"..."} on failure.
    CLASS-METHODS execute
      IMPORTING im_name          TYPE string
                im_input         TYPE string
      RETURNING VALUE(ex_result) TYPE string.

*   One DataSource branch found in a customer exit include
*   ZXRSAU01-04. Public for ABAP Unit (PARSE_EXIT).
    TYPES: BEGIN OF t_exit_hit,
             datasource TYPE roosource-oltpsource,
             exit_incl  TYPE progname,
             include    TYPE progname,
             from_line  TYPE i,
             to_line    TYPE i,
           END OF t_exit_hit.
    TYPES: t_exit_hits TYPE STANDARD TABLE OF t_exit_hit WITH DEFAULT KEY.

*   DataSource branches of one exit include: IF i_datasource = '...'
*   and CASE i_datasource / WHEN '...'. INCLUDE statements inside a
*   branch become one hit each; other code inside a branch becomes one
*   hit with its line range (include = the exit include itself).
*   Public for ABAP Unit.
    CLASS-METHODS parse_exit
      IMPORTING im_exit_incl   TYPE progname
                im_source      TYPE string_table
      RETURNING VALUE(ex_hits) TYPE t_exit_hits.

  PROTECTED SECTION.

  PRIVATE SECTION.

    TYPES: BEGIN OF t_ds,
             oltpsource TYPE roosource-oltpsource,
             type       TYPE roosource-type,
             applnm     TYPE roosource-applnm,
             delta      TYPE roosource-delta,
             exmethod   TYPE roosource-exmethod,
             extractor  TYPE roosource-extractor,
             exstruct   TYPE roosource-exstruct,
             tstpnm     TYPE roosource-tstpnm,
             tstpdat    TYPE roosource-tstpdat,
           END OF t_ds.
    TYPES: t_dss TYPE STANDARD TABLE OF t_ds WITH DEFAULT KEY.

    TYPES: BEGIN OF t_domtext,
             domname TYPE domname,
             value   TYPE domvalue_l,
             text    TYPE string,
           END OF t_domtext.

    CONSTANTS: c_t_list  TYPE string VALUE 'sap_bw_datasources',
               c_t_info  TYPE string VALUE 'sap_bw_datasource_info',
               c_t_table TYPE string VALUE 'sap_bw_table_datasources',
               c_def_max TYPE i VALUE 50,
               c_max_max TYPE i VALUE 200,
               c_max_fld TYPE i VALUE 400,
               c_badi    TYPE exit_def VALUE 'RSU5_SAPI_BADI'.

    CLASS-DATA i_domtext TYPE HASHED TABLE OF t_domtext WITH UNIQUE KEY domname value.
    CLASS-DATA i_exits   TYPE t_exit_hits.
    CLASS-DATA v_exits_read TYPE abap_bool.

    CLASS-METHODS list_datasources
      IMPORTING im_input       TYPE string
      RETURNING VALUE(ex_json) TYPE string
      RAISING   zcx_ajson_error.

    CLASS-METHODS datasource_info
      IMPORTING im_input       TYPE string
      RETURNING VALUE(ex_json) TYPE string
      RAISING   zcx_ajson_error.

    CLASS-METHODS table_datasources
      IMPORTING im_input       TYPE string
      RETURNING VALUE(ex_json) TYPE string
      RAISING   zcx_ajson_error.

    CLASS-METHODS add_view
      IMPORTING im_out  TYPE REF TO zcl_ajson
                im_path TYPE string
                im_view TYPE string
      RAISING   zcx_ajson_error.

    CLASS-METHODS add_fields
      IMPORTING im_out    TYPE REF TO zcl_ajson
                im_ds     TYPE t_ds
      RAISING   zcx_ajson_error.

    CLASS-METHODS add_bw_systems
      IMPORTING im_out  TYPE REF TO zcl_ajson
                im_name TYPE roosource-oltpsource
      RAISING   zcx_ajson_error.

    CLASS-METHODS add_exit_code
      IMPORTING im_out  TYPE REF TO zcl_ajson
                im_name TYPE roosource-oltpsource
      CHANGING  ch_read TYPE string_table
      RAISING   zcx_ajson_error.

    CLASS-METHODS read_exits.

    CLASS-METHODS ds_text
      IMPORTING im_name        TYPE roosource-oltpsource
      RETURNING VALUE(ex_text) TYPE string.

    CLASS-METHODS domain_text
      IMPORTING im_rollname    TYPE rollname
                im_value       TYPE csequence
      RETURNING VALUE(ex_text) TYPE string.

    CLASS-METHODS method_text
      IMPORTING im_exmethod    TYPE roosource-exmethod
                im_extractor   TYPE roosource-extractor
      RETURNING VALUE(ex_text) TYPE string.

    CLASS-METHODS delta_text
      IMPORTING im_delta       TYPE roosource-delta
      RETURNING VALUE(ex_text) TYPE string.

    CLASS-METHODS fm_include
      IMPORTING im_funcname    TYPE csequence
      RETURNING VALUE(ex_incl) TYPE string.

    CLASS-METHODS own_logsys
      RETURNING VALUE(ex_logsys) TYPE logsys.

    CLASS-METHODS is_custom
      IMPORTING im_name       TYPE csequence
      RETURNING VALUE(ex_yes) TYPE abap_bool.

    CLASS-METHODS idx_path
      IMPORTING im_base        TYPE string
                im_index       TYPE i
                im_field       TYPE string
      RETURNING VALUE(ex_path) TYPE string.

    CLASS-METHODS error_json
      IMPORTING im_msg         TYPE string
      RETURNING VALUE(ex_json) TYPE string.

ENDCLASS.


CLASS zcl_abapmcp_bw IMPLEMENTATION.

  METHOD add_bw_systems.
*&---------------------------------------------------------------------*
*& BW systems the DataSource is replicated to (ROOSGEN: transfer
*& structure generated) and its delta init / delta status per BW system
*& from this system's client (ROOSPRMSC).
*&---------------------------------------------------------------------*

    DATA li_gen   TYPE STANDARD TABLE OF roosgen.
    DATA lw_gen   TYPE roosgen.
    DATA li_prm   TYPE STANDARD TABLE OF roosprmsc.
    DATA lw_prm   TYPE roosprmsc.
    DATA lv_own   TYPE logsys.
    DATA lv_i     TYPE i.
    DATA lv_path  TYPE string.
    DATA lv_val   TYPE string.
    DATA lv_ts    TYPE c LENGTH 15.

    lv_own = own_logsys( ).
    lv_val = lv_own.
    im_out->set( iv_path = '/bw/this_system' iv_val = lv_val ).

    SELECT * FROM roosgen INTO TABLE li_gen WHERE oltpsource = im_name.
    im_out->touch_array( '/bw/replicated_to' ).
    LOOP AT li_gen INTO lw_gen.
      lv_i = lv_i + 1.
      lv_path = idx_path( im_base = '/bw/replicated_to/' im_index = lv_i im_field = 'bw_system' ).
      lv_val = lw_gen-rlogsys.
      im_out->set( iv_path = lv_path iv_val = lv_val ).
      lv_path = idx_path( im_base = '/bw/replicated_to/' im_index = lv_i im_field = 'source_client_system' ).
      lv_val = lw_gen-slogsys.
      im_out->set( iv_path = lv_path iv_val = lv_val ).
      IF lw_gen-tstpdat IS NOT INITIAL.
        lv_path = idx_path( im_base = '/bw/replicated_to/' im_index = lv_i im_field = 'generated_on' ).
        CONCATENATE lw_gen-tstpdat(4) '-' lw_gen-tstpdat+4(2) '-' lw_gen-tstpdat+6(2) INTO lv_val.
        im_out->set( iv_path = lv_path iv_val = lv_val ).
      ENDIF.
    ENDLOOP.

    SELECT * FROM roosprmsc INTO TABLE li_prm WHERE oltpsource = im_name.
    im_out->touch_array( '/bw/delta_channels' ).
    lv_i = 0.
    LOOP AT li_prm INTO lw_prm.
      lv_i = lv_i + 1.
      lv_path = idx_path( im_base = '/bw/delta_channels/' im_index = lv_i im_field = 'bw_system' ).
      lv_val = lw_prm-rlogsys.
      IF lv_val = '$ODQ_DUMMY'.
        lv_val = 'ODP / operational delta queue (ODQMON)'.
      ENDIF.
      im_out->set( iv_path = lv_path iv_val = lv_val ).
      lv_path = idx_path( im_base = '/bw/delta_channels/' im_index = lv_i im_field = 'source_client_system' ).
      lv_val = lw_prm-slogsys.
      im_out->set( iv_path = lv_path iv_val = lv_val ).
      lv_path = idx_path( im_base = '/bw/delta_channels/' im_index = lv_i im_field = 'this_client' ).
      IF lw_prm-slogsys = lv_own.
        im_out->set_boolean( iv_path = lv_path iv_val = abap_true ).
      ELSE.
        im_out->set_boolean( iv_path = lv_path iv_val = abap_false ).
      ENDIF.
      lv_path = idx_path( im_base = '/bw/delta_channels/' im_index = lv_i im_field = 'init_done' ).
      IF lw_prm-initstate = 'X'.
        im_out->set_boolean( iv_path = lv_path iv_val = abap_true ).
      ELSE.
        im_out->set_boolean( iv_path = lv_path iv_val = abap_false ).
      ENDIF.
      lv_path = idx_path( im_base = '/bw/delta_channels/' im_index = lv_i im_field = 'delta_requested' ).
      IF lw_prm-deltarnr IS NOT INITIAL.
        im_out->set_boolean( iv_path = lv_path iv_val = abap_true ).
      ELSE.
        im_out->set_boolean( iv_path = lv_path iv_val = abap_false ).
      ENDIF.
      IF lw_prm-timestamp IS NOT INITIAL.
        lv_ts = lw_prm-timestamp.
        CONDENSE lv_ts NO-GAPS.
        lv_path = idx_path( im_base = '/bw/delta_channels/' im_index = lv_i im_field = 'last_change_utc' ).
        CONCATENATE lv_ts(4) '-' lv_ts+4(2) '-' lv_ts+6(2) ' ' lv_ts+8(2) ':' lv_ts+10(2)
               INTO lv_val RESPECTING BLANKS.
        im_out->set( iv_path = lv_path iv_val = lv_val ).
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD add_exit_code.
*&---------------------------------------------------------------------*
*& Custom code that changes the DataSource: its branches in the customer
*& exit includes ZXRSAU01-04 (enhancement RSAP0001) and the
*& implementations of BAdI RSU5_SAPI_BADI, with whether their code names
*& this DataSource. Every custom object found is added to ch_read.
*&---------------------------------------------------------------------*

    TYPES: BEGIN OF lt_imp,
             imp_name  TYPE sxc_exit-imp_name,
             imp_class TYPE sxc_class-imp_class,
             active    TYPE sxc_attr-active,
           END OF lt_imp.

    DATA lw_hit   TYPE t_exit_hit.
    DATA lv_i     TYPE i.
    DATA lv_path  TYPE string.
    DATA lv_val   TYPE string.
    DATA li_imp   TYPE STANDARD TABLE OF lt_imp.
    DATA lw_imp   TYPE lt_imp.
    DATA li_meth  TYPE seop_methods_w_include.
    DATA lw_meth  LIKE LINE OF li_meth.
    DATA lv_cls   TYPE seoclsname.
    DATA li_src   TYPE string_table.
    DATA lv_line  TYPE string.
    DATA lv_lit   TYPE string.
    DATA lv_found TYPE abap_bool.

    read_exits( ).
    im_out->touch_array( '/custom_code/exit_branches' ).
    LOOP AT i_exits INTO lw_hit WHERE datasource = im_name.
      lv_i = lv_i + 1.
      lv_path = idx_path( im_base = '/custom_code/exit_branches/' im_index = lv_i im_field = 'exit_include' ).
      lv_val = lw_hit-exit_incl.
      im_out->set( iv_path = lv_path iv_val = lv_val ).
      lv_path = idx_path( im_base = '/custom_code/exit_branches/' im_index = lv_i im_field = 'exit' ).
      CASE lw_hit-exit_incl.
        WHEN 'ZXRSAU01'.
          lv_val = 'EXIT_SAPLRSAP_001 - transaction data'.
        WHEN 'ZXRSAU02'.
          lv_val = 'EXIT_SAPLRSAP_002 - master data attributes'.
        WHEN 'ZXRSAU03'.
          lv_val = 'EXIT_SAPLRSAP_003 - texts'.
        WHEN OTHERS.
          lv_val = 'EXIT_SAPLRSAP_004 - hierarchies'.
      ENDCASE.
      im_out->set( iv_path = lv_path iv_val = lv_val ).
      lv_path = idx_path( im_base = '/custom_code/exit_branches/' im_index = lv_i im_field = 'code_in' ).
      lv_val = lw_hit-include.
      im_out->set( iv_path = lv_path iv_val = lv_val ).
      IF lw_hit-include = lw_hit-exit_incl.
        lv_path = idx_path( im_base = '/custom_code/exit_branches/' im_index = lv_i im_field = 'lines' ).
        lv_val = lw_hit-from_line.
        lv_line = lw_hit-to_line.
        CONCATENATE lv_val '-' lv_line INTO lv_val.
        CONDENSE lv_val NO-GAPS.
        im_out->set( iv_path = lv_path iv_val = lv_val ).
      ENDIF.
      lv_val = lw_hit-include.
      APPEND lv_val TO ch_read.
    ENDLOOP.

*   BAdI RSU5_SAPI_BADI: runs for every DataSource; an implementation
*   is relevant when its code names this DataSource
    SELECT e~imp_name c~imp_class a~active
      FROM sxc_exit AS e
      INNER JOIN sxc_attr AS a ON a~imp_name = e~imp_name
      LEFT OUTER JOIN sxc_class AS c ON c~imp_name = e~imp_name
      INTO TABLE li_imp
      WHERE e~exit_name = c_badi.
    SORT li_imp BY imp_name.
    DELETE ADJACENT DUPLICATES FROM li_imp COMPARING imp_name.

    CONCATENATE '''' im_name '''' INTO lv_lit.
    TRANSLATE lv_lit TO UPPER CASE.
    im_out->touch_array( '/custom_code/badi_rsu5_sapi_badi' ).
    lv_i = 0.
    LOOP AT li_imp INTO lw_imp.
      lv_i = lv_i + 1.
      lv_path = idx_path( im_base = '/custom_code/badi_rsu5_sapi_badi/' im_index = lv_i im_field = 'implementation' ).
      lv_val = lw_imp-imp_name.
      im_out->set( iv_path = lv_path iv_val = lv_val ).
      lv_path = idx_path( im_base = '/custom_code/badi_rsu5_sapi_badi/' im_index = lv_i im_field = 'class' ).
      lv_val = lw_imp-imp_class.
      im_out->set( iv_path = lv_path iv_val = lv_val ).
      lv_path = idx_path( im_base = '/custom_code/badi_rsu5_sapi_badi/' im_index = lv_i im_field = 'custom' ).
      lv_found = is_custom( lw_imp-imp_name ).
      im_out->set_boolean( iv_path = lv_path iv_val = lv_found ).
      lv_path = idx_path( im_base = '/custom_code/badi_rsu5_sapi_badi/' im_index = lv_i im_field = 'active' ).
      IF lw_imp-active = 'X'.
        im_out->set_boolean( iv_path = lv_path iv_val = abap_true ).
      ELSE.
        im_out->set_boolean( iv_path = lv_path iv_val = abap_false ).
      ENDIF.
      lv_found = abap_false.
      IF lw_imp-imp_class IS NOT INITIAL AND is_custom( lw_imp-imp_class ) = abap_true.
        lv_cls = lw_imp-imp_class.
        TRY.
            li_meth = cl_oo_classname_service=>get_all_method_includes( lv_cls ).
          CATCH cx_root.                                  "#EC NO_HANDLER
            CLEAR li_meth.
        ENDTRY.
        LOOP AT li_meth INTO lw_meth.
          CLEAR li_src.
          READ REPORT lw_meth-incname INTO li_src.
          LOOP AT li_src INTO lv_line.
            TRANSLATE lv_line TO UPPER CASE.
            IF lv_line CS lv_lit.
              lv_found = abap_true.
              EXIT.
            ENDIF.
          ENDLOOP.
          IF lv_found = abap_true.
            lv_val = lw_meth-incname.
            APPEND lv_val TO ch_read.
            EXIT.
          ENDIF.
        ENDLOOP.
      ENDIF.
      lv_path = idx_path( im_base = '/custom_code/badi_rsu5_sapi_badi/' im_index = lv_i im_field = 'names_this_datasource' ).
      im_out->set_boolean( iv_path = lv_path iv_val = lv_found ).
    ENDLOOP.

  ENDMETHOD.


  METHOD add_fields.
*&---------------------------------------------------------------------*
*& Fields of the extract structure with description and data type, plus
*& the DataSource field settings of ROOSFIELD: selectable, hidden, filled
*& only in the customer exit. Fields named ZZ* / YY* are customer
*& appends.
*&---------------------------------------------------------------------*

    TYPES: BEGIN OF lt_flag,
             field     TYPE roosfield-field,
             selection TYPE roosfield-selection,
             storno    TYPE roosfield-storno,
           END OF lt_flag.

    DATA lv_name  TYPE ddobjname.
    DATA li_dd03  TYPE STANDARD TABLE OF dd03p.
    DATA lw_dd03  TYPE dd03p.
    DATA li_flag  TYPE HASHED TABLE OF lt_flag WITH UNIQUE KEY field.
    DATA lw_flag  TYPE lt_flag.
    DATA lv_i     TYPE i.
    DATA lv_path  TYPE string.
    DATA lv_val   TYPE string.
    DATA lv_leng  TYPE string.
    DATA lv_nappl TYPE i.

    IF im_ds-exstruct IS INITIAL.
      RETURN.
    ENDIF.
    lv_name = im_ds-exstruct.
    CALL FUNCTION 'DDIF_TABL_GET'
      EXPORTING
        name          = lv_name
        langu         = sy-langu
      TABLES
        dd03p_tab     = li_dd03
      EXCEPTIONS
        illegal_input = 1
        OTHERS        = 2.
    IF sy-subrc <> 0 OR li_dd03 IS INITIAL.
      im_out->set( iv_path = '/fields_note' iv_val = 'Extract structure could not be read.' ).
      RETURN.
    ENDIF.

    SELECT field selection storno FROM roosfield INTO TABLE li_flag
      WHERE oltpsource = im_ds-oltpsource
        AND objvers    = 'A'.

    im_out->touch_array( '/fields' ).
    LOOP AT li_dd03 INTO lw_dd03.
      IF lw_dd03-fieldname(1) = '.'.
        CONTINUE.
      ENDIF.
      lv_i = lv_i + 1.
      IF lv_i > c_max_fld.
        im_out->set( iv_path = '/fields_note' iv_val = 'Field list cut at 400 fields.' ).
        EXIT.
      ENDIF.
      lv_path = idx_path( im_base = '/fields/' im_index = lv_i im_field = 'field' ).
      lv_val = lw_dd03-fieldname.
      im_out->set( iv_path = lv_path iv_val = lv_val ).
      lv_path = idx_path( im_base = '/fields/' im_index = lv_i im_field = 'text' ).
      lv_val = lw_dd03-ddtext.
      im_out->set( iv_path = lv_path iv_val = lv_val ).
      lv_path = idx_path( im_base = '/fields/' im_index = lv_i im_field = 'type' ).
      lv_leng = lw_dd03-leng.
      SHIFT lv_leng LEFT DELETING LEADING '0'.
      CONCATENATE lw_dd03-datatype lv_leng INTO lv_val SEPARATED BY space.
      im_out->set( iv_path = lv_path iv_val = lv_val ).
      READ TABLE li_flag INTO lw_flag WITH TABLE KEY field = lw_dd03-fieldname.
      IF sy-subrc = 0 AND lw_flag-selection IS NOT INITIAL.
        lv_path = idx_path( im_base = '/fields/' im_index = lv_i im_field = 'setting' ).
        lv_val = domain_text( im_rollname = 'ROSELEC' im_value = lw_flag-selection ).
        IF lv_val IS INITIAL.
          lv_val = lw_flag-selection.
        ENDIF.
        im_out->set( iv_path = lv_path iv_val = lv_val ).
      ENDIF.
      IF sy-subrc = 0 AND lw_flag-storno = 'X'.
        lv_path = idx_path( im_base = '/fields/' im_index = lv_i im_field = 'inverted_on_cancel' ).
        im_out->set_boolean( iv_path = lv_path iv_val = abap_true ).
      ENDIF.
      IF lw_dd03-fieldname(2) = 'ZZ' OR lw_dd03-fieldname(2) = 'YY'.
        lv_path = idx_path( im_base = '/fields/' im_index = lv_i im_field = 'customer_append' ).
        im_out->set_boolean( iv_path = lv_path iv_val = abap_true ).
        lv_nappl = lv_nappl + 1.
      ENDIF.
    ENDLOOP.
    im_out->set_integer( iv_path = '/field_count' iv_val = lv_i ).
    im_out->set_integer( iv_path = '/customer_append_fields' iv_val = lv_nappl ).

  ENDMETHOD.


  METHOD add_view.
*&---------------------------------------------------------------------*
*& Base tables, join conditions and selection conditions of a DDIC view
*& (DDIF_VIEW_GET), under im_path.
*&---------------------------------------------------------------------*

    DATA lv_name  TYPE ddobjname.
    DATA lw_dd25  TYPE dd25v.
    DATA li_dd26  TYPE STANDARD TABLE OF dd26v.
    DATA lw_dd26  TYPE dd26v.
    DATA li_dd27  TYPE STANDARD TABLE OF dd27p.
    DATA li_dd28j TYPE STANDARD TABLE OF dd28j.
    DATA lw_dd28j TYPE dd28j.
    DATA li_dd28v TYPE STANDARD TABLE OF dd28v.
    DATA lw_dd28v TYPE dd28v.
    DATA lv_i     TYPE i.
    DATA lv_path  TYPE string.
    DATA lv_base  TYPE string.
    DATA lv_right TYPE string.
    DATA lv_val   TYPE string.

    lv_name = im_view.
    CALL FUNCTION 'DDIF_VIEW_GET'
      EXPORTING
        name          = lv_name
        state         = 'A'
        langu         = sy-langu
      IMPORTING
        dd25v_wa      = lw_dd25
      TABLES
        dd26v_tab     = li_dd26
        dd27p_tab     = li_dd27
        dd28j_tab     = li_dd28j
        dd28v_tab     = li_dd28v
      EXCEPTIONS
        illegal_input = 1
        OTHERS        = 2.
    IF sy-subrc <> 0.
      CONCATENATE im_path '/note' INTO lv_path.
      lv_val = 'View definition could not be read.'.
      im_out->set( iv_path = lv_path iv_val = lv_val ).
      RETURN.
    ENDIF.

    CONCATENATE im_path '/name' INTO lv_path.
    im_out->set( iv_path = lv_path iv_val = im_view ).
    CONCATENATE im_path '/description' INTO lv_path.
    lv_val = lw_dd25-ddtext.
    im_out->set( iv_path = lv_path iv_val = lv_val ).

    CONCATENATE im_path '/base_tables' INTO lv_path.
    im_out->touch_array( lv_path ).
    CONCATENATE im_path '/base_tables/' INTO lv_base.
    LOOP AT li_dd26 INTO lw_dd26.
      lv_i = sy-tabix.
      lv_path = idx_path( im_base = lv_base im_index = lv_i im_field = '' ).
      lv_val = lw_dd26-tabname.
      im_out->set( iv_path = lv_path iv_val = lv_val ).
    ENDLOOP.

    CONCATENATE im_path '/joins' INTO lv_path.
    im_out->touch_array( lv_path ).
    CONCATENATE im_path '/joins/' INTO lv_base.
    LOOP AT li_dd28j INTO lw_dd28j.
      lv_i = sy-tabix.
      lv_path = idx_path( im_base = lv_base im_index = lv_i im_field = '' ).
      CONCATENATE lw_dd28j-ltab '-' lw_dd28j-lfield INTO lv_val.
      CONCATENATE lw_dd28j-rtab '-' lw_dd28j-rfield INTO lv_right.
      CONCATENATE lv_val lw_dd28j-operator lv_right INTO lv_val SEPARATED BY space.
      im_out->set( iv_path = lv_path iv_val = lv_val ).
    ENDLOOP.

    CONCATENATE im_path '/selection_conditions' INTO lv_path.
    im_out->touch_array( lv_path ).
    CONCATENATE im_path '/selection_conditions/' INTO lv_base.
    LOOP AT li_dd28v INTO lw_dd28v.
      lv_i = sy-tabix.
      lv_path = idx_path( im_base = lv_base im_index = lv_i im_field = '' ).
      CONCATENATE lw_dd28v-tabname '-' lw_dd28v-fieldname INTO lv_val.
      CONCATENATE lv_val lw_dd28v-negation lw_dd28v-operator lw_dd28v-constants lw_dd28v-and_or
             INTO lv_val SEPARATED BY space.
      CONDENSE lv_val.
      im_out->set( iv_path = lv_path iv_val = lv_val ).
    ENDLOOP.

  ENDMETHOD.


  METHOD datasource_info.
*&---------------------------------------------------------------------*
*& One DataSource: header, source of the data, fields, delta, BW
*& systems, custom exit code and BAdIs, and which custom objects to read
*& next. Uses the active version; a DataSource only delivered (version
*& D) is described from that version with a note.
*&---------------------------------------------------------------------*

    DATA lo_in    TYPE REF TO zif_ajson.
    DATA lo_out   TYPE REF TO zcl_ajson.
    DATA lv_name  TYPE string.
    DATA lv_ds    TYPE roosource-oltpsource.
    DATA lw_src   TYPE roosource.
    DATA lw_ds    TYPE t_ds.
    DATA lv_vers  TYPE roosource-objvers.
    DATA lv_val   TYPE string.
    DATA lv_fld   TYPE abap_bool.
    DATA lv_view  TYPE dd25l-viewname.
    DATA lw_lo    TYPE tmcexact.
    DATA lv_incl  TYPE string.
    DATA li_read  TYPE string_table.
    DATA lv_i     TYPE i.
    DATA lv_path  TYPE string.
    DATA lv_yes   TYPE abap_bool.

    lo_in = zcl_ajson=>parse( im_input ).
    lv_name = lo_in->get( '/name' ).
    CONDENSE lv_name NO-GAPS.
    TRANSLATE lv_name TO UPPER CASE.
    IF lv_name IS INITIAL.
      ex_json = error_json( 'Give a DataSource name, e.g. 2LIS_11_VAITM.' ).
      RETURN.
    ENDIF.
    lv_fld = abap_true.
    IF lo_in->exists( '/fields' ) = abap_true.
      lv_fld = lo_in->get_boolean( '/fields' ).
    ENDIF.
    lv_ds = lv_name.

    lv_vers = 'A'.
    SELECT SINGLE * FROM roosource INTO lw_src WHERE oltpsource = lv_ds AND objvers = 'A'.
    IF sy-subrc <> 0.
      lv_vers = 'D'.
      SELECT SINGLE * FROM roosource INTO lw_src WHERE oltpsource = lv_ds AND objvers = 'D'.
      IF sy-subrc <> 0.
        CONCATENATE 'DataSource' lv_name 'does not exist in this system. Use sap_bw_datasources to search.'
               INTO lv_val SEPARATED BY space.
        ex_json = error_json( lv_val ).
        RETURN.
      ENDIF.
    ENDIF.
    MOVE-CORRESPONDING lw_src TO lw_ds.

    lo_out = zcl_ajson=>create_empty( ).
    lo_out->set( iv_path = '/name' iv_val = lv_name ).
    lv_val = ds_text( lv_ds ).
    lo_out->set( iv_path = '/description' iv_val = lv_val ).
    lv_val = domain_text( im_rollname = 'ROOSTYPE' im_value = lw_src-type ).
    lo_out->set( iv_path = '/type' iv_val = lv_val ).
    lv_val = lw_src-applnm.
    lo_out->set( iv_path = '/application' iv_val = lv_val ).
    lv_yes = is_custom( lv_ds ).
    lo_out->set_boolean( iv_path = '/custom' iv_val = lv_yes ).
    IF lv_vers = 'D'.
      lo_out->set( iv_path = '/status' iv_val = 'Delivered by SAP (content version D) but NOT activated in this system (RSA5) - not extracted to BW.' ).
    ELSE.
      lo_out->set( iv_path = '/status' iv_val = 'Active (RSA6).' ).
    ENDIF.
    IF lw_src-tstpdat IS NOT INITIAL.
      CONCATENATE lw_src-tstpdat(4) '-' lw_src-tstpdat+4(2) '-' lw_src-tstpdat+6(2) INTO lv_val.
      lo_out->set( iv_path = '/last_changed/on' iv_val = lv_val ).
      lv_val = lw_src-tstpnm.
      lo_out->set( iv_path = '/last_changed/by' iv_val = lv_val ).
    ENDIF.

*   ---- where the data comes from -------------------------------------
    lv_val = method_text( im_exmethod = lw_src-exmethod im_extractor = lw_src-extractor ).
    lo_out->set( iv_path = '/source/method' iv_val = lv_val ).
    lv_val = lw_src-extractor.
    lo_out->set( iv_path = '/source/extractor' iv_val = lv_val ).
    lv_val = lw_src-exstruct.
    lo_out->set( iv_path = '/source/extract_structure' iv_val = lv_val ).

    IF lw_src-exmethod = 'V'.
      lv_view = lw_src-extractor.
      SELECT SINGLE viewname FROM dd25l INTO lv_view WHERE viewname = lv_view AND as4local = 'A'.
      IF sy-subrc = 0.
        lv_val = lv_view.
        add_view( im_out = lo_out im_path = '/source/view' im_view = lv_val ).
      ELSE.
        lo_out->set( iv_path = '/source/note' iv_val = 'Extracts directly from this table (no view).' ).
      ENDIF.
    ELSEIF lw_src-exmethod(1) = 'F'.
      lv_incl = fm_include( lw_src-extractor ).
      IF lv_incl IS NOT INITIAL.
        lo_out->set( iv_path = '/source/function_include' iv_val = lv_incl ).
      ENDIF.
      IF is_custom( lw_src-extractor ) = abap_true AND lv_incl IS NOT INITIAL.
        APPEND lv_incl TO li_read.
        lo_out->set( iv_path = '/source/note' iv_val = 'Custom function module: read its code with sap_get_source on the function include.' ).
      ELSE.
        lo_out->set( iv_path = '/source/note' iv_val = 'SAP standard extractor: its source is not readable through these tools; describe it from metadata and general SAP knowledge, and say so.' ).
      ENDIF.
    ENDIF.

*   LO cockpit (logistics DataSources)
    SELECT SINGLE * FROM tmcexact INTO lw_lo WHERE isource = lv_ds.
    IF sy-subrc = 0.
      lv_val = lw_lo-mcapp.
      lo_out->set( iv_path = '/lo_cockpit/application' iv_val = lv_val ).
      lv_val = lw_lo-estruc.
      lo_out->set( iv_path = '/lo_cockpit/extract_structure' iv_val = lv_val ).
      IF lw_lo-updact = 'X'.
        lo_out->set( iv_path = '/lo_cockpit/update' iv_val = 'active - postings fill the extraction queue / delta (LBWE)' ).
      ELSE.
        lo_out->set( iv_path = '/lo_cockpit/update' iv_val = 'not active - no delta postings (LBWE)' ).
      ENDIF.
    ENDIF.

*   ---- delta ----------------------------------------------------------
    lv_val = lw_src-delta.
    lo_out->set( iv_path = '/delta/process' iv_val = lv_val ).
    lv_val = delta_text( lw_src-delta ).
    lo_out->set( iv_path = '/delta/meaning' iv_val = lv_val ).
    IF lw_src-gendeltafd IS NOT INITIAL.
      lv_val = lw_src-gendeltafd.
      lo_out->set( iv_path = '/delta/generic_field' iv_val = lv_val ).
      lv_val = domain_text( im_rollname = 'RSGENDLTTP' im_value = lw_src-gendeltatp ).
      lo_out->set( iv_path = '/delta/generic_type' iv_val = lv_val ).
      lv_val = lw_src-deltasafe1.
      CONDENSE lv_val.
      lo_out->set( iv_path = '/delta/safety_lower' iv_val = lv_val ).
      lv_val = lw_src-deltasafe2.
      CONDENSE lv_val.
      lo_out->set( iv_path = '/delta/safety_upper' iv_val = lv_val ).
    ENDIF.

*   ---- BW systems, fields, custom code --------------------------------
    add_bw_systems( im_out = lo_out im_name = lv_ds ).
    IF lv_fld = abap_true.
      add_fields( im_out = lo_out im_ds = lw_ds ).
    ENDIF.
    add_exit_code( EXPORTING im_out = lo_out im_name = lv_ds CHANGING ch_read = li_read ).

    SORT li_read.
    DELETE ADJACENT DUPLICATES FROM li_read.
    lo_out->touch_array( '/read_next' ).
    LOOP AT li_read INTO lv_val.
      lv_i = sy-tabix.
      lv_path = idx_path( im_base = '/read_next/' im_index = lv_i im_field = '' ).
      lo_out->set( iv_path = lv_path iv_val = lv_val ).
    ENDLOOP.

    lo_out->set( iv_path = '/note' iv_val = 'Metadata of this ECC source system only - no data, no extraction run. Read the objects in read_next with sap_get_source to explain the custom logic.' ).

    ex_json = lo_out->stringify( ).

  ENDMETHOD.


  METHOD delta_text.
*&---------------------------------------------------------------------*
*& Delta process in words (RODELTAMT), plus a plain-English gloss of
*& the common processes.
*&---------------------------------------------------------------------*

    DATA lv_txt TYPE rodeltamt-txtlg.

    IF im_delta IS INITIAL.
      ex_text = 'No delta - full upload only.'.
      RETURN.
    ENDIF.
    SELECT SINGLE txtlg FROM rodeltamt INTO lv_txt
      WHERE langu = 'E' AND delta = im_delta.
    ex_text = lv_txt.
    CASE im_delta.
      WHEN 'ABR'.
        CONCATENATE ex_text '- each change sends the after image, the before image (reversed) and deletions; works with cubes and DSOs.'
               INTO ex_text SEPARATED BY space.
      WHEN 'AIE' OR 'AIM' OR 'AIMD'.
        CONCATENATE ex_text '- after images only: needs a DSO with overwrite in BW.'
               INTO ex_text SEPARATED BY space.
      WHEN 'ADD' OR 'ADDD'.
        CONCATENATE ex_text '- additive deltas: values are added up in BW.'
               INTO ex_text SEPARATED BY space.
      WHEN 'E'.
        CONCATENATE ex_text '- delta determined by the extractor itself (e.g. a timestamp or counter).'
               INTO ex_text SEPARATED BY space.
    ENDCASE.
    CONDENSE ex_text.

  ENDMETHOD.


  METHOD domain_text.
*&---------------------------------------------------------------------*
*& English fixed-value text of the domain behind a data element, cached.
*& Empty when the domain has no text for the value.
*&---------------------------------------------------------------------*

    DATA lw_dt  TYPE t_domtext.
    DATA lv_dom TYPE domname.
    DATA lv_txt TYPE dd07t-ddtext.

    SELECT SINGLE domname FROM dd04l INTO lv_dom
      WHERE rollname = im_rollname AND as4local = 'A'.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.
    lw_dt-domname = lv_dom.
    lw_dt-value   = im_value.
    READ TABLE i_domtext INTO lw_dt WITH TABLE KEY domname = lw_dt-domname value = lw_dt-value.
    IF sy-subrc = 0.
      ex_text = lw_dt-text.
      RETURN.
    ENDIF.
    SELECT SINGLE ddtext FROM dd07t INTO lv_txt
      WHERE domname    = lv_dom
        AND ddlanguage = 'E'
        AND as4local   = 'A'
        AND domvalue_l = lw_dt-value.
    lw_dt-text = lv_txt.
    INSERT lw_dt INTO TABLE i_domtext.
    ex_text = lw_dt-text.

  ENDMETHOD.


  METHOD ds_text.
*&---------------------------------------------------------------------*
*& Longest available English (else logon language) description.
*&---------------------------------------------------------------------*

    DATA lw_t TYPE roosourcet.

    SELECT SINGLE * FROM roosourcet INTO lw_t
      WHERE langu = 'E' AND oltpsource = im_name AND objvers = 'A'.
    IF sy-subrc <> 0.
      SELECT SINGLE * FROM roosourcet INTO lw_t
        WHERE langu = 'E' AND oltpsource = im_name AND objvers = 'D'.
    ENDIF.
    IF sy-subrc <> 0.
      SELECT SINGLE * FROM roosourcet INTO lw_t
        WHERE langu = sy-langu AND oltpsource = im_name.
    ENDIF.
    IF lw_t-txtlg IS NOT INITIAL.
      ex_text = lw_t-txtlg.
    ELSEIF lw_t-txtmd IS NOT INITIAL.
      ex_text = lw_t-txtmd.
    ELSE.
      ex_text = lw_t-txtsh.
    ENDIF.

  ENDMETHOD.


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
*& Route the call. A failure is a normal result carrying an error text
*& the model can act on, never an exception to the server.
*&---------------------------------------------------------------------*

    DATA lx_root TYPE REF TO cx_root.
    DATA lv_msg  TYPE string.

    TRY.
        CASE im_name.
          WHEN c_t_list.
            ex_result = list_datasources( im_input ).
          WHEN c_t_info.
            ex_result = datasource_info( im_input ).
          WHEN c_t_table.
            ex_result = table_datasources( im_input ).
          WHEN OTHERS.
            CONCATENATE 'Unknown tool:' im_name INTO lv_msg SEPARATED BY space.
            ex_result = error_json( lv_msg ).
        ENDCASE.
      CATCH cx_root INTO lx_root.
        lv_msg = lx_root->get_text( ).
        ex_result = error_json( lv_msg ).
    ENDTRY.

  ENDMETHOD.


  METHOD fm_include.
*&---------------------------------------------------------------------*
*& Main include of a function module: SAPL<group> + number -> L<group>U<nn>.
*&---------------------------------------------------------------------*

    DATA lv_fm   TYPE tfdir-funcname.
    DATA lw_tf   TYPE tfdir.
    DATA lv_grp  TYPE string.
    DATA lv_ns   TYPE string.
    DATA lv_off  TYPE i.

    lv_fm = im_funcname.
    SELECT SINGLE * FROM tfdir INTO lw_tf WHERE funcname = lv_fm.
    IF sy-subrc <> 0 OR lw_tf-pname(4) <> 'SAPL'.
      RETURN.
    ENDIF.
    lv_grp = lw_tf-pname+4.
*   namespaced group /ABC/XYZ: the L goes after the namespace
    IF lv_grp(1) = '/'.
      FIND FIRST OCCURRENCE OF '/' IN lv_grp+1 MATCH OFFSET lv_off.
      lv_off = lv_off + 2.
      lv_ns  = lv_grp(lv_off).
      lv_grp = lv_grp+lv_off.
      CONCATENATE lv_ns 'L' lv_grp 'U' lw_tf-include INTO ex_incl.
    ELSE.
      CONCATENATE 'L' lv_grp 'U' lw_tf-include INTO ex_incl.
    ENDIF.

  ENDMETHOD.


  METHOD get_tool_defs_json.
*&---------------------------------------------------------------------*
*& Tool catalogue entries: what each returns and when to use it.
*& 23.10.2026: shortened - tools/list was over the 6k token budget.
*&---------------------------------------------------------------------*

    CONCATENATE
      `{"name":"sap_bw_datasources",`
      ` "description":"Find BW DataSources (extractors) of this ECC system, SAP (2LIS_11_VAITM, 0FI_GL_4) `
      `or custom: name, text, type, application component, extraction method, delta process and the BW `
      `systems it is replicated to. Then use sap_bw_datasource_info for one of them.",`
      ` "input_schema":{"type":"object","properties":{`
      `   "pattern":{"type":"string","description":"Name pattern with *, e.g. 2LIS_11*. Default *."},`
      `   "text":{"type":"string","description":"Word in the description, e.g. sales."},`
      `   "application":{"type":"string","description":"Application component, e.g. SD, FI-GL."},`
      `   "type":{"type":"string","description":"TRAN, ATTR, TEXT or HIER."},`
      `   "custom_only":{"type":"boolean","description":"Only Z/Y. Default false."},`
      `   "delta_only":{"type":"boolean","description":"Only delta-capable. Default false."},`
      `   "bw_system":{"type":"string","description":"Replicated to this logical system, e.g. BW2CLNT001."},`
      `   "max_results":{"type":"integer","description":"1-200, default 50."}},`
      `   "required":[]}},`
      `{"name":"sap_bw_datasource_info",`
      ` "description":"Explain one BW DataSource: type; data source (view base tables and joins, function `
      `module, or LO extract structure and status); fields with selectable/hidden/exit-only flags; delta `
      `process; BW systems and delta init; and custom code changing it - the ZXRSAU01-04 branch and `
      `RSU5_SAPI_BADI implementations (read them with sap_get_source; SAP extractor source is not readable).",`
      ` "input_schema":{"type":"object","properties":{`
      `   "name":{"type":"string","description":"DataSource, e.g. 2LIS_11_VAITM."},`
      `   "fields":{"type":"boolean","description":"Include the field list. Default true."}},`
      `   "required":["name"]}},`
      `{"name":"sap_bw_table_datasources",`
      ` "description":"Which BW DataSources read a table: view/table DataSources on it, custom function `
      `module extractors and customer-exit code using it. For impact questions (if table ZXYZ changes, `
      `which extractors are affected?).",`
      ` "input_schema":{"type":"object","properties":{`
      `   "table":{"type":"string","description":"Table name, e.g. VBAP."}},`
      `   "required":["table"]}}`
      INTO ex_json.

  ENDMETHOD.


  METHOD handles.
*&---------------------------------------------------------------------*

    IF im_name = c_t_list OR im_name = c_t_info OR im_name = c_t_table.
      ex_yes = abap_true.
    ENDIF.

  ENDMETHOD.


  METHOD idx_path.
*&---------------------------------------------------------------------*
*& /base/<index>/field (or /base/<index> when field is empty).
*&---------------------------------------------------------------------*

    DATA lv_i TYPE string.

    lv_i = im_index.
    CONDENSE lv_i.
    IF im_field IS INITIAL.
      CONCATENATE im_base lv_i INTO ex_path.
    ELSE.
      CONCATENATE im_base lv_i '/' im_field INTO ex_path.
    ENDIF.

  ENDMETHOD.


  METHOD is_custom.
*&---------------------------------------------------------------------*
*& Z or Y name (custom namespace).
*&---------------------------------------------------------------------*

    DATA lv_first TYPE c LENGTH 1.

    lv_first = im_name.
    IF lv_first = 'Z' OR lv_first = 'Y'.
      ex_yes = abap_true.
    ENDIF.

  ENDMETHOD.


  METHOD list_datasources.
*&---------------------------------------------------------------------*
*& Active DataSources (version A) filtered by name pattern, application,
*& type, description word, custom, delta, BW system. Description and BW
*& systems are added per hit. At most 200.
*&---------------------------------------------------------------------*

    DATA lo_in     TYPE REF TO zif_ajson.
    DATA lo_out    TYPE REF TO zcl_ajson.
    DATA li_ds     TYPE t_dss.
    DATA lw_ds     TYPE t_ds.
    DATA lv_pat    TYPE string.
    DATA lv_like   TYPE roosource-oltpsource.
    DATA lv_text   TYPE string.
    DATA lv_appl   TYPE string.
    DATA lv_type   TYPE string.
    DATA lv_bw     TYPE string.
    DATA lv_cust   TYPE abap_bool.
    DATA lv_delta  TYPE abap_bool.
    DATA lv_max    TYPE i.
    DATA lv_total  TYPE i.
    DATA lv_idx    TYPE i.
    DATA lv_pos    TYPE i.
    DATA lv_dtext  TYPE string.
    DATA lv_up     TYPE string.
    DATA lv_path   TYPE string.
    DATA lv_val    TYPE string.
    DATA lr_appl   TYPE RANGE OF roosource-applnm.
    DATA lw_r_appl LIKE LINE OF lr_appl.
    DATA lr_type   TYPE RANGE OF roosource-type.
    DATA lw_r_type LIKE LINE OF lr_type.
    DATA li_bwds   TYPE STANDARD TABLE OF roosource-oltpsource.
    DATA lv_bwlog  TYPE roosgen-rlogsys.
    DATA li_gen    TYPE STANDARD TABLE OF roosgen.
    DATA lw_gen    TYPE roosgen.
    DATA lv_n      TYPE i.
    DATA lv_yes    TYPE abap_bool.

    lo_in = zcl_ajson=>parse( im_input ).
    lv_pat  = lo_in->get( '/pattern' ).
    lv_text = lo_in->get( '/text' ).
    lv_appl = lo_in->get( '/application' ).
    lv_type = lo_in->get( '/type' ).
    lv_bw   = lo_in->get( '/bw_system' ).
    lv_cust = lo_in->get_boolean( '/custom_only' ).
    lv_delta = lo_in->get_boolean( '/delta_only' ).
    lv_max  = lo_in->get_integer( '/max_results' ).
    CONDENSE: lv_pat NO-GAPS, lv_appl NO-GAPS, lv_type NO-GAPS, lv_bw NO-GAPS.
    TRANSLATE: lv_pat TO UPPER CASE, lv_appl TO UPPER CASE, lv_type TO UPPER CASE,
               lv_bw TO UPPER CASE.
    IF lv_max <= 0.
      lv_max = c_def_max.
    ELSEIF lv_max > c_max_max.
      lv_max = c_max_max.
    ENDIF.
    IF lv_pat IS INITIAL.
      lv_pat = '*'.
    ENDIF.
    lv_like = lv_pat.
    TRANSLATE lv_like USING '*%'.

    IF lv_appl IS NOT INITIAL.
      lw_r_appl-sign   = 'I'.
      lw_r_appl-option = 'EQ'.
      lw_r_appl-low    = lv_appl.
      APPEND lw_r_appl TO lr_appl.
    ENDIF.
    IF lv_type IS NOT INITIAL.
      lw_r_type-sign   = 'I'.
      lw_r_type-option = 'EQ'.
      lw_r_type-low    = lv_type.
      APPEND lw_r_type TO lr_type.
    ENDIF.

    SELECT oltpsource type applnm delta exmethod extractor exstruct tstpnm tstpdat
      FROM roosource INTO TABLE li_ds
      UP TO 50000 ROWS
      WHERE oltpsource LIKE lv_like
        AND objvers    = 'A'
        AND applnm     IN lr_appl
        AND type       IN lr_type.
    SORT li_ds BY oltpsource.

*   BW system filter: DataSources replicated to that system (ROOSGEN)
    IF lv_bw IS NOT INITIAL.
      lv_bwlog = lv_bw.
      SELECT oltpsource FROM roosgen INTO TABLE li_bwds
        WHERE rlogsys = lv_bwlog.
      SORT li_bwds.
      DELETE ADJACENT DUPLICATES FROM li_bwds.
    ENDIF.

    lv_up = lv_text.
    TRANSLATE lv_up TO UPPER CASE.
    LOOP AT li_ds INTO lw_ds.
      lv_pos = sy-tabix.
      IF lv_cust = abap_true AND is_custom( lw_ds-oltpsource ) = abap_false.
        DELETE li_ds INDEX lv_pos.
        CONTINUE.
      ENDIF.
      IF lv_delta = abap_true AND lw_ds-delta IS INITIAL.
        DELETE li_ds INDEX lv_pos.
        CONTINUE.
      ENDIF.
      IF lv_bw IS NOT INITIAL.
        READ TABLE li_bwds TRANSPORTING NO FIELDS WITH KEY table_line = lw_ds-oltpsource BINARY SEARCH.
        IF sy-subrc <> 0.
          DELETE li_ds INDEX lv_pos.
          CONTINUE.
        ENDIF.
      ENDIF.
      IF lv_up IS NOT INITIAL.
        lv_dtext = ds_text( lw_ds-oltpsource ).
        TRANSLATE lv_dtext TO UPPER CASE.
        lv_val = lw_ds-oltpsource.
        IF lv_dtext NS lv_up AND lv_val NS lv_up.
          DELETE li_ds INDEX lv_pos.
          CONTINUE.
        ENDIF.
      ENDIF.
    ENDLOOP.
    lv_total = lines( li_ds ).

    lo_out = zcl_ajson=>create_empty( ).
    lo_out->set_integer( iv_path = '/count' iv_val = lv_total ).
    lo_out->touch_array( '/datasources' ).
    LOOP AT li_ds INTO lw_ds.
      lv_idx = sy-tabix.
      IF lv_idx > lv_max.
        EXIT.
      ENDIF.
      lv_path = idx_path( im_base = '/datasources/' im_index = lv_idx im_field = 'name' ).
      lv_val = lw_ds-oltpsource.
      lo_out->set( iv_path = lv_path iv_val = lv_val ).
      lv_path = idx_path( im_base = '/datasources/' im_index = lv_idx im_field = 'description' ).
      lv_val = ds_text( lw_ds-oltpsource ).
      lo_out->set( iv_path = lv_path iv_val = lv_val ).
      lv_path = idx_path( im_base = '/datasources/' im_index = lv_idx im_field = 'type' ).
      lv_val = domain_text( im_rollname = 'ROOSTYPE' im_value = lw_ds-type ).
      lo_out->set( iv_path = lv_path iv_val = lv_val ).
      lv_path = idx_path( im_base = '/datasources/' im_index = lv_idx im_field = 'application' ).
      lv_val = lw_ds-applnm.
      lo_out->set( iv_path = lv_path iv_val = lv_val ).
      lv_path = idx_path( im_base = '/datasources/' im_index = lv_idx im_field = 'extraction' ).
      lv_val = method_text( im_exmethod = lw_ds-exmethod im_extractor = lw_ds-extractor ).
      lo_out->set( iv_path = lv_path iv_val = lv_val ).
      lv_path = idx_path( im_base = '/datasources/' im_index = lv_idx im_field = 'delta' ).
      lv_val = delta_text( lw_ds-delta ).
      lo_out->set( iv_path = lv_path iv_val = lv_val ).
      lv_path = idx_path( im_base = '/datasources/' im_index = lv_idx im_field = 'custom' ).
      lv_yes = is_custom( lw_ds-oltpsource ).
      lo_out->set_boolean( iv_path = lv_path iv_val = lv_yes ).
      SELECT * FROM roosgen INTO TABLE li_gen WHERE oltpsource = lw_ds-oltpsource.
      lv_path = idx_path( im_base = '/datasources/' im_index = lv_idx im_field = 'bw_systems' ).
      lo_out->touch_array( lv_path ).
      lv_n = 0.
      LOOP AT li_gen INTO lw_gen.
        lv_n = lv_n + 1.
        lv_path = idx_path( im_base = '/datasources/' im_index = lv_idx im_field = 'bw_systems/' ).
        lv_val = lv_n.
        CONDENSE lv_val.
        CONCATENATE lv_path lv_val INTO lv_path.
        lv_val = lw_gen-rlogsys.
        IF lv_val = '$ODQ_DUMMY'.
          lv_val = 'ODP / operational delta queue'.
        ENDIF.
        lo_out->set( iv_path = lv_path iv_val = lv_val ).
      ENDLOOP.
    ENDLOOP.

    IF lv_total = 0.
      lo_out->set( iv_path = '/note' iv_val = 'No active DataSource matches. Try a broader pattern (e.g. *SALES* in text), or check the name in RSA6.' ).
    ELSEIF lv_total > lv_max.
      lo_out->set( iv_path = '/note' iv_val = 'More DataSources match than were returned (count). Narrow with pattern, application, type or text, or raise max_results (at most 200).' ).
    ENDIF.

    ex_json = lo_out->stringify( ).

  ENDMETHOD.


  METHOD method_text.
*&---------------------------------------------------------------------*
*& Extraction method in words.
*&---------------------------------------------------------------------*

    CASE im_exmethod.
      WHEN 'V'.
        ex_text = 'View or table'.
      WHEN 'F1'.
        ex_text = 'Function module (SAP extraction API)'.
      WHEN 'F2'.
        ex_text = 'Function module (simple interface)'.
      WHEN 'D'.
        ex_text = 'Domain fixed values'.
      WHEN 'Q'.
        ex_text = 'InfoSet query'.
      WHEN OTHERS.
        ex_text = domain_text( im_rollname = 'ROEXMETHOD' im_value = im_exmethod ).
        IF ex_text IS INITIAL.
          ex_text = im_exmethod.
        ENDIF.
    ENDCASE.
    IF im_extractor = 'MCEX_BW_LO_API'.
      ex_text = 'Logistics extraction (LO cockpit, SAP extraction API)'.
    ENDIF.

  ENDMETHOD.


  METHOD own_logsys.
*&---------------------------------------------------------------------*

    SELECT SINGLE logsys FROM t000 INTO ex_logsys WHERE mandt = sy-mandt.

  ENDMETHOD.


  METHOD parse_exit.
*&---------------------------------------------------------------------*
*& A small state machine over the statements of one exit include:
*&   IF / ELSEIF i_datasource = 'X'   opens a branch for X (depth 1)
*&   WHEN 'X' inside CASE i_datasource opens a branch for X
*&   nested IF ... ENDIF changes the depth only
*&   INCLUDE y. in a branch           -> hit (X, y)
*&   any other statement in a branch  -> hit (X, exit include, lines)
*& Comments are ignored. Conditions on other variables do not open a
*& branch.
*&---------------------------------------------------------------------*

    DATA lv_line  TYPE string.
    DATA lv_stmt  TYPE string.
    DATA lv_no    TYPE i.
    DATA lv_ds    TYPE string.
    DATA lv_depth TYPE i.
    DATA lv_case  TYPE abap_bool.
    DATA lv_incl  TYPE string.
    DATA lv_off   TYPE i.
    DATA lv_len   TYPE i.
    DATA lw_hit   TYPE t_exit_hit.
    DATA lw_code  TYPE t_exit_hit.
    DATA lv_open  TYPE abap_bool.

    LOOP AT im_source INTO lv_line.
      lv_no = sy-tabix.
      IF lv_line IS INITIAL OR lv_line(1) = '*'.
        CONTINUE.
      ENDIF.
*     drop a trailing comment
      FIND FIRST OCCURRENCE OF '"' IN lv_line MATCH OFFSET lv_off.
      IF sy-subrc = 0.
        IF lv_off = 0.
          CONTINUE.
        ENDIF.
        lv_line = lv_line(lv_off).
      ENDIF.
      lv_stmt = lv_line.
      CONDENSE lv_stmt.
      TRANSLATE lv_stmt TO UPPER CASE.
      IF lv_stmt IS INITIAL.
        CONTINUE.
      ENDIF.

*     a branch for a DataSource opens
      CLEAR lv_ds.
      IF ( lv_stmt CP 'IF I_DATASOURCE*' OR lv_stmt CP 'ELSEIF I_DATASOURCE*' )
         AND ( lv_stmt CS ' = ''' OR lv_stmt CS ' EQ ''' ).
        FIND FIRST OCCURRENCE OF '''' IN lv_stmt MATCH OFFSET lv_off.
        lv_off = lv_off + 1.
        lv_ds = lv_stmt+lv_off.
        FIND FIRST OCCURRENCE OF '''' IN lv_ds MATCH OFFSET lv_len.
        IF sy-subrc = 0.
          lv_ds = lv_ds(lv_len).
        ENDIF.
*       the previous branch (ELSEIF) keeps its own code lines
        IF lv_open = abap_true AND lw_code-from_line > 0.
          lw_code-exit_incl = im_exit_incl.
          lw_code-include   = im_exit_incl.
          APPEND lw_code TO ex_hits.
        ENDIF.
        lw_code-datasource = lv_ds.
        lv_depth = 1.
        lv_open = abap_true.
        CLEAR: lw_code-from_line, lw_code-to_line.
        CONTINUE.
      ENDIF.
      IF lv_stmt CP 'CASE I_DATASOURCE*'.
        lv_case = abap_true.
        lv_open = abap_false.
        CONTINUE.
      ENDIF.
      IF lv_case = abap_true AND lv_depth = 0 AND lv_stmt CP 'WHEN ''*'.
        IF lw_code-from_line > 0.
          lw_code-exit_incl = im_exit_incl.
          lw_code-include   = im_exit_incl.
          APPEND lw_code TO ex_hits.
        ENDIF.
        FIND FIRST OCCURRENCE OF '''' IN lv_stmt MATCH OFFSET lv_off.
        lv_off = lv_off + 1.
        lv_ds = lv_stmt+lv_off.
        FIND FIRST OCCURRENCE OF '''' IN lv_ds MATCH OFFSET lv_len.
        IF sy-subrc = 0.
          lv_ds = lv_ds(lv_len).
        ENDIF.
        CLEAR lw_code.
        lw_code-datasource = lv_ds.
        lv_open = abap_true.
        CONTINUE.
      ENDIF.
      IF lv_case = abap_true AND lv_depth = 0 AND ( lv_stmt CP 'WHEN OTHERS*' OR lv_stmt CP 'ENDCASE*' ).
        IF lv_open = abap_true AND lw_code-from_line > 0.
          lw_code-exit_incl = im_exit_incl.
          lw_code-include   = im_exit_incl.
          APPEND lw_code TO ex_hits.
        ENDIF.
        CLEAR lw_code.
        lv_open = abap_false.
        IF lv_stmt CP 'ENDCASE*'.
          lv_case = abap_false.
        ENDIF.
        CONTINUE.
      ENDIF.

      IF lv_open = abap_false.
        CONTINUE.
      ENDIF.

*     inside an IF branch: track nesting, close on its own ENDIF/ELSE
      IF lv_depth > 0.
        IF lv_stmt CP 'IF *' OR lv_stmt = 'IF'.
          lv_depth = lv_depth + 1.
        ELSEIF lv_stmt CP 'ENDIF*'.
          lv_depth = lv_depth - 1.
        ELSEIF lv_depth = 1 AND ( lv_stmt CP 'ELSE.*' OR lv_stmt CP 'ELSEIF *' ).
          lv_depth = 0.
        ENDIF.
        IF lv_depth = 0.
          IF lw_code-from_line > 0.
            lw_code-exit_incl = im_exit_incl.
            lw_code-include   = im_exit_incl.
            APPEND lw_code TO ex_hits.
          ENDIF.
          CLEAR lw_code.
          lv_open = abap_false.
          CONTINUE.
        ENDIF.
      ENDIF.

      IF lv_stmt CP 'INCLUDE *'.
        lv_incl = lv_stmt+8.
        REPLACE ALL OCCURRENCES OF '.' IN lv_incl WITH ''.
        CONDENSE lv_incl NO-GAPS.
        CLEAR lw_hit.
        lw_hit-datasource = lw_code-datasource.
        lw_hit-exit_incl  = im_exit_incl.
        lw_hit-include    = lv_incl.
        APPEND lw_hit TO ex_hits.
      ELSE.
        IF lw_code-from_line = 0.
          lw_code-from_line = lv_no.
        ENDIF.
        lw_code-to_line = lv_no.
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD read_exits.
*&---------------------------------------------------------------------*
*& Reads and parses ZXRSAU01-04 once per request.
*&---------------------------------------------------------------------*

    DATA li_incl TYPE STANDARD TABLE OF progname.
    DATA lv_incl TYPE progname.
    DATA li_src  TYPE string_table.
    DATA li_hits TYPE t_exit_hits.

    IF v_exits_read = abap_true.
      RETURN.
    ENDIF.
    v_exits_read = abap_true.
    CLEAR i_exits.

    APPEND 'ZXRSAU01' TO li_incl.
    APPEND 'ZXRSAU02' TO li_incl.
    APPEND 'ZXRSAU03' TO li_incl.
    APPEND 'ZXRSAU04' TO li_incl.
    LOOP AT li_incl INTO lv_incl.
      CLEAR li_src.
      READ REPORT lv_incl INTO li_src.
      IF sy-subrc <> 0.
        CONTINUE.
      ENDIF.
      li_hits = parse_exit( im_exit_incl = lv_incl im_source = li_src ).
      APPEND LINES OF li_hits TO i_exits.
    ENDLOOP.

  ENDMETHOD.


  METHOD table_datasources.
*&---------------------------------------------------------------------*
*& DataSources that read a table:
*&   1. view/table DataSources: extractor = the table, or a view built
*&      on it (DD26S)
*&   2. custom function-module extractors whose function include uses
*&      the table (where-used index WBCROSSGT)
*&   3. customer-exit code (ZXRSAU01-04 branches) that uses the table
*&---------------------------------------------------------------------*

    TYPES: BEGIN OF lt_hit,
             datasource TYPE roosource-oltpsource,
             how        TYPE string,
             via        TYPE string,
           END OF lt_hit.

    DATA lo_in    TYPE REF TO zif_ajson.
    DATA lo_out   TYPE REF TO zcl_ajson.
    DATA lv_tab   TYPE string.
    DATA lv_tname TYPE tabname.
    DATA lv_gt    TYPE eu_lname.
    DATA li_view  TYPE STANDARD TABLE OF dd26s-viewname.
    DATA lv_view  TYPE dd26s-viewname.
    DATA li_ds    TYPE t_dss.
    DATA lw_ds    TYPE t_ds.
    DATA lv_extr  TYPE roosource-extractor.
    DATA li_incl  TYPE STANDARD TABLE OF wbcrossgt-include.
    DATA lv_incl  TYPE string.
    DATA li_hit   TYPE STANDARD TABLE OF lt_hit.
    DATA lw_hit   TYPE lt_hit.
    DATA lw_exit  TYPE t_exit_hit.
    DATA lv_i     TYPE i.
    DATA lv_path  TYPE string.
    DATA lv_val   TYPE string.

    lo_in = zcl_ajson=>parse( im_input ).
    lv_tab = lo_in->get( '/table' ).
    CONDENSE lv_tab NO-GAPS.
    TRANSLATE lv_tab TO UPPER CASE.
    IF lv_tab IS INITIAL.
      ex_json = error_json( 'Give a table name, e.g. VBAP.' ).
      RETURN.
    ENDIF.
    lv_tname = lv_tab.

*   1. view/table DataSources
    SELECT viewname FROM dd26s INTO TABLE li_view
      WHERE tabname = lv_tname AND as4local = 'A'.
    APPEND lv_tname TO li_view.
    SORT li_view.
    DELETE ADJACENT DUPLICATES FROM li_view.
    LOOP AT li_view INTO lv_view.
      lv_extr = lv_view.
      CLEAR li_ds.
      SELECT oltpsource type applnm delta exmethod extractor exstruct tstpnm tstpdat
        FROM roosource INTO TABLE li_ds
        WHERE extractor = lv_extr AND objvers = 'A' AND exmethod = 'V'.
      LOOP AT li_ds INTO lw_ds.
        CLEAR lw_hit.
        lw_hit-datasource = lw_ds-oltpsource.
        IF lv_view = lv_tname.
          lw_hit-how = 'extracts directly from the table'.
        ELSE.
          lw_hit-how = 'extracts from a view on the table'.
          lw_hit-via = lv_view.
        ENDIF.
        APPEND lw_hit TO li_hit.
      ENDLOOP.
    ENDLOOP.

*   where-used of the table in code
    lv_gt = lv_tab.
    SELECT include FROM wbcrossgt INTO TABLE li_incl
      UP TO 5000 ROWS
      WHERE name = lv_gt AND otype = 'TY'.
    SORT li_incl.
    DELETE ADJACENT DUPLICATES FROM li_incl.

*   2. custom function-module extractors
    CLEAR li_ds.
    SELECT oltpsource type applnm delta exmethod extractor exstruct tstpnm tstpdat
      FROM roosource INTO TABLE li_ds
      WHERE objvers = 'A' AND ( exmethod = 'F1' OR exmethod = 'F2' ).
    LOOP AT li_ds INTO lw_ds.
      IF is_custom( lw_ds-extractor ) = abap_false.
        CONTINUE.
      ENDIF.
      lv_incl = fm_include( lw_ds-extractor ).
      IF lv_incl IS INITIAL.
        CONTINUE.
      ENDIF.
      READ TABLE li_incl TRANSPORTING NO FIELDS WITH KEY table_line = lv_incl BINARY SEARCH.
      IF sy-subrc = 0.
        CLEAR lw_hit.
        lw_hit-datasource = lw_ds-oltpsource.
        lw_hit-how = 'custom extractor function module uses the table'.
        CONCATENATE lw_ds-extractor '(' lv_incl ')' INTO lw_hit-via SEPARATED BY space.
        APPEND lw_hit TO li_hit.
      ENDIF.
    ENDLOOP.

*   3. customer-exit code
    read_exits( ).
    LOOP AT i_exits INTO lw_exit.
      READ TABLE li_incl TRANSPORTING NO FIELDS WITH KEY table_line = lw_exit-include BINARY SEARCH.
      IF sy-subrc = 0.
        CLEAR lw_hit.
        lw_hit-datasource = lw_exit-datasource.
        lw_hit-how = 'customer exit code for the DataSource uses the table'.
        CONCATENATE lw_exit-exit_incl '>' lw_exit-include INTO lw_hit-via SEPARATED BY space.
        APPEND lw_hit TO li_hit.
      ENDIF.
    ENDLOOP.

    SORT li_hit BY datasource how via.
    DELETE ADJACENT DUPLICATES FROM li_hit COMPARING datasource how via.

    lo_out = zcl_ajson=>create_empty( ).
    lo_out->set( iv_path = '/table' iv_val = lv_tab ).
    lv_i = lines( li_hit ).
    lo_out->set_integer( iv_path = '/count' iv_val = lv_i ).
    lv_i = 0.
    lo_out->touch_array( '/datasources' ).
    LOOP AT li_hit INTO lw_hit.
      lv_i = sy-tabix.
      IF lv_i > c_max_max.
        EXIT.
      ENDIF.
      lv_path = idx_path( im_base = '/datasources/' im_index = lv_i im_field = 'name' ).
      lv_val = lw_hit-datasource.
      lo_out->set( iv_path = lv_path iv_val = lv_val ).
      lv_path = idx_path( im_base = '/datasources/' im_index = lv_i im_field = 'description' ).
      lv_val = ds_text( lw_hit-datasource ).
      lo_out->set( iv_path = lv_path iv_val = lv_val ).
      lv_path = idx_path( im_base = '/datasources/' im_index = lv_i im_field = 'how' ).
      lo_out->set( iv_path = lv_path iv_val = lw_hit-how ).
      IF lw_hit-via IS NOT INITIAL.
        lv_path = idx_path( im_base = '/datasources/' im_index = lv_i im_field = 'via' ).
        lo_out->set( iv_path = lv_path iv_val = lw_hit-via ).
      ENDIF.
    ENDLOOP.

    CONCATENATE 'Covers view/table DataSources, custom function-module extractors (main function include only)'
                'and customer-exit code. Not covered: SAP standard extractor code and LO extract structures'
                'that take fields from the table through SAP communication structures.'
           INTO lv_val SEPARATED BY space.
    lo_out->set( iv_path = '/note' iv_val = lv_val ).

    ex_json = lo_out->stringify( ).

  ENDMETHOD.


ENDCLASS.
