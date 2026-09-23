-- [[ Component-level Russian strings for TRD track image parser ]]
return {
    trd_err_file_too_small           = "Файл слишком мал для образа диска TRD.",
    trd_err_file_too_large           = "Размер файла превышает максимально допустимый лимит в 640 КБ для TRD-образа.",
    trd_err_invalid_signature        = "Неверная структура TRD диска (Отсутствует служебный маркер 0x10 в системном секторе).",
    trd_err_corrupted_header_catalog = "Системный сектор геометрии диска TR-DOS поврежден или не может быть прочитан."
}
