*--------------------------------------------------------------------*
* Title       : ZAI_TOOL_GRP_SEED - seed the AI tool group mapping
* Type        : Report (customizing seed)
* Frequency   : Once per system and client, after import
* Description : Fills ZAI_TOOL_GRP with every AI tool and its tool
*               group, the mapping that ZCL_AI_AUTH=>CHECK_TOOL uses
*               for authorization object Z_AI_TOOL. Existing rows are
*               only overwritten with "Overwrite" ticked, so groups
*               changed in SM30 survive a re-run.
*               Test run (default) lists what would change.
*               Needs Z_AI_ADM function TOOLSW (ZCL_AI_AUTH).
*--------------------------------------------------------------------*
REPORT zai_tool_grp_seed.

TYPES: BEGIN OF t_seed,
         tool_name  TYPE zai_tool,
         tool_group TYPE zai_tgrp,
       END OF t_seed.

DATA: i_seed TYPE STANDARD TABLE OF t_seed,
      w_seed TYPE t_seed.

PARAMETERS: p_test AS CHECKBOX DEFAULT 'X',
            p_over AS CHECKBOX DEFAULT space.

START-OF-SELECTION.

  IF zcl_ai_auth=>check_admin( zcl_ai_auth=>c_adm-toolsw ) = abap_false.
    MESSAGE 'Not authorised for administration function TOOLSW (Z_AI_ADM).' TYPE 'E'.
  ENDIF.

  PERFORM fill_seed.
  PERFORM apply_seed.

*&---------------------------------------------------------------------*
*&      Form  FILL_SEED
*&---------------------------------------------------------------------*
*       Every tool of /sap/bc/mcp with its group - see
*       docs/security.md, section Tool groups.
*----------------------------------------------------------------------*
FORM fill_seed.

  PERFORM add USING 'sap_tcode_info'           'CONFIG'.
  PERFORM add USING 'sap_find_config'          'CONFIG'.
  PERFORM add USING 'sap_read_config'          'CONFIG'.
  PERFORM add USING 'sap_get_ddic'             'DDIC'.
  PERFORM add USING 'sap_find_field'           'DDIC'.
  PERFORM add USING 'sap_message_info'         'DDIC'.
  PERFORM add USING 'sap_auth_object_info'     'DDIC'.
  PERFORM add USING 'sap_whoami'               'DDIC'.
  PERFORM add USING 'sap_search_objects'       'SEARCH'.
  PERFORM add USING 'sap_where_used'           'SEARCH'.
  PERFORM add USING 'sap_get_source'           'CODE'.
  PERFORM add USING 'sap_get_raw_source'       'CODE'.
  PERFORM add USING 'sap_search_source'        'CODE'.
  PERFORM add USING 'sap_list_package'         'CODE'.
  PERFORM add USING 'sap_transport_search'     'TRANSP'.
  PERFORM add USING 'sap_object_transports'    'TRANSP'.
  PERFORM add USING 'sap_object_history'       'TRANSP'.
  PERFORM add USING 'sap_transport_impact'     'TRANSP'.
  PERFORM add USING 'sap_open_requests'        'REVIEW'.
  PERFORM add USING 'sap_get_dumps'            'DIAG'.
  PERFORM add USING 'sap_bw_datasources'       'BW'.
  PERFORM add USING 'sap_bw_datasource_info'   'BW'.
  PERFORM add USING 'sap_bw_table_datasources' 'BW'.

ENDFORM.                    " FILL_SEED

*&---------------------------------------------------------------------*
*&      Form  ADD
*&---------------------------------------------------------------------*
FORM add USING pv_tool  TYPE csequence
               pv_group TYPE csequence.

  CLEAR w_seed.
  w_seed-tool_name  = pv_tool.
  w_seed-tool_group = pv_group.
  APPEND w_seed TO i_seed.

ENDFORM.                    " ADD

*&---------------------------------------------------------------------*
*&      Form  APPLY_SEED
*&---------------------------------------------------------------------*
FORM apply_seed.

  DATA: lw_row    TYPE zai_tool_grp,
        lw_old    TYPE zai_tool_grp,
        lv_action TYPE c LENGTH 10,
        lv_ins    TYPE i,
        lv_upd    TYPE i,
        lv_keep   TYPE i.

  WRITE: / 'Tool', 42 'Group', 54 'Action'.
  ULINE.

  LOOP AT i_seed INTO w_seed.
    CLEAR lw_row.
    lw_row-tool_name  = w_seed-tool_name.
    lw_row-tool_group = w_seed-tool_group.
    lw_row-active     = abap_true.

    SELECT SINGLE * FROM zai_tool_grp INTO lw_old
      WHERE tool_name = lw_row-tool_name.
    IF sy-subrc <> 0.
      lv_action = 'INSERT'.
      lv_ins = lv_ins + 1.
      IF p_test = space.
        INSERT zai_tool_grp FROM lw_row.
      ENDIF.
    ELSEIF lw_old-tool_group = lw_row-tool_group AND lw_old-active = lw_row-active.
      lv_action = 'same'.
      lv_keep = lv_keep + 1.
    ELSEIF p_over = abap_true.
      lv_action = 'UPDATE'.
      lv_upd = lv_upd + 1.
      IF p_test = space.
        UPDATE zai_tool_grp FROM lw_row.
      ENDIF.
    ELSE.
      lv_action = 'kept'.
      lv_keep = lv_keep + 1.
    ENDIF.

    WRITE: / lw_row-tool_name, 42 lw_row-tool_group, 54 lv_action.
  ENDLOOP.

  IF p_test = space.
    COMMIT WORK.
  ENDIF.

  ULINE.
  WRITE: / 'Inserted:', lv_ins, 'Updated:', lv_upd, 'Unchanged:', lv_keep.
  IF p_test = abap_true.
    WRITE: / 'Test run - nothing was saved.'.
  ENDIF.

ENDFORM.                    " APPLY_SEED
