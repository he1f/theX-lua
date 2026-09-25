-- [[ Standalone English localization dataset layer ]]
return {
    -- Reader diagnostics error responses
    err_cannot_open_file         = "Cannot open or read the specified file.",

    -- Configuration and dialogs layouts strings
    m_plugin_menu_title          = "SCL eXplorer",
    m_trd_menu_title             = "TRD eXplorer",
    m_menu_open_scl              = "Open SCL archive...",
    m_menu_create_scl            = "Create SCL archive...",
    m_open_dialog_title          = "Open SCL archive",
    xl_menu_title                = "xLook",
    m_open_dialog_lbl            = "Select SCL file path:",
    m_btn_create                 = "Create",
    m_btn_cancel                 = "Cancel",
    m_err_title                  = "Error",
    m_err_empty_name             = "Filename cannot be empty!",
    m_err_write_failed           = "Failed to write file to disk. Check storage access rights.",

    -- Exporter options checkboxes
    m_chk_skip_headers           = "Skip Headers",

    m_rename_title     = "Rename / Edit TR-DOS file attributes",
    m_lbl_filename     = "&Name:",
    m_lbl_pc_ext       = "&Extension:",
    m_lbl_trdos_type   = "&Type:",
    m_lbl_trdos_start  = "&Start:",
    m_btn_save         = "Save",
    m_btn_copy         = "Copy",
    m_btn_move         = "Move",
    m_btn_ok           = "Ok",

    m_menu_trd_settings          = "TRD eXplorer",
    dlg_trd_settings_title       = "TRD Image Options",
    dlg_trd_use_dirsys           = "Use &DirSys directory extensions",

    trd_err_dirsys_disabled   = "DirSys folder extension is disabled in plugin configuration.",
    trd_msg_init_dirsys_title = "DirSys Initialization",
    trd_msg_init_dirsys_body  = "DirSys file layout was not detected on this image.\nDo you want to initialize the directory engine on this disk?",
    dlg_create_folder_title   = "Create Folder",
    dlg_create_folder_lbl     = "Enter folder name (nesting supported via '\\'):",
    trd_err_dirsys_limit      = "Failed to create folder. DirSys maximum limit of 127 directories exceeded.",

    -- [[ TRD FILE OPERATIONS: DELETION LAYER (F8) ]]
    trd_dlg_delete_title      = "Delete",
    trd_dlg_delete_confirm    = "Do you really want to delete the selected items?",
    trd_err_delete_failed     = "Failed to process target delete items.",

    m_menu_trd_move              = "Move (Defragment Disk)",
    trd_msg_move_success         = "Disk defragmentation (MOVE) completed successfully.",
    trd_msg_move_no_deleted      = "There are no deleted files or folders on this disk. Move operation skipped.",

    m_menu_trd_create            = "Create TRD disk image...",
    trd_msg_create_success       = "TRD disk image created successfully.",


    -- [[ TRD/SCL VIEW MODES COLUMNS TITLES ]]
    col_title_name            = "Name",
    col_title_size            = "Size",
    col_title_start           = "Start",
    col_title_sectors_sz      = "SSz",      -- Size in sectors
    col_title_sector_st       = "Sec",      -- Starting sector index
    col_title_track           = "Trk",
    col_title_description     = "Format",
    col_title_comments        = "Comments",

    -- [[ IO_MANAGER TRANSLATION LAYER ]]
    io_time_not_available     = "N/A",
    io_msg_file_exists        = "File already exists!",
    io_msg_filename           = "Name: ",
    io_msg_current_on_disk    = "Current on disk: %d bytes, %s",
    io_msg_new_from_archive   = "New:  %d bytes",
    io_msg_overwrite_prompt   = "Do you want to overwrite it?",
    io_title_scl_conflict     = "File Conflict",
    io_title_name_conflict    = "Name Conflict",
    io_btn_overwrite          = "Overwrite",
    io_btn_skip               = "Skip",
    io_btn_overwrite_all      = "Overwrite All",
    io_btn_skip_all           = "Skip All",

    trd_err_put_dirsys_disabled = "Cannot import directories. DirSys folder extension is disabled.",
    trd_err_max_files_limit   = "Failed to import. TRD disk limits exceeded (Maximum 128 files allowed).",
    scl_err_max_files_limit   = "Failed to import. SCL archive limits exceeded (Maximum 255 files allowed).",
    trd_err_max_folders_limit = "Failed to import. DirSys catalog limits exceeded (Maximum 127 folders allowed).",
    trd_err_disk_full         = "Failed to import. Not enough free space on TRD disk image.\nRequired: %d sectors, Available: %d sectors.",
    trd_title_import_err      = "Import Error",

    -- [[ INFOLINES SECTION TITLES ]]
    info_sec_files            = "Files info",
    info_sec_dirsys           = "Directories info",
    info_sec_space            = "Free space info",

    -- [[ INFOLINES METRICS LABELS ]]
    info_lbl_label            = "Disk Label:",
    info_lbl_type             = "Disk Type:",
    info_lbl_write_protect    = "Write Protection:",
    info_lbl_wp_active        = "Yes (Read-Only Image)",
    info_lbl_wp_inactive      = "No (Read-Write Allowed)",
    info_lbl_total_files      = "Total Active Files:",
    info_lbl_deleted_files    = "Deleted Files:",
    info_lbl_dirsys_status    = "DirSys Status:",
    info_lbl_dirsys_present   = "Initialized & Present",
    info_lbl_dirsys_absent    = "Not Found / Inactive",
    info_lbl_total_folders    = "Total Active Folders:",
    info_lbl_deleted_folders  = "Deleted Folders:",
    info_lbl_free_track       = "First Free Track:",
    info_lbl_free_sector      = "First Free Sector:",
    info_lbl_free_sectors_qty = "Free Sectors Count:",

}
