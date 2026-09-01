utf8_to_html = require("utf8_to_html")

DEFAULT_EXPORT_PATH = "/tmp/temp"

-- Helper function to get mouse position. Uses only non-deprecated APIs; the
-- legacy get_pointer() path is avoided because it is a known source of native
-- crashes via LGI on the Windows Gdk backend. Any failure yields (nil, nil).
function get_mouse_position()
  local ok, x, y = pcall(function()
    local lgi = require("LuaGObject")
    local display = lgi.Gdk.Display.get_default()
    local seat = display:get_default_seat()
    local pointer = seat:get_pointer()
    local _, px, py = pointer:get_position()
    return px, py
  end)
  if not ok then return nil, nil end
  return x, y
end

-- Centralized Bookmark Parsing
function parse_bookmark(txt)
  local prefix, content = txt:match("^(%*)%s*(.*)")
  if not prefix then
    prefix, content = txt:match("^(%-+>)%s*(.*)")
  end
  return prefix, content
end

-- Set current layer in a version-tolerant way.
function set_current_layer_compat(layer)
  if not layer then return false end
  local ok = pcall(app.setCurrentLayer, layer, false)
  if ok then return true end
  return pcall(app.setCurrentLayer, layer)
end

-- Decode the XML entities used inside .xopp text elements.
function xml_unescape(str)
  if not str then return "" end

  local function utf8_char(code)
    code = tonumber(code)
    if not code then return "" end

    if utf8 and utf8.char then
      local ok, ch = pcall(utf8.char, code)
      if ok and ch then return ch end
    end
    if code >= 0 and code <= 127 then return string.char(code) end
    return ""
  end

  str = str:gsub("&#x(%x+);", function(hex) return utf8_char(tonumber(hex, 16)) end)
  str = str:gsub("&#(%d+);", function(dec) return utf8_char(tonumber(dec, 10)) end)
  str = str:gsub("&quot;", "\"")
  str = str:gsub("&apos;", "'")
  str = str:gsub("&lt;", "<")
  str = str:gsub("&gt;", ">")
  str = str:gsub("&amp;", "&")
  return str
end

function xml_attr(attrs, name)
  if not attrs then return nil end
  local value = attrs:match(name .. '="([^"]*)"')
  if value then return xml_unescape(value) end
  value = attrs:match(name .. "='([^']*)'")
  if value then return xml_unescape(value) end
  return nil
end

-- Read the saved .xopp file without changing the visible page.
-- Uses a pure-Lua gzip/Deflate decompressor (inflate.lua) so it works on any
-- platform, including Windows where the `gzip` binary is not available. The
-- .xopp format is gzip-compressed XML; we decompress it in memory and return
-- the XML text for all pages.
function read_xopp_xml_from_disk()
  local inflate = require("inflate")
  local structure = app.getDocumentStructure()
  local filename = structure and structure.xoppFilename
  if not filename or filename == "" then return nil end

  local ok, bytes = pcall(function()
    local fh = io.open(filename, "rb")
    if not fh then return nil end
    local data = fh:read("*a")
    fh:close()
    return data
  end)
  if not ok or not bytes then return nil end

  return inflate.gunzip(bytes)
end

-- Cache of get_all_texts() results. Keyed by page/layer structure so repeated
-- calls (e.g. Next/Previous Bookmark navigation) stay instant; cleared on any
-- plugin bookmark mutation (create/edit/delete). A short TTL bounds staleness
-- if text is changed directly in the document (outside the plugin).
local allTextsCache = nil
local CACHE_TTL = 3.0

-- Compact signature of the document structure: page count + layer count per
-- page. Any change here invalidates cached text lists.
local function structure_cache_sig(structure)
  local parts = { tostring(#(structure.pages or {})) }
  for p = 1, #(structure.pages or {}) do
    local pi = structure.pages[p]
    parts[#parts + 1] = ":" .. tostring(pi and #(pi.layers or {}) or 0)
  end
  return table.concat(parts)
end

-- Copy a text element returned by the native getTexts() API, tagging it with
-- the page/layer it came from (unless the element already carries them).
local function annotate_text(t, page, layer)
  local item = {}
  for k, v in pairs(t) do item[k] = v end
  item.page = item.page or page
  item.layer = item.layer or layer
  return item
end

-- Silent background save triggered only when bookmarks are altered.
function save_document_silently()
  -- Any save from this plugin invalidates the cached text list; bookmarks may
  -- have been added/edited/removed.
  allTextsCache = nil

  local structure = app.getDocumentStructure()
  local filename = structure and structure.xoppFilename

  if not filename or filename == "" then
    pcall(app.activateAction, "save-as")
    pcall(app.activateAction, "document-save-as")
    pcall(app.uiAction, { action = "ACTION_SAVE_AS" })
    return false
  end

  local attempted = false
  local actionNames = {"save", "document-save", "file-save"}

  for _, actionName in ipairs(actionNames) do
    local ok = pcall(app.activateAction, actionName)
    attempted = attempted or ok
    if ok then break end
  end

  if not attempted then
    pcall(app.uiAction, { action = "ACTION_SAVE" })
  end

  return true
end

-- Fast, unified text reader. Replaces both old text fetchers.
function get_all_texts()
  local structure = app.getDocumentStructure()
  if not structure or not structure.pages or #structure.pages == 0 then
    return {}
  end

  local sig = structure_cache_sig(structure)
  if allTextsCache and allTextsCache.sig == sig
     and os.clock() - (allTextsCache.t or 0) < CACHE_TTL then
    return allTextsCache.texts
  end

  local texts, complete
  local okAll, allTexts = pcall(app.getTexts, "all")
  if okAll and type(allTexts) == "table" and #allTexts > 0 then
    texts, complete = allTexts, true
  else
    texts, complete = read_all_texts_native(structure)
    if not complete then
      texts, complete = read_all_texts_fallback(structure, texts)
    end
  end

  if complete then
    allTextsCache = { sig = sig, texts = texts, t = os.clock() }
  end
  return texts
end

-- Read every page (and every real layer) through the native getTexts("layer")
-- API. This is far faster on large files than decompressing the .xopp and
-- always reflects the live in-memory document. setCurrentPage/setCurrentLayer
-- do not scroll the view or change layer visibility; the original page + layer
-- are restored. Returns (texts, complete).
function read_all_texts_native(structure)
  local texts = {}
  local origPage = structure.currentPage or 1

  local ok = pcall(function()
    for p = 1, #structure.pages do
      app.setCurrentPage(p)
      local pageInfo = structure.pages[p]
      -- layers is 0-indexed: [0]=background, [1..N]=real layers. The `#`
      -- operator counts the 1-based trailing entries, i.e. the real layers.
      local nLayers = math.max(1, #(pageInfo.layers or {}))
      for l = 1, nLayers do
        pcall(app.setCurrentLayer, l, false)
        local okL, layerTexts = pcall(app.getTexts, "layer")
        if okL and type(layerTexts) == "table" then
          for _, t in ipairs(layerTexts) do
            table.insert(texts, annotate_text(t, p, l))
          end
        end
      end
    end
  end)

  -- Restore the original page and layer in all cases.
  pcall(app.setCurrentPage, origPage)
  local origInfo = structure.pages[origPage]
  if origInfo then
    pcall(app.setCurrentLayer, origInfo.currentLayer or 1, false)
  end

  return texts, ok and #texts > 0
end

-- Read all text elements from the on-disk .xopp file (works everywhere), and
-- if that is not possible, fall back to the current page's active layer.
function read_all_texts_fallback(structure, texts)
  local xml = read_xopp_xml_from_disk()
  if xml then
    local result = {}
    local pageNr = 0

    for pageAttrs, pageBody in xml:gmatch("<page([^>]*)>(.-)</page>") do
      pageNr = pageNr + 1
      local layerNr = 0

      for layerAttrs, layerBody in pageBody:gmatch("<layer([^>]*)>(.-)</layer>") do
        layerNr = layerNr + 1

        for textAttrs, encodedText in layerBody:gmatch("<text%s+([^>]*)>(.-)</text>") do
          table.insert(result, {
            text = xml_unescape(encodedText),
            page = pageNr,
            layer = layerNr,
            x = tonumber(xml_attr(textAttrs, "x")) or 0,
            y = tonumber(xml_attr(textAttrs, "y")) or 0,
            color = xml_attr(textAttrs, "color"),
            font = {
              name = xml_attr(textAttrs, "font") or "Sans Regular",
              size = tonumber(xml_attr(textAttrs, "size")) or 12.0
            },
            ref = nil
          })
        end
      end
    end

    -- A non-nil xml means the on-disk file was read and decompressed, so its
    -- result is authoritative for the whole document even if it has no texts.
    return result, true
  end

  -- Unsaved document with no file on disk: read just the current page's
  -- active layer via the native API. This is the only incomplete case, so it
  -- is not cached.
  local currentPage = structure.currentPage or 1
  local okLayer, layerTexts = pcall(app.getTexts, "layer")
  if okLayer and type(layerTexts) == "table" then
    for _, t in ipairs(layerTexts) do
      table.insert(texts, annotate_text(t, currentPage))
    end
  end
  return texts, false
end

function text_coord_close(a, b)
  if a == nil or b == nil then return true end
  return math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) < 0.75
end

-- Resolve a bookmark row from the no-reload list into a live element ref.
function resolve_bookmark_element(bookmark)
  if not bookmark then return nil end
  if bookmark.ref then return bookmark.ref, bookmark end

  app.setCurrentPage(bookmark.page)
  set_current_layer_compat(bookmark.layer or 1)

  local okTexts, layerTexts = pcall(app.getTexts, "layer")
  if not okTexts or type(layerTexts) ~= "table" then return nil end

  local fallback = nil
  for _, t in ipairs(layerTexts) do
    if (t.text or "") == (bookmark.name or bookmark.text or "") then
      fallback = fallback or t

      if text_coord_close(t.x, bookmark.x) and text_coord_close(t.y, bookmark.y) then
        bookmark.ref = t.ref
        bookmark.x = t.x
        bookmark.y = t.y
        bookmark.color = t.color
        bookmark.font = t.font
        return t.ref, t
      end
    end
  end

  if fallback then
    bookmark.ref = fallback.ref
    bookmark.x = fallback.x
    bookmark.y = fallback.y
    bookmark.color = fallback.color
    bookmark.font = fallback.font
    return fallback.ref, fallback
  end

  return nil
end

-- Centralized Bookmark Styling
function get_bookmark_style(text, defaultFontName)
  local baseFontFamily = defaultFontName:gsub(" Regular$", ""):gsub(" Bold$", ""):gsub(" Italic$", ""):gsub(" Black$", "")
  local fontName = baseFontFamily
  local fontSize = 25.0

  if text:match("^%*") then
    if baseFontFamily == "Segoe UI" then
      fontName = baseFontFamily .. " Black"
    else
      fontName = baseFontFamily .. " Bold"
    end
    fontSize = 25.0
  elseif text:match("^%-+>") then
    local depth = string.len(text:match("^(%-+)>"))
    if depth == 1 then
      if baseFontFamily == "Segoe UI" then
        fontName = baseFontFamily .. " Bold"
      else
        fontName = baseFontFamily .. " Regular"
      end
      fontSize = 20.0
    else
      fontName = baseFontFamily .. " Regular"
      fontSize = math.max(15.0, 20.0 - ((depth - 1) * 5.0))
    end
  end
  return fontName, fontSize
end

-- Register Toolbar
function initUi()
  app.registerUi({menu="Previous Bookmark", toolbarId="CUSTOM_PREVIOUS_BOOKMARK", callback="search_bookmark", mode=-1, iconName="go-previous"})
  app.registerUi({menu="New Bookmark", toolbarId="CUSTOM_NEW_BOOKMARK", callback="dialog_new_bookmark", iconName="bookmark-new-symbolic", ["accelerator"]="B"})
  app.registerUi({menu="New Bookmark (No dialog)", toolbarId="CUSTOM_NEW_BOOKMARK_NO_DIALOG", callback="new_bookmark", iconName="bookmark-new-symbolic"})
  app.registerUi({menu="Next Bookmark", toolbarId="CUSTOM_NEXT_BOOKMARK", callback="search_bookmark", mode=1, iconName="go-next"})
  app.registerUi({menu="View Bookmarks", toolbarId="CUSTOM_VIEW_BOOKMARKS", callback = "view_bookmarks", iconName="user-bookmarks-symbolic", ["accelerator"]="<Shift>B"})
  app.registerUi({menu="Export to PDF with Bookmarks", toolbarId="CUSTOM_EXPORT_WITH_BOOKMARKS", callback="export", iconName="xopp-document-export-pdf"})

  local sep = package.config:sub(1,1)
  sourcePath = debug.getinfo(1).source:match("@?(.*" .. sep .. ")")
  if sep == "\\" then DEFAULT_EXPORT_PATH = "%TEMP%\\temp" end
end

function new_bookmark(name)
  if not name or name == "" then return end

  local fontColor = 0x000000
  local fontName = "Sans Regular"
  
  local textToolInfo = app.getToolInfo("text")
  if textToolInfo then
    fontName = (textToolInfo.font and textToolInfo.font.name) or fontName
    fontColor = textToolInfo.color or fontColor
  end

  local newFontName, newFontSize = get_bookmark_style(name, fontName)

  local refs = app.addTexts({
    texts = {
      { text = name, x = 20, y = 20, color = fontColor, font = { name = newFontName, size = newFontSize } }
    }
  })

  if refs and #refs > 0 then
    local currentPage = app.getDocumentStructure().currentPage
    app.clearSelection()
    app.addToSelection(refs)
    app.scrollToPage(currentPage)
    app.refreshPage()
  end

  -- Invalidate the cached text list so later reads see the new bookmark. We do
  -- NOT trigger an immediate disk save here: it reloads/resets the document and
  -- would deselect the text we just selected. The change stays in-memory (and
  -- in xournalpp's undo stack); it hits disk on the user's next normal save.
  allTextsCache = nil

  return refs, name
end

function search_bookmark(mode)
  local allTexts = get_all_texts()
  if not allTexts then return end

  local bookmarkPages = {}
  for _, t in ipairs(allTexts) do
    if parse_bookmark(t.text or "") and t.page then
      bookmarkPages[t.page] = true
    end
  end

  local structure = app.getDocumentStructure()
  local numPages = #structure.pages
  local page = structure.currentPage

  for _ = 1, numPages do
    page = page + mode
    if page > numPages then page = 1 end
    if page < 1 then page = numPages end
    
    if bookmarkPages[page] then
      app.setCurrentPage(page)
      app.scrollToPage(page)
      return
    end
  end

  app.openDialog("No bookmark found.", {"Ok"}, "")
end

function dialog_new_bookmark()
  local hasLgi, lgi = pcall(require, "LuaGObject")
  if not hasLgi then return new_bookmark() end

  local Gtk = lgi.require("Gtk", "3.0")
  local builder = Gtk.Builder()
  assert(builder:add_from_file(sourcePath .. "dlgNew.glade"))
  
  local ui = builder.objects
  local dialog = ui.dlgNew
  dialog:set_title("Xournalpp - New bookmark")
  ui.btnNewOk:set_sensitive(false)

  local new_refs, new_name = nil, nil

  function ui.entryName:on_changed()
    ui.btnNewOk:set_sensitive(parse_bookmark(self:get_text()) ~= nil)
  end

  local function ok()
    local name = ui.entryName:get_text()
    if parse_bookmark(name) then
      new_refs, new_name = new_bookmark(name)
      dialog:destroy()
    end
  end

  ui.btnNewOk.on_clicked = ok
  ui.entryName.on_activate = ok
  function ui.btnNewCancel:on_clicked() dialog:destroy() end

  local mouse_x, mouse_y = get_mouse_position()
  dialog:show_all()
  if mouse_x and mouse_y then
    dialog:move(math.floor(mouse_x - dialog:get_allocated_width() / 2), math.floor(mouse_y - dialog:get_allocated_height() / 2))
  end

  return new_refs, new_name
end

function delete_bookmark(page, layer, elementRef)
  if not elementRef then return end
  app.setCurrentPage(page)
  set_current_layer_compat(layer or 1)
  app.clearSelection()
  app.addToSelection({elementRef})
  app.activateAction("delete")
  app.clearSelection()
  app.refreshPage()

  -- Sync UI deletion to disk
  save_document_silently()
end

function view_bookmarks()
  local hasLgi, lgi = pcall(require, "LuaGObject")
  if not hasLgi then
    return app.openDialog("Lua lgi-module is required to view bookmarks.", {"OK"}, "")
  end

  -- Run the real implementation inside pcall so an unexpected Lua error does
  -- not leave the GTK main loop in a corrupt state.
  local ok, err = pcall(view_bookmarks_impl, lgi)
  if not ok then
    app.openDialog("An error occurred while opening the bookmark manager.\n\n" .. tostring(err), {"OK"}, "", true)
  end
end

function view_bookmarks_impl(lgi)
  local Gtk = lgi.require("Gtk", "3.0")
  local builder = Gtk.Builder()
  assert(builder:add_from_file(sourcePath .. "dlgBookmarks.glade"))

  local ui, dialog = builder.objects, builder.objects.dlgBookmarks
  dialog:set_title("Xournalpp - Bookmarks Manager")

  -- Paint the window background black before the dialog is shown, so the
  -- default (light) window color does not flash white during initialization.
  -- path:
  --   1. realize() so the GdkWindow exists;
  --   2. set the GDK-level background RGBA on that window (affects the very
  --      first surface paint, before any GTK draw pass);
  --   3. override_background_color keeps it black once GTK draws the frame.
  pcall(function()
    dialog:realize()
    local rgba = lgi.Gdk.RGBA()
    rgba.red, rgba.green, rgba.blue, rgba.alpha = 0, 0, 0, 1
    local gwin = dialog:get_window()
    if gwin then gwin:set_background_rgba(rgba) end
    dialog:override_background_color(lgi.Gtk.StateFlags.NORMAL, rgba)
  end)

  local column = { PAGE = 1, LAYER = 2, PREFIX = 3, DISPLAY_NAME = 4, NAME = 5, IDX = 6 }
  local store = Gtk.ListStore.new {
    [column.PAGE] = lgi.GObject.Type.UINT,
    [column.LAYER] = lgi.GObject.Type.UINT,
    [column.PREFIX] = lgi.GObject.Type.STRING,
    [column.DISPLAY_NAME] = lgi.GObject.Type.STRING,
    [column.NAME] = lgi.GObject.Type.STRING,
    [column.IDX] = lgi.GObject.Type.UINT
  }

  local bookmarks = {}

  local function get_bookmark_from_iter(model, iter)
    if not model or not iter then return nil end
    local idx = model[iter][column.IDX]
    if not idx then return nil end
    return bookmarks[idx]
  end

  local function update_row_from_bookmark(model, iter, b)
    if not model or not iter or not b then return end
    local prefix, content = parse_bookmark(b.name or b.text or "")
    b.prefix = prefix or b.prefix or ""
    b.displayName = content or b.displayName or ""
    model[iter][column.PAGE] = b.page or 1
    model[iter][column.LAYER] = b.layer or 1
    model[iter][column.PREFIX] = b.prefix
    model[iter][column.DISPLAY_NAME] = b.displayName
    model[iter][column.NAME] = b.name or b.text or ""
  end

  local function updateTable()
    store:clear()
    bookmarks = {}

    local allTexts = get_all_texts()
    local currentPage = app.getDocumentStructure().currentPage
    local closest_exact_idx, closest_below_idx, closest_above_idx

    for _, t in ipairs(allTexts or {}) do
      local prefix, content = parse_bookmark(t.text or "")
      if prefix and t.page then
        table.insert(bookmarks, {
          page = t.page,
          layer = t.layer or 1,
          prefix = prefix,
          displayName = content,
          name = t.text,
          text = t.text,
          ref = t.ref,
          x = t.x or 0,
          y = t.y or 0,
          color = t.color,
          font = t.font
        })
      end
    end

    table.sort(bookmarks, function(a, b)
      if a.page ~= b.page then return a.page < b.page end
      if (a.layer or 1) ~= (b.layer or 1) then return (a.layer or 1) < (b.layer or 1) end
      return (a.y or 0) < (b.y or 0)
    end)

    for i, b in ipairs(bookmarks) do
      store:append({b.page, b.layer or 1, b.prefix, b.displayName, b.name, i})

      if b.page == currentPage then
        if not closest_exact_idx then closest_exact_idx = i end
      elseif b.page < currentPage then
        closest_below_idx = i
      elseif b.page > currentPage then
        if not closest_above_idx then closest_above_idx = i end
      end
    end

    local best_idx = nil
    if closest_exact_idx then
      best_idx = closest_exact_idx
    else
      local dist_below = closest_below_idx and (currentPage - bookmarks[closest_below_idx].page) or math.huge
      local dist_above = closest_above_idx and (bookmarks[closest_above_idx].page - currentPage) or math.huge
      if dist_below <= dist_above and closest_below_idx then
        best_idx = closest_below_idx
      elseif closest_above_idx then
        best_idx = closest_above_idx
      end
    end

    return best_idx
  end

  local initial_best_idx = updateTable()

  local active_edit = nil

  -- Apply a rename/edit of a bookmark's text to the live document. Shared by
  -- the cell renderer (Enter), focus-out (clicking away / pressing Done).
  local function apply_edit(path_str, new_text)
    local success, iter = store:get_iter(Gtk.TreePath.new_from_string(path_str))
    iter = type(success) == "userdata" and success or iter
    if not iter then return end

    local model = store
    local b = get_bookmark_from_iter(model, iter)
    if not b then return end

    local final_text = new_text:match("^%s*(.-)$") or ""
    local typed_prefix, typed_content = parse_bookmark(final_text)

    if not typed_prefix then
      local old_prefix = parse_bookmark(b.name or "")
      if old_prefix then final_text = old_prefix .. " " .. final_text end
    else
      final_text = typed_prefix .. " " .. typed_content
    end

    if not parse_bookmark(final_text) then
      return app.openDialog("Invalid Bookmark", {"OK"}, "Must start with '*' or '->'.", true)
    end

    local ref, liveEl = resolve_bookmark_element(b)
    if not ref then
      return app.openDialog("Bookmark not found in current document.", {"OK"}, "Refresh the bookmark list.", true)
    end

    app.clearSelection()
    app.addToSelection({ref})

    local selTexts = app.getTexts("selection")
    if selTexts and #selTexts > 0 then
      local oldEl = selTexts[1]
      app.activateAction("delete")
      app.clearSelection()

      local fontName = "Sans Regular"
      if oldEl.font and oldEl.font.name then fontName = oldEl.font.name end

      local newFontName, newFontSize = get_bookmark_style(final_text, fontName)
      local refs = app.addTexts({
        texts = {
          {
            text = final_text,
            x = oldEl.x,
            y = oldEl.y,
            color = oldEl.color,
            font = { name = newFontName, size = newFontSize }
          }
        }
      })

      b.name = final_text
      b.text = final_text
      b.x = oldEl.x
      b.y = oldEl.y
      b.color = oldEl.color
      b.font = { name = newFontName, size = newFontSize }
      b.ref = refs and refs[1] or nil

      app.refreshPage()
      update_row_from_bookmark(model, iter, b)

      -- Sync UI modification to disk
      save_document_silently()
    else
      app.clearSelection()
    end
  end

  -- Commit the in-progress cell edit, unless it was already applied (e.g. the
  -- edit was Enter-committed and the teardown focus-out fires afterwards) or
  -- the user explicitly cancelled with Escape.
  local function commit_active_edit()
    local session = active_edit
    if session and not session.committed and not session.canceled then
      session.committed = true
      apply_edit(session.path, session.entry:get_text())
    end
  end

  local nameRenderer = Gtk.CellRendererText { editable = true }
  function nameRenderer:on_edited(path_str, new_text)
    if active_edit and active_edit.committed then
      active_edit = nil
      return
    end
    active_edit = nil
    apply_edit(path_str, new_text)
  end

  function nameRenderer:on_editing_started(editable, path)
    active_edit = { entry = editable, path = path, committed = false, canceled = false }

    -- Escape cancels the edit like Gtk does; make sure the focus-out that
    -- follows does not commit the discarded text.
    function editable:on_key_press_event(event)
      if event.keyval == lgi.Gdk.KEY_Escape then active_edit.canceled = true end
      return false
    end

    -- Clicking away (or onto Done) ends editing without emitting `edited` in
    -- GTK3, so commit the text explicitly here.
    function editable:on_focus_out_event()
      commit_active_edit()
      return false
    end
  end

  local treeView = Gtk.TreeView {
    model = store,
    Gtk.TreeViewColumn { 
      title = "Page", sizing = "FIXED", fixed_width = 50, 
      { Gtk.CellRendererText {}, {text = column.PAGE} } 
    },
    Gtk.TreeViewColumn { 
      title = "", sizing = "FIXED", fixed_width = 40, 
      { Gtk.CellRendererText {}, {text = column.PREFIX} } 
    },
    Gtk.TreeViewColumn {
      title = "Name",
      expand = true,
      {
        nameRenderer,
        {text = column.DISPLAY_NAME},
      }
    }
  }

  local drag_active = false
  local drag_start_y = 0
  local scroll_start_val = 0
  local last_y = 0
  local velocity = 0
  local scroll_tick = nil
  local dialog_destroyed = false

  local function stop_inertia()
    if scroll_tick then
      lgi.GLib.source_remove(scroll_tick)
      scroll_tick = nil
    end
  end

  function treeView:on_button_press_event(event)
    if dialog_destroyed then return false end
    if event.button == 1 then
      drag_active = true
      drag_start_y = event.y_root
      last_y = event.y_root
      scroll_start_val = ui.scrolledWindow:get_vadjustment():get_value()
      velocity = 0
      stop_inertia()
    end
    return false 
  end

  function treeView:on_button_release_event(event)
    if dialog_destroyed then return false end
    if event.button == 1 then 
      drag_active = false 
      if math.abs(velocity) > 1.5 then
        scroll_tick = lgi.GLib.timeout_add(lgi.GLib.PRIORITY_DEFAULT, 16, function()
          -- Guard against use-after-free: the dialog may have been destroyed
          -- while this timeout was pending.
          if dialog_destroyed or drag_active then return false end

          local vadj = ui.scrolledWindow:get_vadjustment()
          local new_val = vadj:get_value() - velocity

          local lower_limit = vadj:get_lower()
          local upper_limit = vadj:get_upper() - vadj:get_page_size()

          if new_val <= lower_limit then 
            new_val = lower_limit
            velocity = 0 
          elseif new_val >= upper_limit then 
            new_val = upper_limit
            velocity = 0 
          end

          vadj:set_value(new_val)
          velocity = velocity * 0.90 

          if math.abs(velocity) < 0.5 then
            scroll_tick = nil
            return false
          end
          return true
        end)
      end
    end
    return false
  end

  function treeView:on_motion_notify_event(event)
    if dialog_destroyed then return false end
    if drag_active then
      velocity = event.y_root - last_y
      last_y = event.y_root

      local dy = drag_start_y - event.y_root
      local vadj = ui.scrolledWindow:get_vadjustment()
      vadj:set_value(scroll_start_val + dy)

      if math.abs(dy) > 5 then return true end
    end
    return false
  end

  ui.scrolledWindow:add(treeView)

  function treeView:on_row_activated(path)
    local model, iter = self:get_model(), self:get_model():get_iter(path)
    if iter then
      local b = get_bookmark_from_iter(model, iter)
      if not b then return end

      app.setCurrentPage(b.page)
      set_current_layer_compat(b.layer or 1)
      app.scrollToPage(b.page)

      local ref = resolve_bookmark_element(b)
      if ref then
        app.clearSelection()
        app.addToSelection({ref})
      end

      dialog:destroy()
    end
  end

  function ui.btnNew:on_clicked()
    local refs, createdName = dialog_new_bookmark()
    if (not refs or #refs == 0) and not createdName then return end
    local newRef = refs and refs[1]

    -- Rebuild the bookmark list so the new entry appears, then select the row
    -- that references the newly created text element (match by ref identity,
    -- falling back to the text on the current page).
    local currentPage = app.getDocumentStructure().currentPage
    updateTable()
    local treeSel = treeView:get_selection()
    for i, b in ipairs(bookmarks) do
      local matches = (newRef and b.ref == newRef)
          or (createdName and b.page == currentPage and b.text == createdName)
      if matches then
        local path = Gtk.TreePath.new_from_string(tostring(i - 1))
        treeSel:select_path(path)
        treeView:scroll_to_cell(path, nil, true, 0.5, 0.5)
        break
      end
    end
  end

  function ui.btnDelete:on_clicked()
    local model, iter = treeView:get_selection():get_selected()
    if not iter then return end

    local b = get_bookmark_from_iter(model, iter)
    if not b then return end

    local ref = resolve_bookmark_element(b)
    if not ref then
      return app.openDialog("Bookmark not found in current document.", {"OK"}, "Refresh the bookmark list.", true)
    end

    app.clearSelection()
    app.addToSelection({ref})
    app.activateAction("delete")
    app.clearSelection()
    app.refreshPage()

    pcall(function() store:remove(iter) end)
    
    -- Sync UI deletion to disk
    save_document_silently()
  end

  function dialog:on_destroy()
    dialog_destroyed = true
    stop_inertia()
  end

  function ui.btnDone:on_clicked()
    commit_active_edit()
    dialog:destroy()
  end

  local mx, my = get_mouse_position()
  dialog:show_all()
  if mx and my then
    dialog:move(math.floor(mx - dialog:get_allocated_width() / 2), math.floor(my - dialog:get_allocated_height() / 2))
  end

  if initial_best_idx then
    local okPath, path = pcall(lgi.Gtk.TreePath.new_from_string, tostring(initial_best_idx - 1))
    if okPath and path then
      local sel = treeView:get_selection()
      local okSel = pcall(function()
        sel:select_path(path)
        treeView:scroll_to_cell(path, nil, true, 0.5, 0.0)
      end)
    end
  end
end

function export()
  local sep = package.config:sub(1,1)
  local pdftkOk = pcall(os.execute, "pdftk --version")
  if sep == "\\" then
    -- On Windows, pdftk is generally not available and the command-line based
    -- PDF bookmark injection is not supported.
    return app.openDialog("Export with bookmarks currently requires the `pdftk` tool, which was not found.", {"OK"}, "", true)
  end
  if not pdftkOk then return app.openDialog("pdftk is missing.", {"OK"}, "") end

  local structure = app.getDocumentStructure()
  local defaultName = (structure.xoppFilename and structure.xoppFilename:match("(.+)%..+$") or DEFAULT_EXPORT_PATH) .. "_export.pdf"
  local path = app.saveAs(defaultName)
  if not path then return end

  local tempData = os.tmpname()
  local tempPdf = tempData .. "_1337__.pdf"

  app.export({outputFile = tempPdf})
  os.execute("pdftk \"" .. tempPdf .. "\" dump_data output \"" .. tempData .. "\"")

  local bookmarks = {}
  local allTexts = get_all_texts()
  
  for _, t in ipairs(allTexts) do
    if parse_bookmark(t.text or "") and t.page then
      table.insert(bookmarks, { page = t.page, name = utf8_to_html(t.text), y = t.y or 0 })
    end
  end
  
  table.sort(bookmarks, function(a, b) return a.page == b.page and a.y < b.y or a.page < b.page end)
  
  local file = io.open(tempData,"a+")
  for _, b in ipairs(bookmarks) do
    file:write("BookmarkBegin\nBookmarkTitle: " .. b.name .. "\nBookmarkLevel: 1\nBookmarkPageNumber: " .. b.page .. "\n")
  end
  file:close()

  os.execute("pdftk \"" .. tempPdf .. "\" update_info \"" .. tempData .. "\" output \"" .. path .."\"")
  os.remove(tempData)
  os.remove(tempPdf)
end