class ZCL_XTT_XML_BASE definition
  public
  inheriting from ZCL_XTT
  create public .

public section.
  type-pools ABAP .

  types:
    BEGIN OF ts_text_match,
     level TYPE i,
     top   TYPE abap_bool,
     text  TYPE string,
   END OF ts_text_match .
  types:
    tt_text_match TYPE SORTED TABLE OF ts_text_match WITH UNIQUE KEY level top .

  methods CONSTRUCTOR
    importing
      !IO_FILE type ref to ZIF_XTT_FILE
      !IV_BODY_TAG type CSEQUENCE
      !IV_ROW_TAG type CSEQUENCE
      !IV_PATH_IN_ARC type CSEQUENCE optional
      !IV_FILE_FORMAT type I optional
      !IV_FILE_FORMAT_EXT type STRING optional .
  methods GET_RAW
    redefinition .
  methods DOWNLOAD
    redefinition .
  methods MERGE
    redefinition .
protected section.

  data MV_BODY_TAG type STRING .
  data MV_ROW_TAG type STRING .
  data MV_FILE_CONTENT type STRING .
  data MV_VALUE type STRING .
  data MV_PREFIX type STRING .
  methods DO_MERGE
    importing
      !IV_FIRST_LEVEL_IS_TABLE type ABAP_BOOL default ABAP_FALSE
      !IO_REPLACE_BLOCK type ref to ZCL_XTT_REPLACE_BLOCK
    changing
      !CV_CONTENT type STRING .
  methods SPLIT_BY_TAG
    importing
      !IV_TAG type CSEQUENCE
      !IV_TAG_ADD type CSEQUENCE optional
      !IV_BLOCK_NAME type CSEQUENCE
      !IV_FIRST_LEVEL_IS_TABLE type ABAP_BOOL optional
      !IV_FIELD_TYPE type CSEQUENCE optional
    exporting
      !ET_TEXT_MATCH type TT_TEXT_MATCH
    changing
      !CV_BEFORE type CSEQUENCE
      !CV_AFTER type CSEQUENCE
      !CV_MIDDLE type CSEQUENCE .
  methods FIND_BOUNDS
    importing
      !IV_CONTEXT type CSEQUENCE
      !IV_TAG type CSEQUENCE
      !IV_TAG_ADD type CSEQUENCE
      !IV_BLOCK_NAME type CSEQUENCE
      !IV_FIRST_LEVEL_IS_TABLE type ABAP_BOOL
    exporting
      !ET_MATCH type MATCH_RESULT_TAB
      !EV_WITH_TAG type ABAP_BOOL
      !EV_FIRST_MATCH type I
      !EV_LAST_MATCH type I .
  methods ON_MATCH_FOUND
    for event MATCH_FOUND of ZCL_XTT_REPLACE_BLOCK
    importing
      !IV_CONTENT
      !IS_FIELD
      !IV_POS_BEG
      !IV_POS_END .
private section.

  data MV_FILE_FORMAT type I .
  data MV_FILE_FORMAT_EXT type STRING .
  data MV_PATH_IN_ARC type STRING .
  data MO_ZIP type ref to CL_ABAP_ZIP .
ENDCLASS.



CLASS ZCL_XTT_XML_BASE IMPLEMENTATION.


METHOD constructor.
  DATA:
    lv_value TYPE xstring.
  super->constructor( io_file = io_file ).

  " For regex
  mv_body_tag        = iv_body_tag.
  mv_row_tag         = iv_row_tag.
  mv_path_in_arc     = iv_path_in_arc.

  " For download method
  mv_file_format     = iv_file_format.
  mv_file_format_ext = iv_file_format_ext.

  " As text
  IF mv_path_in_arc IS INITIAL.
    io_file->get_content(
    IMPORTING
     ev_as_string = mv_file_content ).
    RETURN.
  ENDIF.

  " Load zip archive from XSTRING
  CREATE OBJECT mo_zip.
  io_file->get_content(
   IMPORTING
    ev_as_xstring = lv_value ).
  mo_zip->load( lv_value ).

  " Get content as a string from file
  zcl_xtt_util=>xml_from_zip(
   EXPORTING
    io_zip   = mo_zip
    iv_name  = mv_path_in_arc
   IMPORTING
    ev_sdoc  = mv_file_content ).
ENDMETHOD.


METHOD download.
  DATA:
    lv_open   TYPE string,
    lv_path   TYPE string,
    lv_no_ext TYPE string.

  " If need saveAs
  lv_open = iv_open.
  IF mv_file_format IS NOT INITIAL AND mv_file_format_ext IS NOT INITIAL.
    lv_open = mc_by_ole.
  ENDIF.

  super->download(
   EXPORTING
     iv_open     = lv_open
     iv_zip      = iv_zip
   CHANGING
     cv_ole_app  = cv_ole_app
     cv_ole_doc  = cv_ole_doc
     cv_fullpath = cv_fullpath ).

  " If opened as OLE
  CHECK lv_open = mc_by_ole.

  " New file name
  zcl_xtt_util=>split_file_path(
    EXPORTING
      iv_fullpath       = cv_fullpath
    IMPORTING
      ev_filename_noext = lv_no_ext
      ev_path           = lv_path ).
  CONCATENATE lv_path lv_no_ext mv_file_format_ext INTO cv_fullpath.

  " Already exist. Add date and time
  IF cl_gui_frontend_services=>file_exist( cv_fullpath ) = abap_true.
    CONCATENATE lv_path lv_no_ext ` ` sy-datum ` ` sy-uzeit `.` mv_file_format_ext INTO cv_fullpath.
  ENDIF.

  CALL METHOD OF cv_ole_doc 'SaveAs'
    EXPORTING
      #1 = cv_fullpath
      #2 = mv_file_format.
ENDMETHOD.


METHOD do_merge.
  DATA:
    lo_new_replace_block TYPE REF TO zcl_xtt_replace_block,
    ls_field             TYPE REF TO zcl_xtt_replace_block=>ts_field,
    lv_before            TYPE string,
    lv_after             TYPE string,
    lv_middle            TYPE string,
    lv_find_str          TYPE string,
    lv_clone             TYPE string,
    lt_text_match        TYPE tt_text_match,
    lo_tree_handler      TYPE REF TO lcl_tree_handler,
    lr_tree              TYPE REF TO zcl_xtt_replace_block=>ts_tree.
  FIELD-SYMBOLS:
   <lt_table>            TYPE ANY TABLE.
***************************************
  " merge-1 @see ME->MATCH_FOUND
  SET HANDLER on_match_found FOR io_replace_block ACTIVATION abap_true.

  " @see match_found
  " What will search in template. At first '{ROOT-'
  io_replace_block->find_match(
   CHANGING
    cv_content     = cv_content ).

  " Turn off event handler
  SET HANDLER on_match_found FOR io_replace_block ACTIVATION abap_false.
***************************************
  " merge-2 Structures and objects
  LOOP AT io_replace_block->mt_fields REFERENCE INTO ls_field WHERE
   typ = zcl_xtt_replace_block=>mc_type_struct OR typ = zcl_xtt_replace_block=>mc_type_object.

    " Based on nested structure
    CREATE OBJECT lo_new_replace_block
      EXPORTING
        is_field = ls_field.

    " Recursion if type is the same
    CHECK ls_field->typ = zcl_xtt_replace_block=>mc_type_struct OR
          ls_field->typ = zcl_xtt_replace_block=>mc_type_object.
    do_merge(
     EXPORTING
        io_replace_block = lo_new_replace_block
     CHANGING
        cv_content       = cv_content ).
  ENDLOOP.

***************************************
  " merge-3 Array types
  LOOP AT io_replace_block->mt_fields REFERENCE INTO ls_field WHERE typ = zcl_xtt_replace_block=>mc_type_table
                                                                 OR typ = zcl_xtt_replace_block=>mc_type_tree.
    " if root is a table
    CLEAR:
     lv_before,
     lv_middle,
     lv_after.

    " Detect bounds
    IF iv_first_level_is_table <> abap_true.
      CONCATENATE `\{` ls_field->name `\b[^}]*\}` "
        INTO lv_find_str.

      " Divide to 3 parts
      split_by_tag(
       EXPORTING
        iv_tag        = mv_row_tag
        iv_tag_add    = lv_find_str
        iv_block_name = ls_field->name
        iv_field_type = ls_field->typ
       IMPORTING
        et_text_match = lt_text_match
       CHANGING
        cv_before     = lv_before
        cv_middle     = cv_content
        cv_after      = lv_after ).
    ENDIF.

    CASE ls_field->typ.
**********************************************************************
      WHEN zcl_xtt_replace_block=>mc_type_tree.

        CREATE OBJECT lo_tree_handler
          EXPORTING
            io_owner      = me
            iv_block_name = ls_field->name
            it_text_match = lt_text_match.

        lr_tree ?= ls_field->dref.
        lo_tree_handler->add_tree_data(
         EXPORTING
           ir_tree = lr_tree
         CHANGING
           cv_text = lv_before ).

        " And set result
        CONCATENATE lv_before
                    lv_after INTO cv_content RESPECTING BLANKS.

**********************************************************************
      WHEN zcl_xtt_replace_block=>mc_type_table.
       " CHECK cv_content IS NOT INITIAL.

        lv_middle = cv_content.
        " Replicate middle
        ASSIGN ls_field->dref->* TO <lt_table>.
        LOOP AT <lt_table> REFERENCE INTO ls_field->dref.
          " Create merge description
          CREATE OBJECT lo_new_replace_block
            EXPORTING
              is_field = ls_field.

          " Recursion
          lv_clone = lv_middle.
          do_merge(
           EXPORTING
            io_replace_block = lo_new_replace_block
           CHANGING
            cv_content       = lv_clone ).

          " Add
          CONCATENATE lv_before lv_clone INTO lv_before RESPECTING BLANKS.
        ENDLOOP.

        " End
        CONCATENATE lv_before lv_after INTO cv_content RESPECTING BLANKS.
    ENDCASE.

  ENDLOOP.
ENDMETHOD.


METHOD find_bounds.
  DATA:
    lv_pattern TYPE string,
*    lv_text    TYPE string,
    lv_tabix   TYPE sytabix.
  FIELD-SYMBOLS:
    <ls_match>    LIKE LINE OF et_match,
    <ls_submatch> LIKE LINE OF <ls_match>-submatches.

  " Divide text by body tag. Usualy 2 matches. <body> and </body>
  CONCATENATE `(<` iv_tag `\b[^>]*>)|(<\/` iv_tag `>)` INTO lv_pattern.

  " Also finf this part
  IF iv_tag_add IS NOT INITIAL.
    CONCATENATE lv_pattern `|(` iv_tag_add `)` INTO lv_pattern.
  ENDIF.

  FIND ALL OCCURRENCES OF REGEX lv_pattern IN iv_context RESULTS et_match RESPECTING CASE.

  " Wrong template
  IF et_match IS INITIAL.
    MESSAGE x001(zsy_xtt).
  ENDIF.

  CASE iv_tag.
    WHEN mv_body_tag.
      " First and last matches
      ev_first_match = 1.
      ev_last_match  = lines( et_match ).
      RETURN.

    WHEN mv_row_tag.
      ev_with_tag    = abap_true.
      ev_first_match = 0.
      ev_last_match  = 0.
      " {iv_block_name*  -  CONCATENATE zcl_xtt_replace_block=>mc_char_block_begin iv_block_name '*' INTO lv_pattern.

      LOOP AT et_match ASSIGNING <ls_match>.
        lv_tabix = sy-tabix.

*        lv_text = iv_context+<ls_match>-offset(<ls_match>-length).
*        CHECK lv_text CP lv_pattern.

        " Only
        READ TABLE <ls_match>-submatches ASSIGNING <ls_submatch> INDEX 3.
        CHECK sy-subrc = 0
          AND <ls_match>-offset = <ls_submatch>-offset
          AND <ls_match>-length = <ls_submatch>-length.

        ev_last_match = lv_tabix.
        IF ev_first_match IS INITIAL.
          ev_first_match = lv_tabix.
        ENDIF.
      ENDLOOP.

      " Extend bounds for iv_tag
      ev_first_match = ev_first_match - 1.
      ev_last_match  = ev_last_match + 1.
  ENDCASE.
ENDMETHOD.


METHOD get_raw.
  DATA:
   lr_content TYPE REF TO xstring.

  IF mv_path_in_arc IS INITIAL.
    " Can convert XML or HTML result to pdf or attach to email for example
    rv_content = zcl_xtt_util=>string_to_xstring( mv_file_content ).
  ELSE.
    " Replace XML file
    zcl_xtt_util=>xml_to_zip(
     io_zip  = mo_zip
     iv_name = mv_path_in_arc
     iv_sdoc = mv_file_content ).

    " ZIP archive as xstring
    rv_content = mo_zip->save( ).
  ENDIF.

  " Change content in special cases
  GET REFERENCE OF rv_content INTO lr_content.
  RAISE EVENT prepare_raw
   EXPORTING
     ir_content = lr_content.
ENDMETHOD.


METHOD merge.
  DATA:
    lo_replace_block        TYPE REF TO zcl_xtt_replace_block,
    lv_typekind             TYPE abap_typekind,
    lv_first_level_is_table TYPE abap_bool,
    lv_before               TYPE string,
    lv_after                TYPE string.

  " Prepare for replacement
  CREATE OBJECT lo_replace_block
    EXPORTING
      is_block      = is_block
      iv_block_name = iv_block_name.

  " Special case
  DESCRIBE FIELD is_block TYPE lv_typekind.
  IF lv_typekind = cl_abap_typedescr=>typekind_table.
    lv_first_level_is_table = abap_true.
  ENDIF.

  " Divide to 3 parts
  split_by_tag(
   EXPORTING
    iv_first_level_is_table = lv_first_level_is_table
    iv_tag                  = mv_body_tag
    iv_block_name           = iv_block_name
   CHANGING
    cv_before               = lv_before
    cv_middle               = mv_file_content
    cv_after                = lv_after ).

  " Update middle part (Body)
  do_merge(
   EXPORTING
    iv_first_level_is_table = lv_first_level_is_table
    io_replace_block        = lo_replace_block
   CHANGING
    cv_content              = mv_file_content ).

  " And just concatenate
  CONCATENATE lv_before mv_file_content lv_after INTO mv_file_content RESPECTING BLANKS.
ENDMETHOD.


METHOD on_match_found.
  FIELD-SYMBOLS:
   <lv_content> TYPE string.
  " Just skip
  CHECK is_field->typ <> zcl_xtt_replace_block=>mc_type_tree.

  " Current document
  ASSIGN iv_content->* TO <lv_content>.

  " Try to get value as a string
  IF mv_value IS INITIAL.
    mv_value = zcl_xtt_replace_block=>get_as_string( is_field = is_field ).
  ENDIF.

  " Write new value
  iv_pos_end = iv_pos_end + 1.
  CONCATENATE
    <lv_content>(iv_pos_beg)
       mv_prefix mv_value
    <lv_content>+iv_pos_end INTO <lv_content> RESPECTING BLANKS.

  " Used in sub classes
  CLEAR:
   mv_prefix,
   mv_value.
ENDMETHOD.


METHOD split_by_tag.
  TYPES:
    BEGIN OF ts_text_off,
      level TYPE i,
      top   TYPE abap_bool,
      first TYPE i,
      last  TYPE i,
    END OF ts_text_off ,
    tt_text_off TYPE SORTED TABLE OF ts_text_off WITH UNIQUE KEY level top.

  DATA:
    lt_match       TYPE match_result_tab,
    lv_first_match TYPE i,
    lv_last_match  TYPE i,
    lv_with_tag    TYPE abap_bool,
    lv_beg         TYPE i,
    lv_end         TYPE i,
    lv_off         TYPE i,
    lv_text        TYPE string,
    lt_text        TYPE stringtab,
    ls_text_off    TYPE ts_text_off,
    lt_text_off    TYPE tt_text_off,
    lv_value       TYPE string,
    lv_tabix       TYPE sytabix,
    lv_from        TYPE sytabix,
    lv_minus       TYPE i,
    ls_text_match  LIKE LINE OF et_text_match.
  FIELD-SYMBOLS:
    <ls_match>     LIKE LINE OF lt_match,
    <ls_submatch>  LIKE LINE OF <ls_match>-submatches,
    <ls_text_off>  LIKE ls_text_off,
    <ls_text_off2> LIKE ls_text_off.

*************
  find_bounds(
   EXPORTING
    iv_context              = cv_middle
    iv_tag                  = iv_tag
    iv_tag_add              = iv_tag_add
    iv_first_level_is_table = iv_first_level_is_table
    iv_block_name           = iv_block_name
   IMPORTING
    et_match                = lt_match
    ev_with_tag             = lv_with_tag
    ev_first_match          = lv_first_match
    ev_last_match           = lv_last_match ).

*************
  " 1 - Text before body
  READ TABLE lt_match ASSIGNING <ls_match> INDEX lv_first_match.

  " Does need an open tag?
  IF lv_with_tag = abap_true.
    lv_beg = <ls_match>-offset.
  ELSE.
    lv_beg = <ls_match>-offset + <ls_match>-length.
  ENDIF.
  cv_before = cv_middle(lv_beg).
*************
  " 2 - Text after body
  READ TABLE lt_match ASSIGNING <ls_match> INDEX lv_last_match.

  IF lv_with_tag = abap_true.
    lv_end = <ls_match>-offset + <ls_match>-length.
  ELSE.
    lv_end = <ls_match>-offset.
  ENDIF.
  cv_after = cv_middle+lv_end.
*************
  " 3 - Body
  lv_end = lv_end - lv_beg.
  cv_middle = cv_middle+lv_beg(lv_end).

**********************************************************************
  " For trees
**********************************************************************
  CHECK iv_field_type = zcl_xtt_replace_block=>mc_type_tree
    AND et_text_match IS REQUESTED.

  " Offset
  lv_minus = lv_beg.


  LOOP AT lt_match ASSIGNING <ls_match>.
    lv_tabix = sy-tabix.
    READ TABLE <ls_match>-submatches ASSIGNING <ls_submatch> INDEX 3.
    CHECK sy-subrc = 0
      AND <ls_match>-offset = <ls_submatch>-offset
      AND <ls_match>-length = <ls_submatch>-length.

    " Get whole match
    lv_off  = <ls_match>-offset - lv_beg.
    lv_text = cv_middle+lv_off(<ls_match>-length).

    " Read from texts
    SPLIT lv_text AT ';' INTO TABLE lt_text.
    LOOP AT lt_text INTO lv_text.
      SPLIT lv_text AT '=' INTO lv_text lv_value.

      CASE lv_text.
        WHEN 'level'.
          ls_text_off-level = lv_value.
        WHEN 'top'.
          IF lv_value CP 'X*'.
            ls_text_off-top = abap_true.
          ELSE.
            ls_text_off-top = abap_false.
          ENDIF.
      ENDCASE.
    ENDLOOP.

    " Exist or new
    READ TABLE lt_text_off ASSIGNING <ls_text_off>
     FROM ls_text_off.
    IF sy-subrc <> 0.
      CLEAR:
       ls_text_off-first,
       ls_text_off-last.
      INSERT ls_text_off INTO TABLE lt_text_off ASSIGNING <ls_text_off>.
    ENDIF.

    <ls_text_off>-last = lv_tabix.
    IF <ls_text_off>-first IS INITIAL.
      <ls_text_off>-first = lv_tabix.
    ENDIF.
  ENDLOOP.

  " Check overlaps
  LOOP AT lt_text_off ASSIGNING <ls_text_off>.
    lv_from = sy-tabix + 1.
    LOOP AT lt_text_off ASSIGNING <ls_text_off2> FROM lv_from WHERE
       ( first <= <ls_text_off>-last AND first >= <ls_text_off>-first ) OR
       ( last  <= <ls_text_off>-last AND last  >= <ls_text_off>-first ).
      MESSAGE x001(zsy_xtt).
    ENDLOOP.
  ENDLOOP.

  " And add
  LOOP AT lt_text_off ASSIGNING <ls_text_off>.
    lv_beg = <ls_text_off>-first - 1.
    READ TABLE lt_match ASSIGNING <ls_match> INDEX lv_beg.
    lv_beg = <ls_match>-offset - lv_minus.

    lv_end = <ls_text_off>-last + 1.
    READ TABLE lt_match ASSIGNING <ls_match> INDEX lv_end.
    lv_end = <ls_match>-offset + <ls_match>-length - lv_beg - lv_minus.

    " And add
    ls_text_match-level = <ls_text_off>-level.
    ls_text_match-top   = <ls_text_off>-top.
    ls_text_match-text  = cv_middle+lv_beg(lv_end).
    INSERT ls_text_match INTO TABLE et_text_match.
  ENDLOOP.
ENDMETHOD.
ENDCLASS.
