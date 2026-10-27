CLASS zcl_abapsync_check DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.
*--------------------------------------------------------------------*
* Title       : ZCL_ABAPSYNC_CHECK - abapsync: syntax check before
*               activation
* Type        : Class (called by ZCL_ABAPSYNC_WRITE, read-only)
* Frequency   : On demand - once per class in an 'abapsync push'
* Description : Checks the syntax of a class the way activation will
*               compile it - the inactive version of every include that
*               has one, the active version of the rest - so the writer
*               can refuse to activate a broken class. SAP's mass
*               activation activates a class whose syntax check fails;
*               that took /sap/bc/mcp down on 09.10.2026.
*--------------------------------------------------------------------*
*& HOW
*& The class pool's main program (<class padded with = to 30>CP) is
*& read, and every INCLUDE of one of the class's own includes is
*& replaced by that include's source - recursively, so ...CL can pull
*& in ...CCDEF / ...CCIMP / ...CCAU - and "include methods." by every
*& method include. SYNTAX-CHECK runs on the result; an error is mapped
*& back to its include and line. Includes of other objects stay as
*& INCLUDE statements; the syntax check reads those itself.
*&
*& READ-ONLY: READ REPORT and SYNTAX-CHECK, nothing is written.
*& NW 7.02 syntax only.
*&---------------------------------------------------------------------*

    CONSTANTS c_version TYPE string VALUE '1.1.0'.

*   ex_ok      abap_false only for a real syntax error
*   ex_checked abap_false when the check could not run (no main program,
*              unexpected layout) - ex_ok is then true, the caller
*              decides; ex_message says why
    CLASS-METHODS class_syntax
      IMPORTING im_class   TYPE string
      EXPORTING ex_ok      TYPE abap_bool
                ex_checked TYPE abap_bool
                ex_message TYPE string.

*   One program part (REPS: main program or include) as activation will
*   compile it - an include through its main program. Same results as
*   CLASS_SYNTAX. 1.1.0, 11.10.2026.
    CLASS-METHODS program_syntax
      IMPORTING im_include TYPE string
      EXPORTING ex_ok      TYPE abap_bool
                ex_checked TYPE abap_bool
                ex_message TYPE string.

protected section.
*"* protected components of class ZCL_ABAPSYNC_CHECK
*"* do not include other source files here!!!

  PRIVATE SECTION.

    TYPES: BEGIN OF t_origin,
             include TYPE progname,
             line    TYPE i,
           END OF t_origin,
           t_origin_tab TYPE STANDARD TABLE OF t_origin WITH DEFAULT KEY.

    CONSTANTS c_max_depth TYPE i VALUE 4.

    CLASS-METHODS expand
      IMPORTING im_include TYPE progname
                im_prefix  TYPE string
                im_class   TYPE seoclsname
                im_depth   TYPE i
      CHANGING  ch_source  TYPE string_table
                ch_origin  TYPE t_origin_tab.

*   Like EXPAND, for programs: custom includes replaced by their source.
    CLASS-METHODS expand_custom
      IMPORTING im_include TYPE progname
                im_depth   TYPE i
      CHANGING  ch_source  TYPE string_table
                ch_origin  TYPE t_origin_tab.

    CLASS-METHODS read_source
      IMPORTING im_include      TYPE progname
      RETURNING VALUE(ex_lines) TYPE string_table.

ENDCLASS.


CLASS zcl_abapsync_check IMPLEMENTATION.

  METHOD class_syntax.
*&---------------------------------------------------------------------*
*& The whole class, flattened, through SYNTAX-CHECK.
*&---------------------------------------------------------------------*

    DATA lv_class  TYPE seoclsname.
    DATA lv_cp     TYPE progname.
    DATA lv_prefix TYPE string.
    DATA li_src    TYPE string_table.
    DATA li_origin TYPE t_origin_tab.
    DATA lw_origin TYPE t_origin.
    DATA lv_msg    TYPE string.
    DATA lv_line   TYPE i.
    DATA lv_word   TYPE string.
    DATA lv_ln     TYPE string.
    DATA lv_where  TYPE string.
    DATA lx_root   TYPE REF TO cx_root.

    ex_ok      = abap_true.
    ex_checked = abap_false.
    CLEAR ex_message.

    lv_class = im_class.
    TRANSLATE lv_class TO UPPER CASE.
*   include names: the class name padded with '=' to 30 characters
    lv_prefix = lv_class.
    WHILE strlen( lv_prefix ) < 30.
      CONCATENATE lv_prefix '=' INTO lv_prefix.
    ENDWHILE.
    CONCATENATE lv_prefix 'CP' INTO lv_cp.

    TRY.
        expand( EXPORTING im_include = lv_cp
                          im_prefix  = lv_prefix
                          im_class   = lv_class
                          im_depth   = 0
                CHANGING  ch_source  = li_src
                          ch_origin  = li_origin ).
        IF li_src IS INITIAL.
          CONCATENATE 'Main program' lv_cp 'not found - syntax not checked.'
            INTO ex_message SEPARATED BY space.
          RETURN.
        ENDIF.

        SYNTAX-CHECK FOR li_src MESSAGE lv_msg LINE lv_line WORD lv_word
          PROGRAM lv_cp.
        CASE sy-subrc.
          WHEN 0.
            ex_checked = abap_true.
          WHEN 4.
            ex_checked = abap_true.
            ex_ok      = abap_false.
*           where the error is, in the include it came from
            CLEAR lw_origin.
            READ TABLE li_origin INTO lw_origin INDEX lv_line.
            IF sy-subrc = 0.
              lv_ln = lw_origin-line.
              CONDENSE lv_ln.
              CONCATENATE lw_origin-include ` line ` lv_ln INTO lv_where.
            ELSE.
              lv_where = lv_class.
            ENDIF.
            CONCATENATE `Syntax error in ` lv_where `: ` lv_msg INTO ex_message.
          WHEN OTHERS.
            ex_message = 'The syntax check could not run - syntax not checked.'.
        ENDCASE.
      CATCH cx_root INTO lx_root.
        ex_ok      = abap_true.
        ex_checked = abap_false.
        ex_message = lx_root->get_text( ).
        CONCATENATE `Syntax check could not run: ` ex_message INTO ex_message.
    ENDTRY.

  ENDMETHOD.


  METHOD expand.
*&---------------------------------------------------------------------*
*& im_include's source into ch_source, each line with its origin. The
*& class's own includes (name starts with im_prefix) are replaced by
*& their source, "include methods." by every method include; any other
*& line - including INCLUDE TYPE / STRUCTURE - is kept as it is.
*&---------------------------------------------------------------------*

    DATA li_lines  TYPE string_table.
    DATA lv_line   TYPE string.
    DATA lv_up     TYPE string.
    DATA lv_name   TYPE string.
    DATA lv_rest   TYPE string.
    DATA lv_pat    TYPE string.
    DATA lv_inc    TYPE progname.
    DATA lv_idx    TYPE i.
    DATA lv_depth  TYPE i.
    DATA lw_origin TYPE t_origin.
    DATA li_meth   TYPE seop_methods_w_include.
    DATA lw_meth   LIKE LINE OF li_meth.

    IF im_depth > c_max_depth.
      RETURN.
    ENDIF.
    lv_depth = im_depth + 1.
    CONCATENATE im_prefix '*' INTO lv_pat.

    li_lines = read_source( im_include ).

    LOOP AT li_lines INTO lv_line.
      lv_idx = sy-tabix.
      lv_up = lv_line.
      CONDENSE lv_up.
      TRANSLATE lv_up TO UPPER CASE.

      IF lv_up CP 'INCLUDE *' AND lv_up CS '.'
         AND NOT ( lv_up CP 'INCLUDE TYPE *' OR lv_up CP 'INCLUDE STRUCTURE *' ).
        lv_name = lv_up+8.
        SPLIT lv_name AT '.' INTO lv_name lv_rest.
        CONDENSE lv_name.

        IF lv_name = 'METHODS'.
          li_meth = cl_oo_classname_service=>get_all_method_includes( im_class ).
          LOOP AT li_meth INTO lw_meth.
            lv_inc = lw_meth-incname.
            expand( EXPORTING im_include = lv_inc
                              im_prefix  = im_prefix
                              im_class   = im_class
                              im_depth   = lv_depth
                    CHANGING  ch_source  = ch_source
                              ch_origin  = ch_origin ).
          ENDLOOP.
          CONTINUE.
        ELSEIF lv_name CP lv_pat.
          lv_inc = lv_name.
          expand( EXPORTING im_include = lv_inc
                            im_prefix  = im_prefix
                            im_class   = im_class
                            im_depth   = lv_depth
                  CHANGING  ch_source  = ch_source
                            ch_origin  = ch_origin ).
          CONTINUE.
        ENDIF.
      ENDIF.

      APPEND lv_line TO ch_source.
      lw_origin-include = im_include.
      lw_origin-line    = lv_idx.
      APPEND lw_origin TO ch_origin.
    ENDLOOP.

  ENDMETHOD.


  METHOD expand_custom.
*&---------------------------------------------------------------------*
*& im_include's source into ch_source, each line with its origin.
*& INCLUDE statements of custom includes (Z*, Y*, LZ*, LY*) are replaced
*& by their source - inactive version first, as activation compiles it;
*& standard includes and INCLUDE TYPE / STRUCTURE stay as they are and
*& the syntax check reads them itself.
*&---------------------------------------------------------------------*

    DATA li_lines  TYPE string_table.
    DATA lv_line   TYPE string.
    DATA lv_up     TYPE string.
    DATA lv_name   TYPE string.
    DATA lv_rest   TYPE string.
    DATA lv_inc    TYPE progname.
    DATA lv_idx    TYPE i.
    DATA lv_depth  TYPE i.
    DATA lw_origin TYPE t_origin.

    IF im_depth > c_max_depth.
      RETURN.
    ENDIF.
    lv_depth = im_depth + 1.

    li_lines = read_source( im_include ).

    LOOP AT li_lines INTO lv_line.
      lv_idx = sy-tabix.
      lv_up = lv_line.
      CONDENSE lv_up.
      TRANSLATE lv_up TO UPPER CASE.

      IF lv_up CP 'INCLUDE *' AND lv_up CS '.'
         AND NOT ( lv_up CP 'INCLUDE TYPE *' OR lv_up CP 'INCLUDE STRUCTURE *' ).
        lv_name = lv_up+8.
        SPLIT lv_name AT '.' INTO lv_name lv_rest.
        CONDENSE lv_name.
        IF lv_name CP 'Z*' OR lv_name CP 'Y*' OR lv_name CP 'LZ*' OR lv_name CP 'LY*'.
          lv_inc = lv_name.
          expand_custom( EXPORTING im_include = lv_inc
                                   im_depth   = lv_depth
                         CHANGING  ch_source  = ch_source
                                   ch_origin  = ch_origin ).
          CONTINUE.
        ENDIF.
      ENDIF.

      APPEND lv_line TO ch_source.
      lw_origin-include = im_include.
      lw_origin-line    = lv_idx.
      APPEND lw_origin TO ch_origin.
    ENDLOOP.

  ENDMETHOD.


  METHOD program_syntax.
*&---------------------------------------------------------------------*
*& One program part of a push (REPS = a main program or an include)
*& through SYNTAX-CHECK, as activation will compile it. An include is
*& checked through its main program (D010INC). Custom includes are read
*& in their inactive version (what activation compiles), standard ones
*& are left to the syntax check. Without this, a program with an error
*& made RS_WORKING_OBJECTS_ACTIVATE ask "activate anyway?" - a popup
*& that dumps over HTTP (DYNPRO_SEND_IN_BACKGROUND, 11.10.2026).
*&---------------------------------------------------------------------*

    DATA lv_inc    TYPE progname.
    DATA lv_main   TYPE progname.
    DATA lv_subc   TYPE progdir-subc.
    DATA li_master TYPE STANDARD TABLE OF d010inc-master.
    DATA li_src    TYPE string_table.
    DATA li_origin TYPE t_origin_tab.
    DATA lw_origin TYPE t_origin.
    DATA lv_msg    TYPE string.
    DATA lv_line   TYPE i.
    DATA lv_word   TYPE string.
    DATA lv_ln     TYPE string.
    DATA lv_where  TYPE string.
    DATA lx_root   TYPE REF TO cx_root.

    ex_ok      = abap_true.
    ex_checked = abap_false.
    CLEAR ex_message.

    lv_inc = im_include.
    TRANSLATE lv_inc TO UPPER CASE.

    TRY.
*       program type: the inactive version first (a new program has no
*       active one yet), then the active one
        SELECT SINGLE subc FROM progdir INTO lv_subc
          WHERE name = lv_inc AND state = 'I'.
        IF sy-subrc <> 0.
          SELECT SINGLE subc FROM progdir INTO lv_subc
            WHERE name = lv_inc AND state = 'A'.
        ENDIF.
        IF sy-subrc <> 0.
          CONCATENATE lv_inc 'not found in PROGDIR - syntax not checked.'
            INTO ex_message SEPARATED BY space.
          RETURN.
        ENDIF.

        IF lv_subc = 'I'.
          SELECT master FROM d010inc INTO TABLE li_master UP TO 1 ROWS
            WHERE include = lv_inc.
          READ TABLE li_master INTO lv_main INDEX 1.
          IF sy-subrc <> 0.
            CONCATENATE 'Include' lv_inc 'is not used by a main program yet - syntax not checked.'
              INTO ex_message SEPARATED BY space.
            RETURN.
          ENDIF.
        ELSE.
          lv_main = lv_inc.
        ENDIF.

        expand_custom( EXPORTING im_include = lv_main
                                 im_depth   = 0
                       CHANGING  ch_source  = li_src
                                 ch_origin  = li_origin ).
        IF li_src IS INITIAL.
          CONCATENATE 'No source for' lv_main '- syntax not checked.'
            INTO ex_message SEPARATED BY space.
          RETURN.
        ENDIF.

        SYNTAX-CHECK FOR li_src MESSAGE lv_msg LINE lv_line WORD lv_word
          PROGRAM lv_main.
        CASE sy-subrc.
          WHEN 0.
            ex_checked = abap_true.
          WHEN 4.
            ex_checked = abap_true.
            ex_ok      = abap_false.
            CLEAR lw_origin.
            READ TABLE li_origin INTO lw_origin INDEX lv_line.
            IF sy-subrc = 0.
              lv_ln = lw_origin-line.
              CONDENSE lv_ln.
              CONCATENATE lw_origin-include ` line ` lv_ln INTO lv_where.
            ELSE.
              lv_where = lv_main.
            ENDIF.
            CONCATENATE `Syntax error in ` lv_where `: ` lv_msg INTO ex_message.
          WHEN OTHERS.
            ex_message = 'The syntax check could not run - syntax not checked.'.
        ENDCASE.
      CATCH cx_root INTO lx_root.
        ex_ok      = abap_true.
        ex_checked = abap_false.
        ex_message = lx_root->get_text( ).
        CONCATENATE `Syntax check could not run: ` ex_message INTO ex_message.
    ENDTRY.

  ENDMETHOD.


  METHOD read_source.
*&---------------------------------------------------------------------*
*& The inactive version when there is one - that is what activation
*& will compile - else the active one.
*&---------------------------------------------------------------------*

    READ REPORT im_include INTO ex_lines STATE 'I'.
    IF sy-subrc <> 0 OR ex_lines IS INITIAL.
      READ REPORT im_include INTO ex_lines.
    ENDIF.

  ENDMETHOD.


ENDCLASS.
