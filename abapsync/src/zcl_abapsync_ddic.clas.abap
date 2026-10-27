CLASS zcl_abapsync_ddic DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.
*--------------------------------------------------------------------*
* Title       : ZCL_ABAPSYNC_DDIC - abapsync for dictionary objects
* Type        : Class (called by the abapsync read and write nodes)
* Frequency   : On demand - one call per 'abapsync pull' / 'push'
* Description : Tables/structures (TABL), data elements (DTEL) and
*               domains (DOMA) for abapsync. They have no source text,
*               so the definition travels as JSON: pull exports it
*               (DDIC_TEXT), push saves it inactive and mass-activates
*               it (RUN) - the route abapGit takes on this system.
*--------------------------------------------------------------------*

    TYPES t_dd03p_tab TYPE STANDARD TABLE OF dd03p WITH DEFAULT KEY.
    TYPES t_dd05m_tab TYPE STANDARD TABLE OF dd05m WITH DEFAULT KEY.
    TYPES t_dd08v_tab TYPE STANDARD TABLE OF dd08v WITH DEFAULT KEY.
    TYPES t_dd12v_tab TYPE STANDARD TABLE OF dd12v WITH DEFAULT KEY.
    TYPES t_dd17v_tab TYPE STANDARD TABLE OF dd17v WITH DEFAULT KEY.
    TYPES t_dd35v_tab TYPE STANDARD TABLE OF dd35v WITH DEFAULT KEY.
    TYPES t_dd36m_tab TYPE STANDARD TABLE OF dd36m WITH DEFAULT KEY.
    TYPES t_dd07v_tab TYPE STANDARD TABLE OF dd07v WITH DEFAULT KEY.

    "The file: one table or structure
    TYPES: BEGIN OF t_tabl,
             dd02v TYPE dd02v,
             dd09l TYPE dd09l,
             dd03p TYPE t_dd03p_tab,
             dd05m TYPE t_dd05m_tab,
             dd08v TYPE t_dd08v_tab,
             dd12v TYPE t_dd12v_tab,
             dd17v TYPE t_dd17v_tab,
             dd35v TYPE t_dd35v_tab,
             dd36m TYPE t_dd36m_tab,
           END OF t_tabl.

    "The file: one data element
    TYPES: BEGIN OF t_dtel,
             dd04v TYPE dd04v,
           END OF t_dtel.

    "The file: one domain with its fixed values
    TYPES: BEGIN OF t_doma,
             dd01v TYPE dd01v,
             dd07v TYPE t_dd07v_tab,
           END OF t_doma.

    CONSTANTS c_version TYPE string VALUE '1.1.0'.

    "Object types this class handles: TABL, DTEL, DOMA. The write node
    "asks this, so a new type here needs no change there.
    CLASS-METHODS is_ddic_type
      IMPORTING im_object     TYPE string
      RETURNING VALUE(ex_yes) TYPE abap_bool.

    "The JSON text of the ACTIVE definition, ending in one LF; '' when
    "there is no active version. Pull writes it, drift is hashed over it.
    CLASS-METHODS ddic_text
      IMPORTING im_object      TYPE string
                im_name        TYPE string
      RETURNING VALUE(ex_text) TYPE string.

    "Entry point of the write node. JSON in, JSON out:
    "  { action: check|write|activate, transport, package, force,
    "    parts: [ { index, object, name, part, expected_hash, source,
    "               create } ] }
    "  -> { results: [ { index, status, message, include, transport,
    "                   new_hash, state } ], messages: [...], error }
    CLASS-METHODS run
      IMPORTING im_request         TYPE string
      RETURNING VALUE(ex_response) TYPE string.

protected section.
*"* protected components of class ZCL_ABAPSYNC_DDIC
*"* do not include other source files here!!!

  PRIVATE SECTION.

    TYPES: BEGIN OF t_part,
             index         TYPE i,
             object        TYPE string,
             name          TYPE string,
             part          TYPE string,
             expected_hash TYPE string,
             source        TYPE string,
             create        TYPE abap_bool,
           END OF t_part,
           t_part_tab TYPE STANDARD TABLE OF t_part WITH DEFAULT KEY.

    TYPES: BEGIN OF t_request,
             action    TYPE string,
             transport TYPE string,
             package   TYPE string,
             force     TYPE abap_bool,
             parts     TYPE t_part_tab,
           END OF t_request.

    TYPES: BEGIN OF t_result,
             index     TYPE i,
             status    TYPE string,   "ok | refused | written | error
             message   TYPE string,
             include   TYPE string,
             transport TYPE string,
             new_hash  TYPE string,
             state     TYPE string,   "A active | I inactive
           END OF t_result,
           t_result_tab TYPE STANDARD TABLE OF t_result WITH DEFAULT KEY.

    TYPES: BEGIN OF t_msg,
             object TYPE string,
             text   TYPE string,
           END OF t_msg,
           t_msg_tab TYPE STANDARD TABLE OF t_msg WITH DEFAULT KEY.

    TYPES: BEGIN OF t_response,
             results  TYPE t_result_tab,
             messages TYPE t_msg_tab,
             error    TYPE string,
           END OF t_response.

    "What the check finds out and the write needs. OBJECT says which of
    "TABL / DTEL / DOMA is filled.
    TYPES: BEGIN OF t_target,
             result     TYPE t_result,
             object     TYPE string,
             name       TYPE ddobjname,
             devclass   TYPE devclass,
             masterlang TYPE sy-langu,
             local      TYPE abap_bool,
             request    TYPE trkorr,
             create     TYPE abap_bool,
             tabl       TYPE t_tabl,
             dtel       TYPE t_dtel,
             doma       TYPE t_doma,
           END OF t_target.

    "Validates one dictionary part of any type (the name is from the
    "table-only first version; methods are never renamed, because push
    "does not delete the old one)
    CLASS-METHODS check_tabl
      IMPORTING im_part          TYPE t_part
                im_request       TYPE t_request
      RETURNING VALUE(ex_target) TYPE t_target.

    CLASS-METHODS write_tabl
      CHANGING ch_target TYPE t_target.

    CLASS-METHODS activate_tabl
      IMPORTING im_parts    TYPE t_part_tab
      EXPORTING ex_results  TYPE t_result_tab
                ex_messages TYPE t_msg_tab.

    "Active definition as DDIF_TABL_GET returns it, uncleaned
    CLASS-METHODS read_tabl
      IMPORTING im_name  TYPE ddobjname
                im_langu TYPE sy-langu
      EXPORTING ex_tabl  TYPE t_tabl
                ex_found TYPE abap_bool.

    "abapGit's serialize cleanup (ZCL_ABAPGIT_OBJECT_TABL)
    CLASS-METHODS normalize
      CHANGING ch_tabl TYPE t_tabl.

    "'' when the change is safe for a table holding data
    CLASS-METHODS risky_change
      IMPORTING im_old        TYPE t_tabl
                im_new        TYPE t_tabl
      RETURNING VALUE(ex_msg) TYPE string.

    CLASS-METHODS has_data
      IMPORTING im_tabl       TYPE t_tabl
      RETURNING VALUE(ex_yes) TYPE abap_bool.

    "Fields the table defines itself: no .INCLUDE content, no nesting
    CLASS-METHODS own_fields
      IMPORTING im_dd03p         TYPE t_dd03p_tab
      RETURNING VALUE(ex_fields) TYPE t_dd03p_tab.

    CLASS-METHODS dtel_type
      IMPORTING im_rollname TYPE rollname
      EXPORTING ex_datatype TYPE dd03p-datatype
                ex_leng     TYPE i
                ex_decimals TYPE i
                ex_found    TYPE abap_bool.

    "JSON writers that leave out every component that is initial for its
    "own ABAP type - ajson's SET only does that at the top level, so a
    "table file would otherwise carry ~70 empty keys per field
    CLASS-METHODS add_struct
      IMPORTING io_json TYPE REF TO zif_ajson
                iv_path TYPE string
                is_data TYPE any
      RAISING   zcx_ajson_error.

    CLASS-METHODS add_table
      IMPORTING io_json TYPE REF TO zif_ajson
                iv_path TYPE string
                it_data TYPE ANY TABLE
      RAISING   zcx_ajson_error.

    CLASS-METHODS masterlang
      IMPORTING im_name        TYPE string
                im_object      TYPE string DEFAULT 'TABL'
      RETURNING VALUE(ex_lang) TYPE sy-langu.

    "--- data elements and domains (1.1.0) ------------------------------

    "Active data element, read from DD04L/DD04T as abapGit does
    "(DDIF_DTEL_GET bypasses the buffer)
    CLASS-METHODS read_dtel
      IMPORTING im_name  TYPE ddobjname
                im_langu TYPE sy-langu
      EXPORTING ex_dtel  TYPE t_dtel
                ex_found TYPE abap_bool.

    CLASS-METHODS read_doma
      IMPORTING im_name  TYPE ddobjname
                im_langu TYPE sy-langu
      EXPORTING ex_doma  TYPE t_doma
                ex_found TYPE abap_bool.

    "abapGit's serialize cleanup for DTEL and DOMA
    CLASS-METHODS normalize_elem
      CHANGING ch_dtel TYPE t_dtel
               ch_doma TYPE t_doma.

    "The type a data element or domain gives a field: a data element
    "with a domain takes the domain's (active) type
    CLASS-METHODS elem_type
      IMPORTING im_object   TYPE string
                im_dtel     TYPE t_dtel
                im_doma     TYPE t_doma
      EXPORTING ex_datatype TYPE dd03p-datatype
                ex_leng     TYPE i
                ex_decimals TYPE i
                ex_found    TYPE abap_bool.

    "Default request + transport entry + TADIR, before any *_PUT
    CLASS-METHODS begin_write
      IMPORTING im_target  TYPE t_target
      EXPORTING ex_saved   TYPE e070use
                ex_message TYPE string.

    CLASS-METHODS write_dtel
      CHANGING ch_target TYPE t_target.

    CLASS-METHODS write_doma
      CHANGING ch_target TYPE t_target.

    "Write order inside one push: domains, data elements, tables
    CLASS-METHODS type_rank
      IMPORTING im_object     TYPE string
      RETURNING VALUE(ex_rank) TYPE i.

ENDCLASS.


CLASS zcl_abapsync_ddic IMPLEMENTATION.

  METHOD activate_tabl.
*&---------------------------------------------------------------------*
    "One mass activation for every dictionary object written, as abapGit activates
    "dictionary objects on this system (ZCL_ABAPGIT_OBJECTS_ACTIVATION->
    "ACTIVATE_DDIC). Its log is read back with TR_READ_LOG, so activation
    "errors reach the developer as text.

    DATA li_gentab  TYPE STANDARD TABLE OF dcgentb.
    DATA lw_gentab  TYPE dcgentb.
    DATA li_deltab  TYPE STANDARD TABLE OF dcdeltb.
    DATA li_action  TYPE STANDARD TABLE OF dctablres.
    DATA li_lines   TYPE STANDARD TABLE OF trlog.
    DATA lw_line    TYPE trlog.
    DATA lv_logname TYPE ddmass-logname.
    DATA lv_logdb   TYPE ddprh-protname.
    DATA lv_rc      TYPE sy-subrc.
    DATA lv_state   TYPE ddgotstate.
    DATA lv_type    TYPE dcgentb-type.
    DATA lv_dname   TYPE dcgentb-name.
    DATA lv_id      TYPE dcgentb-indx.
    DATA lv_text    TYPE string.
    DATA lw_part    TYPE t_part.
    DATA lw_result  TYPE t_result.
    DATA lw_msg     TYPE t_msg.

    CLEAR: ex_results, ex_messages.

    LOOP AT im_parts INTO lw_part.
      CLEAR lw_gentab.
      lw_gentab-tabix = sy-tabix.
      lw_gentab-type  = lw_part-object.
      lw_gentab-name  = lw_part-name.
      APPEND lw_gentab TO li_gentab.
    ENDLOOP.
    IF li_gentab IS INITIAL.
      RETURN.
    ENDIF.

    CONCATENATE 'ABAPSYNC_' sy-datum '_' sy-uzeit INTO lv_logname.

    CALL FUNCTION 'DD_MASS_ACT_C3'
      EXPORTING
        ddmode         = 'O'
        frcact         = abap_true
        medium         = 'T'
        device         = 'T'
        version        = 'M'
        logname        = lv_logname
        write_log      = abap_true
        log_head_tail  = abap_true
        t_on           = space
        prid           = 1
      IMPORTING
        act_rc         = lv_rc
      TABLES
        gentab         = li_gentab
        deltab         = li_deltab
        cnvtab         = li_action
      EXCEPTIONS
        access_failure = 1
        no_objects     = 2
        locked         = 3
        internal_error = 4
        OTHERS         = 5.
    IF sy-subrc <> 0.
      lw_msg-text = zcl_abapsync_write=>sy_message( ).
      CONCATENATE 'DD_MASS_ACT_C3:' lw_msg-text INTO lw_msg-text SEPARATED BY space.
      APPEND lw_msg TO ex_messages.
    ENDIF.

    "--- errors and warnings of the activation log
    IF lv_rc > 0.
      lv_logdb = lv_logname.
      CALL FUNCTION 'TR_READ_LOG'
        EXPORTING
          iv_log_type   = 'DB'
          iv_logname_db = lv_logdb
        TABLES
          et_lines      = li_lines
        EXCEPTIONS
          invalid_input = 1
          access_error  = 2
          OTHERS        = 3.
      IF sy-subrc = 0.
        LOOP AT li_lines INTO lw_line.
          IF lw_line-severity <> 'E' AND lw_line-severity <> 'W'.
            CONTINUE.
          ENDIF.
          "the 'Return code ...' summary line says nothing new
          IF lw_line-class = 'D0' AND lw_line-number = '319'.
            CONTINUE.
          ENDIF.
          CLEAR lw_msg.
          lw_msg-object = lw_line-severity.
          lw_msg-text   = lw_line-line.
          APPEND lw_msg TO ex_messages.
        ENDLOOP.
      ENDIF.
      CLEAR lw_msg.
      CONCATENATE 'Full activation log: program RSPUTPRT, type D, log name' lv_logname
        INTO lw_msg-text SEPARATED BY space.
      APPEND lw_msg TO ex_messages.
    ENDIF.

    "--- the truth is the dictionary: is an inactive version left?
    LOOP AT im_parts INTO lw_part.
      CLEAR: lw_result, lv_state.
      lw_result-index   = lw_part-index.
      lw_result-include = lw_part-name.
      lw_result-status  = 'written'.
      lv_type  = lw_part-object.
      lv_dname = lw_part-name.
      CLEAR lv_id.
      CALL FUNCTION 'DDIF_STATE_GET'
        EXPORTING
          type          = lv_type
          name          = lv_dname
          id            = lv_id
          state         = 'M'
        IMPORTING
          gotstate      = lv_state
        EXCEPTIONS
          illegal_input = 1
          OTHERS        = 2.
      IF sy-subrc = 0 AND ( lv_state IS INITIAL OR lv_state = 'A' ).
        lw_result-state = 'A'.
        lv_text = ddic_text( im_object = lw_part-object im_name = lw_part-name ).
        IF lv_text IS NOT INITIAL.
          lw_result-new_hash = zcl_abapmcp_sync=>hash_text( lv_text ).
        ENDIF.
        IF lw_part-create = abap_true.
          lw_result-message = 'Created and activated.'.
        ELSE.
          lw_result-message = 'Saved and activated.'.
        ENDIF.
      ELSE.
        lw_result-state   = 'I'.
        lw_result-message = 'Saved inactive - activation failed, see activation messages.'.
      ENDIF.
      APPEND lw_result TO ex_results.
    ENDLOOP.

  ENDMETHOD.


  METHOD add_struct.
    "Every component that is not initial for its own type, under IV_PATH,
    "in the structure's own order. Initial is judged by the real ABAP
    "type, so NUMC '0000' and an empty CHAR are both left out, while a
    "CHAR '0' (a real value) stays.

    DATA lo_struct TYPE REF TO cl_abap_structdescr.
    DATA lw_comp   TYPE abap_compdescr.
    DATA lv_name   TYPE string.
    DATA lv_path   TYPE string.

    FIELD-SYMBOLS <lf_val> TYPE any.

    lo_struct ?= cl_abap_typedescr=>describe_by_data( is_data ).
    LOOP AT lo_struct->components INTO lw_comp.
      ASSIGN COMPONENT lw_comp-name OF STRUCTURE is_data TO <lf_val>.
      IF sy-subrc <> 0.
        CONTINUE.
      ENDIF.
      IF <lf_val> IS INITIAL.
        CONTINUE.
      ENDIF.
      lv_name = lw_comp-name.
      TRANSLATE lv_name TO LOWER CASE.
      CONCATENATE iv_path '/' lv_name INTO lv_path.
      io_json->set( iv_path = lv_path iv_val = <lf_val> ).
    ENDLOOP.

  ENDMETHOD.


  METHOD add_table.
    "One array element per row, each written by ADD_STRUCT. An empty table
    "is left out altogether.

    DATA lv_idx  TYPE i.
    DATA lv_i    TYPE string.
    DATA lv_path TYPE string.

    FIELD-SYMBOLS <lf_row> TYPE any.

    IF it_data IS INITIAL.
      RETURN.
    ENDIF.

    io_json->touch_array( iv_path ).
    LOOP AT it_data ASSIGNING <lf_row>.
      lv_idx = lv_idx + 1.
      lv_i = lv_idx.
      CONDENSE lv_i.
      CONCATENATE iv_path '/' lv_i INTO lv_path.
      add_struct( io_json = io_json iv_path = lv_path is_data = <lf_row> ).
    ENDLOOP.

  ENDMETHOD.


  METHOD begin_write.
    "Before any *_PUT: the push request becomes the session default (so
    "the dictionary records into it without a popup, which would dump over
    "HTTP), and the object is recorded in it - which also creates the TADIR
    "entry of a new object (abapGit: CORR_INSERT, object class DICT).

    DATA lv_obj TYPE trobj_name.

    CLEAR: ex_saved, ex_message.

    IF im_target-local = abap_false.
      zcl_abapsync_write=>set_default_request( EXPORTING im_request = im_target-request
                                               IMPORTING ex_saved   = ex_saved
                                                         ex_message = ex_message ).
      IF ex_message IS NOT INITIAL.
        RETURN.
      ENDIF.
    ENDIF.

    CONCATENATE im_target-object im_target-name INTO lv_obj.
    CALL FUNCTION 'RS_CORR_INSERT'
      EXPORTING
        object              = lv_obj
        object_class        = 'DICT'
        devclass            = im_target-devclass
        master_language     = im_target-masterlang
        korrnum             = im_target-request
        mode                = 'I'
        global_lock         = abap_true
        suppress_dialog     = abap_true
      EXCEPTIONS
        cancelled           = 1
        permission_failure  = 2
        unknown_objectclass = 3
        OTHERS              = 4.
    IF sy-subrc <> 0.
      ex_message = zcl_abapsync_write=>sy_message( ).
      CONCATENATE 'Transport:' ex_message INTO ex_message SEPARATED BY space.
    ENDIF.

  ENDMETHOD.


  METHOD check_tabl.
    "One dictionary file - table, data element or domain. Nothing is
    "written here; every rule that can refuse the push is checked now, as
    "for the source parts.

    DATA lv_name    TYPE string.
    DATA lv_part    TYPE string.
    DATA lv_what    TYPE string.
    DATA lv_obj     TYPE sobj_name.
    DATA lv_type    TYPE trobjtype.
    DATA lv_pkg     TYPE devclass.
    DATA lv_msg     TYPE string.
    DATA lv_current TYPE string.
    DATA lv_hash    TYPE string.
    DATA lv_given   TYPE string.
    DATA lv_exists  TYPE abap_bool.
    DATA lv_found   TYPE abap_bool.
    DATA lv_task    TYPE trkorr.
    DATA lo_in      TYPE REF TO zif_ajson.
    DATA lx_json    TYPE REF TO zcx_ajson_error.
    DATA lw_old     TYPE t_tabl.
    DATA lw_odtel   TYPE t_dtel.
    DATA lw_odoma   TYPE t_doma.
    DATA lv_otype   TYPE dd03p-datatype.
    DATA lv_ntype   TYPE dd03p-datatype.
    DATA lv_oleng   TYPE i.
    DATA lv_nleng   TYPE i.
    DATA lv_odec    TYPE i.
    DATA lv_ndec    TYPE i.
    DATA lv_ofound  TYPE abap_bool.
    DATA lv_nfound  TYPE abap_bool.
    DATA lv_num     TYPE string.
    DATA lv_num2    TYPE string.

    ex_target-result-index  = im_part-index.
    ex_target-result-status = 'refused'.
    ex_target-create        = im_part-create.
    ex_target-object        = im_part-object.
    TRANSLATE ex_target-object TO UPPER CASE.
    lv_name = im_part-name.
    TRANSLATE lv_name TO UPPER CASE.
    ex_target-result-include = lv_name.
    lv_part = im_part-part.
    TRANSLATE lv_part TO LOWER CASE.

    "--- what this is
    CASE ex_target-object.
      WHEN 'TABL'.
        lv_what = 'Table'.
      WHEN 'DTEL'.
        lv_what = 'Data element'.
      WHEN 'DOMA'.
        lv_what = 'Domain'.
      WHEN OTHERS.
        ex_target-result-message = 'Only tables (TABL), data elements (DTEL) and domains (DOMA) are handled here.'.
        RETURN.
    ENDCASE.
    IF lv_part <> 'ddic'.
      ex_target-result-message = 'A dictionary object has one part, ddic - its JSON definition.'.
      RETURN.
    ENDIF.
    IF zcl_abapmcp_tools=>check_custom( lv_name ) = abap_false.
      ex_target-result-message = 'Only custom (Z/Y) objects can be changed.'.
      RETURN.
    ENDIF.
    IF strlen( lv_name ) > 30.
      ex_target-result-message = 'A dictionary name is at most 30 characters.'.
      RETURN.
    ENDIF.
    ex_target-name = lv_name.

    "--- the file
    TRY.
        lo_in = zcl_ajson=>parse( im_part-source ).
        CASE ex_target-object.
          WHEN 'TABL'.
            lo_in->to_abap( IMPORTING ev_container = ex_target-tabl ).
          WHEN 'DTEL'.
            lo_in->to_abap( IMPORTING ev_container = ex_target-dtel ).
          WHEN 'DOMA'.
            lo_in->to_abap( IMPORTING ev_container = ex_target-doma ).
        ENDCASE.
      CATCH zcx_ajson_error INTO lx_json.
        lv_msg = lx_json->get_text( ).
        CONCATENATE 'The file is not valid JSON:' lv_msg
          INTO ex_target-result-message SEPARATED BY space.
        RETURN.
    ENDTRY.

    "--- per type: the name inside the file, and what must be there
    CASE ex_target-object.
      WHEN 'TABL'.
        lv_given = ex_target-tabl-dd02v-tabname.
        IF lv_given IS INITIAL.
          ex_target-tabl-dd02v-tabname = lv_name.
        ELSEIF lv_given <> lv_name.
          ex_target-result-message = 'dd02v.tabname must be the table name (the folder name).'.
          RETURN.
        ENDIF.
        CASE ex_target-tabl-dd02v-tabclass.
          WHEN 'TRANSP' OR 'INTTAB'.
          WHEN OTHERS.
            CONCATENATE 'Only transparent tables (TRANSP) and structures (INTTAB) can be pushed, not'
                        ex_target-tabl-dd02v-tabclass '- use SE11.'
              INTO ex_target-result-message SEPARATED BY space.
            RETURN.
        ENDCASE.
        IF ex_target-tabl-dd02v-tabclass = 'TRANSP' AND strlen( lv_name ) > 16.
          ex_target-result-message = 'A transparent table name is at most 16 characters.'.
          RETURN.
        ENDIF.
        IF ex_target-tabl-dd03p IS INITIAL.
          ex_target-result-message = 'The table has no fields (dd03p is empty).'.
          RETURN.
        ENDIF.
      WHEN 'DTEL'.
        lv_given = ex_target-dtel-dd04v-rollname.
        IF lv_given IS INITIAL.
          ex_target-dtel-dd04v-rollname = lv_name.
        ELSEIF lv_given <> lv_name.
          ex_target-result-message = 'dd04v.rollname must be the data element name (the folder name).'.
          RETURN.
        ENDIF.
        "abapGit refuses this too: SE11 will not save it either
        IF ex_target-dtel-dd04v-ddtext IS INITIAL.
          ex_target-result-message = 'A data element needs a short description (dd04v.ddtext).'.
          RETURN.
        ENDIF.
        IF ex_target-dtel-dd04v-domname IS INITIAL AND ex_target-dtel-dd04v-datatype IS INITIAL
           AND ex_target-dtel-dd04v-refkind IS INITIAL.
          ex_target-result-message = 'A data element needs a domain (dd04v.domname) or a built-in type (dd04v.datatype).'.
          RETURN.
        ENDIF.
      WHEN 'DOMA'.
        lv_given = ex_target-doma-dd01v-domname.
        IF lv_given IS INITIAL.
          ex_target-doma-dd01v-domname = lv_name.
        ELSEIF lv_given <> lv_name.
          ex_target-result-message = 'dd01v.domname must be the domain name (the folder name).'.
          RETURN.
        ENDIF.
        IF ex_target-doma-dd01v-datatype IS INITIAL.
          ex_target-result-message = 'A domain needs a data type (dd01v.datatype).'.
          RETURN.
        ENDIF.
    ENDCASE.

    "--- does it exist, and where does it live
    lv_obj  = lv_name.
    lv_type = ex_target-object.
    SELECT SINGLE devclass masterlang FROM tadir
      INTO (ex_target-devclass, ex_target-masterlang)
      WHERE pgmid = 'R3TR' AND object = lv_type AND obj_name = lv_obj.
    IF sy-subrc = 0.
      lv_exists = abap_true.
    ENDIF.

    IF im_part-create = abap_true.
      IF lv_exists = abap_true.
        CONCATENATE lv_what 'already exists - pull it and push changes instead.'
          INTO ex_target-result-message SEPARATED BY space.
        RETURN.
      ENDIF.
      lv_pkg = im_request-package.
      TRANSLATE lv_pkg TO UPPER CASE.
      IF lv_pkg IS INITIAL.
        ex_target-result-message = 'A new dictionary object needs a package - pass --package.'.
        RETURN.
      ENDIF.
      IF NOT ( lv_pkg CP 'Z*' OR lv_pkg CP 'Y*' OR lv_pkg CP '$*' ).
        ex_target-result-message = 'Package must start with Z, Y or $.'.
        RETURN.
      ENDIF.
      SELECT SINGLE devclass FROM tdevc INTO lv_pkg WHERE devclass = lv_pkg.
      IF sy-subrc <> 0.
        ex_target-result-message = 'Package does not exist.'.
        RETURN.
      ENDIF.
      ex_target-devclass   = lv_pkg.
      ex_target-masterlang = sy-langu.
    ELSE.
      IF lv_exists = abap_false.
        CONCATENATE lv_what 'not found - a new one is pushed with --package.'
          INTO ex_target-result-message SEPARATED BY space.
        RETURN.
      ENDIF.
      IF ex_target-masterlang IS INITIAL.
        ex_target-masterlang = sy-langu.
      ENDIF.
    ENDIF.
    IF ex_target-devclass(1) = '$'.
      ex_target-local = abap_true.
    ENDIF.

    "--- authorization: S_DEVELOP as SE11 checks it, plus the push gate
    lv_msg = zcl_abapsync_write=>check_auth( im_devclass = ex_target-devclass
                                            im_objtype  = ex_target-object
                                            im_name     = lv_name ).
    IF lv_msg IS NOT INITIAL.
      ex_target-result-message = lv_msg.
      RETURN.
    ENDIF.

    "--- an existing object: drift, then what the change does to data
    IF lv_exists = abap_true.
      lv_current = ddic_text( im_object = ex_target-object im_name = lv_name ).
      IF lv_current IS NOT INITIAL.
        lv_hash = zcl_abapmcp_sync=>hash_text( lv_current ).
      ENDIF.
      IF im_request-force = abap_false AND lv_hash <> im_part-expected_hash.
        ex_target-result-message = 'Changed in SAP since your pull - re-pull, or push with --force.'.
        RETURN.
      ENDIF.

      CASE ex_target-object.
        WHEN 'TABL'.
          read_tabl( EXPORTING im_name  = ex_target-name
                               im_langu = ex_target-masterlang
                     IMPORTING ex_tabl  = lw_old
                               ex_found = lv_found ).
          IF lv_found = abap_true.
            IF lw_old-dd02v-tabclass <> ex_target-tabl-dd02v-tabclass.
              ex_target-result-message = 'Turning a table into a structure or back is not done by push - use SE11.'.
              RETURN.
            ENDIF.
            IF lw_old-dd02v-tabclass = 'TRANSP' AND has_data( lw_old ) = abap_true.
              lv_msg = risky_change( im_old = lw_old im_new = ex_target-tabl ).
              IF lv_msg IS NOT INITIAL.
                ex_target-result-message = lv_msg.
                RETURN.
              ENDIF.
            ENDIF.
          ENDIF.

        WHEN 'DTEL' OR 'DOMA'.
          "a data element or domain types fields in tables that may hold
          "data, wherever they are - so only making it longer goes through
          IF ex_target-object = 'DTEL'.
            read_dtel( EXPORTING im_name  = ex_target-name
                                 im_langu = ex_target-masterlang
                       IMPORTING ex_dtel  = lw_odtel
                                 ex_found = lv_found ).
          ELSE.
            read_doma( EXPORTING im_name  = ex_target-name
                                 im_langu = ex_target-masterlang
                       IMPORTING ex_doma  = lw_odoma
                                 ex_found = lv_found ).
          ENDIF.
          IF lv_found = abap_true.
            elem_type( EXPORTING im_object   = ex_target-object
                                 im_dtel     = lw_odtel
                                 im_doma     = lw_odoma
                       IMPORTING ex_datatype = lv_otype
                                 ex_leng     = lv_oleng
                                 ex_decimals = lv_odec
                                 ex_found    = lv_ofound ).
            elem_type( EXPORTING im_object   = ex_target-object
                                 im_dtel     = ex_target-dtel
                                 im_doma     = ex_target-doma
                       IMPORTING ex_datatype = lv_ntype
                                 ex_leng     = lv_nleng
                                 ex_decimals = lv_ndec
                                 ex_found    = lv_nfound ).
            IF lv_ofound = abap_true AND lv_nfound = abap_false.
              CONCATENATE lv_what lv_name 'would refer to a domain that is not active - activate it first.'
                INTO ex_target-result-message SEPARATED BY space.
              RETURN.
            ENDIF.
            IF lv_ofound = abap_true AND
               ( lv_ntype <> lv_otype OR lv_ndec <> lv_odec OR lv_nleng < lv_oleng ).
              lv_num  = lv_oleng.
              lv_num2 = lv_nleng.
              CONDENSE: lv_num, lv_num2.
              CONCATENATE lv_what lv_name 'would change from' lv_otype lv_num 'to' lv_ntype lv_num2
                          '- only making it longer is pushed, as it types fields in tables; change it in SE11.'
                INTO ex_target-result-message SEPARATED BY space.
              RETURN.
            ENDIF.
          ENDIF.
      ENDCASE.
    ENDIF.

    "--- transport rules (lock check on R3TR <type>)
    IF ex_target-local = abap_false.
      zcl_abapsync_write=>check_transport( EXPORTING im_transport = im_request-transport
                                                     im_object    = ex_target-object
                                                     im_name      = lv_name
                                                     im_include   = ''
                                           IMPORTING ex_request   = ex_target-request
                                                     ex_message   = lv_msg ).
      IF lv_msg IS NOT INITIAL.
        ex_target-result-message = lv_msg.
        RETURN.
      ENDIF.
      ex_target-result-transport = ex_target-request.

      "the dictionary records into the developer's own task; without one
      "it would ask which request to use - impossible over HTTP
      SELECT SINGLE trkorr FROM e070 INTO lv_task
        WHERE strkorr = ex_target-request
          AND as4user = sy-uname
          AND ( trstatus = 'D' OR trstatus = 'L' ).
      IF sy-subrc <> 0.
        CONCATENATE 'You have no modifiable task in request' ex_target-request
                    '- add one for your user in SE09, then push again.'
          INTO ex_target-result-message SEPARATED BY space.
        RETURN.
      ENDIF.
    ENDIF.

    ex_target-result-status = 'ok'.
    IF im_part-create = abap_true.
      ex_target-result-message = 'Ready to create.'.
    ELSE.
      ex_target-result-message = 'Ready to write.'.
    ENDIF.

  ENDMETHOD.


  METHOD ddic_text.
    "Same text every time for the same definition: the drift check of a
    "push compares the hash of this text with the one taken at pull.
    "Written component by component, so only what the object really says
    "is in the file; on push, every key left out comes back as initial.

    DATA lv_name  TYPE ddobjname.
    DATA lw_tabl  TYPE t_tabl.
    DATA lw_dtel  TYPE t_dtel.
    DATA lw_doma  TYPE t_doma.
    DATA lv_found TYPE abap_bool.
    DATA lo_out   TYPE REF TO zif_ajson.
    DATA lx_json  TYPE REF TO zcx_ajson_error.
    DATA lv_lang  TYPE sy-langu.

    IF is_ddic_type( im_object ) = abap_false.
      RETURN.
    ENDIF.

    lv_name = im_name.
    lv_lang = masterlang( im_name = im_name im_object = im_object ).

    CASE im_object.
      WHEN 'TABL'.
        read_tabl( EXPORTING im_name  = lv_name
                             im_langu = lv_lang
                   IMPORTING ex_tabl  = lw_tabl
                             ex_found = lv_found ).
        IF lv_found = abap_true.
          normalize( CHANGING ch_tabl = lw_tabl ).
        ENDIF.
      WHEN 'DTEL'.
        read_dtel( EXPORTING im_name  = lv_name
                             im_langu = lv_lang
                   IMPORTING ex_dtel  = lw_dtel
                             ex_found = lv_found ).
      WHEN 'DOMA'.
        read_doma( EXPORTING im_name  = lv_name
                             im_langu = lv_lang
                   IMPORTING ex_doma  = lw_doma
                             ex_found = lv_found ).
    ENDCASE.
    IF lv_found = abap_false.
      RETURN.
    ENDIF.
    normalize_elem( CHANGING ch_dtel = lw_dtel
                             ch_doma = lw_doma ).

    TRY.
        lo_out = zcl_ajson=>create_empty( ).
        lo_out->keep_item_order( ).
        CASE im_object.
          WHEN 'TABL'.
            add_struct( io_json = lo_out iv_path = '/dd02v' is_data = lw_tabl-dd02v ).
            add_struct( io_json = lo_out iv_path = '/dd09l' is_data = lw_tabl-dd09l ).
            add_table( io_json = lo_out iv_path = '/dd03p' it_data = lw_tabl-dd03p ).
            add_table( io_json = lo_out iv_path = '/dd05m' it_data = lw_tabl-dd05m ).
            add_table( io_json = lo_out iv_path = '/dd08v' it_data = lw_tabl-dd08v ).
            add_table( io_json = lo_out iv_path = '/dd12v' it_data = lw_tabl-dd12v ).
            add_table( io_json = lo_out iv_path = '/dd17v' it_data = lw_tabl-dd17v ).
            add_table( io_json = lo_out iv_path = '/dd35v' it_data = lw_tabl-dd35v ).
            add_table( io_json = lo_out iv_path = '/dd36m' it_data = lw_tabl-dd36m ).
          WHEN 'DTEL'.
            add_struct( io_json = lo_out iv_path = '/dd04v' is_data = lw_dtel-dd04v ).
          WHEN 'DOMA'.
            add_struct( io_json = lo_out iv_path = '/dd01v' is_data = lw_doma-dd01v ).
            add_table( io_json = lo_out iv_path = '/dd07v' it_data = lw_doma-dd07v ).
        ENDCASE.
        ex_text = lo_out->stringify( iv_indent = 2 ).
      CATCH zcx_ajson_error INTO lx_json.
        CLEAR ex_text.
        RETURN.
    ENDTRY.

    CONCATENATE ex_text cl_abap_char_utilities=>newline INTO ex_text.

  ENDMETHOD.


  METHOD dtel_type.
*&---------------------------------------------------------------------*

    DATA lv_name  TYPE ddobjname.
    DATA lw_dd04v TYPE dd04v.

    CLEAR: ex_datatype, ex_leng, ex_decimals, ex_found.

    lv_name = im_rollname.
    CALL FUNCTION 'DDIF_DTEL_GET'
      EXPORTING
        name          = lv_name
        langu         = sy-langu
      IMPORTING
        dd04v_wa      = lw_dd04v
      EXCEPTIONS
        illegal_input = 1
        OTHERS        = 2.
    IF sy-subrc = 0 AND lw_dd04v-rollname IS NOT INITIAL.
      ex_datatype = lw_dd04v-datatype.
      ex_leng     = lw_dd04v-leng.
      ex_decimals = lw_dd04v-decimals.
      ex_found    = abap_true.
    ENDIF.

  ENDMETHOD.


  METHOD elem_type.
    "The type a field gets from this object. A data element with a domain
    "has the domain's ACTIVE type; one with a built-in type has its own;
    "a reference type counts as REF. Not found: the domain is not active.

    DATA lw_doma  TYPE t_doma.
    DATA lv_name  TYPE ddobjname.
    DATA lv_found TYPE abap_bool.

    CLEAR: ex_datatype, ex_leng, ex_decimals, ex_found.

    IF im_object = 'DOMA'.
      ex_datatype = im_doma-dd01v-datatype.
      ex_leng     = im_doma-dd01v-leng.
      ex_decimals = im_doma-dd01v-decimals.
      ex_found    = abap_true.
      RETURN.
    ENDIF.

    IF im_dtel-dd04v-refkind = 'R'.
      ex_datatype = 'REF'.
      ex_found    = abap_true.
      RETURN.
    ENDIF.

    IF im_dtel-dd04v-domname IS NOT INITIAL.
      lv_name = im_dtel-dd04v-domname.
      read_doma( EXPORTING im_name  = lv_name
                           im_langu = sy-langu
                 IMPORTING ex_doma  = lw_doma
                           ex_found = lv_found ).
      IF lv_found = abap_true.
        ex_datatype = lw_doma-dd01v-datatype.
        ex_leng     = lw_doma-dd01v-leng.
        ex_decimals = lw_doma-dd01v-decimals.
        ex_found    = abap_true.
      ENDIF.
      RETURN.
    ENDIF.

    ex_datatype = im_dtel-dd04v-datatype.
    ex_leng     = im_dtel-dd04v-leng.
    ex_decimals = im_dtel-dd04v-decimals.
    ex_found    = abap_true.

  ENDMETHOD.


  METHOD has_data.
*&---------------------------------------------------------------------*
    "Any row in any client counts. When the answer cannot be found out,
    "the table is treated as holding data - the safe side.

    DATA lv_tab  TYPE tabname.
    DATA lr_wa   TYPE REF TO data.
    DATA lx_root TYPE REF TO cx_root.

    FIELD-SYMBOLS <lf_wa> TYPE any.

    lv_tab = im_tabl-dd02v-tabname.
    TRY.
        CREATE DATA lr_wa TYPE (lv_tab).
        ASSIGN lr_wa->* TO <lf_wa>.
        IF im_tabl-dd02v-clidep = abap_true.
          SELECT SINGLE * FROM (lv_tab) CLIENT SPECIFIED INTO <lf_wa>.
        ELSE.
          SELECT SINGLE * FROM (lv_tab) INTO <lf_wa>.
        ENDIF.
        IF sy-subrc = 0.
          ex_yes = abap_true.
        ENDIF.
      CATCH cx_root INTO lx_root.
        ex_yes = abap_true.
    ENDTRY.

  ENDMETHOD.


  METHOD is_ddic_type.

    IF im_object = 'TABL' OR im_object = 'DTEL' OR im_object = 'DOMA'.
      ex_yes = abap_true.
    ENDIF.

  ENDMETHOD.


  METHOD masterlang.

    DATA lv_obj  TYPE sobj_name.
    DATA lv_type TYPE trobjtype.

    lv_obj  = im_name.
    lv_type = im_object.
    TRANSLATE lv_obj TO UPPER CASE.
    SELECT SINGLE masterlang FROM tadir INTO ex_lang
      WHERE pgmid = 'R3TR' AND object = lv_type AND obj_name = lv_obj.
    IF ex_lang IS INITIAL.
      ex_lang = sy-langu.
    ENDIF.

  ENDMETHOD.


  METHOD normalize.
*&---------------------------------------------------------------------*
    "The cleanup abapGit does before it writes a table to XML, so the
    "file holds what the table says and nothing the system derives.

    DATA lv_masklen TYPE c LENGTH 4.
    DATA lv_index   TYPE i.

    FIELD-SYMBOLS <lf_dd03p> TYPE dd03p.
    FIELD-SYMBOLS <lf_dd05m> TYPE dd05m.
    FIELD-SYMBOLS <lf_dd08v> TYPE dd08v.
    FIELD-SYMBOLS <lf_dd12v> TYPE dd12v.
    FIELD-SYMBOLS <lf_dd35v> TYPE dd35v.
    FIELD-SYMBOLS <lf_dd36m> TYPE dd36m.
    FIELD-SYMBOLS <lf_field> TYPE any.

    "--- change stamps
    CLEAR: ch_tabl-dd02v-as4user, ch_tabl-dd02v-as4date, ch_tabl-dd02v-as4time,
           ch_tabl-dd09l-as4user, ch_tabl-dd09l-as4date, ch_tabl-dd09l-as4time.
    ASSIGN COMPONENT 'ROWORCOLST' OF STRUCTURE ch_tabl-dd09l TO <lf_field>.
    IF sy-subrc = 0 AND <lf_field> = 'C'.
      CLEAR <lf_field>.
    ENDIF.

    "--- indexes
    LOOP AT ch_tabl-dd12v ASSIGNING <lf_dd12v>.
      CLEAR: <lf_dd12v>-as4user, <lf_dd12v>-as4date, <lf_dd12v>-as4time,
             <lf_dd12v>-dbindex.
      IF <lf_dd12v>-dbstate IS INITIAL OR <lf_dd12v>-dbstate = 'O'.
        CLEAR: <lf_dd12v>-dbinclexcl, <lf_dd12v>-dbsyssel1, <lf_dd12v>-dbsyssel2,
               <lf_dd12v>-dbsyssel3, <lf_dd12v>-dbsyssel4.
      ENDIF.
    ENDLOOP.

    "--- fields: own fields only, nothing a data element already says
    DELETE ch_tabl-dd03p WHERE depth <> '00'.
    DELETE ch_tabl-dd03p WHERE adminfield <> '0'.
    LOOP AT ch_tabl-dd03p ASSIGNING <lf_dd03p>.
      ASSIGN COMPONENT 'ACTFLAG' OF STRUCTURE <lf_dd03p> TO <lf_field>.
      IF sy-subrc = 0.
        CLEAR <lf_field>.
      ENDIF.
      IF <lf_dd03p>-rollname IS NOT INITIAL.
        CLEAR: <lf_dd03p>-ddlanguage, <lf_dd03p>-dtelmaster, <lf_dd03p>-logflag,
               <lf_dd03p>-ddtext, <lf_dd03p>-reservedte, <lf_dd03p>-reptext,
               <lf_dd03p>-scrtext_s, <lf_dd03p>-scrtext_m, <lf_dd03p>-scrtext_l.
        lv_masklen = <lf_dd03p>-masklen.
        IF lv_masklen = '' OR NOT lv_masklen CO '0123456789'.
          CLEAR <lf_dd03p>-masklen.
        ENDIF.
        IF <lf_dd03p>-comptype = 'E'.
          CLEAR: <lf_dd03p>-domname, <lf_dd03p>-inttype, <lf_dd03p>-intlen,
                 <lf_dd03p>-mask, <lf_dd03p>-memoryid, <lf_dd03p>-headlen,
                 <lf_dd03p>-scrlen1, <lf_dd03p>-scrlen2, <lf_dd03p>-scrlen3,
                 <lf_dd03p>-datatype, <lf_dd03p>-leng, <lf_dd03p>-outputlen,
                 <lf_dd03p>-deffdname, <lf_dd03p>-convexit, <lf_dd03p>-entitytab,
                 <lf_dd03p>-dommaster, <lf_dd03p>-domname3l, <lf_dd03p>-decimals,
                 <lf_dd03p>-lowercase, <lf_dd03p>-signflag.
        ENDIF.
        IF <lf_dd03p>-shlporigin = 'D'.
          CLEAR: <lf_dd03p>-shlpfield, <lf_dd03p>-shlpname.
        ENDIF.
        IF <lf_dd03p>-routputlen = '      '.
          CLEAR <lf_dd03p>-routputlen.
        ENDIF.
      ENDIF.
      "position, table and language are filled back in on push
      CLEAR: <lf_dd03p>-position, <lf_dd03p>-tabname, <lf_dd03p>-ddlanguage.
    ENDLOOP.

    "--- foreign keys: not the ones inherited from .INCLUDEs
    DELETE ch_tabl-dd08v WHERE noinherit = 'N'.
    LOOP AT ch_tabl-dd05m ASSIGNING <lf_dd05m>.
      lv_index = sy-tabix.
      CLEAR: <lf_dd05m>-tabname, <lf_dd05m>-leng.
      READ TABLE ch_tabl-dd08v WITH KEY fieldname = <lf_dd05m>-fieldname
        TRANSPORTING NO FIELDS.
      IF sy-subrc <> 0.
        DELETE ch_tabl-dd05m INDEX lv_index.
      ENDIF.
    ENDLOOP.
    LOOP AT ch_tabl-dd08v ASSIGNING <lf_dd08v>.
      CLEAR: <lf_dd08v>-tabname, <lf_dd08v>-ddlanguage.
    ENDLOOP.

    "--- search help attachments: not the inherited ones
    DELETE ch_tabl-dd35v WHERE shlpinher = abap_true.
    LOOP AT ch_tabl-dd35v ASSIGNING <lf_dd35v>.
      CLEAR <lf_dd35v>-tabname.
    ENDLOOP.
    LOOP AT ch_tabl-dd36m ASSIGNING <lf_dd36m>.
      lv_index = sy-tabix.
      CLEAR: <lf_dd36m>-tabname, <lf_dd36m>-rollname, <lf_dd36m>-domname,
             <lf_dd36m>-datatype, <lf_dd36m>-leng.
      READ TABLE ch_tabl-dd35v WITH KEY fieldname = <lf_dd36m>-fieldname
        TRANSPORTING NO FIELDS.
      IF sy-subrc <> 0.
        DELETE ch_tabl-dd36m INDEX lv_index.
      ENDIF.
    ENDLOOP.
    SORT ch_tabl-dd36m BY flposition.

  ENDMETHOD.


  METHOD normalize_elem.
    "abapGit's cleanup before it writes a data element or domain, so the
    "file holds what the object says and nothing derived. An initial
    "structure stays initial, so this is safe to call for either.

    DATA lv_masklen TYPE c LENGTH 4.

    FIELD-SYMBOLS <lf_field> TYPE any.
    FIELD-SYMBOLS <lf_dd07v> TYPE dd07v.

    "--- data element
    IF ch_dtel-dd04v IS NOT INITIAL.
      CLEAR: ch_dtel-dd04v-as4user, ch_dtel-dd04v-as4date, ch_dtel-dd04v-as4time.
      "a data element with a domain takes its type from there
      IF ch_dtel-dd04v-refkind = 'D'.
        CLEAR: ch_dtel-dd04v-datatype, ch_dtel-dd04v-leng, ch_dtel-dd04v-decimals,
               ch_dtel-dd04v-outputlen, ch_dtel-dd04v-valexi, ch_dtel-dd04v-lowercase,
               ch_dtel-dd04v-signflag, ch_dtel-dd04v-convexit, ch_dtel-dd04v-entitytab.
      ENDIF.
      ASSIGN COMPONENT 'ACTFLAG' OF STRUCTURE ch_dtel-dd04v TO <lf_field>.
      IF sy-subrc = 0.
        CLEAR <lf_field>.
      ENDIF.
      ASSIGN COMPONENT 'RESERVEDTE' OF STRUCTURE ch_dtel-dd04v TO <lf_field>.
      IF sy-subrc = 0.
        CLEAR <lf_field>.
      ENDIF.
    ENDIF.

    "--- domain
    IF ch_doma-dd01v IS NOT INITIAL.
      CLEAR: ch_doma-dd01v-as4user, ch_doma-dd01v-as4date, ch_doma-dd01v-as4time,
             ch_doma-dd01v-appexist.
      ASSIGN COMPONENT 'ACTFLAG' OF STRUCTURE ch_doma-dd01v TO <lf_field>.
      IF sy-subrc = 0.
        CLEAR <lf_field>.
      ENDIF.
      lv_masklen = ch_doma-dd01v-masklen.
      IF lv_masklen = '' OR NOT lv_masklen CO '0123456789'.
        CLEAR ch_doma-dd01v-masklen.
      ENDIF.
      "fixed values appended by others are theirs, not the domain's
      DELETE ch_doma-dd07v WHERE appval = abap_true.
      SORT ch_doma-dd07v BY valpos ddlanguage.
      LOOP AT ch_doma-dd07v ASSIGNING <lf_dd07v>.
        CLEAR <lf_dd07v>-domname.
      ENDLOOP.
    ENDIF.

  ENDMETHOD.


  METHOD own_fields.
*&---------------------------------------------------------------------*

    DATA lw_field TYPE dd03p.

    LOOP AT im_dd03p INTO lw_field.
      IF lw_field-depth <> '00' OR lw_field-adminfield <> '0'.
        CONTINUE.
      ENDIF.
      "'.INCLUDE' and '.APPEND' rows are not fields
      IF lw_field-fieldname(1) = '.'.
        CONTINUE.
      ENDIF.
      APPEND lw_field TO ex_fields.
    ENDLOOP.

  ENDMETHOD.


  METHOD read_doma.
    "abapGit (ZCL_ABAPGIT_OBJECT_DOMA->SERIALIZE): the active version only

    DATA lv_state TYPE ddgotstate.

    CLEAR: ex_doma, ex_found.

    CALL FUNCTION 'DDIF_DOMA_GET'
      EXPORTING
        name          = im_name
        state         = 'A'
        langu         = im_langu
      IMPORTING
        gotstate      = lv_state
        dd01v_wa      = ex_doma-dd01v
      TABLES
        dd07v_tab     = ex_doma-dd07v
      EXCEPTIONS
        illegal_input = 1
        OTHERS        = 2.
    IF sy-subrc = 0 AND lv_state = 'A' AND ex_doma-dd01v IS NOT INITIAL.
      ex_found = abap_true.
    ELSE.
      CLEAR ex_doma.
    ENDIF.

  ENDMETHOD.


  METHOD read_dtel.
    "abapGit (ZCL_ABAPGIT_OBJECT_DTEL->SERIALIZE): straight from DD04L and
    "DD04T, because DDIF_DTEL_GET bypasses the buffer

    CLEAR: ex_dtel, ex_found.

    SELECT SINGLE * FROM dd04l
      INTO CORRESPONDING FIELDS OF ex_dtel-dd04v
      WHERE rollname = im_name
        AND as4local = 'A'
        AND as4vers  = '0000'.
    IF sy-subrc <> 0 OR ex_dtel-dd04v IS INITIAL.
      CLEAR ex_dtel.
      RETURN.
    ENDIF.

    SELECT SINGLE * FROM dd04t
      INTO CORRESPONDING FIELDS OF ex_dtel-dd04v
      WHERE rollname   = im_name
        AND ddlanguage = im_langu
        AND as4local   = 'A'
        AND as4vers    = '0000'.

    ex_found = abap_true.

  ENDMETHOD.


  METHOD read_tabl.
*&---------------------------------------------------------------------*

    DATA lv_state TYPE ddgotstate.

    CLEAR: ex_tabl, ex_found.

    CALL FUNCTION 'DDIF_TABL_GET'
      EXPORTING
        name          = im_name
        langu         = im_langu
      IMPORTING
        gotstate      = lv_state
        dd02v_wa      = ex_tabl-dd02v
        dd09l_wa      = ex_tabl-dd09l
      TABLES
        dd03p_tab     = ex_tabl-dd03p
        dd05m_tab     = ex_tabl-dd05m
        dd08v_tab     = ex_tabl-dd08v
        dd12v_tab     = ex_tabl-dd12v
        dd17v_tab     = ex_tabl-dd17v
        dd35v_tab     = ex_tabl-dd35v
        dd36m_tab     = ex_tabl-dd36m
      EXCEPTIONS
        illegal_input = 1
        OTHERS        = 2.
    IF sy-subrc = 0 AND lv_state = 'A'.
      ex_found = abap_true.
    ELSE.
      CLEAR ex_tabl.
    ENDIF.

  ENDMETHOD.


  METHOD risky_change.
*&---------------------------------------------------------------------*
    "Only called for a transparent table that holds rows. Refused: a
    "different key, a dropped field, a field whose type changes other
    "than getting longer. Everything else - new fields, longer fields,
    "texts, settings - goes through.

    DATA li_old      TYPE t_dd03p_tab.
    DATA li_new      TYPE t_dd03p_tab.
    DATA lw_old      TYPE dd03p.
    DATA lw_new      TYPE dd03p.
    DATA li_oldkey   TYPE string_table.
    DATA li_newkey   TYPE string_table.
    DATA lv_field    TYPE string.
    DATA lv_newtype  TYPE dd03p-datatype.
    DATA lv_newleng  TYPE i.
    DATA lv_newdec   TYPE i.
    DATA lv_oldleng  TYPE i.
    DATA lv_olddec   TYPE i.
    DATA lv_found    TYPE abap_bool.
    DATA lv_num      TYPE string.
    DATA lv_num2     TYPE string.

    li_old = own_fields( im_old-dd03p ).
    li_new = own_fields( im_new-dd03p ).

    "--- the key, in order
    LOOP AT li_old INTO lw_old WHERE keyflag = abap_true.
      lv_field = lw_old-fieldname.
      APPEND lv_field TO li_oldkey.
    ENDLOOP.
    LOOP AT li_new INTO lw_new WHERE keyflag = abap_true.
      lv_field = lw_new-fieldname.
      APPEND lv_field TO li_newkey.
    ENDLOOP.
    IF li_oldkey <> li_newkey.
      ex_msg = 'The key would change and the table holds data - change the key in SE11, where the conversion can be checked.'.
      RETURN.
    ENDIF.

    "--- every field that is there now
    LOOP AT li_old INTO lw_old.
      READ TABLE li_new INTO lw_new WITH KEY fieldname = lw_old-fieldname.
      IF sy-subrc <> 0.
        CONCATENATE 'Field' lw_old-fieldname
                    'would be dropped and the table holds data - remove fields in SE11.'
          INTO ex_msg SEPARATED BY space.
        RETURN.
      ENDIF.

      IF lw_new-rollname IS NOT INITIAL.
        IF lw_new-rollname = lw_old-rollname.
          CONTINUE.
        ENDIF.
        dtel_type( EXPORTING im_rollname = lw_new-rollname
                   IMPORTING ex_datatype = lv_newtype
                             ex_leng     = lv_newleng
                             ex_decimals = lv_newdec
                             ex_found    = lv_found ).
        IF lv_found = abap_false.
          CONCATENATE 'Field' lw_old-fieldname 'uses data element' lw_new-rollname
                      'which is not active - activate it first.'
            INTO ex_msg SEPARATED BY space.
          RETURN.
        ENDIF.
      ELSE.
        lv_newtype = lw_new-datatype.
        lv_newleng = lw_new-leng.
        lv_newdec  = lw_new-decimals.
      ENDIF.

      lv_oldleng = lw_old-leng.
      lv_olddec  = lw_old-decimals.
      IF lv_newtype <> lw_old-datatype OR lv_newdec <> lv_olddec
         OR lv_newleng < lv_oldleng.
        lv_num  = lv_oldleng.
        lv_num2 = lv_newleng.
        CONDENSE: lv_num, lv_num2.
        CONCATENATE 'Field' lw_old-fieldname 'would change from' lw_old-datatype lv_num
                    'to' lv_newtype lv_num2
                    'and the table holds data - only making a field longer is pushed; change it in SE11.'
          INTO ex_msg SEPARATED BY space.
        RETURN.
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD run.
    "check    validate every part, write nothing
    "write    validate again, then save INACTIVE - domains first, then
    "         data elements, then tables, so each finds what it uses
    "activate one mass activation for everything written; the dictionary
    "         works out the order itself

    TYPES: BEGIN OF lt_order,
             rank TYPE i,
             pos  TYPE i,
           END OF lt_order.

    DATA lo_in     TYPE REF TO zif_ajson.
    DATA lo_out    TYPE REF TO zif_ajson.
    DATA lx_json   TYPE REF TO zcx_ajson_error.
    DATA lw_req    TYPE t_request.
    DATA lw_resp   TYPE t_response.
    DATA lw_part   TYPE t_part.
    DATA lw_target TYPE t_target.
    DATA li_order  TYPE STANDARD TABLE OF lt_order.
    DATA lw_order  TYPE lt_order.
    DATA lv_object TYPE string.

    TRY.
        lo_in = zcl_ajson=>parse( im_request ).
        lo_in->to_abap( IMPORTING ev_container = lw_req ).
      CATCH zcx_ajson_error INTO lx_json.
        lw_resp-error = lx_json->get_text( ).
    ENDTRY.

    IF lw_resp-error IS INITIAL.
      CASE lw_req-action.

        WHEN 'check'.
          LOOP AT lw_req-parts INTO lw_part.
            lw_target = check_tabl( im_part = lw_part im_request = lw_req ).
            APPEND lw_target-result TO lw_resp-results.
          ENDLOOP.

        WHEN 'write'.
          LOOP AT lw_req-parts INTO lw_part.
            lw_order-pos  = sy-tabix.
            lv_object     = lw_part-object.
            TRANSLATE lv_object TO UPPER CASE.
            lw_order-rank = type_rank( lv_object ).
            APPEND lw_order TO li_order.
          ENDLOOP.
          SORT li_order BY rank pos.

          LOOP AT li_order INTO lw_order.
            READ TABLE lw_req-parts INTO lw_part INDEX lw_order-pos.
            lw_target = check_tabl( im_part = lw_part im_request = lw_req ).
            IF lw_target-result-status = 'ok'.
              CASE lw_target-object.
                WHEN 'TABL'.
                  write_tabl( CHANGING ch_target = lw_target ).
                WHEN 'DTEL'.
                  write_dtel( CHANGING ch_target = lw_target ).
                WHEN 'DOMA'.
                  write_doma( CHANGING ch_target = lw_target ).
              ENDCASE.
            ELSE.
              "valid a moment ago in 'check' - something moved in between
              lw_target-result-status = 'error'.
            ENDIF.
            APPEND lw_target-result TO lw_resp-results.
          ENDLOOP.

        WHEN 'activate'.
          activate_tabl( EXPORTING im_parts    = lw_req-parts
                         IMPORTING ex_results  = lw_resp-results
                                   ex_messages = lw_resp-messages ).

        WHEN OTHERS.
          lw_resp-error = 'action must be check, write or activate.'.

      ENDCASE.
    ENDIF.

    TRY.
        lo_out = zcl_ajson=>create_empty( ).
        lo_out->set( iv_path = '/' iv_val = lw_resp ).
        ex_response = lo_out->stringify( ).
      CATCH zcx_ajson_error INTO lx_json.
        ex_response = '{"error":"ZCL_ABAPSYNC_DDIC could not build its answer"}'.
    ENDTRY.

  ENDMETHOD.


  METHOD type_rank.
    "Domains before data elements before tables: each is written after
    "what it refers to (abapGit deserializes in the same order)

    CASE im_object.
      WHEN 'DOMA'.
        ex_rank = 1.
      WHEN 'DTEL'.
        ex_rank = 2.
      WHEN OTHERS.
        ex_rank = 3.
    ENDCASE.

  ENDMETHOD.


  METHOD write_doma.
    "abapGit: ZCL_ABAPGIT_OBJECT_DOMA->ZIF_ABAPGIT_OBJECT~DESERIALIZE.
    "Fixed values are numbered in file order. Saves INACTIVE.

    DATA lv_msg   TYPE string.
    DATA lw_saved TYPE e070use.

    FIELD-SYMBOLS <lf_dd07v> TYPE dd07v.

    ch_target-doma-dd01v-domname = ch_target-name.
    IF ch_target-doma-dd01v-ddlanguage IS INITIAL.
      ch_target-doma-dd01v-ddlanguage = ch_target-masterlang.
    ENDIF.
    LOOP AT ch_target-doma-dd07v ASSIGNING <lf_dd07v>.
      <lf_dd07v>-domname = ch_target-name.
      <lf_dd07v>-valpos  = sy-tabix.
      IF <lf_dd07v>-ddlanguage IS INITIAL.
        <lf_dd07v>-ddlanguage = ch_target-masterlang.
      ENDIF.
    ENDLOOP.

    begin_write( EXPORTING im_target  = ch_target
                 IMPORTING ex_saved   = lw_saved
                           ex_message = lv_msg ).

    IF lv_msg IS INITIAL.
      CALL FUNCTION 'DDIF_DOMA_PUT'
        EXPORTING
          name              = ch_target-name
          dd01v_wa          = ch_target-doma-dd01v
        TABLES
          dd07v_tab         = ch_target-doma-dd07v
        EXCEPTIONS
          doma_not_found    = 1
          name_inconsistent = 2
          doma_inconsistent = 3
          put_failure       = 4
          put_refused       = 5
          OTHERS            = 6.
      IF sy-subrc <> 0.
        lv_msg = zcl_abapsync_write=>sy_message( ).
        CONCATENATE 'DDIF_DOMA_PUT:' lv_msg INTO lv_msg SEPARATED BY space.
      ENDIF.
    ENDIF.

    "the developer's own default request comes back, whatever happened
    IF ch_target-local = abap_false.
      zcl_abapsync_write=>reset_default_request( lw_saved ).
    ENDIF.

    IF lv_msg IS NOT INITIAL.
      ch_target-result-status  = 'error'.
      ch_target-result-message = lv_msg.
      RETURN.
    ENDIF.

    ch_target-result-status = 'written'.
    ch_target-result-state  = 'I'.
    IF ch_target-create = abap_true.
      ch_target-result-message = 'Domain created, saved inactive.'.
    ELSE.
      ch_target-result-message = 'Saved inactive.'.
    ENDIF.

  ENDMETHOD.


  METHOD write_dtel.
    "abapGit: ZCL_ABAPGIT_OBJECT_DTEL->ZIF_ABAPGIT_OBJECT~DESERIALIZE.
    "Saves INACTIVE; RUN 'activate' activates it.

    DATA lv_msg   TYPE string.
    DATA lw_saved TYPE e070use.

    ch_target-dtel-dd04v-rollname = ch_target-name.
    IF ch_target-dtel-dd04v-ddlanguage IS INITIAL.
      ch_target-dtel-dd04v-ddlanguage = ch_target-masterlang.
    ENDIF.

    begin_write( EXPORTING im_target  = ch_target
                 IMPORTING ex_saved   = lw_saved
                           ex_message = lv_msg ).

    IF lv_msg IS INITIAL.
      CALL FUNCTION 'DDIF_DTEL_PUT'
        EXPORTING
          name              = ch_target-name
          dd04v_wa          = ch_target-dtel-dd04v
        EXCEPTIONS
          dtel_not_found    = 1
          name_inconsistent = 2
          dtel_inconsistent = 3
          put_failure       = 4
          put_refused       = 5
          OTHERS            = 6.
      IF sy-subrc <> 0.
        lv_msg = zcl_abapsync_write=>sy_message( ).
        CONCATENATE 'DDIF_DTEL_PUT:' lv_msg INTO lv_msg SEPARATED BY space.
      ENDIF.
    ENDIF.

    "the developer's own default request comes back, whatever happened
    IF ch_target-local = abap_false.
      zcl_abapsync_write=>reset_default_request( lw_saved ).
    ENDIF.

    IF lv_msg IS NOT INITIAL.
      ch_target-result-status  = 'error'.
      ch_target-result-message = lv_msg.
      RETURN.
    ENDIF.

    ch_target-result-status = 'written'.
    ch_target-result-state  = 'I'.
    IF ch_target-create = abap_true.
      ch_target-result-message = 'Data element created, saved inactive.'.
    ELSE.
      ch_target-result-message = 'Saved inactive.'.
    ENDIF.

  ENDMETHOD.


  METHOD write_tabl.
*&---------------------------------------------------------------------*
    "abapGit: ZCL_ABAPGIT_OBJECT_TABL->ZIF_ABAPGIT_OBJECT~DESERIALIZE.
    "Saves the definition INACTIVE; RUN 'activate' activates it.

    DATA lv_obj    TYPE trobj_name.
    DATA lv_msg    TYPE string.
    DATA lw_saved  TYPE e070use.
    DATA lw_dd12v  TYPE dd12v.
    DATA lw_dd17v  TYPE dd17v.
    DATA li_dd17v  TYPE t_dd17v_tab.

    FIELD-SYMBOLS <lf_dd03p>   TYPE dd03p.
    FIELD-SYMBOLS <lf_dd05m>   TYPE dd05m.
    FIELD-SYMBOLS <lf_dd08v>   TYPE dd08v.
    FIELD-SYMBOLS <lf_dd35v>   TYPE dd35v.
    FIELD-SYMBOLS <lf_dd36m>   TYPE dd36m.
    FIELD-SYMBOLS <lf_rowcol>  TYPE any.

    "--- what the file leaves out, as abapGit fills it back in
    ASSIGN COMPONENT 'ROWORCOLST' OF STRUCTURE ch_target-tabl-dd09l TO <lf_rowcol>.
    IF sy-subrc = 0 AND <lf_rowcol> IS INITIAL.
      <lf_rowcol> = 'C'.
    ENDIF.
    ch_target-tabl-dd02v-tabname = ch_target-name.
    IF ch_target-tabl-dd02v-ddlanguage IS INITIAL.
      ch_target-tabl-dd02v-ddlanguage = ch_target-masterlang.
    ENDIF.
    IF ch_target-tabl-dd09l IS NOT INITIAL.
      ch_target-tabl-dd09l-tabname = ch_target-name.
    ENDIF.
    LOOP AT ch_target-tabl-dd03p ASSIGNING <lf_dd03p>.
      <lf_dd03p>-position   = sy-tabix.
      <lf_dd03p>-tabname    = ch_target-name.
      <lf_dd03p>-ddlanguage = ch_target-masterlang.
    ENDLOOP.
    LOOP AT ch_target-tabl-dd05m ASSIGNING <lf_dd05m>.
      <lf_dd05m>-tabname = ch_target-name.
    ENDLOOP.
    LOOP AT ch_target-tabl-dd08v ASSIGNING <lf_dd08v>.
      <lf_dd08v>-tabname    = ch_target-name.
      <lf_dd08v>-ddlanguage = ch_target-masterlang.
    ENDLOOP.
    LOOP AT ch_target-tabl-dd35v ASSIGNING <lf_dd35v>.
      <lf_dd35v>-tabname = ch_target-name.
    ENDLOOP.
    LOOP AT ch_target-tabl-dd36m ASSIGNING <lf_dd36m>.
      <lf_dd36m>-tabname = ch_target-name.
    ENDLOOP.

    "--- the request becomes the session default, so the dictionary
    "    records into it without asking (a popup dumps over HTTP)
    IF ch_target-local = abap_false.
      zcl_abapsync_write=>set_default_request( EXPORTING im_request = ch_target-request
                                               IMPORTING ex_saved   = lw_saved
                                                         ex_message = lv_msg ).
    ENDIF.

    "--- record in the transport, and for a new table create its TADIR
    "    entry (abapGit: CORR_INSERT with object class DICT)
    IF lv_msg IS INITIAL.
      CONCATENATE 'TABL' ch_target-name INTO lv_obj.
      CALL FUNCTION 'RS_CORR_INSERT'
        EXPORTING
          object              = lv_obj
          object_class        = 'DICT'
          devclass            = ch_target-devclass
          master_language     = ch_target-masterlang
          korrnum             = ch_target-request
          mode                = 'I'
          global_lock         = abap_true
          suppress_dialog     = abap_true
        EXCEPTIONS
          cancelled           = 1
          permission_failure  = 2
          unknown_objectclass = 3
          OTHERS              = 4.
      IF sy-subrc <> 0.
        lv_msg = zcl_abapsync_write=>sy_message( ).
        CONCATENATE 'Transport:' lv_msg INTO lv_msg SEPARATED BY space.
      ENDIF.
    ENDIF.

    "--- fill in what the data elements say, then save inactive
    IF lv_msg IS INITIAL.
      CALL FUNCTION 'DD_TABL_EXPAND'
        EXPORTING
          dd02v_wa          = ch_target-tabl-dd02v
        TABLES
          dd03p_tab         = ch_target-tabl-dd03p
          dd05m_tab         = ch_target-tabl-dd05m
          dd08v_tab         = ch_target-tabl-dd08v
          dd35v_tab         = ch_target-tabl-dd35v
          dd36m_tab         = ch_target-tabl-dd36m
        EXCEPTIONS
          illegal_parameter = 1
          OTHERS            = 2.
      IF sy-subrc <> 0.
        lv_msg = zcl_abapsync_write=>sy_message( ).
        CONCATENATE 'DD_TABL_EXPAND:' lv_msg INTO lv_msg SEPARATED BY space.
      ENDIF.
    ENDIF.

    IF lv_msg IS INITIAL.
      CALL FUNCTION 'DDIF_TABL_PUT'
        EXPORTING
          name              = ch_target-name
          dd02v_wa          = ch_target-tabl-dd02v
          dd09l_wa          = ch_target-tabl-dd09l
        TABLES
          dd03p_tab         = ch_target-tabl-dd03p
          dd05m_tab         = ch_target-tabl-dd05m
          dd08v_tab         = ch_target-tabl-dd08v
          dd35v_tab         = ch_target-tabl-dd35v
          dd36m_tab         = ch_target-tabl-dd36m
        EXCEPTIONS
          tabl_not_found    = 1
          name_inconsistent = 2
          tabl_inconsistent = 3
          put_failure       = 4
          put_refused       = 5
          OTHERS            = 6.
      IF sy-subrc <> 0.
        lv_msg = zcl_abapsync_write=>sy_message( ).
        CONCATENATE 'DDIF_TABL_PUT:' lv_msg INTO lv_msg SEPARATED BY space.
      ENDIF.
    ENDIF.

    "--- indexes in the file are created or updated; they are activated
    "    with the table. An index missing from the file is NOT deleted -
    "    push never deletes.
    IF lv_msg IS INITIAL.
      LOOP AT ch_target-tabl-dd12v INTO lw_dd12v.
        lw_dd12v-sqltab = ch_target-name.
        CLEAR li_dd17v.
        LOOP AT ch_target-tabl-dd17v INTO lw_dd17v WHERE indexname = lw_dd12v-indexname.
          lw_dd17v-sqltab = ch_target-name.
          APPEND lw_dd17v TO li_dd17v.
        ENDLOOP.
        CALL FUNCTION 'DDIF_INDX_PUT'
          EXPORTING
            name              = lw_dd12v-sqltab
            id                = lw_dd12v-indexname
            dd12v_wa          = lw_dd12v
          TABLES
            dd17v_tab         = li_dd17v
          EXCEPTIONS
            indx_not_found    = 1
            name_inconsistent = 2
            indx_inconsistent = 3
            put_failure       = 4
            put_refused       = 5
            OTHERS            = 6.
        IF sy-subrc <> 0.
          lv_msg = zcl_abapsync_write=>sy_message( ).
          CONCATENATE 'Index' lw_dd12v-indexname ':' lv_msg INTO lv_msg SEPARATED BY space.
          EXIT.
        ENDIF.
      ENDLOOP.
    ENDIF.

    "the developer's own default request comes back, whatever happened
    IF ch_target-local = abap_false.
      zcl_abapsync_write=>reset_default_request( lw_saved ).
    ENDIF.

    IF lv_msg IS NOT INITIAL.
      ch_target-result-status  = 'error'.
      ch_target-result-message = lv_msg.
      RETURN.
    ENDIF.

    ch_target-result-status = 'written'.
    ch_target-result-state  = 'I'.
    IF ch_target-create = abap_true.
      ch_target-result-message = 'Table created, saved inactive.'.
    ELSE.
      ch_target-result-message = 'Saved inactive.'.
    ENDIF.

  ENDMETHOD.


ENDCLASS.
