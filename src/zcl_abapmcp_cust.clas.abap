CLASS zcl_abapmcp_cust DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.
*--------------------------------------------------------------------*
* Title       : ZCL_ABAPMCP_CUST - configuration lookup MCP tools
* Type        : Class (MCP tool plug-in, read-only)
* Frequency   : On demand (called per MCP tools/call)
* Description : Three read-only tools on /sap/bc/mcp for functional
*               consultants - "where is this configured, and what is
*               it set to?":
*                 sap_tcode_info   transaction -> program, screen,
*                                  SM30 view, auth objects, IMG
*                 sap_find_config  IMG activities by text or by the
*                                  table / view they maintain
*                 sap_read_config  rows of one configuration table
*                 sap_find_field   tables that have a field
*                 sap_message_info message text and long text
*--------------------------------------------------------------------*
*& Plug-in class, same contract as ZCL_ABAPMCP_DIAG:
*&   ZCL_ABAPMCP_TOOLS=>GET_TOOL_DEFS splices GET_TOOL_DEFS_JSON into
*&   its catalogue, and ZCL_ABAPMCP_TOOLS=>EXECUTE hands any tool for
*&   which HANDLES is true to EXECUTE here.
*&
*& READ-ONLY. SELECTs only. There is no write statement and adding one
*& defeats the purpose of this server - see CONTRIBUTING.md.
*&
*& STANDARD OBJECTS
*& These tools are about SAP standard objects, so CHECK_CUSTOM does not
*& apply. Metadata (transactions, IMG, DDIC) is always readable. Table
*& ROWS are guarded in READ_CONFIG:
*&   - configuration tables only (delivery class C, G or E)
*&   - the caller's own S_TABU_DIS or S_TABU_NAM, ACTVT 03
*&   - a hard blocklist (HR, payroll, user master, bank / card /
*&     password fields) that no authorization lifts
*&   - logon client only, row and size caps
*&
*& NW 7.02 syntax only: no inline DATA( ), no VALUE #( ), no NEW.
*&---------------------------------------------------------------------*

*   Rows per sap_read_config call: default and ceiling.
    CONSTANTS c_def_rows  TYPE i VALUE 50.
    CONSTANTS c_max_rows  TYPE i VALUE 200.
*   IMG activities per answer: default and ceiling.
    CONSTANTS c_def_hits  TYPE i VALUE 10.
    CONSTANTS c_max_hits  TYPE i VALUE 20.
*   Rough size ceiling of the row values in one answer, in characters.
    CONSTANTS c_max_chars TYPE i VALUE 20000.
*   Text-table rows read to describe the returned rows.
    CONSTANTS c_max_texts TYPE i VALUE 5000.
*   Tables per sap_find_field answer: default, ceiling, and rows scanned.
    CONSTANTS c_def_fields  TYPE i VALUE 30.
    CONSTANTS c_max_fields  TYPE i VALUE 100.
    CONSTANTS c_scan_fields TYPE i VALUE 2000.
*   Long text of a message, in characters.
    CONSTANTS c_max_longtext TYPE i VALUE 4000.
*   SPRO paths: for the first activities of an answer, how many per
*   activity, and how deep a path may go.
    CONSTANTS c_path_hits TYPE i VALUE 3.
*   activities whose SPRO path is looked up to rank core before industry
    CONSTANTS c_rank_hits TYPE i VALUE 6.
    CONSTANTS c_max_paths TYPE i VALUE 2.
    CONSTANTS c_max_depth TYPE i VALUE 25.
*   SAP Reference IMG (SPRO root) and the database reads one path
*   lookup may spend
    CONSTANTS c_spro_root   TYPE hier_treeg VALUE '368DDFAB3AB96CCFE10000009B38F976'.
    CONSTANTS c_path_budget TYPE i VALUE 400.

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
*"* protected components of class ZCL_ABAPMCP_CUST
*"* do not include other source files here!!!

  PRIVATE SECTION.

    TYPES t_dfies      TYPE STANDARD TABLE OF dfies WITH DEFAULT KEY.
    TYPES t_activities TYPE STANDARD TABLE OF cus_img_ac WITH DEFAULT KEY.
    TYPES: BEGIN OF t_path_cache,
             activity TYPE cus_img_ac,
             core     TYPE abap_bool,
             paths    TYPE string_table,
           END OF t_path_cache.

*   SPRO paths found in this call, per activity
    CLASS-DATA gt_paths TYPE STANDARD TABLE OF t_path_cache WITH DEFAULT KEY.

    CLASS-METHODS tcode_info
      IMPORTING im_input       TYPE string
      RETURNING VALUE(ex_json) TYPE string
      RAISING   zcx_ajson_error.

    CLASS-METHODS find_config
      IMPORTING im_input       TYPE string
      RETURNING VALUE(ex_json) TYPE string
      RAISING   zcx_ajson_error.

    CLASS-METHODS read_config
      IMPORTING im_input       TYPE string
      RETURNING VALUE(ex_json) TYPE string
      RAISING   zcx_ajson_error.

    CLASS-METHODS find_field
      IMPORTING im_input       TYPE string
      RETURNING VALUE(ex_json) TYPE string
      RAISING   zcx_ajson_error.

    CLASS-METHODS message_info
      IMPORTING im_input       TYPE string
      RETURNING VALUE(ex_json) TYPE string
      RAISING   zcx_ajson_error.

*   Authorization objects as SU21 shows them: one object, a pattern,
*   or an object class. Metadata only. 12.10.2026
    CLASS-METHODS auth_object_info
      IMPORTING im_input       TYPE string
      RETURNING VALUE(ex_json) TYPE string
      RAISING   zcx_ajson_error.

    CLASS-METHODS activities_for_object
      IMPORTING im_object      TYPE string
      RETURNING VALUE(ex_list) TYPE t_activities.

    CLASS-METHODS add_activity
      IMPORTING im_out      TYPE REF TO zcl_ajson
                im_base     TYPE string
                im_activity TYPE cus_img_ac
                im_paths    TYPE abap_bool DEFAULT abap_false
      RAISING   zcx_ajson_error.

    CLASS-METHODS spro_paths
      IMPORTING im_activity TYPE cus_img_ac
      EXPORTING ex_paths    TYPE string_table
                ex_core     TYPE abap_bool.

    CLASS-METHODS activity_paths
      IMPORTING im_activity TYPE cus_img_ac
      EXPORTING ex_paths    TYPE string_table
                ex_core     TYPE abap_bool.

    CLASS-METHODS core_first
      IMPORTING im_list        TYPE t_activities
      RETURNING VALUE(ex_list) TYPE t_activities.

    CLASS-METHODS climb
      IMPORTING im_tree  TYPE hier_guid
                im_node  TYPE hier_guid
                im_depth TYPE i
      EXPORTING ex_path  TYPE string
                ex_spro  TYPE abap_bool.

*   SPRO path walk: the root's tree, and reads left in this call
    CLASS-DATA gv_spro_tree TYPE hier_guid.
    CLASS-DATA gv_budget    TYPE i.

    CLASS-METHODS view_tables
      IMPORTING im_view        TYPE string
      RETURNING VALUE(ex_tabs) TYPE string_table.

    CLASS-METHODS sensitive
      IMPORTING im_table         TYPE tabname
                im_fields        TYPE t_dfies
      RETURNING VALUE(ex_reason) TYPE string.

    CLASS-METHODS auth_ok
      IMPORTING im_table TYPE tabname
      EXPORTING ex_ok    TYPE abap_bool
                ex_group TYPE brgru.

    CLASS-METHODS row_key
      IMPORTING im_row        TYPE any
                im_keys       TYPE string_table
      RETURNING VALUE(ex_key) TYPE string.

    CLASS-METHODS add_field
      IMPORTING im_out   TYPE REF TO zcl_ajson
                im_base  TYPE string
                im_field TYPE string
                im_val   TYPE string
      RAISING   zcx_ajson_error.

    CLASS-METHODS add_list
      IMPORTING im_out  TYPE REF TO zcl_ajson
                im_path TYPE string
                im_list TYPE string_table
      RAISING   zcx_ajson_error.

    CLASS-METHODS conv_value
      IMPORTING im_table        TYPE tabname
                im_field        TYPE dfies
                im_value        TYPE string
                im_dir          TYPE char1
      RETURNING VALUE(ex_value) TYPE string.

    CLASS-METHODS rank_activities
      IMPORTING im_list        TYPE t_activities
                im_hint        TYPE string
      RETURNING VALUE(ex_list) TYPE t_activities.

    CLASS-METHODS log_call
      IMPORTING im_name   TYPE string
                im_input  TYPE string
                im_result TYPE string
                im_msec   TYPE i.

    CLASS-METHODS error_json
      IMPORTING im_msg         TYPE string
      RETURNING VALUE(ex_json) TYPE string.

ENDCLASS.


CLASS zcl_abapmcp_cust IMPLEMENTATION.

  METHOD activities_for_object.
*&---------------------------------------------------------------------*
*& IMG activities whose customizing object is im_object, or a view
*& built on it - T001W is maintained through V_T001W, never directly.
*&
*& Ranked in two groups: first the activities that maintain the object
*& itself (the object, or a view whose primary table it is - DD26S
*& TABPOS 0001), then those whose view merely joins it, e.g. a view on
*& order types that shows the sales organization text.
*&---------------------------------------------------------------------*

    DATA li_cact  TYPE STANDARD TABLE OF cus_act.
    DATA li_cact2 TYPE STANDARD TABLE OF cus_act.
    DATA li_views TYPE STANDARD TABLE OF viewname.
    DATA li_join  TYPE STANDARD TABLE OF viewname.
    DATA li_first TYPE t_activities.
    DATA li_later TYPE t_activities.
    DATA lv_act   TYPE cus_img_ac.
    DATA lv_obj   TYPE ob_object.

    lv_obj = im_object.
    SELECT act_id FROM cus_actobj INTO TABLE li_cact WHERE objectname = lv_obj.

    SELECT viewname FROM dd26s INTO TABLE li_views
      WHERE tabname = lv_obj AND as4local = 'A' AND tabpos = '0001'.
    IF li_views IS NOT INITIAL.
      SELECT act_id FROM cus_actobj APPENDING TABLE li_cact
        FOR ALL ENTRIES IN li_views
        WHERE objectname = li_views-table_line.
    ENDIF.

    SELECT viewname FROM dd26s INTO TABLE li_join
      WHERE tabname = lv_obj AND as4local = 'A' AND tabpos <> '0001'.
    IF li_join IS NOT INITIAL.
      SELECT act_id FROM cus_actobj INTO TABLE li_cact2
        FOR ALL ENTRIES IN li_join
        WHERE objectname = li_join-table_line.
    ENDIF.

    SORT li_cact.
    DELETE ADJACENT DUPLICATES FROM li_cact.
    SORT li_cact2.
    DELETE ADJACENT DUPLICATES FROM li_cact2.

    IF li_cact IS NOT INITIAL.
      SELECT activity FROM cus_imgach INTO TABLE li_first
        FOR ALL ENTRIES IN li_cact
        WHERE c_activity = li_cact-table_line.
      SORT li_first.
      DELETE ADJACENT DUPLICATES FROM li_first.
    ENDIF.
    IF li_cact2 IS NOT INITIAL.
      SELECT activity FROM cus_imgach INTO TABLE li_later
        FOR ALL ENTRIES IN li_cact2
        WHERE c_activity = li_cact2-table_line.
      SORT li_later.
      DELETE ADJACENT DUPLICATES FROM li_later.
    ENDIF.

    ex_list = li_first.
*   an activity found both ways keeps its place in the first group
    LOOP AT li_later INTO lv_act.
      READ TABLE li_first TRANSPORTING NO FIELDS WITH KEY table_line = lv_act BINARY SEARCH.
      IF sy-subrc <> 0.
        APPEND lv_act TO ex_list.
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD activity_paths.
*&---------------------------------------------------------------------*
*& SPRO_PATHS once per activity and call: ranking and output both need
*& the paths, and the tree walk is the expensive part.
*&---------------------------------------------------------------------*

    DATA lw_cache TYPE t_path_cache.

    READ TABLE gt_paths INTO lw_cache WITH KEY activity = im_activity.
    IF sy-subrc = 0.
      ex_paths = lw_cache-paths.
      ex_core  = lw_cache-core.
      RETURN.
    ENDIF.

    spro_paths( EXPORTING im_activity = im_activity
                IMPORTING ex_paths    = ex_paths
                          ex_core     = ex_core ).
    lw_cache-activity = im_activity.
    lw_cache-core     = ex_core.
    lw_cache-paths    = ex_paths.
    APPEND lw_cache TO gt_paths.

  ENDMETHOD.


  METHOD add_activity.
*&---------------------------------------------------------------------*
*& One IMG activity, ready for the caller: its text, the transaction it
*& runs and its customizing objects - for a view also the tables that
*& hold the data, which sap_read_config then reads.
*&---------------------------------------------------------------------*

    DATA lw_ach   TYPE cus_imgach.
    DATA lv_text  TYPE hier_text.
    DATA li_obj   TYPE STANDARD TABLE OF cus_actobj.
    DATA lw_obj   TYPE cus_actobj.
    DATA li_tabs  TYPE string_table.
    DATA lv_i     TYPE string.
    DATA lv_obase TYPE string.
    DATA lv_path  TYPE string.
    DATA lv_kind  TYPE string.
    DATA lv_val   TYPE string.
    DATA lv_core  TYPE abap_bool.

    SELECT SINGLE * FROM cus_imgach INTO lw_ach WHERE activity = im_activity.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.
    SELECT SINGLE text FROM cus_imgact INTO lv_text
      WHERE spras = sy-langu AND activity = im_activity.
    IF sy-subrc <> 0.
      SELECT SINGLE text FROM cus_imgact INTO lv_text
        WHERE spras = 'E' AND activity = im_activity.
    ENDIF.

    lv_val = im_activity.
    add_field( im_out = im_out im_base = im_base im_field = 'activity' im_val = lv_val ).
    lv_val = lv_text.
    add_field( im_out = im_out im_base = im_base im_field = 'text' im_val = lv_val ).
    lv_val = lw_ach-tcode.
    add_field( im_out = im_out im_base = im_base im_field = 'tcode' im_val = lv_val ).

*   where it sits in SPRO - only when asked, the tree walk costs reads
    IF im_paths = abap_true.
      activity_paths( EXPORTING im_activity = im_activity
                      IMPORTING ex_paths    = li_tabs
                                ex_core     = lv_core ).
      IF li_tabs IS NOT INITIAL.
        CONCATENATE im_base '/spro_path' INTO lv_path.
        add_list( im_out = im_out im_path = lv_path im_list = li_tabs ).
      ENDIF.
      CLEAR li_tabs.
    ENDIF.

    IF lw_ach-c_activity IS INITIAL.
      RETURN.
    ENDIF.

    SELECT * FROM cus_actobj INTO TABLE li_obj WHERE act_id = lw_ach-c_activity.
*   one row per maintenance transaction or sub-object - list each object once
    SORT li_obj BY objecttype objectname.
    DELETE ADJACENT DUPLICATES FROM li_obj COMPARING objecttype objectname.
    IF li_obj IS INITIAL.
      RETURN.
    ENDIF.
    CONCATENATE im_base '/objects' INTO lv_path.
    im_out->touch_array( lv_path ).

    LOOP AT li_obj INTO lw_obj.
      lv_i = sy-tabix.
      CONDENSE lv_i.
      CONCATENATE im_base '/objects/' lv_i INTO lv_obase.

      CASE lw_obj-objecttype.
        WHEN 'V'.
          lv_kind = 'view'.
        WHEN 'S'.
          lv_kind = 'table'.
        WHEN 'C'.
          lv_kind = 'view cluster'.
        WHEN 'T'.
          lv_kind = 'transaction'.
        WHEN 'L'.
          lv_kind = 'logical object'.
        WHEN OTHERS.
          lv_kind = lw_obj-objecttype.
      ENDCASE.
      add_field( im_out = im_out im_base = lv_obase im_field = 'type' im_val = lv_kind ).
      lv_val = lw_obj-objectname.
      add_field( im_out = im_out im_base = lv_obase im_field = 'name' im_val = lv_val ).

      CLEAR li_tabs.
      IF lw_obj-objecttype = 'V'.
        li_tabs = view_tables( im_view = lv_val ).
      ELSEIF lw_obj-objecttype = 'S'.
        APPEND lv_val TO li_tabs.
      ENDIF.
      IF li_tabs IS NOT INITIAL.
        CONCATENATE lv_obase '/tables' INTO lv_path.
        add_list( im_out = im_out im_path = lv_path im_list = li_tabs ).
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD add_field.
*&---------------------------------------------------------------------*
*& Set im_base/im_field to im_val; an empty value is left out.
*&---------------------------------------------------------------------*

    DATA lv_path TYPE string.

    IF im_val IS INITIAL.
      RETURN.
    ENDIF.
    CONCATENATE im_base '/' im_field INTO lv_path.
    im_out->set( iv_path = lv_path iv_val = im_val ).

  ENDMETHOD.


  METHOD add_list.
*&---------------------------------------------------------------------*
*& im_list as a JSON array of strings at im_path.
*&---------------------------------------------------------------------*

    DATA lv_item TYPE string.
    DATA lv_i    TYPE string.
    DATA lv_path TYPE string.

    im_out->touch_array( im_path ).
    LOOP AT im_list INTO lv_item.
      lv_i = sy-tabix.
      CONDENSE lv_i.
      CONCATENATE im_path '/' lv_i INTO lv_path.
      im_out->set( iv_path = lv_path iv_val = lv_item ).
    ENDLOOP.

  ENDMETHOD.


  METHOD auth_object_info.
*&---------------------------------------------------------------------*
*& Authorization objects as SU21 shows them - metadata only, read from
*& TOBJ/TOBJT (object), TOBC/TOBCT (class), TACTZ/TACTT (permitted
*& activities) and AUTHX/DD04T (field data elements). Three modes:
*&   object = exact name    one object: text, class, author, fields
*&                          with data element and text, activities.
*&                          A name that does not exist is reported as
*&                          free, so a new name can be checked.
*&   object = pattern (*)   matching objects with text and class
*&   class  = class name    the class text and all its objects
*& Never reads which user or role holds an authorization (USR*, AGR*).
*& 12.10.2026
*&---------------------------------------------------------------------*

    TYPES: BEGIN OF lt_obj,
             objct TYPE tobj-objct,
             oclss TYPE tobj-oclss,
           END OF lt_obj.

    DATA lo_in    TYPE REF TO zif_ajson.
    DATA lo_out   TYPE REF TO zcl_ajson.
    DATA lv_obj   TYPE string.
    DATA lv_cls   TYPE string.
    DATA lv_pat   TYPE c LENGTH 40.
    DATA lv_max   TYPE i.
    DATA lv_lang  TYPE sy-langu.
    DATA lw_tobj  TYPE tobj.
    DATA lv_text  TYPE tobjt-ttext.
    DATA lv_ctext TYPE tobct-ctext.
    DATA lv_ocl   TYPE tobc-oclss.
    DATA li_flds  TYPE string_table.
    DATA lv_fld   TYPE string.
    DATA lv_fname TYPE authx-fieldname.
    DATA lv_roll  TYPE authx-rollname.
    DATA lv_ddtxt TYPE dd04t-ddtext.
    DATA lv_has_actvt TYPE abap_bool.
    DATA li_act   TYPE STANDARD TABLE OF tactz-actvt.
    DATA lv_act   TYPE tactz-actvt.
    DATA lv_atext TYPE tactt-ltext.
    DATA li_objs  TYPE STANDARD TABLE OF lt_obj.
    DATA lw_obj   TYPE lt_obj.
    DATA lv_cnt   TYPE i.
    DATA lv_i     TYPE string.
    DATA lv_base  TYPE string.
    DATA lv_path  TYPE string.
    DATA lv_val   TYPE string.
    DATA lv_msg   TYPE string.

    lo_in = zcl_ajson=>parse( im_input ).
    lv_obj = lo_in->get( '/object' ).
    lv_cls = lo_in->get( '/class' ).
    CONDENSE: lv_obj NO-GAPS, lv_cls NO-GAPS.
    TRANSLATE: lv_obj TO UPPER CASE, lv_cls TO UPPER CASE.
    lv_max = lo_in->get_integer( '/max_results' ).
    IF lv_max <= 0.
      lv_max = c_def_fields.
    ELSEIF lv_max > c_max_rows.
      lv_max = c_max_rows.
    ENDIF.
    IF lv_obj IS INITIAL AND lv_cls IS INITIAL.
      ex_json = error_json( im_msg = 'Give object (e.g. S_DEVELOP, or Z_AI* as a pattern) or class (e.g. BC_C).' ).
      RETURN.
    ENDIF.
    IF strlen( lv_obj ) > 10 OR strlen( lv_cls ) > 4.
      ex_json = error_json( im_msg = 'An object name has at most 10 characters, a class at most 4.' ).
      RETURN.
    ENDIF.

    lo_out = zcl_ajson=>create_empty( ).

*   ---- one object by its exact name ---------------------------------
    IF lv_obj IS NOT INITIAL AND lv_obj NA '*'.
      lo_out->set( iv_path = '/object' iv_val = lv_obj ).
      SELECT SINGLE * FROM tobj INTO lw_tobj WHERE objct = lv_obj.
      IF sy-subrc <> 0.
        lo_out->set_boolean( iv_path = '/exists' iv_val = abap_false ).
        CONCATENATE 'No authorization object' lv_obj
                    'exists in this system - the name is free.'
          INTO lv_msg SEPARATED BY space.
        lo_out->set( iv_path = '/note' iv_val = lv_msg ).
        ex_json = lo_out->stringify( ).
        RETURN.
      ENDIF.
      lo_out->set_boolean( iv_path = '/exists' iv_val = abap_true ).

*     texts in the logon language, English when there is none
      lv_lang = sy-langu.
      SELECT SINGLE ttext FROM tobjt INTO lv_text
        WHERE langu = lv_lang AND object = lw_tobj-objct.
      IF sy-subrc <> 0.
        SELECT SINGLE ttext FROM tobjt INTO lv_text
          WHERE langu = 'E' AND object = lw_tobj-objct.
      ENDIF.
      lv_val = lv_text.
      lo_out->set( iv_path = '/text' iv_val = lv_val ).
      lv_val = lw_tobj-oclss.
      lo_out->set( iv_path = '/class' iv_val = lv_val ).
      SELECT SINGLE ctext FROM tobct INTO lv_ctext
        WHERE langu = lv_lang AND oclss = lw_tobj-oclss.
      IF sy-subrc <> 0.
        SELECT SINGLE ctext FROM tobct INTO lv_ctext
          WHERE langu = 'E' AND oclss = lw_tobj-oclss.
      ENDIF.
      lv_val = lv_ctext.
      lo_out->set( iv_path = '/class_text' iv_val = lv_val ).
      lv_val = lw_tobj-bname.
      lo_out->set( iv_path = '/author' iv_val = lv_val ).

*     the fields in their SU21 order
      APPEND lw_tobj-fiel1 TO li_flds.
      APPEND lw_tobj-fiel2 TO li_flds.
      APPEND lw_tobj-fiel3 TO li_flds.
      APPEND lw_tobj-fiel4 TO li_flds.
      APPEND lw_tobj-fiel5 TO li_flds.
      APPEND lw_tobj-fiel6 TO li_flds.
      APPEND lw_tobj-fiel7 TO li_flds.
      APPEND lw_tobj-fiel8 TO li_flds.
      APPEND lw_tobj-fiel9 TO li_flds.
      APPEND lw_tobj-fiel0 TO li_flds.
      DELETE li_flds WHERE table_line IS INITIAL.
      lo_out->touch_array( '/fields' ).
      LOOP AT li_flds INTO lv_fld.
        lv_i = sy-tabix.
        CONDENSE lv_i.
        CONCATENATE '/fields/' lv_i INTO lv_base.
        CONCATENATE lv_base '/field' INTO lv_path.
        lo_out->set( iv_path = lv_path iv_val = lv_fld ).
        IF lv_fld = 'ACTVT'.
          lv_has_actvt = abap_true.
        ENDIF.
        CLEAR: lv_roll, lv_ddtxt.
        lv_fname = lv_fld.
        SELECT SINGLE rollname FROM authx INTO lv_roll WHERE fieldname = lv_fname.
        IF lv_roll IS NOT INITIAL.
          lv_val = lv_roll.
          CONCATENATE lv_base '/data_element' INTO lv_path.
          lo_out->set( iv_path = lv_path iv_val = lv_val ).
          SELECT SINGLE ddtext FROM dd04t INTO lv_ddtxt
            WHERE rollname = lv_roll AND ddlanguage = lv_lang AND as4local = 'A'.
          IF sy-subrc <> 0.
            SELECT SINGLE ddtext FROM dd04t INTO lv_ddtxt
              WHERE rollname = lv_roll AND ddlanguage = 'E' AND as4local = 'A'.
          ENDIF.
          IF lv_ddtxt IS NOT INITIAL.
            lv_val = lv_ddtxt.
            CONCATENATE lv_base '/text' INTO lv_path.
            lo_out->set( iv_path = lv_path iv_val = lv_val ).
          ENDIF.
        ENDIF.
      ENDLOOP.

*     permitted activities, as the "Permitted Activities" button shows
      IF lv_has_actvt = abap_true.
        SELECT actvt FROM tactz INTO TABLE li_act WHERE brobj = lw_tobj-objct.
        SORT li_act.
        lo_out->touch_array( '/activities' ).
        LOOP AT li_act INTO lv_act.
          lv_i = sy-tabix.
          CONDENSE lv_i.
          CONCATENATE '/activities/' lv_i INTO lv_base.
          CONCATENATE lv_base '/activity' INTO lv_path.
          lv_val = lv_act.
          lo_out->set( iv_path = lv_path iv_val = lv_val ).
          CLEAR lv_atext.
          SELECT SINGLE ltext FROM tactt INTO lv_atext
            WHERE spras = lv_lang AND actvt = lv_act.
          IF sy-subrc <> 0.
            SELECT SINGLE ltext FROM tactt INTO lv_atext
              WHERE spras = 'E' AND actvt = lv_act.
          ENDIF.
          lv_val = lv_atext.
          CONCATENATE lv_base '/text' INTO lv_path.
          lo_out->set( iv_path = lv_path iv_val = lv_val ).
        ENDLOOP.
        IF li_act IS INITIAL.
          lo_out->set( iv_path = '/activities_note'
                       iv_val  = 'No permitted activities are maintained - any activity value is accepted.' ).
        ENDIF.
      ENDIF.

      ex_json = lo_out->stringify( ).
      RETURN.
    ENDIF.

*   ---- a class: its text, and whether it exists ---------------------
    IF lv_cls IS NOT INITIAL.
      lv_ocl = lv_cls.
      lo_out->set( iv_path = '/class' iv_val = lv_cls ).
      SELECT SINGLE oclss FROM tobc INTO lv_ocl WHERE oclss = lv_ocl.
      IF sy-subrc <> 0.
        lo_out->set_boolean( iv_path = '/exists' iv_val = abap_false ).
        CONCATENATE 'No authorization object class' lv_cls
                    'exists in this system - the name is free.'
          INTO lv_msg SEPARATED BY space.
        lo_out->set( iv_path = '/note' iv_val = lv_msg ).
        ex_json = lo_out->stringify( ).
        RETURN.
      ENDIF.
      lo_out->set_boolean( iv_path = '/exists' iv_val = abap_true ).
      lv_lang = sy-langu.
      SELECT SINGLE ctext FROM tobct INTO lv_ctext
        WHERE langu = lv_lang AND oclss = lv_ocl.
      IF sy-subrc <> 0.
        SELECT SINGLE ctext FROM tobct INTO lv_ctext
          WHERE langu = 'E' AND oclss = lv_ocl.
      ENDIF.
      lv_val = lv_ctext.
      lo_out->set( iv_path = '/class_text' iv_val = lv_val ).
    ENDIF.

*   ---- the list: by pattern, by class, or both -----------------------
    IF lv_obj IS NOT INITIAL.
*     "_" is a one-character wildcard in LIKE: escape it, so Z_AI*
*     does not also match ZXAI...; "*" becomes "%"
      lv_pat = lv_obj.
      REPLACE ALL OCCURRENCES OF '_' IN lv_pat WITH '#_'.
      TRANSLATE lv_pat USING '*%'.
      IF lv_cls IS NOT INITIAL.
        SELECT objct oclss FROM tobj INTO TABLE li_objs
          WHERE objct LIKE lv_pat ESCAPE '#' AND oclss = lv_ocl.
      ELSE.
        SELECT objct oclss FROM tobj INTO TABLE li_objs
          WHERE objct LIKE lv_pat ESCAPE '#'.
      ENDIF.
    ELSE.
      SELECT objct oclss FROM tobj INTO TABLE li_objs
        WHERE oclss = lv_ocl.
    ENDIF.
    SORT li_objs BY objct.
    DESCRIBE TABLE li_objs LINES lv_cnt.
    lo_out->set_integer( iv_path = '/count' iv_val = lv_cnt ).
    lo_out->touch_array( '/objects' ).
    lv_lang = sy-langu.
    LOOP AT li_objs INTO lw_obj.
      IF sy-tabix > lv_max.
        EXIT.
      ENDIF.
      lv_i = sy-tabix.
      CONDENSE lv_i.
      CONCATENATE '/objects/' lv_i INTO lv_base.
      CONCATENATE lv_base '/object' INTO lv_path.
      lv_val = lw_obj-objct.
      lo_out->set( iv_path = lv_path iv_val = lv_val ).
      CONCATENATE lv_base '/class' INTO lv_path.
      lv_val = lw_obj-oclss.
      lo_out->set( iv_path = lv_path iv_val = lv_val ).
      CLEAR lv_text.
      SELECT SINGLE ttext FROM tobjt INTO lv_text
        WHERE langu = lv_lang AND object = lw_obj-objct.
      IF sy-subrc <> 0.
        SELECT SINGLE ttext FROM tobjt INTO lv_text
          WHERE langu = 'E' AND object = lw_obj-objct.
      ENDIF.
      lv_val = lv_text.
      CONCATENATE lv_base '/text' INTO lv_path.
      lo_out->set( iv_path = lv_path iv_val = lv_val ).
    ENDLOOP.
    IF lv_cnt = 0.
      lo_out->set( iv_path = '/note' iv_val = 'No authorization object matches - those names are free.' ).
    ELSEIF lv_cnt > lv_max.
      lo_out->set( iv_path = '/note' iv_val = 'More objects match than were returned. Narrow the pattern or raise max_results (at most 200).' ).
    ENDIF.

    ex_json = lo_out->stringify( ).

  ENDMETHOD.


  METHOD auth_ok.
*&---------------------------------------------------------------------*
*& The caller's own table display authorization, the same rule SE16
*& applies: S_TABU_DIS for the table's authorization group (TDDAT,
*& &NC& when it has none), or else S_TABU_NAM for the table by name.
*& Activity 03 (display) in both.
*&---------------------------------------------------------------------*

    ex_ok = abap_false.

    SELECT SINGLE cclass FROM tddat INTO ex_group WHERE tabname = im_table.
    IF ex_group IS INITIAL.
      ex_group = '&NC&'.
    ENDIF.

    AUTHORITY-CHECK OBJECT 'S_TABU_DIS'
      ID 'ACTVT'     FIELD '03'
      ID 'DICBERCLS' FIELD ex_group.
    IF sy-subrc = 0.
      ex_ok = abap_true.
      RETURN.
    ENDIF.

    AUTHORITY-CHECK OBJECT 'S_TABU_NAM'
      ID 'ACTVT' FIELD '03'
      ID 'TABLE' FIELD im_table.
    IF sy-subrc = 0.
      ex_ok = abap_true.
    ENDIF.

  ENDMETHOD.


  METHOD climb.
*&---------------------------------------------------------------------*
*& The path from one node up to the top of the whole structure, as text,
*& and whether that top is the SPRO root. SPRO is built from linked
*& sub-structures: at the top of one, each node that links it in
*& (REFTREE_ID, at most 5) is tried, and the first way up to the SPRO
*& root wins. GV_BUDGET caps the database reads of one SPRO_PATHS call.
*&---------------------------------------------------------------------*

    TYPES: BEGIN OF lt_link,
             tree_id TYPE hier_guid,
             node_id TYPE hier_guid,
           END OF lt_link.

    DATA lv_tree   TYPE hier_guid.
    DATA lv_node   TYPE hier_guid.
    DATA lv_parent TYPE hier_guid.
    DATA lv_text   TYPE hier_text.
    DATA lv_step   TYPE string.
    DATA lv_last   TYPE string.
    DATA lv_top    TYPE string.
    DATA lv_depth  TYPE i.
    DATA li_link   TYPE STANDARD TABLE OF lt_link.
    DATA lw_link   TYPE lt_link.
    DATA lv_sub    TYPE string.
    DATA lv_subok  TYPE abap_bool.
    DATA lv_best   TYPE string.
    DATA lv_bestok TYPE abap_bool.
    DATA lv_have   TYPE abap_bool.
    DATA li_steps  TYPE string_table.
    DATA lv_tail   TYPE string.

    CLEAR: ex_path, ex_spro.
    lv_tree  = im_tree.
    lv_node  = im_node.
    lv_depth = im_depth.

    DO.
      lv_depth = lv_depth + 1.
      IF gv_budget <= 0 OR lv_depth > c_max_depth.
        RETURN.
      ENDIF.
      gv_budget = gv_budget - 1.

*     this node's text in front
      CLEAR lv_text.
      SELECT SINGLE text FROM tnodeimgt INTO lv_text
        WHERE spras = sy-langu AND tree_id = lv_tree AND node_id = lv_node.
      IF sy-subrc <> 0.
        SELECT SINGLE text FROM tnodeimgt INTO lv_text
          WHERE spras = 'E' AND tree_id = lv_tree AND node_id = lv_node.
      ENDIF.
      lv_step = lv_text.
      IF lv_step IS NOT INITIAL AND lv_step <> lv_last.
        IF ex_path IS INITIAL.
          ex_path = lv_step.
        ELSE.
          CONCATENATE lv_step ` > ` ex_path INTO ex_path.
        ENDIF.
        lv_last = lv_step.
        lv_top  = lv_step.
      ENDIF.

      CLEAR lv_parent.
      SELECT SINGLE parent_id FROM tnodeimg INTO lv_parent
        WHERE tree_id = lv_tree AND node_id = lv_node.
      IF lv_parent IS NOT INITIAL.
        lv_node = lv_parent.
        CONTINUE.
      ENDIF.

*     top of this structure
      IF lv_tree = gv_spro_tree.
        ex_spro = abap_true.
        RETURN.
      ENDIF.
      SELECT tree_id node_id FROM tnodeimg INTO TABLE li_link
        UP TO 5 ROWS
        WHERE reftree_id = lv_tree.
      LOOP AT li_link INTO lw_link.
        IF lw_link-tree_id = lv_tree.
          CONTINUE.
        ENDIF.
        climb( EXPORTING im_tree  = lw_link-tree_id
                         im_node  = lw_link-node_id
                         im_depth = lv_depth
               IMPORTING ex_path  = lv_sub
                         ex_spro  = lv_subok ).
        IF lv_have = abap_false OR lv_subok = abap_true.
          lv_best   = lv_sub.
          lv_bestok = lv_subok.
          lv_have   = abap_true.
        ENDIF.
        IF lv_subok = abap_true.
          EXIT.
        ENDIF.
      ENDLOOP.

*     join the way up with this part; the linking node usually repeats
*     the text of the top of this part
      IF lv_best IS NOT INITIAL.
        SPLIT lv_best AT ` > ` INTO TABLE li_steps.
        READ TABLE li_steps INTO lv_tail INDEX lines( li_steps ).
        IF lv_tail = lv_top.
          DELETE li_steps INDEX lines( li_steps ).
        ENDIF.
        LOOP AT li_steps INTO lv_tail.
          IF sy-tabix = 1.
            lv_best = lv_tail.
          ELSE.
            CONCATENATE lv_best ` > ` lv_tail INTO lv_best.
          ENDIF.
        ENDLOOP.
        IF li_steps IS NOT INITIAL.
          CONCATENATE lv_best ` > ` ex_path INTO ex_path.
        ENDIF.
      ENDIF.
      ex_spro = lv_bestok.
      RETURN.
    ENDDO.

  ENDMETHOD.


  METHOD conv_value.
*&---------------------------------------------------------------------*
*& The value as the SAP GUI shows it (O) or as the database stores it
*& (I), through the field's conversion exit: order type OR is stored as
*& TA, customer 1 as 0000000001. Without an exit, or when the exit
*& refuses the value, it comes back unchanged.
*&---------------------------------------------------------------------*

    DATA lv_fm    TYPE rs38l_fnam.
    DATA lv_tname TYPE string.
    DATA lr_val   TYPE REF TO data.
    DATA lv_in    TYPE c LENGTH 255.
    DATA lv_out   TYPE c LENGTH 255.
    DATA lx_root  TYPE REF TO cx_root.

    FIELD-SYMBOLS <lf_val> TYPE any.

    ex_value = im_value.
    IF im_field-convexit IS INITIAL.
      RETURN.
    ENDIF.

    IF im_dir = 'I'.
      CONCATENATE 'CONVERSION_EXIT_' im_field-convexit '_INPUT' INTO lv_fm.
    ELSE.
      CONCATENATE 'CONVERSION_EXIT_' im_field-convexit '_OUTPUT' INTO lv_fm.
    ENDIF.
    CONCATENATE im_table '-' im_field-fieldname INTO lv_tname.

    TRY.
        CREATE DATA lr_val TYPE (lv_tname).
        ASSIGN lr_val->* TO <lf_val>.
        IF im_dir = 'I'.
          lv_in = im_value.
          CALL FUNCTION lv_fm
            EXPORTING
              input         = lv_in
            IMPORTING
              output        = <lf_val>
            EXCEPTIONS
              error_message = 1
              OTHERS        = 2.
          IF sy-subrc = 0.
            ex_value = <lf_val>.
          ENDIF.
        ELSE.
          <lf_val> = im_value.
          CALL FUNCTION lv_fm
            EXPORTING
              input         = <lf_val>
            IMPORTING
              output        = lv_out
            EXCEPTIONS
              error_message = 1
              OTHERS        = 2.
          IF sy-subrc = 0.
            ex_value = lv_out.
          ENDIF.
        ENDIF.
      CATCH cx_root INTO lx_root.
        ex_value = im_value.
    ENDTRY.

    SHIFT ex_value LEFT DELETING LEADING space.

  ENDMETHOD.


  METHOD core_first.
*&---------------------------------------------------------------------*
*& Among the first c_rank_hits activities, those whose SPRO path lies in
*& a core application come before industry solutions - OVKK: SD pricing
*& before IS-Hospital pricing, both SIMG* and so equal for
*& RANK_ACTIVITIES. The rest keep their order. The paths found here are
*& cached and reused by ADD_ACTIVITY.
*&---------------------------------------------------------------------*

    DATA lv_act   TYPE cus_img_ac.
    DATA lv_idx   TYPE i.
    DATA li_paths TYPE string_table.
    DATA lv_core  TYPE abap_bool.
    DATA li_core  TYPE t_activities.
    DATA li_other TYPE t_activities.

    LOOP AT im_list INTO lv_act.
      lv_idx = lv_idx + 1.
      IF lv_idx <= c_rank_hits.
        activity_paths( EXPORTING im_activity = lv_act
                        IMPORTING ex_paths    = li_paths
                                  ex_core     = lv_core ).
        IF lv_core = abap_true.
          APPEND lv_act TO li_core.
        ELSE.
          APPEND lv_act TO li_other.
        ENDIF.
      ELSE.
        APPEND lv_act TO li_other.
      ENDIF.
    ENDLOOP.

    ex_list = li_core.
    APPEND LINES OF li_other TO ex_list.

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
*& Route one tool call. A tool failure is a normal result carrying an
*& error text the model can act on, never an exception to the server.
*&---------------------------------------------------------------------*

    DATA lx_root TYPE REF TO cx_root.
    DATA lv_msg  TYPE string.
    DATA lv_t0   TYPE i.
    DATA lv_t1   TYPE i.
    DATA lv_ms   TYPE i.

    GET RUN TIME FIELD lv_t0.
    CLEAR gt_paths.

    TRY.
        CASE im_name.
          WHEN 'sap_tcode_info'.
            ex_result = tcode_info( im_input = im_input ).
          WHEN 'sap_find_config'.
            ex_result = find_config( im_input = im_input ).
          WHEN 'sap_read_config'.
            ex_result = read_config( im_input = im_input ).
          WHEN 'sap_find_field'.
            ex_result = find_field( im_input = im_input ).
          WHEN 'sap_message_info'.
            ex_result = message_info( im_input = im_input ).
          WHEN 'sap_auth_object_info'.
            ex_result = auth_object_info( im_input = im_input ).
          WHEN OTHERS.
            CONCATENATE 'Unknown tool:' im_name INTO lv_msg SEPARATED BY space.
            ex_result = error_json( im_msg = lv_msg ).
        ENDCASE.
      CATCH cx_root INTO lx_root.
        lv_msg = lx_root->get_text( ).
        ex_result = error_json( im_msg = lv_msg ).
    ENDTRY.

*   audit trail of the configuration tools - see LOG_CALL
    GET RUN TIME FIELD lv_t1.
    lv_ms = ( lv_t1 - lv_t0 ) / 1000.
    IF handles( im_name ) = abap_true.
      log_call( im_name   = im_name
                im_input  = im_input
                im_result = ex_result
                im_msec   = lv_ms ).
    ENDIF.

  ENDMETHOD.


  METHOD find_config.
*&---------------------------------------------------------------------*
*& IMG activities by text (CUS_IMGACT) or by the table / view they
*& maintain (CUS_ACTOBJ, and DD26S for views on the table).
*&
*& Text search runs in ABAP, not in the database: the IMG texts are
*& mixed case and LIKE is case-sensitive. CS ignores case. Every word
*& must appear; shorter texts rank first, as they match more exactly.
*&---------------------------------------------------------------------*

    TYPES: BEGIN OF lt_txt,
             activity TYPE cus_img_ac,
             text     TYPE hier_text,
           END OF lt_txt.
    TYPES: BEGIN OF lt_hit,
             score    TYPE i,
             len      TYPE i,
             activity TYPE cus_img_ac,
           END OF lt_hit.

    DATA lo_in    TYPE REF TO zif_ajson.
    DATA lo_out   TYPE REF TO zcl_ajson.
    DATA lv_text  TYPE string.
    DATA lv_obj   TYPE string.
    DATA lv_word  TYPE string.
    DATA lv_score TYPE i.
    DATA lv_best  TYPE i.
    DATA lv_words TYPE i.
    DATA lv_c1    TYPE c LENGTH 10.
    DATA lv_c2    TYPE c LENGTH 10.
    DATA lv_note  TYPE string.
    FIELD-SYMBOLS <lf_word> TYPE string.
    DATA lv_max   TYPE i.
    DATA lv_total TYPE i.
    DATA lv_idx   TYPE i.
    DATA lv_ret   TYPE i.
    DATA lv_i     TYPE string.
    DATA lv_base  TYPE string.
    DATA lv_langu TYPE spras.
    DATA li_words TYPE string_table.
    DATA li_txt   TYPE STANDARD TABLE OF lt_txt.
    DATA lw_txt   TYPE lt_txt.
    DATA li_hit   TYPE STANDARD TABLE OF lt_hit.
    DATA lw_hit   TYPE lt_hit.
    DATA li_act   TYPE t_activities.
    DATA lv_act   TYPE cus_img_ac.

    lo_in = zcl_ajson=>parse( im_input ).
    lv_text = lo_in->get( '/text' ).
    lv_obj  = lo_in->get( '/object' ).
    CONDENSE lv_text.
    CONDENSE lv_obj.
    TRANSLATE lv_obj TO UPPER CASE.

    lv_max = lo_in->get_integer( '/max_results' ).
    IF lv_max <= 0.
      lv_max = c_def_hits.
    ENDIF.
    IF lv_max > c_max_hits.
      lv_max = c_max_hits.
    ENDIF.

    IF lv_obj IS NOT INITIAL.
      li_act = activities_for_object( im_object = lv_obj ).

    ELSEIF lv_text IS NOT INITIAL.
      SPLIT lv_text AT space INTO TABLE li_words.
      DELETE li_words WHERE table_line IS INITIAL.
*     a word stem is enough: "determination" finds "Determine Pricing
*     Procedure", "procedure" finds "Procedures"
      LOOP AT li_words ASSIGNING <lf_word>.
        IF strlen( <lf_word> ) > 6.
          <lf_word> = <lf_word>(6).
        ENDIF.
      ENDLOOP.
      DESCRIBE TABLE li_words LINES lv_words.

      lv_langu = sy-langu.
      SELECT activity text FROM cus_imgact INTO TABLE li_txt WHERE spras = lv_langu.
      IF li_txt IS INITIAL.
        lv_langu = 'E'.
        SELECT activity text FROM cus_imgact INTO TABLE li_txt WHERE spras = lv_langu.
      ENDIF.

*     score = words found; the best score wins, so a text with all the
*     words beats one with some, and some still beat none
      LOOP AT li_txt INTO lw_txt.
        lv_score = 0.
        LOOP AT li_words INTO lv_word.
          IF lw_txt-text CS lv_word.
            lv_score = lv_score + 1.
          ENDIF.
        ENDLOOP.
        IF lv_score > 0 AND lv_score >= lv_best.
          lv_best         = lv_score.
          lw_hit-score    = lv_score.
          lw_hit-len      = strlen( lw_txt-text ).
          lw_hit-activity = lw_txt-activity.
          APPEND lw_hit TO li_hit.
        ENDIF.
      ENDLOOP.
      FREE li_txt.

      DELETE li_hit WHERE score < lv_best.
      SORT li_hit BY len activity.
      IF li_hit IS NOT INITIAL AND lv_best < lv_words.
        lv_c1 = lv_best.
        lv_c2 = lv_words.
        CONDENSE: lv_c1, lv_c2.
        CONCATENATE 'No IMG activity has all the words - these match' lv_c1 'of' lv_c2
                    '(by word stem). Change a word to narrow.'
          INTO lv_note SEPARATED BY space.
      ENDIF.
      LOOP AT li_hit INTO lw_hit.
        APPEND lw_hit-activity TO li_act.
      ENDLOOP.

    ELSE.
      ex_json = error_json( im_msg = 'Give text (words from the IMG activity) or object (a table or view name).' ).
      RETURN.
    ENDIF.

    li_act = rank_activities( im_list = li_act im_hint = '' ).
    li_act = core_first( li_act ).
    DESCRIBE TABLE li_act LINES lv_total.

    lo_out = zcl_ajson=>create_empty( ).
    IF lv_obj IS NOT INITIAL.
      lo_out->set( iv_path = '/object' iv_val = lv_obj ).
    ELSE.
      lo_out->set( iv_path = '/text' iv_val = lv_text ).
    ENDIF.
    lo_out->set_integer( iv_path = '/count' iv_val = lv_total ).
    lo_out->touch_array( '/activities' ).

    LOOP AT li_act INTO lv_act.
      lv_idx = sy-tabix.
      IF lv_idx > lv_max.
        EXIT.
      ENDIF.
      lv_ret = lv_idx.
      lv_i = lv_idx.
      CONDENSE lv_i.
      CONCATENATE '/activities/' lv_i INTO lv_base.
      IF lv_idx <= c_path_hits.
        add_activity( im_out = lo_out im_base = lv_base im_activity = lv_act im_paths = abap_true ).
      ELSE.
        add_activity( im_out = lo_out im_base = lv_base im_activity = lv_act ).
      ENDIF.
    ENDLOOP.
    lo_out->set_integer( iv_path = '/returned' iv_val = lv_ret ).

    IF lv_total = 0.
      lo_out->set( iv_path = '/note'
                   iv_val  = 'No IMG activity matches. Try fewer or other words (English IMG texts), or pass object with a table or view name.' ).
    ELSEIF lv_note IS NOT INITIAL.
      lo_out->set( iv_path = '/note' iv_val = lv_note ).
    ELSEIF lv_total > lv_ret.
      lo_out->set( iv_path = '/note'
                   iv_val  = 'More activities matched than were returned. Add a word to narrow the search.' ).
    ENDIF.

    ex_json = lo_out->stringify( ).

  ENDMETHOD.


  METHOD find_field.
*&---------------------------------------------------------------------*
*& Tables that have a field, by field name or by data element - the F1
*& 'technical information' question asked the other way round. Only
*& real tables (no structures or views); configuration tables (delivery
*& class C, G, E) first, as sap_read_config can read those.
*&---------------------------------------------------------------------*

    TYPES: BEGIN OF lt_hit,
             tabname   TYPE tabname,
             fieldname TYPE fieldname,
             rollname  TYPE rollname,
             keyflag   TYPE keyflag,
             contflag  TYPE contflag,
             rank      TYPE i,
           END OF lt_hit.
    TYPES: BEGIN OF lt_ttext,
             tabname TYPE tabname,
             ddtext  TYPE as4text,
           END OF lt_ttext.

    DATA lo_in    TYPE REF TO zif_ajson.
    DATA lo_out   TYPE REF TO zcl_ajson.
    DATA lv_str   TYPE string.
    DATA lv_name  TYPE fieldname.
    DATA lv_roll  TYPE rollname.
    DATA lv_dtext TYPE as4text.
    DATA lv_max   TYPE i.
    DATA lv_total TYPE i.
    DATA lv_idx   TYPE i.
    DATA lv_ret   TYPE i.
    DATA lv_i     TYPE string.
    DATA lv_base  TYPE string.
    DATA lv_val   TYPE string.
    DATA lv_cfg   TYPE abap_bool.
    DATA li_hit   TYPE STANDARD TABLE OF lt_hit.
    DATA lw_hit   TYPE lt_hit.
    DATA li_ttext TYPE STANDARD TABLE OF lt_ttext.
    DATA lw_ttext TYPE lt_ttext.

    FIELD-SYMBOLS <lf_hit> TYPE lt_hit.

    lo_in = zcl_ajson=>parse( im_input ).
    lv_str = lo_in->get( '/name' ).
    TRANSLATE lv_str TO UPPER CASE.
    CONDENSE lv_str.
    IF lv_str IS INITIAL OR strlen( lv_str ) > 30.
      ex_json = error_json( im_msg = 'name is required: a field name such as KALSM, or a data element such as KALSMASD.' ).
      RETURN.
    ENDIF.
    lv_name = lv_str.
    lv_roll = lv_str.

    lv_max = lo_in->get_integer( '/max_results' ).
    IF lv_max <= 0.
      lv_max = c_def_fields.
    ENDIF.
    IF lv_max > c_max_fields.
      lv_max = c_max_fields.
    ENDIF.

    SELECT a~tabname a~fieldname a~rollname a~keyflag b~contflag
      FROM dd03l AS a INNER JOIN dd02l AS b
        ON  b~tabname  = a~tabname
        AND b~as4local = a~as4local
      INTO CORRESPONDING FIELDS OF TABLE li_hit
      UP TO c_scan_fields ROWS
      WHERE ( a~fieldname = lv_name OR a~rollname = lv_roll )
        AND a~as4local = 'A'
        AND ( b~tabclass = 'TRANSP' OR b~tabclass = 'POOL' OR b~tabclass = 'CLUSTER' ).

    DESCRIBE TABLE li_hit LINES lv_total.

*   configuration tables first, and within each group SAP's own tables
*   before those of add-ons and industry solutions (namespace /XYZ/)
    LOOP AT li_hit ASSIGNING <lf_hit>.
      IF <lf_hit>-contflag = 'C' OR <lf_hit>-contflag = 'G' OR <lf_hit>-contflag = 'E'.
        <lf_hit>-rank = 1.
      ELSE.
        <lf_hit>-rank = 3.
      ENDIF.
      IF <lf_hit>-tabname(1) = '/'.
        <lf_hit>-rank = <lf_hit>-rank + 1.
      ENDIF.
    ENDLOOP.
    SORT li_hit BY rank tabname fieldname.

    IF li_hit IS NOT INITIAL.
      SELECT tabname ddtext FROM dd02t INTO TABLE li_ttext
        FOR ALL ENTRIES IN li_hit
        WHERE tabname    = li_hit-tabname
          AND ddlanguage = sy-langu
          AND as4local   = 'A'.
      SORT li_ttext BY tabname.
    ENDIF.

*   what the data element means - the one asked for, else the first hit's
    SELECT SINGLE ddtext FROM dd04t INTO lv_dtext
      WHERE rollname = lv_roll AND ddlanguage = sy-langu AND as4local = 'A'.
    IF sy-subrc <> 0.
      READ TABLE li_hit INTO lw_hit INDEX 1.
      IF sy-subrc = 0.
        SELECT SINGLE ddtext FROM dd04t INTO lv_dtext
          WHERE rollname = lw_hit-rollname AND ddlanguage = sy-langu AND as4local = 'A'.
      ENDIF.
    ENDIF.

    lo_out = zcl_ajson=>create_empty( ).
    lo_out->set( iv_path = '/name' iv_val = lv_str ).
    lv_val = lv_dtext.
    add_field( im_out = lo_out im_base = '' im_field = 'meaning' im_val = lv_val ).
    lo_out->set_integer( iv_path = '/count' iv_val = lv_total ).
    lo_out->touch_array( '/tables' ).

    LOOP AT li_hit INTO lw_hit.
      lv_idx = sy-tabix.
      IF lv_idx > lv_max.
        EXIT.
      ENDIF.
      lv_ret = lv_idx.
      lv_i = lv_idx.
      CONDENSE lv_i.
      CONCATENATE '/tables/' lv_i INTO lv_base.

      lv_val = lw_hit-tabname.
      add_field( im_out = lo_out im_base = lv_base im_field = 'table' im_val = lv_val ).
      CLEAR lw_ttext.
      READ TABLE li_ttext INTO lw_ttext WITH KEY tabname = lw_hit-tabname BINARY SEARCH.
      lv_val = lw_ttext-ddtext.
      add_field( im_out = lo_out im_base = lv_base im_field = 'description' im_val = lv_val ).
      lv_val = lw_hit-fieldname.
      add_field( im_out = lo_out im_base = lv_base im_field = 'field' im_val = lv_val ).
      lv_val = lw_hit-rollname.
      add_field( im_out = lo_out im_base = lv_base im_field = 'data_element' im_val = lv_val ).
      IF lw_hit-keyflag = abap_true.
        CONCATENATE lv_base '/key' INTO lv_val.
        lo_out->set_boolean( iv_path = lv_val iv_val = abap_true ).
      ENDIF.
      lv_val = lw_hit-contflag.
      add_field( im_out = lo_out im_base = lv_base im_field = 'delivery_class' im_val = lv_val ).
      IF lw_hit-rank <= 2.
        lv_cfg = abap_true.
      ELSE.
        lv_cfg = abap_false.
      ENDIF.
      CONCATENATE lv_base '/configuration' INTO lv_val.
      lo_out->set_boolean( iv_path = lv_val iv_val = lv_cfg ).
    ENDLOOP.
    lo_out->set_integer( iv_path = '/returned' iv_val = lv_ret ).

    IF lv_total = 0.
      lo_out->set( iv_path = '/note'
                   iv_val  = 'No table has a field or data element of that name. Check the name in SE11, or search the IMG with sap_find_config.' ).
    ELSEIF lv_total > lv_ret.
      lo_out->set( iv_path = '/note'
                   iv_val  = 'More tables have it than were returned - configuration tables are listed first.' ).
    ENDIF.

    ex_json = lo_out->stringify( ).

  ENDMETHOD.


  METHOD get_tool_defs_json.
*&---------------------------------------------------------------------*
*& Tool catalogue. Each description says what the tool returns AND what
*& it does not, so the model picks the right one of the three.
*& 23.10.2026: shortened - tools/list was over the 6k token budget.
*&---------------------------------------------------------------------*

    CONCATENATE
      `{"name":"sap_tcode_info",`
      ` "description":"Explain one transaction code, standard or custom: text, program and screen, `
      `package, authorization values, and for a parameter transaction (OVA8, OX10) the called transaction `
      `(often SM30) and the view and tables it maintains, plus the IMG activities using it. Use first when `
      `a question names a transaction. Table contents: sap_read_config.",`
      ` "input_schema":{"type":"object","properties":{`
      `   "tcode":{"type":"string","description":"Transaction code, e.g. OVA8 or VA01."}},`
      `   "required":["tcode"]}},`
      `{"name":"sap_find_config",`
      ` "description":"Find where something is configured in SPRO (IMG), by words of the activity text `
      `(e.g. credit control area) or by table/view (e.g. T001W): activity, text, transaction and `
      `customizing objects with their tables; the first three hits carry the SPRO menu path. Not the `
      `settings themselves - pass the table to sap_read_config.",`
      ` "input_schema":{"type":"object","properties":{`
      `   "text":{"type":"string","description":"Words of the IMG activity text, English."},`
      `   "object":{"type":"string","description":"Table or view instead, e.g. V_T001W."},`
      `   "max_results":{"type":"integer","description":"1-20, default 10."}},`
      `   "required":[]}},`
      `{"name":"sap_read_config",`
      ` "description":"Read rows of one configuration table (delivery class C, G or E, e.g. T001W, TVKO, `
      `NRIV) in the logon client under the caller's table authorization, with the text table description `
      `as _text, values as in the SAP GUI, empty fields left out. Application data, HR, user and bank `
      `tables are refused; for a view it names the tables. Field list: sap_get_ddic.",`
      ` "input_schema":{"type":"object","properties":{`
      `   "table":{"type":"string","description":"Table name, e.g. T001W."},`
      `   "filters":{"type":"object","description":"Field to value, all must match, e.g. {\"WERKS\":\"1000\"}. `
      `Values as typed in the SAP GUI; * is a wildcard."},`
      `   "fields":{"type":"array","items":{"type":"string"},"description":"Fields to return. Default all."},`
      `   "max_rows":{"type":"integer","description":"1-200, default 50."}},`
      `   "required":["table"]}},`
      `{"name":"sap_find_field",`
      ` "description":"Find the database tables that have a field, by field name (e.g. KALSM) or data `
      `element - F1 technical information the other way round. Each table with description, field, data `
      `element, key flag and delivery class; configuration tables come first. No structures, views or rows.",`
      ` "input_schema":{"type":"object","properties":{`
      `   "name":{"type":"string","description":"Field name or data element, e.g. KALSM."},`
      `   "max_results":{"type":"integer","description":"1-100, default 30."}},`
      `   "required":["name"]}},`
      `{"name":"sap_message_info",`
      ` "description":"Explain an SAP message, standard or custom, as SE91 shows it: short text with & `
      `placeholders, message class and long text (cause, system response, procedure). Use it when a `
      `question quotes a message number. It does not say which program raised it.",`
      ` "input_schema":{"type":"object","properties":{`
      `   "message":{"type":"string","description":"Class and number, e.g. V1 123 or V1/123."}},`
      `   "required":["message"]}},`
      `{"name":"sap_auth_object_info",`
      ` "description":"Explain authorization objects as SU21 shows them: for one object its text, class, `
      `fields and permitted activities; for a pattern (Z_AI*) or class (BC_C) the matching objects. An `
      `unknown name is reported as free, so new names can be checked. Metadata only - never which user or `
      `role holds an authorization.",`
      ` "input_schema":{"type":"object","properties":{`
      `   "object":{"type":"string","description":"Object name or pattern with *, e.g. S_TABU_DIS."},`
      `   "class":{"type":"string","description":"Object class, e.g. BC_C."},`
      `   "max_results":{"type":"integer","description":"1-200, default 30."}},`
      `   "required":[]}}`
      INTO ex_json.

  ENDMETHOD.


  METHOD handles.
*&---------------------------------------------------------------------*
*& The configuration tools of this class (sap_auth_object_info added
*& 12.10.2026).
*&---------------------------------------------------------------------*

    IF im_name = 'sap_tcode_info' OR im_name = 'sap_find_config'
       OR im_name = 'sap_read_config' OR im_name = 'sap_find_field'
       OR im_name = 'sap_message_info' OR im_name = 'sap_auth_object_info'.
      ex_yes = abap_true.
    ENDIF.

  ENDMETHOD.


  METHOD log_call.
*&---------------------------------------------------------------------*
*& One row in ZMCP_CUST_LOG per call: who asked for which table,
*& transaction or search, whether it was answered (O), refused by policy
*& or authorization (R) or failed (E), and how much came back. The
*& answer itself is never stored - only its counts.
*& Switched off by ZABAPMCP_CFG key CUST_LOG = OFF. A logging problem
*& never reaches the caller.
*&---------------------------------------------------------------------*

    DATA lw_log  TYPE zmcp_cust_log.
    DATA lv_cfg  TYPE zabapmcp_cfg-cfg_value.
    DATA lv_guid TYPE guid_32.
    DATA lo_in   TYPE REF TO zif_ajson.
    DATA lo_res  TYPE REF TO zif_ajson.
    DATA lv_tgt  TYPE string.
    DATA lv_msg  TYPE string.
    DATA lx_root TYPE REF TO cx_root.

    TRY.
        SELECT SINGLE cfg_value FROM zabapmcp_cfg INTO lv_cfg
          WHERE cfg_key = 'CUST_LOG'.
        IF sy-subrc = 0 AND lv_cfg = 'OFF'.
          RETURN.
        ENDIF.

        CALL FUNCTION 'GUID_CREATE'
          IMPORTING
            ev_guid_32 = lv_guid.
        lw_log-log_id   = lv_guid.
        GET TIME STAMP FIELD lw_log-tstamp.
        lw_log-uname    = sy-uname.
        lw_log-tool     = im_name.
        lw_log-args     = im_input.
        lw_log-duration = im_msec.

*       what was asked for: names in upper case so SE16 can filter them,
*       search words as typed
        TRY.
            lo_in = zcl_ajson=>parse( im_input ).
            lv_tgt = lo_in->get( '/table' ).
            IF lv_tgt IS INITIAL.
              lv_tgt = lo_in->get( '/tcode' ).
            ENDIF.
            IF lv_tgt IS INITIAL.
              lv_tgt = lo_in->get( '/object' ).
            ENDIF.
            IF lv_tgt IS INITIAL.
              lv_tgt = lo_in->get( '/name' ).
            ENDIF.
            IF lv_tgt IS INITIAL.
              lv_tgt = lo_in->get( '/message' ).
            ENDIF.
            IF lv_tgt IS INITIAL.
              lv_tgt = lo_in->get( '/text' ).
            ELSE.
              TRANSLATE lv_tgt TO UPPER CASE.
            ENDIF.
            CONDENSE lv_tgt.
            lw_log-target = lv_tgt.
          CATCH cx_root INTO lx_root.
            CLEAR lw_log-target.
        ENDTRY.

*       how it ended - every refusal text of this class starts with
*       'Refused.' or 'No authorization'
        TRY.
            lo_res = zcl_ajson=>parse( im_result ).
            lv_msg = lo_res->get( '/error' ).
            IF lv_msg IS INITIAL.
              lw_log-status     = 'O'.
              lw_log-rows_ret   = lo_res->get_integer( '/returned' ).
              lw_log-rows_total = lo_res->get_integer( '/count' ).
            ELSEIF lv_msg CP 'Refused*' OR lv_msg CP 'No authorization*'.
              lw_log-status = 'R'.
            ELSE.
              lw_log-status = 'E'.
            ENDIF.
            lw_log-message = lv_msg.
          CATCH cx_root INTO lx_root.
            lw_log-status  = 'E'.
            lw_log-message = 'The answer was not valid JSON.'.
        ENDTRY.

        INSERT zmcp_cust_log FROM lw_log.
        COMMIT WORK.

      CATCH cx_root INTO lx_root.
*       logging must never break the tool call
        RETURN.
    ENDTRY.

  ENDMETHOD.


  METHOD message_info.
*&---------------------------------------------------------------------*
*& One message (SE91): its short text, its message class and its long
*& text - cause, system response, procedure - turned from SAPscript
*& into plain text. Accepts V1 123, V1123, V1/123 or V1-123.
*&---------------------------------------------------------------------*

    TYPES: BEGIN OF lt_line,
             line      TYPE doku_line,
             dokformat TYPE dok_format,
             doktext   TYPE dok_text,
           END OF lt_line.

    DATA lo_in    TYPE REF TO zif_ajson.
    DATA lo_out   TYPE REF TO zcl_ajson.
    DATA lv_str   TYPE string.
    DATA lv_c     TYPE string.
    DATA lv_n     TYPE string.
    DATA lv_len   TYPE i.
    DATA lv_off   TYPE i.
    DATA lv_numc  TYPE n LENGTH 3.
    DATA lv_cls   TYPE arbgb.
    DATA lv_num   TYPE msgnr.
    DATA lv_lang  TYPE sy-langu.
    DATA lv_text  TYPE natxt.
    DATA lv_stext TYPE as4text.
    DATA lv_obj   TYPE doku_obj.
    DATA lv_vers  TYPE dokvers.
    DATA li_lines TYPE STANDARD TABLE OF lt_line.
    DATA lw_line  TYPE lt_line.
    DATA lv_line  TYPE string.
    DATA lv_long  TYPE string.
    DATA lv_val   TYPE string.
    DATA lv_msg   TYPE string.

    lo_in = zcl_ajson=>parse( im_input ).
    lv_str = lo_in->get( '/message' ).
    TRANSLATE lv_str TO UPPER CASE.
    TRANSLATE lv_str USING '/ - '.
    CONDENSE lv_str.

*   class and number: "V1 123", or run together "V1123"
    IF lv_str CA ' '.
      SPLIT lv_str AT space INTO lv_c lv_n.
    ELSE.
      lv_len = strlen( lv_str ).
      IF lv_len > 3.
        lv_off = lv_len - 3.
        lv_c = lv_str(lv_off).
        lv_n = lv_str+lv_off(3).
      ENDIF.
    ENDIF.
    CONDENSE: lv_c, lv_n.
    IF lv_c IS INITIAL OR strlen( lv_c ) > 20 OR lv_n IS INITIAL
       OR strlen( lv_n ) > 3 OR lv_n CN '0123456789'.
      ex_json = error_json( im_msg = 'message is required as class and number, e.g. V1 123 or V1123.' ).
      RETURN.
    ENDIF.
    lv_cls  = lv_c.
    lv_numc = lv_n.
    lv_num  = lv_numc.

*   logon language, English when the message has no text in it
    lv_lang = sy-langu.
    SELECT SINGLE text FROM t100 INTO lv_text
      WHERE sprsl = lv_lang AND arbgb = lv_cls AND msgnr = lv_num.
    IF sy-subrc <> 0.
      lv_lang = 'E'.
      SELECT SINGLE text FROM t100 INTO lv_text
        WHERE sprsl = lv_lang AND arbgb = lv_cls AND msgnr = lv_num.
    ENDIF.
    IF sy-subrc <> 0.
      CONCATENATE 'Message' lv_c lv_num 'does not exist in this system.'
        INTO lv_msg SEPARATED BY space.
      ex_json = error_json( im_msg = lv_msg ).
      RETURN.
    ENDIF.

*   class text in the language of the message, else the original one
    SELECT SINGLE stext FROM t100t INTO lv_stext
      WHERE sprsl = lv_lang AND arbgb = lv_cls.
    IF sy-subrc <> 0.
      SELECT SINGLE stext FROM t100a INTO lv_stext WHERE arbgb = lv_cls.
    ENDIF.

*   long text: document class NA, object = class and number run together
*   (M7021 - checked in DOKIL)
    CONCATENATE lv_cls lv_num INTO lv_obj.
    SELECT SINGLE version FROM dokil INTO lv_vers
      WHERE id = 'NA' AND object = lv_obj AND langu = lv_lang AND typ = 'E'.
    IF sy-subrc = 0.
      SELECT line dokformat doktext FROM doktl INTO TABLE li_lines
        WHERE id = 'NA' AND object = lv_obj AND langu = lv_lang
          AND typ = 'E' AND dokversion = lv_vers.
      SORT li_lines BY line.

      LOOP AT li_lines INTO lw_line.
*       SAPscript commands are not text - but an INCLUDE pulls in a shared
*       text module, so name it rather than lose that part silently
        IF lw_line-dokformat = '/:'.
          IF lw_line-doktext CP 'INCLUDE *'.
            lv_line = lw_line-doktext+8.
            SPLIT lv_line AT space INTO lv_line lv_val.
            CONCATENATE '[see text module' lv_line 'in SE61]' INTO lv_line SEPARATED BY space.
          ELSE.
            CONTINUE.
          ENDIF.
        ELSE.
          lv_line = lw_line-doktext.
        ENDIF.
*       empty lines carry nothing
        IF lv_line IS INITIAL.
          CONTINUE.
        ENDIF.
*       the standard section headings, as words
        CASE lv_line.
          WHEN '&CAUSE&'.
            lv_line = 'Cause:'.
          WHEN '&SYSTEM_RESPONSE&'.
            lv_line = 'System response:'.
          WHEN '&WHAT_TO_DO&'.
            lv_line = 'Procedure:'.
          WHEN '&SYS_ADMIN&'.
            lv_line = 'Procedure for system administration:'.
          WHEN '&DIAGNOSIS&'.
            lv_line = 'Diagnosis:'.
        ENDCASE.
*       character formats and escapes (<ZK>, </>, <(>, <)>)
        REPLACE ALL OCCURRENCES OF REGEX '<[^>]*>' IN lv_line WITH ''.
        IF lv_long IS INITIAL.
          lv_long = lv_line.
        ELSEIF lw_line-dokformat = '='.
          CONCATENATE lv_long lv_line INTO lv_long.
        ELSEIF lw_line-dokformat IS INITIAL.
          CONCATENATE lv_long lv_line INTO lv_long SEPARATED BY space.
        ELSE.
          CONCATENATE lv_long cl_abap_char_utilities=>newline lv_line INTO lv_long.
        ENDIF.
        IF strlen( lv_long ) > c_max_longtext.
          lv_long = lv_long(c_max_longtext).
          CONCATENATE lv_long ' ...' INTO lv_long.
          EXIT.
        ENDIF.
      ENDLOOP.
    ENDIF.

    lo_out = zcl_ajson=>create_empty( ).
    lo_out->set( iv_path = '/class' iv_val = lv_c ).
    lv_val = lv_num.
    lo_out->set( iv_path = '/number' iv_val = lv_val ).
    lv_val = lv_text.
    lo_out->set( iv_path = '/text' iv_val = lv_val ).
    lv_val = lv_stext.
    add_field( im_out = lo_out im_base = '' im_field = 'class_text' im_val = lv_val ).
    add_field( im_out = lo_out im_base = '' im_field = 'long_text' im_val = lv_long ).
    IF lv_text CA '&'.
      lo_out->set( iv_path = '/note'
                   iv_val  = 'The & / &1-&4 placeholders are filled at runtime with the values of the actual case.' ).
    ENDIF.
    IF lv_long IS INITIAL.
      lo_out->set( iv_path = '/long_text_note' iv_val = 'This message has no long text.' ).
    ENDIF.

    ex_json = lo_out->stringify( ).

  ENDMETHOD.


  METHOD rank_activities.
*&---------------------------------------------------------------------*
*& Standard activities first: one whose ID names the transaction
*& (SIMG_CFMENUOLSDVOV8 for VOV8), then the core IMG (SIMG*), then
*& other activities - industry solutions often have no namespace, e.g.
*& ISH_* - and last add-ons with a namespace (/XYZ/). Each group keeps
*& the order it came in.
*&---------------------------------------------------------------------*

    DATA lv_act  TYPE cus_img_ac.
    DATA lv_pass TYPE i.
    DATA lv_grp  TYPE i.

    DO 4 TIMES.
      lv_pass = sy-index.
      LOOP AT im_list INTO lv_act.
        IF im_hint IS NOT INITIAL AND lv_act CS im_hint.
          lv_grp = 1.
        ELSEIF lv_act CP 'SIMG*'.
          lv_grp = 2.
        ELSEIF lv_act(1) <> '/'.
          lv_grp = 3.
        ELSE.
          lv_grp = 4.
        ENDIF.
        IF lv_grp = lv_pass.
          APPEND lv_act TO ex_list.
        ENDIF.
      ENDLOOP.
    ENDDO.

  ENDMETHOD.


  METHOD read_config.
*&---------------------------------------------------------------------*
*& Rows of one configuration table - the SE16 answer to "what is it set
*& to?". Every guard runs before the SELECT, in this order:
*&   name syntax -> exists, is a table (a view names its tables) ->
*&   delivery class C/G/E -> blocklist -> caller's authorization ->
*&   filter / field names exist in the table.
*& The WHERE clause is built only from field names checked against the
*& DDIC and values with their quotes doubled, so input cannot add SQL.
*& The logon client is read; the client field is never returned.
*&---------------------------------------------------------------------*

    TYPES: BEGIN OF lt_text,
             key  TYPE string,
             text TYPE string,
           END OF lt_text.
    TYPES: BEGIN OF lt_cond,
             field TYPE fieldname,
             cond  TYPE string,
           END OF lt_cond.

    DATA lo_in     TYPE REF TO zif_ajson.
    DATA lo_out    TYPE REF TO zcl_ajson.
    DATA lv_str    TYPE string.
    DATA lv_msg    TYPE string.
    DATA lv_tab    TYPE tabname.
    DATA lv_ddname TYPE ddobjname.
    DATA lv_class  TYPE tabclass.
    DATA lv_cont   TYPE contflag.
    DATA lv_clidep TYPE clidep.
    DATA lv_ddtext TYPE as4text.
    DATA lv_ok     TYPE abap_bool.
    DATA lv_group  TYPE brgru.
    DATA lv_val    TYPE string.
    DATA lv_name   TYPE string.
    DATA lv_path   TYPE string.
    DATA lv_field  TYPE string.
    DATA lv_op     TYPE string.
    DATA lv_cond   TYPE string.
    DATA lv_where  TYPE string.
    DATA lv_max    TYPE i.
    DATA lv_total  TYPE i.
    DATA lv_ret    TYPE i.
    DATA lv_idx    TYPE i.
    DATA lv_chars  TYPE i.
    DATA lv_cnt    TYPE i.
    DATA lv_cut    TYPE abap_bool.
    DATA lv_i      TYPE string.
    DATA lv_base   TYPE string.
    DATA lv_key    TYPE string.
    DATA li_tabs   TYPE string_table.
    DATA li_mem    TYPE string_table.
    DATA lv_mem    TYPE string.
    DATA li_want   TYPE STANDARD TABLE OF fieldname.
    DATA li_dfies  TYPE t_dfies.
    DATA lw_dfies  TYPE dfies.
    DATA li_conds  TYPE STANDARD TABLE OF lt_cond.
    DATA lw_cond   TYPE lt_cond.
    DATA lr_rows   TYPE REF TO data.

*   text table
    DATA lv_txttab TYPE tabname.
    DATA lv_tlang  TYPE fieldname.
    DATA lv_tfield TYPE fieldname.
    DATA lv_twhere TYPE string.
    DATA li_tdfies TYPE t_dfies.
    DATA li_keys   TYPE string_table.
    DATA lv_kname  TYPE string.
    DATA lr_texts  TYPE REF TO data.
    DATA li_texts  TYPE SORTED TABLE OF lt_text WITH UNIQUE KEY key.
    DATA lw_text   TYPE lt_text.

    FIELD-SYMBOLS <lf_rows> TYPE STANDARD TABLE.
    FIELD-SYMBOLS <lf_row>  TYPE any.
    FIELD-SYMBOLS <lf_val>  TYPE any.
    FIELD-SYMBOLS <lf_trows> TYPE STANDARD TABLE.

    lo_in = zcl_ajson=>parse( im_input ).

*   ---- which table ----------------------------------------------------
    lv_str = lo_in->get( '/table' ).
    TRANSLATE lv_str TO UPPER CASE.
    CONDENSE lv_str.
    IF lv_str IS INITIAL OR strlen( lv_str ) > 30
       OR lv_str CN 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_/'.
      ex_json = error_json( im_msg = 'table is required: a DDIC table name such as T001W.' ).
      RETURN.
    ENDIF.
    lv_tab = lv_str.

    SELECT SINGLE tabclass contflag clidep FROM dd02l
      INTO (lv_class, lv_cont, lv_clidep)
      WHERE tabname = lv_tab AND as4local = 'A'.
    IF sy-subrc <> 0.
      CONCATENATE 'Table' lv_str 'does not exist in this system.' INTO lv_msg SEPARATED BY space.
      ex_json = error_json( im_msg = lv_msg ).
      RETURN.
    ENDIF.

*   a maintenance view has no rows of its own - point at its tables
    IF lv_class = 'VIEW'.
      li_tabs = view_tables( im_view = lv_str ).
      CONCATENATE LINES OF li_tabs INTO lv_val SEPARATED BY `, `.
      CONCATENATE lv_str ` is a view. Read its tables instead: ` lv_val '.' INTO lv_msg.
      ex_json = error_json( im_msg = lv_msg ).
      RETURN.
    ENDIF.
    IF lv_class <> 'TRANSP' AND lv_class <> 'POOL' AND lv_class <> 'CLUSTER'.
      CONCATENATE lv_str ' is a structure (' lv_class '), it holds no rows.' INTO lv_msg.
      ex_json = error_json( im_msg = lv_msg ).
      RETURN.
    ENDIF.

*   configuration only: C customizing, G customizing protected against
*   SAP upgrade, E customer/SAP shared key areas
    IF lv_cont <> 'C' AND lv_cont <> 'G' AND lv_cont <> 'E'.
      CONCATENATE `Refused. ` lv_str ` has delivery class ` lv_cont
                  ' - only configuration tables (delivery class C, G or E) can be read.'
                  ' Application and system data stay in SE16 under your own authorization.'
        INTO lv_msg.
      ex_json = error_json( im_msg = lv_msg ).
      RETURN.
    ENDIF.

    lv_ddname = lv_tab.
    CALL FUNCTION 'DDIF_FIELDINFO_GET'
      EXPORTING
        tabname        = lv_ddname
      TABLES
        dfies_tab      = li_dfies
      EXCEPTIONS
        not_found      = 1
        internal_error = 2
        OTHERS         = 3.
    IF sy-subrc <> 0 OR li_dfies IS INITIAL.
      ex_json = error_json( im_msg = 'Field list of the table could not be read.' ).
      RETURN.
    ENDIF.

    lv_msg = sensitive( im_table = lv_tab im_fields = li_dfies ).
    IF lv_msg IS NOT INITIAL.
      ex_json = error_json( im_msg = lv_msg ).
      RETURN.
    ENDIF.

    auth_ok( EXPORTING im_table = lv_tab
             IMPORTING ex_ok    = lv_ok
                       ex_group = lv_group ).
    IF lv_ok = abap_false.
      CONCATENATE `No authorization to display ` lv_str
                  `: you need S_TABU_DIS for authorization group ` lv_group
                  ' or S_TABU_NAM for the table, both with activity 03.'
        INTO lv_msg.
      ex_json = error_json( im_msg = lv_msg ).
      RETURN.
    ENDIF.

*   ---- filters -> WHERE ------------------------------------------------
    li_mem = lo_in->members( '/filters' ).
    LOOP AT li_mem INTO lv_mem.
      lv_field = lv_mem.
      TRANSLATE lv_field TO UPPER CASE.
      CONDENSE lv_field.
      READ TABLE li_dfies INTO lw_dfies WITH KEY fieldname = lv_field.
      IF sy-subrc <> 0.
        CONCATENATE `Field ` lv_field ` is not in table ` lv_str
                    '. sap_get_ddic lists its fields.' INTO lv_msg.
        ex_json = error_json( im_msg = lv_msg ).
        RETURN.
      ENDIF.
*     the client is always the logon client
      IF lw_dfies-datatype = 'CLNT'.
        CONTINUE.
      ENDIF.
      CONCATENATE '/filters/' lv_mem INTO lv_path.
      lv_val = lo_in->get( lv_path ).
      IF lv_val CA '*'.
        lv_op = 'LIKE'.
        TRANSLATE lv_val USING '*%'.
      ELSE.
        lv_op = '='.
*       as typed in the SAP GUI: OR finds order type TA
        lv_val = conv_value( im_table = lv_tab im_field = lw_dfies
                             im_value = lv_val im_dir   = 'I' ).
      ENDIF.
      REPLACE ALL OCCURRENCES OF `'` IN lv_val WITH `''`.
      CONCATENATE lv_field ` ` lv_op ` '` lv_val `'` INTO lv_cond.
      IF lv_where IS INITIAL.
        lv_where = lv_cond.
      ELSE.
        CONCATENATE lv_where ` AND ` lv_cond INTO lv_where.
      ENDIF.
      lw_cond-field = lv_field.
      lw_cond-cond  = lv_cond.
      APPEND lw_cond TO li_conds.
    ENDLOOP.

*   ---- fields to return --------------------------------------------------
    li_mem = lo_in->members( '/fields' ).
    LOOP AT li_mem INTO lv_mem.
      CONCATENATE '/fields/' lv_mem INTO lv_path.
      lv_field = lo_in->get( lv_path ).
      TRANSLATE lv_field TO UPPER CASE.
      CONDENSE lv_field.
      READ TABLE li_dfies TRANSPORTING NO FIELDS WITH KEY fieldname = lv_field.
      IF sy-subrc <> 0.
        CONCATENATE `Field ` lv_field ` is not in table ` lv_str
                    '. sap_get_ddic lists its fields.' INTO lv_msg.
        ex_json = error_json( im_msg = lv_msg ).
        RETURN.
      ENDIF.
      APPEND lv_field TO li_want.
    ENDLOOP.

    lv_max = lo_in->get_integer( '/max_rows' ).
    IF lv_max <= 0.
      lv_max = c_def_rows.
    ENDIF.
    IF lv_max > c_max_rows.
      lv_max = c_max_rows.
    ENDIF.

*   ---- the rows ------------------------------------------------------------
    CREATE DATA lr_rows TYPE STANDARD TABLE OF (lv_tab).
    ASSIGN lr_rows->* TO <lf_rows>.

    SELECT COUNT(*) FROM (lv_tab) INTO lv_total WHERE (lv_where).
    SELECT * FROM (lv_tab) INTO TABLE <lf_rows> UP TO lv_max ROWS
      WHERE (lv_where)
      ORDER BY PRIMARY KEY.

*   ---- descriptions from the text table --------------------------------
*   The text table points at this table with a TEXT foreign key. It
*   shares this table's key plus a language field; its first non-key
*   character field is the description.
    SELECT SINGLE tabname FROM dd08l INTO lv_txttab
      WHERE checktable = lv_tab AND frkart = 'TEXT' AND as4local = 'A'.
    IF sy-subrc = 0 AND <lf_rows> IS NOT INITIAL.
      auth_ok( EXPORTING im_table = lv_txttab
               IMPORTING ex_ok    = lv_ok
                         ex_group = lv_group ).
      lv_ddname = lv_txttab.
      CLEAR li_tdfies.
      IF lv_ok = abap_true.
        CALL FUNCTION 'DDIF_FIELDINFO_GET'
          EXPORTING
            tabname        = lv_ddname
          TABLES
            dfies_tab      = li_tdfies
          EXCEPTIONS
            not_found      = 1
            internal_error = 2
            OTHERS         = 3.
        IF sy-subrc <> 0.
          CLEAR li_tdfies.
        ENDIF.
      ENDIF.

      LOOP AT li_tdfies INTO lw_dfies.
        IF lw_dfies-keyflag = abap_true AND lw_dfies-datatype = 'LANG'.
          lv_tlang = lw_dfies-fieldname.
        ELSEIF lw_dfies-keyflag = abap_false AND lw_dfies-inttype = 'C' AND lv_tfield IS INITIAL.
          lv_tfield = lw_dfies-fieldname.
        ENDIF.
      ENDLOOP.
*     the keys both tables share, without the client
      LOOP AT li_dfies INTO lw_dfies WHERE keyflag = abap_true AND datatype <> 'CLNT'.
        READ TABLE li_tdfies TRANSPORTING NO FIELDS
          WITH KEY fieldname = lw_dfies-fieldname keyflag = abap_true.
        IF sy-subrc = 0.
          lv_kname = lw_dfies-fieldname.
          APPEND lv_kname TO li_keys.
        ENDIF.
      ENDLOOP.

      IF lv_tlang IS NOT INITIAL AND lv_tfield IS NOT INITIAL AND li_keys IS NOT INITIAL.
        CONCATENATE lv_tlang ` = '` sy-langu `'` INTO lv_twhere.
        LOOP AT li_conds INTO lw_cond.
          lv_kname = lw_cond-field.
          READ TABLE li_keys TRANSPORTING NO FIELDS WITH KEY table_line = lv_kname.
          IF sy-subrc = 0.
            CONCATENATE lv_twhere ` AND ` lw_cond-cond INTO lv_twhere.
          ENDIF.
        ENDLOOP.

        CREATE DATA lr_texts TYPE STANDARD TABLE OF (lv_txttab).
        ASSIGN lr_texts->* TO <lf_trows>.
        SELECT * FROM (lv_txttab) INTO TABLE <lf_trows> UP TO c_max_texts ROWS
          WHERE (lv_twhere).
        LOOP AT <lf_trows> ASSIGNING <lf_row>.
          lw_text-key = row_key( im_row = <lf_row> im_keys = li_keys ).
          ASSIGN COMPONENT lv_tfield OF STRUCTURE <lf_row> TO <lf_val>.
          IF sy-subrc = 0.
            lw_text-text = <lf_val>.
            INSERT lw_text INTO TABLE li_texts.
          ENDIF.
        ENDLOOP.
        FREE <lf_trows>.
      ELSE.
        CLEAR lv_txttab.
      ENDIF.
    ELSE.
      CLEAR lv_txttab.
    ENDIF.

*   ---- answer ----------------------------------------------------------------
    lo_out = zcl_ajson=>create_empty( ).
    lo_out->set( iv_path = '/table' iv_val = lv_str ).
    SELECT SINGLE ddtext FROM dd02t INTO lv_ddtext
      WHERE tabname = lv_tab AND ddlanguage = sy-langu AND as4local = 'A'.
    lv_val = lv_ddtext.
    add_field( im_out = lo_out im_base = '' im_field = 'description' im_val = lv_val ).
    lv_val = lv_cont.
    add_field( im_out = lo_out im_base = '' im_field = 'delivery_class' im_val = lv_val ).
    IF lv_clidep = abap_true.
      lv_val = sy-mandt.
      add_field( im_out = lo_out im_base = '' im_field = 'client' im_val = lv_val ).
    ENDIF.
    lv_val = lv_txttab.
    add_field( im_out = lo_out im_base = '' im_field = 'text_table' im_val = lv_val ).
    lo_out->set_integer( iv_path = '/count' iv_val = lv_total ).
    lo_out->touch_array( '/rows' ).

    LOOP AT <lf_rows> ASSIGNING <lf_row>.
      lv_idx = sy-tabix.
      lv_i = lv_idx.
      CONDENSE lv_i.
      CONCATENATE '/rows/' lv_i INTO lv_base.
      lv_cnt = 0.
      LOOP AT li_dfies INTO lw_dfies.
        IF lw_dfies-datatype = 'CLNT'.
          CONTINUE.
        ENDIF.
        IF li_want IS NOT INITIAL.
          READ TABLE li_want TRANSPORTING NO FIELDS WITH KEY table_line = lw_dfies-fieldname.
          IF sy-subrc <> 0.
            CONTINUE.
          ENDIF.
        ENDIF.
        ASSIGN COMPONENT lw_dfies-fieldname OF STRUCTURE <lf_row> TO <lf_val>.
        IF sy-subrc <> 0.
          CONTINUE.
        ENDIF.
        IF <lf_val> IS INITIAL.
          CONTINUE.
        ENDIF.
        lv_val = <lf_val>.
*       numbers arrive right-aligned
        IF lw_dfies-inttype = 'P' OR lw_dfies-inttype = 'I' OR lw_dfies-inttype = 'F'
           OR lw_dfies-inttype = 'b' OR lw_dfies-inttype = 's'.
          CONDENSE lv_val.
        ENDIF.
*       as the SAP GUI shows it
        lv_val = conv_value( im_table = lv_tab im_field = lw_dfies
                             im_value = lv_val im_dir   = 'O' ).
*       '/' separates JSON path segments: /ABC/FIELD becomes :ABC:FIELD
        lv_name = lw_dfies-fieldname.
        TRANSLATE lv_name USING '/:'.
        add_field( im_out = lo_out im_base = lv_base im_field = lv_name im_val = lv_val ).
        lv_cnt = lv_cnt + 1.
        lv_chars = lv_chars + strlen( lv_name ) + strlen( lv_val ) + 6.
      ENDLOOP.

*     a row with every field empty still needs its place in the array
      IF lv_cnt = 0.
        add_field( im_out = lo_out im_base = lv_base im_field = '_empty' im_val = 'all fields empty' ).
      ENDIF.

      IF li_texts IS NOT INITIAL.
        lv_key = row_key( im_row = <lf_row> im_keys = li_keys ).
        READ TABLE li_texts INTO lw_text WITH TABLE KEY key = lv_key.
        IF sy-subrc = 0.
          add_field( im_out = lo_out im_base = lv_base im_field = '_text' im_val = lw_text-text ).
          lv_chars = lv_chars + strlen( lw_text-text ) + 10.
        ENDIF.
      ENDIF.

      lv_ret = lv_idx.
      IF lv_chars > c_max_chars.
        lv_cut = abap_true.
        EXIT.
      ENDIF.
    ENDLOOP.
    lo_out->set_integer( iv_path = '/returned' iv_val = lv_ret ).

    IF lv_cut = abap_true.
      lo_out->set( iv_path = '/note'
                   iv_val  = 'Answer size limit reached. Ask for fewer fields, or narrow with filters.' ).
    ELSEIF lv_total > lv_ret.
      lo_out->set( iv_path = '/note'
                   iv_val  = 'More rows matched than were returned. Narrow with filters, or raise max_rows (at most 200).' ).
    ELSEIF lv_total = 0.
      lo_out->set( iv_path = '/note'
                   iv_val  = 'No rows match. Check the filter values - they compare as stored, e.g. with leading zeros.' ).
    ENDIF.

    ex_json = lo_out->stringify( ).

  ENDMETHOD.


  METHOD row_key.
*&---------------------------------------------------------------------*
*& Key values of one row joined with '|' - matches a row of the table
*& to its row in the text table.
*&---------------------------------------------------------------------*

    DATA lv_name TYPE string.
    DATA lv_val  TYPE string.

    FIELD-SYMBOLS <lf_val> TYPE any.

    LOOP AT im_keys INTO lv_name.
      ASSIGN COMPONENT lv_name OF STRUCTURE im_row TO <lf_val>.
      IF sy-subrc = 0.
        lv_val = <lf_val>.
      ELSE.
        CLEAR lv_val.
      ENDIF.
      CONCATENATE ex_key '|' lv_val INTO ex_key.
    ENDLOOP.

  ENDMETHOD.


  METHOD sensitive.
*&---------------------------------------------------------------------*
*& The hard blocklist: refused even when the caller is authorized,
*& because answers leave SAP and land in a chat. Empty = not blocked.
*&   by name   HR and payroll (PA, PB, PCL, HRP, HRT, T5), user master
*&             (USR, UST, USH), RFC destinations (RFCDES)
*&   by field  bank account, IBAN, card number, password
*&---------------------------------------------------------------------*

    DATA li_pref  TYPE string_table.
    DATA lv_pref  TYPE string.
    DATA lw_field TYPE dfies.

    APPEND 'PA*'     TO li_pref.
    APPEND 'PB*'     TO li_pref.
    APPEND 'PCL*'    TO li_pref.
    APPEND 'HRP*'    TO li_pref.
    APPEND 'HRT*'    TO li_pref.
    APPEND 'T5*'     TO li_pref.
    APPEND 'USR*'    TO li_pref.
    APPEND 'UST*'    TO li_pref.
    APPEND 'USH*'    TO li_pref.
    APPEND 'RFCDES*' TO li_pref.

    LOOP AT li_pref INTO lv_pref.
      IF im_table CP lv_pref.
        CONCATENATE `Refused. ` im_table
                    ' belongs to HR, payroll, user or RFC data, which these tools never read.'
          INTO ex_reason.
        RETURN.
      ENDIF.
    ENDLOOP.

    LOOP AT im_fields INTO lw_field.
      IF lw_field-fieldname = 'BANKN' OR lw_field-fieldname = 'IBAN'
         OR lw_field-fieldname = 'CCNUM'
         OR lw_field-rollname CP 'BANKN*' OR lw_field-rollname CP '*IBAN*'
         OR lw_field-rollname CP 'CCNUM*' OR lw_field-rollname CP '*PASSW*'
         OR lw_field-rollname CP '*PWD*'.
        CONCATENATE `Refused. ` im_table ` holds bank, card or password data (field `
                    lw_field-fieldname '), which these tools never read.'
          INTO ex_reason.
        RETURN.
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD spro_paths.
*&---------------------------------------------------------------------*
*& Where an IMG activity sits in SPRO: TNODEIMGR links tree nodes to the
*& activity, CLIMB walks each one up to the top. Paths that end in the
*& SAP Reference IMG (the SPRO root) come first, the shortest of them
*& first - usually the core application rather than an industry copy.
*& Single-step paths come from flat helper trees and are dropped.
*&---------------------------------------------------------------------*

    TYPES: BEGIN OF lt_cand,
             spro  TYPE i,
             core  TYPE i,
             steps TYPE i,
             path  TYPE string,
           END OF lt_cand.

    DATA li_ref   TYPE STANDARD TABLE OF hier_guid.
    DATA lv_ref   TYPE hier_guid.
    DATA lv_robj  TYPE hier_robje.
    DATA lv_tree  TYPE hier_guid.
    DATA lv_root  TYPE zabapmcp_cfg-cfg_value.
    DATA lv_id    TYPE hier_treeg.
    DATA lv_path  TYPE string.
    DATA lv_spro  TYPE abap_bool.
    DATA li_cand  TYPE STANDARD TABLE OF lt_cand.
    DATA lw_cand  TYPE lt_cand.
    DATA li_steps TYPE string_table.
    DATA lv_area  TYPE string.

*   the SPRO root: SAP's Reference IMG unless ZABAPMCP_CFG says otherwise
    SELECT SINGLE cfg_value FROM zabapmcp_cfg INTO lv_root
      WHERE cfg_key = 'SPRO_TREE'.
    IF sy-subrc <> 0 OR lv_root IS INITIAL.
      lv_root = c_spro_root.
    ENDIF.
    lv_id = lv_root.
    CLEAR gv_spro_tree.
    SELECT SINGLE tree_id FROM ttree INTO gv_spro_tree WHERE id = lv_id.
    IF gv_spro_tree IS INITIAL.
      gv_spro_tree = lv_id.
    ENDIF.
    gv_budget = c_path_budget.

    CLEAR: ex_paths, ex_core.
    lv_robj = im_activity.
    SELECT node_id FROM tnodeimgr INTO TABLE li_ref
      UP TO 20 ROWS
      WHERE ref_object = lv_robj.

    LOOP AT li_ref INTO lv_ref.
      SELECT SINGLE tree_id FROM tnodeimg INTO lv_tree WHERE node_id = lv_ref.
      IF sy-subrc <> 0.
        CONTINUE.
      ENDIF.
      climb( EXPORTING im_tree  = lv_tree
                       im_node  = lv_ref
                       im_depth = 0
             IMPORTING ex_path  = lv_path
                       ex_spro  = lv_spro ).
      IF lv_path CS ` > `.
        CLEAR lw_cand.
        IF lv_spro = abap_true.
          lw_cand-spro = 0.
        ELSE.
          lw_cand-spro = 1.
        ENDIF.
        FIND ALL OCCURRENCES OF ` > ` IN lv_path MATCH COUNT lw_cand-steps.
*       industry solutions after the core applications (2nd level)
        SPLIT lv_path AT ` > ` INTO TABLE li_steps.
        CLEAR lv_area.
        READ TABLE li_steps INTO lv_area INDEX 2.
        IF lv_area CP 'Industry*' OR lv_area CP 'SAP *' OR lv_area CP 'IS-*'.
          lw_cand-core = 1.
        ENDIF.
        lw_cand-path = lv_path.
        APPEND lw_cand TO li_cand.
      ENDIF.
    ENDLOOP.

    SORT li_cand BY spro core steps path.
    DELETE ADJACENT DUPLICATES FROM li_cand COMPARING path.
*   core: the best path ends at the SPRO root in a core application
    READ TABLE li_cand INTO lw_cand INDEX 1.
    IF sy-subrc = 0 AND lw_cand-spro = 0 AND lw_cand-core = 0.
      ex_core = abap_true.
    ENDIF.
    LOOP AT li_cand INTO lw_cand.
      APPEND lw_cand-path TO ex_paths.
      IF lines( ex_paths ) >= c_max_paths.
        EXIT.
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD tcode_info.
*&---------------------------------------------------------------------*
*& One transaction: TSTC (program, screen), TSTCT (text), TADIR
*& (package), TSTCA (authorization values), TSTCP (parameters - this is
*& how OVA8 turns out to be SM30 on a view) and the IMG activities that
*& start it or maintain its view.
*&---------------------------------------------------------------------*

    DATA lo_in     TYPE REF TO zif_ajson.
    DATA lo_out    TYPE REF TO zcl_ajson.
    DATA lv_str    TYPE string.
    DATA lv_msg    TYPE string.
    DATA lv_tcode  TYPE tcode.
    DATA lw_tstc   TYPE tstc.
    DATA lv_ttext  TYPE ttext_stct.
    DATA lv_param  TYPE tcdparam.
    DATA lv_pkg    TYPE devclass.
    DATA lv_val    TYPE string.
    DATA lv_rest   TYPE string.
    DATA lv_target TYPE string.
    DATA lv_view   TYPE string.
    DATA lv_off    TYPE i.
    DATA lv_idx    TYPE i.
    DATA lv_i      TYPE string.
    DATA lv_base   TYPE string.
    DATA li_tabs   TYPE string_table.
    DATA li_tstca  TYPE STANDARD TABLE OF tstca.
    DATA lw_tstca  TYPE tstca.
    DATA li_act    TYPE t_activities.
    DATA li_more   TYPE t_activities.
    DATA lv_act    TYPE cus_img_ac.

    lo_in = zcl_ajson=>parse( im_input ).
    lv_str = lo_in->get( '/tcode' ).
    TRANSLATE lv_str TO UPPER CASE.
    CONDENSE lv_str.
    IF lv_str IS INITIAL OR strlen( lv_str ) > 20.
      ex_json = error_json( im_msg = 'tcode is required, e.g. OVA8 or VA01.' ).
      RETURN.
    ENDIF.
    lv_tcode = lv_str.

    SELECT SINGLE * FROM tstc INTO lw_tstc WHERE tcode = lv_tcode.
    IF sy-subrc <> 0.
      CONCATENATE 'Transaction' lv_str 'does not exist in this system.'
        INTO lv_msg SEPARATED BY space.
      ex_json = error_json( im_msg = lv_msg ).
      RETURN.
    ENDIF.

    lo_out = zcl_ajson=>create_empty( ).
    lo_out->set( iv_path = '/tcode' iv_val = lv_str ).

*   text in the logon language, English when it has none
    SELECT SINGLE ttext FROM tstct INTO lv_ttext
      WHERE sprsl = sy-langu AND tcode = lv_tcode.
    IF sy-subrc <> 0.
      SELECT SINGLE ttext FROM tstct INTO lv_ttext
        WHERE sprsl = 'E' AND tcode = lv_tcode.
    ENDIF.
    lv_val = lv_ttext.
    add_field( im_out = lo_out im_base = '' im_field = 'text' im_val = lv_val ).

    lv_val = lw_tstc-pgmna.
    add_field( im_out = lo_out im_base = '' im_field = 'program' im_val = lv_val ).
    IF lw_tstc-dypno IS NOT INITIAL.
      lv_val = lw_tstc-dypno.
      add_field( im_out = lo_out im_base = '' im_field = 'screen' im_val = lv_val ).
    ENDIF.

    SELECT SINGLE devclass FROM tadir INTO lv_pkg
      WHERE pgmid = 'R3TR' AND object = 'TRAN' AND obj_name = lv_tcode.
    lv_val = lv_pkg.
    add_field( im_out = lo_out im_base = '' im_field = 'package' im_val = lv_val ).

*   A parameter transaction calls another transaction with preset
*   values: '/*SM30 VIEWNAME=V_T001W;UPDATE=X;' - '/*' or '/N' skips
*   the first screen. The view is what the consultant really wants.
    SELECT SINGLE param FROM tstcp INTO lv_param WHERE tcode = lv_tcode.
    IF sy-subrc = 0.
      lv_val = lv_param.
      add_field( im_out = lo_out im_base = '' im_field = 'parameters' im_val = lv_val ).
      IF strlen( lv_val ) > 2.
        IF lv_val(2) = '/*' OR lv_val(2) = '/N'.
          lv_rest = lv_val+2.
          SPLIT lv_rest AT space INTO lv_target lv_rest.
          add_field( im_out = lo_out im_base = '' im_field = 'calls_tcode' im_val = lv_target ).
        ENDIF.
      ENDIF.
      FIND 'VIEWNAME=' IN lv_val MATCH OFFSET lv_off.
      IF sy-subrc = 0.
        lv_off = lv_off + 9.
        lv_rest = lv_val+lv_off.
        SPLIT lv_rest AT ';' INTO lv_view lv_rest.
        CONDENSE lv_view.
*       TSTCP keeps the view as typed in SE93, e.g. V_T691f for OVA8
        TRANSLATE lv_view TO UPPER CASE.
        add_field( im_out = lo_out im_base = '' im_field = 'view' im_val = lv_view ).
        li_tabs = view_tables( im_view = lv_view ).
        IF li_tabs IS NOT INITIAL.
          add_list( im_out = lo_out im_path = '/view_tables' im_list = li_tabs ).
        ENDIF.
      ENDIF.
    ENDIF.

*   authorization values the transaction checks on start (SE93)
    SELECT * FROM tstca INTO TABLE li_tstca WHERE tcode = lv_tcode.
    IF li_tstca IS NOT INITIAL.
      lo_out->touch_array( '/authorizations' ).
      LOOP AT li_tstca INTO lw_tstca.
        lv_i = sy-tabix.
        CONDENSE lv_i.
        CONCATENATE '/authorizations/' lv_i INTO lv_base.
        lv_val = lw_tstca-objct.
        add_field( im_out = lo_out im_base = lv_base im_field = 'object' im_val = lv_val ).
        lv_val = lw_tstca-field.
        add_field( im_out = lo_out im_base = lv_base im_field = 'field' im_val = lv_val ).
        lv_val = lw_tstca-value.
        add_field( im_out = lo_out im_base = lv_base im_field = 'value' im_val = lv_val ).
      ENDLOOP.
    ENDIF.

*   IMG activities that run this transaction, or maintain its view
    SELECT activity FROM cus_imgach INTO TABLE li_act WHERE tcode = lv_tcode.
    IF lv_view IS NOT INITIAL.
      li_more = activities_for_object( im_object = lv_view ).
      APPEND LINES OF li_more TO li_act.
    ENDIF.
*   activities that name this transaction as a customizing object - only
*   those whose ID carries the code (SIMG_CFMENUSAPCOX18 for OX18); the
*   rest just mention it (VA01 in /IRM/ activities)
    li_more = activities_for_object( im_object = lv_str ).
    LOOP AT li_more INTO lv_act.
      IF lv_act CS lv_str.
        APPEND lv_act TO li_act.
      ENDIF.
    ENDLOOP.
    SORT li_act.
    DELETE ADJACENT DUPLICATES FROM li_act.
    li_act = rank_activities( im_list = li_act im_hint = lv_str ).
    li_act = core_first( li_act ).

    lo_out->touch_array( '/img_activities' ).
    LOOP AT li_act INTO lv_act.
      lv_idx = sy-tabix.
      IF lv_idx > c_def_hits.
        lo_out->set( iv_path = '/note'
                     iv_val  = 'More IMG activities use this transaction - sap_find_config lists them.' ).
        EXIT.
      ENDIF.
      lv_i = lv_idx.
      CONDENSE lv_i.
      CONCATENATE '/img_activities/' lv_i INTO lv_base.
      IF lv_idx <= c_path_hits.
        add_activity( im_out = lo_out im_base = lv_base im_activity = lv_act im_paths = abap_true ).
      ELSE.
        add_activity( im_out = lo_out im_base = lv_base im_activity = lv_act ).
      ENDIF.
    ENDLOOP.

    ex_json = lo_out->stringify( ).

  ENDMETHOD.


  METHOD view_tables.
*&---------------------------------------------------------------------*
*& Base tables of a view, primary table first (DD26S).
*&---------------------------------------------------------------------*

    TYPES: BEGIN OF lt_base,
             tabname TYPE vibastab,
             tabpos  TYPE mcpos,
           END OF lt_base.

    DATA li_base TYPE STANDARD TABLE OF lt_base.
    DATA lw_base TYPE lt_base.
    DATA lv_tab  TYPE string.
    DATA lv_view TYPE viewname.

    lv_view = im_view.
    SELECT tabname tabpos FROM dd26s INTO TABLE li_base
      WHERE viewname = lv_view AND as4local = 'A'.
    SORT li_base BY tabpos.

    LOOP AT li_base INTO lw_base.
      lv_tab = lw_base-tabname.
      APPEND lv_tab TO ex_tabs.
    ENDLOOP.

  ENDMETHOD.


ENDCLASS.
