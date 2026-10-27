CLASS zcl_abapsync_post DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.
*--------------------------------------------------------------------*
* Title       : ZCL_ABAPSYNC_POST - abapsync: after a class is active
* Type        : Class (called by ZCL_ABAPSYNC_WRITE and report
*               ZABAPSYNC_DESCR_FILL)
* Frequency   : On demand - once per class activated by 'abapsync push'
* Description : Work that follows the activation of a class. Today: the
*               SE24 short description of every method that has none,
*               taken from the method's own comment. A class written as
*               source - by push, paste or abapGit - never gets them,
*               as on 7.02 only the form-based editor maintains them.
*--------------------------------------------------------------------*
*& WHERE THE DESCRIPTION COMES FROM
*&   1. the comment block directly above the method's declaration
*&      (METHODS / CLASS-METHODS in the public, protected or private
*&      section) - unless it only documents parameters (im_/ex_ ...)
*&   2. else the first comment lines inside the method itself
*& Its first sentence, at most 60 characters (SEOCOMPOTX-DESCRIPT).
*& Separator lines (*&----, *---) end a block.
*&
*& WHAT IS WRITTEN
*& SEOCOMPOTX in the class's original language, only where the text is
*& missing or empty - a description typed in SE24 is never replaced.
*& An existing empty row is updated, a missing one inserted; nothing
*& is deleted (abapGit keeps a row per component so the VSEO* views
*& stay intact). The class itself is in the push's request as R3TR
*& CLAS, so the texts travel with it.
*&
*& NW 7.02 syntax only.
*&---------------------------------------------------------------------*

    CONSTANTS c_version TYPE string VALUE '1.0.0'.

*   After a class of a push became active; ex_message says what was
*   done, empty when there was nothing to do.
    CLASS-METHODS class_activated
      IMPORTING im_class   TYPE string
      EXPORTING ex_message TYPE string.

*   Method descriptions from the source comments, where SE24 has none.
*   With im_test nothing is written - ex_list shows what would be.
    CLASS-METHODS fill_descriptions
      IMPORTING im_class  TYPE string
                im_test   TYPE abap_bool DEFAULT abap_false
      EXPORTING ex_filled TYPE i
                ex_list   TYPE string_table.

protected section.
*"* protected components of class ZCL_ABAPSYNC_POST
*"* do not include other source files here!!!

  PRIVATE SECTION.

    CONSTANTS c_max_descr TYPE i VALUE 60.

    CLASS-METHODS decl_comment
      IMPORTING im_lines       TYPE string_table
                im_method      TYPE seocmpname
      RETURNING VALUE(ex_text) TYPE string.

    CLASS-METHODS impl_comment
      IMPORTING im_include     TYPE progname
      RETURNING VALUE(ex_text) TYPE string.

    CLASS-METHODS block_text
      IMPORTING im_block       TYPE string_table
      RETURNING VALUE(ex_text) TYPE string.

    CLASS-METHODS comment_text
      IMPORTING im_line        TYPE string
      RETURNING VALUE(ex_text) TYPE string.

    CLASS-METHODS shorten
      IMPORTING im_text        TYPE string
      RETURNING VALUE(ex_text) TYPE string.

ENDCLASS.


CLASS zcl_abapsync_post IMPLEMENTATION.

  METHOD block_text.
*&---------------------------------------------------------------------*
*& First sentence of a comment block, its lines joined.
*&---------------------------------------------------------------------*

    DATA lv_line TYPE string.
    DATA lv_text TYPE string.
    DATA lv_off  TYPE i.
    DATA lv_len  TYPE i.

    LOOP AT im_block INTO lv_line.
      lv_text = comment_text( lv_line ).
      IF lv_text IS INITIAL.
        CONTINUE.
      ENDIF.
      IF ex_text IS INITIAL.
        ex_text = lv_text.
      ELSE.
        CONCATENATE ex_text lv_text INTO ex_text SEPARATED BY space.
      ENDIF.
*     enough for one sentence
      IF ex_text CS `. ` OR strlen( ex_text ) > 120.
        EXIT.
      ENDIF.
    ENDLOOP.

    FIND FIRST OCCURRENCE OF `. ` IN ex_text MATCH OFFSET lv_off.
    IF sy-subrc = 0.
      ex_text = ex_text(lv_off).
    ENDIF.
    lv_len = strlen( ex_text ).
    IF lv_len > 0.
      lv_len = lv_len - 1.
      IF ex_text+lv_len(1) = '.' OR ex_text+lv_len(1) = ':'.
        ex_text = ex_text(lv_len).
      ENDIF.
    ENDIF.

  ENDMETHOD.


  METHOD class_activated.
*&---------------------------------------------------------------------*
*& Everything that follows the activation of one class.
*&---------------------------------------------------------------------*

    DATA lv_filled TYPE i.
    DATA li_list   TYPE string_table.
    DATA lv_num    TYPE c LENGTH 10.

    CLEAR ex_message.
    fill_descriptions( EXPORTING im_class  = im_class
                       IMPORTING ex_filled = lv_filled
                                 ex_list   = li_list ).
    IF lv_filled > 0.
      lv_num = lv_filled.
      CONDENSE lv_num.
      CONCATENATE lv_num `method description(s) filled from the source comments.`
        INTO ex_message SEPARATED BY space.
    ENDIF.

  ENDMETHOD.


  METHOD comment_text.
*&---------------------------------------------------------------------*
*& The words of a comment line, without " * & and blanks in front; ''
*& for a separator line (only - = * & characters) or a blank comment.
*&---------------------------------------------------------------------*

    DATA lv_len TYPE i.

    ex_text = im_line.
    CONDENSE ex_text.
    DO 10 TIMES.
      lv_len = strlen( ex_text ).
      IF lv_len = 0.
        EXIT.
      ENDIF.
      IF ex_text(1) = '"' OR ex_text(1) = '*' OR ex_text(1) = '&'.
        ex_text = ex_text+1.
        CONDENSE ex_text.
      ELSE.
        EXIT.
      ENDIF.
    ENDDO.
    IF ex_text CO `-=*& `.
      CLEAR ex_text.
    ENDIF.

  ENDMETHOD.


  METHOD decl_comment.
*&---------------------------------------------------------------------*
*& The comment block directly above "METHODS im_method" or
*& "CLASS-METHODS im_method"; a blank line or a separator ends it.
*& A block that only documents parameters (im_..., ex_...) is no
*& description of the method - '' then, so the method's own comment
*& is used.
*&---------------------------------------------------------------------*

    DATA lv_line  TYPE string.
    DATA lv_up    TYPE string.
    DATA lv_kw    TYPE string.
    DATA lv_name  TYPE string.
    DATA lv_rest  TYPE string.
    DATA lv_idx   TYPE i.
    DATA lv_j     TYPE i.
    DATA lv_prev  TYPE string.
    DATA lv_c     TYPE string.
    DATA lv_first TYPE string.
    DATA li_block TYPE string_table.

    LOOP AT im_lines INTO lv_line.
      lv_idx = sy-tabix.
      lv_up = lv_line.
      CONDENSE lv_up.
      TRANSLATE lv_up TO UPPER CASE.
      IF NOT ( lv_up CP 'METHODS *' OR lv_up CP 'CLASS-METHODS *' ).
        CONTINUE.
      ENDIF.
      SPLIT lv_up AT space INTO lv_kw lv_name lv_rest.
      REPLACE ALL OCCURRENCES OF '.' IN lv_name WITH ''.
      REPLACE ALL OCCURRENCES OF ',' IN lv_name WITH ''.
      IF lv_name <> im_method.
        CONTINUE.
      ENDIF.

*     up from the declaration while the lines are comments
      CLEAR li_block.
      lv_j = lv_idx - 1.
      WHILE lv_j > 0.
        READ TABLE im_lines INTO lv_prev INDEX lv_j.
        lv_c = lv_prev.
        CONDENSE lv_c.
        IF lv_c IS INITIAL.
          EXIT.
        ENDIF.
        IF lv_c(1) <> '"' AND lv_c(1) <> '*'.
          EXIT.
        ENDIF.
        IF comment_text( lv_prev ) IS INITIAL.
          EXIT.
        ENDIF.
        INSERT lv_prev INTO li_block INDEX 1.
        lv_j = lv_j - 1.
      ENDWHILE.

      ex_text = block_text( li_block ).
*     parameter documentation, not a description of the method
      lv_first = ex_text.
      TRANSLATE lv_first TO UPPER CASE.
      IF lv_first CP 'IM_*' OR lv_first CP 'EX_*' OR lv_first CP 'CH_*'
         OR lv_first CP 'IV_*' OR lv_first CP 'EV_*' OR lv_first CP 'RV_*'.
        CLEAR ex_text.
      ENDIF.
      RETURN.
    ENDLOOP.

  ENDMETHOD.


  METHOD fill_descriptions.
*&---------------------------------------------------------------------*
*& Every method of the class without a description gets one from its
*& comment, when it has a comment.
*&---------------------------------------------------------------------*

    TYPES: BEGIN OF lt_tx,
             cmpname  TYPE seocmpname,
             descript TYPE seodescr,
           END OF lt_tx.

    DATA lv_cls    TYPE seoclsname.
    DATA lv_obj    TYPE sobj_name.
    DATA lv_lang   TYPE sy-langu.
    DATA li_meth   TYPE STANDARD TABLE OF seocmpname.
    DATA lv_meth   TYPE seocmpname.
    DATA li_tx     TYPE STANDARD TABLE OF lt_tx.
    DATA lw_tx     TYPE lt_tx.
    DATA lv_exists TYPE abap_bool.
    DATA li_decl   TYPE string_table.
    DATA li_part   TYPE string_table.
    DATA lv_prog   TYPE program.
    DATA lv_inc    TYPE progname.
    DATA lw_key    TYPE seocpdkey.
    DATA lv_text   TYPE string.
    DATA lv_line   TYPE string.
    DATA lw_row    TYPE seocompotx.

    CLEAR: ex_filled, ex_list.
    lv_cls = im_class.
    TRANSLATE lv_cls TO UPPER CASE.

*   the original language holds the descriptions SE24 shows
    lv_obj = lv_cls.
    SELECT SINGLE masterlang FROM tadir INTO lv_lang
      WHERE pgmid = 'R3TR' AND object = 'CLAS' AND obj_name = lv_obj.
    IF sy-subrc <> 0 OR lv_lang IS INITIAL.
      lv_lang = sy-langu.
    ENDIF.

    SELECT cmpname FROM seocompo INTO TABLE li_meth
      WHERE clsname = lv_cls AND cmptype = 1.
    IF li_meth IS INITIAL.
      RETURN.
    ENDIF.
    SELECT cmpname descript FROM seocompotx INTO TABLE li_tx
      WHERE clsname = lv_cls AND langu = lv_lang.
    SORT li_tx BY cmpname.

*   all three sections, for the comments above the declarations
    lv_prog = cl_oo_classname_service=>get_pubsec_name( lv_cls ).
    READ REPORT lv_prog INTO li_part.
    APPEND LINES OF li_part TO li_decl.
    lv_prog = cl_oo_classname_service=>get_prosec_name( lv_cls ).
    READ REPORT lv_prog INTO li_part.
    APPEND LINES OF li_part TO li_decl.
    lv_prog = cl_oo_classname_service=>get_prisec_name( lv_cls ).
    READ REPORT lv_prog INTO li_part.
    APPEND LINES OF li_part TO li_decl.

    LOOP AT li_meth INTO lv_meth.
      lv_exists = abap_false.
      READ TABLE li_tx INTO lw_tx WITH KEY cmpname = lv_meth BINARY SEARCH.
      IF sy-subrc = 0.
        IF lw_tx-descript IS NOT INITIAL.
          CONTINUE.
        ENDIF.
        lv_exists = abap_true.
      ENDIF.

      lv_text = decl_comment( im_lines = li_decl im_method = lv_meth ).
      IF lv_text IS INITIAL.
        CLEAR lw_key.
        lw_key-clsname = lv_cls.
        lw_key-cpdname = lv_meth.
        lv_prog = cl_oo_classname_service=>get_method_include( lw_key ).
        IF lv_prog IS NOT INITIAL.
          lv_inc = lv_prog.
          lv_text = impl_comment( lv_inc ).
        ENDIF.
      ENDIF.
      IF lv_text IS INITIAL.
        CONTINUE.
      ENDIF.
      lv_text = shorten( lv_text ).

      IF im_test = abap_false.
        CLEAR lw_row.
        lw_row-clsname  = lv_cls.
        lw_row-cmpname  = lv_meth.
        lw_row-langu    = lv_lang.
        lw_row-descript = lv_text.
        IF lv_exists = abap_true.
          UPDATE seocompotx SET descript = lw_row-descript
            WHERE clsname = lw_row-clsname
              AND cmpname = lw_row-cmpname
              AND langu   = lw_row-langu.
        ELSE.
          INSERT seocompotx FROM lw_row.
        ENDIF.
        IF sy-subrc <> 0.
          CONTINUE.
        ENDIF.
      ENDIF.

      ex_filled = ex_filled + 1.
      CONCATENATE lv_meth `: ` lv_text INTO lv_line.
      APPEND lv_line TO ex_list.
    ENDLOOP.

  ENDMETHOD.


  METHOD impl_comment.
*&---------------------------------------------------------------------*
*& The first comment lines inside the method, after METHOD x. - up to
*& the first line of code. Separators are skipped here, as the header
*& banner of a method usually starts with one.
*&---------------------------------------------------------------------*

    DATA li_lines TYPE string_table.
    DATA lv_line  TYPE string.
    DATA lv_c     TYPE string.
    DATA lv_text  TYPE string.
    DATA li_block TYPE string_table.

    READ REPORT im_include INTO li_lines.

    LOOP AT li_lines INTO lv_line.
      IF sy-tabix = 1.
        CONTINUE.
      ENDIF.
      lv_c = lv_line.
      CONDENSE lv_c.
      IF lv_c IS INITIAL.
        IF li_block IS NOT INITIAL.
          EXIT.
        ENDIF.
        CONTINUE.
      ENDIF.
      IF lv_c(1) <> '"' AND lv_c(1) <> '*'.
        EXIT.
      ENDIF.
      lv_text = comment_text( lv_line ).
      IF lv_text IS INITIAL.
        IF li_block IS NOT INITIAL.
          EXIT.
        ENDIF.
        CONTINUE.
      ENDIF.
      APPEND lv_line TO li_block.
    ENDLOOP.

    ex_text = block_text( li_block ).

  ENDMETHOD.


  METHOD shorten.
*&---------------------------------------------------------------------*
*& At most c_max_descr characters, cut at a word with "..." when longer.
*&---------------------------------------------------------------------*

    DATA lv_cut TYPE i.
    DATA lv_pos TYPE i.

    ex_text = im_text.
    IF strlen( ex_text ) <= c_max_descr.
      RETURN.
    ENDIF.

    lv_cut = c_max_descr - 3.
    ex_text = ex_text(lv_cut).
*   back to the last blank, if that keeps most of the text
    FIND ALL OCCURRENCES OF ` ` IN ex_text MATCH OFFSET lv_pos.
    IF sy-subrc = 0 AND lv_pos > 40.
      ex_text = ex_text(lv_pos).
    ENDIF.
    CONCATENATE ex_text `...` INTO ex_text.

  ENDMETHOD.


ENDCLASS.
