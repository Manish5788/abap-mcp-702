CLASS zcl_abapsync_repo DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.
*--------------------------------------------------------------------*
* Title       : ZCL_ABAPSYNC_REPO - abapsync: new programs, text pools
* Type        : Class (called by the abapsync read and write nodes)
* Frequency   : On demand - one call per 'abapsync pull' / 'push'
* Description : Repository work the write node hands over by name:
*                 new programs     part main, create = X, object PROG
*                 text elements    part texts, object PROG or FUGR
*               Text elements travel as JSON (TEXTS_TEXT on pull). The
*               route is abapGit's on this system
*               (ZCL_ABAPGIT_OBJECTS_PROGRAM): RPY_PROGRAM_INSERT,
*               UPDATE_PROGDIR, INSERT TEXTPOOL ... STATE 'I', then
*               activation of REPS / REPT.
*--------------------------------------------------------------------*
*& THE TEXTS FILE
*& { "language": "E", "texts": [ { "id": "R", "entry": "Title" },
*&                                { "id": "I", "key": "001", "entry": "..",
*&                                  "length": 20 },
*&                                { "id": "S", "key": "P_MATNR", "entry": ".." } ] }
*& id R = title, I = text symbol, S = selection text, H = list heading.
*& Only the original language; translations stay with SE63.
*&
*& A NEW PROGRAM
*& Its type comes from its first statement: REPORT = executable (1),
*& PROGRAM = module pool (M), none of these = include (I). Its title is
*& the R entry of a texts file pushed with it, else its name. Fixed-point
*& arithmetic and the Unicode check are switched on, as SE38 does.
*&
*& NOT HANDLED: screens, GUI status, translations, deleting texts (an
*& empty text list is refused - push never deletes).
*&
*& NW 7.02 syntax only.
*&---------------------------------------------------------------------*

    CONSTANTS c_version TYPE string VALUE '1.1.0'.

    "The parts this class takes from the write node
    CLASS-METHODS claims
      IMPORTING im_object     TYPE string
                im_part       TYPE string
                im_create     TYPE abap_bool
      RETURNING VALUE(ex_yes) TYPE abap_bool.

    "JSON of the ACTIVE text pool in the original language, ending in one
    "LF; '' when there are no texts. Pull writes it, drift is hashed over it.
    CLASS-METHODS texts_text
      IMPORTING im_object      TYPE string
                im_name        TYPE string
      RETURNING VALUE(ex_text) TYPE string.

    "The program a text pool belongs to: the name for PROG, SAPL<name>
    "for a function group
    CLASS-METHODS texts_program
      IMPORTING im_object      TYPE string
                im_name        TYPE string
      RETURNING VALUE(ex_prog) TYPE progname.

    "Object types pulled and pushed through this class alone (TRAN)
    CLASS-METHODS is_repo_type
      IMPORTING im_object     TYPE string
      RETURNING VALUE(ex_yes) TYPE abap_bool.

    "JSON of a transaction, ending in one LF; '' when it does not exist:
    "{ tcode, type R|D|P|V|O, program, screen, text, parameters }
    CLASS-METHODS tran_text
      IMPORTING im_name        TYPE string
      RETURNING VALUE(ex_text) TYPE string.

    "Entry point of the write node, same JSON contract as
    "ZCL_ABAPSYNC_DDIC=>RUN (check | write | activate)
    CLASS-METHODS run
      IMPORTING im_request         TYPE string
      RETURNING VALUE(ex_response) TYPE string.

protected section.
*"* protected components of class ZCL_ABAPSYNC_REPO
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
             status    TYPE string,
             message   TYPE string,
             include   TYPE string,
             transport TYPE string,
             new_hash  TYPE string,
             state     TYPE string,
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

    "One text element in the file
    TYPES: BEGIN OF t_text,
             id     TYPE textpool-id,
             key    TYPE textpool-key,
             entry  TYPE textpool-entry,
             length TYPE i,
           END OF t_text,
           t_text_tab TYPE STANDARD TABLE OF t_text WITH DEFAULT KEY.

    TYPES: BEGIN OF t_texts,
             language TYPE sy-langu,
             texts    TYPE t_text_tab,
           END OF t_texts.

    TYPES t_abap_tab TYPE STANDARD TABLE OF abaptxt255 WITH DEFAULT KEY.
    TYPES t_tpool_tab TYPE STANDARD TABLE OF textpool WITH DEFAULT KEY.

    "What the check finds out and the write needs
    TYPES: BEGIN OF t_target,
             result     TYPE t_result,
             object     TYPE string,
             name       TYPE string,
             part       TYPE string,
             program    TYPE progname,
             devclass   TYPE devclass,
             masterlang TYPE sy-langu,
             local      TYPE abap_bool,
             request    TYPE trkorr,
             create     TYPE abap_bool,
             subc       TYPE subc,
             title      TYPE string,
             abap       TYPE t_abap_tab,
             tpool      TYPE t_tpool_tab,
             tran_prog  TYPE progname,
             dynpro     TYPE d020s-dnum,
           END OF t_target,
           t_target_tab TYPE STANDARD TABLE OF t_target WITH DEFAULT KEY.

    CLASS-METHODS check_part
      IMPORTING im_part          TYPE t_part
                im_request       TYPE t_request
      RETURNING VALUE(ex_target) TYPE t_target.

    CLASS-METHODS check_new_program
      IMPORTING im_part      TYPE t_part
                im_request   TYPE t_request
      CHANGING  ch_target    TYPE t_target.

    CLASS-METHODS check_texts
      IMPORTING im_part      TYPE t_part
                im_request   TYPE t_request
      CHANGING  ch_target    TYPE t_target.

    "Transport and own-task rules, shared by both kinds
    CLASS-METHODS check_request
      IMPORTING im_request TYPE t_request
                im_object  TYPE string
                im_name    TYPE string
      CHANGING  ch_target  TYPE t_target.

    CLASS-METHODS check_tran
      IMPORTING im_part      TYPE t_part
                im_request   TYPE t_request
      CHANGING  ch_target    TYPE t_target.

    CLASS-METHODS write_tran
      CHANGING ch_target TYPE t_target.

    CLASS-METHODS write_program
      CHANGING ch_target TYPE t_target.

    CLASS-METHODS write_texts
      CHANGING ch_target TYPE t_target.

    CLASS-METHODS activate
      IMPORTING im_parts    TYPE t_part_tab
      EXPORTING ex_results  TYPE t_result_tab
                ex_messages TYPE t_msg_tab.

    "Title of a new program from a texts part pushed with it
    CLASS-METHODS title_from_push
      IMPORTING im_request      TYPE t_request
                im_name         TYPE string
      RETURNING VALUE(ex_title) TYPE string.

    "Upper-case text of the first statement, comments dropped
    CLASS-METHODS first_statement
      IMPORTING im_abap        TYPE t_abap_tab
      RETURNING VALUE(ex_text) TYPE string.

    CLASS-METHODS masterlang
      IMPORTING im_object      TYPE string
                im_name        TYPE string
      RETURNING VALUE(ex_lang) TYPE sy-langu.

ENDCLASS.


CLASS zcl_abapsync_repo IMPLEMENTATION.

  METHOD activate.
*&---------------------------------------------------------------------*
    "One run for the new programs (REPS) and text pools (REPT) written,
    "as abapGit queues them (ZCL_ABAPGIT_OBJECTS_ACTIVATION->ACTIVATE_OLD).

    DATA li_objects   TYPE STANDARD TABLE OF dwinactiv.
    DATA lw_object    TYPE dwinactiv.
    DATA lo_checklist TYPE REF TO cl_wb_checklist.
    DATA li_errors    TYPE swbme_error_tab.
    DATA lw_error     LIKE LINE OF li_errors.
    DATA lv_subrc     TYPE sy-subrc.
    DATA lw_part      TYPE t_part.
    DATA lw_result    TYPE t_result.
    DATA lw_msg       TYPE t_msg.
    DATA lv_prog      TYPE progname.
    DATA lv_open      TYPE progname.
    DATA lv_part      TYPE string.
    DATA lv_name      TYPE string.
    DATA lv_text      TYPE string.
    DATA lv_lang      TYPE sy-langu.
    DATA li_tpool     TYPE t_tpool_tab.

    CLEAR: ex_results, ex_messages.

    LOOP AT im_parts INTO lw_part.
      lv_part = lw_part-part.
      TRANSLATE lv_part TO LOWER CASE.
      lv_name = lw_part-name.
      TRANSLATE lv_name TO UPPER CASE.
      "a transaction is active once written - nothing to activate
      IF lv_part = 'tran'.
        CONTINUE.
      ENDIF.
      CLEAR lw_object.
      lw_object-obj_name = texts_program( im_object = lw_part-object im_name = lv_name ).
      IF lv_part = 'texts'.
        lw_object-object = 'REPT'.
      ELSE.
        lw_object-object = 'REPS'.
      ENDIF.
      APPEND lw_object TO li_objects.
    ENDLOOP.
    IF li_objects IS NOT INITIAL.
    SORT li_objects BY object obj_name.
    DELETE ADJACENT DUPLICATES FROM li_objects COMPARING object obj_name.

    TRY.
        CALL FUNCTION 'RS_WORKING_OBJECTS_ACTIVATE'
          EXPORTING
            activate_ddic_objects  = abap_false
            with_popup             = abap_false
            ui_decoupled           = abap_true
          IMPORTING
            p_checklist            = lo_checklist
          TABLES
            objects                = li_objects
          EXCEPTIONS
            excecution_error       = 1
            cancelled              = 2
            insert_into_corr_error = 3
            error_message          = 4
            OTHERS                 = 5.
        lv_subrc = sy-subrc.
      CATCH cx_sy_dyn_call_param_not_found.
        CALL FUNCTION 'RS_WORKING_OBJECTS_ACTIVATE'
          EXPORTING
            activate_ddic_objects  = abap_false
            with_popup             = abap_false
          IMPORTING
            p_checklist            = lo_checklist
          TABLES
            objects                = li_objects
          EXCEPTIONS
            excecution_error       = 1
            cancelled              = 2
            insert_into_corr_error = 3
            error_message          = 4
            OTHERS                 = 5.
        lv_subrc = sy-subrc.
    ENDTRY.

    IF lv_subrc <> 0 AND sy-msgid IS NOT INITIAL.
      lw_msg-text = zcl_abapsync_write=>sy_message( ).
      APPEND lw_msg TO ex_messages.
    ENDIF.
    IF lo_checklist IS BOUND.
      lo_checklist->get_error_messages( IMPORTING p_error_tab = li_errors ).
      LOOP AT li_errors INTO lw_error WHERE mtype = 'E'.
        CLEAR lw_msg.
        lw_msg-object = lw_error-object_text.
        CONCATENATE LINES OF lw_error-mtext INTO lw_msg-text SEPARATED BY space.
        APPEND lw_msg TO ex_messages.
      ENDLOOP.
    ENDIF.
    ENDIF.

    COMMIT WORK.

    "--- the truth: is an inactive version left?
    LOOP AT im_parts INTO lw_part.
      CLEAR: lw_result, lv_open.
      lv_part = lw_part-part.
      TRANSLATE lv_part TO LOWER CASE.
      lv_name = lw_part-name.
      TRANSLATE lv_name TO UPPER CASE.
      lw_result-index   = lw_part-index.
      lw_result-status  = 'written'.

      IF lv_part = 'tran'.
        lw_result-include = lv_name.
        lv_text = tran_text( lv_name ).
        IF lv_text IS INITIAL.
          lw_result-status  = 'error'.
          lw_result-message = 'Transaction not found after the write.'.
        ELSE.
          lw_result-state    = 'A'.
          lw_result-new_hash = zcl_abapmcp_sync=>hash_text( lv_text ).
          lw_result-message  = 'Transaction created.'.
        ENDIF.
        APPEND lw_result TO ex_results.
        CONTINUE.
      ENDIF.
      lv_prog = texts_program( im_object = lw_part-object im_name = lv_name ).
      lw_result-include = lv_prog.

      IF lv_part = 'texts'.
        lv_lang = masterlang( im_object = lw_part-object im_name = lv_name ).
        CLEAR li_tpool.
        READ TEXTPOOL lv_prog INTO li_tpool LANGUAGE lv_lang STATE 'I'.
        IF sy-subrc = 0 AND li_tpool IS NOT INITIAL.
          lv_open = lv_prog.
        ENDIF.
      ELSE.
        SELECT SINGLE progname FROM reposrc INTO lv_open
          WHERE progname = lv_prog AND r3state = 'I'.
      ENDIF.

      IF lv_open IS NOT INITIAL.
        lw_result-state   = 'I'.
        lw_result-message = 'Saved inactive - activation failed, see activation messages.'.
      ELSE.
        lw_result-state = 'A'.
        IF lv_part = 'texts'.
          lv_text = texts_text( im_object = lw_part-object im_name = lv_name ).
          lw_result-new_hash = zcl_abapmcp_sync=>hash_text( lv_text ).
          lw_result-message  = 'Texts saved and activated.'.
        ELSE.
          lv_text = lv_prog.
          lw_result-new_hash = zcl_abapmcp_sync=>include_hash( lv_text ).
          lw_result-message  = 'Program created and activated.'.
        ENDIF.
      ENDIF.
      APPEND lw_result TO ex_results.
    ENDLOOP.

  ENDMETHOD.


  METHOD check_new_program.
*&---------------------------------------------------------------------*

    DATA lv_obj    TYPE sobj_name.
    DATA lv_found  TYPE progname.
    DATA lv_pkg    TYPE devclass.
    DATA lv_msg    TYPE string.
    DATA lv_stmt   TYPE string.
    DATA lv_line   TYPE string.
    DATA lv_len    TYPE i.
    DATA lv_num    TYPE string.
    DATA lv_idx    TYPE i.
    DATA li_lines  TYPE string_table.
    DATA lw_abap   TYPE abaptxt255.

    IF ch_target-object <> 'PROG' OR ch_target-part <> 'main'.
      ch_target-result-message = 'A new program is pushed as PROG, part main.'.
      RETURN.
    ENDIF.
    IF strlen( ch_target-name ) > 30.
      ch_target-result-message = 'A program name is at most 30 characters.'.
      RETURN.
    ENDIF.
    "--- SAP keeps ZX* for the includes of exit function groups and
    "    RPY_PROGRAM_INSERT refuses them - say so before anything is written
    IF ch_target-name CP 'ZX*'.
      ch_target-result-message = 'Names starting with ZX are reserved by SAP for exit includes - choose another name.'.
      RETURN.
    ENDIF.

    "--- must not exist yet, neither as source nor in TADIR
    lv_obj = ch_target-name.
    SELECT SINGLE name FROM trdir INTO lv_found WHERE name = ch_target-program.
    IF sy-subrc = 0.
      ch_target-result-message = 'Program already exists - pull it and push changes instead.'.
      RETURN.
    ENDIF.
    SELECT SINGLE obj_name FROM tadir INTO lv_obj
      WHERE pgmid = 'R3TR' AND object = 'PROG' AND obj_name = lv_obj.
    IF sy-subrc = 0.
      ch_target-result-message = 'Program already exists in TADIR - pull it and push changes instead.'.
      RETURN.
    ENDIF.

    "--- package
    lv_pkg = im_request-package.
    TRANSLATE lv_pkg TO UPPER CASE.
    IF lv_pkg IS INITIAL.
      ch_target-result-message = 'A new program needs a package - pass --package.'.
      RETURN.
    ENDIF.
    IF NOT ( lv_pkg CP 'Z*' OR lv_pkg CP 'Y*' OR lv_pkg CP '$*' ).
      ch_target-result-message = 'Package must start with Z, Y or $.'.
      RETURN.
    ENDIF.
    SELECT SINGLE devclass FROM tdevc INTO lv_pkg WHERE devclass = lv_pkg.
    IF sy-subrc <> 0.
      ch_target-result-message = 'Package does not exist.'.
      RETURN.
    ENDIF.
    ch_target-devclass   = lv_pkg.
    ch_target-masterlang = sy-langu.
    IF lv_pkg(1) = '$'.
      ch_target-local = abap_true.
    ENDIF.

    lv_msg = zcl_abapsync_write=>check_auth( im_devclass = ch_target-devclass
                                            im_objtype  = 'PROG'
                                            im_name     = ch_target-name ).
    IF lv_msg IS NOT INITIAL.
      ch_target-result-message = lv_msg.
      RETURN.
    ENDIF.

    "--- source: 255-character ABAP lines
    SPLIT im_part-source AT cl_abap_char_utilities=>newline INTO TABLE li_lines.
    LOOP AT li_lines INTO lv_line.
      lv_idx = sy-tabix.
      lv_len = strlen( lv_line ).
      IF lv_len > 0.
        lv_len = lv_len - 1.
        IF lv_line+lv_len(1) = cl_abap_char_utilities=>cr_lf(1).
          lv_line = lv_line(lv_len).
        ENDIF.
      ENDIF.
      IF strlen( lv_line ) > 255.
        lv_num = lv_idx.
        CONDENSE lv_num.
        CONCATENATE 'Line' lv_num 'is longer than 255 characters.'
          INTO ch_target-result-message SEPARATED BY space.
        RETURN.
      ENDIF.
      lw_abap-line = lv_line.
      APPEND lw_abap TO ch_target-abap.
    ENDLOOP.
    IF ch_target-abap IS INITIAL.
      ch_target-result-message = 'A new program needs source.'.
      RETURN.
    ENDIF.

    "--- the type, from the first statement
    lv_stmt = first_statement( ch_target-abap ).
    IF lv_stmt CP 'REPORT *' OR lv_stmt = 'REPORT.'.
      ch_target-subc = '1'.
    ELSEIF lv_stmt CP 'PROGRAM *' OR lv_stmt = 'PROGRAM.'.
      ch_target-subc = 'M'.
    ELSEIF lv_stmt CP 'FUNCTION-POOL*' OR lv_stmt CP 'CLASS-POOL*'
        OR lv_stmt CP 'INTERFACE-POOL*' OR lv_stmt CP 'TYPE-POOL*'.
      ch_target-result-message = 'Only reports, module pools and includes are created as programs.'.
      RETURN.
    ELSE.
      ch_target-subc = 'I'.
    ENDIF.

    ch_target-title = title_from_push( im_request = im_request im_name = ch_target-name ).
    IF ch_target-title IS INITIAL.
      ch_target-title = ch_target-name.
    ENDIF.

    check_request( EXPORTING im_request = im_request
                             im_object  = 'PROG'
                             im_name    = ch_target-name
                   CHANGING  ch_target  = ch_target ).
    IF ch_target-result-message IS NOT INITIAL.
      RETURN.
    ENDIF.

    ch_target-result-status  = 'ok'.
    ch_target-result-message = 'Ready to create.'.

  ENDMETHOD.


  METHOD check_part.
*&---------------------------------------------------------------------*
    "Common to both kinds: what this is, the name rule, then the kind's
    "own checks. Nothing is written here.

    DATA lv_part TYPE string.

    ex_target-result-index  = im_part-index.
    ex_target-result-status = 'refused'.
    ex_target-create        = im_part-create.
    ex_target-object        = im_part-object.
    ex_target-name          = im_part-name.
    TRANSLATE ex_target-object TO UPPER CASE.
    TRANSLATE ex_target-name   TO UPPER CASE.
    lv_part = im_part-part.
    TRANSLATE lv_part TO LOWER CASE.
    ex_target-part = lv_part.

    IF claims( im_object = ex_target-object im_part = lv_part
               im_create = im_part-create ) = abap_false.
      ex_target-result-message = 'This part is not handled by ZCL_ABAPSYNC_REPO.'.
      RETURN.
    ENDIF.
    IF zcl_abapmcp_tools=>check_custom( ex_target-name ) = abap_false.
      ex_target-result-message = 'Only custom (Z/Y) objects can be changed.'.
      RETURN.
    ENDIF.

    "a transaction is not a program: its own checks
    IF ex_target-object = 'TRAN'.
      ex_target-result-include = ex_target-name.
      check_tran( EXPORTING im_part    = im_part
                            im_request = im_request
                  CHANGING  ch_target  = ex_target ).
      RETURN.
    ENDIF.

    ex_target-program = texts_program( im_object = ex_target-object
                                       im_name   = ex_target-name ).
    ex_target-result-include = ex_target-program.

    IF lv_part = 'texts'.
      check_texts( EXPORTING im_part    = im_part
                             im_request = im_request
                   CHANGING  ch_target  = ex_target ).
    ELSE.
      check_new_program( EXPORTING im_part    = im_part
                                   im_request = im_request
                         CHANGING  ch_target  = ex_target ).
    ENDIF.

  ENDMETHOD.


  METHOD check_request.
*&---------------------------------------------------------------------*
    "Same rules as every other part: a modifiable request holding the
    "lock, and the developer's own task in it (SAP records into it
    "without a dialog only then).

    DATA lv_msg  TYPE string.
    DATA lv_task TYPE trkorr.

    IF ch_target-local = abap_true.
      RETURN.
    ENDIF.

    zcl_abapsync_write=>check_transport( EXPORTING im_transport = im_request-transport
                                                   im_object    = im_object
                                                   im_name      = im_name
                                                   im_include   = ''
                                         IMPORTING ex_request   = ch_target-request
                                                   ex_message   = lv_msg ).
    IF lv_msg IS NOT INITIAL.
      ch_target-result-message = lv_msg.
      RETURN.
    ENDIF.
    ch_target-result-transport = ch_target-request.

    SELECT SINGLE trkorr FROM e070 INTO lv_task
      WHERE strkorr = ch_target-request
        AND as4user = sy-uname
        AND ( trstatus = 'D' OR trstatus = 'L' ).
    IF sy-subrc <> 0.
      CONCATENATE 'You have no modifiable task in request' ch_target-request
                  '- add one for your user in SE09, then push again.'
        INTO ch_target-result-message SEPARATED BY space.
    ENDIF.

  ENDMETHOD.


  METHOD check_texts.
*&---------------------------------------------------------------------*

    DATA lv_obj     TYPE sobj_name.
    DATA lv_type    TYPE trobjtype.
    DATA lv_msg     TYPE string.
    DATA lv_current TYPE string.
    DATA lv_hash    TYPE string.
    DATA lv_new     TYPE abap_bool.
    DATA lw_texts   TYPE t_texts.
    DATA lw_text    TYPE t_text.
    DATA lw_tpool   TYPE textpool.
    DATA lw_part    TYPE t_part.
    DATA lv_part    TYPE string.
    DATA lo_in      TYPE REF TO zif_ajson.
    DATA lx_json    TYPE REF TO zcx_ajson_error.

    "--- the file
    TRY.
        lo_in = zcl_ajson=>parse( im_part-source ).
        lo_in->to_abap( IMPORTING ev_container = lw_texts ).
      CATCH zcx_ajson_error INTO lx_json.
        lv_msg = lx_json->get_text( ).
        CONCATENATE 'The texts file is not valid JSON:' lv_msg
          INTO ch_target-result-message SEPARATED BY space.
        RETURN.
    ENDTRY.
    IF lw_texts-texts IS INITIAL.
      ch_target-result-message = 'The text list is empty - push never deletes texts; use SE38.'.
      RETURN.
    ENDIF.
    LOOP AT lw_texts-texts INTO lw_text.
      CASE lw_text-id.
        WHEN 'R' OR 'I' OR 'S' OR 'H'.
        WHEN OTHERS.
          CONCATENATE 'Text id' lw_text-id 'is not one of R, I, S, H.'
            INTO ch_target-result-message SEPARATED BY space.
          RETURN.
      ENDCASE.
      IF lw_text-id <> 'R' AND lw_text-key IS INITIAL.
        CONCATENATE 'Text' lw_text-id 'needs a key (text symbol number or selection name).'
          INTO ch_target-result-message SEPARATED BY space.
        RETURN.
      ENDIF.
      CLEAR lw_tpool.
      lw_tpool-id     = lw_text-id.
      lw_tpool-key    = lw_text-key.
      lw_tpool-entry  = lw_text-entry.
      lw_tpool-length = lw_text-length.
      IF lw_tpool-length < strlen( lw_text-entry ).
        lw_tpool-length = strlen( lw_text-entry ).
      ENDIF.
      APPEND lw_tpool TO ch_target-tpool.
    ENDLOOP.

    "--- the program exists - or is created by this same push
    lv_obj  = ch_target-name.
    lv_type = ch_target-object.
    SELECT SINGLE devclass masterlang FROM tadir
      INTO (ch_target-devclass, ch_target-masterlang)
      WHERE pgmid = 'R3TR' AND object = lv_type AND obj_name = lv_obj.
    IF sy-subrc <> 0.
      LOOP AT im_request-parts INTO lw_part WHERE create = abap_true.
        lv_part = lw_part-part.
        TRANSLATE lv_part TO LOWER CASE.
        TRANSLATE lw_part-name TO UPPER CASE.
        IF lw_part-name = ch_target-name AND lv_part = 'main'.
          lv_new = abap_true.
        ENDIF.
      ENDLOOP.
      IF lv_new = abap_false.
        ch_target-result-message = 'Program not found - push its source as a new program with --package.'.
        RETURN.
      ENDIF.
      ch_target-devclass = im_request-package.
      TRANSLATE ch_target-devclass TO UPPER CASE.
    ENDIF.
    IF ch_target-masterlang IS INITIAL.
      ch_target-masterlang = sy-langu.
    ENDIF.
    IF ch_target-devclass(1) = '$'.
      ch_target-local = abap_true.
    ENDIF.

    lv_msg = zcl_abapsync_write=>check_auth( im_devclass = ch_target-devclass
                                            im_objtype  = ch_target-object
                                            im_name     = ch_target-name ).
    IF lv_msg IS NOT INITIAL.
      ch_target-result-message = lv_msg.
      RETURN.
    ENDIF.

    "--- drift: SAP must still hold the texts the developer pulled
    IF lv_new = abap_false.
      lv_current = texts_text( im_object = ch_target-object im_name = ch_target-name ).
      IF lv_current IS NOT INITIAL.
        lv_hash = zcl_abapmcp_sync=>hash_text( lv_current ).
      ENDIF.
      IF im_request-force = abap_false AND lv_hash <> im_part-expected_hash.
        ch_target-result-message = 'Changed in SAP since your pull - re-pull, or push with --force.'.
        RETURN.
      ENDIF.
    ENDIF.

    check_request( EXPORTING im_request = im_request
                             im_object  = ch_target-object
                             im_name    = ch_target-name
                   CHANGING  ch_target  = ch_target ).
    IF ch_target-result-message IS NOT INITIAL.
      RETURN.
    ENDIF.

    ch_target-result-status  = 'ok'.
    ch_target-result-message = 'Ready to write.'.

  ENDMETHOD.


  METHOD check_tran.
*&---------------------------------------------------------------------*
    "A NEW report transaction (SE93 'program and selection screen'): a
    "free name, a custom executable program - existing, or created in the
    "same push - screen 1000 unless the file says otherwise, a short
    "text and a package. Changing an existing transaction is not
    "supported yet. Nothing is written here.

    DATA lo_in    TYPE REF TO zif_ajson.
    DATA lx_json  TYPE REF TO zcx_ajson_error.
    DATA lv_tcode TYPE tcode.
    DATA lv_found TYPE tcode.
    DATA lv_val   TYPE string.
    DATA lv_type  TYPE string.
    DATA lv_prog  TYPE progname.
    DATA lv_subc  TYPE subc.
    DATA lv_pkg   TYPE devclass.
    DATA lv_msg   TYPE string.
    DATA lv_same  TYPE abap_bool.
    DATA lw_other TYPE t_part.
    DATA lv_oobj  TYPE string.
    DATA lv_oname TYPE string.
    DATA lv_opart TYPE string.

    IF strlen( ch_target-name ) > 20.
      ch_target-result-message = 'A transaction code is at most 20 characters.'.
      RETURN.
    ENDIF.
    lv_tcode = ch_target-name.

    SELECT SINGLE tcode FROM tstc INTO lv_found WHERE tcode = lv_tcode.
    IF sy-subrc = 0.
      ch_target-result-message = 'Transaction already exists - changing a transaction is not supported yet, use SE93.'.
      RETURN.
    ENDIF.

    TRY.
        lo_in = zcl_ajson=>parse( im_part-source ).
      CATCH zcx_ajson_error INTO lx_json.
        ch_target-result-message = 'The transaction file is not valid JSON.'.
        RETURN.
    ENDTRY.

    "--- the file describes this transaction
    lv_val = lo_in->get( '/tcode' ).
    TRANSLATE lv_val TO UPPER CASE.
    IF lv_val IS NOT INITIAL AND lv_val <> ch_target-name.
      CONCATENATE 'The file is for transaction' lv_val '- its folder says' ch_target-name
        INTO ch_target-result-message SEPARATED BY space.
      RETURN.
    ENDIF.

    lv_type = lo_in->get( '/type' ).
    TRANSLATE lv_type TO UPPER CASE.
    IF lv_type <> 'R'.
      ch_target-result-message = 'Only report transactions (type R: program and selection screen) can be created.'.
      RETURN.
    ENDIF.

    "--- the program: custom, executable, existing or created with it
    lv_val = lo_in->get( '/program' ).
    TRANSLATE lv_val TO UPPER CASE.
    CONDENSE lv_val.
    IF lv_val IS INITIAL OR strlen( lv_val ) > 40.
      ch_target-result-message = 'program is required: the report the transaction starts.'.
      RETURN.
    ENDIF.
    IF zcl_abapmcp_tools=>check_custom( lv_val ) = abap_false.
      ch_target-result-message = 'The program must be a custom (Z/Y) report.'.
      RETURN.
    ENDIF.
    lv_prog = lv_val.
    SELECT SINGLE subc FROM reposrc INTO lv_subc WHERE progname = lv_prog.
    IF sy-subrc = 0.
      IF lv_subc <> '1'.
        CONCATENATE 'Program' lv_val 'is not an executable report (type 1).'
          INTO ch_target-result-message SEPARATED BY space.
        RETURN.
      ENDIF.
    ELSE.
      LOOP AT im_request-parts INTO lw_other.
        lv_oobj  = lw_other-object.
        lv_oname = lw_other-name.
        lv_opart = lw_other-part.
        TRANSLATE lv_oobj  TO UPPER CASE.
        TRANSLATE lv_oname TO UPPER CASE.
        TRANSLATE lv_opart TO LOWER CASE.
        IF lv_oobj = 'PROG' AND lv_oname = lv_val AND lv_opart = 'main'
           AND lw_other-create = abap_true.
          lv_same = abap_true.
        ENDIF.
      ENDLOOP.
      IF lv_same = abap_false.
        CONCATENATE 'Program' lv_val 'does not exist - push it first, or in the same push.'
          INTO ch_target-result-message SEPARATED BY space.
        RETURN.
      ENDIF.
    ENDIF.
    ch_target-tran_prog = lv_prog.

    "--- screen and short text
    lv_val = lo_in->get( '/screen' ).
    CONDENSE lv_val.
    IF lv_val IS INITIAL.
      lv_val = '1000'.
    ENDIF.
    IF strlen( lv_val ) <> 4 OR lv_val CN '0123456789'.
      ch_target-result-message = 'screen must be 4 digits - 1000 is the selection screen of a report.'.
      RETURN.
    ENDIF.
    ch_target-dynpro = lv_val.

    ch_target-title = lo_in->get( '/text' ).
    IF ch_target-title IS INITIAL OR strlen( ch_target-title ) > 36.
      ch_target-result-message = 'text is required, at most 36 characters.'.
      RETURN.
    ENDIF.

    "--- package
    lv_pkg = im_request-package.
    TRANSLATE lv_pkg TO UPPER CASE.
    IF lv_pkg IS INITIAL.
      ch_target-result-message = 'A new transaction needs a package - pass --package.'.
      RETURN.
    ENDIF.
    IF NOT ( lv_pkg CP 'Z*' OR lv_pkg CP 'Y*' OR lv_pkg CP '$*' ).
      ch_target-result-message = 'Package must start with Z, Y or $.'.
      RETURN.
    ENDIF.
    SELECT SINGLE devclass FROM tdevc INTO lv_pkg WHERE devclass = lv_pkg.
    IF sy-subrc <> 0.
      ch_target-result-message = 'Package does not exist.'.
      RETURN.
    ENDIF.
    ch_target-devclass   = lv_pkg.
    ch_target-masterlang = sy-langu.
    IF lv_pkg(1) = '$'.
      ch_target-local = abap_true.
    ENDIF.

    lv_msg = zcl_abapsync_write=>check_auth( im_devclass = ch_target-devclass
                                            im_objtype  = 'TRAN'
                                            im_name     = ch_target-name ).
    IF lv_msg IS NOT INITIAL.
      ch_target-result-message = lv_msg.
      RETURN.
    ENDIF.

    check_request( EXPORTING im_request = im_request
                             im_object  = 'TRAN'
                             im_name    = ch_target-name
                   CHANGING  ch_target  = ch_target ).
    IF ch_target-result-message IS NOT INITIAL.
      RETURN.
    ENDIF.

    ch_target-result-status  = 'ok'.
    ch_target-result-message = 'Ready to create.'.

  ENDMETHOD.


  METHOD claims.
*&---------------------------------------------------------------------*

    DATA lv_part TYPE string.

    lv_part = im_part.
    TRANSLATE lv_part TO LOWER CASE.

    IF lv_part = 'texts' AND ( im_object = 'PROG' OR im_object = 'FUGR' ).
      ex_yes = abap_true.
    ELSEIF im_object = 'PROG' AND im_create = abap_true.
      ex_yes = abap_true.
    ELSEIF im_object = 'TRAN' AND lv_part = 'tran'.
      ex_yes = abap_true.
    ENDIF.

  ENDMETHOD.


  METHOD first_statement.
*&---------------------------------------------------------------------*

    DATA lw_abap TYPE abaptxt255.
    DATA lv_line TYPE string.
    DATA lv_pos  TYPE i.
    DATA lv_last TYPE i.

    LOOP AT im_abap INTO lw_abap.
      lv_line = lw_abap-line.
      CONDENSE lv_line.
      IF lv_line IS INITIAL OR lv_line(1) = '*'.
        CONTINUE.
      ENDIF.
      FIND FIRST OCCURRENCE OF '"' IN lv_line MATCH OFFSET lv_pos.
      IF sy-subrc = 0.
        IF lv_pos = 0.
          CONTINUE.
        ENDIF.
        lv_line = lv_line(lv_pos).
        CONDENSE lv_line.
      ENDIF.
      CONCATENATE ex_text lv_line INTO ex_text SEPARATED BY space.
      lv_last = strlen( lv_line ) - 1.
      IF lv_last >= 0 AND lv_line+lv_last(1) = '.'.
        EXIT.
      ENDIF.
    ENDLOOP.

    CONDENSE ex_text.
    TRANSLATE ex_text TO UPPER CASE.

  ENDMETHOD.


  METHOD is_repo_type.
*&---------------------------------------------------------------------*
    "Object types pulled and pushed through this class alone. PROG and
    "FUGR belong to the source path - only their texts and the creation
    "of programs come here, see CLAIMS.

    IF im_object = 'TRAN'.
      ex_yes = abap_true.
    ENDIF.

  ENDMETHOD.


  METHOD masterlang.
*&---------------------------------------------------------------------*

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


  METHOD run.
*&---------------------------------------------------------------------*
    "check    validate every part, write nothing
    "write    validate again, then save INACTIVE - new programs first, so
    "         their texts find them; transactions last, as they need
    "         their program
    "activate one activation run for what this class wrote

    DATA lo_in     TYPE REF TO zif_ajson.
    DATA lo_out    TYPE REF TO zif_ajson.
    DATA lx_json   TYPE REF TO zcx_ajson_error.
    DATA lw_req    TYPE t_request.
    DATA lw_resp   TYPE t_response.
    DATA lw_part   TYPE t_part.
    DATA lw_target TYPE t_target.
    DATA lv_round  TYPE i.
    DATA lv_part   TYPE string.

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
            lw_target = check_part( im_part = lw_part im_request = lw_req ).
            APPEND lw_target-result TO lw_resp-results.
          ENDLOOP.

        WHEN 'write'.
          "round 1 new programs, round 2 texts, round 3 transactions
          DO 3 TIMES.
            lv_round = sy-index.
            LOOP AT lw_req-parts INTO lw_part.
              lv_part = lw_part-part.
              TRANSLATE lv_part TO LOWER CASE.
              IF ( lv_round = 1 AND ( lv_part = 'texts' OR lv_part = 'tran' ) )
                 OR ( lv_round = 2 AND lv_part <> 'texts' )
                 OR ( lv_round = 3 AND lv_part <> 'tran' ).
                CONTINUE.
              ENDIF.
              lw_target = check_part( im_part = lw_part im_request = lw_req ).
              IF lw_target-result-status = 'ok'.
                IF lv_part = 'texts'.
                  write_texts( CHANGING ch_target = lw_target ).
                ELSEIF lv_part = 'tran'.
                  write_tran( CHANGING ch_target = lw_target ).
                ELSE.
                  write_program( CHANGING ch_target = lw_target ).
                ENDIF.
              ELSE.
                "valid a moment ago in 'check' - something moved in between
                lw_target-result-status = 'error'.
              ENDIF.
              APPEND lw_target-result TO lw_resp-results.
            ENDLOOP.
          ENDDO.

        WHEN 'activate'.
          activate( EXPORTING im_parts    = lw_req-parts
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
        ex_response = '{"error":"ZCL_ABAPSYNC_REPO could not build its answer"}'.
    ENDTRY.

  ENDMETHOD.


  METHOD texts_program.
*&---------------------------------------------------------------------*

    IF im_object = 'FUGR'.
      CONCATENATE 'SAPL' im_name INTO ex_prog.
    ELSE.
      ex_prog = im_name.
    ENDIF.
    TRANSLATE ex_prog TO UPPER CASE.

  ENDMETHOD.


  METHOD texts_text.
*&---------------------------------------------------------------------*
    "Same text every time for the same text pool: the drift check of a
    "push compares the hash of this text with the one taken at pull.

    DATA lv_prog   TYPE progname.
    DATA lv_lang   TYPE sy-langu.
    DATA li_tpool  TYPE t_tpool_tab.
    DATA lw_tpool  TYPE textpool.
    DATA lo_out    TYPE REF TO zif_ajson.
    DATA lx_json   TYPE REF TO zcx_ajson_error.
    DATA lv_idx    TYPE i.
    DATA lv_len    TYPE i.
    DATA lv_i      TYPE string.
    DATA lv_base   TYPE string.
    DATA lv_path   TYPE string.

    IF im_object <> 'PROG' AND im_object <> 'FUGR'.
      RETURN.
    ENDIF.

    lv_prog = texts_program( im_object = im_object im_name = im_name ).
    lv_lang = masterlang( im_object = im_object im_name = im_name ).

    READ TEXTPOOL lv_prog INTO li_tpool LANGUAGE lv_lang STATE 'A'.
    IF sy-subrc <> 0 OR li_tpool IS INITIAL.
      RETURN.
    ENDIF.

    "abapGit drops the empty title SE38 creates for every program
    READ TABLE li_tpool INTO lw_tpool WITH KEY id = 'R'.
    IF sy-subrc = 0 AND lw_tpool-key IS INITIAL AND lw_tpool-entry IS INITIAL.
      DELETE li_tpool INDEX sy-tabix.
    ENDIF.
    IF li_tpool IS INITIAL.
      RETURN.
    ENDIF.
    SORT li_tpool BY id key.

    TRY.
        lo_out = zcl_ajson=>create_empty( ).
        lo_out->keep_item_order( ).
        lo_out->set( iv_path = '/language' iv_val = lv_lang ).
        lo_out->touch_array( '/texts' ).
        LOOP AT li_tpool INTO lw_tpool.
          lv_idx = lv_idx + 1.
          lv_i = lv_idx.
          CONDENSE lv_i.
          CONCATENATE '/texts/' lv_i INTO lv_base.

          CONCATENATE lv_base '/id' INTO lv_path.
          lo_out->set( iv_path = lv_path iv_val = lw_tpool-id ).
          IF lw_tpool-key IS NOT INITIAL.
            CONCATENATE lv_base '/key' INTO lv_path.
            lo_out->set( iv_path = lv_path iv_val = lw_tpool-key ).
          ENDIF.
          CONCATENATE lv_base '/entry' INTO lv_path.
          lo_out->set_string( iv_path = lv_path iv_val = lw_tpool-entry ).
          "the stored length only says something when it is more than the
          "text's own length - text symbols reserve room for translation
          lv_len = lw_tpool-length.
          IF lv_len > strlen( lw_tpool-entry ).
            CONCATENATE lv_base '/length' INTO lv_path.
            lo_out->set_integer( iv_path = lv_path iv_val = lv_len ).
          ENDIF.
        ENDLOOP.
        ex_text = lo_out->stringify( iv_indent = 2 ).
      CATCH zcx_ajson_error INTO lx_json.
        CLEAR ex_text.
        RETURN.
    ENDTRY.

    CONCATENATE ex_text cl_abap_char_utilities=>newline INTO ex_text.

  ENDMETHOD.


  METHOD title_from_push.
*&---------------------------------------------------------------------*
    "The R entry of a texts part for the same program in this push

    DATA lw_part  TYPE t_part.
    DATA lw_texts TYPE t_texts.
    DATA lw_text  TYPE t_text.
    DATA lv_part  TYPE string.
    DATA lv_name  TYPE string.
    DATA lo_in    TYPE REF TO zif_ajson.
    DATA lx_json  TYPE REF TO zcx_ajson_error.

    LOOP AT im_request-parts INTO lw_part.
      lv_part = lw_part-part.
      TRANSLATE lv_part TO LOWER CASE.
      lv_name = lw_part-name.
      TRANSLATE lv_name TO UPPER CASE.
      IF lv_part <> 'texts' OR lv_name <> im_name.
        CONTINUE.
      ENDIF.
      TRY.
          lo_in = zcl_ajson=>parse( lw_part-source ).
          lo_in->to_abap( IMPORTING ev_container = lw_texts ).
        CATCH zcx_ajson_error INTO lx_json.
          RETURN.
      ENDTRY.
      READ TABLE lw_texts-texts INTO lw_text WITH KEY id = 'R'.
      IF sy-subrc = 0.
        ex_title = lw_text-entry.
      ENDIF.
      RETURN.
    ENDLOOP.

  ENDMETHOD.


  METHOD tran_text.
*&---------------------------------------------------------------------*
    "Same text every time for the same transaction - the drift check of a
    "push hashes it. The type is read from TSTC-CINFO the way abapGit
    "does (ZCL_ABAPGIT_OBJECT_TRAN): x'80' report, x'08' OO transaction,
    "x'02' parameter or variant transaction (a variant's parameters start
    "with '@'), anything else a dialog transaction.

    CONSTANTS lc_hex_rep TYPE x VALUE '80'.
    CONSTANTS lc_hex_obj TYPE x VALUE '08'.
    CONSTANTS lc_hex_par TYPE x VALUE '02'.

    DATA lv_tcode TYPE tcode.
    DATA lw_tstc  TYPE tstc.
    DATA lv_ttext TYPE ttext_stct.
    DATA lv_param TYPE tcdparam.
    DATA lv_lang  TYPE sy-langu.
    DATA lv_type  TYPE string.
    DATA lv_val   TYPE string.
    DATA lo_out   TYPE REF TO zif_ajson.
    DATA lx_json  TYPE REF TO zcx_ajson_error.

    lv_tcode = im_name.
    SELECT SINGLE * FROM tstc INTO lw_tstc WHERE tcode = lv_tcode.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.
    SELECT SINGLE param FROM tstcp INTO lv_param WHERE tcode = lv_tcode.

    IF lw_tstc-cinfo O lc_hex_rep.
      lv_type = 'R'.
    ELSEIF lw_tstc-cinfo O lc_hex_obj.
      lv_type = 'O'.
    ELSEIF lw_tstc-cinfo O lc_hex_par.
      IF lv_param(1) = '@'.
        lv_type = 'V'.
      ELSE.
        lv_type = 'P'.
      ENDIF.
    ELSE.
      lv_type = 'D'.
    ENDIF.

    "text in the original language, the logon language when it has none
    lv_lang = masterlang( im_object = 'TRAN' im_name = im_name ).
    SELECT SINGLE ttext FROM tstct INTO lv_ttext
      WHERE sprsl = lv_lang AND tcode = lv_tcode.
    IF sy-subrc <> 0.
      SELECT SINGLE ttext FROM tstct INTO lv_ttext
        WHERE sprsl = sy-langu AND tcode = lv_tcode.
    ENDIF.

    TRY.
        lo_out = zcl_ajson=>create_empty( ).
        lo_out->keep_item_order( ).
        lv_val = lv_tcode.
        lo_out->set_string( iv_path = '/tcode' iv_val = lv_val ).
        lo_out->set_string( iv_path = '/type' iv_val = lv_type ).
        IF lw_tstc-pgmna IS NOT INITIAL.
          lv_val = lw_tstc-pgmna.
          lo_out->set_string( iv_path = '/program' iv_val = lv_val ).
        ENDIF.
        IF lw_tstc-dypno IS NOT INITIAL.
          lv_val = lw_tstc-dypno.
          lo_out->set_string( iv_path = '/screen' iv_val = lv_val ).
        ENDIF.
        lv_val = lv_ttext.
        lo_out->set_string( iv_path = '/text' iv_val = lv_val ).
        IF lv_param IS NOT INITIAL.
          lv_val = lv_param.
          lo_out->set_string( iv_path = '/parameters' iv_val = lv_val ).
        ENDIF.
        ex_text = lo_out->stringify( iv_indent = 2 ).
      CATCH zcx_ajson_error INTO lx_json.
        CLEAR ex_text.
        RETURN.
    ENDTRY.

    CONCATENATE ex_text cl_abap_char_utilities=>newline INTO ex_text.

  ENDMETHOD.


  METHOD write_program.
*&---------------------------------------------------------------------*
    "abapGit: ZCL_ABAPGIT_OBJECTS_PROGRAM->DESERIALIZE_PROGRAM and
    "INSERT_PROGRAM. Saved INACTIVE; ACTIVATE activates it.

    DATA lv_msg     TYPE string.
    DATA lv_obj     TYPE trobj_name.
    DATA lv_title   TYPE rglif-title.
    DATA lv_subrc   TYPE sy-subrc.
    DATA lw_saved   TYPE e070use.
    DATA lw_progdir TYPE progdir.

    FIELD-SYMBOLS <lf_ttab> TYPE any.

    IF ch_target-local = abap_false.
      zcl_abapsync_write=>set_default_request( EXPORTING im_request = ch_target-request
                                               IMPORTING ex_saved   = lw_saved
                                                         ex_message = lv_msg ).
    ENDIF.

    "--- record in the transport (abapGit: object class ABAP)
    IF lv_msg IS INITIAL.
      lv_obj = ch_target-name.
      CALL FUNCTION 'RS_CORR_INSERT'
        EXPORTING
          object              = lv_obj
          object_class        = 'ABAP'
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

    "--- create, inactive. RPY_PROGRAM_INSERT keeps the header line of
    "    TTAB between calls (abapGit clears it first)
    IF lv_msg IS INITIAL.
      ASSIGN ('(SAPLSIFP)TTAB') TO <lf_ttab>.
      IF sy-subrc = 0.
        CLEAR <lf_ttab>.
      ENDIF.
      lv_title = ch_target-title.
      TRY.
          CALL FUNCTION 'RPY_PROGRAM_INSERT'
            EXPORTING
              development_class = ch_target-devclass
              program_name      = ch_target-program
              program_type      = ch_target-subc
              title_string      = lv_title
              save_inactive     = 'I'
              suppress_dialog   = abap_true
            TABLES
              source_extended   = ch_target-abap
            EXCEPTIONS
              already_exists    = 1
              cancelled         = 2
              name_not_allowed  = 3
              permission_error  = 4
              OTHERS            = 5.
          lv_subrc = sy-subrc.
        CATCH cx_sy_dyn_call_param_not_found.
          "older releases do not know SUPPRESS_DIALOG
          CALL FUNCTION 'RPY_PROGRAM_INSERT'
            EXPORTING
              development_class = ch_target-devclass
              program_name      = ch_target-program
              program_type      = ch_target-subc
              title_string      = lv_title
              save_inactive     = 'I'
            TABLES
              source_extended   = ch_target-abap
            EXCEPTIONS
              already_exists    = 1
              cancelled         = 2
              name_not_allowed  = 3
              permission_error  = 4
              OTHERS            = 5.
          lv_subrc = sy-subrc.
      ENDTRY.
      IF lv_subrc <> 0.
        lv_msg = zcl_abapsync_write=>sy_message( ).
        CONCATENATE 'RPY_PROGRAM_INSERT:' lv_msg INTO lv_msg SEPARATED BY space.
      ENDIF.
    ENDIF.

    "--- fixed-point arithmetic and Unicode check on, as SE38 sets them
    IF lv_msg IS INITIAL.
      CALL FUNCTION 'READ_PROGDIR'
        EXPORTING
          i_progname = ch_target-program
          i_state    = 'I'
        IMPORTING
          e_progdir  = lw_progdir
        EXCEPTIONS
          not_exists = 1
          OTHERS     = 2.
      IF sy-subrc = 0 AND ( lw_progdir-fixpt IS INITIAL OR lw_progdir-uccheck IS INITIAL ).
        lw_progdir-fixpt   = abap_true.
        lw_progdir-uccheck = abap_true.
        CALL FUNCTION 'UPDATE_PROGDIR'
          EXPORTING
            i_progdir    = lw_progdir
            i_progname   = lw_progdir-name
            i_state      = lw_progdir-state
          EXCEPTIONS
            not_executed = 1
            OTHERS       = 2.
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

    ch_target-result-status  = 'written'.
    ch_target-result-state   = 'I'.
    ch_target-result-message = 'Program created, saved inactive.'.

  ENDMETHOD.


  METHOD write_texts.
*&---------------------------------------------------------------------*
    "abapGit: ZCL_ABAPGIT_OBJECTS_PROGRAM->DESERIALIZE_TEXTPOOL - the
    "original language is written INACTIVE and activated as REPT.

    DATA lv_msg   TYPE string.
    DATA lv_obj   TYPE trobj_name.
    DATA lw_saved TYPE e070use.
    DATA lv_prog  TYPE progname.

    "--- never texts without their program: when the program could not be
    "    created in this push, the texts would leave an object directory
    "    entry, a transport entry and an inactive text pool behind
    lv_prog = ch_target-program.
    SELECT SINGLE progname FROM reposrc INTO lv_prog WHERE progname = lv_prog.
    IF sy-subrc <> 0.
      ch_target-result-status = 'error'.
      CONCATENATE 'Program' lv_prog 'does not exist - its texts were not written.'
        INTO ch_target-result-message SEPARATED BY space.
      RETURN.
    ENDIF.

    IF ch_target-local = abap_false.
      zcl_abapsync_write=>set_default_request( EXPORTING im_request = ch_target-request
                                               IMPORTING ex_saved   = lw_saved
                                                         ex_message = lv_msg ).
    ENDIF.

    IF lv_msg IS INITIAL.
      lv_obj = ch_target-program.
      CALL FUNCTION 'RS_CORR_INSERT'
        EXPORTING
          object              = lv_obj
          object_class        = 'ABAP'
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

    IF lv_msg IS INITIAL.
      INSERT TEXTPOOL ch_target-program
        FROM ch_target-tpool
        LANGUAGE ch_target-masterlang
        STATE 'I'.
      IF sy-subrc <> 0.
        lv_msg = 'INSERT TEXTPOOL failed.'.
      ENDIF.
    ENDIF.

    IF ch_target-local = abap_false.
      zcl_abapsync_write=>reset_default_request( lw_saved ).
    ENDIF.

    IF lv_msg IS NOT INITIAL.
      ch_target-result-status  = 'error'.
      ch_target-result-message = lv_msg.
      RETURN.
    ENDIF.

    ch_target-result-status  = 'written'.
    ch_target-result-state   = 'I'.
    ch_target-result-message = 'Texts saved inactive.'.

  ENDMETHOD.


  METHOD write_tran.
*&---------------------------------------------------------------------*
    "abapGit: ZCL_ABAPGIT_OBJECT_TRAN->DESERIALIZE - the transport entry
    "(object class TRAN) first, then RPY_TRANSACTION_INSERT without a
    "transport dialog of its own. A transaction is active at once.

    DATA lv_msg    TYPE string.
    DATA lv_obj    TYPE trobj_name.
    DATA lw_saved  TYPE e070use.
    DATA lv_tcode  TYPE tcode.
    DATA lv_prog   TYPE tstc-pgmna.
    DATA lv_dynpro TYPE d020s-dnum.
    DATA lv_text   TYPE tstct-ttext.
    DATA lv_type   TYPE rglif-docutype.
    DATA li_param  TYPE STANDARD TABLE OF rsparam.
    DATA lv_json   TYPE string.

    IF ch_target-local = abap_false.
      zcl_abapsync_write=>set_default_request( EXPORTING im_request = ch_target-request
                                               IMPORTING ex_saved   = lw_saved
                                                         ex_message = lv_msg ).
    ENDIF.

    IF lv_msg IS INITIAL.
      lv_obj = ch_target-name.
      CALL FUNCTION 'RS_CORR_INSERT'
        EXPORTING
          object              = lv_obj
          object_class        = 'TRAN'
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

    IF lv_msg IS INITIAL.
      lv_tcode  = ch_target-name.
      lv_prog   = ch_target-tran_prog.
      lv_dynpro = ch_target-dynpro.
      lv_text   = ch_target-title.
      lv_type   = 'R'.
      CALL FUNCTION 'RPY_TRANSACTION_INSERT'
        EXPORTING
          transaction             = lv_tcode
          program                 = lv_prog
          dynpro                  = lv_dynpro
          language                = ch_target-masterlang
          development_class       = ch_target-devclass
          transaction_type        = lv_type
          shorttext               = lv_text
          called_transaction      = space
          called_transaction_skip = space
          variant                 = space
          cl_independend          = space
          html_enabled            = abap_true
          java_enabled            = abap_true
          wingui_enabled          = abap_true
          suppress_corr_insert    = abap_true
        TABLES
          param_values            = li_param
        EXCEPTIONS
          cancelled               = 1
          already_exist           = 2
          permission_error        = 3
          name_not_allowed        = 4
          name_conflict           = 5
          illegal_type            = 6
          object_inconsistent     = 7
          db_access_error         = 8
          OTHERS                  = 9.
      IF sy-subrc <> 0.
        lv_msg = zcl_abapsync_write=>sy_message( ).
        CONCATENATE 'RPY_TRANSACTION_INSERT:' lv_msg INTO lv_msg SEPARATED BY space.
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

    lv_json = tran_text( ch_target-name ).
    ch_target-result-status   = 'written'.
    ch_target-result-state    = 'A'.
    ch_target-result-new_hash = zcl_abapmcp_sync=>hash_text( lv_json ).
    ch_target-result-message  = 'Transaction created.'.

  ENDMETHOD.


ENDCLASS.
