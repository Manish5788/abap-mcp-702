CLASS zcl_abapmcp_cts DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.
*--------------------------------------------------------------------*
* Title       : ZCL_ABAPMCP_CTS - transport and change history MCP tools
* Type        : Class (MCP tool plug-in, read-only)
* Frequency   : On demand (called per MCP tools/call)
* Description : Three read-only tools on /sap/bc/mcp for project
*               inventories ("which objects belong to project X, and
*               how far has each got in the landscape?"):
*                 sap_transport_search  requests whose description
*                                       contains a word, their objects
*                                       and where they were imported
*                 sap_object_transports every request that changed one
*                                       object, import status per
*                                       system, and its version history
*                 sap_search_source     custom programs, classes and
*                                       function groups whose source -
*                                       by default the header and its
*                                       change log - contains a word
*--------------------------------------------------------------------*
*& Plug-in class, same contract as ZCL_ABAPMCP_CUST:
*&   ZCL_ABAPMCP_TOOLS=>GET_TOOL_DEFS splices GET_TOOL_DEFS_JSON into
*&   its catalogue, and ZCL_ABAPMCP_TOOLS=>EXECUTE hands any tool for
*&   which HANDLES is true to EXECUTE here.
*&
*& READ-ONLY. SELECTs, READ REPORT and the transport log reader only.
*& There is no write statement and adding one defeats the purpose of
*& this server.
*&
*& AUTHORIZATION
*& The transport tools need S_TRANSPRT display (ACTVT 03), the same as
*& displaying a request in SE09. Source search is limited to Z and Y
*& objects, like sap_get_source.
*&
*& IMPORT HISTORY
*& Which systems a request was imported into is read from its
*& transport log (cofile) with TR_READ_GLOBAL_INFO_OF_REQUEST. Its
*& result type lives in type group CTSLG, so it is created and read
*& dynamically: when the layout differs on a release, the answer says
*& the history is unavailable instead of the class failing.
*&
*& NW 7.02 syntax only: no inline DATA( ), no VALUE #( ), no NEW.
*&---------------------------------------------------------------------*

*   Requests per answer: default and ceiling.
    CONSTANTS c_def_requests TYPE i VALUE 30.
    CONSTANTS c_max_requests TYPE i VALUE 100.
*   Requests whose transport log is read in one answer.
    CONSTANTS c_max_imports  TYPE i VALUE 60.
*   Objects listed per request, and in the combined object list.
    CONSTANTS c_req_objects  TYPE i VALUE 60.
    CONSTANTS c_max_objects  TYPE i VALUE 500.
*   Parts listed per request in sap_object_transports.
    CONSTANTS c_max_parts    TYPE i VALUE 20.
*   Versions listed in sap_object_transports.
    CONSTANTS c_max_versions TYPE i VALUE 20.
*   Source search: hits per answer, includes read, lines per hit, and
*   how many lines count as the header.
    CONSTANTS c_def_hits     TYPE i VALUE 50.
    CONSTANTS c_max_hits     TYPE i VALUE 200.
    CONSTANTS c_max_scan     TYPE i VALUE 3000.
    CONSTANTS c_hit_lines    TYPE i VALUE 3.
    CONSTANTS c_head_lines   TYPE i VALUE 120.
*   Release-order dependencies in sap_open_requests: the production
*   system, requests per object read, how far back an open request still
*   counts as active work, and how many objects
*   per answer are checked (each costs one history read). 12.10.2026
    CONSTANTS c_prod_system  TYPE string VALUE 'PRD'.
    CONSTANTS c_dep_requests TYPE i VALUE 10.
    CONSTANTS c_dep_days     TYPE i VALUE 365.
    CONSTANTS c_dep_objects  TYPE i VALUE 25.
*   Absolute name of the transport log structure (type group CTSLG).
    CONSTANTS c_cofile_type  TYPE string VALUE '\TYPE-POOL=CTSLG\TYPE=CTSLG_COFILE'.

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
*"* protected components of class ZCL_ABAPMCP_CTS
*"* do not include other source files here!!!

  PRIVATE SECTION.

*   One transport request (never a task).
    TYPES: BEGIN OF t_req,
             trkorr     TYPE trkorr,
             trfunction TYPE trfunction,
             trstatus   TYPE trstatus,
             as4user    TYPE tr_as4user,
             as4date    TYPE as4date,
             as4time    TYPE as4time,
             strkorr    TYPE strkorr,
           END OF t_req,
           t_req_tab TYPE STANDARD TABLE OF t_req WITH DEFAULT KEY.

    TYPES t_korr_tab TYPE STANDARD TABLE OF trkorr WITH DEFAULT KEY.

*   Task or request -> the request it belongs to.
    TYPES: BEGIN OF t_map,
             trkorr  TYPE trkorr,
             request TYPE trkorr,
           END OF t_map,
           t_map_tab TYPE SORTED TABLE OF t_map WITH UNIQUE KEY trkorr.

*   One object list entry of a request or task.
    TYPES: BEGIN OF t_e071,
             trkorr   TYPE trkorr,
             pgmid    TYPE pgmid,
             object   TYPE trobjtype,
             obj_name TYPE trobj_name,
           END OF t_e071,
           t_e071_tab TYPE STANDARD TABLE OF t_e071 WITH DEFAULT KEY.

*   An object as a developer names it (R3TR level).
    TYPES: BEGIN OF t_obj,
             object   TYPE trobjtype,
             obj_name TYPE trobj_name,
           END OF t_obj,
           t_obj_tab TYPE STANDARD TABLE OF t_obj WITH DEFAULT KEY.

*   An object changed in a task of a request, with the task's owner.
    TYPES: BEGIN OF t_tobj,
             object   TYPE trobjtype,
             obj_name TYPE trobj_name,
             owner    TYPE tr_as4user,
             task     TYPE trkorr,
           END OF t_tobj,
           t_tobj_tab TYPE STANDARD TABLE OF t_tobj WITH DEFAULT KEY.

*   Import of one request into one other system.
    TYPES: BEGIN OF t_imp,
             system   TYPE string,
             imported TYPE abap_bool,
             date     TYPE string,
             rc       TYPE i,
           END OF t_imp,
           t_imp_tab TYPE STANDARD TABLE OF t_imp WITH DEFAULT KEY.

*   System descriptions from TMS, read once per call.
    TYPES: BEGIN OF t_sys,
             sysnam TYPE tmssysnam,
             systxt TYPE as4text,
           END OF t_sys.
    CLASS-DATA gt_sys TYPE STANDARD TABLE OF t_sys WITH DEFAULT KEY.

    CLASS-METHODS transport_search
      IMPORTING im_input       TYPE string
      RETURNING VALUE(ex_json) TYPE string
      RAISING   zcx_ajson_error.

    CLASS-METHODS object_transports
      IMPORTING im_input       TYPE string
      RETURNING VALUE(ex_json) TYPE string
      RAISING   zcx_ajson_error.

    CLASS-METHODS source_search
      IMPORTING im_input       TYPE string
      RETURNING VALUE(ex_json) TYPE string
      RAISING   zcx_ajson_error.

*   Open requests of one user (or one request) with the parts changed.
    CLASS-METHODS open_requests
      IMPORTING im_input       TYPE string
      RETURNING VALUE(ex_json) TYPE string
      RAISING   zcx_ajson_error.

*   Release-order dependencies of one object of an open request: other
*   requests with the same object not yet in production, and other
*   users' tasks in the same request (im_shared). 12.10.2026
    CLASS-METHODS add_dependencies
      IMPORTING im_out     TYPE REF TO zcl_ajson
                im_base    TYPE string
                im_object  TYPE trobjtype
                im_name    TYPE trobj_name
                im_request TYPE trkorr
                im_shared  TYPE t_tobj_tab
      CHANGING  ch_owners  TYPE string_table
                ch_count   TYPE i
      RAISING   zcx_ajson_error.

*   S_TRANSPRT display, as in SE09.
    CLASS-METHODS auth_ok
      RETURNING VALUE(ex_ok) TYPE abap_bool.

*   The requests behind a list of requests and tasks, and which request
*   each entry belongs to.
    CLASS-METHODS requests_of
      IMPORTING im_list TYPE t_korr_tab
      EXPORTING ex_reqs TYPE t_req_tab
                ex_map  TYPE t_map_tab.

*   Every object a request and its tasks contain, at R3TR level.
    CLASS-METHODS request_objects
      IMPORTING im_trkorr      TYPE trkorr
      RETURNING VALUE(ex_list) TYPE t_obj_tab.

*   The R3TR object an object list entry belongs to.
    CLASS-METHODS main_object
      IMPORTING im_entry  TYPE t_e071
      EXPORTING ex_object TYPE trobjtype
                ex_name   TYPE trobj_name.

*   The program an include belongs to, as an R3TR object.
    CLASS-METHODS include_owner
      IMPORTING im_include TYPE string
      EXPORTING ex_object  TYPE trobjtype
                ex_name    TYPE trobj_name.

*   Where a request was imported, from its transport log.
    CLASS-METHODS read_imports
      IMPORTING im_trkorr TYPE trkorr
      EXPORTING ex_list   TYPE t_imp_tab
                ex_export TYPE string
                ex_note   TYPE string.

*   Request header, text and - when asked - its import history.
    CLASS-METHODS add_request
      IMPORTING im_out     TYPE REF TO zcl_ajson
                im_base    TYPE string
                im_req     TYPE t_req
                im_imports TYPE abap_bool
      EXPORTING ex_imports TYPE t_imp_tab
      RAISING   zcx_ajson_error.

    CLASS-METHODS request_text
      IMPORTING im_trkorr      TYPE trkorr
      RETURNING VALUE(ex_text) TYPE string.

    CLASS-METHODS type_text
      IMPORTING im_type        TYPE trfunction
      RETURNING VALUE(ex_text) TYPE string.

    CLASS-METHODS status_text
      IMPORTING im_status      TYPE trstatus
      RETURNING VALUE(ex_text) TYPE string.

    CLASS-METHODS system_text
      IMPORTING im_system      TYPE string
      RETURNING VALUE(ex_text) TYPE string.

*   YYYYMMDD as YYYY-MM-DD; anything else unchanged.
    CLASS-METHODS iso_date
      IMPORTING im_date        TYPE clike
      RETURNING VALUE(ex_text) TYPE string.

    CLASS-METHODS error_json
      IMPORTING im_msg         TYPE string
      RETURNING VALUE(ex_json) TYPE string.

ENDCLASS.


CLASS zcl_abapmcp_cts IMPLEMENTATION.

  METHOD add_dependencies.
*&---------------------------------------------------------------------*
*& Release-order dependencies of one object of an open request, written
*& to <im_base>/dependencies. A transport carries the whole current
*& object, so another request with the same object matters when it is
*&   not_in_prd     released but not imported into the production
*&                  system, and newer than anything that reached it:
*&                  this request carries that change too, and importing
*&                  the older one after it would overwrite it;
*&   stale_in_queue released, not in production, but older than a
*&                  request that reached it - its change is already
*&                  there, importing it now would put an older version
*&                  back (queue hygiene, not this release's problem;
*&                  not counted in ch_count / ch_owners);
*&   open_elsewhere still open in another request (last c_dep_days);
*&   same_request   another user's task in this very request changed
*&                  the object (im_shared, worked out by the caller).
*& The history comes from OBJECT_TRANSPORTS (newest c_dep_requests
*& requests, newest first). Never fails the caller: anything
*& that goes wrong here just leaves the list empty. Warning only - it
*& does not change a review verdict. 12.10.2026
*&---------------------------------------------------------------------*

    DATA lv_in    TYPE string.
    DATA lv_json  TYPE string.
    DATA lo_hist  TYPE REF TO zif_ajson.
    DATA li_rq    TYPE string_table.
    DATA li_im    TYPE string_table.
    DATA lv_rq    TYPE string.
    DATA lv_im    TYPE string.
    DATA lv_path  TYPE string.
    DATA lv_req   TYPE string.
    DATA lv_stat  TYPE string.
    DATA lv_own   TYPE string.
    DATA lv_txt   TYPE string.
    DATA lv_chg   TYPE string.
    DATA lv_exp   TYPE string.
    DATA lv_sys   TYPE string.
    DATA lv_date  TYPE string.
    DATA lv_where TYPE string.
    DATA lv_kind  TYPE string.
    DATA lv_adv   TYPE string.
    DATA lv_prd   TYPE abap_bool.
    DATA lv_seen  TYPE abap_bool.
    DATA lv_cut   TYPE d.
    DATA lv_cutc  TYPE string.
    DATA lv_n     TYPE i.
    DATA lv_i     TYPE string.
    DATA lv_max   TYPE string.
    DATA lv_dbase TYPE string.
    DATA lv_ebase TYPE string.
    DATA lv_typ   TYPE string.
    DATA lv_nam   TYPE string.
    DATA lv_cur   TYPE string.
    DATA lv_own_k TYPE string.
    DATA lw_sh    TYPE t_tobj.
    DATA lx_root  TYPE REF TO cx_root.

    lv_typ = im_object.
    lv_nam = im_name.
    lv_cur = im_request.
    CONCATENATE sy-sysid 'K' INTO lv_own_k.
    lv_cut = sy-datum - c_dep_days.
    lv_cutc = iso_date( lv_cut ).
    lv_max = c_dep_requests.
    CONDENSE lv_max.

    CONCATENATE im_base '/dependencies' INTO lv_dbase.
    im_out->touch_array( lv_dbase ).
    lv_n = 0.

*   ---- another user's task in this request ---------------------------
    LOOP AT im_shared INTO lw_sh.
      lv_n = lv_n + 1.
      lv_i = lv_n.
      CONDENSE lv_i.
      CONCATENATE lv_dbase '/' lv_i INTO lv_ebase.
      lv_own = lw_sh-owner.
      lv_req = lw_sh-task.
      CONCATENATE 'Also changed by' lv_own 'in task' lv_req
                  'of this request. Both changes go to production together - agree with them before releasing.'
        INTO lv_adv SEPARATED BY space.
      CONCATENATE lv_ebase '/kind' INTO lv_path.
      im_out->set( iv_path = lv_path iv_val = 'same_request' ).
      CONCATENATE lv_ebase '/request' INTO lv_path.
      im_out->set( iv_path = lv_path iv_val = lv_cur ).
      CONCATENATE lv_ebase '/task' INTO lv_path.
      im_out->set( iv_path = lv_path iv_val = lv_req ).
      CONCATENATE lv_ebase '/owner' INTO lv_path.
      im_out->set( iv_path = lv_path iv_val = lv_own ).
      CONCATENATE lv_ebase '/advice' INTO lv_path.
      im_out->set( iv_path = lv_path iv_val = lv_adv ).
      ch_count = ch_count + 1.
      READ TABLE ch_owners TRANSPORTING NO FIELDS WITH KEY table_line = lv_own.
      IF sy-subrc <> 0.
        APPEND lv_own TO ch_owners.
      ENDIF.
    ENDLOOP.

*   ---- other requests with the same object ---------------------------
    CONCATENATE `{"name":"` lv_nam `","type":"` lv_typ `","max_results":` lv_max `}` INTO lv_in.
    TRY.
        lv_json = object_transports( lv_in ).
        IF strlen( lv_json ) >= 9 AND lv_json(9) = '{"error":'.
          RETURN.
        ENDIF.
        lo_hist = zcl_ajson=>parse( lv_json ).
        li_rq = lo_hist->members( '/requests' ).
      CATCH cx_root INTO lx_root.
        RETURN.
    ENDTRY.

    LOOP AT li_rq INTO lv_rq.
      CONCATENATE '/requests/' lv_rq '/request' INTO lv_path.
      lv_req = lo_hist->get( lv_path ).
      IF lv_req = lv_cur.
        CONTINUE.
      ENDIF.
*     only requests made here go up the landscape; SAPK* command files
*     and requests imported from elsewhere never do
      IF strlen( lv_req ) < 4 OR lv_req(4) <> lv_own_k.
        CONTINUE.
      ENDIF.
      CONCATENATE '/requests/' lv_rq '/changed' INTO lv_path.
      lv_chg = lo_hist->get( lv_path ).
      CONCATENATE '/requests/' lv_rq '/status' INTO lv_path.
      lv_stat = lo_hist->get( lv_path ).
      CONCATENATE '/requests/' lv_rq '/owner' INTO lv_path.
      lv_own = lo_hist->get( lv_path ).
      CONCATENATE '/requests/' lv_rq '/text' INTO lv_path.
      lv_txt = lo_hist->get( lv_path ).
      CONCATENATE '/requests/' lv_rq '/exported' INTO lv_path.
      lv_exp = lo_hist->get( lv_path ).

      CLEAR: lv_kind, lv_where, lv_prd, lv_adv.
      IF lv_stat CP 'released*'.
*       where it got to; reached production means no dependency
        CONCATENATE '/requests/' lv_rq '/imports' INTO lv_path.
        li_im = lo_hist->members( lv_path ).
        LOOP AT li_im INTO lv_im.
          CONCATENATE '/requests/' lv_rq '/imports/' lv_im '/imported' INTO lv_path.
          IF lo_hist->get_boolean( lv_path ) = abap_false.
            CONTINUE.
          ENDIF.
          CONCATENATE '/requests/' lv_rq '/imports/' lv_im '/system' INTO lv_path.
          lv_sys = lo_hist->get( lv_path ).
          CONCATENATE '/requests/' lv_rq '/imports/' lv_im '/date' INTO lv_path.
          lv_date = lo_hist->get( lv_path ).
          IF lv_sys = c_prod_system.
            lv_prd = abap_true.
          ENDIF.
          IF lv_where IS INITIAL.
            CONCATENATE lv_sys lv_date INTO lv_where SEPARATED BY space.
          ELSE.
            CONCATENATE lv_where `, ` lv_sys ` ` lv_date INTO lv_where.
          ENDIF.
        ENDLOOP.
*       newest first: once one reached production, older ones are stale
        IF lv_prd = abap_true.
          lv_seen = abap_true.
          CONTINUE.
        ENDIF.
        IF lv_where IS INITIAL.
          lv_where = 'not imported anywhere yet'.
        ENDIF.
        IF lv_seen = abap_true.
          lv_kind = 'stale_in_queue'.
          CONCATENATE 'Released, never imported to' c_prod_system '- but a newer request already took the object there.'
                      'Do not import' lv_req 'to' c_prod_system 'any more: it would put an older version back. Remove it from the import queue.'
            INTO lv_adv SEPARATED BY space.
        ELSE.
          lv_kind = 'not_in_prd'.
          CONCATENATE 'Released, not yet in' c_prod_system '- your request carries this change too. Import'
                      lv_req 'to' c_prod_system 'first, or together with yours, never yours alone.'
            INTO lv_adv SEPARATED BY space.
        ENDIF.
      ELSEIF lv_stat CP 'modifiable*'.
*       a request left open for longer than that is not active work
        IF lv_chg < lv_cutc.
          CONTINUE.
        ENDIF.
        lv_kind = 'open_elsewhere'.
        CONCATENATE 'Also open in' lv_req 'of' lv_own '- agree who releases first.'
          INTO lv_adv SEPARATED BY space.
      ELSE.
        CONTINUE.
      ENDIF.

      lv_n = lv_n + 1.
      lv_i = lv_n.
      CONDENSE lv_i.
      CONCATENATE lv_dbase '/' lv_i INTO lv_ebase.
      CONCATENATE lv_ebase '/kind' INTO lv_path.
      im_out->set( iv_path = lv_path iv_val = lv_kind ).
      CONCATENATE lv_ebase '/request' INTO lv_path.
      im_out->set( iv_path = lv_path iv_val = lv_req ).
      CONCATENATE lv_ebase '/owner' INTO lv_path.
      im_out->set( iv_path = lv_path iv_val = lv_own ).
      CONCATENATE lv_ebase '/status' INTO lv_path.
      im_out->set( iv_path = lv_path iv_val = lv_stat ).
      CONCATENATE lv_ebase '/text' INTO lv_path.
      im_out->set( iv_path = lv_path iv_val = lv_txt ).
      CONCATENATE lv_ebase '/changed' INTO lv_path.
      im_out->set( iv_path = lv_path iv_val = lv_chg ).
      IF lv_exp IS NOT INITIAL.
        CONCATENATE lv_ebase '/released' INTO lv_path.
        im_out->set( iv_path = lv_path iv_val = lv_exp ).
      ENDIF.
      IF lv_where IS NOT INITIAL.
        CONCATENATE lv_ebase '/imported_to' INTO lv_path.
        im_out->set( iv_path = lv_path iv_val = lv_where ).
      ENDIF.
      CONCATENATE lv_ebase '/advice' INTO lv_path.
      im_out->set( iv_path = lv_path iv_val = lv_adv ).

*     a stale request is shown, but nobody needs to agree on it
      IF lv_kind = 'stale_in_queue'.
        CONTINUE.
      ENDIF.
      ch_count = ch_count + 1.
      READ TABLE ch_owners TRANSPORTING NO FIELDS WITH KEY table_line = lv_own.
      IF sy-subrc <> 0.
        APPEND lv_own TO ch_owners.
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD add_request.
*&---------------------------------------------------------------------*
*& One request at im_base: number, description, type, status, owner,
*& last change and - when asked - its export date and, per other
*& system, whether it was imported, when, and with which return code.
*&---------------------------------------------------------------------*

    DATA lv_path   TYPE string.
    DATA lv_val    TYPE string.
    DATA lv_i      TYPE string.
    DATA lv_base   TYPE string.
    DATA lv_export TYPE string.
    DATA lv_note   TYPE string.
    DATA li_imps   TYPE t_imp_tab.
    DATA lw_imp    TYPE t_imp.

    CLEAR ex_imports.

    CONCATENATE im_base '/request' INTO lv_path.
    lv_val = im_req-trkorr.
    im_out->set( iv_path = lv_path iv_val = lv_val ).
    CONCATENATE im_base '/text' INTO lv_path.
    lv_val = request_text( im_req-trkorr ).
    im_out->set( iv_path = lv_path iv_val = lv_val ).
    CONCATENATE im_base '/type' INTO lv_path.
    lv_val = type_text( im_req-trfunction ).
    im_out->set( iv_path = lv_path iv_val = lv_val ).
    CONCATENATE im_base '/status' INTO lv_path.
    lv_val = status_text( im_req-trstatus ).
    im_out->set( iv_path = lv_path iv_val = lv_val ).
    CONCATENATE im_base '/owner' INTO lv_path.
    lv_val = im_req-as4user.
    im_out->set( iv_path = lv_path iv_val = lv_val ).
    CONCATENATE im_base '/changed' INTO lv_path.
    lv_val = iso_date( im_req-as4date ).
    im_out->set( iv_path = lv_path iv_val = lv_val ).

    IF im_imports = abap_false.
      RETURN.
    ENDIF.

    read_imports( EXPORTING im_trkorr = im_req-trkorr
                  IMPORTING ex_list   = li_imps
                            ex_export = lv_export
                            ex_note   = lv_note ).
    IF lv_export IS NOT INITIAL.
      CONCATENATE im_base '/exported' INTO lv_path.
      lv_val = iso_date( lv_export ).
      im_out->set( iv_path = lv_path iv_val = lv_val ).
    ENDIF.
    IF lv_note IS NOT INITIAL.
      CONCATENATE im_base '/imports_note' INTO lv_path.
      im_out->set( iv_path = lv_path iv_val = lv_note ).
    ENDIF.

    CONCATENATE im_base '/imports' INTO lv_path.
    im_out->touch_array( lv_path ).
    LOOP AT li_imps INTO lw_imp.
      lv_i = sy-tabix.
      CONDENSE lv_i.
      CONCATENATE im_base '/imports/' lv_i INTO lv_base.
      CONCATENATE lv_base '/system' INTO lv_path.
      im_out->set( iv_path = lv_path iv_val = lw_imp-system ).
      lv_val = system_text( lw_imp-system ).
      IF lv_val IS NOT INITIAL.
        CONCATENATE lv_base '/description' INTO lv_path.
        im_out->set( iv_path = lv_path iv_val = lv_val ).
      ENDIF.
      CONCATENATE lv_base '/imported' INTO lv_path.
      im_out->set_boolean( iv_path = lv_path iv_val = lw_imp-imported ).
      CONCATENATE lv_base '/date' INTO lv_path.
      lv_val = iso_date( lw_imp-date ).
      im_out->set( iv_path = lv_path iv_val = lv_val ).
      CONCATENATE lv_base '/rc' INTO lv_path.
      im_out->set_integer( iv_path = lv_path iv_val = lw_imp-rc ).
    ENDLOOP.

    ex_imports = li_imps.

  ENDMETHOD.


  METHOD auth_ok.
*&---------------------------------------------------------------------*
*& Display authorization for transport requests, as SE09 checks it.
*&---------------------------------------------------------------------*

    AUTHORITY-CHECK OBJECT 'S_TRANSPRT'
      ID 'TTYPE' DUMMY
      ID 'ACTVT' FIELD '03'.
    IF sy-subrc = 0.
      ex_ok = abap_true.
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
*& Route one tool call. A tool failure is a normal result carrying an
*& error text the model can act on, never an exception to the server.
*&---------------------------------------------------------------------*

    DATA lx_root TYPE REF TO cx_root.
    DATA lv_msg  TYPE string.

    CLEAR gt_sys.

    TRY.
        CASE im_name.
          WHEN 'sap_transport_search'.
            ex_result = transport_search( im_input = im_input ).
          WHEN 'sap_object_transports'.
            ex_result = object_transports( im_input = im_input ).
          WHEN 'sap_search_source'.
            ex_result = source_search( im_input = im_input ).
          WHEN 'sap_open_requests'.
            ex_result = open_requests( im_input = im_input ).
          WHEN OTHERS.
            CONCATENATE 'Unknown tool:' im_name INTO lv_msg SEPARATED BY space.
            ex_result = error_json( im_msg = lv_msg ).
        ENDCASE.
      CATCH cx_root INTO lx_root.
        lv_msg = lx_root->get_text( ).
        ex_result = error_json( im_msg = lv_msg ).
    ENDTRY.

  ENDMETHOD.


  METHOD get_tool_defs_json.
*&---------------------------------------------------------------------*
*& Tool catalogue. Each description says what the tool returns AND what
*& it does not, so the model picks the right one of the three.
*& 23.10.2026: shortened - tools/list was over the 6k token budget.
*&---------------------------------------------------------------------*

    CONCATENATE
      `{"name":"sap_transport_search",`
      ` "description":"Find transport requests whose description (or a task's) contains a word, e.g. a `
      `project name such as PAYMENTS, newest first: text, type, status, owner, objects, and per system whether `
      `and when it was imported. Ends with one de-duplicated object list with packages - a project `
      `inventory in one call. History of one object: sap_object_transports. Source code: sap_search_source.",`
      ` "input_schema":{"type":"object","properties":{`
      `   "text":{"type":"string","description":"Word from the description, 3-60 characters, e.g. PAYMENTS."},`
      `   "max_results":{"type":"integer","description":"1-100, default 30."},`
      `   "objects":{"type":"boolean","description":"List objects. Default true."},`
      `   "imports":{"type":"boolean","description":"Read imports into QA, PRD ... Default true."}},`
      `   "required":["text"]}},`
      `{"name":"sap_object_transports",`
      ` "description":"Transport and change history of ONE custom object: every request that changed it or `
      `a part of it, newest first, with the parts and where it was imported; per system how many released `
      `requests reached it; requests still open here; and the SE38/SE24 version history. Use it to see `
      `whether an object is in production or only in DEV/QA. Z and Y objects only.",`
      ` "input_schema":{"type":"object","properties":{`
      `   "name":{"type":"string","description":"Object name, e.g. ZCL_FI_PAYMENT_API."},`
      `   "type":{"type":"string","description":"PROG, CLAS, FUGR, TABL ... when the name is ambiguous."},`
      `   "max_results":{"type":"integer","description":"1-100, default 30."}},`
      `   "required":["name"]}},`
      `{"name":"sap_search_source",`
      ` "description":"Find custom programs, classes and function groups whose source contains a word - by `
      `default only in the include header, where the program header and change log sit, so it finds objects `
      `by project, ticket or author. Each hit gives object, include, package and matching lines. Reads at `
      `most 3000 includes. Transport descriptions: sap_transport_search.",`
      ` "input_schema":{"type":"object","properties":{`
      `   "text":{"type":"string","description":"Word to find, 3-60 characters."},`
      `   "pattern":{"type":"string","description":"Name pattern with *, Z or Y, e.g. ZFI*."},`
      `   "package":{"type":"string","description":"Package, e.g. ZFI. Give pattern, package or both."},`
      `   "header_only":{"type":"boolean","description":"Only the first 120 lines of each include. Default true."},`
      `   "max_results":{"type":"integer","description":"1-200, default 50."}},`
      `   "required":["text"]}},`
      `{"name":"sap_open_requests",`
      ` "description":"Open (unreleased) transport requests of one SAP user, or one request by number, for `
      `a code review: tasks with owner and status, and every object with the parts that changed (methods, `
      `includes, FMs, screens) - read those with sap_get_source. Customizing is counted, not listed. `
      `dependencies warns about release order per object: not_in_prd, stale_in_queue, open_elsewhere, `
      `same_request. Released history: sap_object_transports.",`
      ` "input_schema":{"type":"object","properties":{`
      `   "owner":{"type":"string","description":"SAP user, e.g. DEVELOPER1."},`
      `   "request":{"type":"string","description":"Request or task instead, e.g. DEVK900123."},`
      `   "max_results":{"type":"integer","description":"1-100, default 30."}},`
      `   "required":[]}}`
      INTO ex_json.

  ENDMETHOD.


  METHOD handles.
*&---------------------------------------------------------------------*
*& The three transport and change history tools of this class.
*&---------------------------------------------------------------------*

    IF im_name = 'sap_transport_search' OR im_name = 'sap_object_transports'
       OR im_name = 'sap_search_source' OR im_name = 'sap_open_requests'.
      ex_yes = abap_true.
    ENDIF.

  ENDMETHOD.


  METHOD include_owner.
*&---------------------------------------------------------------------*
*& Class includes carry the class name before the '=' padding; a
*& program's own include is a program; SAPL<group> and L<group>xxx
*& belong to a function group. Anything else stays a program.
*&---------------------------------------------------------------------*

    DATA lv_inc  TYPE string.
    DATA lv_rest TYPE string.
    DATA lv_len  TYPE i.
    DATA lv_obj  TYPE sobj_name.
    DATA lv_hit  TYPE sobj_name.

    lv_inc = im_include.
    CONDENSE lv_inc.
    ex_object = 'PROG'.
    ex_name   = lv_inc.

    IF lv_inc CA '='.
      ex_object = 'CLAS'.
      SPLIT lv_inc AT '=' INTO lv_obj lv_rest.
      ex_name = lv_obj.
      RETURN.
    ENDIF.

    lv_obj = lv_inc.
    SELECT SINGLE obj_name FROM tadir INTO lv_hit
      WHERE pgmid = 'R3TR' AND object = 'PROG' AND obj_name = lv_obj.
    IF sy-subrc = 0.
      RETURN.
    ENDIF.

    IF lv_inc CP 'SAPL*'.
      ex_object = 'FUGR'.
      ex_name   = lv_inc+4.
      RETURN.
    ENDIF.

*   L<group> plus a three-character suffix: TOP, UXX, U01, F01 ...
    lv_len = strlen( lv_inc ) - 4.
    IF lv_inc(1) = 'L' AND lv_len > 0.
      lv_obj = lv_inc+1(lv_len).
      SELECT SINGLE obj_name FROM tadir INTO lv_hit
        WHERE pgmid = 'R3TR' AND object = 'FUGR' AND obj_name = lv_obj.
      IF sy-subrc = 0.
        ex_object = 'FUGR'.
        ex_name   = lv_obj.
      ENDIF.
    ENDIF.

  ENDMETHOD.


  METHOD iso_date.
*&---------------------------------------------------------------------*
*& YYYYMMDD as YYYY-MM-DD; an empty or other value unchanged.
*&---------------------------------------------------------------------*

    DATA lv_in TYPE string.

    lv_in = im_date.
    CONDENSE lv_in.
    IF strlen( lv_in ) = 8 AND lv_in CO '0123456789'.
      IF lv_in = '00000000'.
        CLEAR ex_text.
        RETURN.
      ENDIF.
      CONCATENATE lv_in(4) '-' lv_in+4(2) '-' lv_in+6(2) INTO ex_text.
    ELSE.
      ex_text = lv_in.
    ENDIF.

  ENDMETHOD.


  METHOD main_object.
*&---------------------------------------------------------------------*
*& The R3TR object a transport entry belongs to. Whole objects (R3TR)
*& and table contents (TABU) stay as they are; a part (LIMU) is traced
*& to its owner - a method to its class, a function module to its
*& function group, an include to its program or group. A part type not
*& listed here is returned unchanged.
*&---------------------------------------------------------------------*

    DATA lv_name  TYPE string.
    DATA lv_fname TYPE rs38l_fnam.
    DATA lv_pname TYPE pname.

    ex_object = im_entry-object.
    ex_name   = im_entry-obj_name.
    IF im_entry-pgmid <> 'LIMU'.
      RETURN.
    ENDIF.

    CASE im_entry-object.
      WHEN 'METH'.
*       class name in the first 30 characters, then the method
        ex_object = 'CLAS'.
        ex_name   = im_entry-obj_name(30).
      WHEN 'CPUB' OR 'CPRI' OR 'CPRO' OR 'CLSD' OR 'CPAK'.
        ex_object = 'CLAS'.
      WHEN 'FUNC'.
        lv_fname = im_entry-obj_name.
        SELECT SINGLE pname FROM tfdir INTO lv_pname WHERE funcname = lv_fname.
        IF sy-subrc = 0 AND lv_pname CP 'SAPL*'.
          ex_object = 'FUGR'.
          ex_name   = lv_pname+4.
        ENDIF.
      WHEN 'REPS' OR 'REPT' OR 'CUAD' OR 'CINC'.
        lv_name = im_entry-obj_name.
        include_owner( EXPORTING im_include = lv_name
                       IMPORTING ex_object  = ex_object
                                 ex_name    = ex_name ).
      WHEN 'DYNP'.
*       program in the first 40 characters, then the screen number
        lv_name = im_entry-obj_name(40).
        include_owner( EXPORTING im_include = lv_name
                       IMPORTING ex_object  = ex_object
                                 ex_name    = ex_name ).
      WHEN 'TABD' OR 'TABT'.
        ex_object = 'TABL'.
      WHEN 'DTED'.
        ex_object = 'DTEL'.
      WHEN 'DOMD'.
        ex_object = 'DOMA'.
      WHEN 'VIED' OR 'VIET'.
        ex_object = 'VIEW'.
      WHEN 'TTYD'.
        ex_object = 'TTYP'.
      WHEN 'SHLD'.
        ex_object = 'SHLP'.
      WHEN 'ENQD'.
        ex_object = 'ENQU'.
      WHEN 'MESS'.
*       message class in the first 20 characters, then the number
        ex_object = 'MSAG'.
        ex_name   = im_entry-obj_name(20).
    ENDCASE.

  ENDMETHOD.


  METHOD object_transports.
*&---------------------------------------------------------------------*
*& Every request that changed one custom object - as a whole or any
*& part of it (methods, includes, function modules, screens) - newest
*& first, with what it changed and where it was imported. Then, per
*& other system, how many released requests reached it and which did
*& not; the requests still open in this system; and the version
*& history (SE38 / SE24 versions) as the program's change log.
*&---------------------------------------------------------------------*

    TYPES: BEGIN OF lt_part,
             request TYPE trkorr,
             part    TYPE string,
           END OF lt_part.
    TYPES: BEGIN OF lt_reqimp,
             trkorr   TYPE trkorr,
             system   TYPE string,
             imported TYPE abap_bool,
           END OF lt_reqimp.
    TYPES: BEGIN OF lt_vrsd,
             objname TYPE versobjnam,
             versno  TYPE versno,
             korrnum TYPE verskorrno,
             author  TYPE versuser,
             datum   TYPE versdate,
           END OF lt_vrsd.

    DATA lo_in     TYPE REF TO zif_ajson.
    DATA lo_out    TYPE REF TO zcl_ajson.
    DATA lv_name   TYPE string.
    DATA lv_type   TYPE string.
    DATA lv_max    TYPE i.
    DATA lv_obj    TYPE trobj_name.
    DATA lv_c30    TYPE c LENGTH 30.
    DATA lv_c40    TYPE c LENGTH 40.
    DATA lv_like   TYPE c LENGTH 60.
    DATA lv_tadir  TYPE sobj_name.
    DATA lv_dev    TYPE devclass.
    DATA lv_pname  TYPE pname.
    DATA lv_len    TYPE i.
    DATA lv_t      TYPE trobjtype.
    DATA li_types  TYPE STANDARD TABLE OF trobjtype.
    DATA lr_types  TYPE RANGE OF trobjtype.
    DATA lw_rtype  LIKE LINE OF lr_types.
    DATA li_e071   TYPE t_e071_tab.
    DATA li_tmp    TYPE t_e071_tab.
    DATA lw_e071   TYPE t_e071.
    DATA li_fm     TYPE STANDARD TABLE OF trobj_name.
    DATA li_fname  TYPE STANDARD TABLE OF rs38l_fnam.
    DATA lv_fname  TYPE rs38l_fnam.
    DATA li_korr   TYPE t_korr_tab.
    DATA li_reqs   TYPE t_req_tab.
    DATA lw_req    TYPE t_req.
    DATA li_map    TYPE t_map_tab.
    DATA lw_map    TYPE t_map.
    DATA li_parts  TYPE STANDARD TABLE OF lt_part.
    DATA lw_part   TYPE lt_part.
    DATA li_imps   TYPE t_imp_tab.
    DATA lw_imp    TYPE t_imp.
    DATA li_reqimp TYPE STANDARD TABLE OF lt_reqimp.
    DATA lw_reqimp TYPE lt_reqimp.
    DATA li_sysl   TYPE string_table.
    DATA lv_sys    TYPE string.
    DATA li_rel    TYPE t_korr_tab.
    DATA li_open   TYPE t_korr_tab.
    DATA lv_korr   TYPE trkorr.
    DATA li_vrsd   TYPE STANDARD TABLE OF lt_vrsd.
    DATA lw_vrsd   TYPE lt_vrsd.
    DATA lv_vtype  TYPE versobjtyp.
    DATA lv_vname  TYPE versobjnam.
    DATA lv_vlike  TYPE c LENGTH 60.
    DATA lv_total  TYPE i.
    DATA lv_idx    TYPE i.
    DATA lv_ret    TYPE i.
    DATA lv_cnt    TYPE i.
    DATA lv_ok     TYPE i.
    DATA lv_pos    TYPE i.
    DATA lv_i      TYPE string.
    DATA lv_j      TYPE string.
    DATA lv_base   TYPE string.
    DATA lv_path   TYPE string.
    DATA lv_val    TYPE string.

    lo_in = zcl_ajson=>parse( im_input ).
    lv_name = lo_in->get( '/name' ).
    CONDENSE lv_name.
    TRANSLATE lv_name TO UPPER CASE.
    lv_type = lo_in->get( '/type' ).
    CONDENSE lv_type.
    TRANSLATE lv_type TO UPPER CASE.
    IF lv_name IS INITIAL OR strlen( lv_name ) > 40
       OR ( lv_name(1) <> 'Z' AND lv_name(1) <> 'Y' ).
      ex_json = error_json( im_msg = 'Refused. Give one custom object name - it must start with Z or Y.' ).
      RETURN.
    ENDIF.
    lv_max = lo_in->get_integer( '/max_results' ).
    IF lv_max <= 0.
      lv_max = c_def_requests.
    ELSEIF lv_max > c_max_requests.
      lv_max = c_max_requests.
    ENDIF.

    IF auth_ok( ) = abap_false.
      ex_json = error_json( im_msg = 'No authorization to display transport requests (S_TRANSPRT, activity 03).' ).
      RETURN.
    ENDIF.

    lv_obj   = lv_name.
    lv_tadir = lv_name.

*   ---- which object types carry this name ---------------------------
    IF lv_type IS NOT INITIAL.
      lv_t = lv_type.
      APPEND lv_t TO li_types.
    ELSE.
      SELECT object FROM tadir INTO TABLE li_types
        WHERE pgmid = 'R3TR' AND obj_name = lv_tadir.
    ENDIF.
    LOOP AT li_types INTO lv_t.
      lw_rtype-sign   = 'I'.
      lw_rtype-option = 'EQ'.
      lw_rtype-low    = lv_t.
      APPEND lw_rtype TO lr_types.
    ENDLOOP.
    IF li_types IS NOT INITIAL.
      READ TABLE li_types INTO lv_t INDEX 1.
      SELECT SINGLE devclass FROM tadir INTO lv_dev
        WHERE pgmid = 'R3TR' AND object = lv_t AND obj_name = lv_tadir.
    ENDIF.

*   ---- every object list entry that touched it ----------------------
*   the whole object
    SELECT trkorr pgmid object obj_name FROM e071 INTO TABLE li_e071
      WHERE pgmid = 'R3TR' AND obj_name = lv_obj.
    IF lr_types IS NOT INITIAL.
      DELETE li_e071 WHERE object NOT IN lr_types.
    ENDIF.

*   parts carrying the same name: program source and texts, class
*   sections, table and data element definitions ...
    SELECT trkorr pgmid object obj_name FROM e071 APPENDING TABLE li_e071
      WHERE pgmid = 'LIMU' AND obj_name = lv_obj.

*   class: methods (class name padded to 30, then the method) and
*   local includes (class name, '=' padding, suffix)
    IF lv_type IS INITIAL OR lv_type = 'CLAS'.
      lv_c30 = lv_name.
      lv_like = lv_c30.
      lv_like+30(1) = '%'.
      SELECT trkorr pgmid object obj_name FROM e071 INTO TABLE li_tmp
        WHERE pgmid = 'LIMU' AND object = 'METH' AND obj_name LIKE lv_like.
*     LIKE takes '_' as a wildcard - keep exact matches only
      LOOP AT li_tmp INTO lw_e071.
        IF lw_e071-obj_name(30) = lv_c30.
          APPEND lw_e071 TO li_e071.
        ENDIF.
      ENDLOOP.
      CLEAR li_tmp.
      CONCATENATE lv_name '=%' INTO lv_like.
      lv_len = strlen( lv_name ).
      SELECT trkorr pgmid object obj_name FROM e071 INTO TABLE li_tmp
        WHERE pgmid = 'LIMU' AND object = 'CINC' AND obj_name LIKE lv_like.
      LOOP AT li_tmp INTO lw_e071.
        IF lw_e071-obj_name(lv_len) = lv_name AND lw_e071-obj_name+lv_len(1) = '='.
          APPEND lw_e071 TO li_e071.
        ENDIF.
      ENDLOOP.
      CLEAR li_tmp.
    ENDIF.

*   function group: its function modules, its main program and its
*   includes L<group> plus a three-character suffix
    IF lv_type IS INITIAL OR lv_type = 'FUGR'.
      CONCATENATE 'SAPL' lv_name INTO lv_pname.
      SELECT funcname FROM tfdir INTO TABLE li_fname WHERE pname = lv_pname.
      LOOP AT li_fname INTO lv_fname.
        lv_obj = lv_fname.
        APPEND lv_obj TO li_fm.
      ENDLOOP.
      lv_obj = lv_pname.
      APPEND lv_obj TO li_fm.
      SELECT trkorr pgmid object obj_name FROM e071 APPENDING TABLE li_e071
        FOR ALL ENTRIES IN li_fm
        WHERE pgmid = 'LIMU' AND ( object = 'FUNC' OR object = 'REPS' )
          AND obj_name = li_fm-table_line.
      CONCATENATE 'L' lv_name '%' INTO lv_like.
      lv_len = strlen( lv_name ) + 4.
      lv_pos = strlen( lv_name ).
      SELECT trkorr pgmid object obj_name FROM e071 INTO TABLE li_tmp
        WHERE pgmid = 'LIMU' AND ( object = 'REPS' OR object = 'REPT' )
          AND obj_name LIKE lv_like.
*     LIKE takes '_' as a wildcard and ZAB% also finds ZABC - keep
*     L<group> plus exactly three characters
      LOOP AT li_tmp INTO lw_e071.
        lv_val = lw_e071-obj_name.
        IF strlen( lv_val ) = lv_len AND lv_val+1(lv_pos) = lv_name.
          APPEND lw_e071 TO li_e071.
        ENDIF.
      ENDLOOP.
      CLEAR li_tmp.
      lv_obj = lv_name.
    ENDIF.

*   program: its screens (program padded to 40, then the number)
    IF lv_type IS INITIAL OR lv_type = 'PROG'.
      lv_c40 = lv_name.
      lv_like = lv_c40.
      lv_like+40(1) = '%'.
      SELECT trkorr pgmid object obj_name FROM e071 INTO TABLE li_tmp
        WHERE pgmid = 'LIMU' AND object = 'DYNP' AND obj_name LIKE lv_like.
      LOOP AT li_tmp INTO lw_e071.
        IF lw_e071-obj_name(40) = lv_c40.
          APPEND lw_e071 TO li_e071.
        ENDIF.
      ENDLOOP.
      CLEAR li_tmp.
    ENDIF.

*   ---- entries -> requests, and what each request changed -----------
    LOOP AT li_e071 INTO lw_e071.
      APPEND lw_e071-trkorr TO li_korr.
    ENDLOOP.
    SORT li_korr.
    DELETE ADJACENT DUPLICATES FROM li_korr.
    requests_of( EXPORTING im_list = li_korr
                 IMPORTING ex_reqs = li_reqs
                           ex_map  = li_map ).

    LOOP AT li_e071 INTO lw_e071.
      READ TABLE li_map INTO lw_map WITH TABLE KEY trkorr = lw_e071-trkorr.
      IF sy-subrc <> 0.
        CONTINUE.
      ENDIF.
      lw_part-request = lw_map-request.
      CASE lw_e071-object.
        WHEN 'METH'.
          lv_val = lw_e071-obj_name+30.
          CONCATENATE 'method' lv_val INTO lw_part-part SEPARATED BY space.
        WHEN 'DYNP'.
          lv_val = lw_e071-obj_name+40.
          CONCATENATE 'screen' lv_val INTO lw_part-part SEPARATED BY space.
        WHEN OTHERS.
          lv_val = lw_e071-obj_name.
          CONCATENATE lw_e071-pgmid lw_e071-object lv_val INTO lw_part-part SEPARATED BY space.
      ENDCASE.
      APPEND lw_part TO li_parts.
    ENDLOOP.
    SORT li_parts BY request part.
    DELETE ADJACENT DUPLICATES FROM li_parts COMPARING request part.

    SORT li_reqs BY as4date DESCENDING as4time DESCENDING trkorr DESCENDING.
    DESCRIBE TABLE li_reqs LINES lv_total.

    lo_out = zcl_ajson=>create_empty( ).
    lo_out->set( iv_path = '/object' iv_val = lv_name ).
    IF li_types IS NOT INITIAL.
      lo_out->touch_array( '/types' ).
      LOOP AT li_types INTO lv_t.
        lv_i = sy-tabix.
        CONDENSE lv_i.
        CONCATENATE '/types/' lv_i INTO lv_path.
        lv_val = lv_t.
        lo_out->set( iv_path = lv_path iv_val = lv_val ).
      ENDLOOP.
    ELSE.
      lo_out->set( iv_path = '/note_object'
                   iv_val  = 'Not in the object directory of this system (deleted, or never created here). Its transport history is still shown.' ).
    ENDIF.
    IF lv_dev IS NOT INITIAL.
      lv_val = lv_dev.
      lo_out->set( iv_path = '/package' iv_val = lv_val ).
    ENDIF.
    lv_val = sy-sysid.
    lo_out->set( iv_path = '/system' iv_val = lv_val ).
    lo_out->set_integer( iv_path = '/count' iv_val = lv_total ).
    lo_out->touch_array( '/requests' ).

    LOOP AT li_reqs INTO lw_req.
      lv_idx = sy-tabix.
      IF lv_idx > lv_max.
        EXIT.
      ENDIF.
      lv_ret = lv_idx.
      lv_i = lv_idx.
      CONDENSE lv_i.
      CONCATENATE '/requests/' lv_i INTO lv_base.

      IF lv_idx <= c_max_imports.
        add_request( EXPORTING im_out     = lo_out
                               im_base    = lv_base
                               im_req     = lw_req
                               im_imports = abap_true
                     IMPORTING ex_imports = li_imps ).
      ELSE.
        add_request( EXPORTING im_out     = lo_out
                               im_base    = lv_base
                               im_req     = lw_req
                               im_imports = abap_false
                     IMPORTING ex_imports = li_imps ).
      ENDIF.

*     what this request changed
      CONCATENATE lv_base '/changed_parts' INTO lv_path.
      lo_out->touch_array( lv_path ).
      lv_cnt = 0.
      LOOP AT li_parts INTO lw_part WHERE request = lw_req-trkorr.
        lv_cnt = lv_cnt + 1.
        IF lv_cnt > c_max_parts.
          EXIT.
        ENDIF.
        lv_j = lv_cnt.
        CONDENSE lv_j.
        CONCATENATE lv_base '/changed_parts/' lv_j INTO lv_path.
        lo_out->set( iv_path = lv_path iv_val = lw_part-part ).
      ENDLOOP.

*     for the landscape summary below
      IF lw_req-trstatus = 'R' OR lw_req-trstatus = 'N'.
        IF lv_idx <= c_max_imports.
          APPEND lw_req-trkorr TO li_rel.
          LOOP AT li_imps INTO lw_imp.
            lw_reqimp-trkorr   = lw_req-trkorr.
            lw_reqimp-system   = lw_imp-system.
            lw_reqimp-imported = lw_imp-imported.
            APPEND lw_reqimp TO li_reqimp.
            APPEND lw_imp-system TO li_sysl.
          ENDLOOP.
        ENDIF.
      ELSE.
        APPEND lw_req-trkorr TO li_open.
      ENDIF.
    ENDLOOP.
    lo_out->set_integer( iv_path = '/returned' iv_val = lv_ret ).

*   ---- landscape: per other system, released requests imported or not
    SORT li_sysl.
    DELETE ADJACENT DUPLICATES FROM li_sysl.
    lo_out->touch_array( '/landscape' ).
    LOOP AT li_sysl INTO lv_sys.
      lv_i = sy-tabix.
      CONDENSE lv_i.
      CONCATENATE '/landscape/' lv_i INTO lv_base.
      CONCATENATE lv_base '/system' INTO lv_path.
      lo_out->set( iv_path = lv_path iv_val = lv_sys ).
      lv_val = system_text( lv_sys ).
      IF lv_val IS NOT INITIAL.
        CONCATENATE lv_base '/description' INTO lv_path.
        lo_out->set( iv_path = lv_path iv_val = lv_val ).
      ENDIF.
      lv_ok  = 0.
      lv_cnt = 0.
      CONCATENATE lv_base '/not_imported' INTO lv_path.
      lo_out->touch_array( lv_path ).
      LOOP AT li_rel INTO lv_korr.
        READ TABLE li_reqimp INTO lw_reqimp
          WITH KEY trkorr = lv_korr system = lv_sys imported = abap_true.
        IF sy-subrc = 0.
          lv_ok = lv_ok + 1.
        ELSE.
          lv_cnt = lv_cnt + 1.
          IF lv_cnt <= 10.
            lv_j = lv_cnt.
            CONDENSE lv_j.
            CONCATENATE lv_base '/not_imported/' lv_j INTO lv_path.
            lv_val = lv_korr.
            lo_out->set( iv_path = lv_path iv_val = lv_val ).
          ENDIF.
        ENDIF.
      ENDLOOP.
      CONCATENATE lv_base '/released_requests' INTO lv_path.
      lv_pos = lines( li_rel ).
      lo_out->set_integer( iv_path = lv_path iv_val = lv_pos ).
      CONCATENATE lv_base '/imported' INTO lv_path.
      lo_out->set_integer( iv_path = lv_path iv_val = lv_ok ).
    ENDLOOP.

    lo_out->touch_array( '/open_requests' ).
    LOOP AT li_open INTO lv_korr.
      lv_i = sy-tabix.
      CONDENSE lv_i.
      CONCATENATE '/open_requests/' lv_i INTO lv_path.
      lv_val = lv_korr.
      lo_out->set( iv_path = lv_path iv_val = lv_val ).
    ENDLOOP.

*   ---- version history: the program's change log --------------------
    CLEAR lv_vtype.
    lv_vname = lv_name.
    IF lv_type IS INITIAL.
      READ TABLE li_types INTO lv_t INDEX 1.
    ELSE.
      lv_t = lv_type.
    ENDIF.
    CASE lv_t.
      WHEN 'PROG'.
        lv_vtype = 'REPS'.
      WHEN 'TABL'.
        lv_vtype = 'TABD'.
      WHEN 'DTEL'.
        lv_vtype = 'DTED'.
      WHEN 'DOMA'.
        lv_vtype = 'DOMD'.
      WHEN 'CLAS'.
        lv_vtype = 'METH'.
    ENDCASE.
    IF lv_vtype = 'METH'.
      lv_c30 = lv_name.
      lv_vlike = lv_c30.
      lv_vlike+30(1) = '%'.
      SELECT objname versno korrnum author datum FROM vrsd INTO TABLE li_vrsd
        WHERE objtype = lv_vtype AND objname LIKE lv_vlike.
      LOOP AT li_vrsd INTO lw_vrsd.
        lv_pos = sy-tabix.
        IF lw_vrsd-objname(30) <> lv_c30.
          DELETE li_vrsd INDEX lv_pos.
        ENDIF.
      ENDLOOP.
    ELSEIF lv_vtype IS NOT INITIAL.
      SELECT objname versno korrnum author datum FROM vrsd INTO TABLE li_vrsd
        WHERE objtype = lv_vtype AND objname = lv_vname.
    ENDIF.

    IF lv_vtype IS NOT INITIAL.
      SORT li_vrsd BY datum DESCENDING versno DESCENDING.
      DESCRIBE TABLE li_vrsd LINES lv_cnt.
      lo_out->set_integer( iv_path = '/version_count' iv_val = lv_cnt ).
      lo_out->touch_array( '/versions' ).
      LOOP AT li_vrsd INTO lw_vrsd.
        lv_pos = sy-tabix.
        IF lv_pos > c_max_versions.
          EXIT.
        ENDIF.
        lv_i = lv_pos.
        CONDENSE lv_i.
        CONCATENATE '/versions/' lv_i INTO lv_base.
        IF lv_vtype = 'METH'.
          CONCATENATE lv_base '/method' INTO lv_path.
          lv_val = lw_vrsd-objname+30.
          lo_out->set( iv_path = lv_path iv_val = lv_val ).
        ENDIF.
        CONCATENATE lv_base '/version' INTO lv_path.
        lv_val = lw_vrsd-versno.
        SHIFT lv_val LEFT DELETING LEADING '0'.
*       version 0 is the version directory's entry for the active one
        IF lv_val IS INITIAL.
          lv_val = 'active'.
        ENDIF.
        lo_out->set( iv_path = lv_path iv_val = lv_val ).
        CONCATENATE lv_base '/request' INTO lv_path.
        lv_val = lw_vrsd-korrnum.
        lo_out->set( iv_path = lv_path iv_val = lv_val ).
        CONCATENATE lv_base '/author' INTO lv_path.
        lv_val = lw_vrsd-author.
        lo_out->set( iv_path = lv_path iv_val = lv_val ).
        CONCATENATE lv_base '/date' INTO lv_path.
        lv_val = iso_date( lw_vrsd-datum ).
        lo_out->set( iv_path = lv_path iv_val = lv_val ).
      ENDLOOP.
    ENDIF.

    IF lv_total = 0.
      lo_out->set( iv_path = '/note'
                   iv_val  = 'No transport request contains this object. It was never transported (local, or created before the transport history was kept).' ).
    ELSEIF lv_total > lv_ret.
      lo_out->set( iv_path = '/note'
                   iv_val  = 'More requests than were returned. Raise max_results (at most 100). The landscape summary covers the returned released requests only.' ).
    ENDIF.

    ex_json = lo_out->stringify( ).

  ENDMETHOD.


  METHOD open_requests.
*&---------------------------------------------------------------------*
*& The work in progress a reviewer needs: for one SAP user, every
*& request that is still open and holds their work (requests they own,
*& or requests with a task of theirs); or one request by number. Per
*& request its tasks and every object changed, each with the parts that
*& changed (methods, includes, function modules, screens), so a review
*& can read exactly those routines. With an owner, only that person's
*& changes are listed. Customizing entries are counted, not reviewed.
*& Per custom object (at most c_dep_objects per answer) the release-
*& order dependencies - see ADD_DEPENDENCIES - and, at the top, their
*& count and the other users involved, to copy in a review mail.
*&---------------------------------------------------------------------*

    TYPES: BEGIN OF lt_objpart,
             object   TYPE trobjtype,
             obj_name TYPE trobj_name,
             part     TYPE string,
           END OF lt_objpart.

    DATA lo_in     TYPE REF TO zif_ajson.
    DATA lo_out    TYPE REF TO zcl_ajson.
    DATA lv_owner  TYPE string.
    DATA lv_req_in TYPE string.
    DATA lv_user   TYPE tr_as4user.
    DATA lv_korr   TYPE trkorr.
    DATA lv_max    TYPE i.
    DATA li_own    TYPE t_req_tab.
    DATA lw_own    TYPE t_req.
    DATA li_korr   TYPE t_korr_tab.
    DATA li_reqs   TYPE t_req_tab.
    DATA lw_req    TYPE t_req.
    DATA li_map    TYPE t_map_tab.
    DATA li_task   TYPE t_req_tab.
    DATA lw_task   TYPE t_req.
    DATA li_src    TYPE t_korr_tab.
    DATA li_e071   TYPE t_e071_tab.
    DATA lw_e071   TYPE t_e071.
    DATA li_parts  TYPE STANDARD TABLE OF lt_objpart.
    DATA lw_part   TYPE lt_objpart.
    DATA lw_prev   TYPE lt_objpart.
    DATA li_cust   TYPE string_table.
    DATA lv_imps   TYPE t_imp_tab.
    DATA lv_total  TYPE i.
    DATA lv_idx    TYPE i.
    DATA lv_ret    TYPE i.
    DATA lv_ocnt   TYPE i.
    DATA lv_pcnt   TYPE i.
    DATA lv_i      TYPE string.
    DATA lv_j      TYPE string.
    DATA lv_k      TYPE string.
    DATA lv_base   TYPE string.
    DATA lv_obase  TYPE string.
    DATA lv_path   TYPE string.
    DATA lv_val    TYPE string.
    DATA lv_custom TYPE abap_bool.
    DATA li_all    TYPE t_korr_tab.
    DATA li_alle   TYPE t_e071_tab.
    DATA li_tobj   TYPE t_tobj_tab.
    DATA lw_tobj   TYPE t_tobj.
    DATA li_shared TYPE t_tobj_tab.
    DATA li_downs  TYPE string_table.
    DATA lv_dcnt   TYPE i.
    DATA lv_dchk   TYPE i.
    DATA lv_dskip  TYPE i.
    DATA lv_nown   TYPE i.
    DATA lv_dmax   TYPE i.

    lo_in = zcl_ajson=>parse( im_input ).
    lv_owner = lo_in->get( '/owner' ).
    lv_req_in = lo_in->get( '/request' ).
    CONDENSE: lv_owner NO-GAPS, lv_req_in NO-GAPS.
    TRANSLATE: lv_owner TO UPPER CASE, lv_req_in TO UPPER CASE.
    IF lv_owner IS INITIAL AND lv_req_in IS INITIAL.
      ex_json = error_json( im_msg = 'Give owner (an SAP user, e.g. DEVELOPER1) or request (e.g. DEVK900123).' ).
      RETURN.
    ENDIF.
    lv_max = lo_in->get_integer( '/max_results' ).
    IF lv_max <= 0.
      lv_max = c_def_requests.
    ELSEIF lv_max > c_max_requests.
      lv_max = c_max_requests.
    ENDIF.

    IF auth_ok( ) = abap_false.
      ex_json = error_json( im_msg = 'No authorization to display transport requests (S_TRANSPRT, activity 03).' ).
      RETURN.
    ENDIF.

*   whose work: one's own needs Z_AI_SCOPE OWN, anyone else's ANY
*   (ZCL_AI_AUTH, 23.10.2026). A request by number: see below.
    IF lv_req_in IS INITIAL AND zcl_ai_auth=>check_owner( lv_owner ) = abap_false.
      lv_val = zcl_ai_auth=>last_reason( ).
      ex_json = error_json( im_msg = lv_val ).
      RETURN.
    ENDIF.

*   ---- the requests in scope ----------------------------------------
    IF lv_req_in IS NOT INITIAL.
*     one request by number - a task number counts as its request
      lv_korr = lv_req_in.
      APPEND lv_korr TO li_korr.
      requests_of( EXPORTING im_list = li_korr
                   IMPORTING ex_reqs = li_reqs
                             ex_map  = li_map ).
      IF li_reqs IS INITIAL.
        CONCATENATE 'Request' lv_req_in 'does not exist in this system.' INTO lv_val SEPARATED BY space.
        ex_json = error_json( im_msg = lv_val ).
        RETURN.
      ENDIF.
*     the request's owner decides whose work it is (Z_AI_SCOPE)
      LOOP AT li_reqs INTO lw_req.
        IF zcl_ai_auth=>check_owner( lw_req-as4user ) = abap_false.
          lv_val = zcl_ai_auth=>last_reason( ).
          ex_json = error_json( im_msg = lv_val ).
          RETURN.
        ENDIF.
      ENDLOOP.
    ELSE.
*     open requests and tasks of this user (modifiable, or protected)
      lv_user = lv_owner.
      SELECT trkorr trfunction trstatus as4user as4date as4time strkorr
        FROM e070 INTO TABLE li_own
        WHERE as4user = lv_user
          AND ( trstatus = 'D' OR trstatus = 'L' ).
      LOOP AT li_own INTO lw_own.
        IF lw_own-strkorr IS INITIAL.
          APPEND lw_own-trkorr TO li_korr.
        ELSE.
          APPEND lw_own-strkorr TO li_korr.
        ENDIF.
      ENDLOOP.
      SORT li_korr.
      DELETE ADJACENT DUPLICATES FROM li_korr.
      requests_of( EXPORTING im_list = li_korr
                   IMPORTING ex_reqs = li_reqs
                             ex_map  = li_map ).
*     a released request has nothing left to review
      DELETE li_reqs WHERE trstatus <> 'D' AND trstatus <> 'L'.
    ENDIF.
    SORT li_reqs BY as4date DESCENDING as4time DESCENDING trkorr DESCENDING.
    DESCRIBE TABLE li_reqs LINES lv_total.

*   one request is checked in full, a whole owner up to c_dep_objects
    IF lv_req_in IS NOT INITIAL.
      lv_dmax = c_req_objects.
    ELSE.
      lv_dmax = c_dep_objects.
    ENDIF.

    lo_out = zcl_ajson=>create_empty( ).
    IF lv_owner IS NOT INITIAL.
      lo_out->set( iv_path = '/owner' iv_val = lv_owner ).
    ENDIF.
    lv_val = sy-sysid.
    lo_out->set( iv_path = '/system' iv_val = lv_val ).
    lo_out->set_integer( iv_path = '/count' iv_val = lv_total ).
    lo_out->touch_array( '/requests' ).

    LOOP AT li_reqs INTO lw_req.
      lv_idx = sy-tabix.
      IF lv_idx > lv_max.
        EXIT.
      ENDIF.
      lv_ret = lv_idx.
      lv_i = lv_idx.
      CONDENSE lv_i.
      CONCATENATE '/requests/' lv_i INTO lv_base.
      add_request( EXPORTING im_out     = lo_out
                             im_base    = lv_base
                             im_req     = lw_req
                             im_imports = abap_false
                   IMPORTING ex_imports = lv_imps ).

*     tasks of the request; with an owner, only theirs carry the changes
      CLEAR: li_task, li_src.
      SELECT trkorr trfunction trstatus as4user as4date as4time strkorr
        FROM e070 INTO TABLE li_task
        WHERE strkorr = lw_req-trkorr.
      CONCATENATE lv_base '/tasks' INTO lv_path.
      lo_out->touch_array( lv_path ).
      LOOP AT li_task INTO lw_task.
        lv_j = sy-tabix.
        CONDENSE lv_j.
        CONCATENATE lv_base '/tasks/' lv_j INTO lv_obase.
        CONCATENATE lv_obase '/task' INTO lv_path.
        lv_val = lw_task-trkorr.
        lo_out->set( iv_path = lv_path iv_val = lv_val ).
        CONCATENATE lv_obase '/owner' INTO lv_path.
        lv_val = lw_task-as4user.
        lo_out->set( iv_path = lv_path iv_val = lv_val ).
        CONCATENATE lv_obase '/status' INTO lv_path.
        lv_val = status_text( lw_task-trstatus ).
        lo_out->set( iv_path = lv_path iv_val = lv_val ).
        IF lv_owner IS INITIAL OR lw_task-as4user = lv_user.
          APPEND lw_task-trkorr TO li_src.
        ENDIF.
      ENDLOOP.
      IF lv_owner IS INITIAL OR lw_req-as4user = lv_user.
        APPEND lw_req-trkorr TO li_src.
      ENDIF.

*     who changed which object in this request, over all tasks
      CLEAR: li_all, li_alle, li_tobj.
      APPEND lw_req-trkorr TO li_all.
      LOOP AT li_task INTO lw_task.
        APPEND lw_task-trkorr TO li_all.
      ENDLOOP.
      SELECT trkorr pgmid object obj_name FROM e071 INTO TABLE li_alle
        FOR ALL ENTRIES IN li_all
        WHERE trkorr = li_all-table_line.
      LOOP AT li_alle INTO lw_e071.
        IF lw_e071-pgmid = 'CORR'.
          CONTINUE.
        ENDIF.
        CLEAR lw_tobj.
        main_object( EXPORTING im_entry  = lw_e071
                     IMPORTING ex_object = lw_tobj-object
                               ex_name   = lw_tobj-obj_name ).
        lw_tobj-task = lw_e071-trkorr.
        lw_tobj-owner = lw_req-as4user.
        READ TABLE li_task INTO lw_task WITH KEY trkorr = lw_e071-trkorr.
        IF sy-subrc = 0.
          lw_tobj-owner = lw_task-as4user.
        ENDIF.
        APPEND lw_tobj TO li_tobj.
      ENDLOOP.
      SORT li_tobj BY object obj_name owner task.
      DELETE ADJACENT DUPLICATES FROM li_tobj COMPARING object obj_name owner.

*     what changed, per object
      CLEAR: li_e071, li_parts, li_cust.
      IF li_src IS NOT INITIAL.
        SELECT trkorr pgmid object obj_name FROM e071 INTO TABLE li_e071
          FOR ALL ENTRIES IN li_src
          WHERE trkorr = li_src-table_line.
      ENDIF.
      LOOP AT li_e071 INTO lw_e071.
        IF lw_e071-pgmid = 'CORR'.
          CONTINUE.
        ENDIF.
        CLEAR lw_part.
        main_object( EXPORTING im_entry  = lw_e071
                     IMPORTING ex_object = lw_part-object
                               ex_name   = lw_part-obj_name ).
*       table contents and customizing views: counted, not reviewed
        IF lw_e071-object = 'TABU' OR lw_e071-object = 'CDAT' OR lw_e071-object = 'VDAT'
           OR lw_e071-object = 'TDAT'.
          CONCATENATE lw_e071-object lw_part-obj_name INTO lv_val SEPARATED BY space.
          APPEND lv_val TO li_cust.
          CONTINUE.
        ENDIF.
        CASE lw_e071-object.
          WHEN 'METH'.
            lv_val = lw_e071-obj_name+30.
            CONCATENATE 'method' lv_val INTO lw_part-part SEPARATED BY space.
          WHEN 'DYNP'.
            lv_val = lw_e071-obj_name+40.
            CONCATENATE 'screen' lv_val INTO lw_part-part SEPARATED BY space.
          WHEN 'FUNC'.
            lv_val = lw_e071-obj_name.
            CONCATENATE 'function' lv_val INTO lw_part-part SEPARATED BY space.
          WHEN 'REPS' OR 'CINC'.
            lv_val = lw_e071-obj_name.
            CONCATENATE 'include' lv_val INTO lw_part-part SEPARATED BY space.
          WHEN OTHERS.
            IF lw_e071-pgmid = 'R3TR'.
              lw_part-part = 'whole object'.
            ELSE.
              lv_val = lw_e071-obj_name.
              CONCATENATE lw_e071-object lv_val INTO lw_part-part SEPARATED BY space.
            ENDIF.
        ENDCASE.
        APPEND lw_part TO li_parts.
      ENDLOOP.
      SORT li_parts BY object obj_name part.
      DELETE ADJACENT DUPLICATES FROM li_parts COMPARING object obj_name part.
      SORT li_cust.
      DELETE ADJACENT DUPLICATES FROM li_cust.

      CONCATENATE lv_base '/objects' INTO lv_path.
      lo_out->touch_array( lv_path ).
      lv_ocnt = 0.
      CLEAR lw_prev.
      LOOP AT li_parts INTO lw_part.
        IF lw_part-object <> lw_prev-object OR lw_part-obj_name <> lw_prev-obj_name.
          lv_ocnt = lv_ocnt + 1.
          lv_pcnt = 0.
          lv_k = lv_ocnt.
          CONDENSE lv_k.
          CONCATENATE lv_base '/objects/' lv_k INTO lv_obase.
          CONCATENATE lv_obase '/object' INTO lv_path.
          CONCATENATE lw_part-object lw_part-obj_name INTO lv_val SEPARATED BY space.
          lo_out->set( iv_path = lv_path iv_val = lv_val ).
          lv_custom = abap_false.
          IF lw_part-obj_name(1) = 'Z' OR lw_part-obj_name(1) = 'Y'.
            lv_custom = abap_true.
          ENDIF.
          CONCATENATE lv_obase '/custom' INTO lv_path.
          lo_out->set_boolean( iv_path = lv_path iv_val = lv_custom ).
          CONCATENATE lv_obase '/changed_parts' INTO lv_path.
          lo_out->touch_array( lv_path ).
          lw_prev = lw_part.

*         release order: other users in this request, other requests
          IF lv_custom = abap_true.
            IF lv_dchk >= lv_dmax.
              lv_dskip = lv_dskip + 1.
            ELSE.
              lv_dchk = lv_dchk + 1.
              CLEAR: li_shared, lv_nown.
              LOOP AT li_tobj INTO lw_tobj
                   WHERE object = lw_part-object AND obj_name = lw_part-obj_name.
                lv_nown = lv_nown + 1.
                IF lv_owner IS INITIAL OR lw_tobj-owner <> lv_user.
                  APPEND lw_tobj TO li_shared.
                ENDIF.
              ENDLOOP.
*             without an owner, one person's object is not shared
              IF lv_owner IS INITIAL AND lv_nown < 2.
                CLEAR li_shared.
              ENDIF.
              add_dependencies( EXPORTING im_out     = lo_out
                                          im_base    = lv_obase
                                          im_object  = lw_part-object
                                          im_name    = lw_part-obj_name
                                          im_request = lw_req-trkorr
                                          im_shared  = li_shared
                                CHANGING  ch_owners  = li_downs
                                          ch_count   = lv_dcnt ).
            ENDIF.
          ENDIF.
        ENDIF.
        lv_pcnt = lv_pcnt + 1.
        IF lv_pcnt > c_max_parts.
          CONTINUE.
        ENDIF.
        lv_j = lv_pcnt.
        CONDENSE lv_j.
        CONCATENATE lv_obase '/changed_parts/' lv_j INTO lv_path.
        lo_out->set( iv_path = lv_path iv_val = lw_part-part ).
      ENDLOOP.
      CONCATENATE lv_base '/object_count' INTO lv_path.
      lo_out->set_integer( iv_path = lv_path iv_val = lv_ocnt ).

      DESCRIBE TABLE li_cust LINES lv_pcnt.
      CONCATENATE lv_base '/customizing_entries' INTO lv_path.
      lo_out->set_integer( iv_path = lv_path iv_val = lv_pcnt ).
    ENDLOOP.
    lo_out->set_integer( iv_path = '/returned' iv_val = lv_ret ).

*   release-order warnings over all objects; the other users, to copy
    IF lv_owner IS NOT INITIAL.
      DELETE li_downs WHERE table_line = lv_owner.
    ENDIF.
    SORT li_downs.
    DELETE ADJACENT DUPLICATES FROM li_downs.
    lo_out->set_integer( iv_path = '/dependency_count' iv_val = lv_dcnt ).
    lo_out->touch_array( '/dependency_owners' ).
    LOOP AT li_downs INTO lv_val.
      lv_i = sy-tabix.
      CONDENSE lv_i.
      CONCATENATE '/dependency_owners/' lv_i INTO lv_path.
      lo_out->set( iv_path = lv_path iv_val = lv_val ).
    ENDLOOP.
    IF lv_dskip > 0.
      lv_i = lv_dskip.
      CONDENSE lv_i.
      lv_j = lv_dmax.
      CONDENSE lv_j.
      CONCATENATE 'Dependencies were checked for the first' lv_j 'custom objects only;' lv_i
                  'more were not checked - ask for one request to check them.'
        INTO lv_val SEPARATED BY space.
      lo_out->set( iv_path = '/dependency_note' iv_val = lv_val ).
    ENDIF.

    IF lv_total = 0.
      lo_out->set( iv_path = '/note'
                   iv_val  = 'No open request holds work of this user. Released requests are not listed - use sap_object_transports for history.' ).
    ELSEIF lv_total > lv_ret.
      lo_out->set( iv_path = '/note'
                   iv_val  = 'More open requests than were returned. Raise max_results (at most 100).' ).
    ELSE.
      CONCATENATE `Review the custom objects: read each changed part with sap_get_source (routine = the method or FORM; name = the include). `
                  `Customizing entries are counted only. dependencies per object are release-order warnings, never findings.`
        INTO lv_val.
      lo_out->set( iv_path = '/note' iv_val = lv_val ).
    ENDIF.

    ex_json = lo_out->stringify( ).

  ENDMETHOD.


  METHOD read_imports.
*&---------------------------------------------------------------------*
*& Where a request went, from its transport log: for every other
*& system, whether its import step ran (I main import, H dictionary
*& import), the last date anything happened there and the highest
*& return code. The export date comes from this system's E step.
*&
*& The log structure (type group CTSLG) is created and read by name,
*& so a layout this code does not know gives a note, not a dump.
*&---------------------------------------------------------------------*

    DATA lr_cofile TYPE REF TO data.
    DATA lx_root   TYPE REF TO cx_root.
    DATA lv_kind   TYPE c LENGTH 1.
    DATA lv_sys    TYPE string.
    DATA lv_step   TYPE string.
    DATA lv_date   TYPE string.
    DATA lv_rc     TYPE string.
    DATA lv_rc_i   TYPE i.
    DATA lw_imp    TYPE t_imp.

    FIELD-SYMBOLS <lf_cofile>  TYPE any.
    FIELD-SYMBOLS <lf_comp>    TYPE any.
    FIELD-SYMBOLS <lf_systems> TYPE ANY TABLE.
    FIELD-SYMBOLS <lf_sys>     TYPE any.
    FIELD-SYMBOLS <lf_steps>   TYPE ANY TABLE.
    FIELD-SYMBOLS <lf_step>    TYPE any.
    FIELD-SYMBOLS <lf_actions> TYPE ANY TABLE.
    FIELD-SYMBOLS <lf_act>     TYPE any.

    CLEAR: ex_list, ex_export, ex_note.

    TRY.
        CREATE DATA lr_cofile TYPE (c_cofile_type).
      CATCH cx_sy_create_data_error INTO lx_root.
        ex_note = 'Import history is not available in this system (transport log type CTSLG_COFILE not found).'.
        RETURN.
    ENDTRY.
    ASSIGN lr_cofile->* TO <lf_cofile>.

    TRY.
        CALL FUNCTION 'TR_READ_GLOBAL_INFO_OF_REQUEST'
          EXPORTING
            iv_trkorr = im_trkorr
          IMPORTING
            es_cofile = <lf_cofile>
          EXCEPTIONS
            OTHERS    = 1.
      CATCH cx_root INTO lx_root.
        ex_note = lx_root->get_text( ).
        CONCATENATE 'Import history could not be read:' ex_note INTO ex_note SEPARATED BY space.
        RETURN.
    ENDTRY.
    IF sy-subrc <> 0.
      ex_note = 'No transport log was found for this request.'.
      RETURN.
    ENDIF.

    CLEAR lv_kind.
    ASSIGN COMPONENT 'SYSTEMS' OF STRUCTURE <lf_cofile> TO <lf_comp>.
    IF sy-subrc = 0.
      DESCRIBE FIELD <lf_comp> TYPE lv_kind.
    ENDIF.
    IF lv_kind <> 'h'.
      ex_note = 'Import history has a layout this tool does not know (no SYSTEMS table).'.
      RETURN.
    ENDIF.
    ASSIGN <lf_comp> TO <lf_systems>.

    LOOP AT <lf_systems> ASSIGNING <lf_sys>.
      ASSIGN COMPONENT 'SYSTEMID' OF STRUCTURE <lf_sys> TO <lf_comp>.
      IF sy-subrc <> 0.
        CONTINUE.
      ENDIF.
      lv_sys = <lf_comp>.
      CONDENSE lv_sys.
      CLEAR lw_imp.
      lw_imp-system = lv_sys.

      CLEAR lv_kind.
      ASSIGN COMPONENT 'STEPS' OF STRUCTURE <lf_sys> TO <lf_comp>.
      IF sy-subrc = 0.
        DESCRIBE FIELD <lf_comp> TYPE lv_kind.
      ENDIF.
      IF lv_kind = 'h'.
        ASSIGN <lf_comp> TO <lf_steps>.
        LOOP AT <lf_steps> ASSIGNING <lf_step>.
          ASSIGN COMPONENT 'STEPID' OF STRUCTURE <lf_step> TO <lf_comp>.
          IF sy-subrc <> 0.
            CONTINUE.
          ENDIF.
          lv_step = <lf_comp>.
          CLEAR lv_kind.
          ASSIGN COMPONENT 'ACTIONS' OF STRUCTURE <lf_step> TO <lf_comp>.
          IF sy-subrc = 0.
            DESCRIBE FIELD <lf_comp> TYPE lv_kind.
          ENDIF.
          IF lv_kind <> 'h'.
            CONTINUE.
          ENDIF.
          ASSIGN <lf_comp> TO <lf_actions>.

          LOOP AT <lf_actions> ASSIGNING <lf_act>.
            CLEAR: lv_date, lv_rc.
            ASSIGN COMPONENT 'DATE' OF STRUCTURE <lf_act> TO <lf_comp>.
            IF sy-subrc = 0.
              lv_date = <lf_comp>.
            ENDIF.
            ASSIGN COMPONENT 'RC' OF STRUCTURE <lf_act> TO <lf_comp>.
            IF sy-subrc = 0.
              lv_rc = <lf_comp>.
              CONDENSE lv_rc.
            ENDIF.

*           this system: only the export date matters
            IF lv_sys = sy-sysid.
              IF lv_step = 'E' AND lv_date > ex_export.
                ex_export = lv_date.
              ENDIF.
              CONTINUE.
            ENDIF.

            IF lv_step = 'I' OR lv_step = 'H'.
              lw_imp-imported = abap_true.
            ENDIF.
            IF lv_date > lw_imp-date.
              lw_imp-date = lv_date.
            ENDIF.
            IF lv_rc IS NOT INITIAL AND lv_rc CO '0123456789'.
              lv_rc_i = lv_rc.
              IF lv_rc_i > lw_imp-rc.
                lw_imp-rc = lv_rc_i.
              ENDIF.
            ENDIF.
          ENDLOOP.
        ENDLOOP.
      ENDIF.

      IF lv_sys <> sy-sysid.
        APPEND lw_imp TO ex_list.
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD request_objects.
*&---------------------------------------------------------------------*
*& Every object of a request and of its tasks, each named once at the
*& level a developer knows it (PROG, CLAS, FUGR, TABL ...), not by the
*& method or include that was actually changed.
*&---------------------------------------------------------------------*

    DATA li_korr TYPE t_korr_tab.
    DATA li_e071 TYPE t_e071_tab.
    DATA lw_e071 TYPE t_e071.
    DATA lw_obj  TYPE t_obj.

    SELECT trkorr FROM e070 INTO TABLE li_korr WHERE strkorr = im_trkorr.
    APPEND im_trkorr TO li_korr.

    SELECT trkorr pgmid object obj_name FROM e071 INTO TABLE li_e071
      FOR ALL ENTRIES IN li_korr
      WHERE trkorr = li_korr-table_line.

    LOOP AT li_e071 INTO lw_e071.
*     comment lines and relocation markers are not objects
      IF lw_e071-pgmid = 'CORR'.
        CONTINUE.
      ENDIF.
      CLEAR lw_obj.
      main_object( EXPORTING im_entry  = lw_e071
                   IMPORTING ex_object = lw_obj-object
                             ex_name   = lw_obj-obj_name ).
      IF lw_obj-obj_name IS NOT INITIAL.
        APPEND lw_obj TO ex_list.
      ENDIF.
    ENDLOOP.
    SORT ex_list BY object obj_name.
    DELETE ADJACENT DUPLICATES FROM ex_list COMPARING object obj_name.

  ENDMETHOD.


  METHOD request_text.
*&---------------------------------------------------------------------*
*& Description of a request: logon language, else English, else any.
*&---------------------------------------------------------------------*

    DATA lv_text  TYPE as4text.
    DATA li_texts TYPE STANDARD TABLE OF as4text.

    SELECT SINGLE as4text FROM e07t INTO lv_text
      WHERE trkorr = im_trkorr AND langu = sy-langu.
    IF sy-subrc <> 0.
      SELECT SINGLE as4text FROM e07t INTO lv_text
        WHERE trkorr = im_trkorr AND langu = 'E'.
    ENDIF.
    IF sy-subrc <> 0.
      SELECT as4text FROM e07t INTO TABLE li_texts UP TO 1 ROWS
        WHERE trkorr = im_trkorr.
      READ TABLE li_texts INTO lv_text INDEX 1.
    ENDIF.
    ex_text = lv_text.

  ENDMETHOD.


  METHOD requests_of.
*&---------------------------------------------------------------------*
*& A task counts as its request: a project is moved by requests, and a
*& task's text often repeats the request's. Tasks whose request no
*& longer exists are dropped.
*&---------------------------------------------------------------------*

    DATA li_e070 TYPE t_req_tab.
    DATA lw_e070 TYPE t_req.
    DATA lw_map  TYPE t_map.
    DATA li_req  TYPE t_korr_tab.

    CLEAR: ex_reqs, ex_map.
    IF im_list IS INITIAL.
      RETURN.
    ENDIF.

    SELECT trkorr trfunction trstatus as4user as4date as4time strkorr
      FROM e070 INTO TABLE li_e070
      FOR ALL ENTRIES IN im_list
      WHERE trkorr = im_list-table_line.

    LOOP AT li_e070 INTO lw_e070.
      lw_map-trkorr = lw_e070-trkorr.
      IF lw_e070-strkorr IS INITIAL.
        lw_map-request = lw_e070-trkorr.
      ELSE.
        lw_map-request = lw_e070-strkorr.
      ENDIF.
      INSERT lw_map INTO TABLE ex_map.
      APPEND lw_map-request TO li_req.
    ENDLOOP.
    SORT li_req.
    DELETE ADJACENT DUPLICATES FROM li_req.
    IF li_req IS INITIAL.
      RETURN.
    ENDIF.

    SELECT trkorr trfunction trstatus as4user as4date as4time strkorr
      FROM e070 INTO TABLE ex_reqs
      FOR ALL ENTRIES IN li_req
      WHERE trkorr = li_req-table_line
        AND strkorr = space.

  ENDMETHOD.


  METHOD source_search.
*&---------------------------------------------------------------------*
*& Custom programs, classes and function groups - chosen by a name
*& pattern and/or a package - whose source contains a word. By default
*& only the header of each include is read (the first lines, where the
*& program header and its modification log sit), which finds objects by
*& project name, ticket or author in their change log. With
*& header_only false the whole source is searched.
*&
*& Includes searched: a program itself; a class's public section, and
*& with the whole source its local implementations and every method;
*& a function group's function modules and TOP include, and with the
*& whole source all its includes.
*&---------------------------------------------------------------------*

    TYPES: BEGIN OF lt_tad,
             object   TYPE trobjtype,
             obj_name TYPE sobj_name,
             devclass TYPE devclass,
           END OF lt_tad.
    TYPES: BEGIN OF lt_inc,
             obj_name TYPE sobj_name,
             object   TYPE trobjtype,
             include  TYPE progname,
             devclass TYPE devclass,
           END OF lt_inc.

    DATA lo_in      TYPE REF TO zif_ajson.
    DATA lo_out     TYPE REF TO zcl_ajson.
    DATA lx_root    TYPE REF TO cx_root.
    DATA lv_text    TYPE string.
    DATA lv_pattern TYPE string.
    DATA lv_package TYPE string.
    DATA lv_head    TYPE abap_bool.
    DATA lv_max     TYPE i.
    DATA lv_olike   TYPE c LENGTH 41.
    DATA lv_dlike   TYPE c LENGTH 31.
    DATA li_tad     TYPE STANDARD TABLE OF lt_tad.
    DATA lw_tad     TYPE lt_tad.
    DATA li_inc     TYPE STANDARD TABLE OF lt_inc.
    DATA lw_inc     TYPE lt_inc.
    DATA lv_c30     TYPE c LENGTH 30.
    DATA lv_cls     TYPE seoclsname.
    DATA li_meth    TYPE seop_methods_w_include.
    DATA lw_meth    LIKE LINE OF li_meth.
    DATA lv_pname   TYPE pname.
    DATA li_fmi     TYPE STANDARD TABLE OF includenr.
    DATA lv_fmi     TYPE includenr.
    DATA lv_like    TYPE c LENGTH 42.
    DATA li_trdir   TYPE STANDARD TABLE OF progname.
    DATA lv_prog    TYPE progname.
    DATA lv_str     TYPE string.
    DATA lv_len     TYPE i.
    DATA lv_nlen    TYPE i.
    DATA li_src     TYPE string_table.
    DATA lv_line    TYPE string.
    DATA li_res     TYPE match_result_tab.
    DATA lw_res     TYPE match_result.
    DATA lv_scanned TYPE i.
    DATA lv_hits    TYPE i.
    DATA lv_stop    TYPE abap_bool.
    DATA lv_n       TYPE i.
    DATA lv_cut     TYPE i.
    DATA lv_last    TYPE i.
    DATA lv_cnt     TYPE i.
    DATA lv_i       TYPE string.
    DATA lv_j       TYPE string.
    DATA lv_base    TYPE string.
    DATA lv_lbase   TYPE string.
    DATA lv_path    TYPE string.
    DATA lv_val     TYPE string.

    lo_in = zcl_ajson=>parse( im_input ).
    lv_text = lo_in->get( '/text' ).
    CONDENSE lv_text.
    lv_pattern = lo_in->get( '/pattern' ).
    CONDENSE lv_pattern NO-GAPS.
    TRANSLATE lv_pattern TO UPPER CASE.
    lv_package = lo_in->get( '/package' ).
    CONDENSE lv_package NO-GAPS.
    TRANSLATE lv_package TO UPPER CASE.

    IF strlen( lv_text ) < 3 OR strlen( lv_text ) > 60.
      ex_json = error_json( im_msg = 'text is required: 3 to 60 characters, e.g. PAYMENTS.' ).
      RETURN.
    ENDIF.
    IF lv_pattern IS INITIAL AND lv_package IS INITIAL.
      ex_json = error_json( im_msg = 'Give pattern (object names, e.g. ZFI*) or package (e.g. ZFI), or both.' ).
      RETURN.
    ENDIF.
    IF lv_pattern IS NOT INITIAL AND lv_pattern(1) <> 'Z' AND lv_pattern(1) <> 'Y'.
      ex_json = error_json( im_msg = 'Refused. pattern must begin with Z or Y, for example ZFI*.' ).
      RETURN.
    ENDIF.
    IF lv_package IS NOT INITIAL AND lv_package(1) <> 'Z' AND lv_package(1) <> 'Y'
       AND lv_package(1) <> '$'.
      ex_json = error_json( im_msg = 'Refused. package must begin with Z, Y or $.' ).
      RETURN.
    ENDIF.
    IF strlen( lv_pattern ) > 40 OR strlen( lv_package ) > 30.
      ex_json = error_json( im_msg = 'pattern is at most 40 characters, package at most 30.' ).
      RETURN.
    ENDIF.

    lv_head = abap_true.
    IF lo_in->exists( '/header_only' ) = abap_true.
      lv_head = lo_in->get_boolean( '/header_only' ).
    ENDIF.
    lv_max = lo_in->get_integer( '/max_results' ).
    IF lv_max <= 0.
      lv_max = c_def_hits.
    ELSEIF lv_max > c_max_hits.
      lv_max = c_max_hits.
    ENDIF.

*   ---- the objects in scope -----------------------------------------
    IF lv_pattern IS INITIAL.
      lv_olike = '%'.
    ELSE.
      lv_olike = lv_pattern.
      TRANSLATE lv_olike USING '*%'.
    ENDIF.
    IF lv_package IS INITIAL.
      lv_dlike = '%'.
    ELSE.
      lv_dlike = lv_package.
      TRANSLATE lv_dlike USING '*%'.
    ENDIF.

    SELECT object obj_name devclass FROM tadir INTO TABLE li_tad
      WHERE pgmid = 'R3TR'
        AND ( object = 'PROG' OR object = 'CLAS' OR object = 'FUGR' )
        AND obj_name LIKE lv_olike
        AND devclass LIKE lv_dlike
        AND delflag  = space.
*   custom objects only, also when only a package was given
    DELETE li_tad WHERE obj_name NP 'Z*' AND obj_name NP 'Y*'.
*   only packages whose code the caller may read (Z_AI_SCOPE DEVCLASS,
*   ZCL_AI_AUTH 23.10.2026) - the rest is left out of the search
    LOOP AT li_tad INTO lw_tad.
      IF zcl_ai_auth=>check_package( lw_tad-devclass ) = abap_false.
        DELETE li_tad.
      ENDIF.
    ENDLOOP.
    SORT li_tad BY obj_name object.

*   ---- the includes to read -----------------------------------------
    LOOP AT li_tad INTO lw_tad.
      IF lines( li_inc ) >= c_max_scan.
        lv_stop = abap_true.
        EXIT.
      ENDIF.
      CLEAR lw_inc.
      lw_inc-obj_name = lw_tad-obj_name.
      lw_inc-object   = lw_tad-object.
      lw_inc-devclass = lw_tad-devclass.

      CASE lw_tad-object.
        WHEN 'PROG'.
          lw_inc-include = lw_tad-obj_name.
          APPEND lw_inc TO li_inc.

        WHEN 'CLAS'.
          lv_c30 = lw_tad-obj_name.
          TRANSLATE lv_c30 USING ' ='.
          CONCATENATE lv_c30 'CU' INTO lw_inc-include.
          APPEND lw_inc TO li_inc.
          IF lv_head = abap_false.
            CONCATENATE lv_c30 'CCIMP' INTO lw_inc-include.
            APPEND lw_inc TO li_inc.
            lv_cls = lw_tad-obj_name.
            TRY.
                li_meth = cl_oo_classname_service=>get_all_method_includes( lv_cls ).
              CATCH cx_root INTO lx_root.
                CLEAR li_meth.
            ENDTRY.
            LOOP AT li_meth INTO lw_meth.
              lw_inc-include = lw_meth-incname.
              APPEND lw_inc TO li_inc.
            ENDLOOP.
          ENDIF.

        WHEN 'FUGR'.
          CONCATENATE 'SAPL' lw_tad-obj_name INTO lv_pname.
          SELECT include FROM tfdir INTO TABLE li_fmi WHERE pname = lv_pname.
          LOOP AT li_fmi INTO lv_fmi.
            CONCATENATE 'L' lw_tad-obj_name 'U' lv_fmi INTO lw_inc-include.
            APPEND lw_inc TO li_inc.
          ENDLOOP.
          CONCATENATE 'L' lw_tad-obj_name 'TOP' INTO lw_inc-include.
          APPEND lw_inc TO li_inc.
          IF lv_head = abap_false.
            lw_inc-include = lv_pname.
            APPEND lw_inc TO li_inc.
*           L<group> plus exactly three characters - LIKE takes '_' as
*           a wildcard and ZAB% also finds ZABC
            CONCATENATE 'L' lw_tad-obj_name '%' INTO lv_like.
            SELECT name FROM trdir INTO TABLE li_trdir WHERE name LIKE lv_like.
            lv_nlen = strlen( lw_tad-obj_name ).
            lv_len  = lv_nlen + 4.
            LOOP AT li_trdir INTO lv_prog.
              lv_str = lv_prog.
              IF strlen( lv_str ) = lv_len AND lv_str+1(lv_nlen) = lw_tad-obj_name.
                lw_inc-include = lv_prog.
                APPEND lw_inc TO li_inc.
              ENDIF.
            ENDLOOP.
          ENDIF.
      ENDCASE.
    ENDLOOP.
    SORT li_inc BY include.
    DELETE ADJACENT DUPLICATES FROM li_inc COMPARING include.
    SORT li_inc BY obj_name object include.

*   ---- read and search -----------------------------------------------
    lo_out = zcl_ajson=>create_empty( ).
    lo_out->set( iv_path = '/text' iv_val = lv_text ).
    IF lv_pattern IS NOT INITIAL.
      lo_out->set( iv_path = '/pattern' iv_val = lv_pattern ).
    ENDIF.
    IF lv_package IS NOT INITIAL.
      lo_out->set( iv_path = '/package' iv_val = lv_package ).
    ENDIF.
    lo_out->set_boolean( iv_path = '/header_only' iv_val = lv_head ).
    lo_out->touch_array( '/hits' ).

    LOOP AT li_inc INTO lw_inc.
      IF lv_scanned >= c_max_scan.
        lv_stop = abap_true.
        EXIT.
      ENDIF.
      lv_scanned = lv_scanned + 1.

      lv_prog = lw_inc-include.
      CLEAR li_src.
      READ REPORT lv_prog INTO li_src.
      IF sy-subrc <> 0.
        CONTINUE.
      ENDIF.
      IF lv_head = abap_true.
        lv_n = lines( li_src ).
        IF lv_n > c_head_lines.
          lv_cut = c_head_lines + 1.
          DELETE li_src FROM lv_cut.
        ENDIF.
      ENDIF.

      CLEAR li_res.
      FIND ALL OCCURRENCES OF lv_text IN TABLE li_src IGNORING CASE RESULTS li_res.
      IF li_res IS INITIAL.
        CONTINUE.
      ENDIF.
      lv_hits = lv_hits + 1.
      IF lv_hits > lv_max.
        CONTINUE.
      ENDIF.

      lv_i = lv_hits.
      CONDENSE lv_i.
      CONCATENATE '/hits/' lv_i INTO lv_base.
      CONCATENATE lv_base '/object' INTO lv_path.
      CONCATENATE lw_inc-object lw_inc-obj_name INTO lv_val SEPARATED BY space.
      lo_out->set( iv_path = lv_path iv_val = lv_val ).
      CONCATENATE lv_base '/include' INTO lv_path.
      lv_val = lw_inc-include.
      lo_out->set( iv_path = lv_path iv_val = lv_val ).
      CONCATENATE lv_base '/package' INTO lv_path.
      lv_val = lw_inc-devclass.
      lo_out->set( iv_path = lv_path iv_val = lv_val ).
      CONCATENATE lv_base '/matches' INTO lv_path.
      lv_cnt = lines( li_res ).
      lo_out->set_integer( iv_path = lv_path iv_val = lv_cnt ).

      CONCATENATE lv_base '/lines' INTO lv_path.
      lo_out->touch_array( lv_path ).
      lv_last = 0.
      lv_n    = 0.
      LOOP AT li_res INTO lw_res.
        IF lw_res-line = lv_last.
          CONTINUE.
        ENDIF.
        lv_last = lw_res-line.
        lv_n = lv_n + 1.
        IF lv_n > c_hit_lines.
          EXIT.
        ENDIF.
        READ TABLE li_src INTO lv_line INDEX lw_res-line.
        CONDENSE lv_line.
        IF strlen( lv_line ) > 200.
          lv_line = lv_line(200).
        ENDIF.
        lv_j = lv_n.
        CONDENSE lv_j.
        CONCATENATE lv_base '/lines/' lv_j INTO lv_lbase.
        CONCATENATE lv_lbase '/line' INTO lv_path.
        lo_out->set_integer( iv_path = lv_path iv_val = lw_res-line ).
        CONCATENATE lv_lbase '/text' INTO lv_path.
        lo_out->set( iv_path = lv_path iv_val = lv_line ).
      ENDLOOP.
    ENDLOOP.

    lv_n = lines( li_tad ).
    lo_out->set_integer( iv_path = '/objects_in_scope' iv_val = lv_n ).
    lo_out->set_integer( iv_path = '/includes_read' iv_val = lv_scanned ).
    lo_out->set_integer( iv_path = '/hit_count' iv_val = lv_hits ).

    IF lv_stop = abap_true.
      lo_out->set( iv_path = '/note'
                   iv_val  = 'Stopped after 3000 includes - narrow the pattern or the package and search again.' ).
    ELSEIF lv_hits > lv_max.
      lo_out->set( iv_path = '/note'
                   iv_val  = 'More includes matched than were returned. Raise max_results (at most 200) or narrow the scope.' ).
    ELSEIF lv_hits = 0 AND lv_head = abap_true.
      lo_out->set( iv_path = '/note'
                   iv_val  = 'Not found in the headers. Search the whole source with header_only false.' ).
    ENDIF.

    ex_json = lo_out->stringify( ).

  ENDMETHOD.


  METHOD status_text.
*&---------------------------------------------------------------------*
*& Request status as a word (domain TRSTATUS).
*&---------------------------------------------------------------------*

    CASE im_status.
      WHEN 'D'.
        ex_text = 'modifiable'.
      WHEN 'L'.
        ex_text = 'modifiable, protected'.
      WHEN 'O'.
        ex_text = 'release started'.
      WHEN 'R'.
        ex_text = 'released'.
      WHEN 'N'.
        ex_text = 'released (repairs protected)'.
      WHEN OTHERS.
        ex_text = im_status.
    ENDCASE.

  ENDMETHOD.


  METHOD system_text.
*&---------------------------------------------------------------------*
*& The description TMS holds for a system, e.g. "Quality assurance".
*& Read once per call.
*&---------------------------------------------------------------------*

    DATA lw_sys TYPE t_sys.

    IF gt_sys IS INITIAL.
      SELECT sysnam systxt FROM tmscsys INTO TABLE gt_sys.
      IF gt_sys IS INITIAL.
*       remember that there is nothing to read
        lw_sys-sysnam = '-'.
        APPEND lw_sys TO gt_sys.
      ENDIF.
      SORT gt_sys BY sysnam.
    ENDIF.

    READ TABLE gt_sys INTO lw_sys WITH KEY sysnam = im_system BINARY SEARCH.
    IF sy-subrc = 0.
      ex_text = lw_sys-systxt.
    ENDIF.

  ENDMETHOD.


  METHOD transport_search.
*&---------------------------------------------------------------------*
*& Requests whose description - or the description of one of their
*& tasks - contains a word, newest first. Per request its objects and
*& where it was imported; across all of them one de-duplicated object
*& list with each object's package, so a project inventory comes from
*& a single call. The text is matched as typed, in upper case, lower
*& case and capitalised, as E07T texts are stored as entered.
*&---------------------------------------------------------------------*

    TYPES: BEGIN OF lt_all,
             object   TYPE trobjtype,
             obj_name TYPE trobj_name,
             requests TYPE i,
             latest   TYPE trkorr,
           END OF lt_all.
    TYPES: BEGIN OF lt_tadir,
             object   TYPE trobjtype,
             obj_name TYPE sobj_name,
             devclass TYPE devclass,
           END OF lt_tadir.
    TYPES: BEGIN OF lt_count,
             object TYPE trobjtype,
             count  TYPE i,
           END OF lt_count.

    DATA lo_in    TYPE REF TO zif_ajson.
    DATA lo_out   TYPE REF TO zcl_ajson.
    DATA lv_text  TYPE string.
    DATA lv_up    TYPE string.
    DATA lv_low   TYPE string.
    DATA lv_cap   TYPE string.
    DATA lv_first TYPE string.
    DATA lv_rest  TYPE string.
    DATA lv_p1    TYPE c LENGTH 70.
    DATA lv_p2    TYPE c LENGTH 70.
    DATA lv_p3    TYPE c LENGTH 70.
    DATA lv_p4    TYPE c LENGTH 70.
    DATA lv_max   TYPE i.
    DATA lv_objs  TYPE abap_bool.
    DATA lv_imps  TYPE abap_bool.
    DATA li_hit   TYPE t_korr_tab.
    DATA li_reqs  TYPE t_req_tab.
    DATA li_map   TYPE t_map_tab.
    DATA lw_req   TYPE t_req.
    DATA li_objs  TYPE t_obj_tab.
    DATA lw_obj   TYPE t_obj.
    DATA li_imps  TYPE t_imp_tab.
    DATA li_all   TYPE SORTED TABLE OF lt_all WITH UNIQUE KEY object obj_name.
    DATA lw_all   TYPE lt_all.
    DATA li_keys  TYPE STANDARD TABLE OF lt_tadir.
    DATA lw_key   TYPE lt_tadir.
    DATA li_tadir TYPE SORTED TABLE OF lt_tadir WITH UNIQUE KEY object obj_name.
    DATA lw_tadir TYPE lt_tadir.
    DATA li_count TYPE SORTED TABLE OF lt_count WITH UNIQUE KEY object.
    DATA lw_count TYPE lt_count.
    DATA lv_total TYPE i.
    DATA lv_idx   TYPE i.
    DATA lv_ret   TYPE i.
    DATA lv_cnt   TYPE i.
    DATA lv_pos   TYPE i.
    DATA lv_i     TYPE string.
    DATA lv_base  TYPE string.
    DATA lv_path  TYPE string.
    DATA lv_val   TYPE string.

    FIELD-SYMBOLS <lf_all>   TYPE lt_all.
    FIELD-SYMBOLS <lf_count> TYPE lt_count.

    lo_in = zcl_ajson=>parse( im_input ).
    lv_text = lo_in->get( '/text' ).
    CONDENSE lv_text.
    IF strlen( lv_text ) < 3 OR strlen( lv_text ) > 60.
      ex_json = error_json( im_msg = 'text is required: 3 to 60 characters from the request description, e.g. PAYMENTS.' ).
      RETURN.
    ENDIF.
    lv_max = lo_in->get_integer( '/max_results' ).
    IF lv_max <= 0.
      lv_max = c_def_requests.
    ELSEIF lv_max > c_max_requests.
      lv_max = c_max_requests.
    ENDIF.
    lv_objs = abap_true.
    IF lo_in->exists( '/objects' ) = abap_true.
      lv_objs = lo_in->get_boolean( '/objects' ).
    ENDIF.
    lv_imps = abap_true.
    IF lo_in->exists( '/imports' ) = abap_true.
      lv_imps = lo_in->get_boolean( '/imports' ).
    ENDIF.

    IF auth_ok( ) = abap_false.
      ex_json = error_json( im_msg = 'No authorization to display transport requests (S_TRANSPRT, activity 03).' ).
      RETURN.
    ENDIF.

*   the four spellings a description is likely to use
    lv_up = lv_text.
    TRANSLATE lv_up TO UPPER CASE.
    lv_low = lv_text.
    TRANSLATE lv_low TO LOWER CASE.
    lv_first = lv_low(1).
    TRANSLATE lv_first TO UPPER CASE.
    lv_rest = lv_low+1.
    CONCATENATE lv_first lv_rest INTO lv_cap.
    CONCATENATE '%' lv_text '%' INTO lv_p1.
    CONCATENATE '%' lv_up '%' INTO lv_p2.
    CONCATENATE '%' lv_low '%' INTO lv_p3.
    CONCATENATE '%' lv_cap '%' INTO lv_p4.

    SELECT trkorr FROM e07t INTO TABLE li_hit
      WHERE as4text LIKE lv_p1 OR as4text LIKE lv_p2
         OR as4text LIKE lv_p3 OR as4text LIKE lv_p4.
    SORT li_hit.
    DELETE ADJACENT DUPLICATES FROM li_hit.

    requests_of( EXPORTING im_list = li_hit
                 IMPORTING ex_reqs = li_reqs
                           ex_map  = li_map ).
    SORT li_reqs BY as4date DESCENDING as4time DESCENDING trkorr DESCENDING.
    DESCRIBE TABLE li_reqs LINES lv_total.

    lo_out = zcl_ajson=>create_empty( ).
    lo_out->set( iv_path = '/text' iv_val = lv_text ).
    lv_val = sy-sysid.
    lo_out->set( iv_path = '/system' iv_val = lv_val ).
    lo_out->set_integer( iv_path = '/count' iv_val = lv_total ).
    lo_out->touch_array( '/requests' ).

    LOOP AT li_reqs INTO lw_req.
      lv_idx = sy-tabix.
      IF lv_idx > lv_max.
        EXIT.
      ENDIF.
      lv_ret = lv_idx.
      lv_i = lv_idx.
      CONDENSE lv_i.
      CONCATENATE '/requests/' lv_i INTO lv_base.

*     the transport log is a file read per request - only for the
*     newest ones
      IF lv_imps = abap_true AND lv_idx <= c_max_imports.
        add_request( EXPORTING im_out     = lo_out
                               im_base    = lv_base
                               im_req     = lw_req
                               im_imports = abap_true
                     IMPORTING ex_imports = li_imps ).
      ELSE.
        add_request( EXPORTING im_out     = lo_out
                               im_base    = lv_base
                               im_req     = lw_req
                               im_imports = abap_false
                     IMPORTING ex_imports = li_imps ).
      ENDIF.

      IF lv_objs = abap_false.
        CONTINUE.
      ENDIF.

      li_objs = request_objects( lw_req-trkorr ).
      DESCRIBE TABLE li_objs LINES lv_cnt.
      CONCATENATE lv_base '/object_count' INTO lv_path.
      lo_out->set_integer( iv_path = lv_path iv_val = lv_cnt ).
      CONCATENATE lv_base '/objects' INTO lv_path.
      lo_out->touch_array( lv_path ).

      LOOP AT li_objs INTO lw_obj.
        lv_pos = sy-tabix.
        IF lv_pos <= c_req_objects.
          lv_i = lv_pos.
          CONDENSE lv_i.
          CONCATENATE lv_base '/objects/' lv_i INTO lv_path.
          CONCATENATE lw_obj-object lw_obj-obj_name INTO lv_val SEPARATED BY space.
          lo_out->set( iv_path = lv_path iv_val = lv_val ).
        ENDIF.

*       combined list - requests come newest first, so the first one
*       that names an object is its latest
        READ TABLE li_all ASSIGNING <lf_all>
          WITH TABLE KEY object = lw_obj-object obj_name = lw_obj-obj_name.
        IF sy-subrc = 0.
          <lf_all>-requests = <lf_all>-requests + 1.
        ELSE.
          CLEAR lw_all.
          lw_all-object   = lw_obj-object.
          lw_all-obj_name = lw_obj-obj_name.
          lw_all-requests = 1.
          lw_all-latest   = lw_req-trkorr.
          INSERT lw_all INTO TABLE li_all.
        ENDIF.
      ENDLOOP.
    ENDLOOP.
    lo_out->set_integer( iv_path = '/returned' iv_val = lv_ret ).

*   ---- the combined object list, with each object's package ---------
    IF lv_objs = abap_true.
      LOOP AT li_all INTO lw_all.
        IF strlen( lw_all-obj_name ) <= 40.
          lw_key-object   = lw_all-object.
          lw_key-obj_name = lw_all-obj_name.
          APPEND lw_key TO li_keys.
        ENDIF.
      ENDLOOP.
      IF li_keys IS NOT INITIAL.
        SELECT object obj_name devclass FROM tadir INTO TABLE li_tadir
          FOR ALL ENTRIES IN li_keys
          WHERE pgmid    = 'R3TR'
            AND object   = li_keys-object
            AND obj_name = li_keys-obj_name.
      ENDIF.

      DESCRIBE TABLE li_all LINES lv_cnt.
      lo_out->set_integer( iv_path = '/object_count' iv_val = lv_cnt ).
      lo_out->touch_array( '/objects' ).
      LOOP AT li_all INTO lw_all.
        lv_pos = sy-tabix.

        READ TABLE li_count ASSIGNING <lf_count> WITH TABLE KEY object = lw_all-object.
        IF sy-subrc = 0.
          <lf_count>-count = <lf_count>-count + 1.
        ELSE.
          lw_count-object = lw_all-object.
          lw_count-count  = 1.
          INSERT lw_count INTO TABLE li_count.
        ENDIF.

        IF lv_pos > c_max_objects.
          CONTINUE.
        ENDIF.
        lv_i = lv_pos.
        CONDENSE lv_i.
        CONCATENATE '/objects/' lv_i INTO lv_base.
        CONCATENATE lv_base '/object' INTO lv_path.
        CONCATENATE lw_all-object lw_all-obj_name INTO lv_val SEPARATED BY space.
        lo_out->set( iv_path = lv_path iv_val = lv_val ).
        READ TABLE li_tadir INTO lw_tadir
          WITH TABLE KEY object = lw_all-object obj_name = lw_all-obj_name.
        IF sy-subrc = 0.
          CONCATENATE lv_base '/package' INTO lv_path.
          lv_val = lw_tadir-devclass.
          lo_out->set( iv_path = lv_path iv_val = lv_val ).
        ENDIF.
        CONCATENATE lv_base '/requests' INTO lv_path.
        lo_out->set_integer( iv_path = lv_path iv_val = lw_all-requests ).
        CONCATENATE lv_base '/latest_request' INTO lv_path.
        lv_val = lw_all-latest.
        lo_out->set( iv_path = lv_path iv_val = lv_val ).
      ENDLOOP.

      LOOP AT li_count INTO lw_count.
        lv_val = lw_count-object.
        CONCATENATE '/object_types/' lv_val INTO lv_path.
        lo_out->set_integer( iv_path = lv_path iv_val = lw_count-count ).
      ENDLOOP.
    ENDIF.

    IF lv_total = 0.
      lo_out->set( iv_path = '/note'
                   iv_val  = 'No request or task description contains this text (searched as typed, upper case, lower case and capitalised).' ).
    ELSEIF lv_total > lv_ret.
      lo_out->set( iv_path = '/note'
                   iv_val  = 'More requests matched than were returned. Raise max_results (at most 100), or add a word to narrow the text. The object list covers the returned requests only.' ).
    ENDIF.

    ex_json = lo_out->stringify( ).

  ENDMETHOD.


  METHOD type_text.
*&---------------------------------------------------------------------*
*& Request type as a word (domain TRFUNCTION).
*&---------------------------------------------------------------------*

    CASE im_type.
      WHEN 'K'.
        ex_text = 'workbench'.
      WHEN 'W'.
        ex_text = 'customizing'.
      WHEN 'T'.
        ex_text = 'transport of copies'.
      WHEN 'C'.
        ex_text = 'relocation'.
      WHEN OTHERS.
        ex_text = im_type.
    ENDCASE.

  ENDMETHOD.


ENDCLASS.
