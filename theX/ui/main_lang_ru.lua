-- [[ Standalone Russian localization dataset layer ]]
return {
    -- Reader diagnostics error responses
    err_cannot_open_file         = "Не удалось открыть или прочитать файл.",

    -- Configuration and dialogs layouts strings
    m_plugin_menu_title          = "SCL eXplorer",
    m_trd_menu_title             = "TRD eXplorer",
    m_menu_open_scl              = "Открыть SCL архив...",
    m_menu_create_scl            = "Создать SCL архив...",
    m_open_dialog_title          = "Открыть SCL архив",
    xl_menu_title                = "xLook",
    m_open_dialog_lbl            = "Выберите путь к SCL файлу:",
    m_btn_create                 = "Создать",
    m_btn_cancel                 = "Отмена",
    m_err_title                  = "Ошибка",
    m_err_empty_name             = "Имя файла не может быть пустым!",
    m_err_write_failed           = "Не удалось создать файл на диске. Проверьте права доступа.",

    m_rename_title     = "Переименование / Редактирование атрибутов файла",
    m_lbl_filename     = "&Имя:",
    m_lbl_pc_ext       = "&Тип/Расширение:",
    m_lbl_trdos_start  = "&Стартовый адрес:",
    m_btn_save         = "Сохранить",
    m_btn_copy         = "Копировать",
    m_btn_move         = "Переместить",
    m_btn_ok           = "Ок",

    m_menu_trd_settings          = "TRD eXplorer",
    dlg_trd_settings_title       = "Настройки TRD образов",
    dlg_trd_use_dirsys           = "Использовать расширение каталогов &DirSys",

    trd_err_dirsys_disabled   = "Расширение каталогов DirSys отключено в настройках плагина.",
    trd_msg_init_dirsys_title = "Инициализация DirSys",
    trd_msg_init_dirsys_body  = "На этом диске не обнаружена структура DirSys.\nЖелаете инициализировать систему каталогов на данном TRD-образе?",
    dlg_create_folder_title   = "Создание каталога",
    dlg_create_folder_lbl     = "Введите имя каталога (поддерживается вложенность через '\\'):",
    trd_err_dirsys_limit      = "Не удалось создать каталог. Превышен максимальный лимит DirSys в 127 папок.",

    -- [[ TRD FILE OPERATIONS: DELETION LAYER (F8) ]]
    trd_dlg_delete_title      = "Удаление",
    trd_dlg_delete_confirm    = "Вы действительно хотите удалить выбранные файлы?",
    trd_err_delete_failed     = "Не удалось выполнить операцию удаления файлов.",

    m_menu_trd_move              = "Move (Уплотнить диск)",
    trd_msg_move_success         = "Уплотнение диска (MOVE) успешно завершено.",
    trd_msg_move_no_deleted      = "На диске нет удаленных файлов или каталогов. Операция MOVE пропущена.",

    m_menu_trd_create            = "Создать TRD образ диска...",
    trd_msg_create_success       = "TRD образ диска успешно создан.",


    -- [[ TRD/SCL VIEW MODES COLUMNS TITLES ]]
    col_title_name            = "Имя",
    col_title_size            = "Размр",     -- Сокращено до "Размр"
    col_title_start           = "Старт",
    col_title_sectors_sz      = "РCк",      -- Размер в секторах (Размер Секторов)
    col_title_sector_st       = "Сек",      -- Стартовый сектор
    col_title_track           = "Дор",      -- Сокращено до "Дор"
    col_title_description     = "Формат",
    col_title_comments        = "Комментарии",

    -- [[ IO_MANAGER TRANSLATION LAYER ]]
    io_time_not_available     = "н/д",
    io_msg_file_exists        = "Файл уже существует!",
    io_msg_filename           = "Имя: ",
    io_msg_current_on_disk    = "Текущий на диске:  %d байт, %s",
    io_msg_new_from_archive   = "Новый:   %d байт",
    io_msg_overwrite_prompt   = "Желаете перезаписать его?",
    io_title_scl_conflict     = "Конфликт файлов",
    io_title_name_conflict    = "Конфликт имён",
    io_btn_overwrite          = "Перезаписать",
    io_btn_skip               = "Пропустить",
    io_btn_overwrite_all      = "Перезаписать Все",
    io_btn_skip_all           = "Пропустить Все",

    trd_err_put_dirsys_disabled = "Невозможно импортировать директории. Расширение каталогов DirSys отключено.",
    trd_err_max_files_limit   = "Ошибка: Превышен лимит файлов в TRD (Разрешено максимум 128 файлов).",
    scl_err_max_files_limit   = "Ошибка: Превышен лимит файлов в SCL архиве (Разрешено максимум 255 файлов).",
    trd_err_max_folders_limit = "Ошибка: Превышен лимит каталогов DirSys (Разрешено максимум 127 папок).",
    trd_err_disk_full         = "Ошибка: Недостаточно свободного места на TRD образе.\nТребуется: %d сект., Доступно: %d сект.",
    trd_title_import_err      = "Ошибка импорта",

    -- [[ INFOLINES SECTION TITLES ]]
    info_sec_files            = "Информация о файлах",
    info_sec_dirsys           = "Информация о папках",
    info_sec_space            = "Свободное пространство",

    -- [[ INFOLINES METRICS LABELS ]]
    info_lbl_label            = "Метка диска:",
    info_lbl_type             = "Тип диска:",
    info_lbl_write_protect    = "Защита от записи:",
    info_lbl_wp_active        = "Да (Образ защищён / RO)",
    info_lbl_wp_inactive      = "Нет (Доступна запись / RW)",
    info_lbl_total_files      = "Всего активных файлов:",
    info_lbl_deleted_files    = "Удалённых файлов:",
    info_lbl_dirsys_status    = "Статус DirSys:",
    info_lbl_dirsys_present   = "Инициализирована",
    info_lbl_dirsys_absent    = "Отсутствует / Отключена",
    info_lbl_total_folders    = "Всего активных папок:",
    info_lbl_deleted_folders  = "Удалённых папок:",
    info_lbl_free_track       = "Первый свободный трек:",
    info_lbl_free_sector      = "Первый свободный сектор:",
    info_lbl_free_sectors_qty = "Свободно секторов:",

}
