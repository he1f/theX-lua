-- [[ Component-level English strings for TRD track image parser ]]
return {
    trd_err_file_too_small           = "File is too small to be a valid TRD disk image.",
    trd_err_file_too_large           = "The file size exceeds the maximum allowed 640KB TRD ceiling constraint.",
    trd_err_invalid_signature        = "Invalid TRD image layout (Missing constant 0x10 marker inside system sector).",
    trd_err_corrupted_header_catalog = "TR-DOS system geometry sector track descriptor is corrupted or missing."
}
