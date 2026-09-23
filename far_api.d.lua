---@meta

-- [[ Standalone Definition File for Far Manager & LuaFAR API (VS Code Only) ]]

---@diagnostic disable: lowercase-global, redundant-parameter

---@class far
far = {}

---@overload fun(items: string|table): integer
---@overload fun(items: string|table, title: string): integer
---@overload fun(items: string|table, title: string, buttons: string): integer
---@overload fun(items: string|table, title: string, buttons: string, flags: string): integer
function far.Message(items, title, buttons, flags) end

---@class tFarListItem
---@field Flags integer Native list item operational state bitmask flags (e.g., LIF_*)
---@field Text string Displayable label text string assigned to this list row element

---@class tFarListHash
---@field SelectIndex integer 1-based index pointing to the currently focused row item element

---@alias tFarDialogList table<integer, tFarListItem>|tFarListHash

---@alias tFarDialogItem table
---| [1] integer|string Type: Scoped Dialog Item type specifier code identifier (e.g., DI_EDIT)
---| [2] integer X1: Relative left-bound horizontal frame index offset boundary coordinate
---| [3] integer Y1: Relative top-bound vertical frame index offset boundary coordinate
---| [4] integer X2: Relative right-bound horizontal frame index offset boundary coordinate
---| [5] integer Y2: Relative bottom-bound vertical frame index offset boundary coordinate
---| [6] integer|tFarDialogList Selected/ListItems: State index (checked/radio), or table array list of drop-down items matrix
---| [7] string History: Far persistent history log tracker storage identifier mapping label string
---| [8] string Mask: Format mask schema constraint parameter validation string (e.g., matching inputs rules)
---| [9] integer Flags: Native item modification bitmask operational state flags (e.g., DIF_FOCUS)
---| [10] string Data: Core textual caption representation label string or internal edit field buffer payload
---| [11] integer MaxLength: Maximum character capacity ceiling boundary size constraint mapping constraint
---| [12] integer UserData: Custom contextual raw numeric metadata signature property payload link

---@class tFarDialogHandle : userdata
local tFarDialogHandle = {}

---Returns the original low-level handle received from Far Manager, suitable for LuaJIT FFI or as a table key.
---@return lightuserdata rawhandle
function tFarDialogHandle:rawhandle() end

---Sends a dialog message to Far Manager core frame environment. (Equivalent to far.SendDlgMessage).
---@param Msg integer Native operational command notification message code key (any DM_*)
---@param Param1 integer|any Contextual parameter argument (usually 1-based element numerical position ID)
---@param Param2 any Contextual parameter metadata block (type signature definitions vary based on Msg code)
---@return any result Response code metric evaluated by Far Manager framework
function tFarDialogHandle:send(Msg, Param1, Param2) end

---@alias fDlgProc fun(hDlg: tFarDialogHandle, Msg: integer, Param1: integer, Param2: any): integer|boolean|nil

---Displays an interactive system modal dialog frame block instantly on screen, halting background executions loops.
---@param Guid string|nil System unique registry 128-bit GUID identification token mapping string
---@param X1 integer Absolute screen coordinate left horizontal positioning ceiling block line
---@param Y1 integer Absolute screen coordinate top vertical positioning ceiling block line
---@param X2 integer Absolute screen coordinate right horizontal positioning ceiling block line
---@param Y2 integer Absolute screen coordinate bottom vertical positioning ceiling block line
---@param HelpTopic string|nil Help file reference path mapping key identifier context string, or nil
---@param Items tFarDialogItem[] Stateful sequential array dictionary layout mapping rows elements context frames
---@param Flags integer? Native dialog operational window bitmask modifier flags (e.g., FDLG_*)
---@param fDlgProc fDlgProc? Optional dialog activity callback processor event handler hook, or nil
---@param Param any? Optional transient baseline value object mapping into callback initialization context loops
---@return integer|nil result Focused closing button/element 1-based index row position ID, or nil if creation collapsed
function far.Dialog(Guid, X1, Y1, X2, Y2, HelpTopic, Items, Flags, fDlgProc, Param) end

---Initializes an asynchronous dialog pipeline context, returning an operational handle token for external control loops.
---@param Guid string|nil System unique registry 128-bit GUID identification token mapping string
---@param X1 integer Absolute screen coordinate left horizontal positioning ceiling block line
---@param Y1 integer Absolute screen coordinate top vertical positioning ceiling block line
---@param X2 integer Absolute screen coordinate right horizontal positioning ceiling block line
---@param Y2 integer Absolute screen coordinate bottom vertical positioning ceiling block line
---@param HelpTopic string|nil Help file reference path mapping key identifier context string, or nil
---@param Items tFarDialogItem[] Stateful sequential array dictionary layout mapping rows elements context frames
---@param Flags integer? Native dialog operational window bitmask modifier flags (e.g., FDLG_*)
---@param DlgProc fDlgProc? Optional dialog activity callback processor event handler hook, or nil
---@param Param any? Optional transient baseline value object mapping into callback initialization context loops
---@return tFarDialogHandle|nil hDlg Active stateful dialog controller handler interface object pointer, or nil on failure
function far.DialogInit(Guid, X1, Y1, X2, Y2, HelpTopic, Items, Flags, DlgProc, Param) end

---Sends a low-level dialog management control or query message straight to the active Far Manager dialog window handler.
---@param hDlg tFarDialogHandle Active stateful dialog controller handler interface object pointer received from far.DialogInit
---@param Msg integer Native operational command notification or query message code key (any DM_*)
---@param Param1 integer|any Contextual argument parameter (usually maps to a 1-based element numerical position ID, or 0)
---@param Param2 any Contextual metadata block or pointer reference (type signature payload values vary dynamically based on Msg code)
---@return any result Response code metric evaluated and returned by the active Far Manager dialog procedure context
function far.SendDlgMessage(hDlg, Msg, Param1, Param2) end

---@class tFarMenuProperties
---@field X integer? Horizontal menu alignment layout coordinate index (set to -1 for auto-centering)
---@field Y integer? Vertical menu alignment layout coordinate index (set to -1 for auto-centering)
---@field MaxHeight integer? Maximum visual height capacity ceiling constraint mapping lines quantity
---@field Flags integer? Native Far menu bitmask operational flags (defaults to FMENU_WRAPMODE)
---@field Title string? Top header caption label string displayed on the frame boundary
---@field Bottom string? Bottom footer caption label string displayed on the frame boundary
---@field HelpTopic string? Help file reference path mapping key identifier context string, or nil
---@field SelectIndex integer? 1-based index forcing structural selection highlight focus onto this item row
---@field Id string? System unique registry 128-bit GUID identification token mapping string

---@class tFarSubMenuItem
---@field text string? Displayable label text string assigned to this menu row element
---@field checked boolean|string? Renders a checkmark indicator state or specific check string prefix
---@field separator boolean? If true, transforms the row into a visual flat dividing separator bar separator
---@field disable boolean? If true, blocks user interaction selection loops on this menu row completely
---@field grayed boolean? If true, applies a muted gray color layout scheme onto the row text
---@field hidden boolean? If true, completely hides the target item entry from the visual viewport layout
---@field selected boolean? Initial selection highlight state mapping identifier parameter
---@field AccelKey table|string? Table key layout configuration or string token macro key name pattern

---@alias tFarMenuItem string|tFarSubMenuItem

---@class tFarBreakKeyItem
---@field BreakKey string Keyboard shortcut layout identifier mapping string (e.g., "A+Enter")

---@alias tFarBreakKeys table<integer, tFarBreakKeyItem>|string

---Displays a modal user interactive popup menu context screen block seamlessly over active frames.
---@param Properties tFarMenuProperties Structural configuration attributes defining framing properties bounds
---@param Items tFarMenuItem[] Sequential array dictionary listing active menu rows entities elements
---@param BreakKeys tFarBreakKeys? Optional interceptor keys sequence tracking hotkey cancels hooks triggers
---@return table|nil Item Selected item table element object (or break key array data), or nil if aborted via Escape
---@return integer|nil Position 1-based index integer tracking chosen item location at closure moment, or nil if cancelled
function far.Menu(Properties, Items, BreakKeys) end

---@class far.Flags
---@extending integer
---@index integer Global static bitmask flags authority dictionary for Far Manager 3 API.
local Flags = {
    OPIF_ADDDOTS            = 0x0000000000000008,
    OPM_SILENT              = 0x0000000000000001,
    OPM_FIND                = 0x0000000000000002,
    PFLAGS_REVERSESORTORDER = 0x0000000000000004,
    FE_CHANGEVIEWMODE       = 0,
    PANEL_ACTIVE            = 1,
    PANEL_PASSIVE           = 0,
    OPEN_ANALYSE            = 9,
    SM_UNSORTED             = 1,

    DI_TEXT                 = 0,
    DI_VTEXT                = 1,
    DI_SINGLEBOX            = 2,
    DI_DOUBLEBOX            = 3,
    DI_EDIT                 = 4,
    DI_PSWEDIT              = 5,
    DI_FIXEDIT              = 6,
    DI_BUTTON               = 7,
    DI_CHECKBOX             = 8,
    DI_RADIOBUTTON          = 9,
    DI_COMBOBOX             = 10,
    DI_LISTBOX              = 11,
    DIF_GROUP               = 0x0000000000000400,
    DIF_CENTERGROUP         = 0x0000000000004000,
    DIF_SEPARATOR           = 0x0000000000010000,
    DIF_HISTORY             = 0x0000000000040000,
    DIF_DEFAULTBUTTON       = 0x0000000100000000,
    DIF_FOCUS               = 0x0000000200000000,

    DM_GETTEXT              = 7,
    DM_SETTEXT              = 15,

    DN_EDITCHANGE           = 4103,
    DN_CLOSE                = 4117,

    FMENU_AUTOHIGHLIGHT     = 0x0000000000000004,
}

-- Assign the local symbol back to global namespace to activate autocomplete chains
far.Flags = Flags


---@class panel
panel = {}

--- Safely extracts live comma-separated column type mappings from the targeted layout context.
---@param handle userdata The low-level Far Manager panel handle context pointer
---@param panel_type integer Direction flag constraint identifier (e.g., F.PANEL_ACTIVE)
---@return string|nil types_str Comma-delimited list layout of active columns (e.g., "C0,C1,C2")
function panel.GetColumnTypes(handle, panel_type) end

--- Safely extracts physical character column width allocations layout from the targeted panel context.
---@param handle userdata The low-level Far Manager panel handle context pointer
---@param panel_type integer Direction flag constraint identifier (e.g., F.PANEL_ACTIVE)
---@return string|nil widths_str Comma-delimited list layout of active column character widths (e.g., "7,5,0")
function panel.GetColumnWidths(handle, panel_type) end

---@class tPanelRect
---@field left integer
---@field top integer
---@field right integer
---@field bottom integer

---@class tPanelInfo
---@field OwnerGuid string System unique registry 128-bit GUID mapping string of the owning plugin
---@field PluginHandle lightuserdata|nil Low-level C++ panel context handle pointer, or nil if native file layout
---@field PanelType integer Native panel type mode (e.g., standard file panel or virtual plugin VFS)
---@field PanelRect tPanelRect Visual boundaries structure positioning coordinates table
---@field ItemsNumber integer Total number of files and folders allocated inside the current view
---@field SelectedItemsNumber integer Total number of explicitly checked / highlighted item elements
---@field CurrentItem integer 1-based index pointing to the active element currently focused under the cursor
---@field TopPanelItem integer 1-based index pointing to the first visually visible item at the top of the pane view
---@field ViewMode integer Active panel display layout mode index (maps to m0..m9 configurations definitions)
---@field SortMode integer Active sort ordering mode tracking index metric
---@field Flags integer Native Far Manager panel state operation bitmask flags (e.g., PFLAGS_*)
---@field PluginObject any LuaFAR-specific. Present only if OwnerGuid matches active PluginGuid context lock. Used to evaluate macro calls.

---@overload fun(handle: nil, whatpanel: 0|1): tPanelInfo|nil
---Queries runtime state parameters and metadata blocks from active or passive panel frames layout.
---@param handle userdata Low-level Far Manager panel core instance frame context pointer handle
---@param whatpanel integer? Optional configuration bit: 1 maps to active panel viewport, 0 maps to passive panel viewport
---@return tPanelInfo|nil tPanelInfo Unified structure layout metadata dictionary, or nil if target pane is unallocated
function panel.GetPanelInfo(handle, whatpanel) end

---@overload fun(handle: nil, whatpanel: 0|1, keepselection?: boolean): boolean
---Forces Far Manager to refresh, reload, and rebuild the inner files and directories layout index of the target panel pane.
---@param handle userdata Low-level Far Manager panel frame handle context pointer
---@param whatpanel integer? Ignored if explicit handle parameter is passed; otherwise: 1 sets active panel, 0 sets passive panel
---@param keepselection boolean? Optional bit constraint: if true, preserves current user highlights/checks blocks across the refresh cycle. Defaults to false.
---@return boolean result Returns true if the targeted panel was successfully updated, false on execution failures or missing frames
function panel.UpdatePanel(handle, whatpanel, keepselection) end

---@class tRedrawInfo
---@field CurrentItem integer 1-based index pointing to the panel row item to focus cursor on after redrawing
---@field TopPanelItem integer 1-based index forcing the panel viewport to scroll this item row to the very top line

---@overload fun(handle: nil, whatpanel: 0|1, redrawinfo?: tRedrawInfo): boolean
---Forces Far Manager to visually repaint and redraw the specified file panel viewport on screen.
---@param handle userdata Low-level Far Manager panel frame handle context pointer, or nil
---@param whatpanel integer? Ignored if explicit handle parameter is passed; otherwise: 1 sets active panel, 0 sets passive panel
---@param redrawinfo tRedrawInfo? Optional positioning table layout constraints forcing cursor focus and top scroll boundaries
---@return boolean result Returns true if the visual repaint operation was successfully completed, false on failures
function panel.RedrawPanel(handle, whatpanel, redrawinfo) end

---@class tFarPanelDirectory
---@field Name string Absolute filesystem path or virtual VFS path of the current directory
---@field Param string Optional panel parameters or specific plug-in command-line arguments
---@field PluginId string Unique system registry 128-bit GUID mapping string of the target owning plugin
---@field File string Specific file target path if the panel is mounted directly inside an archive container

---@overload fun(handle: nil, whatpanel: 0|1): tFarPanelDirectory|nil
---Retrieves detailed directory path parameters and metadata blocks from the specified panel frame layout.
---@param handle userdata Low-level Far Manager panel core instance frame context pointer handle, or nil
---@param whatpanel integer? Ignored if explicit handle parameter is passed; otherwise: 1 sets active panel, 0 sets passive panel
---@return tFarPanelDirectory|nil PanelDir Structured directory metadata dictionary, or nil if target pane is unallocated
function panel.GetPanelDirectory(handle, whatpanel) end

---@class tPluginPanelItem
---@field LastWriteTime number|userdata Number of time ticks since Jan 1, 1601, or bit64-userdata structure
---@field LastAccessTime number|userdata Number of time ticks since Jan 1, 1601, or bit64-userdata structure
---@field CreationTime number|userdata Number of time ticks since Jan 1, 1601, or bit64-userdata structure
---@field ChangeTime number|userdata Number of time ticks since Jan 1, 1601, or bit64-userdata structure
---@field FileSize number Logical payload size of the panel element in bytes
---@field AllocationSize number Physical sectors layout occupancy size constraints inside storage container
---@field FileName string Virtual or physical name string of the targeted item element row
---@field AlternateFileName string Short 8.3 legacy fallback filename placeholder string mapping container boundaries
---@field FileAttributes string Concatenated string of alphanumeric attribute flags (e.g. 'd' for directory, 'a' for archive)
---@field Flags integer Native internal Far Manager operational state flags mask mapping indicators
---@field NumberOfLinks integer Hard link counter metric assigned onto OS file system entry targets
---@field CRC32 integer Hardware file content integrity verification checksum metric trailer
---@field Description string|nil Advanced item annotation description line text string extracted via metadata extensions
---@field Owner string|nil Security owner token account name text string mapping active asset records
---@field CustomColumnData table|nil Matrix array of formatted column strings mapping active custom visual viewport modes
---@field UserData any Scoped custom value storage metadata buffer allocated by current session plugin context hooks
---
---### FileAttributes Character Map Guidelines:
---* `a` - Archive
---* `c` - Compressed
---* `d` - Directory folder container layer
---* `e` - Reparse point anchor
---* `h` - Hidden system visibility bit flag
---* `i` - Not content indexed marker asset properties
---* `n` - Encrypted data cipher block
---* `o` - Offline target resource mode mapping
---* `p` - Sparse file layout metrics tracker
---* `r` - Read only write protection status
---* `s` - System file service marker anchor
---* `t` - Temporary cache memory workspace storage
---* `u` - No scrub data verification parameters bounds
---* `v` - Virtual memory partition element container

---@overload fun(handle: nil, whatpanel: 0|1): tPluginPanelItem|nil
---Retrieves detailed file attributes metadata and content metrics from the element currently focused under the panel cursor.
---@param handle userdata Low-level Far Manager panel core instance frame context pointer handle, or nil
---@param whatpanel integer? Ignored if explicit handle parameter is passed; otherwise: 1 sets active panel, 0 sets passive panel
---@return tPluginPanelItem|nil item Structured panel row element metadata dictionary, or nil if target cursor resides on an unallocated or empty pane view
function panel.GetCurrentPanelItem(handle, whatpanel) end


---@class M
M = {}
---Native Far Manager VFS operational callback triggered whenever a user attempts to create a new folder node (F7).
---
---### Note 1:
---The 3-rd parameter (`Name`) should be strictly ignored inside the implementation body.
---It is preserved solely to maintain backward compatibility across old interface layers.
---
---### Return Sizing (Status Codes):
---* `1`  - Directory created successfully.
---* `0`  - Operation was explicitly aborted or cancelled by the user.
---* `-1` - Execution collapsed (e.g. folder already exists, naming collision, or storage full bounds).
---@param object table The active parent plugin panel context mapping states
---@param handle userdata Low-level Far Manager panel frame handle context pointer
---@param Name any Obsolete layout string parameter. **MUST BE IGNORED** inside the routine body.
---@param OpMode integer Native operational bitmask modification flags passed by Far Manager core (F.OPM_*)
---@return integer Status Execution result integer code mapping onto standard Far Manager API boundaries
---@return string? NewName Optional string parameter containing the actual or modified newly established directory node name string
function M.MakeDirectory(object, handle, Name, OpMode) end

---@class tAnalyseInfo
---@field FileName string Absolute UTF-8 host filesystem path targeting the resource being analyzed
---@field Buffer string Binary buffer slice containing raw initial bytes read from the target resource header
---@field OpMode integer Native operation bitmask flags passed by Far Manager core (F.OPM_*)
---@field Handle any|nil Internal user data object returned previously by export.Analyse module routine

---@class tShortcutInfo
---@field HostFile string Absolute target file container path mapping the shortcut reference destination
---@field ShortcutData string Internal serialization command metadata string tracked within Far shortcut registry
---@field Flags integer Native shortcut execution bitmask operational status modifiers flags

---@class tDialogInfo
---@field hDlg tFarDialogHandle Active system dialog handle object context allocated inside active workspace

---@class tMacroArgsTable : table
---@field n integer Total sequential array size capacity elements counter parameter logged inside macro call stack

---@overload fun(OpenFrom: 6, Guid: string, Item: tMacroArgsTable): ...any # OPEN_FROMMACRO handler routing
---@overload fun(OpenFrom: 0, Guid: string, Item: string): table|integer|nil # OPEN_COMMANDLINE handler routing
---@overload fun(OpenFrom: 1, Guid: string, Item: tShortcutInfo): table|integer|nil # OPEN_SHORTCUT handler routing
---@overload fun(OpenFrom: 2, Guid: string, Item: tDialogInfo): table|integer|nil # OPEN_DIALOG handler routing
---@overload fun(OpenFrom: 9, Guid: string, Item: tAnalyseInfo): table|integer|nil # OPEN_ANALYSE handler routing
---
---Core entry point orchestration callback invoked by Far Manager core engine to initialize and mount VFS panel layers.
---
---### General Return Handling Bounds (Except OPEN_FROMMACRO):
---* `nil` or `false` - Rejects the request frame. NULL is returned straight back to Far Manager.
---* `-1`             - Terminates active routines. PANEL_STOP is returned straight back to Far Manager.
---* `table`          - Successful VFS panel instantiation instance state tracker object context map.
---@param OpenFrom integer Native activation context origin code key (maps to standard F.OPEN_*)
---@param Guid string System unique registry 128-bit GUID identification token mapping string
---@param Item any Input parameter object matching signature properties constraints defined by the active OpenFrom origin context mode
---@return any ret Handled response evaluation result parameter passed right back to the Far Manager core execution layout
function M.Open(OpenFrom, Guid, Item) end


---Retrieves the current input code page identifier assigned onto the active Windows console process frame context.
---@return integer code_page The active numerical code page index (e.g., 65001 for UTF-8 or 1251 for Windows-1251)
function win.GetConsoleCP() end

---Assigns a fresh input code page identifier onto the active Windows console process frame context.
---@param code_page integer The targeted numerical code page index to enforce (use 866 to swap execution toward TR-DOS CP866)
---@return boolean success Returns true if the console code page layout was safely mutated, false on OS failures
function win.SetConsoleCP(code_page) end

---Converts a standard UTF-8 string into the active console OEM code page layout representation block.
---@param utf8_str string Clean input UTF-8 string token characters sequence
---@return string oem_bytes Raw binary formatted string matching active console code page bounds
function win.Utf8ToOem(utf8_str) end

---Converts a raw binary formatted string from active console OEM layout back into standard clean UTF-8.
---@param oem_bytes string Raw binary input characters stream block
---@return string utf8_str Pristine UTF-8 string character mapping sequence ready for visual layout render frames
function win.OemToUtf8(oem_bytes) end

---Assigns a fresh input code page identifier onto the active Windows console process frame context.
---@param codepage integer The targeted numerical code page index to enforce (use 866 to swap execution toward TR-DOS CP866)
---@return boolean|nil result Returns true if the console code page layout was safely mutated, or nil on OS failures
---@return string? error_message Present only if result evaluates to nil; contains detailed OS system error text payload description
function win.SetConsoleCP(codepage) end

