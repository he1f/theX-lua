-- [[ Component-level English strings for standalone HoBeta file parser ]]
return {
    hobeta_err_cannot_open_file         = "Cannot open or read the specified HoBeta file resource.",
    hobeta_err_file_too_large           = "The file size exceeds the maximum allowed TR-DOS HoBeta limit.",
    hobeta_err_file_too_small           = "File is too small to be a valid HoBeta container.",
    hobeta_err_corrupted_header_catalog = "HoBeta file structural header descriptor is corrupted.",
    hobeta_err_checksum_mismatch        = "HoBeta header integrity verification failed (CRC mismatch).",
    hobeta_err_data_size_mismatch       = "HoBeta physical file size on disk is smaller than the embedded sector registry bounds."
}
