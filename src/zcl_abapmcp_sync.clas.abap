CLASS zcl_abapmcp_sync DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.
*&---------------------------------------------------------------------*
*& Repository sync reads for the abapsync CLI.
*&
*& Two read-only MCP tools, served through the existing /sap/bc/mcp
*& node (ZCL_ABAPMCP_SERVER -> ZCL_ABAPMCP_TOOLS -> this class):
*&
*&   sap_list_package    every PROG/CLAS/INTF/FUGR in a package tree,
*&                       with one hash per source include
*&   sap_get_raw_source  exact, uncompressed source of up to 25 objects
*&
*& Unlike ZCL_ABAPMCP_TOOLS=>GET_SOURCE (skeleton + compression for an
*& LLM) this class returns source BYTE-EXACT, because the CLI hashes
*& it to detect changes. Never route this output through
*& ZCL_ABAPMCP_STRUCTURE.
*&
*& READ-ONLY. Every method is a SELECT or a READ REPORT. The write
*& path (push) belongs on a separate ICF node - see abapsync/README.md.
*&
*& NW 7.02 syntax only: no inline DATA( ), no VALUE #( ), no NEW.
*& JSON via ajson. Hashing and class part names reuse abapGit
*& (ZCL_ABAPGIT_HASH, ZCL_ABAPGIT_OO_CLASS), and the DDIC and program
*& reads reuse ZCL_ABAPSYNC_DDIC / _REPO - so the abapsync classes and
*& abapGit's developer version must be installed (docs/install.md).
*&---------------------------------------------------------------------*
    TYPES: BEGIN OF ty_part_meta,
             part     TYPE string,
             include  TYPE string,
             lines    TYPE i,
             hash     TYPE string,
           END OF ty_part_meta,
           tt_part_meta TYPE STANDARD TABLE OF ty_part_meta WITH DEFAULT KEY.

    TYPES: BEGIN OF ty_part,
             part     TYPE string,
             include  TYPE string,
             lines    TYPE i,
             hash     TYPE string,
             source   TYPE string,
           END OF ty_part,
           tt_part TYPE STANDARD TABLE OF ty_part WITH DEFAULT KEY.

    CONSTANTS c_max_objects   TYPE i VALUE 3000.  "per sap_list_package
    CONSTANTS c_max_batch     TYPE i VALUE 25.    "per sap_get_raw_source
    CONSTANTS c_hash_alg      TYPE string VALUE 'SHA1'.

    "Tool definitions in Anthropic Messages API shape (input_schema),
    "as a comma-separated list WITHOUT brackets - splice into the
    "array built by ZCL_ABAPMCP_TOOLS=>GET_TOOL_DEFS.
    CLASS-METHODS get_tool_defs_json
      RETURNING VALUE(rv_json) TYPE string.

    "abap_true if iv_name is one of this class's tools
    CLASS-METHODS handles
      IMPORTING iv_name       TYPE string
      RETURNING VALUE(rv_yes) TYPE abap_bool.

    "Entry point, same contract as ZCL_ABAPMCP_TOOLS=>EXECUTE:
    "JSON arguments in, JSON result out, {"error":"..."} on failure.
    CLASS-METHODS execute
      IMPORTING iv_name          TYPE string
                iv_input         TYPE string
      RETURNING VALUE(rv_result) TYPE string.

    "Hash of the ACTIVE source of one include, exactly as
    "sap_list_package reports it. '' if the include does not exist.
    "Used by ZCL_ABAPSYNC_WRITE for its drift check.
    CLASS-METHODS include_hash
      IMPORTING iv_include     TYPE string
      RETURNING VALUE(rv_hash) TYPE string.

    "SHA-1 (lower-case hex) of the UTF-8 bytes of a text.
    CLASS-METHODS hash_text
      IMPORTING iv_text        TYPE string
      RETURNING VALUE(rv_hash) TYPE string.

PROTECTED SECTION.

  PRIVATE SECTION.

    TYPES: BEGIN OF ty_object,
             object   TYPE string,
             name     TYPE string,
             package  TYPE string,
             parts    TYPE tt_part_meta,
           END OF ty_object,
           tt_object TYPE STANDARD TABLE OF ty_object WITH DEFAULT KEY.

    TYPES: BEGIN OF ty_object_src,
             object   TYPE string,
             name     TYPE string,
             package  TYPE string,
             parts    TYPE tt_part,
           END OF ty_object_src,
           tt_object_src TYPE STANDARD TABLE OF ty_object_src WITH DEFAULT KEY.

    TYPES: BEGIN OF ty_skip,
             object   TYPE string,
             count    TYPE i,
           END OF ty_skip,
           tt_skip TYPE STANDARD TABLE OF ty_skip WITH DEFAULT KEY.

    TYPES: BEGIN OF ty_err,
             object   TYPE string,
             name     TYPE string,
             message  TYPE string,
           END OF ty_err,
           tt_err TYPE STANDARD TABLE OF ty_err WITH DEFAULT KEY.

    TYPES: BEGIN OF ty_list_result,
             package      TYPE string,
             subpackages  TYPE abap_bool,
             hash_alg     TYPE string,
             object_count TYPE i,
             packages     TYPE string_table,
             objects      TYPE tt_object,
             skipped      TYPE tt_skip,
           END OF ty_list_result.

    TYPES: BEGIN OF ty_src_result,
             hash_alg     TYPE string,
             objects      TYPE tt_object_src,
             errors       TYPE tt_err,
           END OF ty_src_result.

    TYPES: BEGIN OF ty_tadir,
             object   TYPE trobjtype,
             obj_name TYPE sobj_name,
             devclass TYPE devclass,
           END OF ty_tadir,
           tt_tadir TYPE STANDARD TABLE OF ty_tadir WITH DEFAULT KEY.

    CLASS-METHODS list_package
      IMPORTING iv_input       TYPE string
      RETURNING VALUE(rv_json) TYPE string
      RAISING   zcx_ajson_error.

    CLASS-METHODS get_raw_source
      IMPORTING iv_input       TYPE string
      RETURNING VALUE(rv_json) TYPE string
      RAISING   zcx_ajson_error.

    CLASS-METHODS collect_packages
      IMPORTING iv_root        TYPE devclass
                iv_sub         TYPE abap_bool
      RETURNING VALUE(rt_pkgs) TYPE string_table.

    CLASS-METHODS get_parts
      IMPORTING iv_object TYPE string
                iv_name   TYPE string
      EXPORTING et_parts  TYPE tt_part.

    "Name of a class/interface pool include: the name padded with '='
    "to 30 characters, then the suffix (CU, CO, CI, CCDEF, IU, ...)
    CLASS-METHODS clif_include
      IMPORTING iv_name           TYPE string
                iv_suffix         TYPE string
      RETURNING VALUE(rv_include) TYPE string.

    CLASS-METHODS add_part
      IMPORTING iv_part    TYPE string
                iv_include TYPE string
                iv_drop_banner TYPE abap_bool DEFAULT abap_false
      CHANGING  ct_parts   TYPE tt_part.

    CLASS-METHODS read_include
      IMPORTING iv_include TYPE string
      EXPORTING ev_text    TYPE string
                ev_lines   TYPE i
                ev_found   TYPE abap_bool
                ev_banner_only TYPE abap_bool.

    CLASS-METHODS is_supported
      IMPORTING iv_object     TYPE string
      RETURNING VALUE(rv_yes) TYPE abap_bool.

    CLASS-METHODS error_json
      IMPORTING iv_msg         TYPE string
      RETURNING VALUE(rv_json) TYPE string.

ENDCLASS.


CLASS zcl_abapmcp_sync IMPLEMENTATION.

  METHOD add_part.

    DATA ls_part   TYPE ty_part.
    DATA lv_found  TYPE abap_bool.
    DATA lv_banner TYPE abap_bool.

    IF iv_include IS INITIAL.
      RETURN.
    ENDIF.

    read_include( EXPORTING iv_include     = iv_include
                  IMPORTING ev_text        = ls_part-source
                            ev_lines       = ls_part-lines
                            ev_found       = lv_found
                            ev_banner_only = lv_banner ).

    "Missing includes, empty includes, and generated includes holding
    "nothing but the class builder's comment banner are not parts.
    IF lv_found = abap_false OR ls_part-lines = 0.
      RETURN.
    ENDIF.
    IF iv_drop_banner = abap_true AND lv_banner = abap_true.
      RETURN.
    ENDIF.

    ls_part-part    = iv_part.
    ls_part-include = iv_include.
    ls_part-hash    = hash_text( ls_part-source ).
    APPEND ls_part TO ct_parts.

  ENDMETHOD.


  METHOD clif_include.

    DATA lv_root TYPE c LENGTH 30.

    lv_root = iv_name.
    TRANSLATE lv_root USING ' ='.          "same as abapGit's PROGSTRUC-ROOTNAME
    CONCATENATE lv_root iv_suffix INTO rv_include.

  ENDMETHOD.


  METHOD collect_packages.
    "Breadth-first walk of TDEVC-PARENTCL. Each package is visited once,
    "so a cycle in the hierarchy terminates.

    DATA lv_idx    TYPE i.
    DATA lv_pkg_s  TYPE string.
    DATA lv_pkg    TYPE devclass.
    DATA lt_child  TYPE STANDARD TABLE OF devclass.
    DATA lv_child  TYPE devclass.
    DATA lv_child_s TYPE string.

    lv_pkg_s = iv_root.
    APPEND lv_pkg_s TO rt_pkgs.

    IF iv_sub = abap_false.
      RETURN.
    ENDIF.

    lv_idx = 1.
    WHILE lv_idx <= lines( rt_pkgs ).

      READ TABLE rt_pkgs INDEX lv_idx INTO lv_pkg_s.
      lv_pkg = lv_pkg_s.

      CLEAR lt_child.
      SELECT devclass FROM tdevc INTO TABLE lt_child WHERE parentcl = lv_pkg.

      LOOP AT lt_child INTO lv_child.
        lv_child_s = lv_child.
        READ TABLE rt_pkgs WITH KEY table_line = lv_child_s TRANSPORTING NO FIELDS.
        IF sy-subrc <> 0.
          APPEND lv_child_s TO rt_pkgs.
        ENDIF.
      ENDLOOP.

      lv_idx = lv_idx + 1.
    ENDWHILE.

  ENDMETHOD.


  METHOD error_json.
    "Same shape as ZCL_ABAPMCP_TOOLS=>ERROR_JSON is expected to produce.
    "If yours differs, change this one method.

    DATA lo_out TYPE REF TO zif_ajson.
    DATA lx     TYPE REF TO zcx_ajson_error.

    TRY.
        lo_out = zcl_ajson=>create_empty( ).
        lo_out->set( iv_path = '/error' iv_val = iv_msg ).
        rv_json = lo_out->stringify( ).
      CATCH zcx_ajson_error INTO lx.
        rv_json = '{"error":"internal error building error message"}'.
    ENDTRY.

  ENDMETHOD.


  METHOD execute.

    DATA lx_json TYPE REF TO zcx_ajson_error.
    DATA lv_msg  TYPE string.

    TRY.
        CASE iv_name.
          WHEN 'sap_list_package'.
            rv_result = list_package( iv_input ).
          WHEN 'sap_get_raw_source'.
            rv_result = get_raw_source( iv_input ).
          WHEN OTHERS.
            CONCATENATE 'Unknown tool' iv_name INTO lv_msg SEPARATED BY space.
            rv_result = error_json( lv_msg ).
        ENDCASE.
      CATCH zcx_ajson_error INTO lx_json.
        lv_msg = lx_json->get_text( ).
        CONCATENATE 'Invalid JSON arguments:' lv_msg INTO lv_msg SEPARATED BY space.
        rv_result = error_json( lv_msg ).
    ENDTRY.

  ENDMETHOD.


  METHOD get_parts.
    "Split an object into its source includes. Part names are stable
    "identifiers the CLI turns into file names:
    "  PROG  main
    "  INTF  main
    "  CLAS  pubsec protsec privsec locals_def locals_imp macros
    "        testclasses  method.<METHOD>
    "  FUGR  main  fm.<FUNCTION>  include.<SUFFIX>

    DATA lv_cls      TYPE seoclsname.
    DATA lv_inc_s    TYPE string.
    DATA lv_part     TYPE string.
    DATA lt_meth     TYPE seop_methods_w_include.
    DATA ls_meth     LIKE LINE OF lt_meth.
    DATA lv_main     TYPE string.
    DATA lv_pattern  TYPE string.
    DATA lv_prefix   TYPE string.
    DATA lv_len      TYPE i.
    DATA lv_off      TYPE i.
    DATA lt_trdir    TYPE STANDARD TABLE OF progname.
    DATA lv_trdir    TYPE progname.
    DATA lv_suffix   TYPE string.
    DATA lv_fmnum    TYPE c LENGTH 2.
    DATA lv_pname    TYPE pname.
    DATA lv_func     TYPE rs38l_fnam.
    DATA ls_ddic     TYPE ty_part.

    CLEAR et_parts.

    "Dictionary objects have no source text: the definition as JSON
    "(ZCL_ABAPSYNC_DDIC). One part, 'ddic'; the include column carries the
    "object name. No active version: no part, like an empty include.
    IF zcl_abapsync_ddic=>is_ddic_type( iv_object ) = abap_true.
      ls_ddic-source = zcl_abapsync_ddic=>ddic_text( im_object = iv_object
                                                    im_name   = iv_name ).
      IF ls_ddic-source IS NOT INITIAL.
        ls_ddic-part    = 'ddic'.
        ls_ddic-include = iv_name.
        ls_ddic-hash    = hash_text( ls_ddic-source ).
        FIND ALL OCCURRENCES OF cl_abap_char_utilities=>newline
          IN ls_ddic-source MATCH COUNT ls_ddic-lines.
        APPEND ls_ddic TO et_parts.
      ENDIF.
      RETURN.
    ENDIF.

    "Transactions: the definition as JSON (ZCL_ABAPSYNC_REPO), one part
    "'tran'; the include column carries the transaction code.
    IF zcl_abapsync_repo=>is_repo_type( iv_object ) = abap_true.
      ls_ddic-source = zcl_abapsync_repo=>tran_text( iv_name ).
      IF ls_ddic-source IS NOT INITIAL.
        ls_ddic-part    = 'tran'.
        ls_ddic-include = iv_name.
        ls_ddic-hash    = hash_text( ls_ddic-source ).
        FIND ALL OCCURRENCES OF cl_abap_char_utilities=>newline
          IN ls_ddic-source MATCH COUNT ls_ddic-lines.
        APPEND ls_ddic TO et_parts.
      ENDIF.
      RETURN.
    ENDIF.

    CASE iv_object.

      WHEN 'PROG'.
        add_part( EXPORTING iv_part = 'main' iv_include = iv_name
                  CHANGING  ct_parts = et_parts ).

      WHEN 'INTF'.
        "Include names are built, not looked up: <name padded with = to
        "30>IU. Same convention as the class includes below - visible in
        "the live system as e.g. ZCL_ABAPMCP_TOOLS=============CU.
        lv_inc_s = clif_include( iv_name = iv_name iv_suffix = 'IU' ).
        add_part( EXPORTING iv_part = 'main' iv_include = lv_inc_s
                  CHANGING  ct_parts = et_parts ).

      WHEN 'CLAS'.
        lv_cls = iv_name.

        lv_inc_s = clif_include( iv_name = iv_name iv_suffix = 'CU' ).
        add_part( EXPORTING iv_part = 'pubsec' iv_include = lv_inc_s
                  CHANGING  ct_parts = et_parts ).

        lv_inc_s = clif_include( iv_name = iv_name iv_suffix = 'CO' ).
        add_part( EXPORTING iv_part = 'protsec' iv_include = lv_inc_s iv_drop_banner = abap_true
                  CHANGING  ct_parts = et_parts ).

        lv_inc_s = clif_include( iv_name = iv_name iv_suffix = 'CI' ).
        add_part( EXPORTING iv_part = 'privsec' iv_include = lv_inc_s iv_drop_banner = abap_true
                  CHANGING  ct_parts = et_parts ).

        lv_inc_s = clif_include( iv_name = iv_name iv_suffix = 'CCDEF' ).
        add_part( EXPORTING iv_part = 'locals_def' iv_include = lv_inc_s iv_drop_banner = abap_true
                  CHANGING  ct_parts = et_parts ).

        lv_inc_s = clif_include( iv_name = iv_name iv_suffix = 'CCIMP' ).
        add_part( EXPORTING iv_part = 'locals_imp' iv_include = lv_inc_s iv_drop_banner = abap_true
                  CHANGING  ct_parts = et_parts ).

        lv_inc_s = clif_include( iv_name = iv_name iv_suffix = 'CCMAC' ).
        add_part( EXPORTING iv_part = 'macros' iv_include = lv_inc_s iv_drop_banner = abap_true
                  CHANGING  ct_parts = et_parts ).

        lv_inc_s = clif_include( iv_name = iv_name iv_suffix = 'CCAU' ).
        add_part( EXPORTING iv_part = 'testclasses' iv_include = lv_inc_s iv_drop_banner = abap_true
                  CHANGING  ct_parts = et_parts ).

        "All method includes, INCLUDING interface method implementations
        "(ZIF_X~METH). Called functionally, exactly as the abapGit
        "installed in this system does (ZCL_ABAPGIT_OO_CLASS).
        lt_meth = cl_oo_classname_service=>get_all_method_includes( lv_cls ).
        SORT lt_meth BY cpdkey-cpdname.
        LOOP AT lt_meth INTO ls_meth.
          lv_part = ls_meth-cpdkey-cpdname.
          CONCATENATE 'method.' lv_part INTO lv_part.
          lv_inc_s = ls_meth-incname.
          add_part( EXPORTING iv_part = lv_part iv_include = lv_inc_s
                    CHANGING  ct_parts = et_parts ).
        ENDLOOP.

      WHEN 'FUGR'.
        "Main program SAPL<fg>, and every include L<fg><3-char suffix>.
        "The fixed length stops ZAB from picking up includes of ZABC.
        CONCATENATE 'SAPL' iv_name INTO lv_main.
        add_part( EXPORTING iv_part = 'main' iv_include = lv_main
                  CHANGING  ct_parts = et_parts ).

        CONCATENATE 'L' iv_name '%' INTO lv_pattern.
        lv_len = strlen( iv_name ) + 4.
        lv_off = strlen( iv_name ) + 1.

        SELECT name FROM trdir INTO TABLE lt_trdir WHERE name LIKE lv_pattern.
        SORT lt_trdir.

        "LIKE treats '_' as a one-character wildcard, and function group
        "names often contain '_', so re-check the exact prefix here.
        CONCATENATE 'L' iv_name INTO lv_prefix.

        LOOP AT lt_trdir INTO lv_trdir.
          IF strlen( lv_trdir ) <> lv_len.
            CONTINUE.
          ENDIF.
          IF lv_trdir(lv_off) <> lv_prefix.
            CONTINUE.
          ENDIF.

          lv_suffix = lv_trdir+lv_off(3).
          lv_inc_s  = lv_trdir.
          CONCATENATE 'include.' lv_suffix INTO lv_part.

          "L<fg>Unn is the include of function module nn
          IF lv_suffix(1) = 'U' AND lv_suffix+1(2) CO '0123456789'.
            lv_fmnum = lv_suffix+1(2).
            lv_pname = lv_main.
            CLEAR lv_func.
            SELECT SINGLE funcname FROM tfdir INTO lv_func
              WHERE pname = lv_pname AND include = lv_fmnum.
            IF sy-subrc = 0.
              lv_part = lv_func.
              CONCATENATE 'fm.' lv_part INTO lv_part.
            ENDIF.
          ENDIF.

          add_part( EXPORTING iv_part = lv_part iv_include = lv_inc_s
                    CHANGING  ct_parts = et_parts ).
        ENDLOOP.

    ENDCASE.

    "Text elements of a program or function group: JSON from
    "ZCL_ABAPSYNC_REPO, one part 'texts'; the include column carries the
    "program they belong to. No texts: no part.
    IF iv_object = 'PROG' OR iv_object = 'FUGR'.
      CLEAR ls_ddic.
      ls_ddic-source = zcl_abapsync_repo=>texts_text( im_object = iv_object
                                                     im_name   = iv_name ).
      IF ls_ddic-source IS NOT INITIAL.
        ls_ddic-part    = 'texts'.
        ls_ddic-include = zcl_abapsync_repo=>texts_program( im_object = iv_object
                                                           im_name   = iv_name ).
        ls_ddic-hash    = hash_text( ls_ddic-source ).
        FIND ALL OCCURRENCES OF cl_abap_char_utilities=>newline
          IN ls_ddic-source MATCH COUNT ls_ddic-lines.
        APPEND ls_ddic TO et_parts.
      ENDIF.
    ENDIF.

  ENDMETHOD.


  METHOD get_raw_source.

    DATA lo_in      TYPE REF TO zif_ajson.
    DATA lo_out     TYPE REF TO zif_ajson.
    DATA lt_req     TYPE string_table.
    DATA lv_req     TYPE string.
    DATA lv_obj     TYPE string.
    DATA lv_name    TYPE string.
    DATA lv_tadobj  TYPE trobjtype.
    DATA lv_tadnam  TYPE sobj_name.
    DATA lv_devc    TYPE devclass.
    DATA ls_result  TYPE ty_src_result.
    DATA ls_obj     TYPE ty_object_src.
    DATA ls_err     TYPE ty_err.

    lo_in = zcl_ajson=>parse( iv_input ).

    IF lo_in->exists( '/objects' ) = abap_false.
      rv_json = error_json( 'objects is required.' ).
      RETURN.
    ENDIF.

    lt_req = lo_in->array_to_string_table( '/objects' ).

    IF lines( lt_req ) > c_max_batch.
      rv_json = error_json( 'At most 25 objects per call.' ).
      RETURN.
    ENDIF.

    ls_result-hash_alg = c_hash_alg.

    LOOP AT lt_req INTO lv_req.

      CLEAR: lv_obj, lv_name, ls_err, ls_obj.
      CONDENSE lv_req.
      TRANSLATE lv_req TO UPPER CASE.
      SPLIT lv_req AT space INTO lv_obj lv_name.

      ls_err-object = lv_obj.
      ls_err-name   = lv_name.

      IF lv_name IS INITIAL OR is_supported( lv_obj ) = abap_false.
        ls_err-message = 'Expected TYPE NAME with TYPE one of PROG, CLAS, INTF, FUGR, TABL, DTEL, DOMA.'.
        APPEND ls_err TO ls_result-errors.
        CONTINUE.
      ENDIF.

      IF zcl_abapmcp_tools=>check_custom( lv_name ) = abap_false.
        ls_err-message = 'Only custom (Z/Y) objects can be read.'.
        APPEND ls_err TO ls_result-errors.
        CONTINUE.
      ENDIF.

      lv_tadobj = lv_obj.
      lv_tadnam = lv_name.
      SELECT SINGLE devclass FROM tadir INTO lv_devc
        WHERE pgmid = 'R3TR' AND object = lv_tadobj AND obj_name = lv_tadnam.
      IF sy-subrc <> 0.
        ls_err-message = 'Object not found in TADIR.'.
        APPEND ls_err TO ls_result-errors.
        CONTINUE.
      ENDIF.

*     the package's code must be readable (Z_AI_SCOPE, 23.10.2026)
      IF zcl_ai_auth=>check_package( lv_devc ) = abap_false.
        ls_err-message = zcl_ai_auth=>last_reason( ).
        APPEND ls_err TO ls_result-errors.
        CONTINUE.
      ENDIF.

      ls_obj-object  = lv_obj.
      ls_obj-name    = lv_name.
      ls_obj-package = lv_devc.

      get_parts( EXPORTING iv_object = lv_obj iv_name = lv_name
                 IMPORTING et_parts  = ls_obj-parts ).

      APPEND ls_obj TO ls_result-objects.

    ENDLOOP.

    lo_out = zcl_ajson=>create_empty( ).
    lo_out->set( iv_path = '/' iv_val = ls_result ).
    rv_json = lo_out->stringify( ).

  ENDMETHOD.


  METHOD get_tool_defs_json.

    CONCATENATE
      `{"name":"sap_list_package",`
      ` "description":"List every program, class, interface and function group in a custom package `
      `(and, by default, all its sub-packages), with one hash per source include. Used by the abapsync `
      `CLI to pull a package and to detect server-side changes. Returns metadata only, no source.",`
      ` "input_schema":{"type":"object","properties":{`
      `   "package":{"type":"string","description":"Package name: Z, Y, or a local $ package ($TMP lists only your own objects)."},`
      `   "subpackages":{"type":"boolean","description":"Include sub-packages. Default true."},`
      `   "types":{"type":"array","items":{"type":"string"},"description":"Optional filter: PROG, CLAS, INTF, FUGR, TABL, DTEL, DOMA."}},`
      `   "required":["package"]}},`
      `{"name":"sap_get_raw_source",`
      ` "description":"Return the exact, uncompressed source of up to 25 custom objects, split into `
      `their source includes (class sections, local classes, test classes, one include per method, `
      `function modules). Used by the abapsync CLI. For reading code to answer a question, use `
      `sap_get_source instead - it is built for that.",`
      ` "input_schema":{"type":"object","properties":{`
      `   "objects":{"type":"array","items":{"type":"string"},"description":"Up to 25 entries of the form 'TYPE NAME', e.g. 'CLAS ZCL_FOO' or 'PROG ZREPORT'."}},`
      `   "required":["objects"]}}`
      INTO rv_json.

  ENDMETHOD.


  METHOD handles.

    IF iv_name = 'sap_list_package' OR iv_name = 'sap_get_raw_source'.
      rv_yes = abap_true.
    ENDIF.

  ENDMETHOD.


  METHOD hash_text.
    "SHA-1 (lower-case hex) of the UTF-8 bytes. Change detection, not
    "security. Uses CL_ABAP_HMAC with an EMPTY key, which yields the plain
    "SHA-1 digest - the exact call ZCL_ABAPGIT_HASH=>SHA1_RAW makes in
    "this system to compute git object ids, so it is proven on 7.02.

    DATA lo_conv TYPE REF TO cl_abap_conv_out_ce.
    DATA lv_x    TYPE xstring.
    DATA lv_key  TYPE xstring.
    DATA lv_hash TYPE string.
    DATA lx      TYPE REF TO cx_abap_message_digest.

    lo_conv = cl_abap_conv_out_ce=>create( encoding = 'UTF-8' ).
    lo_conv->convert( EXPORTING data   = iv_text
                      IMPORTING buffer = lv_x ).

    TRY.
        cl_abap_hmac=>calculate_hmac_for_raw(
          EXPORTING if_key        = lv_key
                    if_data       = lv_x
          IMPORTING ef_hmacstring = lv_hash ).
      CATCH cx_abap_message_digest INTO lx.
        CLEAR lv_hash.
    ENDTRY.

    rv_hash = lv_hash.
    TRANSLATE rv_hash TO LOWER CASE.

  ENDMETHOD.


  METHOD include_hash.

    DATA lv_text  TYPE string.
    DATA lv_lines TYPE i.
    DATA lv_found TYPE abap_bool.
    DATA lv_ban   TYPE abap_bool.

    read_include( EXPORTING iv_include     = iv_include
                  IMPORTING ev_text        = lv_text
                            ev_lines       = lv_lines
                            ev_found       = lv_found
                            ev_banner_only = lv_ban ).
    IF lv_found = abap_true AND lv_lines > 0.
      rv_hash = hash_text( lv_text ).
    ENDIF.

  ENDMETHOD.


  METHOD is_supported.

    IF iv_object = 'PROG' OR iv_object = 'CLAS'
       OR iv_object = 'INTF' OR iv_object = 'FUGR'.
      rv_yes = abap_true.
      RETURN.
    ENDIF.

    "dictionary objects (TABL, DTEL, DOMA, ...), as JSON: whatever
    "ZCL_ABAPSYNC_DDIC handles, so a new type there needs no change here
    rv_yes = zcl_abapsync_ddic=>is_ddic_type( iv_object ).
    IF rv_yes = abap_false.
      "transactions, as JSON: whatever ZCL_ABAPSYNC_REPO owns outright
      rv_yes = zcl_abapsync_repo=>is_repo_type( iv_object ).
    ENDIF.

  ENDMETHOD.


  METHOD list_package.

    DATA lo_in      TYPE REF TO zif_ajson.
    DATA lo_out     TYPE REF TO zif_ajson.
    DATA lv_pkg     TYPE devclass.
    DATA lv_pkg_s   TYPE string.
    DATA lv_sub     TYPE abap_bool.
    DATA lt_types   TYPE string_table.
    DATA lv_type    TYPE string.
    DATA lt_pkgs    TYPE string_table.
    DATA lv_p       TYPE string.
    DATA lt_rng     TYPE RANGE OF devclass.
    DATA ls_rng     LIKE LINE OF lt_rng.
    DATA lt_tadir   TYPE tt_tadir.
    DATA ls_tadir   TYPE ty_tadir.
    DATA ls_result  TYPE ty_list_result.
    DATA ls_obj     TYPE ty_object.
    DATA lt_parts   TYPE tt_part.
    DATA ls_part    TYPE ty_part.
    DATA ls_meta    TYPE ty_part_meta.
    DATA ls_skip    TYPE ty_skip.
    DATA lv_count   TYPE i.
    DATA lv_msg     TYPE string.
    DATA lv_name    TYPE string.
    DATA lv_obj     TYPE string.

    FIELD-SYMBOLS <ls_skip> TYPE ty_skip.

    lo_in = zcl_ajson=>parse( iv_input ).

    lv_pkg_s = lo_in->get_string( '/package' ).
    TRANSLATE lv_pkg_s TO UPPER CASE.
    lv_pkg = lv_pkg_s.

    "--- namespace guard: custom (Z/Y) or local ($) packages only.
    "    Objects inside are still checked with CHECK_CUSTOM below.
    IF lv_pkg IS INITIAL OR NOT ( lv_pkg CP 'Z*' OR lv_pkg CP 'Y*' OR lv_pkg CP '$*' ).
      rv_json = error_json( 'Package must start with Z, Y or $.' ).
      RETURN.
    ENDIF.

    SELECT SINGLE devclass FROM tdevc INTO lv_pkg WHERE devclass = lv_pkg.
    IF sy-subrc <> 0.
      CONCATENATE 'Package' lv_pkg_s 'does not exist.' INTO lv_msg SEPARATED BY space.
      rv_json = error_json( lv_msg ).
      RETURN.
    ENDIF.

*   the package's code must be readable (Z_AI_SCOPE, 23.10.2026)
    IF zcl_ai_auth=>check_package( lv_pkg ) = abap_false.
      lv_msg = zcl_ai_auth=>last_reason( ).
      rv_json = error_json( lv_msg ).
      RETURN.
    ENDIF.

    lv_sub = abap_true.
    IF lo_in->exists( '/subpackages' ) = abap_true.
      lv_sub = lo_in->get_boolean( '/subpackages' ).
    ENDIF.

    IF lo_in->exists( '/types' ) = abap_true.
      lt_types = lo_in->array_to_string_table( '/types' ).
      LOOP AT lt_types INTO lv_type.
        TRANSLATE lv_type TO UPPER CASE.
        MODIFY lt_types FROM lv_type.
      ENDLOOP.
    ENDIF.

    "--- package tree
    lt_pkgs = collect_packages( iv_root = lv_pkg iv_sub = lv_sub ).

    ls_rng-sign   = 'I'.
    ls_rng-option = 'EQ'.
    LOOP AT lt_pkgs INTO lv_p.
      ls_rng-low = lv_p.
      APPEND ls_rng TO lt_rng.
    ENDLOOP.

    "$TMP is shared by every developer: only the caller's own objects
    IF lv_pkg = '$TMP'.
      SELECT object obj_name devclass FROM tadir
        INTO TABLE lt_tadir
        WHERE pgmid    = 'R3TR'
          AND devclass = lv_pkg
          AND author   = sy-uname
          AND delflag  = space.
    ELSE.
      SELECT object obj_name devclass FROM tadir
        INTO TABLE lt_tadir
        WHERE pgmid    = 'R3TR'
          AND devclass IN lt_rng
          AND delflag  = space.
    ENDIF.

    SORT lt_tadir BY object obj_name.

    ls_result-package     = lv_pkg_s.
    ls_result-subpackages = lv_sub.
    ls_result-hash_alg    = c_hash_alg.
    ls_result-packages    = lt_pkgs.

    LOOP AT lt_tadir INTO ls_tadir.

      lv_obj  = ls_tadir-object.
      lv_name = ls_tadir-obj_name.

      "--- unsupported type, filtered-out type, or not custom: count and skip
      CLEAR lv_count.
      IF is_supported( lv_obj ) = abap_false.
        lv_count = 1.
      ELSEIF lt_types IS NOT INITIAL.
        READ TABLE lt_types WITH KEY table_line = lv_obj TRANSPORTING NO FIELDS.
        IF sy-subrc <> 0.
          lv_count = 1.
        ENDIF.
      ENDIF.
      IF lv_count = 0 AND zcl_abapmcp_tools=>check_custom( lv_name ) = abap_false.
        lv_count = 1.
      ENDIF.

      IF lv_count = 1.
        READ TABLE ls_result-skipped ASSIGNING <ls_skip> WITH KEY object = lv_obj.
        IF sy-subrc = 0.
          <ls_skip>-count = <ls_skip>-count + 1.
        ELSE.
          ls_skip-object = lv_obj.
          ls_skip-count  = 1.
          APPEND ls_skip TO ls_result-skipped.
        ENDIF.
        CONTINUE.
      ENDIF.

      IF lines( ls_result-objects ) >= c_max_objects.
        rv_json = error_json( 'More than 3000 objects - narrow the pull with types or subpackages=false.' ).
        RETURN.
      ENDIF.

      CLEAR ls_obj.
      ls_obj-object  = lv_obj.
      ls_obj-name    = lv_name.
      ls_obj-package = ls_tadir-devclass.

      get_parts( EXPORTING iv_object = lv_obj iv_name = lv_name
                 IMPORTING et_parts  = lt_parts ).

      LOOP AT lt_parts INTO ls_part.
        ls_meta-part    = ls_part-part.
        ls_meta-include = ls_part-include.
        ls_meta-lines   = ls_part-lines.
        ls_meta-hash    = ls_part-hash.
        APPEND ls_meta TO ls_obj-parts.
      ENDLOOP.

      APPEND ls_obj TO ls_result-objects.

    ENDLOOP.

    ls_result-object_count = lines( ls_result-objects ).

    lo_out = zcl_ajson=>create_empty( ).
    lo_out->set( iv_path = '/' iv_val = ls_result ).
    rv_json = lo_out->stringify( ).

  ENDMETHOD.


  METHOD read_include.
    "Source is joined with LF and ends with one LF. The CLI writes that
    "text to disk unchanged, so the hash below describes the file.

    DATA lt_src  TYPE string_table.
    DATA lv_line TYPE string.
    DATA lv_prog TYPE progname.

    CLEAR: ev_text, ev_lines, ev_found.
    ev_banner_only = abap_true.

    lv_prog = iv_include.
    READ REPORT lv_prog INTO lt_src.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    ev_found = abap_true.
    ev_lines = lines( lt_src ).
    IF ev_lines = 0.
      RETURN.
    ENDIF.

    LOOP AT lt_src INTO lv_line.
      IF lv_line IS NOT INITIAL AND lv_line(1) <> '*'.
        ev_banner_only = abap_false.
        EXIT.
      ENDIF.
    ENDLOOP.

    CONCATENATE LINES OF lt_src INTO ev_text
      SEPARATED BY cl_abap_char_utilities=>newline.
    CONCATENATE ev_text cl_abap_char_utilities=>newline INTO ev_text.

  ENDMETHOD.


ENDCLASS.
