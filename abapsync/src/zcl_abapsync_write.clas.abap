CLASS zcl_abapsync_write DEFINITION PUBLIC FINAL CREATE PUBLIC.
*--------------------------------------------------------------------*
* Title       : abapsync write endpoint (ICF /sap/bc/zabapsync)
* Type        : Interface (inbound HTTP, ICF handler)
* Frequency   : On demand - one call per 'abapsync push'
* Description : The only write path of the abapsync CLI. Receives
*               changed ABAP source as JSON, validates every part
*               (Z/Y scope, S_DEVELOP, ZMCP_USE, drift, transport)
*               and only if ALL parts pass records them in the
*               transport, saves them inactive and activates them in
*               one run. Every part is logged in ZABAPSYNC_LOG.
*               Development systems only - SCC4 and the
*               ZABAPMCP_CFG kill switch refuse writes elsewhere.
*--------------------------------------------------------------------*
*&---------------------------------------------------------------------*
*& abapsync write path - ICF handler for /sap/bc/zabapsync
*&
*& The ONLY place abapsync writes to SAP. Deliberately separate from
*& the read-only MCP node /sap/bc/mcp, so no AI client configured
*& against /sap/bc/mcp can ever change code.
*&
*& SCOPE: existing source includes of programs (PROG) and function
*& groups (FUGR: main, TOP/Fxx/... includes, function module bodies),
*& new function modules, (0.4.0) global classes - existing ones
*& changed, new ones created - and (0.5.0) tables and structures, via
*& ZCL_ABAPSYNC_DDIC. Interfaces are refused.
*&
*& CLASSES (0.4.0): a part with object "CLAS" and part "pubsec",
*& "protsec", "privsec", "locals_def", "locals_imp", "macros",
*& "testclasses" or "method.<NAME>". All parts of one class are written
*& together: the full class source is rebuilt from the pushed parts plus
*& what SAP holds for the others, and handed to abapGit's OO layer
*& (ZCL_ABAPGIT_OO_CLASS, deserialize_source - the 7.02 route that keeps
*& SEOCOMPO and friends in step with the source). A new class is a set of
*& parts with "create":true and the package in the request.
*&
*& NEW FUNCTION MODULES (0.3.0): a FUGR part with "create":true and
*& part "fm.<NAME>" creates the function module in an existing group.
*& The interface comes as structured JSON ("fm": import/export/
*& changing/tables/exceptions), never from the interface comments - SAP
*& generates that block itself. Sequence, as abapGit's
*& ZCL_ABAPGIT_OBJECT_FUGR->DESERIALIZE_FUNCTIONS does it on 7.02:
*&   RS_FUNCTIONMODULE_INSERT  create FM + interface, record LIMU FUNC
*&   RPY_INCLUDE_UPDATE        save the body into the generated include
*&   RS_WORKING_OBJECTS_ACTIVATE  activate FUNC with its include
*&
*& The write sequence follows abapGit (ZCL_ABAPGIT_OBJECTS_PROGRAM,
*& ZCL_ABAPGIT_CTS_API, ZCL_ABAPGIT_OBJECTS_ACTIVATION), which runs on
*& NW 7.02:
*&   RS_CORR_INSERT            record the object in the transport
*&   RPY_INCLUDE_UPDATE        save the source as an INACTIVE version
*&   RS_WORKING_OBJECTS_ACTIVATE  activate (runs the syntax check)
*&
*& Request, JSON POST:
*&   { "action":"check"|"push", "transport":"DEVK900123",
*&     "activate":true, "force":false,
*&     "parts":[ { "object":"PROG", "name":"ZREPORT", "part":"main",
*&                 "include":"ZREPORT", "expected_hash":"...",
*&                 "source":"REPORT zreport.\n..." } ] }
*&
*& All parts are validated first. If ANY part is refused, nothing is
*& written. 'check' stops after validation (server-side dry run).
*&
*& NW 7.02 syntax only: no inline DATA( ), no VALUE #( ), no NEW.
*&---------------------------------------------------------------------*
  PUBLIC SECTION.

    INTERFACES if_http_extension.

    CONSTANTS c_max_parts   TYPE i VALUE 100.
    CONSTANTS c_max_line    TYPE i VALUE 255.
    "Push gate: an authorization object with fields ZUSER and ACTVT that
    "restricts this codebase to its developers (create it in SU21, or
    "point this constant at an existing one). Mandatory - no role, no
    "push. Checked with ACTVT 03; switch to 23 if push must need Maintain.
    CONSTANTS c_auth_object TYPE xuobject VALUE 'ZMCP_USE'.
    CONSTANTS c_auth_actvt  TYPE c LENGTH 2 VALUE '03'.
    CONSTANTS c_version     TYPE string VALUE '0.9.3'.
    "The class running this request is never pushed through itself
    CONSTANTS c_self        TYPE string VALUE 'ZCL_ABAPSYNC_WRITE'.
    "abapGit's class writer; called by name so this class activates
    "without abapGit and answers with a clear message when it is absent
    CONSTANTS c_oo_class    TYPE string VALUE 'ZCL_ABAPGIT_OO_CLASS'.
    CONSTANTS c_oo_prefix   TYPE string VALUE 'ZIF_ABAPGIT_OO_OBJECT_FNC~'.
    CONSTANTS c_max_desc    TYPE i VALUE 60.
    "Dictionary objects are handled by this class, called by name, so the
    "write node activates without it and refuses tables with a clear
    "message until it is pushed (with abapsync - it is an ordinary class)
    CONSTANTS c_ddic_class  TYPE string VALUE 'ZCL_ABAPSYNC_DDIC'.
    "New programs and text elements: same contract, same reasons
    CONSTANTS c_repo_class  TYPE string VALUE 'ZCL_ABAPSYNC_REPO'.
    "Syntax check of a class before activation (0.7.0), called by name
    CONSTANTS c_check_class TYPE string VALUE 'ZCL_ABAPSYNC_CHECK'.
    "Work after a class is active (0.8.0), called by name
    CONSTANTS c_post_class  TYPE string VALUE 'ZCL_ABAPSYNC_POST'.

    "--- shared with ZCL_ABAPSYNC_DDIC (0.5.0): the same transport,
    "    authorization and default-request rules for every object type

    "The given request must be modifiable and must be the one holding the
    "object's lock, if any. A task is resolved to its request.
    CLASS-METHODS check_transport
      IMPORTING im_transport     TYPE string
                im_object        TYPE string
                im_name          TYPE string
                im_include       TYPE progname
      EXPORTING ex_request       TYPE trkorr
                ex_message       TYPE string.

    "S_DEVELOP change + the push gate (C_AUTH_OBJECT). '' when allowed.
    CLASS-METHODS check_auth
      IMPORTING im_devclass   TYPE devclass
                im_objtype    TYPE string
                im_name       TYPE string
      RETURNING VALUE(ex_msg) TYPE string.

    "RS_FUNCTIONMODULE_INSERT, the class builder and the dictionary
    "record the transport themselves and would show the 'choose request'
    "popup - a dump (DYNPRO_SEND_IN_BACKGROUND) over HTTP. A default
    "request for the session suppresses it, exactly as
    "ZCL_ABAPGIT_DEFAULT_TRANSPORT does (TR_TASK_GET / _SET / _RESET).
    CLASS-METHODS set_default_request
      IMPORTING im_request TYPE trkorr
      EXPORTING ex_saved   TYPE e070use
                ex_message TYPE string.

    CLASS-METHODS reset_default_request
      IMPORTING im_saved TYPE e070use.

    CLASS-METHODS sy_message
      RETURNING VALUE(ex_text) TYPE string.

  PROTECTED SECTION.

  PRIVATE SECTION.

    "One function module parameter, as the CLI reads it from the SE37
    "interface comment block. typing: blank, TYPE, LIKE, TYPE REF TO
    "or STRUCTURE
    TYPES: BEGIN OF t_in_param,
             name     TYPE string,
             typing   TYPE string,
             type     TYPE string,
             optional TYPE abap_bool,
             default  TYPE string,
             by_value TYPE abap_bool,
           END OF t_in_param,
           t_in_param_tab TYPE STANDARD TABLE OF t_in_param WITH DEFAULT KEY.

    TYPES: BEGIN OF t_in_fm,
             import     TYPE t_in_param_tab,
             export     TYPE t_in_param_tab,
             changing   TYPE t_in_param_tab,
             tables     TYPE t_in_param_tab,
             exceptions TYPE string_table,
           END OF t_in_fm.

    TYPES: BEGIN OF t_in_part,
             object        TYPE string,
             name          TYPE string,
             part          TYPE string,
             include       TYPE string,
             expected_hash TYPE string,
             source        TYPE string,
             create        TYPE abap_bool,
             short_text    TYPE string,
             fm            TYPE t_in_fm,
           END OF t_in_part,
           t_in_part_tab TYPE STANDARD TABLE OF t_in_part WITH DEFAULT KEY.

    TYPES: BEGIN OF t_request,
             action    TYPE string,
             transport TYPE string,
             package   TYPE string,   "only for new classes
             activate  TYPE abap_bool,
             force     TYPE abap_bool,
             parts     TYPE t_in_part_tab,
           END OF t_request.

    TYPES: BEGIN OF t_result,
             object    TYPE string,
             name      TYPE string,
             part      TYPE string,
             include   TYPE string,
             status    TYPE string,   "ok | refused | written | error
             message   TYPE string,
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
             ok                  TYPE abap_bool,
             action              TYPE string,
             user                TYPE string,
             system              TYPE string,
             activation_ran      TYPE abap_bool,
             activation_ok       TYPE abap_bool,
             results             TYPE t_result_tab,
             activation_messages TYPE t_msg_tab,
             error               TYPE string,
           END OF t_response.

    TYPES t_abap_tab TYPE STANDARD TABLE OF abaptxt255 WITH DEFAULT KEY.

    "One validated part, carrying everything the write step needs.
    "kind: INCL change an existing include | NEWFUNC create a function module
    "      CLASS one part of a global class (written together, see WRITE_CLASS)
    TYPES: BEGIN OF t_work,
             result      TYPE t_result,
             kind        TYPE string,
             cls_part    TYPE string,    "CLASS: part name, lower case
             cls_new     TYPE abap_bool, "CLASS/DDIC: the object does not exist yet
             cls_text    TYPE string,    "CLASS: description of a new class
             ddic_src    TYPE string,    "DDIC: the JSON definition as pushed
             ddic_hash   TYPE string,    "DDIC: hash the developer pulled
             include     TYPE progname,
             devclass    TYPE devclass,
             masterlang  TYPE sy-langu,
             local       TYPE abap_bool,
             request     TYPE trkorr,
             abap        TYPE t_abap_tab,
             funcname    TYPE rs38l_fnam,
             short_text  TYPE tftit-stext,
             fm_import   TYPE STANDARD TABLE OF rsimp WITH DEFAULT KEY,
             fm_export   TYPE STANDARD TABLE OF rsexp WITH DEFAULT KEY,
             fm_changing TYPE STANDARD TABLE OF rscha WITH DEFAULT KEY,
             fm_tables   TYPE STANDARD TABLE OF rstbl WITH DEFAULT KEY,
             fm_except   TYPE STANDARD TABLE OF rsexc WITH DEFAULT KEY,
           END OF t_work,
           t_work_tab TYPE STANDARD TABLE OF t_work WITH DEFAULT KEY.

    "The JSON contract with ZCL_ABAPSYNC_DDIC=>RUN. Mirrored here rather
    "than referenced, so this class does not depend on that one.
    TYPES: BEGIN OF t_ddic_part,
             index         TYPE i,
             object        TYPE string,
             name          TYPE string,
             part          TYPE string,
             expected_hash TYPE string,
             source        TYPE string,
             create        TYPE abap_bool,
           END OF t_ddic_part,
           t_ddic_part_tab TYPE STANDARD TABLE OF t_ddic_part WITH DEFAULT KEY.

    TYPES: BEGIN OF t_ddic_request,
             action    TYPE string,
             transport TYPE string,
             package   TYPE string,
             force     TYPE abap_bool,
             parts     TYPE t_ddic_part_tab,
           END OF t_ddic_request.

    TYPES: BEGIN OF t_ddic_result,
             index     TYPE i,
             status    TYPE string,
             message   TYPE string,
             include   TYPE string,
             transport TYPE string,
             new_hash  TYPE string,
             state     TYPE string,
           END OF t_ddic_result,
           t_ddic_result_tab TYPE STANDARD TABLE OF t_ddic_result WITH DEFAULT KEY.

    TYPES: BEGIN OF t_ddic_response,
             results  TYPE t_ddic_result_tab,
             messages TYPE t_msg_tab,
             error    TYPE string,
           END OF t_ddic_response.

    CLASS-METHODS process
      IMPORTING im_request         TYPE t_request
      RETURNING VALUE(ex_response) TYPE t_response.

    CLASS-METHODS check_part
      IMPORTING im_part      TYPE t_in_part
                im_request   TYPE t_request
      RETURNING VALUE(ex_work) TYPE t_work.

    CLASS-METHODS check_include_belongs
      IMPORTING im_object    TYPE string
                im_name      TYPE string
                im_include   TYPE string
      RETURNING VALUE(ex_ok) TYPE abap_bool.

    CLASS-METHODS fm_interface_unchanged
      IMPORTING im_include   TYPE progname
                im_new       TYPE string_table
      RETURNING VALUE(ex_ok) TYPE abap_bool.

    "LF-separated text -> 255-character ABAP lines (CR stripped)
    CLASS-METHODS split_source
      IMPORTING im_source  TYPE string
      EXPORTING ex_abap    TYPE t_abap_tab
                ex_lines   TYPE string_table
                ex_message TYPE string.

    CLASS-METHODS check_create_func
      IMPORTING im_part        TYPE t_in_part
                im_request     TYPE t_request
      RETURNING VALUE(ex_work) TYPE t_work.

    "--- stage 2: global classes (0.4.0) ---------------------------------
    "Validates one class part. Nothing is written here.
    CLASS-METHODS check_class_part
      IMPORTING im_part        TYPE t_in_part
                im_request     TYPE t_request
      RETURNING VALUE(ex_work) TYPE t_work.

    "Include of a class part: the class builder's own naming, never the
    "client's word. '' for a method that does not exist yet.
    CLASS-METHODS class_include
      IMPORTING im_class          TYPE string
                im_part           TYPE string
      RETURNING VALUE(ex_include) TYPE progname.

    "Upper-case text of the first statement, comments dropped
    CLASS-METHODS first_statement
      IMPORTING im_lines       TYPE string_table
      RETURNING VALUE(ex_text) TYPE string.

    "Limits of what can be created from files: '' when acceptable
    CLASS-METHODS check_new_class
      IMPORTING im_name       TYPE string
                im_works      TYPE t_work_tab
      RETURNING VALUE(ex_msg) TYPE string.

    "Pushed text of a class part, else what SAP holds now
    CLASS-METHODS part_lines
      IMPORTING im_name         TYPE string
                im_part         TYPE string
                im_works        TYPE t_work_tab
      RETURNING VALUE(ex_lines) TYPE string_table.

    "Full class source (definition + implementation) as abapGit's scanner
    "expects it
    CLASS-METHODS assemble_class
      IMPORTING im_name   TYPE string
                im_works  TYPE t_work_tab
      EXPORTING ex_source TYPE string_table.

    "Runs the class scanner over the assembled source - the dry run for
    "'check'. '' when it scans cleanly.
    CLASS-METHODS scan_class
      IMPORTING im_name       TYPE string
                im_works      TYPE t_work_tab
      RETURNING VALUE(ex_msg) TYPE string.

    "Writes every part of one class in a single pass
    CLASS-METHODS write_class
      IMPORTING im_name      TYPE string
      CHANGING  ch_work_tab  TYPE t_work_tab.

    CLASS-METHODS abap_lines
      IMPORTING im_abap         TYPE t_abap_tab
      RETURNING VALUE(ex_lines) TYPE string_table.

    CLASS-METHODS read_lines
      IMPORTING im_include      TYPE progname
      RETURNING VALUE(ex_lines) TYPE string_table.

    "JSON parameters -> RSIMP/RSEXP/RSCHA/RSTBL/RSEXC rows.
    "ch_msg stays '' when valid (7.02: no RETURNING next to CHANGING).
    CLASS-METHODS map_fm_interface
      IMPORTING im_fm   TYPE t_in_fm
      CHANGING  ch_work TYPE t_work
                ch_msg  TYPE string.

    CLASS-METHODS map_param
      IMPORTING im_param  TYPE t_in_param
                im_kind   TYPE string
      CHANGING  ch_target TYPE any
                ch_error  TYPE string.

    "Fields are set by name, so a field missing on this release is a
    "clear refusal instead of a syntax error in the whole class.
    CLASS-METHODS set_field
      IMPORTING im_field  TYPE string
                im_value  TYPE any
      CHANGING  ch_target TYPE any
                ch_error  TYPE string.

    "Dispatch: create a function module, or write an existing include
    CLASS-METHODS write_part
      CHANGING ch_work TYPE t_work.

    CLASS-METHODS write_include
      CHANGING ch_work TYPE t_work.

    CLASS-METHODS create_func
      CHANGING ch_work TYPE t_work.

    CLASS-METHODS get_title
      IMPORTING im_include      TYPE progname
                im_lang         TYPE sy-langu
      RETURNING VALUE(ex_title) TYPE repti.

    CLASS-METHODS activate
      IMPORTING im_request     TYPE t_request
      CHANGING  ch_work_tab    TYPE t_work_tab
                ch_response    TYPE t_response.

    CLASS-METHODS hash_abap
      IMPORTING im_abap        TYPE t_abap_tab
      RETURNING VALUE(ex_hash) TYPE string.

    CLASS-METHODS client_allows_changes
      RETURNING VALUE(ex_ok) TYPE abap_bool.

    "Kill switch without a transport: ZABAPMCP_CFG key ABAPSYNC_WRITE
    "set to OFF refuses every push. Absent means on. Same table the MCP
    "server already uses for TOOLS_DISABLED and CAPTURE_BODIES.
    CLASS-METHODS write_enabled
      RETURNING VALUE(ex_ok) TYPE abap_bool.

    CLASS-METHODS log_part
      IMPORTING im_result TYPE t_result
                im_action TYPE string.

    "ZCL_ABAPSYNC_DDIC=>IS_DDIC_TYPE, called by name. When the class
    "cannot answer, the known dictionary types still count, so their parts
    "reach DDIC_CALL and get its 'class missing' message.
    CLASS-METHODS is_ddic_object
      IMPORTING im_object     TYPE string
      RETURNING VALUE(ex_yes) TYPE abap_bool.

    "Work after a class is active: method descriptions (0.8.0)
    CLASS-METHODS post_class
      IMPORTING im_class   TYPE string
      EXPORTING ex_message TYPE string.

    "Syntax of a class as activation will compile it (0.7.0)
    CLASS-METHODS class_check
      IMPORTING im_class   TYPE string
      EXPORTING ex_ok      TYPE abap_bool
                ex_checked TYPE abap_bool
                ex_message TYPE string.

    "Syntax of a program or include as activation will compile it (0.9.3)
    CLASS-METHODS program_check
      IMPORTING im_include TYPE string
      EXPORTING ex_ok      TYPE abap_bool
                ex_checked TYPE abap_bool
                ex_message TYPE string.

    "ZCL_ABAPSYNC_REPO=>CLAIMS, called by name: new programs and text
    "elements. When the class cannot answer, those parts still count,
    "so they get DDIC_CALL's 'class missing' message.
    CLASS-METHODS is_repo_part
      IMPORTING im_object     TYPE string
                im_part       TYPE string
                im_create     TYPE abap_bool
      RETURNING VALUE(ex_yes) TYPE abap_bool.

    "Hands the parts of one kind (DDIC or REPO) to that kind's class -
    "ZCL_ABAPSYNC_DDIC or ZCL_ABAPSYNC_REPO=>RUN - as JSON (action check |
    "write | activate) and copies its answer back into the matching work
    "rows, found by their position. The name is from the first kind.
    CLASS-METHODS ddic_call
      IMPORTING im_action    TYPE string
                im_request   TYPE t_request
                im_kind      TYPE string DEFAULT 'DDIC'
      EXPORTING ex_messages  TYPE t_msg_tab
      CHANGING  ch_work_tab  TYPE t_work_tab.

    CLASS-METHODS send_json
      IMPORTING im_server TYPE REF TO if_http_server
                im_status TYPE i
                im_data   TYPE t_response.

ENDCLASS.


CLASS zcl_abapsync_write IMPLEMENTATION.

  METHOD abap_lines.

    DATA lw_abap TYPE abaptxt255.
    DATA lv_line TYPE string.

    LOOP AT im_abap INTO lw_abap.
      lv_line = lw_abap-line.
      APPEND lv_line TO ex_lines.
    ENDLOOP.

  ENDMETHOD.


  METHOD activate.
    "One activation run for everything written, so SAP resolves the
    "order itself (abapGit: ZCL_ABAPGIT_OBJECTS_ACTIVATION->ACTIVATE_OLD).

    DATA li_objects   TYPE STANDARD TABLE OF dwinactiv.
    DATA lw_object    TYPE dwinactiv.
    DATA lo_checklist TYPE REF TO cl_wb_checklist.
    DATA li_errors    TYPE swbme_error_tab.
    DATA lw_error     LIKE LINE OF li_errors.
    DATA lv_text      TYPE string.
    DATA lw_msg       TYPE t_msg.
    DATA lv_active    TYPE string.
    DATA lv_all_ok    TYPE abap_bool.
    DATA lv_incl      TYPE string.
    DATA lv_subrc     TYPE sy-subrc.
    DATA li_inactive  TYPE STANDARD TABLE OF dwinactiv.
    DATA lv_grp_name  TYPE trobj_name.
    DATA lv_grp_type  TYPE trobjtype.
    DATA lv_uxx       TYPE string.
    DATA lv_prog      TYPE progname.
    DATA lv_prog_open TYPE progname.
    DATA li_ddic_msg  TYPE t_msg_tab.
    DATA lv_ddic_ok   TYPE abap_bool VALUE abap_true.
    DATA lv_has_ddic  TYPE abap_bool.
    DATA lv_cls_name  TYPE string.
    DATA lv_cls_ok    TYPE abap_bool.
    DATA lv_cls_chk   TYPE abap_bool.
    DATA lv_cls_msg   TYPE string.
    DATA lv_syntax_ok TYPE abap_bool VALUE abap_true.
    DATA lv_part_lc   TYPE string.
    DATA lv_has_def   TYPE abap_bool.

    FIELD-SYMBOLS <lf_work> TYPE t_work.

    "--- dictionary first, in its own mass activation (abapGit activates
    "    DDIC before everything else for the same reason): programs and
    "    classes of this push may use the new or changed tables
    CLEAR lv_has_ddic.
    LOOP AT ch_work_tab TRANSPORTING NO FIELDS
         WHERE kind = 'DDIC' AND result-status = 'written'.
      lv_has_ddic = abap_true.
      EXIT.
    ENDLOOP.
    IF lv_has_ddic = abap_true.
      ch_response-activation_ran = abap_true.
      ddic_call( EXPORTING im_action   = 'activate'
                           im_request  = im_request
                 IMPORTING ex_messages = li_ddic_msg
                 CHANGING  ch_work_tab = ch_work_tab ).
      APPEND LINES OF li_ddic_msg TO ch_response-activation_messages.
      LOOP AT ch_work_tab TRANSPORTING NO FIELDS
           WHERE kind = 'DDIC' AND result-status = 'written' AND result-state <> 'A'.
        lv_ddic_ok = abap_false.
        EXIT.
      ENDLOOP.
    ENDIF.

    "--- texts of a program or function group whose source is also in
    "    this push wait until that source is active (0.9.0): a new
    "    selection text only activates against the new selection screen
    LOOP AT ch_work_tab ASSIGNING <lf_work>
         WHERE kind = 'REPO' AND result-status = 'written'.
      lv_part_lc = <lf_work>-result-part.
      TRANSLATE lv_part_lc TO LOWER CASE.
      IF lv_part_lc <> 'texts'.
        CONTINUE.
      ENDIF.
      LOOP AT ch_work_tab TRANSPORTING NO FIELDS
           WHERE result-object = <lf_work>-result-object
             AND result-name   = <lf_work>-result-name
             AND result-status = 'written'
             AND kind <> 'REPO' AND kind <> 'DDIC' AND kind <> 'CLASS'.
        <lf_work>-result-status = 'deferred'.
        lv_has_def = abap_true.
        EXIT.
      ENDLOOP.
    ENDLOOP.

    "--- then new programs and text pools, activated by ZCL_ABAPSYNC_REPO,
    "    before the source objects that may include a new program
    CLEAR lv_has_ddic.
    LOOP AT ch_work_tab TRANSPORTING NO FIELDS
         WHERE kind = 'REPO' AND result-status = 'written'.
      lv_has_ddic = abap_true.
      EXIT.
    ENDLOOP.
    IF lv_has_ddic = abap_true.
      ch_response-activation_ran = abap_true.
      ddic_call( EXPORTING im_action   = 'activate'
                           im_request  = im_request
                           im_kind     = 'REPO'
                 IMPORTING ex_messages = li_ddic_msg
                 CHANGING  ch_work_tab = ch_work_tab ).
      APPEND LINES OF li_ddic_msg TO ch_response-activation_messages.
      LOOP AT ch_work_tab TRANSPORTING NO FIELDS
           WHERE kind = 'REPO' AND result-status = 'written' AND result-state <> 'A'.
        lv_ddic_ok = abap_false.
        EXIT.
      ENDLOOP.
    ENDIF.

    LOOP AT ch_work_tab ASSIGNING <lf_work> WHERE result-status = 'written'.
      "the dictionary and the repository delegate are done above
      IF <lf_work>-kind = 'DDIC' OR <lf_work>-kind = 'REPO'.
        CONTINUE.
      ENDIF.
      "a class is activated as one object (abapGit adds CLAS, not its
      "includes); duplicates of the same class are removed below
      IF <lf_work>-kind = 'CLASS'.
        lw_object-object   = 'CLAS'.
        lw_object-obj_name = <lf_work>-result-name.
        APPEND lw_object TO li_objects.
        CONTINUE.
      ENDIF.
      lw_object-object   = 'REPS'.
      lw_object-obj_name = <lf_work>-include.
      APPEND lw_object TO li_objects.
      IF <lf_work>-kind <> 'NEWFUNC'.
        CONTINUE.
      ENDIF.

      "new function module: the FUNC entry carries interface + include
      lw_object-object   = 'FUNC'.
      lw_object-obj_name = <lf_work>-funcname.
      APPEND lw_object TO li_objects.

      "plus whatever RS_FUNCTIONMODULE_INSERT left inactive for it in the
      "group (the UXX include it extended) - nothing else of the group
      CONCATENATE 'L' <lf_work>-result-name 'UXX' INTO lv_uxx.
      lv_grp_name = <lf_work>-result-name.
      lv_grp_type = 'FUGR'.
      CLEAR li_inactive.
      CALL FUNCTION 'RS_INACTIVE_OBJECTS_IN_OBJECT'
        EXPORTING
          obj_name         = lv_grp_name
          object           = lv_grp_type
        TABLES
          inactive_objects = li_inactive
        EXCEPTIONS
          object_not_found = 1
          OTHERS           = 2.
      IF sy-subrc = 0.
        LOOP AT li_inactive INTO lw_object.
          IF lw_object-obj_name = lv_uxx.
            APPEND lw_object TO li_objects.
          ENDIF.
        ENDLOOP.
      ENDIF.
    ENDLOOP.
    SORT li_objects BY object obj_name.
    DELETE ADJACENT DUPLICATES FROM li_objects COMPARING object obj_name.

    "only dictionary objects in this push: nothing more to activate
    IF li_objects IS INITIAL.
      COMMIT WORK.
      ch_response-activation_ok = lv_ddic_ok.
      RETURN.
    ENDIF.

    "--- every class as activation will compile it (0.7.0). SAP's mass
    "    activation activates a class whose syntax check fails; then the
    "    broken class is the active one. One error: activate nothing.
    "    Programs and includes too (0.9.3): for them the same activation
    "    asks "activate anyway?" - a popup that dumps over HTTP.
    LOOP AT li_objects INTO lw_object WHERE object = 'CLAS' OR object = 'REPS'.
      lv_cls_name = lw_object-obj_name.
      IF lw_object-object = 'CLAS'.
        class_check( EXPORTING im_class   = lv_cls_name
                     IMPORTING ex_ok      = lv_cls_ok
                               ex_checked = lv_cls_chk
                               ex_message = lv_cls_msg ).
      ELSE.
        program_check( EXPORTING im_include = lv_cls_name
                       IMPORTING ex_ok      = lv_cls_ok
                                 ex_checked = lv_cls_chk
                                 ex_message = lv_cls_msg ).
      ENDIF.
      IF lv_cls_ok = abap_false.
        lv_syntax_ok = abap_false.
        CLEAR lw_msg.
        lw_msg-object = lv_cls_name.
        lw_msg-text   = lv_cls_msg.
        APPEND lw_msg TO ch_response-activation_messages.
      ELSEIF lv_cls_chk = abap_false AND lv_cls_msg IS NOT INITIAL.
        CLEAR lw_msg.
        lw_msg-object = lv_cls_name.
        CONCATENATE `Not checked before activation: ` lv_cls_msg INTO lw_msg-text.
        APPEND lw_msg TO ch_response-activation_messages.
      ENDIF.
    ENDLOOP.

    IF lv_syntax_ok = abap_false.
      CLEAR lw_msg.
      lw_msg-text = 'Nothing was activated: a class or program has syntax errors (see above). What was written is saved inactive; the active versions are unchanged. Fix the source and push again.'.
      APPEND lw_msg TO ch_response-activation_messages.
      LOOP AT ch_work_tab ASSIGNING <lf_work> WHERE result-status = 'written'.
        IF <lf_work>-kind = 'DDIC' OR <lf_work>-kind = 'REPO'.
          CONTINUE.
        ENDIF.
        <lf_work>-result-state   = 'I'.
        <lf_work>-result-message = 'Saved inactive - not activated, a class or program of this push has syntax errors.'.
      ENDLOOP.
      LOOP AT ch_work_tab ASSIGNING <lf_work> WHERE result-status = 'deferred'.
        <lf_work>-result-status  = 'written'.
        <lf_work>-result-state   = 'I'.
        <lf_work>-result-message = 'Saved inactive - not activated, a class or program of this push has syntax errors.'.
      ENDLOOP.
      COMMIT WORK.
      ch_response-activation_ran = abap_true.
      ch_response-activation_ok  = abap_false.
      RETURN.
    ENDIF.

    ch_response-activation_ran = abap_true.

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
        "7.02 may not know UI_DECOUPLED - same call without it
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
      lw_msg-object = ''.
      lw_msg-text   = sy_message( ).
      APPEND lw_msg TO ch_response-activation_messages.
    ENDIF.

    IF lo_checklist IS BOUND.
      lo_checklist->get_error_messages( IMPORTING p_error_tab = li_errors ).
      LOOP AT li_errors INTO lw_error WHERE mtype = 'E'.
        CLEAR lw_msg.
        lw_msg-object = lw_error-object_text.
        CONCATENATE LINES OF lw_error-mtext INTO lw_msg-text SEPARATED BY space.
        APPEND lw_msg TO ch_response-activation_messages.
      ENDLOOP.
    ENDIF.

    COMMIT WORK.

    "--- the truth is the active source: did each include become active?
    lv_all_ok = lv_ddic_ok.
    LOOP AT ch_work_tab ASSIGNING <lf_work> WHERE result-status = 'written'.

      "dictionary and repository parts were judged by their own class
      IF <lf_work>-kind = 'DDIC' OR <lf_work>-kind = 'REPO'.
        CONTINUE.
      ENDIF.

      "a class part is judged by whether an inactive version is left:
      "the class builder may lay the text out a little differently from
      "what was pushed, so a hash comparison would call a good
      "activation a failure. The hash reported back is SAP's own.
      IF <lf_work>-kind = 'CLASS'.
        lv_prog = <lf_work>-include.
        CLEAR lv_prog_open.
        IF lv_prog IS NOT INITIAL.
          SELECT SINGLE progname FROM reposrc INTO lv_prog_open
            WHERE progname = lv_prog AND r3state = 'I'.
        ENDIF.
        IF lv_prog_open IS NOT INITIAL.
          <lf_work>-result-state   = 'I'.
          <lf_work>-result-message = 'Saved inactive - activation failed, see activation messages.'.
          lv_all_ok = abap_false.
        ELSE.
          lv_incl = <lf_work>-include.
          <lf_work>-result-state    = 'A'.
          <lf_work>-result-new_hash = zcl_abapmcp_sync=>include_hash( lv_incl ).
          IF <lf_work>-cls_new = abap_true.
            <lf_work>-result-message = 'Class created and activated.'.
          ELSE.
            <lf_work>-result-message = 'Saved and activated.'.
          ENDIF.
        ENDIF.
        CONTINUE.
      ENDIF.

      lv_incl = <lf_work>-include.
      lv_active = zcl_abapmcp_sync=>include_hash( lv_incl ).
      IF lv_active = <lf_work>-result-new_hash.
        <lf_work>-result-state   = 'A'.
        IF <lf_work>-kind = 'NEWFUNC'.
          <lf_work>-result-message = 'Function module created and activated.'.
        ELSE.
          <lf_work>-result-message = 'Saved and activated.'.
        ENDIF.
      ELSE.
        <lf_work>-result-state   = 'I'.
        <lf_work>-result-message = 'Saved inactive - activation failed, see activation messages.'.
        lv_all_ok = abap_false.
      ENDIF.
    ENDLOOP.

    "--- the deferred texts, now that their source is active (0.9.0).
    "    Activating the program drops its inactive text pool, so they
    "    are written again and then activated (0.9.1). Only they go to
    "    ZCL_ABAPSYNC_REPO: the parts it activated above are held back,
    "    because activating an active object again asks POPUP_TO_DECIDE
    "    and dumps over HTTP. Texts whose source did not activate stay
    "    inactive.
    IF lv_has_def = abap_true.
      LOOP AT ch_work_tab ASSIGNING <lf_work> WHERE kind = 'REPO'.
        IF <lf_work>-result-status = 'written'.
          <lf_work>-result-status = 'held'.
        ELSEIF <lf_work>-result-status = 'deferred'.
          <lf_work>-result-status = 'ok'.
          LOOP AT ch_work_tab TRANSPORTING NO FIELDS
               WHERE result-object = <lf_work>-result-object
                 AND result-name   = <lf_work>-result-name
                 AND result-status = 'written'
                 AND result-state  <> 'A'
                 AND kind <> 'REPO' AND kind <> 'DDIC' AND kind <> 'CLASS'.
            <lf_work>-result-status  = 'held'.
            <lf_work>-result-state   = 'I'.
            <lf_work>-result-message = 'Saved inactive - not activated, the source of this program did not activate.'.
            EXIT.
          ENDLOOP.
        ENDIF.
      ENDLOOP.
      ddic_call( EXPORTING im_action   = 'write'
                           im_request  = im_request
                           im_kind     = 'REPO'
                 IMPORTING ex_messages = li_ddic_msg
                 CHANGING  ch_work_tab = ch_work_tab ).
      APPEND LINES OF li_ddic_msg TO ch_response-activation_messages.
      ddic_call( EXPORTING im_action   = 'activate'
                           im_request  = im_request
                           im_kind     = 'REPO'
                 IMPORTING ex_messages = li_ddic_msg
                 CHANGING  ch_work_tab = ch_work_tab ).
      APPEND LINES OF li_ddic_msg TO ch_response-activation_messages.
      LOOP AT ch_work_tab ASSIGNING <lf_work>
           WHERE kind = 'REPO' AND result-status = 'held'.
        <lf_work>-result-status = 'written'.
      ENDLOOP.
      LOOP AT ch_work_tab ASSIGNING <lf_work> WHERE kind = 'REPO'.
        IF <lf_work>-result-status = 'error' OR <lf_work>-result-status = 'refused'
           OR ( <lf_work>-result-status = 'written' AND <lf_work>-result-state <> 'A' ).
          lv_all_ok = abap_false.
          EXIT.
        ENDIF.
      ENDLOOP.
    ENDIF.

    ch_response-activation_ok = lv_all_ok.

    "--- after a fully successful activation: per class, the follow-up
    "    work of ZCL_ABAPSYNC_POST (0.8.0: method descriptions)
    IF lv_all_ok = abap_true.
      LOOP AT li_objects INTO lw_object WHERE object = 'CLAS'.
        lv_cls_name = lw_object-obj_name.
        post_class( EXPORTING im_class   = lv_cls_name
                    IMPORTING ex_message = lv_cls_msg ).
        IF lv_cls_msg IS NOT INITIAL.
          CLEAR lw_msg.
          lw_msg-object = lv_cls_name.
          lw_msg-text   = lv_cls_msg.
          APPEND lw_msg TO ch_response-activation_messages.
        ENDIF.
      ENDLOOP.
      COMMIT WORK.
    ENDIF.

  ENDMETHOD.


  METHOD assemble_class.
    "The full class source the scanner (and abapGit) expect: the three
    "sections, ENDCLASS, then CLASS ... IMPLEMENTATION with every method.
    "Methods are in name order, as the pull writes them. Local classes
    "are not part of it - they have includes of their own.

    DATA li_names TYPE string_table.
    DATA li_part  TYPE string_table.
    DATA li_meth  TYPE seop_methods_w_include.
    DATA lw_meth  LIKE LINE OF li_meth.
    DATA lv_mname TYPE string.
    DATA lv_sec   TYPE string.
    DATA lv_line  TYPE string.
    DATA lv_new   TYPE abap_bool.
    DATA lv_cls   TYPE seoclsname.

    FIELD-SYMBOLS <lf_work> TYPE t_work.

    CLEAR ex_source.

    LOOP AT im_works ASSIGNING <lf_work> WHERE kind = 'CLASS' AND result-name = im_name.
      lv_new = <lf_work>-cls_new.
      EXIT.
    ENDLOOP.

    "--- definition
    DO 3 TIMES.
      CASE sy-index.
        WHEN 1.
          lv_sec = 'pubsec'.
        WHEN 2.
          lv_sec = 'protsec'.
        WHEN OTHERS.
          lv_sec = 'privsec'.
      ENDCASE.
      li_part = part_lines( im_name = im_name im_part = lv_sec im_works = im_works ).
      APPEND LINES OF li_part TO ex_source.
    ENDDO.
    APPEND 'ENDCLASS.' TO ex_source.
    APPEND '' TO ex_source.

    "--- implementation: every method SAP has, plus any new one pushed
    CONCATENATE 'CLASS' im_name 'IMPLEMENTATION.' INTO lv_line SEPARATED BY space.
    APPEND lv_line TO ex_source.

    IF lv_new = abap_false.
      lv_cls  = im_name.
      li_meth = cl_oo_classname_service=>get_all_method_includes( lv_cls ).
      LOOP AT li_meth INTO lw_meth.
        lv_mname = lw_meth-cpdkey-cpdname.
        APPEND lv_mname TO li_names.
      ENDLOOP.
    ENDIF.
    LOOP AT im_works ASSIGNING <lf_work> WHERE kind = 'CLASS' AND result-name = im_name.
      IF strlen( <lf_work>-cls_part ) > 7 AND <lf_work>-cls_part(7) = 'method.'.
        lv_mname = <lf_work>-cls_part+7.
        TRANSLATE lv_mname TO UPPER CASE.
        APPEND lv_mname TO li_names.
      ENDIF.
    ENDLOOP.
    SORT li_names.
    DELETE ADJACENT DUPLICATES FROM li_names.

    LOOP AT li_names INTO lv_mname.
      CONCATENATE 'method.' lv_mname INTO lv_sec.
      TRANSLATE lv_sec TO LOWER CASE.
      li_part = part_lines( im_name = im_name im_part = lv_sec im_works = im_works ).
      APPEND LINES OF li_part TO ex_source.
    ENDLOOP.

    APPEND 'ENDCLASS.' TO ex_source.

  ENDMETHOD.


  METHOD check_auth.

    DATA lv_objtype TYPE c LENGTH 4.
    DATA lv_name40  TYPE c LENGTH 40.

    lv_objtype = im_objtype.
    lv_name40  = im_name.
    AUTHORITY-CHECK OBJECT 'S_DEVELOP'
      ID 'DEVCLASS' FIELD im_devclass
      ID 'OBJTYPE'  FIELD lv_objtype
      ID 'OBJNAME'  FIELD lv_name40
      ID 'P_GROUP'  DUMMY
      ID 'ACTVT'    FIELD '02'.
    IF sy-subrc <> 0.
      ex_msg = 'No S_DEVELOP change authorization for this object.'.
      RETURN.
    ENDIF.

    "--- codebase gate: only developers holding C_AUTH_OBJECT may push
    AUTHORITY-CHECK OBJECT c_auth_object
      ID 'ZUSER' FIELD sy-uname
      ID 'ACTVT' FIELD c_auth_actvt.
    IF sy-subrc <> 0.
      CONCATENATE 'No' c_auth_object 'authorization (ACTVT' c_auth_actvt
                  ') - push is limited to this codebase''s developers.'
        INTO ex_msg SEPARATED BY space.
    ENDIF.

  ENDMETHOD.


  METHOD check_class_part.
    "One part of a global class. Nothing is written here; every rule that
    "can refuse the push is checked now, as for the other parts.

    DATA lv_name    TYPE string.
    DATA lv_part    TYPE string.
    DATA lv_given   TYPE string.
    DATA lv_known   TYPE abap_bool.
    DATA lv_exists  TYPE abap_bool.
    DATA lv_cls     TYPE sobj_name.
    DATA lv_pkg     TYPE devclass.
    DATA lv_msg     TYPE string.
    DATA lv_current TYPE string.
    DATA lv_incl    TYPE string.
    DATA lv_task    TYPE trkorr.
    DATA li_lines   TYPE string_table.

    ex_work-kind          = 'CLASS'.
    ex_work-cls_new       = im_part-create.
    ex_work-result-object = 'CLAS'.
    ex_work-result-name   = im_part-name.
    ex_work-result-part   = im_part-part.
    ex_work-result-status = 'refused'.
    TRANSLATE ex_work-result-name TO UPPER CASE.
    lv_name = ex_work-result-name.
    lv_part = im_part-part.
    TRANSLATE lv_part TO LOWER CASE.
    ex_work-cls_part = lv_part.

    "--- which part of the class this is
    CASE lv_part.
      WHEN 'pubsec' OR 'protsec' OR 'privsec' OR 'locals_def'
        OR 'locals_imp' OR 'macros' OR 'testclasses'.
        lv_known = abap_true.
      WHEN OTHERS.
        IF strlen( lv_part ) > 7 AND lv_part(7) = 'method.'.
          lv_known = abap_true.
        ENDIF.
    ENDCASE.
    IF lv_known = abap_false.
      ex_work-result-message = 'Class part must be pubsec, protsec, privsec, locals_def, locals_imp, macros, testclasses or method.<NAME>.'.
      RETURN.
    ENDIF.

    "--- never the class that is running this very request
    IF lv_name = c_self.
      ex_work-result-message = 'ZCL_ABAPSYNC_WRITE is the class running this request - change it in SE24.'.
      RETURN.
    ENDIF.

    "--- namespace guard (same rule as the MCP tools)
    IF zcl_abapmcp_tools=>check_custom( lv_name ) = abap_false.
      ex_work-result-message = 'Only custom (Z/Y) objects can be changed.'.
      RETURN.
    ENDIF.

    "--- does the class exist, and where does it live
    lv_cls = lv_name.
    SELECT SINGLE devclass masterlang FROM tadir
      INTO (ex_work-devclass, ex_work-masterlang)
      WHERE pgmid = 'R3TR' AND object = 'CLAS' AND obj_name = lv_cls.
    IF sy-subrc = 0.
      lv_exists = abap_true.
    ENDIF.

    IF im_part-create = abap_true.
      IF lv_exists = abap_true.
        ex_work-result-message = 'Class already exists - pull it and push changes instead.'.
        RETURN.
      ENDIF.
      lv_pkg = im_request-package.
      TRANSLATE lv_pkg TO UPPER CASE.
      IF lv_pkg IS INITIAL.
        ex_work-result-message = 'A new class needs a package - pass --package.'.
        RETURN.
      ENDIF.
      IF NOT ( lv_pkg CP 'Z*' OR lv_pkg CP 'Y*' OR lv_pkg CP '$*' ).
        ex_work-result-message = 'Package must start with Z, Y or $.'.
        RETURN.
      ENDIF.
      SELECT SINGLE devclass FROM tdevc INTO lv_pkg WHERE devclass = lv_pkg.
      IF sy-subrc <> 0.
        ex_work-result-message = 'Package does not exist.'.
        RETURN.
      ENDIF.
      IF strlen( im_part-short_text ) > c_max_desc.
        ex_work-result-message = 'Class description is longer than 60 characters.'.
        RETURN.
      ENDIF.
      ex_work-devclass   = lv_pkg.
      ex_work-masterlang = sy-langu.
      IF im_part-short_text IS INITIAL.
        ex_work-cls_text = lv_name.
      ELSE.
        ex_work-cls_text = im_part-short_text.
      ENDIF.
    ELSE.
      IF lv_exists = abap_false.
        ex_work-result-message = 'Class not found - a new class is pushed as a set of files with --package.'.
        RETURN.
      ENDIF.
      IF ex_work-masterlang IS INITIAL.
        ex_work-masterlang = sy-langu.
      ENDIF.
    ENDIF.
    IF ex_work-devclass(1) = '$'.
      ex_work-local = abap_true.
    ENDIF.

    "--- authorization: S_DEVELOP as SE24 checks it, plus the push gate
    lv_msg = check_auth( im_devclass = ex_work-devclass
                         im_objtype  = 'CLAS'
                         im_name     = lv_name ).
    IF lv_msg IS NOT INITIAL.
      ex_work-result-message = lv_msg.
      RETURN.
    ENDIF.

    "--- source
    split_source( EXPORTING im_source  = im_part-source
                  IMPORTING ex_abap    = ex_work-abap
                            ex_lines   = li_lines
                            ex_message = lv_msg ).
    IF lv_msg IS NOT INITIAL.
      ex_work-result-message = lv_msg.
      RETURN.
    ENDIF.

    "--- the include is the class builder's name for this part; the
    "    client's include, if given, must agree (no writing a foreign
    "    include by claiming a Z class)
    ex_work-include        = class_include( im_class = lv_name im_part = lv_part ).
    ex_work-result-include = ex_work-include.
    lv_given = im_part-include.
    TRANSLATE lv_given TO UPPER CASE.
    IF lv_given IS NOT INITIAL AND ex_work-include IS NOT INITIAL
       AND lv_given <> ex_work-include.
      ex_work-result-message = 'Include does not belong to this class part.'.
      RETURN.
    ENDIF.

    "--- drift check: SAP must still hold what the developer pulled. A
    "    part with no include yet (a new method) has nothing to drift.
    IF im_part-create = abap_false AND ex_work-include IS NOT INITIAL.
      lv_incl    = ex_work-include.
      lv_current = zcl_abapmcp_sync=>include_hash( lv_incl ).
      IF im_request-force = abap_false AND lv_current <> im_part-expected_hash.
        ex_work-result-message = 'Changed in SAP since your pull - re-pull, or push with --force.'.
        RETURN.
      ENDIF.
    ENDIF.

    "--- transport rules
    IF ex_work-local = abap_false.
      check_transport( EXPORTING im_transport = im_request-transport
                                 im_object    = 'CLAS'
                                 im_name      = lv_name
                                 im_include   = ex_work-include
                       IMPORTING ex_request   = ex_work-request
                                 ex_message   = lv_msg ).
      IF lv_msg IS NOT INITIAL.
        ex_work-result-message = lv_msg.
        RETURN.
      ENDIF.
      ex_work-result-transport = ex_work-request.

      "the class builder records into the developer's own task; without
      "one it would ask which request to use - impossible over HTTP
      SELECT SINGLE trkorr FROM e070 INTO lv_task
        WHERE strkorr = ex_work-request
          AND as4user = sy-uname
          AND ( trstatus = 'D' OR trstatus = 'L' ).
      IF sy-subrc <> 0.
        CONCATENATE 'You have no modifiable task in request' ex_work-request
                    '- add one for your user in SE09, then push again.'
          INTO ex_work-result-message SEPARATED BY space.
        RETURN.
      ENDIF.
    ENDIF.

    ex_work-result-status = 'ok'.
    IF im_part-create = abap_true.
      ex_work-result-message = 'Ready to create.'.
    ELSE.
      ex_work-result-message = 'Ready to write.'.
    ENDIF.

  ENDMETHOD.


  METHOD check_create_func.
    "A new function module in an existing Z/Y function group. Nothing is
    "written here - all checks first, as for every other part.

    DATA lv_fm      TYPE string.
    DATA lv_len     TYPE i.
    DATA lv_msg     TYPE string.
    DATA lv_found   TYPE rs38l_fnam.
    DATA lv_objname TYPE sobj_name.
    DATA li_lines   TYPE string_table.
    DATA lv_line    TYPE string.
    DATA lv_first   TYPE string.
    DATA lv_expect  TYPE string.
    DATA lv_task    TYPE trkorr.

    ex_work-kind           = 'NEWFUNC'.
    ex_work-result-object  = im_part-object.
    ex_work-result-name    = im_part-name.
    ex_work-result-part    = im_part-part.
    ex_work-result-status  = 'refused'.
    TRANSLATE ex_work-result-object TO UPPER CASE.
    TRANSLATE ex_work-result-name   TO UPPER CASE.

    IF ex_work-result-object <> 'FUGR'.
      ex_work-result-message = 'New function modules are created in a function group - object must be FUGR.'.
      RETURN.
    ENDIF.

    "--- part is fm.<NAME>
    lv_len = strlen( im_part-part ).
    IF lv_len < 4.
      ex_work-result-message = 'Part of a new function module must be fm.<NAME>.'.
      RETURN.
    ENDIF.
    IF im_part-part(3) <> 'fm.'.
      ex_work-result-message = 'Part of a new function module must be fm.<NAME>.'.
      RETURN.
    ENDIF.
    lv_fm = im_part-part+3.
    TRANSLATE lv_fm TO UPPER CASE.
    IF strlen( lv_fm ) > 30.
      ex_work-result-message = 'Function module name is longer than 30 characters.'.
      RETURN.
    ENDIF.
    IF lv_fm CN 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_'.
      ex_work-result-message = 'Function module name may only hold letters, digits and _ (no namespaces).'.
      RETURN.
    ENDIF.
    ex_work-funcname = lv_fm.

    "--- namespace guard on both the group and the new name
    IF zcl_abapmcp_tools=>check_custom( ex_work-result-name ) = abap_false
      OR zcl_abapmcp_tools=>check_custom( lv_fm ) = abap_false.
      ex_work-result-message = 'Only custom (Z/Y) function groups and function modules can be created.'.
      RETURN.
    ENDIF.

    "--- the group exists, and where it lives
    lv_objname = ex_work-result-name.
    SELECT SINGLE devclass masterlang FROM tadir
      INTO (ex_work-devclass, ex_work-masterlang)
      WHERE pgmid = 'R3TR' AND object = 'FUGR' AND obj_name = lv_objname.
    IF sy-subrc <> 0.
      ex_work-result-message = 'Function group not found - create the group in SE80 first.'.
      RETURN.
    ENDIF.
    IF ex_work-masterlang IS INITIAL.
      ex_work-masterlang = sy-langu.
    ENDIF.
    IF ex_work-devclass(1) = '$'.
      ex_work-local = abap_true.
    ENDIF.

    "--- the function module must not exist yet, in any group
    SELECT SINGLE funcname FROM tfdir INTO lv_found WHERE funcname = ex_work-funcname.
    IF sy-subrc = 0.
      ex_work-result-message = 'Function module already exists - pull its group and push changes instead.'.
      RETURN.
    ENDIF.

    lv_msg = check_auth( im_devclass = ex_work-devclass
                         im_objtype  = 'FUGR'
                         im_name     = ex_work-result-name ).
    IF lv_msg IS NOT INITIAL.
      ex_work-result-message = lv_msg.
      RETURN.
    ENDIF.

    "--- source
    split_source( EXPORTING im_source  = im_part-source
                  IMPORTING ex_abap    = ex_work-abap
                            ex_lines   = li_lines
                            ex_message = lv_msg ).
    IF lv_msg IS NOT INITIAL.
      ex_work-result-message = lv_msg.
      RETURN.
    ENDIF.

    "first statement must be FUNCTION <name>.
    LOOP AT li_lines INTO lv_line.
      CONDENSE lv_line.
      IF lv_line IS INITIAL.
        CONTINUE.
      ENDIF.
      IF lv_line(1) = '*' OR lv_line(1) = '"'.
        CONTINUE.
      ENDIF.
      lv_first = lv_line.
      EXIT.
    ENDLOOP.
    TRANSLATE lv_first TO UPPER CASE.
    CONCATENATE 'FUNCTION' lv_fm INTO lv_expect SEPARATED BY space.
    CONCATENATE lv_expect '.' INTO lv_expect.
    IF lv_first <> lv_expect.
      CONCATENATE 'Source must start with' lv_expect INTO ex_work-result-message SEPARATED BY space.
      RETURN.
    ENDIF.

    "--- interface and short text
    CLEAR lv_msg.
    map_fm_interface( EXPORTING im_fm   = im_part-fm
                      CHANGING  ch_work = ex_work
                                ch_msg  = lv_msg ).
    IF lv_msg IS NOT INITIAL.
      ex_work-result-message = lv_msg.
      RETURN.
    ENDIF.
    IF strlen( im_part-short_text ) > 74.
      ex_work-result-message = 'Short text is longer than 74 characters.'.
      RETURN.
    ENDIF.
    IF im_part-short_text IS INITIAL.
      ex_work-short_text = lv_fm.
    ELSE.
      ex_work-short_text = im_part-short_text.
    ENDIF.

    "--- transport rules (lock check on R3TR FUGR; no include exists yet)
    IF ex_work-local = abap_false.
      check_transport( EXPORTING im_transport = im_request-transport
                                 im_object    = 'FUGR'
                                 im_name      = ex_work-result-name
                                 im_include   = ''
                       IMPORTING ex_request   = ex_work-request
                                 ex_message   = lv_msg ).
      IF lv_msg IS NOT INITIAL.
        ex_work-result-message = lv_msg.
        RETURN.
      ENDIF.
      ex_work-result-transport = ex_work-request.

      "SAP records the new function module in the developer's own task;
      "without one it would ask which request to use - impossible here
      SELECT SINGLE trkorr FROM e070 INTO lv_task
        WHERE strkorr = ex_work-request
          AND as4user = sy-uname
          AND ( trstatus = 'D' OR trstatus = 'L' ).
      IF sy-subrc <> 0.
        CONCATENATE 'You have no modifiable task in request' ex_work-request
                    '- add one for your user in SE09, then push again.'
          INTO ex_work-result-message SEPARATED BY space.
        RETURN.
      ENDIF.
    ENDIF.

    ex_work-result-status  = 'ok'.
    ex_work-result-message = 'Ready to create.'.

  ENDMETHOD.


  METHOD check_include_belongs.

    DATA lv_prefix TYPE string.
    DATA lv_len    TYPE i.
    DATA lv_prog   TYPE progname.
    DATA lv_found  TYPE progname.

    IF im_object = 'PROG'.
      IF im_include <> im_name.
        RETURN.
      ENDIF.
    ELSE.
      "FUGR: SAPL<group> or L<group><3 characters>
      CONCATENATE 'SAPL' im_name INTO lv_prefix.
      IF im_include <> lv_prefix.
        CONCATENATE 'L' im_name INTO lv_prefix.
        lv_len = strlen( lv_prefix ).
        IF strlen( im_include ) <> lv_len + 3.
          RETURN.
        ENDIF.
        IF im_include(lv_len) <> lv_prefix.
          RETURN.
        ENDIF.
      ENDIF.
    ENDIF.

    lv_prog = im_include.
    SELECT SINGLE name FROM trdir INTO lv_found WHERE name = lv_prog.
    IF sy-subrc = 0.
      ex_ok = abap_true.
    ENDIF.

  ENDMETHOD.


  METHOD check_new_class.
    "What can be created from files today: a plain global class. Anything
    "that needs class metadata beyond the source (superclass, interfaces,
    "abstract, non-public creation, friends, test class) is refused with
    "the way round it, rather than created half right.

    DATA lv_stmt   TYPE string.
    DATA lv_expect TYPE string.
    DATA lv_line   TYPE string.
    DATA lv_found  TYPE abap_bool.
    DATA li_lines  TYPE string_table.

    FIELD-SYMBOLS <lf_work> TYPE t_work.

    LOOP AT im_works ASSIGNING <lf_work>
         WHERE kind = 'CLASS' AND result-name = im_name AND cls_part = 'pubsec'.
      li_lines = abap_lines( im_abap = <lf_work>-abap ).
      lv_found = abap_true.
    ENDLOOP.
    IF lv_found = abap_false.
      ex_msg = 'A new class needs its pubsec file (the CLASS ... DEFINITION part).'.
      RETURN.
    ENDIF.

    lv_stmt = first_statement( im_lines = li_lines ).
    CONCATENATE 'CLASS' im_name 'DEFINITION' INTO lv_expect SEPARATED BY space.
    CONCATENATE lv_expect '*' INTO lv_expect.
    IF lv_stmt NP lv_expect.
      ex_msg = 'The pubsec file must start with CLASS <name> DEFINITION, with the class name matching the folder.'.
      RETURN.
    ENDIF.
    IF lv_stmt NS ' PUBLIC'.
      ex_msg = 'Only global classes can be created - the definition must say PUBLIC.'.
      RETURN.
    ENDIF.
    IF lv_stmt CS ' INHERITING FROM' OR lv_stmt CS ' ABSTRACT'
       OR lv_stmt CS ' CREATE PROTECTED' OR lv_stmt CS ' CREATE PRIVATE'
       OR lv_stmt CS ' FOR TESTING' OR lv_stmt CS ' FRIENDS'.
      ex_msg = 'A new class must be plain: no INHERITING FROM, ABSTRACT, CREATE PROTECTED/PRIVATE, FRIENDS or FOR TESTING yet. Create the shell in SE24 once, then push changes.'.
      RETURN.
    ENDIF.

    "INTERFACES makes SEOIMPLEMENTING entries the scanner is not trusted
    "to derive for a brand-new class
    LOOP AT im_works ASSIGNING <lf_work> WHERE kind = 'CLASS' AND result-name = im_name.
      IF <lf_work>-cls_part = 'pubsec' OR <lf_work>-cls_part = 'protsec'
         OR <lf_work>-cls_part = 'privsec'.
        li_lines = abap_lines( im_abap = <lf_work>-abap ).
        LOOP AT li_lines INTO lv_line.
          CONDENSE lv_line.
          TRANSLATE lv_line TO UPPER CASE.
          IF lv_line CP 'INTERFACES*'.
            ex_msg = 'A new class cannot implement interfaces yet. Create the shell in SE24 once, then push changes.'.
            RETURN.
          ENDIF.
        ENDLOOP.
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD check_part.

    DATA lv_obj      TYPE trobjtype.
    DATA lv_objname  TYPE sobj_name.
    DATA lv_current  TYPE string.
    DATA li_lines    TYPE string_table.
    DATA lv_len      TYPE i.
    DATA lv_msg      TYPE string.
    DATA lv_suffix   TYPE string.
    DATA lv_objtype  TYPE string.

    lv_objtype = im_part-object.
    TRANSLATE lv_objtype TO UPPER CASE.
    IF lv_objtype = 'CLAS'.
      ex_work = check_class_part( im_part = im_part im_request = im_request ).
      RETURN.
    ENDIF.

    "new programs and text elements: recorded here, judged by
    "ZCL_ABAPSYNC_REPO in PROCESS (step 1d). Before the function module
    "route below, which would otherwise take a new PROG for a new FM.
    IF is_repo_part( im_object = lv_objtype
                     im_part   = im_part-part
                     im_create = im_part-create ) = abap_true.
      ex_work-kind           = 'REPO'.
      ex_work-cls_new        = im_part-create.
      ex_work-ddic_src       = im_part-source.
      ex_work-ddic_hash      = im_part-expected_hash.
      ex_work-result-object  = lv_objtype.
      ex_work-result-name    = im_part-name.
      ex_work-result-part    = im_part-part.
      ex_work-result-include = im_part-include.
      TRANSLATE ex_work-result-name    TO UPPER CASE.
      TRANSLATE ex_work-result-include TO UPPER CASE.
      ex_work-result-status  = 'ok'.
      ex_work-result-message = 'Waiting for the repository check.'.
      RETURN.
    ENDIF.

    "dictionary objects: recorded here, judged by ZCL_ABAPSYNC_DDIC in
    "PROCESS (step 1c) together with the other dictionary parts. Which
    "types count is that class's answer, so a new one needs no change here.
    IF is_ddic_object( lv_objtype ) = abap_true.
      ex_work-kind           = 'DDIC'.
      ex_work-cls_new        = im_part-create.
      ex_work-ddic_src       = im_part-source.
      ex_work-ddic_hash      = im_part-expected_hash.
      ex_work-result-object  = lv_objtype.
      ex_work-result-name    = im_part-name.
      ex_work-result-part    = im_part-part.
      ex_work-result-include = im_part-name.
      TRANSLATE ex_work-result-name    TO UPPER CASE.
      TRANSLATE ex_work-result-include TO UPPER CASE.
      ex_work-result-status  = 'ok'.
      ex_work-result-message = 'Waiting for the dictionary check.'.
      RETURN.
    ENDIF.

    IF im_part-create = abap_true.
      ex_work = check_create_func( im_part = im_part im_request = im_request ).
      RETURN.
    ENDIF.

    ex_work-kind           = 'INCL'.
    ex_work-result-object  = im_part-object.
    ex_work-result-name    = im_part-name.
    ex_work-result-part    = im_part-part.
    ex_work-result-include = im_part-include.
    ex_work-result-status  = 'refused'.
    TRANSLATE ex_work-result-object  TO UPPER CASE.
    TRANSLATE ex_work-result-name    TO UPPER CASE.
    TRANSLATE ex_work-result-include TO UPPER CASE.
    ex_work-include = ex_work-result-include.

    "--- scope: classes are routed above; interfaces are stage 3
    IF ex_work-result-object = 'INTF'.
      ex_work-result-message = 'Interface push is not supported yet - use SE24.'.
      RETURN.
    ENDIF.
    IF ex_work-result-object <> 'PROG' AND ex_work-result-object <> 'FUGR'.
      ex_work-result-message = 'Only PROG and FUGR can be pushed.'.
      RETURN.
    ENDIF.

    "--- namespace guard (same rule as the MCP tools)
    IF zcl_abapmcp_tools=>check_custom( ex_work-result-name ) = abap_false.
      ex_work-result-message = 'Only custom (Z/Y) objects can be changed.'.
      RETURN.
    ENDIF.

    "--- the object exists, and where it lives
    lv_obj     = ex_work-result-object.
    lv_objname = ex_work-result-name.
    SELECT SINGLE devclass masterlang FROM tadir
      INTO (ex_work-devclass, ex_work-masterlang)
      WHERE pgmid = 'R3TR' AND object = lv_obj AND obj_name = lv_objname.
    IF sy-subrc <> 0.
      ex_work-result-message = 'Object not found - creating new objects is not supported yet.'.
      RETURN.
    ENDIF.
    IF ex_work-masterlang IS INITIAL.
      ex_work-masterlang = sy-langu.
    ENDIF.
    IF ex_work-devclass(1) = '$'.
      ex_work-local = abap_true.
    ENDIF.

    "--- the include really belongs to this object (no writing a
    "    foreign include by claiming a Z object)
    IF check_include_belongs( im_object  = ex_work-result-object
                              im_name    = ex_work-result-name
                              im_include = ex_work-result-include ) = abap_false.
      ex_work-result-message = 'Include does not belong to this object, or does not exist.'.
      RETURN.
    ENDIF.

    "--- authorization: S_DEVELOP as SE38/SE37 check it, plus the push gate
    lv_msg = check_auth( im_devclass = ex_work-devclass
                         im_objtype  = ex_work-result-object
                         im_name     = ex_work-result-name ).
    IF lv_msg IS NOT INITIAL.
      ex_work-result-message = lv_msg.
      RETURN.
    ENDIF.

    "--- drift check: SAP must still hold what the developer pulled
    lv_current = zcl_abapmcp_sync=>include_hash( ex_work-result-include ).
    IF im_request-force = abap_false AND lv_current <> im_part-expected_hash.
      ex_work-result-message = 'Changed in SAP since your pull - re-pull, or push with --force.'.
      RETURN.
    ENDIF.

    "--- source: LF-separated text -> 255-character ABAP lines
    split_source( EXPORTING im_source  = im_part-source
                  IMPORTING ex_abap    = ex_work-abap
                            ex_lines   = li_lines
                            ex_message = lv_msg ).
    IF lv_msg IS NOT INITIAL.
      ex_work-result-message = lv_msg.
      RETURN.
    ENDIF.

    "--- function module body: the interface comment block is generated
    "    from SE37 metadata, so a change there would be silently lost
    IF ex_work-result-object = 'FUGR'.
      lv_len = strlen( ex_work-result-include ) - 3.
      lv_suffix = ex_work-result-include+lv_len(3).
      IF lv_suffix(1) = 'U' AND lv_suffix+1(2) CO '0123456789'.
        IF fm_interface_unchanged( im_include = ex_work-include
                                   im_new     = li_lines ) = abap_false.
          ex_work-result-message = 'Function module interface changed - change parameters in SE37.'.
          RETURN.
        ENDIF.
      ENDIF.
    ENDIF.

    "--- transport rules
    IF ex_work-local = abap_false.
      check_transport( EXPORTING im_transport = im_request-transport
                                 im_object    = ex_work-result-object
                                 im_name      = ex_work-result-name
                                 im_include   = ex_work-include
                       IMPORTING ex_request   = ex_work-request
                                 ex_message   = lv_msg ).
      IF lv_msg IS NOT INITIAL.
        ex_work-result-message = lv_msg.
        RETURN.
      ENDIF.
      ex_work-result-transport = ex_work-request.
    ENDIF.

    ex_work-result-status  = 'ok'.
    ex_work-result-message = 'Ready to write.'.

  ENDMETHOD.


  METHOD check_transport.
    "The given request must be modifiable. If the object is already
    "locked in an open request, it must be that one - SAP locks an object
    "in one request only. The lock is read with TR_CHECK_OBJECT_LOCK, the
    "same call ZCL_ABAPGIT_CTS_API makes in this system.

    TYPES: BEGIN OF lt_e070,
             trkorr   TYPE trkorr,
             trstatus TYPE trstatus,
             strkorr  TYPE strkorr,
           END OF lt_e070.

    DATA lw_e070     TYPE lt_e070.
    DATA lv_trkorr   TYPE trkorr.
    DATA lv_holder   TYPE trkorr.
    DATA lv_task     TYPE trkorr.
    DATA lv_parent   TYPE strkorr.
    DATA lv_lockable TYPE abap_bool.
    DATA lv_locked   TYPE abap_bool.
    DATA li_tlock    TYPE STANDARD TABLE OF tlock.
    DATA lv_pgmid    TYPE pgmid.
    DATA lv_objtype  TYPE trobjtype.
    DATA lv_objname  TYPE trobj_name.
    DATA lv_round    TYPE i.

    CLEAR: ex_request, ex_message.

    IF im_transport IS INITIAL.
      ex_message = 'Package is transportable - pass --transport <request>.'.
      RETURN.
    ENDIF.

    lv_trkorr = im_transport.
    TRANSLATE lv_trkorr TO UPPER CASE.
    SELECT SINGLE trkorr trstatus strkorr FROM e070
      INTO lw_e070 WHERE trkorr = lv_trkorr.
    IF sy-subrc <> 0.
      CONCATENATE 'Transport' lv_trkorr 'does not exist.' INTO ex_message SEPARATED BY space.
      RETURN.
    ENDIF.
    IF lw_e070-trstatus <> 'D' AND lw_e070-trstatus <> 'L'.
      CONCATENATE 'Transport' lv_trkorr 'is released - use a modifiable request.'
        INTO ex_message SEPARATED BY space.
      RETURN.
    ENDIF.

    "a task was given: work with its request
    IF lw_e070-strkorr IS NOT INITIAL.
      ex_request = lw_e070-strkorr.
    ELSE.
      ex_request = lw_e070-trkorr.
    ENDIF.

    "who holds the lock? Check the whole object (R3TR) and the include (LIMU REPS)
    DO 2 TIMES.
      lv_round = sy-index.
      IF lv_round = 1.
        lv_pgmid   = 'R3TR'.
        lv_objtype = im_object.
        lv_objname = im_name.
      ELSE.
        "a function module being created has no include yet
        IF im_include IS INITIAL.
          EXIT.
        ENDIF.
        lv_pgmid   = 'LIMU'.
        lv_objtype = 'REPS'.
        lv_objname = im_include.
      ENDIF.

      CLEAR: lv_lockable, lv_locked, lv_holder, lv_task, li_tlock.
      CALL FUNCTION 'TR_CHECK_OBJECT_LOCK'
        EXPORTING
          wi_pgmid             = lv_pgmid
          wi_object            = lv_objtype
          wi_objname           = lv_objname
        IMPORTING
          we_lockable_object   = lv_lockable
          we_locked            = lv_locked
          we_lock_order        = lv_holder
          we_lock_task         = lv_task
        TABLES
          wt_tlock             = li_tlock
        EXCEPTIONS
          empty_key            = 1
          no_systemname        = 2
          no_systemtype        = 3
          unallowed_lock_order = 4
          OTHERS               = 5.
      IF sy-subrc <> 0 OR lv_locked = abap_false OR lv_holder IS INITIAL.
        CONTINUE.
      ENDIF.

      "we_lock_order is the request; be tolerant if a task comes back
      SELECT SINGLE strkorr FROM e070 INTO lv_parent WHERE trkorr = lv_holder.
      IF sy-subrc = 0 AND lv_parent IS NOT INITIAL.
        lv_holder = lv_parent.
      ENDIF.

      IF lv_holder <> ex_request.
        CONCATENATE 'Already locked in request' lv_holder '- push with --transport' lv_holder
          INTO ex_message SEPARATED BY space.
        RETURN.
      ENDIF.
    ENDDO.

  ENDMETHOD.


  METHOD class_check.
*&---------------------------------------------------------------------*
*& ZCL_ABAPSYNC_CHECK=>CLASS_SYNTAX, called by name like the dictionary
*& and repository delegates, so this class activates without it. When
*& it is absent or fails to run, the class counts as not checked - it
*& is never refused for that.
*&---------------------------------------------------------------------*

    DATA lv_class TYPE string.
    DATA lx_root  TYPE REF TO cx_root.

    ex_ok      = abap_true.
    ex_checked = abap_false.
    CLEAR ex_message.

    lv_class = c_check_class.
    TRY.
        CALL METHOD (lv_class)=>('CLASS_SYNTAX')
          EXPORTING
            im_class   = im_class
          IMPORTING
            ex_ok      = ex_ok
            ex_checked = ex_checked
            ex_message = ex_message.
      CATCH cx_root INTO lx_root.
        ex_ok      = abap_true.
        ex_checked = abap_false.
        ex_message = lx_root->get_text( ).
        CONCATENATE `Syntax check not available: ` ex_message INTO ex_message.
    ENDTRY.

  ENDMETHOD.


  METHOD class_include.
    "The class builder's own include names (CL_OO_CLASSNAME_SERVICE), as
    "abapGit uses them - never built by hand.

    DATA lv_cls  TYPE seoclsname.
    DATA lv_prog TYPE program.
    DATA lw_key  TYPE seocpdkey.
    DATA lv_meth TYPE string.

    lv_cls = im_class.

    CASE im_part.
      WHEN 'pubsec'.
        lv_prog = cl_oo_classname_service=>get_pubsec_name( lv_cls ).
      WHEN 'protsec'.
        lv_prog = cl_oo_classname_service=>get_prosec_name( lv_cls ).
      WHEN 'privsec'.
        lv_prog = cl_oo_classname_service=>get_prisec_name( lv_cls ).
      WHEN 'locals_def'.
        lv_prog = cl_oo_classname_service=>get_ccdef_name( lv_cls ).
      WHEN 'locals_imp'.
        lv_prog = cl_oo_classname_service=>get_ccimp_name( lv_cls ).
      WHEN 'macros'.
        lv_prog = cl_oo_classname_service=>get_ccmac_name( lv_cls ).
      WHEN 'testclasses'.
        lv_prog = cl_oo_classname_service=>get_ccau_name( lv_cls ).
      WHEN OTHERS.
        "method.<NAME>: only an existing method has an include yet
        lv_meth = im_part+7.
        TRANSLATE lv_meth TO UPPER CASE.
        lw_key-clsname = lv_cls.
        lw_key-cpdname = lv_meth.
        "a class that does not exist yet raises CLASS_NOT_EXISTING, not
        "METHOD_NOT_EXISTING (seen live on the first new-class check)
        cl_oo_classname_service=>get_method_include(
          EXPORTING mtdkey = lw_key
          RECEIVING result = lv_prog
          EXCEPTIONS method_not_existing = 1
                     class_not_existing  = 2
                     OTHERS              = 3 ).
        IF sy-subrc <> 0.
          CLEAR lv_prog.
        ENDIF.
    ENDCASE.

    ex_include = lv_prog.

  ENDMETHOD.


  METHOD client_allows_changes.
    "SCC4: ' ' and '1' allow changes to repository objects,
    "'2' and '3' do not. A production client is normally '3'.

    DATA lv_ind TYPE t000-ccnocliind.

    SELECT SINGLE ccnocliind FROM t000 INTO lv_ind WHERE mandt = sy-mandt.
    IF lv_ind = space OR lv_ind = '1'.
      ex_ok = abap_true.
    ENDIF.

  ENDMETHOD.


  METHOD create_func.
    "abapGit: ZCL_ABAPGIT_OBJECT_FUGR->DESERIALIZE_FUNCTIONS, 7.02 branch

    DATA lv_area      TYPE rs38l-area.
    DATA lv_group     TYPE rs38l-area.
    DATA lv_namespace TYPE rs38l-namespace.
    DATA lv_fname     TYPE rs38l-name.
    DATA lv_include   TYPE rs38l-include.
    DATA lv_corr      TYPE trkorr.
    DATA lv_parent    TYPE strkorr.
    DATA lv_msg       TYPE string.
    DATA li_gen       TYPE string_table.
    DATA li_block     TYPE string_table.
    DATA li_abap      TYPE t_abap_tab.
    DATA lw_abap      TYPE abaptxt255.
    DATA lv_line      TYPE string.
    DATA lv_upper     TYPE string.
    DATA lv_done      TYPE abap_bool.
    DATA lv_subrc     TYPE sy-subrc.
    DATA lw_saved     TYPE e070use.

    lv_area  = ch_work-result-name.
    lv_fname = ch_work-funcname.

    CALL FUNCTION 'FUNCTION_INCLUDE_SPLIT'
      EXPORTING
        complete_area = lv_area
      IMPORTING
        namespace     = lv_namespace
        group         = lv_group
      EXCEPTIONS
        OTHERS        = 12.
    IF sy-subrc <> 0.
      ch_work-result-status  = 'error'.
      ch_work-result-message = sy_message( ).
      RETURN.
    ENDIF.

    "--- 1. create the function module with its interface; this records
    "       LIMU FUNC in the request and generates the include. The
    "       request is made the session default first, so SAP records
    "       into it without asking (no popup is possible over HTTP).
    IF ch_work-local = abap_false.
      set_default_request( EXPORTING im_request = ch_work-request
                           IMPORTING ex_saved   = lw_saved
                                     ex_message = lv_msg ).
      IF lv_msg IS NOT INITIAL.
        ch_work-result-status  = 'error'.
        ch_work-result-message = lv_msg.
        RETURN.
      ENDIF.
    ENDIF.

    CALL FUNCTION 'RS_FUNCTIONMODULE_INSERT'
      EXPORTING
        funcname                = lv_fname
        function_pool           = lv_group
        short_text              = ch_work-short_text
        namespace               = lv_namespace
        corrnum                 = ch_work-request
        suppress_corr_check     = abap_false
      IMPORTING
        function_include        = lv_include
        corrnum_e               = lv_corr
      TABLES
        import_parameter        = ch_work-fm_import
        export_parameter        = ch_work-fm_export
        tables_parameter        = ch_work-fm_tables
        changing_parameter      = ch_work-fm_changing
        exception_list          = ch_work-fm_except
      EXCEPTIONS
        double_task             = 1
        error_message           = 2
        function_already_exists = 3
        invalid_function_pool   = 4
        invalid_name            = 5
        too_many_functions      = 6
        no_modify_permission    = 7
        no_show_permission      = 8
        enqueue_system_failure  = 9
        canceled_in_corr        = 10
        OTHERS                  = 11.
    lv_subrc = sy-subrc.
    IF lv_subrc <> 0.
      lv_msg = sy_message( ).
    ENDIF.

    "the developer's own default request comes back, whatever happened
    IF ch_work-local = abap_false.
      reset_default_request( lw_saved ).
    ENDIF.

    IF lv_subrc <> 0.
      CONCATENATE 'Create function module:' lv_msg INTO ch_work-result-message SEPARATED BY space.
      ch_work-result-status = 'error'.
      RETURN.
    ENDIF.

    ch_work-include         = lv_include.
    ch_work-result-include  = lv_include.

    "--- 2. the *" interface block is SAP's: take the generated one, so
    "       the saved source matches SE37 exactly
    READ REPORT lv_include INTO li_gen STATE 'I'.
    IF sy-subrc <> 0.
      READ REPORT lv_include INTO li_gen.
    ENDIF.
    LOOP AT li_gen INTO lv_line.
      IF strlen( lv_line ) >= 2 AND lv_line(2) = '*"'.
        APPEND lv_line TO li_block.
      ENDIF.
    ENDLOOP.
    IF li_block IS NOT INITIAL.
      LOOP AT ch_work-abap INTO lw_abap.
        IF strlen( lw_abap-line ) >= 2 AND lw_abap-line(2) = '*"'.
          CONTINUE.
        ENDIF.
        APPEND lw_abap TO li_abap.
        IF lv_done = abap_false.
          lv_upper = lw_abap-line.
          CONDENSE lv_upper.
          "CP, not a 'FUNCTION ' literal: trailing blanks of text
          "literals do not count, so that comparison never matched
          IF lv_upper CP 'FUNCTION *'.
            LOOP AT li_block INTO lv_line.
              lw_abap-line = lv_line.
              APPEND lw_abap TO li_abap.
            ENDLOOP.
            lv_done = abap_true.
          ENDIF.
        ENDIF.
      ENDLOOP.
      "use the merged source only if SAP's block really went in;
      "otherwise keep the developer's own interface comments
      IF lv_done = abap_true.
        ch_work-abap = li_abap.
      ENDIF.
    ENDIF.

    "--- 3. save the body like any other include (transport + inactive)
    write_include( CHANGING ch_work = ch_work ).
    IF ch_work-result-status <> 'written'.
      CONCATENATE 'Function module created, but its source was not saved:' ch_work-result-message
        INTO ch_work-result-message SEPARATED BY space.
      RETURN.
    ENDIF.
    ch_work-result-message = 'Function module created, saved inactive.'.

    "SAP may record it in another request than the one given
    IF ch_work-local = abap_false AND lv_corr IS NOT INITIAL.
      SELECT SINGLE strkorr FROM e070 INTO lv_parent WHERE trkorr = lv_corr.
      IF sy-subrc = 0 AND lv_parent IS NOT INITIAL.
        lv_corr = lv_parent.
      ENDIF.
      IF lv_corr <> ch_work-request.
        ch_work-result-transport = lv_corr.
      ENDIF.
    ENDIF.

  ENDMETHOD.


  METHOD ddic_call.
    "The dictionary parts of the push go to ZCL_ABAPSYNC_DDIC as one JSON
    "request; each part carries its row number in CH_WORK_TAB, so the
    "answer lands on the right row. The class is called by name: when it
    "is missing, every dictionary part gets a message saying so, and the
    "rest of the push is unaffected.

    DATA lw_req   TYPE t_ddic_request.
    DATA lw_part  TYPE t_ddic_part.
    DATA lw_resp  TYPE t_ddic_response.
    DATA lw_res   TYPE t_ddic_result.
    DATA lo_json  TYPE REF TO zif_ajson.
    DATA lx_root  TYPE REF TO cx_root.
    DATA lv_in    TYPE string.
    DATA lv_out   TYPE string.
    DATA lv_class TYPE string.
    DATA lv_fail  TYPE string.
    DATA lv_cname TYPE abap_abstypename.

    FIELD-SYMBOLS <lf_work> TYPE t_work.

    CLEAR ex_messages.

    "--- the request: the dictionary parts this step is about
    lw_req-action    = im_action.
    lw_req-transport = im_request-transport.
    lw_req-package   = im_request-package.
    lw_req-force     = im_request-force.
    LOOP AT ch_work_tab ASSIGNING <lf_work> WHERE kind = im_kind.
      IF im_action = 'write' AND <lf_work>-result-status <> 'ok'.
        CONTINUE.
      ENDIF.
      IF im_action = 'activate' AND <lf_work>-result-status <> 'written'.
        CONTINUE.
      ENDIF.
      CLEAR lw_part.
      lw_part-index         = sy-tabix.
      lw_part-object        = <lf_work>-result-object.
      lw_part-name          = <lf_work>-result-name.
      lw_part-part          = <lf_work>-result-part.
      lw_part-expected_hash = <lf_work>-ddic_hash.
      lw_part-source        = <lf_work>-ddic_src.
      lw_part-create        = <lf_work>-cls_new.
      APPEND lw_part TO lw_req-parts.
    ENDLOOP.
    IF lw_req-parts IS INITIAL.
      RETURN.
    ENDIF.

    "a check refuses; a failed write or activation is an error
    IF im_action = 'check'.
      lv_fail = 'refused'.
    ELSE.
      lv_fail = 'error'.
    ENDIF.

    "--- the call, by name
    IF im_kind = 'REPO'.
      lv_class = c_repo_class.
    ELSE.
      lv_class = c_ddic_class.
    ENDIF.
    TRY.
        lo_json = zcl_ajson=>create_empty( ).
        lo_json->set( iv_path = '/' iv_val = lw_req ).
        lv_in = lo_json->stringify( ).
        CALL METHOD (lv_class)=>('RUN')
          EXPORTING
            im_request  = lv_in
          RECEIVING
            ex_response = lv_out.
        lo_json = zcl_ajson=>parse( lv_out ).
        lo_json->to_abap( IMPORTING ev_container = lw_resp ).
      CATCH cx_root INTO lx_root.
        lv_cname = cl_abap_classdescr=>get_class_name( lx_root ).
        IF lv_cname CS 'DYN_CALL_ILLEGAL_CLASS'.
          CONCATENATE 'This push needs class' lv_class 'in this system - push it with abapsync first.'
            INTO lw_resp-error SEPARATED BY space.
        ELSE.
          lw_resp-error = lx_root->get_text( ).
          IF lw_resp-error IS INITIAL.
            lw_resp-error = lv_cname.
          ENDIF.
        ENDIF.
    ENDTRY.

    IF lw_resp-error IS NOT INITIAL.
      LOOP AT lw_req-parts INTO lw_part.
        READ TABLE ch_work_tab ASSIGNING <lf_work> INDEX lw_part-index.
        IF sy-subrc = 0.
          <lf_work>-result-status  = lv_fail.
          <lf_work>-result-message = lw_resp-error.
        ENDIF.
      ENDLOOP.
      RETURN.
    ENDIF.

    "--- the answer, row by row
    LOOP AT lw_resp-results INTO lw_res.
      READ TABLE ch_work_tab ASSIGNING <lf_work> INDEX lw_res-index.
      IF sy-subrc <> 0.
        CONTINUE.
      ENDIF.
      IF <lf_work>-kind <> im_kind.
        CONTINUE.
      ENDIF.
      IF lw_res-status IS NOT INITIAL.
        <lf_work>-result-status = lw_res-status.
      ENDIF.
      <lf_work>-result-message = lw_res-message.
      IF lw_res-include IS NOT INITIAL.
        <lf_work>-result-include = lw_res-include.
      ENDIF.
      IF lw_res-transport IS NOT INITIAL.
        <lf_work>-result-transport = lw_res-transport.
      ENDIF.
      IF lw_res-new_hash IS NOT INITIAL.
        <lf_work>-result-new_hash = lw_res-new_hash.
      ENDIF.
      IF lw_res-state IS NOT INITIAL.
        <lf_work>-result-state = lw_res-state.
      ENDIF.
    ENDLOOP.

    "a part the dictionary class did not answer for is not left looking
    "valid
    IF im_action = 'check'.
      LOOP AT lw_req-parts INTO lw_part.
        READ TABLE lw_resp-results TRANSPORTING NO FIELDS WITH KEY index = lw_part-index.
        IF sy-subrc <> 0.
          READ TABLE ch_work_tab ASSIGNING <lf_work> INDEX lw_part-index.
          IF sy-subrc = 0.
            <lf_work>-result-status  = 'refused'.
            CONCATENATE 'No answer from' lv_class 'for this part.'
              INTO <lf_work>-result-message SEPARATED BY space.
          ENDIF.
        ENDIF.
      ENDLOOP.
    ENDIF.

    ex_messages = lw_resp-messages.

  ENDMETHOD.


  METHOD first_statement.
    "The first statement of a source, upper case, comments dropped - to
    "judge a class definition without parsing it.

    DATA lv_line TYPE string.
    DATA lv_pos  TYPE i.
    DATA lv_last TYPE i.

    LOOP AT im_lines INTO lv_line.
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


  METHOD fm_interface_unchanged.
    "Compare the *" comment lines (the generated local interface) of
    "the active version and the new source.

    DATA li_old     TYPE string_table.
    DATA lv_line    TYPE string.
    DATA li_old_if  TYPE string_table.
    DATA li_new_if  TYPE string_table.

    READ REPORT im_include INTO li_old.

    LOOP AT li_old INTO lv_line.
      IF strlen( lv_line ) >= 2 AND lv_line(2) = '*"'.
        APPEND lv_line TO li_old_if.
      ENDIF.
    ENDLOOP.
    LOOP AT im_new INTO lv_line.
      IF strlen( lv_line ) >= 2 AND lv_line(2) = '*"'.
        CONDENSE lv_line.   "ignore spacing differences
        APPEND lv_line TO li_new_if.
      ENDIF.
    ENDLOOP.
    LOOP AT li_old_if INTO lv_line.
      CONDENSE lv_line.
      MODIFY li_old_if FROM lv_line.
    ENDLOOP.

    IF li_old_if = li_new_if.
      ex_ok = abap_true.
    ENDIF.

  ENDMETHOD.


  METHOD get_title.

    DATA li_tpool TYPE STANDARD TABLE OF textpool.
    DATA lw_tpool TYPE textpool.

    READ TEXTPOOL im_include INTO li_tpool LANGUAGE im_lang.
    READ TABLE li_tpool INTO lw_tpool WITH KEY id = 'R'.
    IF sy-subrc = 0.
      ex_title = lw_tpool-entry.
      RETURN.
    ENDIF.

    SELECT SINGLE text FROM trdirt INTO ex_title
      WHERE name = im_include AND sprsl = im_lang.

  ENDMETHOD.


  METHOD hash_abap.
    "Hash exactly as ZCL_ABAPMCP_SYNC hashes an include: lines joined
    "by LF plus a final LF. abaptxt255 lines drop trailing blanks, just
    "as the repository does, so this matches READ REPORT afterwards.

    DATA lw_abap TYPE abaptxt255.
    DATA lv_line TYPE string.
    DATA li_str  TYPE string_table.
    DATA lv_text TYPE string.

    LOOP AT im_abap INTO lw_abap.
      lv_line = lw_abap-line.
      APPEND lv_line TO li_str.
    ENDLOOP.
    CONCATENATE LINES OF li_str INTO lv_text SEPARATED BY cl_abap_char_utilities=>newline.
    CONCATENATE lv_text cl_abap_char_utilities=>newline INTO lv_text.
    ex_hash = zcl_abapmcp_sync=>hash_text( lv_text ).

  ENDMETHOD.


  METHOD if_http_extension~handle_request.

    DATA lv_method  TYPE string.
    DATA lv_marker  TYPE string.
    DATA lv_body    TYPE string.
    DATA lv_info    TYPE string.
    DATA lv_user    TYPE string.
    DATA lo_in      TYPE REF TO zif_ajson.
    DATA lo_json_error    TYPE REF TO zcx_ajson_error.
    DATA lw_request TYPE t_request.
    DATA lw_resp    TYPE t_response.

    lv_method = server->request->get_header_field( '~request_method' ).
    TRANSLATE lv_method TO UPPER CASE.

    "--- GET: a plain-text page, so a browser check after SICF setup works
    IF lv_method = 'GET'.
      lv_user = sy-uname.
      CONCATENATE 'abapsync write endpoint' c_version INTO lv_info SEPARATED BY space.
      CONCATENATE lv_info cl_abap_char_utilities=>newline INTO lv_info.
      CONCATENATE lv_info 'system' sy-sysid 'client' sy-mandt 'user' lv_user
             INTO lv_info SEPARATED BY space.
      CONCATENATE lv_info cl_abap_char_utilities=>newline
                  'POST JSON with header X-Requested-With: abapsync' INTO lv_info.
      server->response->set_header_field( name = 'Content-Type' value = 'text/plain; charset=utf-8' ).
      server->response->set_cdata( lv_info ).
      server->response->set_status( code = 200 reason = 'OK' ).
      RETURN.
    ENDIF.

    lw_resp-user   = sy-uname.
    lw_resp-system = sy-sysid.

    IF lv_method <> 'POST'.
      lw_resp-error = 'Only GET and POST are supported.'.
      send_json( im_server = server im_status = 405 im_data = lw_resp ).
      RETURN.
    ENDIF.

    "--- a custom header cannot be set by a cross-site form post, so
    "    requiring it blocks CSRF from a browser with an SAP session
    lv_marker = server->request->get_header_field( 'x-requested-with' ).
    IF lv_marker <> 'abapsync'.
      lw_resp-error = 'Missing header X-Requested-With: abapsync.'.
      send_json( im_server = server im_status = 403 im_data = lw_resp ).
      RETURN.
    ENDIF.

    lv_body = server->request->get_cdata( ).
    TRY.
        lo_in = zcl_ajson=>parse( lv_body ).
        lo_in->to_abap( IMPORTING ev_container = lw_request ).
      CATCH zcx_ajson_error INTO lo_json_error.
        lw_resp-error = lo_json_error->get_text( ).
        CONCATENATE 'Invalid JSON:' lw_resp-error INTO lw_resp-error SEPARATED BY space.
        send_json( im_server = server im_status = 400 im_data = lw_resp ).
        RETURN.
    ENDTRY.

    lw_resp = process( lw_request ).
    send_json( im_server = server im_status = 200 im_data = lw_resp ).

  ENDMETHOD.


  METHOD is_ddic_object.

    DATA lv_class TYPE string.
    DATA lx_root  TYPE REF TO cx_root.

    lv_class = c_ddic_class.
    TRY.
        CALL METHOD (lv_class)=>('IS_DDIC_TYPE')
          EXPORTING
            im_object = im_object
          RECEIVING
            ex_yes    = ex_yes.
      CATCH cx_root INTO lx_root.
        IF im_object = 'TABL' OR im_object = 'DTEL' OR im_object = 'DOMA'.
          ex_yes = abap_true.
        ELSE.
          ex_yes = abap_false.
        ENDIF.
    ENDTRY.

  ENDMETHOD.


  METHOD is_repo_part.

    DATA lv_class TYPE string.
    DATA lv_part  TYPE string.
    DATA lx_root  TYPE REF TO cx_root.

    lv_class = c_repo_class.
    TRY.
        CALL METHOD (lv_class)=>('CLAIMS')
          EXPORTING
            im_object = im_object
            im_part   = im_part
            im_create = im_create
          RECEIVING
            ex_yes    = ex_yes.
      CATCH cx_root INTO lx_root.
        lv_part = im_part.
        TRANSLATE lv_part TO LOWER CASE.
        IF ( lv_part = 'texts' AND ( im_object = 'PROG' OR im_object = 'FUGR' ) )
           OR ( im_object = 'PROG' AND im_create = abap_true ).
          ex_yes = abap_true.
        ELSE.
          ex_yes = abap_false.
        ENDIF.
    ENDTRY.

  ENDMETHOD.


  METHOD log_part.
    "One row per part in ZABAPSYNC_LOG - create the table first, see
    "docs/07-write-handler.md. A failed INSERT does not stop the push.

    DATA lw_log TYPE zabapsync_log.

    CALL FUNCTION 'GUID_CREATE'
      IMPORTING
        ev_guid_32 = lw_log-log_id.
    GET TIME STAMP FIELD lw_log-tstamp.
    lw_log-uname    = sy-uname.
    lw_log-action   = im_action.
    lw_log-object   = im_result-object.
    lw_log-obj_name = im_result-name.
    lw_log-include  = im_result-include.
    lw_log-trkorr   = im_result-transport.
    lw_log-status   = im_result-status.
    lw_log-state    = im_result-state.
    lw_log-new_hash = im_result-new_hash.
    lw_log-message  = im_result-message.

    INSERT zabapsync_log FROM lw_log.

  ENDMETHOD.


  METHOD map_fm_interface.

    DATA lw_param TYPE t_in_param.
    DATA lw_imp   TYPE rsimp.
    DATA lw_exp   TYPE rsexp.
    DATA lw_cha   TYPE rscha.
    DATA lw_tbl   TYPE rstbl.
    DATA lw_exc   TYPE rsexc.
    DATA lv_exc   TYPE string.

    LOOP AT im_fm-import INTO lw_param.
      CLEAR lw_imp.
      map_param( EXPORTING im_param = lw_param im_kind = 'IMPORTING'
                 CHANGING  ch_target = lw_imp ch_error = ch_msg ).
      APPEND lw_imp TO ch_work-fm_import.
    ENDLOOP.
    LOOP AT im_fm-export INTO lw_param.
      CLEAR lw_exp.
      map_param( EXPORTING im_param = lw_param im_kind = 'EXPORTING'
                 CHANGING  ch_target = lw_exp ch_error = ch_msg ).
      APPEND lw_exp TO ch_work-fm_export.
    ENDLOOP.
    LOOP AT im_fm-changing INTO lw_param.
      CLEAR lw_cha.
      map_param( EXPORTING im_param = lw_param im_kind = 'CHANGING'
                 CHANGING  ch_target = lw_cha ch_error = ch_msg ).
      APPEND lw_cha TO ch_work-fm_changing.
    ENDLOOP.
    LOOP AT im_fm-tables INTO lw_param.
      CLEAR lw_tbl.
      map_param( EXPORTING im_param = lw_param im_kind = 'TABLES'
                 CHANGING  ch_target = lw_tbl ch_error = ch_msg ).
      APPEND lw_tbl TO ch_work-fm_tables.
    ENDLOOP.
    LOOP AT im_fm-exceptions INTO lv_exc.
      CLEAR lw_exc.
      CONDENSE lv_exc.
      TRANSLATE lv_exc TO UPPER CASE.
      IF lv_exc IS INITIAL OR lv_exc CN 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_'.
        IF ch_msg IS INITIAL.
          CONCATENATE 'Invalid exception name' lv_exc INTO ch_msg SEPARATED BY space.
        ENDIF.
        CONTINUE.
      ENDIF.
      set_field( EXPORTING im_field = 'EXCEPTION' im_value = lv_exc
                 CHANGING  ch_target = lw_exc ch_error = ch_msg ).
      APPEND lw_exc TO ch_work-fm_except.
    ENDLOOP.

  ENDMETHOD.


  METHOD map_param.
    "TYPE -> TYP, TYPE REF TO -> TYP + REF_CLASS, LIKE -> DBFIELD,
    "STRUCTURE (TABLES only) -> DBSTRUCT. No VALUE( ) -> REFERENCE = X.

    DATA lv_name   TYPE string.
    DATA lv_typing TYPE string.
    DATA lv_type   TYPE string.

    IF ch_error IS NOT INITIAL.
      RETURN.
    ENDIF.

    lv_name = im_param-name.
    CONDENSE lv_name.
    TRANSLATE lv_name TO UPPER CASE.
    lv_typing = im_param-typing.
    CONDENSE lv_typing.
    TRANSLATE lv_typing TO UPPER CASE.
    lv_type = im_param-type.
    CONDENSE lv_type.
    TRANSLATE lv_type TO UPPER CASE.

    IF lv_name IS INITIAL OR strlen( lv_name ) > 30
      OR lv_name CN 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_'.
      CONCATENATE 'Invalid' im_kind 'parameter name' lv_name INTO ch_error SEPARATED BY space.
      RETURN.
    ENDIF.
    IF lv_typing IS NOT INITIAL AND lv_type IS INITIAL.
      CONCATENATE im_kind 'parameter' lv_name 'has no type.' INTO ch_error SEPARATED BY space.
      RETURN.
    ENDIF.

    set_field( EXPORTING im_field = 'PARAMETER' im_value = lv_name
               CHANGING  ch_target = ch_target ch_error = ch_error ).

    CASE lv_typing.
      WHEN ''.
        "untyped
      WHEN 'TYPE'.
        set_field( EXPORTING im_field = 'TYP' im_value = lv_type
                   CHANGING  ch_target = ch_target ch_error = ch_error ).
      WHEN 'TYPE REF TO'.
        IF im_kind = 'TABLES'.
          CONCATENATE 'TABLES parameter' lv_name 'cannot be TYPE REF TO.' INTO ch_error SEPARATED BY space.
          RETURN.
        ENDIF.
        set_field( EXPORTING im_field = 'TYP' im_value = lv_type
                   CHANGING  ch_target = ch_target ch_error = ch_error ).
        set_field( EXPORTING im_field = 'REF_CLASS' im_value = abap_true
                   CHANGING  ch_target = ch_target ch_error = ch_error ).
      WHEN 'LIKE'.
        IF im_kind = 'TABLES'.
          CONCATENATE 'TABLES parameter' lv_name 'must use STRUCTURE or TYPE, not LIKE.' INTO ch_error SEPARATED BY space.
          RETURN.
        ENDIF.
        set_field( EXPORTING im_field = 'DBFIELD' im_value = lv_type
                   CHANGING  ch_target = ch_target ch_error = ch_error ).
      WHEN 'STRUCTURE'.
        IF im_kind <> 'TABLES'.
          CONCATENATE 'STRUCTURE typing is only allowed for TABLES parameters (' lv_name ').'
            INTO ch_error SEPARATED BY space.
          RETURN.
        ENDIF.
        set_field( EXPORTING im_field = 'DBSTRUCT' im_value = lv_type
                   CHANGING  ch_target = ch_target ch_error = ch_error ).
      WHEN OTHERS.
        CONCATENATE 'Unsupported typing' lv_typing 'for parameter' lv_name INTO ch_error SEPARATED BY space.
        RETURN.
    ENDCASE.

    IF im_kind = 'IMPORTING' OR im_kind = 'CHANGING'.
      IF im_param-default IS NOT INITIAL.
        set_field( EXPORTING im_field = 'DEFAULT' im_value = im_param-default
                   CHANGING  ch_target = ch_target ch_error = ch_error ).
      ENDIF.
    ENDIF.
    IF im_kind <> 'EXPORTING'.
      IF im_param-optional = abap_true OR im_param-default IS NOT INITIAL.
        set_field( EXPORTING im_field = 'OPTIONAL' im_value = abap_true
                   CHANGING  ch_target = ch_target ch_error = ch_error ).
      ENDIF.
    ENDIF.
    IF im_kind <> 'TABLES' AND im_param-by_value = abap_false.
      set_field( EXPORTING im_field = 'REFERENCE' im_value = abap_true
                 CHANGING  ch_target = ch_target ch_error = ch_error ).
    ENDIF.

  ENDMETHOD.


  METHOD part_lines.
    "The text a part will have: what was pushed, else what SAP holds.

    DATA lv_inc   TYPE progname.
    DATA lv_found TYPE abap_bool.

    FIELD-SYMBOLS <lf_work> TYPE t_work.

    LOOP AT im_works ASSIGNING <lf_work>
         WHERE kind = 'CLASS' AND result-name = im_name AND cls_part = im_part.
      ex_lines = abap_lines( im_abap = <lf_work>-abap ).
      lv_found = abap_true.
    ENDLOOP.
    IF lv_found = abap_true.
      RETURN.
    ENDIF.

    lv_inc = class_include( im_class = im_name im_part = im_part ).
    IF lv_inc IS NOT INITIAL.
      ex_lines = read_lines( im_include = lv_inc ).
    ENDIF.

  ENDMETHOD.


  METHOD post_class.
*&---------------------------------------------------------------------*
*& ZCL_ABAPSYNC_POST=>CLASS_ACTIVATED, called by name like the other
*& delegates: work that follows the activation of a class (0.8.0: the
*& SE24 method descriptions). Anything going wrong there is ignored -
*& the push itself has already succeeded.
*&---------------------------------------------------------------------*

    DATA lv_class TYPE string.
    DATA lx_root  TYPE REF TO cx_root.

    CLEAR ex_message.
    lv_class = c_post_class.
    TRY.
        CALL METHOD (lv_class)=>('CLASS_ACTIVATED')
          EXPORTING
            im_class   = im_class
          IMPORTING
            ex_message = ex_message.
      CATCH cx_root INTO lx_root.
        CLEAR ex_message.
    ENDTRY.

  ENDMETHOD.


  METHOD process.

    DATA li_work    TYPE t_work_tab.
    DATA lw_work    TYPE t_work.
    DATA lw_part    TYPE t_in_part.
    DATA lv_refused TYPE abap_bool.
    DATA lv_written TYPE i.
    DATA lv_errors  TYPE i.
    DATA lv_action  TYPE string.
    DATA li_classes TYPE string_table.
    DATA lv_class   TYPE string.
    DATA lv_msg     TYPE string.
    DATA li_ddic_msg TYPE t_msg_tab.
    DATA lw_msg_skip TYPE t_msg.

    FIELD-SYMBOLS <lf_work> TYPE t_work.

    ex_response-action = im_request-action.
    ex_response-user   = sy-uname.
    ex_response-system = sy-sysid.

    IF im_request-action <> 'check' AND im_request-action <> 'push'.
      ex_response-error = 'action must be check or push.'.
      RETURN.
    ENDIF.
    IF im_request-parts IS INITIAL.
      ex_response-error = 'No parts to push.'.
      RETURN.
    ENDIF.
    IF lines( im_request-parts ) > c_max_parts.
      ex_response-error = 'More than 100 parts in one push - push in smaller groups.'.
      RETURN.
    ENDIF.
    IF client_allows_changes( ) = abap_false.
      ex_response-error = 'This client does not allow changes to repository objects (SCC4).'.
      RETURN.
    ENDIF.
    IF write_enabled( ) = abap_false.
      ex_response-error = 'Push is switched off in this system (ZABAPMCP_CFG ABAPSYNC_WRITE = OFF).'.
      RETURN.
    ENDIF.

    "--- 1. validate everything before writing anything
    LOOP AT im_request-parts INTO lw_part.
      lw_work = check_part( im_part = lw_part im_request = im_request ).
      IF lw_work-result-status = 'refused'.
        lv_refused = abap_true.
      ENDIF.
      APPEND lw_work TO li_work.
    ENDLOOP.

    "--- 1b. classes: the parts of one class are judged together. The
    "        assembled source must scan cleanly and a new class must stay
    "        within what can be created from files. This is what makes
    "        'check' a real dry run for classes.
    LOOP AT li_work INTO lw_work WHERE kind = 'CLASS' AND result-status = 'ok'.
      lv_class = lw_work-result-name.
      APPEND lv_class TO li_classes.
    ENDLOOP.
    SORT li_classes.
    DELETE ADJACENT DUPLICATES FROM li_classes.

    LOOP AT li_classes INTO lv_class.
      CLEAR: lv_msg, lw_work.
      "first part of this class: they all agree on whether it is new
      LOOP AT li_work INTO lw_work WHERE kind = 'CLASS' AND result-name = lv_class.
        EXIT.
      ENDLOOP.
      IF lw_work-cls_new = abap_true.
        lv_msg = check_new_class( im_name = lv_class im_works = li_work ).
      ENDIF.
      IF lv_msg IS INITIAL.
        lv_msg = scan_class( im_name = lv_class im_works = li_work ).
      ENDIF.
      IF lv_msg IS NOT INITIAL.
        LOOP AT li_work ASSIGNING <lf_work> WHERE kind = 'CLASS' AND result-name = lv_class.
          <lf_work>-result-status  = 'refused'.
          <lf_work>-result-message = lv_msg.
        ENDLOOP.
        lv_refused = abap_true.
      ENDIF.
    ENDLOOP.

    "--- 1c. dictionary parts: judged by ZCL_ABAPSYNC_DDIC, all at once
    READ TABLE li_work TRANSPORTING NO FIELDS WITH KEY kind = 'DDIC'.
    IF sy-subrc = 0.
      ddic_call( EXPORTING im_action   = 'check'
                           im_request  = im_request
                 IMPORTING ex_messages = li_ddic_msg
                 CHANGING  ch_work_tab = li_work ).
      APPEND LINES OF li_ddic_msg TO ex_response-activation_messages.
      LOOP AT li_work TRANSPORTING NO FIELDS WHERE kind = 'DDIC' AND result-status = 'refused'.
        lv_refused = abap_true.
        EXIT.
      ENDLOOP.
    ENDIF.

    "--- 1d. new programs and text elements: judged by ZCL_ABAPSYNC_REPO
    READ TABLE li_work TRANSPORTING NO FIELDS WITH KEY kind = 'REPO'.
    IF sy-subrc = 0.
      ddic_call( EXPORTING im_action   = 'check'
                           im_request  = im_request
                           im_kind     = 'REPO'
                 IMPORTING ex_messages = li_ddic_msg
                 CHANGING  ch_work_tab = li_work ).
      APPEND LINES OF li_ddic_msg TO ex_response-activation_messages.
      LOOP AT li_work TRANSPORTING NO FIELDS WHERE kind = 'REPO' AND result-status = 'refused'.
        lv_refused = abap_true.
        EXIT.
      ENDLOOP.
    ENDIF.

    IF lv_refused = abap_true OR im_request-action = 'check'.
      LOOP AT li_work INTO lw_work.
        APPEND lw_work-result TO ex_response-results.
        IF im_request-action = 'push'.
          IF lw_work-kind = 'NEWFUNC' OR lw_work-cls_new = abap_true.
            lv_action = 'CREATE'.
          ELSE.
            lv_action = 'PUSH'.
          ENDIF.
          log_part( im_result = lw_work-result im_action = lv_action ).
        ENDIF.
      ENDLOOP.
      IF lv_refused = abap_false.
        ex_response-ok = abap_true.
      ELSE.
        ex_response-error = 'Nothing was written - fix the refused parts first.'.
      ENDIF.
      COMMIT WORK.
      RETURN.
    ENDIF.

    "--- 2. write. Dictionary first, so a class or program in the same
    "       push can already see a new table; then one include at a time;
    "       the parts of a class go as a whole, as the class builder
    "       needs them
    READ TABLE li_work TRANSPORTING NO FIELDS WITH KEY kind = 'DDIC'.
    IF sy-subrc = 0.
      ddic_call( EXPORTING im_action   = 'write'
                           im_request  = im_request
                 IMPORTING ex_messages = li_ddic_msg
                 CHANGING  ch_work_tab = li_work ).
      APPEND LINES OF li_ddic_msg TO ex_response-activation_messages.
      LOOP AT li_work ASSIGNING <lf_work> WHERE kind = 'DDIC'.
        IF <lf_work>-result-status = 'written'.
          lv_written = lv_written + 1.
        ELSE.
          lv_errors = lv_errors + 1.
        ENDIF.
      ENDLOOP.
    ENDIF.

    "new programs next: an existing program of this push may include one
    READ TABLE li_work TRANSPORTING NO FIELDS WITH KEY kind = 'REPO'.
    IF sy-subrc = 0.
      ddic_call( EXPORTING im_action   = 'write'
                           im_request  = im_request
                           im_kind     = 'REPO'
                 IMPORTING ex_messages = li_ddic_msg
                 CHANGING  ch_work_tab = li_work ).
      APPEND LINES OF li_ddic_msg TO ex_response-activation_messages.
      LOOP AT li_work ASSIGNING <lf_work> WHERE kind = 'REPO'.
        IF <lf_work>-result-status = 'written'.
          lv_written = lv_written + 1.
        ELSE.
          lv_errors = lv_errors + 1.
        ENDIF.
      ENDLOOP.
    ENDIF.

    LOOP AT li_work ASSIGNING <lf_work>.
      IF <lf_work>-kind = 'CLASS' OR <lf_work>-kind = 'DDIC' OR <lf_work>-kind = 'REPO'.
        CONTINUE.
      ENDIF.
      write_part( CHANGING ch_work = <lf_work> ).
      IF <lf_work>-result-status = 'written'.
        lv_written = lv_written + 1.
      ELSE.
        lv_errors = lv_errors + 1.
      ENDIF.
    ENDLOOP.

    LOOP AT li_classes INTO lv_class.
      write_class( EXPORTING im_name     = lv_class
                   CHANGING  ch_work_tab = li_work ).
    ENDLOOP.
    LOOP AT li_work ASSIGNING <lf_work> WHERE kind = 'CLASS'.
      IF <lf_work>-result-status = 'written'.
        lv_written = lv_written + 1.
      ELSE.
        lv_errors = lv_errors + 1.
      ENDIF.
    ENDLOOP.
    "abapGit (ZCL_ABAPGIT_OBJECTS_ACTIVATION=>ACTIVATE, this system):
    "commit first, because an activation error rolls back the LUW
    COMMIT WORK AND WAIT.

    "--- 3. activate everything written, in one run - but only when every
    "       part was written. Objects activated together are checked
    "       against each other's INACTIVE versions, so activating the rest
    "       of a half-written push can make an active class call something
    "       that never became active: a syntax error at runtime. (Seen on
    "       09.10.2026: a new class failed to write, the class using it
    "       activated, and /sap/bc/mcp dumped.) Nothing is activated then;
    "       the active versions keep running, and a fixed push activates.
    IF im_request-activate = abap_true AND lv_written > 0 AND lv_errors = 0.
      activate( EXPORTING im_request  = im_request
                CHANGING  ch_work_tab = li_work
                          ch_response = ex_response ).
    ELSEIF im_request-activate = abap_true AND lv_written > 0.
      CLEAR lw_msg_skip.
      lw_msg_skip-text = 'Nothing was activated: a part of this push could not be written. What was written is saved inactive; the active versions are unchanged. Fix the failed part and push again.'.
      APPEND lw_msg_skip TO ex_response-activation_messages.
    ENDIF.

    LOOP AT li_work INTO lw_work.
      APPEND lw_work-result TO ex_response-results.
      IF lw_work-kind = 'NEWFUNC' OR lw_work-cls_new = abap_true.
        lv_action = 'CREATE'.
      ELSE.
        lv_action = 'PUSH'.
      ENDIF.
      log_part( im_result = lw_work-result im_action = lv_action ).
    ENDLOOP.
    COMMIT WORK.

    IF lv_errors = 0.
      ex_response-ok = abap_true.
    ELSE.
      ex_response-error = 'Some parts could not be written - see results.'.
    ENDIF.

  ENDMETHOD.


  METHOD program_check.
*&---------------------------------------------------------------------*
*& ZCL_ABAPSYNC_CHECK=>PROGRAM_SYNTAX (check class 1.1.0), called by name
*& like CLASS_CHECK. When it is absent or fails to run, the program
*& counts as not checked - it is never refused for that. 0.9.3
*&---------------------------------------------------------------------*

    DATA lv_class TYPE string.
    DATA lx_root  TYPE REF TO cx_root.

    ex_ok      = abap_true.
    ex_checked = abap_false.
    CLEAR ex_message.

    lv_class = c_check_class.
    TRY.
        CALL METHOD (lv_class)=>('PROGRAM_SYNTAX')
          EXPORTING
            im_include = im_include
          IMPORTING
            ex_ok      = ex_ok
            ex_checked = ex_checked
            ex_message = ex_message.
      CATCH cx_root INTO lx_root.
        ex_ok      = abap_true.
        ex_checked = abap_false.
        ex_message = lx_root->get_text( ).
        CONCATENATE `Syntax check not available: ` ex_message INTO ex_message.
    ENDTRY.

  ENDMETHOD.


  METHOD read_lines.

    READ REPORT im_include INTO ex_lines.
    IF sy-subrc <> 0.
      CLEAR ex_lines.
    ENDIF.

  ENDMETHOD.


  METHOD reset_default_request.
    "Drop the default set for the push and give back the developer's own.
    "Errors are ignored: the function module is already created by now.

    DATA li_e070use TYPE STANDARD TABLE OF e070use.
    DATA lw_current TYPE e070use.

    CALL FUNCTION 'TR_TASK_GET'
      TABLES
        tt_e070use       = li_e070use
      EXCEPTIONS
        invalid_username = 1
        invalid_category = 2
        invalid_client   = 3
        OTHERS           = 4.
    IF sy-subrc = 0.
      READ TABLE li_e070use INTO lw_current INDEX 1.
      IF sy-subrc = 0.
        CALL FUNCTION 'TR_TASK_RESET'
          EXPORTING
            iv_username      = lw_current-username
            iv_order         = lw_current-ordernum
            iv_task          = lw_current-tasknum
            iv_dialog        = abap_false
          EXCEPTIONS
            invalid_username = 1
            invalid_order    = 2
            invalid_task     = 3
            OTHERS           = 4.
      ENDIF.
    ENDIF.

    "no own default before the push: nothing to give back
    IF im_saved IS INITIAL.
      RETURN.
    ENDIF.
    CALL FUNCTION 'TR_TASK_SET'
      EXPORTING
        iv_order          = im_saved-ordernum
        iv_task           = im_saved-tasknum
      EXCEPTIONS
        invalid_username  = 1
        invalid_category  = 2
        invalid_client    = 3
        invalid_validdays = 4
        invalid_order     = 5
        invalid_task      = 6
        OTHERS            = 7.

  ENDMETHOD.


  METHOD scan_class.
    "Dry run: the class scanner is what abapGit hands the source to
    "first, so a source it rejects would fail the write anyway. Finding
    "out here keeps 'check' honest and writes nothing.

    DATA li_source  TYPE string_table.
    DATA lo_scanner TYPE REF TO cl_oo_source_scanner_class.
    DATA lx_root    TYPE REF TO cx_root.
    DATA lv_cls     TYPE seoclsname.
    DATA lv_msg     TYPE string.
    DATA lv_line    TYPE string.
    DATA lv_new     TYPE abap_bool.
    DATA lv_cname   TYPE abap_abstypename.

    FIELD-SYMBOLS <lf_line> TYPE i.
    FIELD-SYMBOLS <lf_work> TYPE t_work.

    LOOP AT im_works ASSIGNING <lf_work> WHERE kind = 'CLASS' AND result-name = im_name.
      lv_new = <lf_work>-cls_new.
      EXIT.
    ENDLOOP.

    assemble_class( EXPORTING im_name   = im_name
                              im_works  = im_works
                    IMPORTING ex_source = li_source ).

    lv_cls = im_name.
    TRY.
        lo_scanner = cl_oo_source_scanner_class=>create_class_scanner(
                       clif_name = lv_cls
                       source    = li_source ).
        lo_scanner->scan( ).
      CATCH cx_root INTO lx_root.
        "A class that is not in SAP yet may make the scanner complain about
        "that rather than about the source. Only a real scan error counts
        "then; the write itself scans again once the class exists.
        lv_cname = cl_abap_classdescr=>get_class_name( lx_root ).
        IF lv_new = abap_true AND lv_cname NS 'SCAN_ERROR'.
          RETURN.
        ENDIF.
        lv_msg = lx_root->get_text( ).
        "scan errors carry the line in the assembled source
        ASSIGN lx_root->('SOURCE_POSITION-LINE') TO <lf_line>.
        IF sy-subrc = 0.
          lv_line = <lf_line>.
          CONDENSE lv_line.
          CONCATENATE lv_msg '(line' lv_line 'of the assembled class source)'
            INTO lv_msg SEPARATED BY space.
        ENDIF.
        CONCATENATE 'The class source does not scan:' lv_msg
          INTO ex_msg SEPARATED BY space.
    ENDTRY.

  ENDMETHOD.


  METHOD send_json.

    DATA lo_out  TYPE REF TO zif_ajson.
    DATA lv_json TYPE string.
    DATA lo_error      TYPE REF TO zcx_ajson_error.

    TRY.
        lo_out = zcl_ajson=>create_empty( ).
        lo_out->set( iv_path = '/' iv_val = im_data ).
        lv_json = lo_out->stringify( ).
      CATCH zcx_ajson_error INTO lo_error.
        lv_json = '{"ok":false,"error":"internal error building the response"}'.
    ENDTRY.

    im_server->response->set_header_field( name = 'Content-Type' value = 'application/json; charset=utf-8' ).
    im_server->response->set_cdata( lv_json ).
    im_server->response->set_status( code = im_status reason = '' ).

  ENDMETHOD.


  METHOD set_default_request.
    "Remember the developer's own default request, then make the push
    "request the default for the rest of this session (1 day, as abapGit).

    DATA li_e070use TYPE STANDARD TABLE OF e070use.

    CLEAR: ex_saved, ex_message.

    CALL FUNCTION 'TR_TASK_GET'
      TABLES
        tt_e070use       = li_e070use
      EXCEPTIONS
        invalid_username = 1
        invalid_category = 2
        invalid_client   = 3
        OTHERS           = 4.
    IF sy-subrc = 0.
      READ TABLE li_e070use INTO ex_saved INDEX 1.
    ENDIF.

    CALL FUNCTION 'TR_TASK_SET'
      EXPORTING
        iv_order          = im_request
        iv_validdays      = 1
      EXCEPTIONS
        invalid_username  = 1
        invalid_category  = 2
        invalid_client    = 3
        invalid_validdays = 4
        invalid_order     = 5
        invalid_task      = 6
        OTHERS            = 7.
    IF sy-subrc <> 0.
      ex_message = sy_message( ).
      CONCATENATE 'Request could not be set as default:' ex_message INTO ex_message
        SEPARATED BY space.
    ENDIF.

  ENDMETHOD.


  METHOD set_field.

    FIELD-SYMBOLS <lf_field> TYPE any.

    IF ch_error IS NOT INITIAL.
      RETURN.
    ENDIF.
    ASSIGN COMPONENT im_field OF STRUCTURE ch_target TO <lf_field>.
    IF sy-subrc <> 0.
      CONCATENATE 'Function interface field' im_field 'does not exist on this release.'
        INTO ch_error SEPARATED BY space.
      RETURN.
    ENDIF.
    <lf_field> = im_value.

  ENDMETHOD.


  METHOD split_source.

    DATA lv_line TYPE string.
    DATA lv_len  TYPE i.
    DATA lv_off  TYPE i.
    DATA lv_idx  TYPE i.
    DATA lv_num  TYPE string.
    DATA lw_abap TYPE abaptxt255.

    CLEAR: ex_abap, ex_lines, ex_message.

    SPLIT im_source AT cl_abap_char_utilities=>newline INTO TABLE ex_lines.
    LOOP AT ex_lines INTO lv_line.
      lv_idx = sy-tabix.
      lv_len = strlen( lv_line ).
      IF lv_len > 0.
        lv_off = lv_len - 1.
        IF lv_line+lv_off(1) = cl_abap_char_utilities=>cr_lf(1).
          lv_line = lv_line(lv_off).
          MODIFY ex_lines FROM lv_line.
          lv_len = lv_off.
        ENDIF.
      ENDIF.
      IF lv_len > c_max_line.
        lv_num = lv_idx.
        CONDENSE lv_num.
        CONCATENATE 'Line' lv_num 'is longer than 255 characters.' INTO ex_message
          SEPARATED BY space.
        RETURN.
      ENDIF.
      lw_abap-line = lv_line.
      APPEND lw_abap TO ex_abap.
    ENDLOOP.
    IF ex_abap IS INITIAL.
      ex_message = 'Empty source - deleting code is not supported by push.'.
    ENDIF.

  ENDMETHOD.


  METHOD sy_message.

    IF sy-msgid IS INITIAL.
      ex_text = 'Unknown error.'.
      RETURN.
    ENDIF.
    MESSAGE ID sy-msgid TYPE 'S' NUMBER sy-msgno
      WITH sy-msgv1 sy-msgv2 sy-msgv3 sy-msgv4 INTO ex_text.

  ENDMETHOD.


  METHOD write_class.
    "All parts of one class in a single pass, the way abapGit deserializes
    "a class on 7.02 (ZCL_ABAPGIT_OBJECT_CLAS->DESERIALIZE_ABAP):
    "  create the class if it is new         -> ...OO_OBJECT_FNC~CREATE
    "  local classes, if any was pushed      -> ...~GENERATE_LOCALS
    "  scan + write sections, metadata,
    "  method includes, full-class include   -> ...~DESERIALIZE_SOURCE
    "abapGit's class is called by name: if abapGit is not in the system
    "this class still activates and the push answers with a clear text.
    "The includes are left INACTIVE; ACTIVATE makes them active with the
    "other parts of the push.

    DATA lo_oo      TYPE REF TO object.
    DATA lx_root    TYPE REF TO cx_root.
    DATA lw_key     TYPE seoclskey.
    DATA lw_class   TYPE vseoclass.
    DATA lw_saved   TYPE e070use.
    DATA li_source  TYPE string_table.
    DATA li_ccdef   TYPE string_table.
    DATA li_ccimp   TYPE string_table.
    DATA li_ccmac   TYPE string_table.
    DATA li_ccau    TYPE string_table.
    DATA lv_ooname  TYPE string.
    DATA lv_method  TYPE string.
    DATA lv_msg     TYPE string.
    DATA lv_first   TYPE abap_bool VALUE abap_true.
    DATA lv_new     TYPE abap_bool.
    DATA lv_local   TYPE abap_bool.
    DATA lv_has_loc TYPE abap_bool.
    DATA lv_pkg     TYPE devclass.
    DATA lv_req     TYPE trkorr.
    DATA lv_lang    TYPE sy-langu.
    DATA lv_text    TYPE string.
    DATA lv_unicode TYPE uccheck.
    DATA lv_cls     TYPE seoclsname.
    DATA lv_obj     TYPE trobj_name.
    DATA lv_cname   TYPE abap_abstypename.

    FIELD-SYMBOLS <lf_work> TYPE t_work.

    "--- what every part of this class agrees on
    LOOP AT ch_work_tab ASSIGNING <lf_work> WHERE kind = 'CLASS' AND result-name = im_name.
      IF lv_first = abap_true.
        lv_first = abap_false.
        lv_pkg   = <lf_work>-devclass.
        lv_req   = <lf_work>-request.
        lv_local = <lf_work>-local.
        lv_new   = <lf_work>-cls_new.
        lv_lang  = <lf_work>-masterlang.
        lv_text  = <lf_work>-cls_text.
      ENDIF.
      CASE <lf_work>-cls_part.
        WHEN 'locals_def' OR 'locals_imp' OR 'macros' OR 'testclasses'.
          lv_has_loc = abap_true.
      ENDCASE.
    ENDLOOP.

    lw_key-clsname = im_name.
    lv_cls         = im_name.

    "--- the request becomes the session default, so the class builder
    "    records into it without asking (a popup dumps over HTTP)
    IF lv_local = abap_false.
      set_default_request( EXPORTING im_request = lv_req
                           IMPORTING ex_saved   = lw_saved
                                     ex_message = lv_msg ).
    ENDIF.

    IF lv_msg IS INITIAL.
      TRY.
          lv_ooname = c_oo_class.
          CREATE OBJECT lo_oo TYPE (lv_ooname).

          "--- 1. a new class: shell, TADIR entry, transport entry
          IF lv_new = abap_true.
            "set by name: a field this release lacks is a clear message,
            "not a syntax error in the whole class
            set_field( EXPORTING im_field = 'CLSNAME'  im_value = im_name
                       CHANGING  ch_target = lw_class ch_error = lv_msg ).
            set_field( EXPORTING im_field = 'LANGU'    im_value = lv_lang
                       CHANGING  ch_target = lw_class ch_error = lv_msg ).
            set_field( EXPORTING im_field = 'DESCRIPT' im_value = lv_text
                       CHANGING  ch_target = lw_class ch_error = lv_msg ).
            set_field( EXPORTING im_field = 'STATE'    im_value = '1'
                       CHANGING  ch_target = lw_class ch_error = lv_msg ).
            set_field( EXPORTING im_field = 'UNICODE'  im_value = 'X'
                       CHANGING  ch_target = lw_class ch_error = lv_msg ).
            set_field( EXPORTING im_field = 'FIXPT'    im_value = 'X'
                       CHANGING  ch_target = lw_class ch_error = lv_msg ).
            set_field( EXPORTING im_field = 'CATEGORY' im_value = '00'
                       CHANGING  ch_target = lw_class ch_error = lv_msg ).
            set_field( EXPORTING im_field = 'EXPOSURE' im_value = '2'
                       CHANGING  ch_target = lw_class ch_error = lv_msg ).
            IF lv_msg IS INITIAL.
              CONCATENATE c_oo_prefix 'CREATE' INTO lv_method.
              CALL METHOD lo_oo->(lv_method)
                EXPORTING
                  iv_check      = abap_false
                  iv_package    = lv_pkg
                CHANGING
                  cg_properties = lw_class.
            ENDIF.
            lv_unicode = 'X'.
          ELSE.
            "an existing class keeps its own ABAP language version
            CALL FUNCTION 'SEO_CLIF_GET'
              EXPORTING
                cifkey       = lw_key
                version      = '1'
              IMPORTING
                class        = lw_class
              EXCEPTIONS
                not_existing = 1
                deleted      = 2
                model_only   = 3
                OTHERS       = 4.
            IF sy-subrc = 0.
              lv_unicode = lw_class-unicode.
            ENDIF.
            IF lv_unicode IS INITIAL.
              lv_unicode = 'X'.
            ENDIF.
          ENDIF.

          "--- 2. lock the class into the request (abapGit: CORR_INSERT)
          IF lv_local = abap_false AND lv_msg IS INITIAL.
            lv_obj = im_name.
            CALL FUNCTION 'RS_CORR_INSERT'
              EXPORTING
                object              = lv_obj
                object_class        = 'CLAS'
                devclass            = lv_pkg
                master_language     = lv_lang
                korrnum             = lv_req
                mode                = 'I'
                global_lock         = abap_true
                suppress_dialog     = abap_true
              EXCEPTIONS
                cancelled           = 1
                permission_failure  = 2
                unknown_objectclass = 3
                OTHERS              = 4.
            IF sy-subrc <> 0.
              lv_msg = sy_message( ).
              CONCATENATE 'Transport:' lv_msg INTO lv_msg SEPARATED BY space.
            ENDIF.
          ENDIF.

          "--- 3. local classes. GENERATE_LOCALS drops the test include when
          "       it gets no test classes, so whatever was not pushed is
          "       handed back as SAP holds it now.
          IF lv_msg IS INITIAL AND lv_has_loc = abap_true.
            li_ccdef = part_lines( im_name = im_name im_part = 'locals_def'
                                   im_works = ch_work_tab ).
            li_ccimp = part_lines( im_name = im_name im_part = 'locals_imp'
                                   im_works = ch_work_tab ).
            li_ccmac = part_lines( im_name = im_name im_part = 'macros'
                                   im_works = ch_work_tab ).
            li_ccau  = part_lines( im_name = im_name im_part = 'testclasses'
                                   im_works = ch_work_tab ).
            CONCATENATE c_oo_prefix 'GENERATE_LOCALS' INTO lv_method.
            CALL METHOD lo_oo->(lv_method)
              EXPORTING
                is_key                   = lw_key
                iv_package               = lv_pkg
                iv_version               = lv_unicode
                it_local_definitions     = li_ccdef
                it_local_implementations = li_ccimp
                it_local_macros          = li_ccmac
                it_local_test_classes    = li_ccau.
          ENDIF.

          "--- 4. sections + metadata + method includes + full-class include
          IF lv_msg IS INITIAL.
            assemble_class( EXPORTING im_name   = im_name
                                      im_works  = ch_work_tab
                            IMPORTING ex_source = li_source ).
            CONCATENATE c_oo_prefix 'DESERIALIZE_SOURCE' INTO lv_method.
            CALL METHOD lo_oo->(lv_method)
              EXPORTING
                is_key     = lw_key
                it_source  = li_source
                iv_package = lv_pkg
                iv_version = lv_unicode.
          ENDIF.

        CATCH cx_root INTO lx_root.
          lv_cname = cl_abap_classdescr=>get_class_name( lx_root ).
          lv_msg   = lx_root->get_text( ).
          IF lv_msg IS INITIAL.
            lv_msg = lv_cname.
          ENDIF.
          IF lv_cname = '\CLASS=CX_SY_CREATE_OBJECT_ERROR'.
            lv_msg = 'Class push needs abapGit (ZCL_ABAPGIT_OO_CLASS) in this system.'.
          ENDIF.
      ENDTRY.
    ENDIF.

    "the developer's own default request comes back, whatever happened
    IF lv_local = abap_false.
      reset_default_request( lw_saved ).
    ENDIF.

    "--- report, part by part
    LOOP AT ch_work_tab ASSIGNING <lf_work> WHERE kind = 'CLASS' AND result-name = im_name.
      IF lv_msg IS NOT INITIAL.
        <lf_work>-result-status  = 'error'.
        <lf_work>-result-message = lv_msg.
        CONTINUE.
      ENDIF.
      "a new method has its include only now
      <lf_work>-include        = class_include( im_class = im_name im_part = <lf_work>-cls_part ).
      <lf_work>-result-include = <lf_work>-include.
      <lf_work>-result-status  = 'written'.
      <lf_work>-result-state   = 'I'.
      <lf_work>-result-new_hash = hash_abap( <lf_work>-abap ).
      IF lv_new = abap_true.
        <lf_work>-result-message = 'Class created, saved inactive.'.
      ELSE.
        <lf_work>-result-message = 'Saved inactive.'.
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD write_enabled.

    DATA lv_val TYPE zabapmcp_cfg-cfg_value.

    ex_ok = abap_true.
    SELECT SINGLE cfg_value FROM zabapmcp_cfg INTO lv_val
      WHERE cfg_key = 'ABAPSYNC_WRITE'.
    IF sy-subrc = 0 AND lv_val = 'OFF'.
      ex_ok = abap_false.
    ENDIF.

  ENDMETHOD.


  METHOD write_include.

    DATA lv_logon  TYPE sy-langu.
    DATA lv_title  TYPE repti.
    DATA lv_object TYPE trobj_name.
    DATA lv_msg    TYPE string.
    DATA lv_subrc  TYPE sy-subrc.
    DATA lv_err    TYPE string.
    DATA lw_saved  TYPE e070use.

    FIELD-SYMBOLS <lf_ttab> TYPE any.

    lv_logon = sy-langu.

    "--- 1. record in the transport (abapGit: ZCL_ABAPGIT_CTS_API)
    IF ch_work-local = abap_false.
      lv_object = ch_work-include.
      CALL FUNCTION 'RS_CORR_INSERT'
        EXPORTING
          object              = lv_object
          object_class        = 'ABAP'
          devclass            = ch_work-devclass
          master_language     = ch_work-masterlang
          korrnum             = ch_work-request
          mode                = 'I'
          global_lock         = abap_true
          suppress_dialog     = abap_true
        EXCEPTIONS
          cancelled           = 1
          permission_failure  = 2
          unknown_objectclass = 3
          OTHERS              = 4.
      IF sy-subrc <> 0.
        lv_msg = sy_message( ).
        CONCATENATE 'Transport:' lv_msg INTO ch_work-result-message SEPARATED BY space.
        ch_work-result-status = 'error'.
        RETURN.
      ENDIF.
    ENDIF.

    "--- 2. save inactive, in the object's original language
    "       (abapGit: ZCL_ABAPGIT_OBJECTS_PROGRAM->UPDATE_PROGRAM)
    lv_title = get_title( im_include = ch_work-include im_lang = ch_work-masterlang ).

    "RPY_PROGRAM_UPDATE / RPY_INCLUDE_UPDATE keep the header line of TTAB
    "between calls, so a title length can leak between objects (abapGit)
    ASSIGN ('(SAPLSIFP)TTAB') TO <lf_ttab>.
    IF sy-subrc = 0.
      CLEAR <lf_ttab>.
    ENDIF.

    "RPY_INCLUDE_UPDATE records the transport again on its own and asks
    "which request to use when the session has no default request - a
    "popup that dumps over HTTP (DYNPRO_SEND_IN_BACKGROUND, 11.10.2026).
    "Same cure as classes and new function modules: the push request is
    "the session default while SAP saves, then the developer's own comes
    "back (0.9.2).
    IF ch_work-local = abap_false.
      set_default_request( EXPORTING im_request = ch_work-request
                           IMPORTING ex_saved   = lw_saved
                                     ex_message = lv_msg ).
    ENDIF.

    IF ch_work-masterlang <> lv_logon.
      SET LOCALE LANGUAGE ch_work-masterlang.
    ENDIF.

    CALL FUNCTION 'RPY_INCLUDE_UPDATE'
      EXPORTING
        include_name     = ch_work-include
        title_string     = lv_title
        save_inactive    = 'I'
      TABLES
        source_extended  = ch_work-abap
      EXCEPTIONS
        not_found        = 1
        cancelled        = 2
        permission_error = 3
        OTHERS           = 4.
    lv_subrc = sy-subrc.

    "the message is read before the request reset can overwrite SY-MSG*
    IF lv_subrc <> 0.
      IF sy-msgid = 'EU' AND sy-msgno = '510'.
        lv_err = 'Somebody is editing this object right now (EU510).'.
      ELSE.
        lv_err = sy_message( ).
      ENDIF.
    ENDIF.

    IF ch_work-masterlang <> lv_logon.
      SET LOCALE LANGUAGE lv_logon.
    ENDIF.

    "the developer's own default request comes back, whatever happened
    IF ch_work-local = abap_false.
      reset_default_request( lw_saved ).
    ENDIF.

    IF lv_subrc <> 0.
      ch_work-result-status  = 'error'.
      ch_work-result-message = lv_err.
      RETURN.
    ENDIF.

    ch_work-result-status   = 'written'.
    ch_work-result-state    = 'I'.
    ch_work-result-new_hash = hash_abap( ch_work-abap ).
    ch_work-result-message  = 'Saved inactive.'.

  ENDMETHOD.


  METHOD write_part.

    IF ch_work-kind = 'NEWFUNC'.
      create_func( CHANGING ch_work = ch_work ).
    ELSE.
      write_include( CHANGING ch_work = ch_work ).
    ENDIF.

  ENDMETHOD.


ENDCLASS.
